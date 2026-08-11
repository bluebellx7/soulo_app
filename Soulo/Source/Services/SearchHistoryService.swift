import Foundation
import SwiftData

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

    static func addEntry(keyword: String, platformID: UUID?, context: ModelContext) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check for duplicate keyword within the last minute
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        if let existing = try? context.fetch(descriptor), existing.contains(where: {
            !$0.isWebVisit && $0.keyword == trimmed && $0.timestamp >= oneMinuteAgo
        }) {
            return
        }

        let item = SearchHistoryItem(keyword: trimmed, platformID: platformID)
        context.insert(item)
        try? context.save()
    }

    // MARK: - Fetch Recent

    static func fetchRecent(limit: Int = 20, context: ModelContext) -> [SearchHistoryItem] {
        let descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return Array(all.prefix(max(limit, 0)))
    }

    // MARK: - Browsing History

    /// Records a completed HTTP(S) page visit. Repeated visits update the same
    /// URL entry so reloads and WebKit progress callbacks do not create noise.
    static func recordWebVisit(
        url: URL,
        title: String?,
        visitedAt: Date = Date(),
        context: ModelContext
    ) {
        guard let canonicalURL = canonicalHistoryURLString(for: url) else { return }

        purgeExpiredBrowsingHistory(referenceDate: visitedAt, context: context, save: false)

        let descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        let all = (try? context.fetch(descriptor)) ?? []
        let matches = all.filter { $0.visitedURLString == canonicalURL }
        let displayTitle = normalizedPageTitle(title, url: url)

        if let existing = matches.first {
            existing.keyword = displayTitle
            existing.timestamp = visitedAt
            for duplicate in matches.dropFirst() {
                context.delete(duplicate)
            }
        } else {
            context.insert(
                SearchHistoryItem(
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
        context: ModelContext
    ) {
        purgeExpiredBrowsingHistory(referenceDate: referenceDate, context: context, save: true)
    }

    static func clearBrowsingHistory(context: ModelContext) {
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        guard let all = try? context.fetch(descriptor) else { return }
        for item in all where item.isWebVisit {
            context.delete(item)
        }
        try? context.save()
    }

    static func isVisibleInHistory(_ item: SearchHistoryItem, referenceDate: Date = Date()) -> Bool {
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
        components.fragment = nil
        if let queryItems = components.queryItems {
            let stableItems = queryItems.filter { item in
                let name = item.name.lowercased()
                return !transientQueryNames.contains(name)
                    && !name.hasPrefix("utm_")
                    && name != "fbclid"
                    && name != "gclid"
            }
            components.queryItems = stableItems.isEmpty ? nil : stableItems
        }
        return components.url?.absoluteString
    }

    // MARK: - Delete Entry

    static func deleteEntry(_ item: SearchHistoryItem, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    // MARK: - Clear All

    static func clearAll(context: ModelContext) {
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        guard let all = try? context.fetch(descriptor) else { return }
        for item in all {
            context.delete(item)
        }
        try? context.save()
    }

    /// Alias for PrivacySettingsView (throws version)
    static func clearAll(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        let all = try context.fetch(descriptor)
        for item in all {
            context.delete(item)
        }
        try context.save()
    }

    // MARK: - Suggestions

    static func suggestions(prefix: String, context: ModelContext) -> [String] {
        let lowercased = prefix.lowercased()
        let descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
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
        context: ModelContext,
        save: Bool
    ) {
        let cutoff = referenceDate.addingTimeInterval(-browsingHistoryLifetime)
        let descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
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
