import Foundation

/// Host execution belongs to one native coordination scope, through accessor
/// and security-scoped resource cleanup. Expiration requests interruption; it
/// must not release the assertion while a native accessor still holds access.
public struct CoordinatedFileExecutionLease: Sendable {
    public let checkpoint: @Sendable () throws -> Void
    public let installInterruptionHandler: @Sendable (@escaping @Sendable () -> Void) -> Void
    public let release: @Sendable () -> Void

    public init(
        checkpoint: @escaping @Sendable () throws -> Void,
        installInterruptionHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void,
        release: @escaping @Sendable () -> Void
    ) {
        self.checkpoint = checkpoint
        self.installInterruptionHandler = installInterruptionHandler
        self.release = release
    }
}

public enum CoordinatedFileExecutionProtection {
    public typealias Acquisition = @Sendable () throws -> CoordinatedFileExecutionLease?
    @TaskLocal public static var synchronousAcquisition: Acquisition?

    private final class Policy: @unchecked Sendable {
        let lock = NSLock()
        var acquisition: Acquisition?
    }
    private static let policy = Policy()

    /// Install before constructing drives or starting workers. Acquisition is
    /// synchronous because file-presenter callbacks also enter native access.
    public static func installDefaultAcquisition(_ acquisition: @escaping Acquisition) {
        policy.lock.withLock { policy.acquisition = acquisition }
    }

    static func acquire() throws -> CoordinatedFileExecutionLease? {
        let acquisition = synchronousAcquisition ?? policy.lock.withLock { policy.acquisition }
        return try acquisition?()
    }
}

/// NSFileCoordinator permits cancellation from another thread. Accessor state
/// stays on its calling thread; this carrier transfers only the cancel handle.
final class CoordinatedFileRequest: @unchecked Sendable {
    private let coordinator: NSFileCoordinator

    init(presenter: (any NSFilePresenter)?) {
        coordinator = NSFileCoordinator(filePresenter: presenter)
    }

    func cancel() { coordinator.cancel() }

    /// Execution may also cover metadata work after a native accessor returns.
    /// Keep the access value within this synchronous callback.
    func withExecution<Value>(
        _ operation: (Access) throws -> Value
    ) throws -> Value {
        try Task.checkCancellation()
        let execution = try CoordinatedFileExecutionProtection.acquire()
        defer { execution?.release() }
        execution?.installInterruptionHandler { [self] in cancel() }
        let checkCancellation: () throws -> Void = {
            try Task.checkCancellation()
            try execution?.checkpoint()
        }
        try checkCancellation()
        return try operation(Access(coordinator: coordinator, checkCancellation: checkCancellation))
    }

    /// Confined to the synchronous execution scope. Native access and resource
    /// cleanup share one implementation across actor and presenter callers.
    struct Access {
        private let coordinator: NSFileCoordinator
        let checkCancellation: () throws -> Void

        fileprivate init(coordinator: NSFileCoordinator, checkCancellation: @escaping () throws -> Void) {
            self.coordinator = coordinator
            self.checkCancellation = checkCancellation
        }

        func read<Value>(
            at url: URL,
            options: NSFileCoordinator.ReadingOptions = [],
            _ operation: @escaping (URL) throws -> Value
        ) throws -> Value {
            try CoordinatedAccess.perform(
                resources: [url],
                coordinate: { accessor in
                    var error: NSError?
                    coordinator.coordinate(readingItemAt: url, options: options,
                                           error: &error, byAccessor: accessor)
                    return error
                },
                checkCancellation: checkCancellation,
                operation: operation
            )
        }

        func write<Value>(
            at url: URL,
            options: NSFileCoordinator.WritingOptions = [],
            _ operation: @escaping (URL) throws -> Value
        ) throws -> Value {
            try CoordinatedAccess.perform(
                resources: [url],
                coordinate: { accessor in
                    var error: NSError?
                    coordinator.coordinate(writingItemAt: url, options: options,
                                           error: &error, byAccessor: accessor)
                    return error
                },
                checkCancellation: checkCancellation,
                operation: operation
            )
        }

        func read<Value>(
            at readURL: URL,
            writingAt writeURL: URL,
            writeOptions: NSFileCoordinator.WritingOptions = [],
            _ operation: @escaping (URL, URL) throws -> Value
        ) throws -> Value {
            try CoordinatedAccess.perform(
                resources: [readURL, writeURL],
                coordinate: { accessor in
                    var error: NSError?
                    coordinator.coordinate(readingItemAt: readURL, options: [],
                                           writingItemAt: writeURL, options: writeOptions,
                                           error: &error) { accessor(($0, $1)) }
                    return error
                },
                checkCancellation: checkCancellation,
                operation: { try operation($0.0, $0.1) }
            )
        }
    }
}

/// Executes one synchronous coordinator accessor with balanced resource access.
/// Native coordination is supplied by CoordinatedFileManager, not simulated here.
/// Once an accessor commits, cancellation must not turn its success into failure.
enum CoordinatedAccess {
    static func perform<Input, Output>(
        resources: [URL],
        startAccess: (URL) -> Bool = { $0.startAccessingSecurityScopedResource() },
        stopAccess: (URL) -> Void = { $0.stopAccessingSecurityScopedResource() },
        coordinate: (_ accessor: @escaping (Input) -> Void) -> NSError?,
        checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() },
        operation: @escaping (Input) throws -> Output
    ) throws -> Output {
        try checkCancellation()
        // Start on the original URLs: a coordinator may supply a relocated URL
        // which does not carry the caller's security-scoped bookmark information.
        let accessed = resources.filter(startAccess)
        defer { accessed.reversed().forEach(stopAccess) }

        var result: Result<Output, Swift.Error>?
        let coordinatorError = coordinate { input in
            guard result == nil else { return }
            result = Result {
                // Cancellation can arrive while another presenter holds access.
                try checkCancellation()
                return try operation(input)
            }
        }
        // The accessor is synchronous. Resolve once, after native coordination
        // has returned, rather than resuming a continuation from two paths.
        if let result { return try result.get() }
        // Cancellation can prevent native coordination from calling the
        // accessor at all. Preserve that retryable outcome instead of exposing
        // a generic Foundation error to lifecycle/admission callers.
        try checkCancellation()
        if let coordinatorError { throw coordinatorError }
        throw CocoaError(.fileReadUnknown)
    }
}

// Synchronous native-test observation after removal commits. No observer is
// installed in ordinary use; it cannot move admission into another task.
#if DEBUG
enum CoordinatedRemovalObservation {
    @TaskLocal static var didRemove: (@Sendable () -> Void)?
}
#endif
