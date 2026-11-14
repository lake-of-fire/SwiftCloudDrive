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
        try await perform { access in
            try access.read(at: fileURL) { [self] url in
                var isDir: ObjCBool = false
                let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDir)
                return (exists, isDir.boolValue)
            }
        }
    }

    public func createDirectory(coordinatingAccessAt dirURL: URL, withIntermediateDirectories: Bool) async throws {
        try await perform { access in
            try access.write(at: dirURL, options: .forMerging) { [self] url in
                try fileManager.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
            }
        }
    }

    public func removeItem(coordinatingAccessAt dirURL: URL) async throws {
        try await perform { access in
            try access.write(at: dirURL, options: .forDeleting) { [self] url in
                try fileManager.removeItem(at: url)
            }
        }
    }

    public func copyItem(coordinatingAccessFrom fromURL: URL, to toURL: URL) async throws {
        try await perform { access in
            try access.read(at: fromURL, writingAt: toURL, writeOptions: .forReplacing) { [self] read, write in
                try fileManager.copyItem(at: read, to: write)
            }
        }
    }

    public func contentsOfDirectory(coordinatingAccessAt dirURL: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions) async throws -> [URL] {
        try await perform { access in
            try access.read(at: dirURL) { [self] url in
                try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
            }
        }
    }

    public func contentsOfFile(coordinatingAccessAt url: URL) async throws -> Data {
        try await perform { access in
            try access.read(at: url) { try Data(contentsOf: $0) }
        }
    }

    public func write(_ data: Data, coordinatingAccessTo url: URL) async throws {
        try await perform { access in
            try access.write(at: url) { try data.write(to: $0) }
        }
    }

    public func updateFile(coordinatingAccessTo url: URL, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        try await perform { access in
            try access.write(at: url, block)
        }
    }

    public func readFile(coordinatingAccessTo url: URL, in block: @Sendable @escaping (URL) throws -> Void) async throws {
        try await perform { access in
            try access.read(at: url, block)
        }
    }

    private func perform<Value>(
        _ operation: (CoordinatedFileRequest.Access) throws -> Value
    ) async throws -> Value {
        let request = CoordinatedFileRequest(presenter: presenter)
        return try await withTaskCancellationHandler {
            try request.withExecution(operation)
        } onCancel: { request.cancel() }
    }
}
