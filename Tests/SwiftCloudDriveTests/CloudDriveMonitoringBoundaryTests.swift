import Foundation
import XCTest
@testable import SwiftCloudDrive

/// Native Foundation tests: not part of the Linux boundary-helper runner.
private final class CloudDriveOwningObserver: CloudDriveObserver {
    var drive: CloudDrive?

    func cloudDriveDidChange(
        _ cloudDrive: CloudDrive,
        rootRelativePaths: [RootRelativePath]
    ) {}
}

final class CloudDriveMonitoringBoundaryTests: XCTestCase, @unchecked Sendable {
    func testObserverDoesNotCreateOwnerDriveRetainCycle() async throws {
        let root = try temporaryDirectory()
        var owner: CloudDriveOwningObserver? = CloudDriveOwningObserver()
        owner?.drive = try await CloudDrive(
            storage: .localDirectory(rootURL: root),
            relativePathToRoot: "Books"
        )
        owner?.drive?.observer = owner

        weak var weakOwner = owner
        weak var weakDrive = owner?.drive
        let selectedRoot = try XCTUnwrap(owner?.drive?.rootDirectory)
            .absoluteURL.standardizedFileURL
        XCTAssertEqual(presenters(at: selectedRoot).count, 1)

        owner = nil

        XCTAssertNil(weakOwner)
        XCTAssertNil(weakDrive)
        XCTAssertTrue(
            presenters(at: selectedRoot).isEmpty,
            "Releasing a Reader-style owner must also release its drive presenter"
        )
    }

    func testDriveOwnsPresenterRegistrationAndUnregistersOnRelease() async throws {
        let root = try temporaryDirectory()
        var drive: CloudDrive? = try await CloudDrive(storage: .localDirectory(rootURL: root))
        weak var weakDrive = drive
        let presentedRoot = try XCTUnwrap(drive?.rootDirectory).absoluteURL.standardizedFileURL
        XCTAssertEqual(presenters(at: presentedRoot).count, 1)
        XCTAssertNotNil(drive)
        drive = nil
        XCTAssertNil(weakDrive)
        XCTAssertTrue(presenters(at: presentedRoot).isEmpty)
    }

