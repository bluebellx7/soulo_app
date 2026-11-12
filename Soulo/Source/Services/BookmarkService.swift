import Foundation
import CoreData
import CoreSpotlight

struct BookmarkService {

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
