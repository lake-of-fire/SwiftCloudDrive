//
//  FileManager+Coordination.swift
//
//  Created by Drew McCormack on 08/06/2022.
//

import Foundation

/// Async entry points isolated to one actor. Native file coordination is
/// synchronous and serial within this manager; use separate managers when
/// independent operations should be able to coordinate concurrently.
public actor CoordinatedFileManager {
    private(set) var presenter: (any NSFilePresenter)?
    private let fileManager = FileManager()

    public init(presenter: (any NSFilePresenter)? = nil) {
        self.presenter = presenter
    }

    public func fileExists(coordinatingAccessAt fileURL: URL) async throws -> (exists: Bool, isDirectory: Bool) {
        try await coordinate(readingItemAt: fileURL) { [self] url in
            var isDir: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
            return (exists, isDir.boolValue)
        }
    }

    public func createDirectory(coordinatingAccessAt dirURL: URL, withIntermediateDirectories: Bool) async throws {
        try await coordinate(writingItemAt: dirURL, options: .forMerging) { [self] url in
            try fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
        }
    }

    public func removeItem(coordinatingAccessAt dirURL: URL) async throws {
        try await coordinate(writingItemAt: dirURL, options: .forDeleting) { [self] url in
            try fileManager.removeItem(at: url)
        }
    }

    public func copyItem(coordinatingAccessFrom fromURL: URL, to toURL: URL) async throws {
        try await coordinate(readingItemAt: fromURL, writingItemAt: toURL, writeOptions: .forReplacing) { [self] read, write in
            try fileManager.copyItem(at: read, to: write)
        }
    }

    public func contentsOfDirectory(coordinatingAccessAt dirURL: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) async throws -> [URL] {
        try await coordinate(readingItemAt: dirURL) { [self] url in
            try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
        }
    }

    public func contentsOfFile(coordinatingAccessAt url: URL) async throws -> Data {
        try await coordinate(readingItemAt: url) { try Data(contentsOf: $0) }
    }

    public func write(_ data: Data, coordinatingAccessTo url: URL) async throws {
        try await coordinate(writingItemAt: url) { try data.write(to: $0) }
    }

    public func updateFile(coordinatingAccessTo url: URL, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        try await coordinate(writingItemAt: url, with: block)
    }

    public func readFile(coordinatingAccessTo url: URL, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        try await coordinate(readingItemAt: url, with: block)
    }

    private func coordinate<T>(
        readingItemAt url: URL,
        options: NSFileCoordinator.ReadingOptions = [],
        with block: @escaping (URL) throws -> T
    ) async throws -> T {
        let request = CoordinatedFileRequest(presenter: presenter)
        return try await withTaskCancellationHandler {
            try request.withExecution { checkCancellation in
                try CoordinatedAccess.perform(
                    resources: [url],
                    startAccess: { $0.startAccessingSecurityScopedResource() },
                    stopAccess: { $0.stopAccessingSecurityScopedResource() },
                    coordinate: { accessor in
                        var error: NSError?
                        request.coordinator.coordinate(
                            readingItemAt: url, options: options, error: &error,
                            byAccessor: accessor
                        )
                        return error
                    },
                    checkCancellation: checkCancellation,
                    operation: block
                )
            }
        } onCancel: { request.cancel() }
    }

    private func coordinate<T>(
        writingItemAt url: URL,
        options: NSFileCoordinator.WritingOptions = [],
        with block: @escaping (URL) throws -> T
    ) async throws -> T {
        let request = CoordinatedFileRequest(presenter: presenter)
        return try await withTaskCancellationHandler {
            try request.withExecution { checkCancellation in
                try CoordinatedAccess.perform(
                    resources: [url],
                    startAccess: { $0.startAccessingSecurityScopedResource() },
                    stopAccess: { $0.stopAccessingSecurityScopedResource() },
                    coordinate: { accessor in
                        var error: NSError?
                        request.coordinator.coordinate(
                            writingItemAt: url, options: options, error: &error,
                            byAccessor: accessor
                        )
                        return error
                    },
                    checkCancellation: checkCancellation,
                    operation: block
                )
            }
        } onCancel: { request.cancel() }
    }

    private func coordinate<T>(
        readingItemAt readURL: URL,
        writingItemAt writeURL: URL,
        writeOptions: NSFileCoordinator.WritingOptions = [],
        with block: @escaping (URL, URL) throws -> T
    ) async throws -> T {
        let request = CoordinatedFileRequest(presenter: presenter)
        return try await withTaskCancellationHandler {
            try request.withExecution { checkCancellation in
                try CoordinatedAccess.perform(
                    resources: [readURL, writeURL],
                    startAccess: { $0.startAccessingSecurityScopedResource() },
                    stopAccess: { $0.stopAccessingSecurityScopedResource() },
                    coordinate: { accessor in
                        var error: NSError?
                        request.coordinator.coordinate(
                            readingItemAt: readURL, options: [],
                            writingItemAt: writeURL, options: writeOptions, error: &error
                        ) { read, write in accessor((read, write)) }
                        return error
                    },
                    checkCancellation: checkCancellation,
                    operation: { try block($0.0, $0.1) }
                )
            }
        } onCancel: { request.cancel() }
    }
}
