import Foundation
import WebKit

enum StorageUsageCategory: String, CaseIterable, Identifiable, Sendable {
    case webData, tabSnapshots, favicons, wallpaperCache, otherCaches, temporaryFiles, ruleCache
    case wallpapers, downloads, downloadTasks, readingData, backups, filterRules, extensions, personalData, sharedData, otherData
    var id: Self { self }
    var canClear: Bool { [.webData, .tabSnapshots, .favicons, .wallpaperCache, .otherCaches, .temporaryFiles, .ruleCache, .downloadTasks].contains(self) }
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
    var documents: URL? = nil
    var library: URL? = nil
    var temporary: URL? = nil
    var sharedContainer: URL? = nil
    var appBundle: URL? = nil

    static var current: Self {
        let manager = FileManager.default
        return Self(downloads: manager.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads"),
                    applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                    caches: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
                    documents: manager.urls(for: .documentDirectory, in: .userDomainMask)[0],
                    library: manager.urls(for: .libraryDirectory, in: .userDomainMask)[0],
                    temporary: manager.temporaryDirectory,
                    sharedContainer: manager.containerURL(forSecurityApplicationGroupIdentifier: SouloSharedConstants.appGroupIdentifier),
                    appBundle: Bundle.main.bundleURL)
    }
}

