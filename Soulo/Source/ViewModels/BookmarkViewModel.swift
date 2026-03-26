import SwiftUI
import SwiftData

@MainActor
class BookmarkViewModel: ObservableObject {
    @Published var bookmarks: [BookmarkItem] = []

    func loadBookmarks(context: ModelContext) {
        bookmarks = BookmarkService.fetchAll(context: context)
    }

    func addBookmark(title: String, url: String, platformName: String?, context: ModelContext) {
        BookmarkService.add(title: title, url: url, platformName: platformName, context: context)
        loadBookmarks(context: context)
    }

    func deleteBookmark(_ item: BookmarkItem, context: ModelContext) {
        BookmarkService.delete(item, context: context)
        loadBookmarks(context: context)
    }

    func isBookmarked(url: String, context: ModelContext) -> Bool {
        BookmarkService.isBookmarked(url: url, context: context)
    }

    func toggleBookmark(title: String, url: String, platformName: String?, context: ModelContext) -> Bool {
        let result = BookmarkService.toggleBookmark(title: title, url: url, platformName: platformName, context: context)
        loadBookmarks(context: context)
        return result
    }
}