    func testPresenterRegistersTheSelectedSubdirectoryNotTheContainer() async throws {
        let container = try temporaryDirectory()
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: container), relativePathToRoot: "Books")
        let selectedRoot = container.appendingPathComponent("Books", isDirectory: true).standardizedFileURL
        XCTAssertEqual(drive.rootDirectory.absoluteURL.standardizedFileURL, selectedRoot)
        XCTAssertEqual(presenters(at: selectedRoot).count, 1)
        XCTAssertTrue(presenters(at: container).isEmpty)
        withExtendedLifetime(drive) {}
    }

    func testMoveWithinRootReportsBothRelativeNames() throws {
        let root = try temporaryDirectory()
        let monitor = FileMonitor(rootDirectory: root)
        var received: [[String]] = []
        monitor.changeHandler = { received.append($0.map(\.path)) }
        monitor.presentedSubitem(at: root.appendingPathComponent("old.epub"),
                                 didMoveTo: root.appendingPathComponent("作者/new.epub"))
        XCTAssertEqual(received, [["old.epub", "作者/new.epub"]])
    }

    func testMoveAcrossRootBoundaryReportsOnlyItsInScopeSide() throws {
        let root = try temporaryDirectory()
        let monitor = FileMonitor(rootDirectory: root)
        var received: [[String]] = []
        monitor.changeHandler = { received.append($0.map(\.path)) }
        let outside = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-other/a.epub")
        let inside = root.appendingPathComponent("a.epub")
        monitor.presentedSubitem(at: inside, didMoveTo: outside)
        monitor.presentedSubitem(at: outside, didMoveTo: inside)
        monitor.presentedSubitemDidChange(at: outside)
        XCTAssertEqual(received, [["a.epub"], ["a.epub"]])
    }

    func testDuplicateMoveNamesDoNotDuplicateInvalidations() throws {
        let root = try temporaryDirectory()
        let monitor = FileMonitor(rootDirectory: root)
        var received: [[String]] = []
        monitor.changeHandler = { received.append($0.map(\.path)) }
        let url = root.appendingPathComponent("book.epub")
        monitor.presentedSubitem(at: url, didMoveTo: url)
        XCTAssertEqual(received, [["book.epub"]])
    }

    func testMetadataPredicateExcludesSiblingDirectoriesAndActiveDownloads() {
        let root = URL(fileURLWithPath: "/library/Books", isDirectory: true)
        let predicate = MetadataMonitor.downloadPredicate(rootDirectory: root)
        func item(_ path: String, downloading: Bool = false) -> [String: Any] {
            [NSMetadataItemPathKey: path,
             NSMetadataUbiquitousItemDownloadingStatusKey: NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
             NSMetadataUbiquitousItemIsDownloadingKey: downloading]
        }
        XCTAssertTrue(predicate.evaluate(with: item("/library/Books/book.epub")))
        XCTAssertFalse(predicate.evaluate(with: item("/library/BooksOld/book.epub")))
        XCTAssertFalse(predicate.evaluate(with: item("/library/Other/book.epub")))
        XCTAssertFalse(predicate.evaluate(with: item("/library/Books/book.epub", downloading: true)))
    }

    func testInvalidSelectionDoesNotCreateMissingBaseDirectory() async throws {
        let parent = try temporaryDirectory()
        for selection in ["../outside", "/outside", "Books/../outside", "Books/\u{0}outside"] {
            let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                _ = try await CloudDrive(storage: .localDirectory(rootURL: root), relativePathToRoot: selection)
                XCTFail("Invalid selection was accepted: \(selection)")
            } catch RootRelativePathError.invalidRelativePath {
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
            XCTAssertTrue(presenters(at: root).isEmpty)
        }
    }

    func testCancelledInitializationDoesNotCreateMissingBaseDirectory() async throws {
        let parent = try temporaryDirectory()
        let root = parent.appendingPathComponent("not-created", isDirectory: true)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            _ = try await CloudDrive(storage: .localDirectory(rootURL: root), relativePathToRoot: "Books")
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled initialization succeeded")
        } catch is CancellationError {
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(presenters(at: root).isEmpty)
    }

    func testMissingRootUnderAliasInitializesAndSupportsFileOperations() async throws {
        let parent = try temporaryDirectory()
        let physical = parent.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let root = alias.appendingPathComponent("new-library", isDirectory: true)
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: root), relativePathToRoot: "Books")
        let selected = root.appendingPathComponent("Books", isDirectory: true)
        XCTAssertEqual(drive.rootDirectory, selected)
        XCTAssertEqual(presenters(at: selected).count, 1)
        let payload = Data("日本語".utf8)
        let path = RootRelativePath(path: "book.txt")
        try await drive.writeFile(with: payload, at: path)
        let actual = try await drive.readFile(at: path)
        XCTAssertEqual(actual, payload)
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("new-library/Books/book.txt")), payload)
        withExtendedLifetime(drive) {}
    }

    private enum RemovalAdmissionError: Swift.Error { case obsolete }

    private func checkGuardedRemoval(isDirectory: Bool, reject: Bool) async throws {
        let root = try temporaryDirectory()
        let drive = try await CloudDrive(storage: .localDirectory(rootURL: root))
        let path = RootRelativePath(path: "selected")
        let target = root.appendingPathComponent("selected", isDirectory: isDirectory)
        let payload = isDirectory ? target.appendingPathComponent("book.txt") : target
        if isDirectory {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        }
        try Data("keep".utf8).write(to: payload)
        var admissions = 0
        do {
            try drive.removeItemSynchronously(at: path, isDirectory: isDirectory) {
                admissions += 1
                XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
                if reject { throw RemovalAdmissionError.obsolete }
            }
            XCTAssertFalse(reject, "Obsolete admission must throw")
        } catch RemovalAdmissionError.obsolete {
            XCTAssertTrue(reject)
        }
        XCTAssertEqual(admissions, 1)
        if reject {
            XCTAssertEqual(try Data(contentsOf: payload), Data("keep".utf8))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }

    func testGuardedFileRemovalRejectsFinalAdmissionAndPreservesBytes() async throws {
        try await checkGuardedRemoval(isDirectory: false, reject: true)
    }

    func testGuardedDirectoryRemovalRejectsFinalAdmissionAndPreservesBytes() async throws {
        try await checkGuardedRemoval(isDirectory: true, reject: true)
    }

    func testGuardedFileRemovalCommitsCurrentAdmission() async throws {
        try await checkGuardedRemoval(isDirectory: false, reject: false)
    }

    func testGuardedDirectoryRemovalCommitsCurrentAdmission() async throws {
        try await checkGuardedRemoval(isDirectory: true, reject: false)
    }

    func testGuardedRemovalCancelledAtAccessorPreservesBytes() async throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("book.txt")
        try Data("keep".utf8).write(to: target)
        let task = Task {
            let selectedDrive = try await CloudDrive(storage: .localDirectory(rootURL: root))
            try selectedDrive.removeItemSynchronously(at: RootRelativePath(path: "book.txt"), isDirectory: false) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Expected accessor cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testGuardedRemovalCancellationAfterCommitRemainsSuccess() async throws {
        let root = try temporaryDirectory()
        let target = root.appendingPathComponent("book.txt")
        try Data("remove".utf8).write(to: target)
        let task = Task {
            let drive = try await CloudDrive(storage: .localDirectory(rootURL: root))
            try CoordinatedRemovalObservation.$didRemove.withValue({
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                try drive.removeItemSynchronously(
                    at: RootRelativePath(path: "book.txt"), isDirectory: false,
                    validateAdmission: {}
                )
            }
            XCTAssertTrue(Task.isCancelled)
        }
        try await task.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func presenters(at root: URL) -> [any NSFilePresenter] {
        NSFileCoordinator.filePresenters.filter {
            $0.presentedItemURL?.absoluteURL.standardizedFileURL == root.absoluteURL.standardizedFileURL
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
