import Foundation
import WebKit
import Darwin
import CoreData

enum StorageUsageCategory: String, CaseIterable, Identifiable, Sendable {
    case webData, websiteStorage, tabSnapshots, favicons, wallpaperCache, otherCaches, temporaryFiles, ruleCache
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

struct StorageCleanupReport: Sendable {
    var retainedCategories: Set<StorageUsageCategory> = []
    var failures: [String] = []
    mutating func merge(_ other: Self) {
        retainedCategories.formUnion(other.retainedCategories); failures += other.failures
    }
    @MainActor var notice: String? {
        guard !retainedCategories.isEmpty || !failures.isEmpty else { return nil }
        return ([FeatureText.text("Manage saved content in its own list. Active temporary files and system cache databases are released when safe.")]
            + retainedCategories.map(\.title).sorted() + failures).joined(separator: "\n\n")
    }
}

/// Inventory covers app-container and shared files separately from the installed
/// bundle. Destructive saved-data actions stay in their existing owner pages;
/// regenerable cache categories have an explicit, confirmed cleanup action.
enum StorageUsageService {
    private static let sessionStartedAt = Date()
    static func prepareSession() { _ = sessionStartedAt }
    @MainActor private static let inventoryCache = StorageInventoryCache { appBytes in
        measureInventory(locations: .current, knownAppBytes: appBytes)
    }
    @MainActor static var cachedInventory: StorageUsageInventory? { inventoryCache.value }
    @MainActor static func invalidateInventory() { inventoryCache.invalidate() }
    @MainActor static func inventory(forceRefresh: Bool = false) async -> StorageUsageInventory {
        await inventoryCache.inventory(forceRefresh: forceRefresh)
    }

    @MainActor static func scan() async -> [StorageUsageRecord] { await inventory().records }

    @discardableResult @MainActor
    static func clear(_ category: StorageUsageCategory, tabManager: TabManager? = nil) async throws -> StorageCleanupReport {
        guard category.canClear else { throw CocoaError(.fileWriteNoPermission) }
        invalidateInventory()
        defer { invalidateInventory() }
        var report = StorageCleanupReport()
        switch category {
        case .webData:
            URLCache.shared.removeAllCachedResponses()
            report = await WebsiteStorageService.clearBrowserCaches()
        case .tabSnapshots:
            tabManager?.tabs.forEach { $0.webViewModel.clearSnapshotCache() }
            await WebViewModel.deleteAllPersistedSnapshotsAndWait()
        case .favicons:
            WebsiteFaviconService.shared.clear()
        case .ruleCache:
            do { try await clearCompiledRuleCache(in: WKContentRuleListStore.default()) }
            catch { report.retainedCategories.insert(.ruleCache); report.failures.append(error.localizedDescription) }
            let locations = StorageUsageLocations.current
            report.merge(try await Task.detached(priority: .utility) { try clearAdditionalCache(.ruleCache, locations: locations, olderThan: .distantFuture) }.value)
        case .downloadTasks:
            let retained = Set(DownloadManagerService.shared.downloads.map(\.id)).union(TorrentDownloadService.shared.jobs.map(\.id))
            let locations = StorageUsageLocations.current, cutoff = sessionStartedAt
            report.merge(try await Task.detached(priority: .utility) { try clearUnusedDownloadData(locations: locations, retainedIDs: retained, olderThan: cutoff) }.value)
        case .wallpaperCache, .otherCaches, .temporaryFiles:
            if category == .temporaryFiles,
               DownloadManagerService.shared.downloads.contains(where: { [.inProgress, .paused].contains($0.status) }) {
                throw WebExtensionTemporaryCacheError.inUse
            }
            if category == .wallpaperCache { WallpaperManager.shared.prepareForImageCacheCleanup() }
            if category == .otherCaches { URLCache.shared.removeAllCachedResponses() }
            let locations = StorageUsageLocations.current, cutoff = sessionStartedAt
            report.merge(try await Task.detached(priority: .utility) { try clearAdditionalCache(category, locations: locations, olderThan: cutoff) }.value)
        case .websiteStorage, .wallpapers, .downloads, .readingData, .backups, .filterRules,
             .extensions, .personalData, .sharedData, .otherData:
            throw CocoaError(.fileWriteNoPermission)
        }
        return report
    }

    @MainActor static func clearWebsiteData() async -> StorageCleanupReport {
        invalidateInventory()
        defer { invalidateInventory() }
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.removeCookies(since: .distantPast)
        return await WebsiteStorageService.clearAll()
    }

