import Foundation
import XCTest
@testable import SwiftCloudDrive

final class DirectoryObservationScopeTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/library/Books", isDirectory: true)

    func testNestedItemUsesTheConfiguredRoot() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertEqual(scope.relativePath(for: root.appendingPathComponent("作者/本.epub")), "作者/本.epub")
    }

    func testSiblingWithTheSameStringPrefixIsOutsideTheScope() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertNil(scope.relativePath(for: URL(fileURLWithPath: "/library/BooksOld/private.epub")))
        XCTAssertNil(scope.relativePath(for: URL(fileURLWithPath: "/library/Book/private.epub")))
        XCTAssertNil(scope.relativePath(for: URL(fileURLWithPath: "/elsewhere/Books/book.epub")))
    }

    func testWholeRootNotificationHasAnEmptyRelativePath() {
        XCTAssertEqual(DirectoryObservationScope(rootDirectory: root).relativePath(for: root), "")
    }

    func testPrefixIncludesASeparator() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertEqual(scope.descendantPathPrefix, "/library/Books/")
        XCTAssertFalse("/library/BooksOld/book.epub".hasPrefix(scope.descendantPathPrefix))
        XCTAssertTrue("/library/Books/book.epub".hasPrefix(scope.descendantPathPrefix))
    }

    func testFilesystemRootHasOneSeparator() {
        let scope = DirectoryObservationScope(rootDirectory: URL(fileURLWithPath: "/", isDirectory: true))
        XCTAssertEqual(scope.descendantPathPrefix, "/")
        XCTAssertEqual(scope.relativePath(for: URL(fileURLWithPath: "/Books/book.epub")), "Books/book.epub")
    }

    func testDotSegmentsCannotTurnAnOutsideNotificationIntoAChild() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertNil(scope.relativePath(for: URL(fileURLWithPath: "/library/Books/../Other/book.epub")))
        XCTAssertEqual(scope.relativePath(for: URL(fileURLWithPath: "/library/Books/sub/../book.epub")), "book.epub")
    }

    func testNonFileURLsAreNotFilesystemNotifications() throws {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertNil(scope.relativePath(for: try XCTUnwrap(URL(string: "https://example.com/library/Books/a.epub"))))
    }

    func testMissingMovedOrDeletedPathsRemainMappable() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        XCTAssertEqual(scope.relativePath(for: root.appendingPathComponent("not-on-disk.epub")), "not-on-disk.epub")
    }

    func testEscapedFilenameCharactersRemainFilenameCharacters() {
        let scope = DirectoryObservationScope(rootDirectory: root)
        let name = "夏 #1 100%.epub"
        XCTAssertEqual(scope.relativePath(for: root.appendingPathComponent(name)), name)
    }

    func testSystemOrUserParentAliasMapsToTheSameRoot() throws {
        let temporary = try makeTemporaryRoot()
        let actual = temporary.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = temporary.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let scope = DirectoryObservationScope(rootDirectory: alias)
        XCTAssertEqual(scope.relativePath(for: actual.appendingPathComponent("book.epub")), "book.epub")
    }

    func testInRootSymlinkNotificationNamesTheLinkNotItsTarget() throws {
        let temporary = try makeTemporaryRoot()
        let directory = temporary.appendingPathComponent("books", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = temporary.appendingPathComponent("outside.epub")
        try Data("outside".utf8).write(to: outside)
        let link = directory.appendingPathComponent("link.epub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let scope = DirectoryObservationScope(rootDirectory: directory)
        XCTAssertEqual(scope.relativePath(for: link), "link.epub")
        XCTAssertNil(scope.relativePath(for: outside))
    }

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
