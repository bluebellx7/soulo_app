import SwiftUI
import CoreData

@MainActor
class BookmarkViewModel: ObservableObject {
    @Published var bookmarks: [BookmarkRecord] = []

    func loadBookmarks(context: NSManagedObjectContext) {
        bookmarks = BookmarkService.fetchAll(context: context)
    }

    func addBookmark(title: String, url: String, platformName: String?, context: NSManagedObjectContext) {
        BookmarkService.add(title: title, url: url, platformName: platformName, context: context)
        loadBookmarks(context: context)
    }

    func deleteBookmark(_ item: BookmarkRecord, context: NSManagedObjectContext) {
        BookmarkService.delete(item, context: context)
        loadBookmarks(context: context)
    }

    func isBookmarked(url: String, context: NSManagedObjectContext) -> Bool {
        BookmarkService.isBookmarked(url: url, context: context)
    }

    func toggleBookmark(title: String, url: String, platformName: String?, context: NSManagedObjectContext) -> Bool {
        let result = BookmarkService.toggleBookmark(title: title, url: url, platformName: platformName, context: context)
        loadBookmarks(context: context)
        return result
    }
}