    @MainActor static func clearCompiledRuleCache(in store: WKContentRuleListStore) async throws {
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        var failures: [String] = []
        for identifier in identifiers where identifier.hasPrefix("SouloAdBlock") {
            do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.removeContentRuleList(forIdentifier: identifier) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            } } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw NSError(domain: "Soulo.StorageCleanup", code: 1, userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")]) }
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
    static func measureInventory(locations: StorageUsageLocations, knownAppBytes: Int64? = nil) -> StorageUsageInventory {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        let classifier = StoragePathClassifier(locations: locations)
        var visited = Set<String>(), totals: [StorageUsageCategory: Int64] = [:]
        var entries: [String: StorageDiskEntry] = [:]
        let roots = [locations.documents, locations.library, locations.temporary,
            locations.sharedContainer, locations.applicationSupport, locations.caches, locations.downloads].compactMap { $0 }
        func walk(_ url: URL, forced: StorageUsageCategory? = nil) {
            guard !Task.isCancelled,
                  let info = try? url.resourceValues(forKeys: keys), info.isSymbolicLink != true,
                  visited.insert(classifier.normalizedPath(url.path)).inserted else { return }
            if info.isDirectory == true {
                for child in (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? [] { walk(child, forced: forced) }
            } else if info.isRegularFile == true {
                let path = classifier.normalizedPath(url.path)
                let category = forced ?? classifier.category(path)
                let bytes = Int64(max(0, info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0))
                totals[category] = adding(totals[category] ?? 0, bytes)
                let (bucket, label) = classifier.bucket(path)
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
        let appBytes = knownAppBytes ?? locations.appBundle.map { allocatedBytes(at: $0, includeHLSReferences: false, visited: &bundleVisited) } ?? 0
        return .init(records: StorageUsageCategory.allCases.map { .init(category: $0, bytes: totals[$0] ?? 0, isEstimated: false) },
            entries: entries.values.sorted { $0.bytes == $1.bytes ? $0.displayPath < $1.displayPath : $0.bytes > $1.bytes }, appBytes: appBytes)
    }

    /// Clear only regenerable roots. User content and resumable downloads must
    /// go through their owning services rather than raw filesystem deletion.
    @discardableResult
    static func clearAdditionalCache(_ category: StorageUsageCategory, locations: StorageUsageLocations,
                                     olderThan cutoff: Date) throws -> StorageCleanupReport {
        let manager = FileManager.default
        let base: URL
        switch category {
        case .wallpaperCache, .otherCaches, .ruleCache: base = locations.caches
        case .temporaryFiles:
            guard let temporary = locations.temporary else { return .init() }; base = temporary
        default: throw CocoaError(.fileWriteNoPermission)
        }
        guard manager.fileExists(atPath: base.path) else { return .init() }
        guard (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw ReadingToolError.unsafePath }
        let children = try manager.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
        var report = StorageCleanupReport()
        let classifier = StoragePathClassifier(locations: locations)
        for child in children {
            do {
            let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .contentModificationDateKey])
            guard info.isSymbolicLink != true else { continue }
            // Classify a child path, including an empty directory, using the
            // same rule as inventory. Never traverse a user-supplied symlink.
            guard classifier.category(child.appendingPathComponent(".probe").path) == category else { continue }
            if category == .otherCaches {
                let name = child.lastPathComponent
                // Their live database files belong to URLCache / WebKit APIs.
                if name.hasPrefix(".") || name.hasPrefix("com.") || name.hasPrefix("org.") || name.hasPrefix("nsurlsession") { continue }
            }
            if category == .temporaryFiles {
                guard let modified = info.contentModificationDate, modified < cutoff,
                      !containsFileModified(since: cutoff, at: child) else { report.retainedCategories.insert(category); continue }
            }
            guard child.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                    == base.standardizedFileURL.resolvingSymlinksInPath() else { throw ReadingToolError.unsafePath }
            try manager.removeItem(at: child)
            } catch {
                if manager.fileExists(atPath: child.path) {
                    report.retainedCategories.insert(category)
                    report.failures.append(child.lastPathComponent + " · " + error.localizedDescription)
                }
            }
        }
        return report
    }

    /// Reclaim only abandoned intermediates whose UUID is absent from both
    /// download histories. Paused tasks, torrent metadata, current-session
    /// files and final user downloads remain owned by their existing services.
    @discardableResult
    static func clearUnusedDownloadData(locations: StorageUsageLocations, retainedIDs: Set<UUID>, olderThan cutoff: Date) throws -> StorageCleanupReport {
        let manager=FileManager.default
        var report = StorageCleanupReport()
        var roots = [locations.applicationSupport.appendingPathComponent("DownloadResumeData"),
            locations.applicationSupport.appendingPathComponent("SeparatedMediaDownloads"),
            locations.applicationSupport.appendingPathComponent("TorrentTasks"),
            locations.applicationSupport.appendingPathComponent("ED2KTasks"),
            locations.caches.appendingPathComponent("BackgroundDownloadStaging")]
        if let temporary=locations.temporary { roots.append(temporary.appendingPathComponent("SouloAuthenticatedHLS")) }
        for root in roots {
            guard let info=try? root.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink != true else {continue}
            do {
            for child in try manager.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isSymbolicLinkKey,.contentModificationDateKey]) {
                do {
                let info=try child.resourceValues(forKeys:[.isSymbolicLinkKey,.contentModificationDateKey])
                guard info.isSymbolicLink != true, let id=UUID(uuidString:String(child.lastPathComponent.prefix(36))),
                      !retainedIDs.contains(id), let modified=info.contentModificationDate,modified < cutoff,
                      !containsFileModified(since:cutoff,at:child),
                      child.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
                        == root.standardizedFileURL.resolvingSymlinksInPath() else { report.retainedCategories.insert(.downloadTasks); continue }
                try manager.removeItem(at:child)
                } catch {
                    if manager.fileExists(atPath: child.path) {
                        report.retainedCategories.insert(.downloadTasks); report.failures.append(error.localizedDescription)
                    }
                }
            }
            } catch { report.retainedCategories.insert(.downloadTasks); report.failures.append(error.localizedDescription) }
        }
        return report
    }

