import Foundation

/// Executes one synchronous coordinator accessor with balanced resource access.
/// Native coordination is supplied by CoordinatedFileManager, not simulated here.
/// Once an accessor commits, cancellation must not turn its success into failure.
enum CoordinatedAccess {
    static func perform<Input, Output>(
        resources: [URL],
        startAccess: (URL) -> Bool,
        stopAccess: (URL) -> Void,
        coordinate: (_ accessor: @escaping (Input) -> Void) -> NSError?,
        operation: @escaping (Input) throws -> Output
    ) throws -> Output {
        try Task.checkCancellation()
        // Start on the original URLs: a coordinator may supply a relocated URL
        // which does not carry the caller's security-scoped bookmark information.
        let accessed = resources.filter(startAccess)
        defer { accessed.reversed().forEach(stopAccess) }

        var result: Result<Output, Swift.Error>?
        let coordinatorError = coordinate { input in
            guard result == nil else { return }
            result = Result {
                // Cancellation can arrive while another presenter holds access.
                try Task.checkCancellation()
                return try operation(input)
            }
        }
        // The accessor is synchronous. Resolve once, after native coordination
        // has returned, rather than resuming a continuation from two paths.
        if let result { return try result.get() }
        if let coordinatorError { throw coordinatorError }
        throw CocoaError(.fileReadUnknown)
    }
}

// Synchronous native-test observation after removal commits. No observer is
// installed in ordinary use; it cannot move admission into another task.
enum CoordinatedRemovalObservation {
    @TaskLocal static var didRemove: (@Sendable () -> Void)?
}
