import XCTest
import SwiftData
@testable import Soulo

final class BookmarkImportExportTests: XCTestCase {
    private let chrome = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>
    <DL><p>
      <DT><H3 ADD_DATE="1700000000" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
      <DL><p>
        <DT><H3 ADD_DATE="1700000001">研究 &amp; 工作</H3>
        <DL><p>
          <DT><A HREF="https://example.com/?a=1&amp;b=2#part" ADD_DATE="1700000002" ICON="data:image/png;base64,ignored">中文 &#128218; &lt;资料&gt;</A>
          <DT><A HREF="javascript:alert(1)">Bookmarklet</A>
        </DL><p>
        <DT><H3>Empty folder</H3><DL><p></DL><p>
      </DL><p>
      <DT><A HREF="https://root.example/">Root</A>
    </DL><p>
    """

    func testChromeHierarchyEntitiesEmptyFoldersAndUnsupportedLinks() throws {
        let archive = try BookmarkHTML.parse(Data(chrome.utf8))
        XCTAssertEqual(archive.folders.map(\.title), ["Bookmarks bar", "研究 & 工作", "Empty folder"])
        XCTAssertNil(archive.folders[0].parentID)
        XCTAssertEqual(archive.folders[1].parentID, archive.folders[0].id)
        XCTAssertEqual(archive.folders[2].parentID, archive.folders[0].id)
        XCTAssertEqual(archive.links.count, 2)
        XCTAssertEqual(archive.links[0].folderID, archive.folders[1].id)
        XCTAssertEqual(archive.links[0].url, "https://example.com/?a=1&b=2#part")
        XCTAssertEqual(archive.links[0].title, "中文 📚 <资料>")
        XCTAssertEqual(archive.links[0].dateAdded.timeIntervalSince1970, 1700000002)
        XCTAssertNil(archive.links[1].folderID)
        XCTAssertEqual(archive.skipped, 1)
    }

    func testEdgeLowercaseSingleQuotedAttributesAndUTF16() throws {
        let edge = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1><dl><p><dt><h3 personal_toolbar_folder='true'>Favorites bar</h3>
        <dl><dt><a href='https://example.org/?q=x>y&amp;b=2' add_date='1680000000'>A &quot;B&quot; &amp;amp;</a></dl>
        <!-- <a href="https://bad.example">ignore</a> -->
        <script>"<a href='https://bad.example'>bad</a>"</script></dl>
        """
        for data in [Data(edge.utf8), try XCTUnwrap(edge.data(using: .utf16))] {
            let archive = try BookmarkHTML.parse(data)
            XCTAssertEqual(archive.links.count, 1)
            XCTAssertEqual(archive.links[0].title, "A \"B\" &amp;")
            XCTAssertEqual(archive.links[0].folderID, archive.folders.first?.id)
        }
    }

    func testExportRoundTripPreservesFoldersLinksAndEscapes() throws {
        let source = try BookmarkHTML.parse(Data(chrome.utf8))
        let data = BookmarkHTML.encode(source)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).hasPrefix("<!DOCTYPE NETSCAPE-Bookmark-file-1>"))
        let imported = try BookmarkHTML.parse(data)
        XCTAssertEqual(imported.folders.map(\.title), source.folders.map(\.title))
        XCTAssertEqual(imported.links.map(\.url), source.links.map(\.url))
        XCTAssertEqual(imported.links.map(\.title), source.links.map(\.title))
        for (actual, expected) in zip(imported.links, source.links) {
            XCTAssertEqual(actual.dateAdded.timeIntervalSince1970, expected.dateAdded.timeIntervalSince1970, accuracy: 1)
        }
        XCTAssertEqual(imported.links[0].folderID, imported.folders[1].id)
        XCTAssertEqual(imported.skipped, 0)
    }

    func testInvalidAndOversizedInputDoNotPartiallyImport() throws {
        XCTAssertThrowsError(try BookmarkHTML.parse(Data("<html><a href='https://example.com'>Not a bookmark file</a></html>".utf8)))
        XCTAssertThrowsError(try BookmarkHTML.parse(Data(repeating: 65, count: BookmarkHTML.maximumBytes + 1)))
        let deep = String(repeating: "<DL><H3>Nested</H3>", count: 66)
        XCTAssertThrowsError(try BookmarkHTML.parse(Data(deep.utf8)))
        let empty = try BookmarkHTML.parse(Data("<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p></DL>".utf8))
        XCTAssertTrue(empty.links.isEmpty)
    }

    func testExportDoesNotDropDeepOrDetachedContents() throws {
        var archive = BookmarkArchive()
        var parent: UUID?
        for index in 0..<100 {
            let folder = BookmarkArchive.Folder(parentID: parent, title: "Level \(index)", dateAdded: Date(timeIntervalSince1970: 1))
            archive.folders.append(folder)
            parent = folder.id
        }
        archive.links.append(.init(folderID: parent, title: "Deep", url: "https://deep.example", dateAdded: Date()))
        archive.links.append(.init(folderID: UUID(), title: "Detached", url: "https://detached.example", dateAdded: Date()))
        let html = String(decoding: BookmarkHTML.encode(archive), as: UTF8.self)
        XCTAssertTrue(html.contains("https://deep.example"))
        XCTAssertTrue(html.contains("https://detached.example"))
        XCTAssertEqual(html.components(separatedBy: "<DT><H3").count - 1, 100)
    }

    @MainActor
    func testImportMergeDeduplicationAndFolderRemovalPreserveContents() throws {
        let container = try ModelContainer(for: BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let existing = BookmarkItem(title: "Existing", urlString: "https://existing.example")
        context.insert(existing)
        let source = try BookmarkHTML.parse(Data(chrome.utf8))
        let first = try BookmarkLibraryService.importArchive(source, into: nil, context: context)
        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(first.folders, 3)
        let again = try BookmarkLibraryService.importArchive(try BookmarkHTML.parse(Data(chrome.utf8)), into: nil, context: context)
        XCTAssertEqual(again.added, 0)
        XCTAssertEqual(again.folders, 0)
        XCTAssertEqual(again.duplicates, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkItem>()), 3)
        let folders = try context.fetch(FetchDescriptor<BookmarkFolder>())
        let bar = try XCTUnwrap(folders.first { $0.title == "Bookmarks bar" })
        try BookmarkLibraryService.removeFolder(bar, context: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkItem>()), 3)
        XCTAssertTrue(try context.fetch(FetchDescriptor<BookmarkFolder>()).allSatisfy { $0.parentID == nil })
        XCTAssertEqual(existing.title, "Existing")
        let exported = try BookmarkLibraryService.archive(context: context)
        XCTAssertEqual(try BookmarkHTML.parse(BookmarkHTML.encode(exported)).links.count, 3)
        try BookmarkService.clearAll(in: context)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkItem>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BookmarkFolder>()), 0)
    }

    @MainActor
    func testImportIntoSelectedFolderAndSameURLInDifferentFolders() throws {
        let container = try ModelContainer(for: BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let destination = BookmarkFolder(title: "Imported")
        context.insert(destination)
        let source = try BookmarkHTML.parse(Data(chrome.utf8))
        _ = try BookmarkLibraryService.importArchive(source, into: nil, context: context)
        let result = try BookmarkLibraryService.importArchive(source, into: destination.id, context: context)
        XCTAssertEqual(result.added, 2)
        XCTAssertEqual(result.duplicates, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<BookmarkItem>()).filter { $0.folderID == destination.id }.count, 1)
    }

    @MainActor
    func testExistingOnDiskBookmarksMigrateWithoutLosingData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("bookmarks.store")
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1680000000)
        try autoreleasepool {
            let old = try ModelContainer(for: LegacyBookmarks.BookmarkItem.self,
                configurations: ModelConfiguration(url: url))
            let item = LegacyBookmarks.BookmarkItem(title: "旧收藏", urlString: "https://existing.example/?a=1&b=2")
            item.id = id; item.dateAdded = date; item.platformName = "Example"
            item.faviconData = Data([1, 2, 3])
            old.mainContext.insert(item)
            try old.mainContext.save()
        }
        let updated = try ModelContainer(for: BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration(url: url))
        let items = try updated.mainContext.fetch(FetchDescriptor<BookmarkItem>())
        let saved = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(saved.id, id)
        XCTAssertEqual(saved.title, "旧收藏")
        XCTAssertEqual(saved.dateAdded, date)
        XCTAssertEqual(saved.platformName, "Example")
        XCTAssertEqual(saved.faviconData, Data([1, 2, 3]))
        XCTAssertNil(saved.folderID)
    }
}

private enum LegacyBookmarks {
    @Model final class BookmarkItem {
        var id: UUID
        var title: String
        var urlString: String
        var platformName: String?
        var dateAdded: Date
        @Attribute(.externalStorage) var faviconData: Data?
        init(title: String, urlString: String) {
            id = UUID(); self.title = title; self.urlString = urlString; dateAdded = Date()
        }
    }
}
