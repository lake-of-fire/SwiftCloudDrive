import Foundation
import XCTest
@testable import SwiftCloudDrive

final class CoordinatedAccessTests: XCTestCase, @unchecked Sendable {
    private enum Failure: Swift.Error, Equatable { case operation }
    private let source = URL(fileURLWithPath: "/source/book.epub")
    private let destination = URL(fileURLWithPath: "/library/book.epub")

    func testScopesCoverCoordinationAndAccessorThenReleaseInReverseOrder() throws {
        var events: [String] = []
        let value: Int = try CoordinatedAccess.perform(
            resources: [source, destination],
            startAccess: { events.append("start:\($0.path)"); return true },
            stopAccess: { events.append("stop:\($0.path)") },
            coordinate: { accessor in
                events.append("coordinate")
                accessor(7)
                events.append("returned")
                return nil
            },
            operation: { events.append("accessor"); return $0 * 2 }
        )
        XCTAssertEqual(value, 14)
        XCTAssertEqual(events, ["start:/source/book.epub", "start:/library/book.epub",
                                "coordinate", "accessor", "returned",
                                "stop:/library/book.epub", "stop:/source/book.epub"])
    }

    func testOrdinarySandboxURLsDoNotNeedSuccessfulScopeAcquisition() throws {
        var stopped: [URL] = []
        let result: String = try CoordinatedAccess.perform(
            resources: [source, destination], startAccess: { $0 == self.source },
            stopAccess: { stopped.append($0) },
            coordinate: { $0("ok"); return nil }, operation: { $0 }
        )
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(stopped, [source])
    }

    func testOriginalScopedURLsAreNotReplacedByRelocatedAccessorURLs() throws {
        let relocated = URL(fileURLWithPath: "/new-location/book.epub")
        var started: [URL] = []
        var stopped: [URL] = []
        let received: URL = try CoordinatedAccess.perform(
            resources: [source], startAccess: { started.append($0); return true },
            stopAccess: { stopped.append($0) },
            coordinate: { $0(relocated); return nil }, operation: { $0 }
        )
        XCTAssertEqual(received, relocated)
        XCTAssertEqual(started, [source])
        XCTAssertEqual(stopped, [source])
    }

    func testCoordinationFailureReleasesScopesWithoutRunningOperation() {
        let expected = NSError(domain: "coordination-test", code: 12)
        var stopped: [URL] = []
        var executed = false
        XCTAssertThrowsError(try CoordinatedAccess.perform(
            resources: [source, destination], startAccess: { _ in true },
            stopAccess: { stopped.append($0) },
            coordinate: { (_: (Int) -> Void) in expected },
            operation: { _ in executed = true }
        )) { XCTAssertEqual($0 as NSError, expected) }
        XCTAssertFalse(executed)
        XCTAssertEqual(stopped, [destination, source])
    }

    func testOperationFailureReleasesScopesAndPreservesItsError() {
        var stopped: [URL] = []
        XCTAssertThrowsError(try CoordinatedAccess.perform(
            resources: [source, destination], startAccess: { _ in true },
            stopAccess: { stopped.append($0) },
            coordinate: { $0(7); return nil },
            operation: { _ -> Void in throw Failure.operation }
        )) { XCTAssertEqual($0 as? Failure, .operation) }
        XCTAssertEqual(stopped, [destination, source])
    }

    func testVoidAndNilAreSuccessfulResultsNotMissingAccessorResults() throws {
        let _: Void = try CoordinatedAccess.perform(
            resources: [], startAccess: { _ in false }, stopAccess: { _ in },
            coordinate: { $0(()); return nil }, operation: { _ in }
        )
        let value: String? = try CoordinatedAccess.perform(
            resources: [], startAccess: { _ in false }, stopAccess: { _ in },
            coordinate: { $0(()); return nil }, operation: { _ in nil }
        )
        XCTAssertNil(value)
    }

    func testAbsentAccessorAndErrorFailsRatherThanLeavingAWaiterSuspended() {
        XCTAssertThrowsError(try CoordinatedAccess.perform(
            resources: [], startAccess: { _ in false }, stopAccess: { _ in },
            coordinate: { (_: (Int) -> Void) in nil }, operation: { $0 }
        )) { XCTAssertEqual(($0 as? CocoaError)?.code, .fileReadUnknown) }
    }

    func testASecondCallbackCannotRunTheMutationTwice() throws {
        var writes: [Int] = []
        let result = try CoordinatedAccess.perform(
            resources: [], startAccess: { _ in false }, stopAccess: { _ in },
            coordinate: { $0(1); $0(2); return nil },
            operation: { writes.append($0); return $0 }
        )
        XCTAssertEqual(result, 1)
        XCTAssertEqual(writes, [1])
    }

    func testAccessorFailureIsNotReplacedByALaterCoordinatorError() {
        XCTAssertThrowsError(try CoordinatedAccess.perform(
            resources: [], startAccess: { _ in false }, stopAccess: { _ in },
            coordinate: { $0(1); return NSError(domain: "later", code: 1) },
            operation: { _ -> Void in throw Failure.operation }
        )) { XCTAssertEqual($0 as? Failure, .operation) }
    }

    func testAlreadyCancelledTaskNeverAcquiresAccessOrCoordinates() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CoordinatedAccess.perform(
                resources: [source], startAccess: { _ in XCTFail("started access"); return true },
                stopAccess: { _ in XCTFail("stopped unacquired access") },
                coordinate: { (_: (Int) -> Void) in XCTFail("coordinated"); return nil },
                operation: { $0 }
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCancellationWhileWaitingForCoordinationDoesNotWriteFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { () throws -> Void in
            var stopped = false
            defer { XCTAssertTrue(stopped) }
            try CoordinatedAccess.perform(
                resources: [url], startAccess: { _ in true }, stopAccess: { _ in stopped = true },
                coordinate: { accessor in
                    withUnsafeCurrentTask { $0?.cancel() }
                    accessor(url)
                    return nil
                }, operation: { try Data("stale".utf8).write(to: $0) }
            )
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: url), Data("original".utf8))
    }

    func testCancellationAfterCommittedWriteDoesNotReportAnUnperformedMutation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            try CoordinatedAccess.perform(
                resources: [url], startAccess: { _ in false }, stopAccess: { _ in },
                coordinate: { $0(url); return nil },
                operation: { destination in
                    try Data("committed".utf8).write(to: destination)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "committed"
                }
            )
        }
        let result = try await task.value
        XCTAssertEqual(result, "committed")
        XCTAssertEqual(try Data(contentsOf: url), Data("committed".utf8))
    }
}
