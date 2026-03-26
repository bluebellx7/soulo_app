import Foundation
import SwiftData

struct SearchHistoryService {

    // MARK: - Add Entry

    static func addEntry(keyword: String, platformID: UUID?, context: ModelContext) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check for duplicate keyword within the last minute
        let oneMinuteAgo = Date().addingTimeInterval(-60)
        let descriptor = FetchDescriptor<SearchHistoryItem>(
            predicate: #Predicate { item in
                item.keyword == trimmed && item.timestamp >= oneMinuteAgo
            }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            return
        }

        let item = SearchHistoryItem(keyword: trimmed, platformID: platformID)
        context.insert(item)
        try? context.save()
    }

    // MARK: - Fetch Recent

    static func fetchRecent(limit: Int = 20, context: ModelContext) -> [SearchHistoryItem] {
        var descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
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
            let keyword = item.keyword
            guard keyword.lowercased().contains(lowercased) else { continue }
            guard !seen.contains(keyword) else { continue }
            seen.insert(keyword)
            results.append(keyword)
            if results.count >= 10 { break }
        }

        return results
    }
}
