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
            try RootRelativePath(path: "Books/book.epub").fileURL(forRoot: root),
            "External descendant was accepted"
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

    func testMissingRootBelowTrustedAliasRemainsUsableBeforeCreation() throws {
        let fixture = try fixture()
        let physical = fixture.appendingPathComponent("physical", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        let root = alias.appendingPathComponent("new-library", isDirectory: true)

        let file = try RootRelativePath(path: "日本語/book.epub").fileURL(forRoot: root)
        XCTAssertEqual(file, root.appendingPathComponent("日本語/book.epub"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("book".utf8).write(to: file)
        XCTAssertEqual(try Data(contentsOf: physical.appendingPathComponent("new-library/日本語/book.epub")), Data("book".utf8))
    }

    func testEmptyRelativePathAcceptsMissingRootBelowAlias() throws {
        let fixture = try fixture()
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture)
        let root = alias.appendingPathComponent("new/nested/library", isDirectory: true)
        XCTAssertEqual(try RootRelativePath.root.directoryURL(forRoot: root), root)
        XCTAssertEqual(try RootRelativePath.root.fileURL(forRoot: root), root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMissingDirectoryBelowAliasRootCanBeCreated() throws {
        let fixture = try fixture()
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture)
        let root = alias.appendingPathComponent("new-library", isDirectory: true)
        let result = try RootRelativePath(path: "Books").directoryURL(forRoot: root)
        XCTAssertTrue(result.hasDirectoryPath)
        XCTAssertEqual(result, root.appendingPathComponent("Books", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExistingAliasRootDoesNotAuthorizeExternalDescendant() throws {
        let fixture = try fixture()
        let physical = fixture.appendingPathComponent("physical", isDirectory: true)
        let outside = fixture.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical)
        try FileManager.default.createSymbolicLink(at: physical.appendingPathComponent("escape"), withDestinationURL: outside)
        for path in ["escape", "escape/new", "escape/new/book.epub"] {
            XCTAssertThrowsError(try RootRelativePath(path: path).fileURL(forRoot: alias))
            XCTAssertThrowsError(try RootRelativePath(path: path).directoryURL(forRoot: alias))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testMissingRootThroughDanglingAliasIsRejected() throws {
        let fixture = try fixture()
        let missing = fixture.appendingPathComponent("missing", isDirectory: true)
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: missing)
        let root = alias.appendingPathComponent("library", isDirectory: true)
        XCTAssertThrowsError(try RootRelativePath.root.directoryURL(forRoot: root))
        XCTAssertThrowsError(try RootRelativePath(path: "book.epub").fileURL(forRoot: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testSymbolicLinkCycleIsRejectedWithoutCreatingAnything() throws {
        let root = try fixture()
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)
        XCTAssertThrowsError(try RootRelativePath(path: "first/new/book.epub").fileURL(forRoot: root))
        XCTAssertThrowsError(try RootRelativePath(path: "second/new").directoryURL(forRoot: root))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: first.path), second.path)
    }

    func testMissingRootDoesNotWeakenSyntacticTraversalRejection() throws {
        let fixture = try fixture()
        let alias = fixture.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture)
        let root = alias.appendingPathComponent("new-library", isDirectory: true)
        for path in ["../outside", "Books/../outside", "/outside", "Books/\u{0}outside"] {
            XCTAssertThrowsError(try RootRelativePath(path: path).directoryURL(forRoot: root))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testLiteralURLDelimiterCharactersRemainFilenameData() throws {
        let root = try fixture()
        let path = "Books/日本語 #?%2F.epub"
        let result = try RootRelativePath(path: path).fileURL(forRoot: root)
        XCTAssertEqual(result.lastPathComponent, "日本語 #?%2F.epub")
        XCTAssertNil(result.query)
        XCTAssertNil(result.fragment)
    }
}
