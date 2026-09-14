import XCTest
@testable import Soulo

final class FileRenameTests: XCTestCase {
    func testRenamePreservesExtensionBytesAndRejectsOverwriteOrTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.M4A")
        let bytes = Data("original bytes".utf8)
        try bytes.write(to: original)
        let target = try LibraryFileActions.rename(original, baseName: " 新名字 ", in: root)
        XCTAssertEqual(target.lastPathComponent, "新名字.M4A")
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        try Data("keep".utf8).write(to: root.appendingPathComponent("existing.M4A"))
        for invalid in ["existing", "../escape", "a/b", ".hidden", "", "a\0b"] {
            XCTAssertThrowsError(try LibraryFileActions.rename(target, baseName: invalid, in: root))
        }
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("existing.M4A")), Data("keep".utf8))
    }

    @MainActor func testRenamedDownloadAndBookRetainIdentityAndReadingPositionAfterReload() async throws {
        let root = BookLibrary.directory
        let prefix = "Soulo-Rename-QA-" + UUID().uuidString
        let source = root.appendingPathComponent(prefix + ".txt")
        let target = root.appendingPathComponent(prefix + "-renamed.txt")
        let metadata = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + ".json")
        let suite = prefix
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: metadata); defaults.removePersistentDomain(forName: suite)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = BookLibrary(metadata: metadata)
        let manager = DownloadManagerService(userDefaults: defaults, storageKey: "downloads", storageDirectory: root)
        let (item, destination) = manager.beginDownload(suggestedFilename: source.lastPathComponent, sourceURL: URL(string: "https://example.com/book"))
        try Data("Chapter 1\nOriginal test book.".utf8).write(to: destination)
        manager.markFinished(id: item.id)
        let book = try await library.add(source)
        library.update(book.id, location: "chapter:1:42", fraction: 0.42)
        let moved = try LibraryFileActions.rename(source, baseName: prefix + "-renamed", in: root)
        try library.updateFileReference(bookIDs: [book.id], to: moved)
        manager.updateFileReference(from: source, to: moved)
        let restoredBook = try XCTUnwrap(BookLibrary(metadata: metadata).books.first)
        XCTAssertEqual(restoredBook.id, book.id)
        XCTAssertEqual(restoredBook.location, "chapter:1:42")
        XCTAssertEqual(restoredBook.fraction, 0.42)
        XCTAssertEqual(restoredBook.url.standardizedFileURL, moved.standardizedFileURL)
        let restoredManager = DownloadManagerService(userDefaults: defaults, storageKey: "downloads", storageDirectory: root)
        let restoredDownload = try XCTUnwrap(restoredManager.downloads.first)
        XCTAssertEqual(restoredDownload.id, item.id)
        XCTAssertEqual(restoredDownload.fileName, target.lastPathComponent)
        XCTAssertEqual(restoredDownload.localURL, target)
        XCTAssertEqual(restoredDownload.status, .finished)
    }
}