/// Inventory covers app-container and shared files separately from the installed
/// bundle. Destructive saved-data actions stay in their existing owner pages;
/// regenerable cache categories have an explicit, confirmed cleanup action.
enum StorageUsageService {
    private static let sessionStartedAt = Date()
    static func prepareSession() { _ = sessionStartedAt }
    @MainActor static func inventory() async -> StorageUsageInventory {
        let locations = StorageUsageLocations.current
        let task = Task.detached(priority: .utility) { measureInventory(locations: locations) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    @MainActor static func scan() async -> [StorageUsageRecord] { await inventory().records }

    @MainActor
    static func clear(_ category: StorageUsageCategory, tabManager: TabManager? = nil) async throws {
        guard category.canClear else { throw CocoaError(.fileWriteNoPermission) }
        switch category {
        case .webData:
            URLCache.shared.removeAllCachedResponses()
            await WebsiteStorageService.clearBrowserCaches()
        case .tabSnapshots:
            tabManager?.tabs.forEach { $0.webViewModel.clearSnapshotCache() }
            await WebViewModel.deleteAllPersistedSnapshotsAndWait()
        case .favicons:
            WebsiteFaviconService.shared.clear()
        case .ruleCache:
            try await clearCompiledRuleCache(in: WKContentRuleListStore.default())
            let locations = StorageUsageLocations.current
            try await Task.detached(priority: .utility) { try clearAdditionalCache(.ruleCache, locations: locations, olderThan: .distantFuture) }.value
        case .downloadTasks:
            let retained = Set(DownloadManagerService.shared.downloads.map(\.id)).union(TorrentDownloadService.shared.jobs.map(\.id))
            let locations = StorageUsageLocations.current, cutoff = sessionStartedAt
            try await Task.detached(priority: .utility) { try clearUnusedDownloadData(locations: locations, retainedIDs: retained, olderThan: cutoff) }.value
        case .wallpaperCache, .otherCaches, .temporaryFiles:
            if category == .temporaryFiles,
               DownloadManagerService.shared.downloads.contains(where: { [.inProgress, .paused].contains($0.status) }) {
                throw WebExtensionTemporaryCacheError.inUse
            }
            if category == .wallpaperCache { WallpaperManager.shared.prepareForImageCacheCleanup() }
            if category == .otherCaches { URLCache.shared.removeAllCachedResponses() }
            let locations = StorageUsageLocations.current, cutoff = sessionStartedAt
            try await Task.detached(priority: .utility) { try clearAdditionalCache(category, locations: locations, olderThan: cutoff) }.value
        case .wallpapers, .downloads, .readingData, .backups, .filterRules,
             .extensions, .personalData, .sharedData, .otherData:
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @MainActor static func clearCompiledRuleCache(in store: WKContentRuleListStore) async throws {
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        for identifier in identifiers where identifier.hasPrefix("SouloAdBlock") {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.removeContentRuleList(forIdentifier: identifier) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
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

    fileprivate static func allocatedBytes(at root: URL, includeHLSReferences: Bool, visited: inout Set<String>) -> Int64 {
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

    fileprivate static func adding(_ left: Int64, _ right: Int64) -> Int64 {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int64.max : result.partialValue
    }
}

struct StorageDiskEntry: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let displayPath: String
    let category: StorageUsageCategory
    var bytes: Int64
}

struct StorageUsageInventory: Sendable {
    var records: [StorageUsageRecord]
    var entries: [StorageDiskEntry]
    var appBytes: Int64
    var dataBytes: Int64 { records.reduce(0) { StorageUsageService.adding($0, $1.bytes) } }
}

extension StorageUsageService {
    /// One background filesystem walk counts every regular file in the app's
    /// Documents, Library, temporary and shared containers, excluding links.
    /// Allocated size, not preallocated logical download length, is reported.
    static func measureInventory(locations: StorageUsageLocations) -> StorageUsageInventory {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        var visited = Set<String>(), totals: [StorageUsageCategory: Int64] = [:]
        var entries: [String: StorageDiskEntry] = [:]
        let roots = [locations.documents, locations.library, locations.temporary,
            locations.sharedContainer, locations.applicationSupport, locations.caches, locations.downloads].compactMap { $0 }
        func walk(_ url: URL, forced: StorageUsageCategory? = nil) {
            guard !Task.isCancelled,
                  let info = try? url.resourceValues(forKeys: keys), info.isSymbolicLink != true,
                  visited.insert(url.standardizedFileURL.path).inserted else { return }
            if info.isDirectory == true {
                for child in (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? [] { walk(child, forced: forced) }
            } else if info.isRegularFile == true {
                let category = forced ?? Self.category(for: url, locations: locations)
                let bytes = Int64(max(0, info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0))
                totals[category] = adding(totals[category] ?? 0, bytes)
                let (bucket, label) = Self.bucket(for: url, locations: locations)
                let key = category.rawValue + ":" + bucket.path
                if var old = entries[key] { old.bytes = adding(old.bytes, bytes); entries[key] = old }
                else { entries[key] = .init(url: bucket, displayPath: label, category: category, bytes: bytes) }
                // AVFoundation stores offline packages outside Downloads.
                // Resolve only validated Soulo references; the visited set also
                // prevents a second reference or a later root walk counting twice.
                if url.pathExtension.lowercased() == OfflineHLSReference.fileExtension,
                   (info.fileSize ?? Int.max) <= 1024 * 1024,
                   let package = try? OfflineHLSReference.packageURL(for: url) { walk(package, forced: .downloads) }
            }
        }
        for root in roots { walk(root) }
        var bundleVisited = Set<String>()
        let appBytes = locations.appBundle.map { allocatedBytes(at: $0, includeHLSReferences: false, visited: &bundleVisited) } ?? 0
        return .init(records: StorageUsageCategory.allCases.map { .init(category: $0, bytes: totals[$0] ?? 0, isEstimated: false) },
            entries: entries.values.sorted { $0.bytes == $1.bytes ? $0.displayPath < $1.displayPath : $0.bytes > $1.bytes }, appBytes: appBytes)
    }

    private static func relative(_ url: URL, in root: URL?) -> [String]? {
        guard let root else { return nil }
        let prefix = root.standardizedFileURL.path + "/", path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        return path.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }

    private static func category(for url: URL, locations: StorageUsageLocations) -> StorageUsageCategory {
        if relative(url, in: locations.downloads) != nil { return .downloads }
        if let parts = relative(url, in: locations.applicationSupport), let first = parts.first {
            switch first {
            case "SouloTabSnapshots": return .tabSnapshots
            case "WallpaperFavorites": return .wallpapers
            case "BookLibrary.json", "BookCovers", "ReadingList.json": return .readingData
            case "AdBlock": return .filterRules
            case "SouloExtensions": return .extensions
            case "TorrentTasks", "ED2KTasks", "DownloadResumeData", "SeparatedMediaDownloads": return .downloadTasks
            case "Soulo": return parts.dropFirst().first == "SettingsBackups" ? .backups : .personalData
            default:
                if first.hasPrefix("SouloLibrary.sqlite") { return .personalData }
            }
        }
        if let parts = relative(url, in: locations.caches), let first = parts.first {
            switch first {
            case "SouloTabSnapshots": return .tabSnapshots
            case "wallpaper_hd": return .wallpapers // legacy favorite originals
            case "CurrentWallpaper", "WallpaperSourcePreviews": return .wallpaperCache
            case "SouloFavicons": return .favicons
            case "SouloAdBlockStartup": return .ruleCache
            case "BackgroundDownloadStaging": return .downloadTasks
            default:
                if parts.contains("SouloFavicons") { return .favicons }
                if parts.contains("ContentRuleLists") { return .ruleCache }
                if parts.contains(where: { $0.localizedCaseInsensitiveContains("webkit") }) { return .webData }
                return .otherCaches
            }
        }
        if let parts = relative(url, in: locations.documents), let first = parts.first,
           first.hasPrefix("custom_wallpaper") { return .wallpapers }
        if let parts = relative(url, in: locations.temporary), let first = parts.first {
            if first == "SouloAuthenticatedHLS" || first.hasPrefix("SouloHLS") || first.hasPrefix("SouloStreaming") { return .downloadTasks }
            if first.hasPrefix("extension-script-host-") { return .extensions }
            return .temporaryFiles
        }
        if let parts = relative(url, in: locations.library), let first = parts.first {
            if first == "WebKit", parts.contains("ContentRuleLists") { return .ruleCache }
            if ["WebKit", "Cookies", "HTTPStorages"].contains(first) { return .webData }
            if first == "Preferences" { return .personalData }
        }
        if relative(url, in: locations.sharedContainer) != nil { return .sharedData }
        return .otherData
    }

    private static func bucket(for url: URL, locations: StorageUsageLocations) -> (URL, String) {
        let roots: [(URL?, String)] = [(locations.downloads, "Downloads"), (locations.applicationSupport, "Application Support"),
            (locations.caches, "Caches"), (locations.documents, "Documents"), (locations.temporary, "Temporary"),
            (locations.library, "Library"), (locations.sharedContainer, "Shared")]
        for (root, title) in roots {
            if let parts = relative(url, in: root), let first = parts.first, let root {
                let selected = first == "Soulo" && parts.count > 1 ? Array(parts.prefix(2)) : [first]
                return (selected.reduce(root) { $0.appendingPathComponent($1) }, ([title] + selected).joined(separator: "/"))
            }
        }
        return (url, url.lastPathComponent)
    }

    /// Clear only regenerable roots. User content and resumable downloads must
    /// go through their owning services rather than raw filesystem deletion.
    static func clearAdditionalCache(_ category: StorageUsageCategory, locations: StorageUsageLocations,
                                     olderThan cutoff: Date) throws {
        let manager = FileManager.default
        let base: URL
        switch category {
        case .wallpaperCache, .otherCaches, .ruleCache: base = locations.caches
        case .temporaryFiles:
            guard let temporary = locations.temporary else { return }; base = temporary
        default: throw CocoaError(.fileWriteNoPermission)
        }
        guard (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw ReadingToolError.unsafePath }
        let children = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
        for child in children {
            let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
            guard info.isSymbolicLink != true else { continue }
            // Classify a child path, including an empty directory, using the
            // same rule as inventory. Never traverse a user-supplied symlink.
            guard self.category(for: child.appendingPathComponent(".probe"), locations: locations) == category else { continue }
            if category == .otherCaches {
                let name = child.lastPathComponent
                // Their live database files belong to URLCache / WebKit APIs.
                if name.hasPrefix(".") || name.hasPrefix("com.") || name.hasPrefix("org.") || name.hasPrefix("nsurlsession") { continue }
            }
            if category == .temporaryFiles {
                guard let modified = info.contentModificationDate, modified < cutoff,
                      !containsFileModified(since: cutoff, at: child) else { continue }
            }
            guard child.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                    == base.standardizedFileURL.resolvingSymlinksInPath() else { throw ReadingToolError.unsafePath }
            try manager.removeItem(at: child)
        }
    }

    /// Reclaim only abandoned intermediates whose UUID is absent from both
    /// download histories. Paused tasks, torrent metadata, current-session
    /// files and final user downloads remain owned by their existing services.
    static func clearUnusedDownloadData(locations: StorageUsageLocations, retainedIDs: Set<UUID>, olderThan cutoff: Date) throws {
        let manager=FileManager.default
        var roots = [locations.applicationSupport.appendingPathComponent("DownloadResumeData"),
            locations.applicationSupport.appendingPathComponent("SeparatedMediaDownloads"),
            locations.applicationSupport.appendingPathComponent("TorrentTasks"),
            locations.applicationSupport.appendingPathComponent("ED2KTasks"),
            locations.caches.appendingPathComponent("BackgroundDownloadStaging")]
        if let temporary=locations.temporary { roots.append(temporary.appendingPathComponent("SouloAuthenticatedHLS")) }
        for root in roots {
            guard let info=try? root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else {continue}
            for child in try manager.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.contentModificationDateKey]) {
                let info=try child.resourceValues(forKeys:[.isSymbolicLinkKey,.contentModificationDateKey])
                guard info.isSymbolicLink != true, let id=UUID(uuidString:String(child.lastPathComponent.prefix(36))),
                      !retainedIDs.contains(id), let modified=info.contentModificationDate,modified < cutoff,
                      !containsFileModified(since:cutoff,at:child),
                      child.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                        == root.standardizedFileURL.resolvingSymlinksInPath() else {continue}
                try manager.removeItem(at:child)
            }
        }
    }

    private static func containsFileModified(since date: Date, at root: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return false }
        for case let file as URL in files {
            guard let info = try? file.resourceValues(forKeys: keys), info.isSymbolicLink != true else { files.skipDescendants(); continue }
            if (info.contentModificationDate ?? .distantFuture) >= date { return true }
        }
        return false
    }
}

struct WebsiteStorageEntry: Identifiable, Sendable, Hashable {
    var id: String { domain }
    let domain: String
    let dataTypes: Set<String>
    let bytes: WebsiteStorageBytes?
    var indexedDBBytes: Int64? {
        guard dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) else { return 0 }
        guard let bytes, bytes.indexedDB > 0 else { return nil }
        return bytes.indexedDB
    }
}

struct WebsiteStorageBytes: Sendable, Hashable {
    var indexedDB: Int64 = 0
    var cache: Int64 = 0
    var localStorage: Int64 = 0
    var other: Int64 = 0
    var isExtension = false
    var total: Int64 { indexedDB + cache + localStorage + other }
    mutating func add(_ other: Self) {
        indexedDB += other.indexedDB; cache += other.cache
        localStorage += other.localStorage; self.other += other.other
        isExtension = isExtension || other.isExtension
    }
}

/// Uses public WebKit records for listing and deletion. The optional disk
/// estimate reads only origin metadata and file sizes in our own sandbox.
/// Unrecognized layouts remain unknown; files are never deleted directly.
enum WebsiteStorageService {
    static let cacheTypes: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeOfflineWebApplicationCache, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeServiceWorkerRegistrations]

    @MainActor static func entries() async -> [WebsiteStorageEntry] {
        let records = await records()
        var types = records.reduce(into: [String: Set<String>]()) { $0[$1.displayName, default: []].formUnion($1.dataTypes) }
        let root = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("WebKit")
        let domains = Set(types.keys)
        let measured = await Task.detached(priority: .utility) { measure(root: root, domains: domains) }.value
        // Public website records can omit custom extension schemes. Their
        // locally measured origin metadata still provides a verified identity.
        for (domain, bytes) in measured where bytes.isExtension && bytes.total > 0 {
            if bytes.indexedDB > 0 { types[domain, default: []].insert(WKWebsiteDataTypeIndexedDBDatabases) }
            if bytes.cache > 0 { types[domain, default: []].insert(WKWebsiteDataTypeFetchCache) }
            if bytes.localStorage > 0 { types[domain, default: []].insert(WKWebsiteDataTypeLocalStorage) }
        }
        return types.map { WebsiteStorageEntry(domain: $0.key, dataTypes: $0.value, bytes: measured[$0.key]) }
            .sorted { ($0.bytes?.total ?? -1) == ($1.bytes?.total ?? -1)
                ? $0.domain.localizedStandardCompare($1.domain) == .orderedAscending : ($0.bytes?.total ?? -1) > ($1.bytes?.total ?? -1) }
    }

    @MainActor private static func records() async -> [WKWebsiteDataRecord] {
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
    }

    @MainActor static func clear(_ entry: WebsiteStorageEntry, types: Set<String>) async throws {
        if types == cacheTypes, let id = UUID(uuidString: entry.domain), #available(iOS 18.4, *) {
            try await NativeWebExtensionRuntime.shared.clearTemporaryCaches(identifiers: [id])
            return
        }
        let matching = await records().filter { $0.displayName == entry.domain }
        guard !matching.isEmpty else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.default().removeData(ofTypes: types, for: matching) { continuation.resume() }
        }
    }

