import Foundation
import XCTest
@testable import SwiftCloudDrive

/// Uses real NSFileCoordinator and files; requires the Apple Foundation graph.
final class CoordinatedFileManagerBoundaryTests: XCTestCase, @unchecked Sendable {
    func testAlreadyCancelledWriteLeavesExistingFileUnchanged() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("book.txt")
        try Data("original".utf8).write(to: file)
        let manager = CoordinatedFileManager()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.write(Data("stale".utf8), coordinatingAccessTo: file)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), Data("original".utf8))
        // Cancellation belongs to the request, not to the actor or next caller.
        try await manager.write(Data("new".utf8), coordinatingAccessTo: file)
        let contents = try await manager.contentsOfFile(coordinatingAccessAt: file)
        XCTAssertEqual(contents, Data("new".utf8))
    }

    func testAlreadyCancelledDeletePreservesItsTarget() async throws {
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("book.txt")
        try Data("keep".utf8).write(to: file)
        let manager = CoordinatedFileManager()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.removeItem(coordinatingAccessAt: file)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testAlreadyCancelledCopyDoesNotInstallAPayload() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        try Data("payload".utf8).write(to: source)
        let manager = CoordinatedFileManager()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.copyItem(coordinatingAccessFrom: source, to: destination)
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSuccessfulCopyAndExistingDestinationFailureRemainDistinct() async throws {
        let root = try temporaryDirectory()
        let source = root.appendingPathComponent("source.txt")
        let destination = root.appendingPathComponent("copy.txt")
        let manager = CoordinatedFileManager()
        try Data("first".utf8).write(to: source)
        try await manager.copyItem(coordinatingAccessFrom: source, to: destination)
        try Data("second".utf8).write(to: source)
        do {
            try await manager.copyItem(coordinatingAccessFrom: source, to: destination)
            XCTFail("Must not overwrite an existing destination")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteFileExists.rawValue)
        }
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
    }

    func testAccessorErrorReleasesCoordinationForTheNextOperation() async throws {
        enum Expected: Swift.Error { case failed }
        let root = try temporaryDirectory()
        let file = root.appendingPathComponent("book.txt")
        try Data("old".utf8).write(to: file)
        let manager = CoordinatedFileManager()
        do {
            try await manager.updateFile(coordinatingAccessTo: file) { _ in throw Expected.failed }
            XCTFail("Expected accessor failure")
        } catch { XCTAssertTrue(error is Expected) }
        try await manager.write(Data("new".utf8), coordinatingAccessTo: file)
        XCTAssertEqual(try Data(contentsOf: file), Data("new".utf8))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
}
