import Foundation
import CoreData
import CoreSpotlight

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

    static func addEntry(keyword: String, platformID: UUID?, context: NSManagedObjectContext) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check for duplicate keyword within the last minute
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        var descriptor = SearchHistoryRecord.request(predicate: NSPredicate(format: "visitedURLString == nil AND keyword == %@ AND timestamp >= %@", trimmed, oneMinuteAgo as NSDate))
        descriptor.fetchLimit = 1
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            return
        }

        let item = SearchHistoryRecord(keyword: trimmed, platformID: platformID)
        context.insert(item)
        try? context.save()
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
    static func recordWebVisit(
        url: URL,
        title: String?,
        visitedAt: Date = Date(),
        context: NSManagedObjectContext
    ) {
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
            existing.keyword = displayTitle
            existing.timestamp = visitedAt
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            context.insert(
                SearchHistoryRecord(
                    keyword: displayTitle,
                    timestamp: visitedAt,
                    visitedURLString: canonicalURL
                )
            )
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
        var seenURLs = Set<String>()
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

            if seenURLs.contains(canonicalURL) {
                context.delete(item)
                changed = true
                continue
            }
            seenURLs.insert(canonicalURL)

            if storedURL != canonicalURL {
                item.visitedURLString = canonicalURL
                changed = true
            }
        }
        if save, changed {
            try? context.save()
        }
    }

    private static func normalizedPageTitle(_ title: String?, url: URL) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty, trimmed.caseInsensitiveCompare(url.absoluteString) != .orderedSame {
            return trimmed
        }
        return url.host ?? url.absoluteString
    }
}
