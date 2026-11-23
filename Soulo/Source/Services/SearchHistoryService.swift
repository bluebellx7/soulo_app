import Foundation
import CoreData
import CoreSpotlight
import UIKit

struct SearchHistoryService {
    static let browsingHistoryLifetime: TimeInterval = 3 * 24 * 60 * 60
    private static let transientQueryNames: Set<String> = [
        "douyin_web_id",
        "innerheight",
        "innerwidth",
        "is_no_width_reload",
        "reload_from",
        "reloadnavstart",
    ]

    // MARK: - Add Entry

    @discardableResult
    static func addEntry(keyword: String, platformID: UUID?, context: NSManagedObjectContext,
                         searchedAt: Date = Date()) -> SearchHistoryRecord? {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let platform = platformID.map { NSPredicate(format: "platformID == %@", $0 as NSUUID) }
            ?? NSPredicate(format: "platformID == nil")
        let request = SearchHistoryRecord.request(
            predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "visitedURLString == nil AND keyword ==[c] %@", trimmed), platform
            ]),
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        guard let matches = try? context.fetch(request) else { return nil }
        let item: SearchHistoryRecord
        if let latest = matches.first {
            item = latest
            if searchedAt >= latest.timestamp {
                latest.keyword = trimmed
                latest.timestamp = searchedAt
            }
        } else {
            item = SearchHistoryRecord(keyword: trimmed, platformID: platformID, timestamp: searchedAt)
            context.insert(item)
        }
        let duplicates = matches.dropFirst()
        let identifiers = duplicates.map { "search-history-\($0.id.uuidString)" }
        duplicates.forEach { context.delete($0) }
        do {
            try context.save()
            if !identifiers.isEmpty {
                CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: identifiers, completionHandler: nil)
            }
            return item
        } catch {
            return nil
        }
    }

    // MARK: - Fetch Recent

    static func fetchRecent(limit: Int = 20, context: NSManagedObjectContext) -> [SearchHistoryRecord] {
        guard limit > 0 else { return [] }
        var descriptor = SearchHistoryRecord.request(
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Fetch only search terms, stopping once the home page has enough unique
    /// chips. Browsing visits can greatly outnumber searches in the same store.
    static func recentSearchKeywords(limit: Int = 20, context: NSManagedObjectContext) -> [String] {
        guard limit > 0 else { return [] }
        var descriptor = SearchHistoryRecord.request(
            predicate: NSPredicate(format: "visitedURLString == nil"),
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        let batchSize = 64
        descriptor.fetchLimit = batchSize
        var seen = Set<String>()
        var results: [String] = []
        while let batch = try? context.fetch(descriptor), !batch.isEmpty {
            for item in batch where seen.insert(item.keyword).inserted {
                results.append(item.keyword)
                if results.count == limit { return results }
            }
            if batch.count < batchSize { break }
            descriptor.fetchOffset = descriptor.fetchOffset + batch.count
        }
        return results
    }

    // MARK: - Browsing History

    /// Records a completed HTTP(S) page visit. Repeated visits update the same
    /// URL entry so reloads and WebKit progress callbacks do not create noise.
    @MainActor static func recordWebVisit(
        url: URL,
        title: String?,
        visitedAt: Date = Date(),
        usedVideoTools: Bool = false,
        context: NSManagedObjectContext
    ) {
        guard !(UserDefaults.standard.bool(forKey: BrowsingHistoryExitPolicy.preferenceKey)
                && UIApplication.shared.applicationState == .background) else { return }
        guard let canonicalURL = canonicalHistoryURLString(for: url) else { return }

        // The hot path runs when a page finishes loading. Do not materialize
        // and parse the entire library for every visit. History's maintenance
        // pass still normalizes legacy URLs and merges old duplicates.
        let cutoff = visitedAt.addingTimeInterval(-browsingHistoryLifetime)
        let expired = SearchHistoryRecord.request(predicate: NSPredicate(format: "visitedURLString != nil AND timestamp < %@", cutoff as NSDate))
        if let entries = try? context.fetch(expired) {
            entries.forEach { context.delete($0) }
        }

        let descriptor = SearchHistoryRecord.request(
            predicate: NSPredicate(format: "visitedURLString == %@", canonicalURL),
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        let matches = (try? context.fetch(descriptor)) ?? []
        let displayTitle = normalizedPageTitle(title, url: url)

        if let existing = matches.first {
            if visitedAt >= existing.timestamp {
                // A load-progress callback can arrive before WebKit supplies the title.
                if let displayTitle { existing.keyword = displayTitle }
                existing.timestamp = visitedAt
            }
            if !existing.usedVideoTools {
                existing.usedVideoTools = usedVideoTools || matches.dropFirst().contains(where: \.usedVideoTools)
            }
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            let item = SearchHistoryRecord(keyword: displayTitle ?? url.host ?? url.absoluteString,
                                           timestamp: visitedAt, visitedURLString: canonicalURL)
            item.usedVideoTools = usedVideoTools
            context.insert(item)
        }
        try? context.save()
    }

    static func purgeExpiredBrowsingHistory(
        referenceDate: Date = Date(),
        context: NSManagedObjectContext
    ) {
        purgeExpiredBrowsingHistory(referenceDate: referenceDate, context: context, save: true)
    }

    static func clearBrowsingHistory(context: NSManagedObjectContext) {
        let descriptor = SearchHistoryRecord.request(predicate: NSPredicate(format: "visitedURLString != nil"))
        guard let all = try? context.fetch(descriptor) else { return }
        for item in all where item.isWebVisit {
            context.delete(item)
        }
        try? context.save()
    }

    static func isVisibleInHistory(_ item: SearchHistoryRecord, referenceDate: Date = Date()) -> Bool {
        guard item.isWebVisit else { return true }
        return item.timestamp >= referenceDate.addingTimeInterval(-browsingHistoryLifetime)
    }

    enum EntryIdentity: Hashable {
        case page(String)
        case search(String, UUID?)
    }

    static func identity(of entry: SearchHistoryRecord) -> EntryIdentity {
        if let address = entry.visitedURLString {
            return .page(URL(string: address).flatMap(canonicalHistoryURLString(for:)) ?? address)
        }
        return .search(entry.keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), entry.platformID)
    }

    static func canonicalHistoryURLString(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }

        components.scheme = scheme
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        if let queryItems = components.percentEncodedQueryItems {
            let stableItems = queryItems.filter { item in
                let name = (item.name.removingPercentEncoding ?? item.name).lowercased()
                return !transientQueryNames.contains(name)
                    && !name.hasPrefix("utm_")
                    && name != "fbclid"
                    && name != "gclid"
            }
            components.percentEncodedQueryItems = stableItems.isEmpty ? nil : stableItems
        }
        return components.url?.absoluteString
    }

    // MARK: - Delete Entry

    static func deleteEntry(_ item: SearchHistoryRecord, context: NSManagedObjectContext, index: CSSearchableIndex = .default()) {
        let identifier = "search-history-\(item.id.uuidString)"
        context.delete(item)
        do {
            try context.save()
            SpotlightIndexingService.deindexItem(id: identifier, index: index)
        } catch {}
    }

    // MARK: - Clear All

    static func clearAll(context: NSManagedObjectContext, index: CSSearchableIndex = .default()) {
        try? clearAll(in: context, index: index)
    }

    /// Alias for PrivacySettingsView (throws version)
    static func clearAll(in context: NSManagedObjectContext, index: CSSearchableIndex = .default()) throws {
        let descriptor = SearchHistoryRecord.request()
        let all = try context.fetch(descriptor)
        for item in all {
            context.delete(item)
        }
        try context.save()
        SpotlightIndexingService.deindexAll(domain: "soulo.history", index: index)
    }

    // MARK: - Suggestions

    static func suggestions(prefix: String, context: NSManagedObjectContext) -> [String] {
        let lowercased = prefix.lowercased()
        let descriptor = SearchHistoryRecord.request(
            predicate: NSPredicate(format: "visitedURLString == nil"),
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        guard let all = try? context.fetch(descriptor) else { return [] }

        var seen = Set<String>()
        var results: [String] = []

        for item in all {
            guard !item.isWebVisit else { continue }
            let keyword = item.keyword
            guard keyword.lowercased().contains(lowercased) else { continue }
            guard !seen.contains(keyword) else { continue }
            seen.insert(keyword)
            results.append(keyword)
            if results.count >= 10 { break }
        }

        return results
    }

    private static func purgeExpiredBrowsingHistory(
        referenceDate: Date,
        context: NSManagedObjectContext,
        save: Bool
    ) {
        let cutoff = referenceDate.addingTimeInterval(-browsingHistoryLifetime)
        let descriptor = SearchHistoryRecord.request(
            predicate: NSPredicate(format: "visitedURLString != nil"),
            sortBy: [NSSortDescriptor(key: "timestamp", ascending: false)]
        )
        guard let all = try? context.fetch(descriptor) else { return }
        var changed = false
        var latestByURL: [String: SearchHistoryRecord] = [:]
        for item in all where item.isWebVisit {
            guard item.timestamp >= cutoff,
                  let storedURL = item.visitedURLString,
                  let url = URL(string: storedURL),
                  let canonicalURL = canonicalHistoryURLString(for: url)
            else {
                context.delete(item)
                changed = true
                continue
            }

            if let latest = latestByURL[canonicalURL] {
                if item.usedVideoTools, !latest.usedVideoTools { latest.usedVideoTools = true }
                context.delete(item)
                changed = true
                continue
            }
            latestByURL[canonicalURL] = item

            if storedURL != canonicalURL {
                item.visitedURLString = canonicalURL
                changed = true
            }
        }
        if save, changed {
            try? context.save()
        }
    }

    private static func normalizedPageTitle(_ title: String?, url: URL) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.caseInsensitiveCompare(url.absoluteString) != .orderedSame {
            return trimmed
        }
        return nil
    }
}

/// UIApplication's notification covers the whole process, unlike individual
/// iPad scenes. Also clear on launch because force-quitting has no callback.
@MainActor final class BrowsingHistoryExitPolicy {
    nonisolated static let preferenceKey = "privacy_clear_browsing_on_exit"
    private let container: NSPersistentContainer
    private let defaults: UserDefaults
    private let notifications: NotificationCenter
    private var observer: NSObjectProtocol?
    private var cleanup: Task<Void, Never>?

    init(container: NSPersistentContainer, defaults: UserDefaults = .standard,
         notifications: NotificationCenter = .default) {
        self.container = container; self.defaults = defaults; self.notifications = notifications
    }

    deinit {
        if let observer { notifications.removeObserver(observer) }
        cleanup?.cancel()
    }

    func start() {
        guard observer == nil else { return }
        observer = notifications.addObserver(forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, Self.shouldClear(enabled:self.defaults.bool(forKey:Self.preferenceKey),
                        state:UIApplication.shared.applicationState) else { return }
                    self.scheduleCleanup(inBackground:true)
                }
            }
        scheduleCleanup(inBackground:false)
    }

    static func shouldClear(enabled: Bool, state: UIApplication.State) -> Bool {
        enabled && state == .background
    }

    private func scheduleCleanup(inBackground: Bool) {
        guard defaults.bool(forKey:Self.preferenceKey), cleanup == nil else { return }
        let backgroundID = inBackground ? UIApplication.shared.beginBackgroundTask(withName:"Clear browsing history") { [weak self] in
            self?.cleanup?.cancel()
        } : .invalid
        cleanup = Task { [weak self] in
            defer { if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID) } }
            guard let self else { return }
            defer { self.cleanup = nil }
            do { _ = try await self.clearIfEnabled() }
            catch is CancellationError { }
            catch { BrowserStartupTrace.mark("history_exit_cleanup_failed") }
        }
    }

    /// Delete bounded batches off the UI queue. Preserve search terms,
    /// bookmarks, unsaved main-context edits and visits made after this pass.
    @discardableResult
    func clearIfEnabled(referenceDate: Date = Date(), index: CSSearchableIndex = .default()) async throws -> Int {
        guard defaults.bool(forKey:Self.preferenceKey) else { return 0 }
        let worker = container.newBackgroundContext()
        worker.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        worker.undoManager = nil
        var deleted = 0
        while defaults.bool(forKey:Self.preferenceKey) {
            try Task.checkCancellation()
            let identifiers: [String] = try await worker.perform {
                let request = SearchHistoryRecord.request(predicate:NSPredicate(format:"visitedURLString != nil AND timestamp <= %@",referenceDate as NSDate))
                request.fetchLimit = 256; request.fetchBatchSize = 256
                let rows = try worker.fetch(request)
                let identifiers = rows.map { "search-history-" + $0.id.uuidString }
                for row in rows { worker.delete(row) }
                if worker.hasChanges { try worker.save() }
                worker.reset()
                return identifiers
            }
            guard !identifiers.isEmpty else { break }
            index.deleteSearchableItems(withIdentifiers:identifiers, completionHandler:nil)
            deleted += identifiers.count
        }
        return deleted
    }
}
