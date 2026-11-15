import Foundation
import CoreData
import CoreSpotlight

struct BookmarkService {
    static var sortDescriptors: [NSSortDescriptor] { [NSSortDescriptor(key: "sortOrder", ascending: true), NSSortDescriptor(key: "dateAdded", ascending: false), NSSortDescriptor(key: "id", ascending: true)] }

    /// A filtered grid reorders only its own slots in the full bookmark order.
    /// Persist once on drop, rather than saving repeatedly while the finger moves.
    static func reorder(_ ids: [UUID], context: NSManagedObjectContext) throws {
        let all = try context.fetch(BookmarkRecord.request(sortBy: sortDescriptors))
        let records = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let unique = Set(ids)
        guard unique.count == ids.count, unique.isSubset(of: Set(records.keys)) else { return }
        var replacement = ids.makeIterator()
        let ordered = all.map { unique.contains($0.id) ? records[replacement.next()!]! : $0 }
        for (index, item) in ordered.enumerated() where item.sortOrder != Int64(index + 1) { item.sortOrder = Int64(index + 1) }
        if context.hasChanges { try context.save() }
    }
    /// Starred bookmarks from any folder win; otherwise use the newest saved
    /// pages. Do not show duplicate URLs or non-web links on the landing page.
    static func quickLinks(from bookmarks: [BookmarkRecord], limit: Int = 8) -> [BookmarkRecord] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [BookmarkRecord] = []
        func append(_ item: BookmarkRecord) {
            guard let url = item.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
                  seen.insert(item.urlString).inserted else { return }
            result.append(item)
        }
        for item in bookmarks where item.isFavorite {
            append(item)
            if result.count == limit { return result }
        }
        if !result.isEmpty { return result }
        for item in bookmarks {
            append(item)
            if result.count == limit { break }
        }
        return result
    }

    // MARK: - Add

    static func add(title: String, url: String, platformName: String?, context: NSManagedObjectContext) {
        let item = BookmarkRecord(title: title, urlString: url, platformName: platformName)
        context.insert(item)
        try? context.save()
    }

    // MARK: - Delete

    static func delete(_ item: BookmarkRecord, context: NSManagedObjectContext) {
        context.delete(item)
        try? context.save()
    }

    // MARK: - Fetch All

    static func fetchAll(context: NSManagedObjectContext) -> [BookmarkRecord] {
        let descriptor = BookmarkRecord.request(
            sortBy: [NSSortDescriptor(key: "dateAdded", ascending: false)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Clear All

    static func clearAll(in context: NSManagedObjectContext, index: CSSearchableIndex = .default()) throws {
        let descriptor = BookmarkRecord.request()
        let all = try context.fetch(descriptor)
        for item in all {
            context.delete(item)
        }
        for folder in try context.fetch(BookmarkFolderRecord.request()) {
            context.delete(folder)
        }
        try context.save()
        SpotlightIndexingService.deindexAll(domain: "soulo.bookmarks", index: index)
    }

    // MARK: - Is Bookmarked

    static func isBookmarked(url: String, context: NSManagedObjectContext) -> Bool {
        var descriptor = BookmarkRecord.request(
            predicate: NSPredicate(format: "urlString == %@", url)
        )
        descriptor.fetchLimit = 1
        let results = (try? context.fetch(descriptor)) ?? []
        return !results.isEmpty
    }

    // MARK: - Toggle Bookmark

    @discardableResult
    static func toggleBookmark(title: String, url: String, platformName: String?, context: NSManagedObjectContext) -> Bool {
        let descriptor = BookmarkRecord.request(
            predicate: NSPredicate(format: "urlString == %@", url)
        )
        let existing = (try? context.fetch(descriptor)) ?? []

        if let item = existing.first {
            context.delete(item)
            try? context.save()
            return false
        } else {
            let newItem = BookmarkRecord(title: title, urlString: url, platformName: platformName)
            context.insert(newItem)
            try? context.save()
            return true
        }
    }
}