    fileprivate static func containsFileModified(since date: Date, at root: URL) -> Bool {
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

    @MainActor static func entries(onList: (([WebsiteStorageEntry]) -> Void)? = nil) async -> [WebsiteStorageEntry] {
        let records = await records()
        var types = records.reduce(into: [String: Set<String>]()) { $0[$1.displayName, default: []].formUnion($1.dataTypes) }
        onList?(types.map { .init(domain: $0.key, dataTypes: $0.value, bytes: nil) }
            .sorted { $0.domain.localizedStandardCompare($1.domain) == .orderedAscending })
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
        StorageUsageService.invalidateInventory()
        defer { StorageUsageService.invalidateInventory() }
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

    @discardableResult @MainActor static func clearBrowserCaches() async -> StorageCleanupReport {
        // Do not bypass the active-media guard by deleting extension caches as
        // part of the global website-store removal first.
        let matching = await records().filter { UUID(uuidString: $0.displayName) == nil }
        if !matching.isEmpty {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.default().removeData(ofTypes: cacheTypes, for: matching) { continuation.resume() }
            }
        }
        var report = StorageCleanupReport()
        if #available(iOS 18.4, *) {
            do { try await NativeWebExtensionRuntime.shared.clearTemporaryCaches() }
            catch {
                report.retainedCategories.insert(.webData)
                if !(error is WebExtensionTemporaryCacheError) { report.failures.append(error.localizedDescription) }
            }
        }
        return report
    }

    /// One confirmed action clears every website's databases, cache and login
    /// storage. Active extension media remains protected, without preventing
    /// removal of other sites. The full-store API also covers unlisted origins.
    @MainActor static func clearAll() async -> StorageCleanupReport {
        var report = StorageCleanupReport()
        var extensionsInUse = false
        if #available(iOS 18.4, *) {
            do { try await NativeWebExtensionRuntime.shared.clearTemporaryCaches() }
            catch {
                extensionsInUse = true; report.retainedCategories.insert(.websiteStorage)
                if !(error is WebExtensionTemporaryCacheError) { report.failures.append(error.localizedDescription) }
            }
        }
        let store = WKWebsiteDataStore.default(), types = WKWebsiteDataStore.allWebsiteDataTypes()
        if extensionsInUse {
            let sites = await records().filter { UUID(uuidString: $0.displayName) == nil }
            if !sites.isEmpty {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    store.removeData(ofTypes: types, for: sites) { c.resume() }
                }
            }
        } else {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.removeData(ofTypes: types, modifiedSince: .distantPast) { c.resume() }
            }
        }
        return report
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

/// Keep one scan in flight and reuse the immutable installed-bundle size.
/// Invalidating during cleanup prevents a pre-deletion scan from winning later.
@MainActor final class StorageInventoryCache {
    private let scan: @Sendable (Int64?) -> StorageUsageInventory
    private var inFlight: (UUID, Task<StorageUsageInventory, Never>)?
    private var measuredAt = Date.distantPast
    private var appBytes: Int64?
    private(set) var value: StorageUsageInventory?

    init(scan: @escaping @Sendable (Int64?) -> StorageUsageInventory) { self.scan = scan }

    func invalidate() {
        inFlight?.1.cancel(); inFlight = nil
        value = nil; measuredAt = .distantPast
    }

    func inventory(forceRefresh: Bool = false) async -> StorageUsageInventory {
        if !forceRefresh, let value, Date().timeIntervalSince(measuredAt) < 15 { return value }
        let work: (UUID, Task<StorageUsageInventory, Never>)
        if let inFlight { work = inFlight }
        else {
            let scan = scan, appBytes = appBytes
            work = (UUID(), Task.detached(priority: .utility) { scan(appBytes) })
            inFlight = work
        }
        let result = await work.1.value
        if inFlight?.0 == work.0 {
            inFlight = nil
            if !work.1.isCancelled {
                value = result; appBytes = result.appBytes; measuredAt = Date()
            }
        } else if work.1.isCancelled, !Task.isCancelled {
            return await inventory(forceRefresh: false)
        }
        return result
    }
}

/// Paths are prepared once per inventory. No per-file filesystem resolution or
/// repeated root URL construction is needed to classify thousands of entries.
struct StoragePathClassifier {
    private let downloads: String, support: String, caches: String
    private let documents: String?, library: String?, temporary: String?, shared: String?
    private let buckets: [(String, String)]
    private let aliases: [(String, String)]

    init(locations: StorageUsageLocations) {
        func path(_ url: URL) -> String { Self.foldPrivatePrefix(url.standardizedFileURL.resolvingSymlinksInPath().path) + "/" }
        let roots = [locations.downloads, locations.applicationSupport, locations.caches,
            locations.documents, locations.library, locations.temporary, locations.sharedContainer].compactMap { $0 }
        var mappings: [String: String] = [:]
        for root in roots {
            let canonical = path(root)
            for variant in [root.path, root.standardizedFileURL.path, root.resolvingSymlinksInPath().path] {
                mappings[Self.foldPrivatePrefix(variant) + "/"] = canonical
            }
        }
        aliases = mappings.map { ($0.key, $0.value) }.sorted { $0.0.count > $1.0.count }
        downloads = path(locations.downloads); support = path(locations.applicationSupport); caches = path(locations.caches)
        documents = locations.documents.map(path); library = locations.library.map(path)
        temporary = locations.temporary.map(path); shared = locations.sharedContainer.map(path)
        buckets = [(Optional(locations.downloads), "Downloads"), (locations.applicationSupport, "Application Support"),
                   (locations.caches, "Caches"), (locations.documents, "Documents"), (locations.temporary, "Temporary"),
                   (locations.library, "Library"), (locations.sharedContainer, "Shared")]
            .compactMap { url, name in url.map { (path($0), name) } }
    }

    private func parts(_ path: String, under root: String?) -> [Substring]? {
        guard let root, path.hasPrefix(root) else { return nil }
        return path.dropFirst(root.count).split(separator: "/")
    }

