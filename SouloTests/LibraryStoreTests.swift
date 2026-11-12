import CoreData
import SwiftData
import XCTest
@testable import Soulo

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testExistingSwiftDataLibraryMigratesAndDeletedItemsStayDeleted() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Legacy SwiftData libraries require iOS 17") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("library.sqlite")
        let bookmarkID = UUID(), folderID = UUID(), historyID = UUID()
        let date = Date(timeIntervalSince1970: 1_680_000_000)
        let favicon = Data(repeating: 17, count: 2 * 1024 * 1024)
        try autoreleasepool {
            let legacy = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL))
            let folder = BookmarkFolder(title: "Saved folder")
            folder.id = folderID
            folder.dateAdded = date
            let bookmark = BookmarkItem(title: "Saved page", urlString: "https://example.com/?a=1&b=2", platformName: "Example")
            bookmark.id = bookmarkID
            bookmark.folderID = folderID
            bookmark.dateAdded = date
            bookmark.faviconData = favicon
            let history = SearchHistoryItem(keyword: "Saved visit", platformID: UUID(), timestamp: date,
                visitedURLString: "https://example.com/")
            history.id = historyID
            legacy.mainContext.insert(folder)
            legacy.mainContext.insert(bookmark)
            legacy.mainContext.insert(history)
            try legacy.mainContext.save()
        }
        try autoreleasepool {
            let library = try LibraryStore(url: destination, legacyURL: legacyURL)
            let context = library.mainContext
            let bookmark = try XCTUnwrap(context.fetch(BookmarkRecord.request()).first)
            XCTAssertEqual(bookmark.id, bookmarkID)
            XCTAssertEqual(bookmark.folderID, folderID)
            XCTAssertEqual(bookmark.dateAdded, date)
            XCTAssertEqual(bookmark.faviconData, favicon)
            XCTAssertEqual(bookmark.platformName, "Example")
            let folder = try XCTUnwrap(context.fetch(BookmarkFolderRecord.request()).first)
            XCTAssertEqual(folder.id, folderID)
            XCTAssertEqual(folder.title, "Saved folder")
            let history = try XCTUnwrap(context.fetch(SearchHistoryRecord.request()).first)
            XCTAssertEqual(history.id, historyID)
            XCTAssertEqual(history.timestamp, date)
            XCTAssertEqual(history.visitedURLString, "https://example.com/")
            context.delete(bookmark)
            try context.save()
            try close(library)
        }
        try autoreleasepool {
            // Core Data can leave a truncated SQLite file after destruction.
            // Verify its records are gone, then simulate a stale source being
            // restored from backup: the migration marker must prevent revival.
            let retired = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL))
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<BookmarkItem>()), 0)
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<BookmarkFolder>()), 0)
            XCTAssertEqual(try retired.mainContext.fetchCount(FetchDescriptor<SearchHistoryItem>()), 0)
            let stale = BookmarkItem(title: "Deleted bookmark", urlString: "https://example.com/")
            stale.id = bookmarkID
            retired.mainContext.insert(stale)
            try retired.mainContext.save()
        }
        let reopened = try LibraryStore(url: destination, legacyURL: legacyURL)
        XCTAssertEqual(try reopened.mainContext.count(for: BookmarkRecord.request()), 0)
        XCTAssertEqual(try reopened.mainContext.count(for: BookmarkFolderRecord.request()), 1)
        XCTAssertEqual(try reopened.mainContext.count(for: SearchHistoryRecord.request()), 1)
        try close(reopened)
    }

    func testFailedLegacyImportPreservesSourceAndCanRetry() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Legacy SwiftData libraries require iOS 17") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacyURL = directory.appendingPathComponent("default.store")
        let destination = directory.appendingPathComponent("library.sqlite")
        let invalid = Data("Unreadable legacy library".utf8)
        try invalid.write(to: legacyURL)
        XCTAssertThrowsError(try LibraryStore(url: destination, legacyURL: legacyURL))
        XCTAssertEqual(try Data(contentsOf: legacyURL), invalid)
        try FileManager.default.removeItem(at: legacyURL)
        try autoreleasepool {
            let legacy = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
                configurations: ModelConfiguration(url: legacyURL))
            legacy.mainContext.insert(BookmarkItem(title: "Recovered", urlString: "https://example.com/"))
            try legacy.mainContext.save()
        }
        let recovered = try LibraryStore(url: destination, legacyURL: legacyURL)
        XCTAssertEqual(try recovered.mainContext.fetch(BookmarkRecord.request()).map(\.title), ["Recovered"])
        try close(recovered)
    }

    private func close(_ library: LibraryStore) throws {
        library.mainContext.reset()
        for store in library.container.persistentStoreCoordinator.persistentStores {
            try library.container.persistentStoreCoordinator.remove(store)
        }
    }

    func testRollbackRestoresBookmarkChanges() throws {
        let library = try LibraryStore(inMemory: true)
        let bookmark = BookmarkRecord(title: "Original", urlString: "https://example.com/")
        library.mainContext.insert(bookmark)
        try library.mainContext.save()
        bookmark.title = "Unsaved"
        bookmark.folderID = UUID()
        library.mainContext.rollback()
        XCTAssertEqual(bookmark.title, "Original")
        XCTAssertNil(bookmark.folderID)
    }
}
