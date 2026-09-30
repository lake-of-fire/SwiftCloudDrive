//
//  MetadataMonitor.swift
//
//  Created by Drew McCormack on 10/06/2022.
//

import Foundation
import os

/// Monitors metadata to download new files and updates below the selected root.
class MetadataMonitor {
    let rootDirectory: URL
    let fileManager: FileManager = .init()
    private let scope: DirectoryObservationScope
    private var metadataQuery: NSMetadataQuery?

    init(rootDirectory: URL) {
        let scope = DirectoryObservationScope(rootDirectory: rootDirectory)
        self.rootDirectory = scope.rootDirectory
        self.scope = scope
    }

    deinit {
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: metadataQuery)
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: metadataQuery)

        nonisolated(unsafe) let query = metadataQuery
        Task { @MainActor in
            guard let query else { return }
            query.disableUpdates()
            query.stop()
        }
    }

    static func downloadPredicate(rootDirectory: URL) -> NSPredicate {
        let scope = DirectoryObservationScope(rootDirectory: rootDirectory)
        // The separator matters: a root named Books must not download BooksOld.
        return NSPredicate(
            format: "%K = %@ AND %K = FALSE AND %K BEGINSWITH %@",
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemDownloadingStatusNotDownloaded,
            NSMetadataUbiquitousItemIsDownloadingKey,
            NSMetadataItemPathKey,
            scope.descendantPathPrefix
        )
    }

    func startMonitoringMetadata() async {
        guard metadataQuery == nil else { return }
        let query = NSMetadataQuery()
        query.notificationBatchingInterval = 3.0
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = Self.downloadPredicate(rootDirectory: rootDirectory)
        metadataQuery = query

        NotificationCenter.default.addObserver(self, selector: #selector(handleMetadataNotification(_:)), name: .NSMetadataQueryDidFinishGathering, object: query)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMetadataNotification(_:)), name: .NSMetadataQueryDidUpdate, object: query)

        // Finish starting before setup returns. An unstructured start could run
        // after teardown's stop and leave a query alive without its owner.
        nonisolated(unsafe) let queryToStart = query
        await MainActor.run { _ = queryToStart.start() }
    }

    @objc private func handleMetadataNotification(_ notification: Notification) {
        guard let query = metadataQuery,
              let notificationQuery = notification.object as? NSMetadataQuery,
              notificationQuery === query else { return }
        for url in updatedURLs(in: query) {
            do {
                try fileManager.startDownloadingUbiquitousItem(at: url)
            } catch {
                os_log("Failed to start downloading file")
            }
        }
    }

    private func updatedURLs(in query: NSMetadataQuery) -> [URL] {
        query.disableUpdates()
        defer { query.enableUpdates() }
        return query.results.compactMap { result in
            guard let item = result as? NSMetadataItem,
                  let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL,
                  let path = scope.relativePath(for: url), !path.isEmpty else { return nil }
            return url
        }
    }
}