    private static func foldPrivatePrefix(_ path: String) -> String {
        // Directory enumeration on physical devices returns /private/var even
        // when Foundation's sandbox roots and resolvingSymlinks return /var.
        if path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") { return String(path.dropFirst(8)) }
        return path
    }

    func normalizedPath(_ rawPath: String) -> String {
        let path = Self.foldPrivatePrefix(rawPath)
        for (alias, canonical) in aliases {
            if path.hasPrefix(alias) { return canonical + path.dropFirst(alias.count) }
            if path == alias.dropLast() { return String(canonical.dropLast()) }
        }
        return path
    }

    func category(_ rawPath: String) -> StorageUsageCategory {
        let path = normalizedPath(rawPath)
        if path.hasPrefix(downloads) { return .downloads }
        if let parts = parts(path, under: support), let first = parts.first {
            switch first {
            case "SouloTabSnapshots": return .tabSnapshots
            case "WallpaperFavorites": return .wallpapers
            case "BookLibrary.json", "BookCovers", "ReadingList.json": return .readingData
            case "AdBlock": return .filterRules
            case "SouloExtensions": return .extensions
            case "TorrentTasks", "ED2KTasks", "DownloadResumeData", "SeparatedMediaDownloads": return .downloadTasks
            case "Soulo": return parts.dropFirst().first == "SettingsBackups" ? .backups : .personalData
            default: if first.hasPrefix("SouloLibrary.sqlite") || first == ".SouloLibrary_SUPPORT" { return .personalData }
            }
        }
        if let parts = parts(path, under: caches), let first = parts.first {
            switch first {
            case "SouloTabSnapshots": return .tabSnapshots
            case "wallpaper_hd": return .wallpapers
            case "CurrentWallpaper", "WallpaperSourcePreviews": return .wallpaperCache
            case "SouloAdBlockStartup": return .ruleCache
            case "BackgroundDownloadStaging": return .downloadTasks
            default: break
            }
            if parts.contains("SouloFavicons") {
                // URLCache keeps its live SQLite catalog after response removal.
                return parts.contains("fsCachedData") ? .favicons : .otherData
            }
            if parts.contains("ContentRuleLists") { return .ruleCache }
            if parts.contains(where: { ["IndexedDB", "LocalStorage", "FileSystem", "BackgroundFetch"].contains($0) }) { return .websiteStorage }
            if parts.contains(where: { $0.localizedCaseInsensitiveContains("webkit") }) || parts.contains("fsCachedData") {
                return .webData
            }
            // These live system databases cannot be removed with raw unlink.
            if first.hasPrefix(".") || first.hasPrefix("com.") || first.hasPrefix("org.") || first.hasPrefix("nsurlsession") { return .otherData }
            return .otherCaches
        }
        if let parts = parts(path, under: documents), parts.first?.hasPrefix("custom_wallpaper") == true { return .wallpapers }
        if let parts = parts(path, under: temporary), let first = parts.first {
            if first == "SouloAuthenticatedHLS" || first.hasPrefix("SouloHLS") || first.hasPrefix("SouloStreaming") { return .downloadTasks }
            if first.hasPrefix("extension-script-host-") { return .extensions }
            return .temporaryFiles
        }
        if let parts = parts(path, under: library), let first = parts.first {
            if first == "WebKit" {
                if parts.contains("ContentRuleLists") { return .ruleCache }
                if parts.contains(where: { ["CacheStorage", "NetworkCache", "ServiceWorkers", "ApplicationCache"].contains($0) }) { return .webData }
                return .websiteStorage
            }
            if first == "HTTPStorages" || first == "Cookies" { return .websiteStorage }
            if first == "Preferences" || first == "SyncedPreferences" { return .personalData }
        }
        if let shared, path.hasPrefix(shared) { return .sharedData }
        return .otherData
    }

    func bucket(_ rawPath: String) -> (URL, String) {
        let path = normalizedPath(rawPath)
        for (root, title) in buckets where path.hasPrefix(root) {
            let parts = path.dropFirst(root.count).split(separator: "/", maxSplits: 2)
            guard let first = parts.first else { continue }
            let selected = first == "Soulo" && parts.count > 1 ? parts.prefix(2) : parts.prefix(1)
            let suffix = selected.joined(separator: "/")
            return (URL(fileURLWithPath: root + suffix), title + "/" + suffix)
        }
        let url = URL(fileURLWithPath: path)
        return (url, url.lastPathComponent)
    }
}

