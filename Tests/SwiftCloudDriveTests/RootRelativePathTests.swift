import Foundation
import XCTest
@testable import SwiftCloudDrive

final class RootRelativePathTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-relative-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testRootAndOrdinaryNestedPathsStayInsideRoot() throws {
        let root = try fixture()
        XCTAssertEqual(try RootRelativePath.root.fileURL(forRoot: root), root)

        let path = RootRelativePath(path: "Books/Japanese/book.epub")
        let resolved = try path.fileURL(forRoot: root)
        XCTAssertEqual(
            resolved.standardizedFileURL,
            root.appendingPathComponent("Books/Japanese/book.epub").standardizedFileURL
        )
    }

    func testParentComponentsAreRejectedBeforeFilesystemAccess() throws {
        let root = try fixture()
        for path in [
            "../outside",
            "Books/../../outside",
            "Books/../outside",
            "./Books/book.epub",
        ] {
            XCTAssertThrowsError(
                try RootRelativePath(path: path).fileURL(forRoot: root),
                path
            ) { error in
                guard case RootRelativePathError.invalidRelativePath = error else {
                    return XCTFail("Unexpected error for \(path): \(error)")
                }
            }
        }
    }

    func testAbsoluteAndNulPathsAreRejected() throws {
        let root = try fixture()
        XCTAssertThrowsError(
            try RootRelativePath(path: "/outside").fileURL(forRoot: root)
        )
        XCTAssertThrowsError(
            try RootRelativePath(path: "Books/\u{0}book.epub").fileURL(forRoot: root)
        )
    }

    func testExistingSymlinkAncestorCannotEscapeRoot() throws {
        let root = try fixture()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }

        let link = root.appendingPathComponent("Books")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(
            try RootRelativePath(path: "Books/book.epub").fileURL(forRoot: root)
        ) { error in
            guard case RootRelativePathError.escapesRoot = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent("book.epub").path
            )
        )
    }

    func testDanglingSymlinkAncestorIsRejected() throws {
        let root = try fixture()
        let link = root.appendingPathComponent("Books")
        let missingTarget = root.deletingLastPathComponent()
            .appendingPathComponent("missing-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: missingTarget
        )

        XCTAssertThrowsError(
            try RootRelativePath(path: "Books/book.epub").fileURL(forRoot: root)
        ) { error in
            guard case RootRelativePathError.unresolvedSymlink = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
    }

    func testSymlinkAncestorResolvingInsideRootRemainsUsable() throws {
        let root = try fixture()
        let real = root.appendingPathComponent("RealBooks", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("Books")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let result = try RootRelativePath(path: "Books/book.epub").fileURL(forRoot: root)
        XCTAssertEqual(result, link.appendingPathComponent("book.epub"))
    }

    func testAppendingCannotSmuggleParentTraversalPastResolution() throws {
        let root = try fixture()
        let path = RootRelativePath(path: "Books").appending("../outside")
        XCTAssertThrowsError(try path.directoryURL(forRoot: root))
    }
}
