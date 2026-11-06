import Foundation
import WebKit

enum StorageUsageCategory: String, CaseIterable, Identifiable, Sendable {
    case webData, tabSnapshots, favicons, wallpapers, downloads, readingData, backups, filterRules
    var id: Self { self }
    var canClear: Bool { [.webData, .tabSnapshots, .favicons].contains(self) }
}

struct StorageUsageRecord: Identifiable, Sendable {
    var id: StorageUsageCategory { category }
    let category: StorageUsageCategory
    let bytes: Int64
    let isEstimated: Bool
    var canClear: Bool { category.canClear }
}

struct StorageUsageLocations: Sendable {
    let downloads: URL
    let applicationSupport: URL
    let caches: URL

    static var current: Self {
        let manager = FileManager.default
        return Self(downloads: manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads"),
                    applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    caches: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0])
    }
}

/// Usage is measured without following symlinks. User files, reading progress,
/// saved settings and subscription source rules are informational categories;
/// only explicitly named, regenerable cache categories have a clear action.
enum StorageUsageService {
    private static let websiteCacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations]

    @MainActor
    static func scan() async -> [StorageUsageRecord] {
        let locations = StorageUsageLocations.current
        let disk = await Task.detached(priority: .utility) { measureDiskUsage(locations: locations) }.value
        let faviconBytes = Int64(WebsiteFaviconService.responseCache.currentDiskUsage)
            + Int64(WebsiteFaviconService.responseCache.currentMemoryUsage)
        let allBrowserCaches = await BrowserCacheService.currentSizeInBytes()
        let snapshotBytes = disk.first(where: { $0.category == .tabSnapshots })?.bytes ?? 0
        return StorageUsageCategory.allCases.compactMap { category in
            if category == .webData {
                return StorageUsageRecord(category: category, bytes: max(0, allBrowserCaches - snapshotBytes - faviconBytes), isEstimated: true)
            }
            if category == .favicons { return StorageUsageRecord(category: category, bytes: max(0, faviconBytes), isEstimated: true) }
            return disk.first { $0.category == category }
        }
    }

    @MainActor
    static func clear(_ category: StorageUsageCategory, tabManager: TabManager? = nil) async throws {
        guard category.canClear else { throw CocoaError(.fileWriteNoPermission) }
        switch category {
        case .webData:
            URLCache.shared.removeAllCachedResponses()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().removeData(ofTypes: websiteCacheTypes, modifiedSince: .distantPast) { continuation.resume() }
            }
        case .tabSnapshots:
            tabManager?.tabs.forEach { $0.webViewModel.clearSnapshotCache() }
            await WebViewModel.deleteAllPersistedSnapshotsAndWait()
        case .favicons:
            WebsiteFaviconService.shared.clear()
        case .wallpapers, .downloads, .readingData, .backups, .filterRules:
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    /// Pure disk portion, also used with isolated temporary locations in tests.
    static func measureDiskUsage(locations: StorageUsageLocations) -> [StorageUsageRecord] {
        let paths: [(StorageUsageCategory, [URL])] = [
            (.tabSnapshots, [locations.applicationSupport.appendingPathComponent("SouloTabSnapshots"), locations.caches.appendingPathComponent("SouloTabSnapshots")]),
            (.wallpapers, [locations.applicationSupport.appendingPathComponent("WallpaperFavorites"), locations.caches.appendingPathComponent("wallpaper_hd")]),
            (.downloads, [locations.downloads]),
            (.readingData, [locations.applicationSupport.appendingPathComponent("BookLibrary.json"), locations.applicationSupport.appendingPathComponent("BookCovers"),
                            locations.applicationSupport.appendingPathComponent("ReadingList.json")]),
            (.backups, [locations.applicationSupport.appendingPathComponent("Soulo/SettingsBackups")]),
            (.filterRules, [locations.applicationSupport.appendingPathComponent("AdBlock"), locations.caches.appendingPathComponent("SouloAdBlockStartup")])
        ]
        return paths.map { category, urls in
            if category == .wallpapers {
                return StorageUsageRecord(category: category, bytes: favoriteWallpaperBytes(in: urls), isEstimated: false)
            }
            var visited = Set<String>()
            let bytes = urls.reduce(Int64(0)) { total, url in
                adding(total, allocatedBytes(at: url, includeHLSReferences: category == .downloads, visited: &visited))
            }
            return StorageUsageRecord(category: category, bytes: bytes, isEstimated: false)
        }
    }

    /// Only named disk caches are accepted. This does not remove the selected
    /// wallpaper, favorites, Downloads, book covers/index, backups, or rule data.
    static func clearDiskCache(_ category: StorageUsageCategory, locations: StorageUsageLocations) throws {
        let targets: [(URL, URL)]
        switch category {
        case .tabSnapshots:
            targets = [(locations.applicationSupport.appendingPathComponent("SouloTabSnapshots"), locations.applicationSupport),
                       (locations.caches.appendingPathComponent("SouloTabSnapshots"), locations.caches)]
        default:
            throw CocoaError(.fileWriteNoPermission)
        }
        let manager = FileManager.default
        for (target, root) in targets {
            guard let attributes = try? manager.attributesOfItem(atPath: target.path) else { continue }
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  target.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                    == root.standardizedFileURL.resolvingSymlinksInPath() else { throw ReadingToolError.unsafePath }
        }
        for (target, _) in targets where manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
    }

    private static func favoriteWallpaperBytes(in directories: [URL]) -> Int64 {
        var sizes: [String: Int64] = [:]
        for directory in directories {
            guard let info = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true,
                  let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            for file in children where !file.lastPathComponent.hasPrefix(".") {
                var visited = Set<String>()
                let bytes = allocatedBytes(at: file, includeHLSReferences: false, visited: &visited)
                // A migration may temporarily leave the same favorite in both
                // locations. Count its stored identity once during that window.
                sizes[file.lastPathComponent] = max(sizes[file.lastPathComponent] ?? 0, bytes)
            }
        }
        return sizes.values.reduce(Int64(0), adding)
    }

    private static func allocatedBytes(at root: URL, includeHLSReferences: Bool, visited: inout Set<String>) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard !Task.isCancelled,
              let info = try? root.resourceValues(forKeys: keys), info.isSymbolicLink != true else { return 0 }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard visited.insert(canonical).inserted else { return 0 }
        if info.isRegularFile == true {
            var size = Int64(max(0, info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0))
            if includeHLSReferences, (info.fileSize ?? 0) <= 1024 * 1024,
               root.pathExtension.lowercased() == OfflineHLSReference.fileExtension,
               let package = try? OfflineHLSReference.packageURL(for: root) {
                size = adding(size, allocatedBytes(at: package, includeHLSReferences: false, visited: &visited))
            }
            return size
        }
        guard info.isDirectory == true,
              let children = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for child in children {
            guard !Task.isCancelled else { return total }
            total = adding(total, allocatedBytes(at: child, includeHLSReferences: includeHLSReferences, visited: &visited))
        }
        return total
    }

    private static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int64.max : result.partialValue
    }
}
