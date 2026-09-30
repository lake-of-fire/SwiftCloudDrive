//
//  RootRelativePath.swift
//
//  Created by Drew McCormack on 25/06/2022.
//

import Foundation

public enum RootRelativePathError: LocalizedError, Sendable {
    case invalidRelativePath(String)
    case escapesRoot(URL)
    case unresolvedSymlink(URL)

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "Invalid root-relative path: \(path)"
        case .escapesRoot(let url):
            return "Root-relative path escapes the configured drive root: \(url.path)"
        case .unresolvedSymlink(let url):
            return "Root-relative path crosses a symlink whose target cannot be verified: \(url.path)"
        }
    }
}

/// Used as a relative path to the files and directories
/// in the container. Can also be seen as an identifier
/// of files and directories.
public struct RootRelativePath: Hashable, Sendable {

    public var path: String

    public init(path: String) {
        self.path = path
    }

    public func fileURL(forRoot rootDirURL: URL) throws -> URL {
        try resolvedURL(forRoot: rootDirURL, isDirectory: false)
    }

    public func directoryURL(forRoot rootDirURL: URL) throws -> URL {
        try resolvedURL(forRoot: rootDirURL, isDirectory: true)
    }

    public func appending(_ addition: String) -> RootRelativePath {
        .init(path: (path as NSString).appendingPathComponent(addition))
    }

    /// The root of the container.
    public static let root: Self = Self(path: "")

    private func resolvedURL(forRoot rootDirURL: URL, isDirectory: Bool) throws -> URL {
        guard rootDirURL.isFileURL, rootDirURL.hasDirectoryPath else {
            throw Error.rootDirectoryURLIsNotDirectory
        }
        try validateRelativeSyntax()

        let requested = path.isEmpty
            ? rootDirURL
            : rootDirURL.appendingPathComponent(path, isDirectory: isDirectory)
        // Resolve both sides by the same rule. The configured root may not
        // exist yet; resolvingSymlinksInPath alone then leaves a trusted parent
        // alias unresolved and falsely reports its descendants as escaping.
        let resolvedRoot = try Self.resolvingExistingAncestor(of: rootDirURL)
        let resolvedRequested = try Self.resolvingExistingAncestor(of: requested)
        guard Self.contains(resolvedRequested, in: resolvedRoot) else {
            throw RootRelativePathError.escapesRoot(resolvedRequested)
        }
        return requested
    }

    private func validateRelativeSyntax() throws {
        guard !path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RootRelativePathError.invalidRelativePath(path)
        }
        for component in path.split(separator: "/", omittingEmptySubsequences: true)
            where component == "." || component == ".." {
            throw RootRelativePathError.invalidRelativePath(path)
        }
    }

    private static func resolvingExistingAncestor(of requestedURL: URL) throws -> URL {
        let fileManager = FileManager.default
        var cursor = requestedURL.standardizedFileURL
        var missingComponents: [String] = []

        while !fileManager.fileExists(atPath: cursor.path) {
            // fileExists follows symlinks, so a dangling link looks missing.
            // Do not authorize descendants through a target we cannot resolve.
            if (try? fileManager.destinationOfSymbolicLink(atPath: cursor.path)) != nil {
                throw RootRelativePathError.unresolvedSymlink(cursor)
            }
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { break }
            missingComponents.append(cursor.lastPathComponent)
            cursor = parent
        }

        var resolved = cursor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = candidate.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}