/// Explicit destructive media cleanup. Ordinary cache cleanup never stops work.
enum StorageMediaCleanup {
    @MainActor private static var running = false

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/private/var/") || path.hasPrefix("/private/tmp/") ? String(path.dropFirst(8)) : path
    }

    static func isManagedContainer(_ url: URL, locations: StorageUsageLocations) -> Bool {
        guard let library = locations.library,
              url.lastPathComponent.hasPrefix("com.apple.UserManagedAssets."),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return false }
        return canonicalPath(url.deletingLastPathComponent()) == canonicalPath(library)
    }

    @MainActor static func clear(container: URL? = nil, preservingReferencedMedia: Bool = false) async throws -> StorageCleanupReport {
        guard !running else { throw WebExtensionTemporaryCacheError.inUse }
        let places = StorageUsageLocations.current
        if let container, !isManagedContainer(container, locations: places) { throw ReadingToolError.unsafePath }
        running = true
        let cleanupStarted = Date()
        StorageUsageService.invalidateInventory()
        defer { running = false; StorageUsageService.invalidateInventory() }

        // This path is reached only after a warning that unfinished transfers,
        // playback and exports will stop. Preserve completed ordinary files.
        MediaSession.shared.stop()
        MediaExportBackgroundService.shared.cancelForStorageCleanup()
        let manager = DownloadManagerService.shared
        let unfinished = manager.downloads.filter {
            [.inProgress, .paused].contains($0.status) && ![.torrent, .ed2k].contains($0.transport)
        }
        unfinished.forEach { manager.delete($0) }
        await StreamingMediaDownloadService.shared.cancelTasksForStorageCleanup()
        await SeparatedMediaDownloadService.shared.cancelTasksForStorageCleanup()
        await BackgroundDownloadService.shared.cancelTasksForStorageCleanup()
        var quiet = false
        for _ in 0..<30 {
            let background = await BackgroundDownloadService.shared.pendingTasksForStorageCleanup()
            let streaming = await StreamingMediaDownloadService.shared.pendingTasksForStorageCleanup()
            let separated = await SeparatedMediaDownloadService.shared.pendingTasksForStorageCleanup()
            if !background && !streaming && !separated && !MediaExportBackgroundService.shared.hasJobsForStorageCleanup {
                quiet = true; break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let category: StorageUsageCategory = container == nil ? .temporaryFiles : .otherData
        // A system downloader can hold assets in another process. Never unlink
        // its managed directory while cancellation/finalization is outstanding.
        if container != nil && !quiet {
            return .init(retainedCategories: [category], failures: [ToolText.text("storage_files_still_in_use")])
        }
        let cutoff = quiet ? (container == nil ? Date() : .distantFuture) : cleanupStarted
        let preserveTransfers = !quiet
        var retainedLeases = Set<String>()
        if #available(iOS 18.4, *) {
            retainedLeases = Set(WebExtensionBlobBridge.retainedTemporaryURLs.map(canonicalPath))
        }
        let protectedLeases = retainedLeases
        let result = try await Task.detached(priority: .utility) {
            let root = container ?? places.temporary
            guard let root else { return (StorageCleanupReport(), [URL]()) }
            let preserved = preservingReferencedMedia ? Set(references(in: places.documents, under: root).map { canonicalPath($0.1) }) : []
            return try removeFilesAndReferences(at: root, category: category, locations: places,
                protectedPaths: openFilePaths().union(protectedLeases), olderThan: cutoff, removeRoot: container != nil,
                preserveTransfers: preserveTransfers, preservedPackages: preserved)
        }.value
        for reference in result.1 { manager.didDeleteLocalFile(at: reference) }
        if !result.1.isEmpty { manager.removeMissingFiles() }
        var report = result.0
        if !quiet { report.retainedCategories.insert(category) }
        if !report.retainedCategories.isEmpty { report.failures.append(ToolText.text("storage_files_still_in_use")) }
        return report
    }

    static func removeFilesAndReferences(at root: URL, category: StorageUsageCategory, locations: StorageUsageLocations,
                                        protectedPaths: Set<String>, olderThan cutoff: Date,
                                        removeRoot: Bool, preserveTransfers: Bool = false,
                                        preservedPackages: Set<String> = []) throws -> (StorageCleanupReport, [URL]) {
        let ownedReferences = removeRoot ? references(in: locations.documents, under: root) : []
        var report = try removeReleasedFiles(at: root, category: category, locations: locations,
            protectedPaths: protectedPaths, olderThan: cutoff, removeRoot: removeRoot,
            preserveTransfers: preserveTransfers, preservedPackages: preservedPackages)
        var removed: [URL] = []
        for (reference, package) in ownedReferences where !FileManager.default.fileExists(atPath: package.path) {
            do {
                try LibraryFileActions.delete([reference], in: reference.deletingLastPathComponent())
                removed.append(reference)
            } catch { report.failures.append(reference.lastPathComponent + " · " + error.localizedDescription) }
        }
        return (report, removed)
    }

    /// File descriptors are inspected only in our own process, using public
    /// Darwin APIs. An open decoder, exporter or importer keeps its file.
    static func openFilePaths() -> Set<String> {
        var result = Set<String>()
        for fd in 0..<getdtablesize() {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if fcntl(fd, F_GETPATH, &buffer) == 0 {
                let url = URL(fileURLWithPath: String(cString: buffer))
                result.insert(canonicalPath(url))
            }
        }
        return result
    }

    static func references(in documents: URL?, under container: URL) -> [(URL, URL)] {
        guard let documents,
              let scan = FileManager.default.enumerator(at: documents, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey]) else { return [] }
        let prefix = canonicalPath(container) + "/"
        var result: [(URL, URL)] = []
        for case let file as URL in scan {
            guard let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]), values.isSymbolicLink != true else {
                scan.skipDescendants(); continue
            }
            guard file.pathExtension.lowercased() == OfflineHLSReference.fileExtension,
                  (values.fileSize ?? Int.max) <= 1024 * 1024,
                  let package = try? OfflineHLSReference.packageURL(for: file),
                  canonicalPath(package).hasPrefix(prefix) else { continue }
            result.append((file, package))
        }
        return result
    }

    /// Continue per file, protecting open files, links, and new writes. Only a
    /// validated managed-assets container or the supplied temporary root enters.
    static func removeReleasedFiles(at root: URL, category: StorageUsageCategory, locations: StorageUsageLocations,
                                    protectedPaths: Set<String>, olderThan cutoff: Date,
                                    removeRoot: Bool, preserveTransfers: Bool = false,
                                    preservedPackages: Set<String> = []) throws -> StorageCleanupReport {
        let manager = FileManager.default
        let isManaged = isManagedContainer(root, locations: locations)
        let isTemporary = locations.temporary.map {
            canonicalPath(root) == canonicalPath($0)
        } == true
        guard (removeRoot && isManaged) || (!removeRoot && isTemporary),
              (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { throw ReadingToolError.unsafePath }
        var report = StorageCleanupReport()
        let classifier = StoragePathClassifier(locations: locations)
        let rootPath = canonicalPath(root)
        func retain(_ url: URL, error: Error? = nil) {
            report.retainedCategories.insert(category)
            if let error, report.failures.count < 20 { report.failures.append(url.lastPathComponent + " · " + error.localizedDescription) }
        }
        func walk(_ file: URL, isRoot: Bool = false) {
            do {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                guard values.isSymbolicLink != true else { retain(file); return }
                let path = canonicalPath(file)
                guard path == rootPath || path.hasPrefix(rootPath + "/") else { retain(file, error: ReadingToolError.unsafePath); return }
                if preservedPackages.contains(path) { return }
                guard !protectedPaths.contains(path) else { retain(file); return }
                if preserveTransfers && !isRoot,
                   classifier.category(file.appendingPathComponent(".probe").path) == .downloadTasks
                    || (preserveTransfers && file.lastPathComponent.hasPrefix("CFNetworkDownload")) {
                    retain(file); return
                }
                if !removeRoot && !isRoot {
                    // Extension script hosts are persistent extension state,
                    // even when their compatibility host lives under tmp.
                    let owner = classifier.category(file.appendingPathComponent(".probe").path)
                    guard [.temporaryFiles, .downloadTasks].contains(owner) else { return }
                    let name = file.lastPathComponent.lowercased()
                    if name.contains("webkit") || name.hasPrefix("com.apple.")
                        || ["sqlite", "sqlite3", "db"].contains(file.pathExtension.lowercased())
                        || name.hasSuffix("-wal") || name.hasSuffix("-shm") {
                        // WebKit/system processes own these handles; their
                        // caches must be released through the website APIs.
                        retain(file); return
                    }
                }
                if values.isDirectory == true {
                    // Offline HLS bundles are private AVFoundation packages.
                    // Keep or delete the whole asset; removing individual
                    // fragments could corrupt a package that is still playing.
                    if file.pathExtension.lowercased() == "movpkg" {
                        guard !protectedPaths.contains(where: { $0.hasPrefix(path + "/") }),
                              !StorageUsageService.containsFileModified(since: cutoff, at: file) else {
                            retain(file); return
                        }
                        try manager.removeItem(at: file)
                        return
                    }
                    for child in try manager.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) { walk(child) }
                    if (!isRoot || removeRoot), try manager.contentsOfDirectory(atPath: file.path).isEmpty {
                        try manager.removeItem(at: file)
                    }
                } else if values.isRegularFile == true {
                    guard let modified = values.contentModificationDate, modified < cutoff else { retain(file); return }
                    try manager.removeItem(at: file)
                } else { retain(file) }
            } catch {
                if manager.fileExists(atPath: file.path) { retain(file, error: error) }
            }
        }
        walk(root, isRoot: true)
        return report
    }
}

