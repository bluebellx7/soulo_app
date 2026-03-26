import Foundation
import SwiftData

struct BookmarkService {

    // MARK: - Add

    static func add(title: String, url: String, platformName: String?, context: ModelContext) {
        let item = BookmarkItem(title: title, urlString: url, platformName: platformName)
        context.insert(item)
        try? context.save()
    }

    // MARK: - Delete

    static func delete(_ item: BookmarkItem, context: ModelContext) {
        context.delete(item)
        try? context.save()
    }

    // MARK: - Fetch All

    static func fetchAll(context: ModelContext) -> [BookmarkItem] {
        let descriptor = FetchDescriptor<BookmarkItem>(
            sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Clear All

    static func clearAll(in context: ModelContext) throws {
        let descriptor = FetchDescriptor<BookmarkItem>()
        let all = try context.fetch(descriptor)
        for item in all {
            context.delete(item)
        }
        try context.save()
    }

    // MARK: - Is Bookmarked

    static func isBookmarked(url: String, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<BookmarkItem>(
            predicate: #Predicate { item in
                item.urlString == url
            }
        )
        let results = (try? context.fetch(descriptor)) ?? []
        return !results.isEmpty
    }

    // MARK: - Toggle Bookmark

    @discardableResult
    static func toggleBookmark(title: String, url: String, platformName: String?, context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<BookmarkItem>(
            predicate: #Predicate { item in
                item.urlString == url
            }
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        if let item = existing.first {
            context.delete(item)
            try? context.save()
            return false
        } else {
            let newItem = BookmarkItem(title: title, urlString: url, platformName: platformName)
            context.insert(newItem)
            try? context.save()
            return true
        }
    }
}
