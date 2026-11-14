//
//  File.swift
//
//  Created by Drew McCormack on 17/04/2024.
//

import Foundation
import os

/// Registration belongs to CloudDrive, not to the presenter. Foundation retains
/// registered presenters, so a presenter's own deinit cannot unregister itself.
final class FileMonitorRegistration {
    private let presenter: FileMonitor

    init(_ presenter: FileMonitor) {
        self.presenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    deinit {
        NSFileCoordinator.removeFilePresenter(presenter)
    }
}

/// Monitors changes to files using file presenter, including remote changes.
class FileMonitor: NSObject, NSFilePresenter, @unchecked Sendable {
    let rootDirectory: URL
    private let scope: DirectoryObservationScope
    var presentedItemURL: URL? { rootDirectory }

    /// Called when any file changes, is added, or removed.
    var changeHandler: (([RootRelativePath]) -> Void)?

    /// Returns true if resolved; otherwise the default resolution is applied.
    var conflictHandler: ((RootRelativePath) -> Bool)?

    lazy var presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(rootDirectory: URL) {
        let scope = DirectoryObservationScope(rootDirectory: rootDirectory)
        self.scope = scope
        self.rootDirectory = scope.rootDirectory
    }

    /// The owner must retain the returned registration for its monitoring lifetime.
    func startMonitoring() -> FileMonitorRegistration {
        FileMonitorRegistration(self)
    }

    func presentedSubitemDidAppear(at url: URL) {
        informOfChanges(at: [url])
    }

    func presentedSubitemDidChange(at url: URL) {
        informOfChanges(at: [url])
    }

    func presentedItemDidChange() {
        informOfChanges(at: [rootDirectory])
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        // A move within the scope invalidates both names. A move across its
        // boundary reports only the side that belongs to this drive.
        informOfChanges(at: [oldURL, newURL])
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        presentedItemDidGain(at: version.url, isConflict: version.isConflict)
    }

    /// A version change remains an invalidation even when cleanup is deferred
    /// by execution admission. Consumers must still observe the changed item.
    func presentedItemDidGain(at url: URL, isConflict: Bool) {
        defer { informOfChanges(at: [url]) }
        do {
            if isConflict {
                try resolveConflicts(for: url)
            }
        } catch {
            os_log("Failed to handle cloud metadata")
        }
    }

    private func informOfChanges(at urls: [URL]) {
        var seen = Set<String>()
        let paths = urls.compactMap { url -> RootRelativePath? in
            guard let path = scope.relativePath(for: url),
                  seen.insert(path).inserted else { return nil }
            return RootRelativePath(path: path)
        }
        guard !paths.isEmpty else { return }
        changeHandler?(paths)
    }

    func resolveConflicts(for url: URL) throws {
        guard let path = scope.relativePath(for: url) else { return }
        let resolved = conflictHandler?(RootRelativePath(path: path)) ?? false
        guard !resolved else { return }

        let request = CoordinatedFileRequest(presenter: self)
        try request.withExecution { access in
            try access.write(at: url, options: .forDeleting) {
                try NSFileVersion.removeOtherVersionsOfItem(at: $0)
            }

            try access.checkCancellation()
            let conflictVersions = NSFileVersion.unresolvedConflictVersionsOfItem(at: url)
            for version in conflictVersions ?? [] {
                try access.checkCancellation()
                version.isResolved = true
            }
        }
    }
}