/// Extra system caches use a narrow allowlist. Cloud tokens and preference
/// journals are settings, and live URLCache databases remain owned by the API.
enum StorageOtherCleanup {
    static func canClearCache(_ url: URL, locations: StorageUsageLocations) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { return false }
        let classifier = StoragePathClassifier(locations: locations)
        let parent = classifier.normalizedPath(url.deletingLastPathComponent().path)
        if parent == classifier.normalizedPath(locations.caches.path) {
            return classifier.category(url.appendingPathComponent(".probe").path) == .otherData
        }
        return locations.library.map { parent == classifier.normalizedPath($0.path) } == true
            && ["SplashBoard", "Saved Application State", "LanguageModeling"].contains(url.lastPathComponent)
    }

    @MainActor static func clearCaches(entry: URL? = nil) async throws -> StorageCleanupReport {
        let places = StorageUsageLocations.current
        if let entry, !canClearCache(entry, locations: places) { throw ReadingToolError.unsafePath }
        StorageUsageService.invalidateInventory()
        defer { StorageUsageService.invalidateInventory() }
        URLCache.shared.removeAllCachedResponses()
        WebsiteFaviconService.shared.clear()
        let cutoff = Date()
        var report = try await Task.detached(priority: .utility) {
            let roots: [URL]
            if let entry { roots = [entry] }
            else {
                roots = [Optional(places.caches), places.library].compactMap { $0 }.flatMap {
                    (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
                }.filter { canClearCache($0, locations: places) }
            }
            var result = StorageCleanupReport()
            let protected = StorageMediaCleanup.openFilePaths()
            for root in roots {
                result.merge(try removeCacheFiles(at: root, locations: places, protectedPaths: protected, olderThan: cutoff))
            }
            return result
        }.value
        if !report.retainedCategories.isEmpty { report.failures.append(ToolText.text("storage_system_data_retained")) }
        return report
    }

    @MainActor static func clearOfflineMedia() async throws -> StorageCleanupReport {
        let places = StorageUsageLocations.current
        guard let library = places.library else { return .init() }
        let roots = try FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { StorageMediaCleanup.isManagedContainer($0, locations: places) }
        var report = StorageCleanupReport()
        for root in roots {
            do { report.merge(try await StorageMediaCleanup.clear(container: root, preservingReferencedMedia: true)) }
            catch { report.retainedCategories.insert(.otherData); report.failures.append(error.localizedDescription) }
        }
        return report
    }

    static func removeCacheFiles(at root: URL, locations: StorageUsageLocations, protectedPaths: Set<String>,
                                 olderThan cutoff: Date) throws -> StorageCleanupReport {
        guard canClearCache(root, locations: locations) else { throw ReadingToolError.unsafePath }
        let manager = FileManager.default, classifier = StoragePathClassifier(locations: locations)
        let rootPath = classifier.normalizedPath(root.path)
        var report = StorageCleanupReport()
        func retain(_ file: URL, error: Error? = nil) {
            report.retainedCategories.insert(.otherData)
            if let error, report.failures.count < 20 { report.failures.append(file.lastPathComponent + " · " + error.localizedDescription) }
        }
        func walk(_ file: URL) {
            do {
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
                let path = classifier.normalizedPath(file.path)
                guard values.isSymbolicLink != true, path == rootPath || path.hasPrefix(rootPath + "/") else { retain(file); return }
                guard !protectedPaths.contains(path) else { retain(file); return }
                guard classifier.category(file.appendingPathComponent(".probe").path) == .otherData else { return }
                if values.isDirectory == true {
                    for child in try manager.contentsOfDirectory(at: file, includingPropertiesForKeys: nil) { walk(child) }
                    if try manager.contentsOfDirectory(atPath: file.path).isEmpty { try manager.removeItem(at: file) }
                } else if values.isRegularFile == true {
                    let name = file.lastPathComponent.lowercased()
                    // A SQLite/LMDB catalog can be open in a system process.
                    guard !["sqlite", "sqlite3", "db", "mdb"].contains(file.pathExtension.lowercased()),
                          !name.hasSuffix("-wal"), !name.hasSuffix("-shm"), !name.hasSuffix("-journal"),
                          let modified = values.contentModificationDate, modified < cutoff else { retain(file); return }
                    try manager.removeItem(at: file)
                } else { retain(file) }
            } catch { if manager.fileExists(atPath: file.path) { retain(file, error: error) } }
        }
        walk(root)
        return report
    }
}

