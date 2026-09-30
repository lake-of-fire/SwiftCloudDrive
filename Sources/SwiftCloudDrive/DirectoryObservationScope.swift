import Foundation

/// Maps notification URLs, not read/write authority. Names outside the selected
/// directory must not become relative paths just because their strings overlap.
struct DirectoryObservationScope: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.absoluteURL.standardizedFileURL
    }

    var descendantPathPrefix: String {
        let path = rootDirectory.path
        return path.hasSuffix("/") ? path : path + "/"
    }

    func relativePath(for url: URL) -> String? {
        guard rootDirectory.isFileURL, url.isFileURL else { return nil }
        let item = url.absoluteURL.standardizedFileURL
        // Prefer the reported spelling. This preserves an in-root symlink's
        // own name and still works after the item was moved or removed.
        if let path = Self.relativePath(item, within: rootDirectory) { return path }
        // File presenters can report a system alias (/var vs /private/var).
        return Self.relativePath(
            item.resolvingSymlinksInPath(),
            within: rootDirectory.resolvingSymlinksInPath()
        )
    }

    private static func relativePath(_ item: URL, within root: URL) -> String? {
        let base = root.pathComponents
        let components = item.pathComponents
        guard components.count >= base.count,
              components.starts(with: base) else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }
}
