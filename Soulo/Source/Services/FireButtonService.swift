import Foundation
import SwiftData
import WebKit

enum FireButtonService {
    @MainActor
    static func burn(tabManager: TabManager?, completion: @escaping () -> Void) {
        NotificationCenter.default.post(name: .cancelActiveDownloads, object: nil)
        DownloadManagerService.shared.cancelAllDownloads()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()

        tabManager?.resetTabsForPrivacy()
        WebViewModel.deleteAllPersistedSnapshots()
        AdBlockSettingsService.shared.resetStats()
        PrivacyProtectionService.shared.resetAllSummaries()

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }
}

enum BrowserCacheService {
    private static let websiteCacheDataTypes: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeServiceWorkerRegistrations
    ]

    /// Clears recreatable browser resources and Soulo's recent page visits while
    /// deliberately preserving cookies, local storage, bookmarks, search terms,
    /// and downloads.
    @MainActor
    static func clear(tabManager: TabManager?, historyContext: ModelContext? = nil) async {
        URLCache.shared.removeAllCachedResponses()
        WebViewModel.deleteAllPersistedSnapshots()
        tabManager?.tabs.forEach { $0.webViewModel.snapshot = nil }
        if let historyContext {
            SearchHistoryService.clearBrowsingHistory(context: historyContext)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(
                ofTypes: websiteCacheDataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }

    /// Returns an estimate of the recreatable browser data cleared by
    /// `clear(tabManager:historyContext:)`. WebKit does not expose byte counts for its data
    /// records, so cache-only WebKit folders are measured on disk without
    /// including cookies, local storage, downloads, or wallpaper files.
    static func currentSizeInBytes() async -> Int64 {
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            var total = Int64(URLCache.shared.currentDiskUsage)
                + Int64(URLCache.shared.currentMemoryUsage)

            if let cachesDirectory = fileManager.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first {
                total += allocatedSize(
                    at: cachesDirectory.appendingPathComponent(
                        "SouloTabSnapshots",
                        isDirectory: true
                    )
                )

                let children = (try? fileManager.contentsOfDirectory(
                    at: cachesDirectory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                for child in children where child.lastPathComponent
                    .localizedCaseInsensitiveContains("webkit") {
                    total += allocatedSize(at: child)
                }
            }

            if let libraryDirectory = fileManager.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first {
                total += allocatedSize(
                    at: libraryDirectory.appendingPathComponent("WebKit", isDirectory: true),
                    cacheFilesOnly: true
                )
            }

            return max(total, 0)
        }.value
    }

    static func formattedSize(_ byteCount: Int64) -> String {
        guard byteCount >= 1_024 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: byteCount)
    }

    private static func allocatedSize(
        at root: URL,
        cacheFilesOnly: Bool = false
    ) -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .fileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }

            if cacheFilesOnly {
                let relativePath = String(fileURL.path.dropFirst(root.path.count)).lowercased()
                guard relativePath.contains("cache")
                    || relativePath.contains("serviceworker") else { continue }
            }

            let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(max(size, 0))
        }
        return total
    }
}