struct StorageCleanupEstimate: Sendable {
    let bytes: Int64?
    let isEstimated: Bool
}

/// A cleanup scope can differ from an inventory category: favorite wallpapers
/// exclude the selected custom background, and orphan HLS assets exclude saved
/// Downloads. Shared database records use logical content estimates, not a
/// repeated charge for the complete SQLite store.
enum StorageCleanupEstimateService {
    @MainActor static func estimates(records: [StorageUsageRecord], context: NSManagedObjectContext? = nil) async -> [StorageCleanupChoice: StorageCleanupEstimate] {
        let locations = StorageUsageLocations.current
        let favoriteIDs = WallpaperManager.shared.favorites.map(\.id)
        async let fileEstimates = Task.detached(priority: .utility) {
            let scan = StorageCleanupEstimateScanner(locations: locations)
            return scan.estimates(favoriteIDs: favoriteIDs)
        }.value
        var result: [StorageCleanupChoice: StorageCleanupEstimate] = [:]
        for record in records where record.canClear {
            result[.cache(record.category)] = .init(bytes: record.isEstimated ? nil : record.bytes, isEstimated: record.isEstimated)
        }
        let websites = records.filter { [.webData, .websiteStorage].contains($0.category) }
        let websitesKnown = websites.count == 2 && !websites.contains(where: \.isEstimated)
        result[.websiteData] = .init(bytes: websitesKnown ? websites.reduce(0) { StorageUsageService.adding($0, $1.bytes) } : nil,
                                    isEstimated: !websitesKnown)
        result[.history] = .init(bytes: nil, isEstimated: true)
        result[.bookmarks] = .init(bytes: nil, isEstimated: true)
        if let coordinator = context?.persistentStoreCoordinator {
            let worker = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            worker.persistentStoreCoordinator = coordinator
            worker.undoManager = nil
            let logical = await worker.perform {
                var values: [StorageCleanupChoice: StorageCleanupEstimate] = [:]
                let scopes: [(StorageCleanupChoice, [String])] = [
                    (.history, [SearchHistoryRecord.entityName]),
                    (.bookmarks, [BookmarkRecord.entityName, BookmarkFolderRecord.entityName])
                ]
                for (choice, entities) in scopes {
                    do {
                        var total: Int64 = 0
                        for entityName in entities {
                            let request = NSFetchRequest<NSManagedObject>(entityName: entityName)
                            request.fetchBatchSize = 128
                            request.includesPendingChanges = false
                            for row in try worker.fetch(request) {
                                total = try autoreleasepool {
                                    var fields: [String: Any] = [:]
                                    for key in row.entity.attributesByName.keys {
                                        guard let value = row.value(forKey: key) else { continue }
                                        if let id = value as? UUID { fields[key] = id.uuidString }
                                        else { fields[key] = value }
                                    }
                                    let payload = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
                                    let size = StorageUsageService.adding(total, Int64(payload.count))
                                    worker.refresh(row, mergeChanges: false)
                                    return size
                                }
                            }
                        }
                        values[choice] = .init(bytes: total, isEstimated: true)
                    } catch { values[choice] = .init(bytes: nil, isEstimated: true) }
                }
                return values
            }
            result.merge(logical) { _, new in new }
        }
        result.merge(await fileEstimates) { _, new in new }
        return result
    }
}

