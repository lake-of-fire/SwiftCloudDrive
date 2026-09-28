import Foundation
import XCTest
@testable import SwiftCloudDrive

/// Native Foundation tests: not part of the Linux boundary-helper runner.
final class CloudDriveMonitoringBoundaryTests: XCTestCase, @unchecked Sendable {
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