    @MainActor static func clearBrowserCaches() async {
        // Do not bypass the active-media guard by deleting extension caches as
        // part of the global website-store removal first.
        let matching = await records().filter { UUID(uuidString: $0.displayName) == nil }
        if !matching.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, for: matching) { continuation.resume() }
            }
        }
        if #available(iOS 18.4, *) { try? await NativeWebExtensionRuntime.shared.clearTemporaryCaches() }
    }

    static func measure(root: URL, domains: Set<String>) -> [String: WebsiteStorageBytes] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard (try? root.resourceValues(forKeys: keys).isSymbolicLink) == false,
              let files = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return [:] }
        var result: [String: WebsiteStorageBytes] = [:], visited = 0
        let orderedDomains = domains.sorted { $0.count > $1.count }
        func domain(for host: String) -> String? {
            orderedDomains.first { host == $0.lowercased() || host.hasSuffix("." + $0.lowercased()) }
        }
        for case let file as URL in files {
            guard !Task.isCancelled, visited < 100_000 else { break }; visited += 1
            guard let info = try? file.resourceValues(forKeys: keys), info.isSymbolicLink != true else { files.skipDescendants(); continue }
            if info.isDirectory == true {
                let origin = file.appendingPathComponent("origin")
                if let size = try? origin.resourceValues(forKeys: keys), size.isRegularFile == true,
                   size.isSymbolicLink != true, (size.fileSize ?? Int.max) <= 4_096,
                   let data = try? Data(contentsOf: origin), let decoded = decodeOrigin(data),
                   let name = domain(for: decoded.host) ?? (decoded.scheme == "webkit-extension" ? decoded.host : nil) {
                    var value = WebsiteStorageBytes(); value.isExtension = decoded.scheme == "webkit-extension"
                    value.indexedDB = directoryBytes(file.appendingPathComponent("IndexedDB"))
                    value.cache = directoryBytes(file.appendingPathComponent("CacheStorage"))
                    value.localStorage = directoryBytes(file.appendingPathComponent("LocalStorage"))
                    for kind in ["FileSystem", "BackgroundFetch"] { value.other += directoryBytes(file.appendingPathComponent(kind)) }
                    result[name, default: .init()].add(value); files.skipDescendants()
                } else if file.pathComponents.contains("IndexedDB"), let host = legacyHost(file.lastPathComponent), let name = domain(for: host) {
                    var value = WebsiteStorageBytes(); value.indexedDB = directoryBytes(file)
                    result[name, default: .init()].add(value); files.skipDescendants()
                }
            }
        }
        return result
    }

    private static func directoryBytes(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard (try? root.resourceValues(forKeys: keys).isSymbolicLink) == false,
              let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return 0 }
        var bytes: Int64 = 0, count = 0
        for case let file as URL in iterator {
            guard !Task.isCancelled, count < 100_000 else { break }; count += 1
            guard let info = try? file.resourceValues(forKeys: keys), info.isSymbolicLink != true else { iterator.skipDescendants(); continue }
            if info.isRegularFile == true { bytes += Int64(max(0, info.fileAllocatedSize ?? info.fileSize ?? 0)) }
        }
        return bytes
    }

    private static func legacyHost(_ name: String) -> String? {
        guard name.hasPrefix("http_") || name.hasPrefix("https_"), let first = name.firstIndex(of: "_"), let last = name.lastIndex(of: "_"),
              first != last, UInt16(name[name.index(after: last)...]) != nil else { return nil }
        return String(name[name.index(after: first)..<last]).lowercased()
    }

    /// WebKit's origin metadata contains top and client origins. Attribute a
    /// partitioned store to the client origin, not to the embedding website.
    static func decodeOrigin(_ data: Data) -> (scheme: String, host: String)? {
        guard data.count <= 4_096 else { return nil }
        let bytes = Array(data); var position = 0
        func integer(_ width: Int) -> UInt64? {
            guard position + width <= bytes.count else { return nil }
            defer { position += width }
            return (0..<width).reduce(0) { $0 | UInt64(bytes[position + $1]) << ($1 * 8) }
        }
        func string() -> String? {
            guard let length = integer(4), length > 0, length <= 1_024, let narrow = integer(1), narrow <= 1 else { return nil }
            let count = Int(length) * (narrow == 1 ? 1 : 2)
            guard position + count <= bytes.count else { return nil }; defer { position += count }
            return String(bytes: bytes[position..<(position + count)], encoding: narrow == 1 ? .isoLatin1 : .utf16LittleEndian)
        }
        func origin() -> (String, String)? {
            guard let scheme = string(), ["http", "https", "webkit-extension"].contains(scheme), let host = string(),
                  !host.isEmpty, !host.contains(where: { "/\\?#@\0".contains($0) }),
                  let hasPort = integer(1), hasPort <= 1 else { return nil }
            if hasPort == 1 && integer(2) == nil { return nil }
            return (scheme, host.lowercased())
        }
        guard origin() != nil, let client = origin(), position == bytes.count else { return nil }
        return client
    }
}