private final class StorageCleanupEstimateScanner {
    private let locations: StorageUsageLocations
    private let manager = FileManager.default
    private let classifier: StoragePathClassifier
    private let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]

    init(locations: StorageUsageLocations) {
        self.locations = locations
        classifier = StoragePathClassifier(locations: locations)
    }

    func estimates(favoriteIDs: [String]) -> [StorageCleanupChoice: StorageCleanupEstimate] {
        var result: [StorageCleanupChoice: StorageCleanupEstimate] = [:]
        var complete = true
        let downloads = children(locations.downloads, skipHidden: true, complete: &complete)
        result[.downloadedFiles] = estimate(downloads, followingReferences: true, complete: complete)

        let originals = FavoriteWallpaperImageStore(applicationSupport: locations.applicationSupport, caches: locations.caches)
        let favoriteFiles = favoriteIDs.flatMap { originals.imageURLs(for: $0) }
        result[.wallpapers] = estimate(favoriteFiles)
        result[.reading] = estimate(["BookLibrary.json", "BookCovers", "ReadingList.json"].map {
            locations.applicationSupport.appendingPathComponent($0)
        })

        complete = true
        let backupsDirectory = locations.applicationSupport.appendingPathComponent("Soulo/SettingsBackups")
        let backups = children(backupsDirectory, complete: &complete).compactMap { file -> URL? in
            guard file.pathExtension == "json",
                  (try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map({ $0.isRegularFile == true && $0.isSymbolicLink != true }) == true else { return nil }
            guard let data = try? Data(contentsOf: file), let backup = try? JSONDecoder().decode(CloudSettingsBackup.self, from: data), backup.version == 1 else { return nil }
            // deleteAll() resolves each decoded backup by its identifier.
            return backupsDirectory.appendingPathComponent(backup.id.uuidString + ".json")
        }
        result[.backups] = estimate(backups, complete: complete)

        complete = true
        let libraryChildren = locations.library.map { children($0, complete: &complete) } ?? []
        let managed = libraryChildren.filter { StorageMediaCleanup.isManagedContainer($0, locations: locations) }
        var packages: [URL] = []
        for container in managed {
            let savedPaths = Set(StorageMediaCleanup.references(in: locations.documents, under: container).map { classifier.normalizedPath($0.1.path) })
            func findPackages(_ directory: URL) {
                for file in children(directory, complete: &complete) {
                    guard let values = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { continue }
                    guard values.isDirectory == true else { continue }
                    if file.pathExtension.lowercased() == "movpkg" {
                        if !savedPaths.contains(classifier.normalizedPath(file.path)) { packages.append(file) }
                    } else { findPackages(file) }
                }
            }
            findPackages(container)
        }
        result[.offlineMedia] = estimate(packages, complete: complete)

        complete = true
        let caches = children(locations.caches, complete: &complete)
        let systemRoots = (caches + libraryChildren).filter { StorageOtherCleanup.canClearCache($0, locations: locations) }
        let protected = StorageMediaCleanup.openFilePaths()
        let cutoff = Date()
        var visited = Set<String>()
        let systemBytes = systemRoots.reduce(Int64(0)) { total, root in
            StorageUsageService.adding(total, size(root, visited: &visited, complete: &complete) { file, info in
                let path = self.classifier.normalizedPath(file.path)
                guard self.classifier.category(file.appendingPathComponent(".probe").path) == .otherData,
                      !protected.contains(path) else { return false }
                if info.isDirectory == true { return true }
                let name = file.lastPathComponent.lowercased()
                return !["sqlite", "sqlite3", "db", "mdb"].contains(file.pathExtension.lowercased())
                    && !name.hasSuffix("-wal") && !name.hasSuffix("-shm") && !name.hasSuffix("-journal")
                    && (info.contentModificationDate ?? .distantFuture) < cutoff
            })
        }
        result[.systemCaches] = .init(bytes: complete ? systemBytes : nil, isEstimated: true)
        return result
    }

    private func children(_ directory: URL, skipHidden: Bool = false, complete: inout Bool) -> [URL] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        do {
            guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return [] }
            return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: skipHidden ? [.skipsHiddenFiles] : [])
        } catch { complete = false; return [] }
    }

    private func estimate(_ roots: [URL], followingReferences: Bool = false, complete known: Bool = true) -> StorageCleanupEstimate {
        var complete = known, visited = Set<String>()
        let bytes = roots.reduce(Int64(0)) { StorageUsageService.adding($0, size($1, visited: &visited, complete: &complete, followingReferences: followingReferences)) }
        return .init(bytes: complete ? bytes : nil, isEstimated: true)
    }

    private func size(_ file: URL, visited: inout Set<String>, complete: inout Bool, followingReferences: Bool = false,
                      include: ((URL, URLResourceValues) -> Bool)? = nil) -> Int64 {
        guard !Task.isCancelled, manager.fileExists(atPath: file.path) else { return 0 }
        do {
            let info = try file.resourceValues(forKeys: keys)
            guard info.isSymbolicLink != true, visited.insert(classifier.normalizedPath(file.path)).inserted,
                  include?(file, info) != false else { return 0 }
            if info.isDirectory == true {
                return children(file, complete: &complete).reduce(0) {
                    StorageUsageService.adding($0, size($1, visited: &visited, complete: &complete, followingReferences: followingReferences, include: include))
                }
            }
            guard info.isRegularFile == true else { return 0 }
            var bytes = Int64(max(0, info.totalFileAllocatedSize ?? info.fileAllocatedSize ?? info.fileSize ?? 0))
            if followingReferences, file.pathExtension.lowercased() == OfflineHLSReference.fileExtension,
               (info.fileSize ?? Int.max) <= 1024 * 1024, let package = try? OfflineHLSReference.packageURL(for: file) {
                bytes = StorageUsageService.adding(bytes, size(package, visited: &visited, complete: &complete))
            }
            return bytes
        } catch { complete = false; return 0 }
    }
}
