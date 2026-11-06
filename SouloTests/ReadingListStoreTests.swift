import XCTest
@testable import Soulo

@MainActor
final class ReadingListStoreTests: XCTestCase {
    private var root: URL!
    private var fileURL: URL { root.appendingPathComponent("ApplicationSupport/ReadingList.json") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-list-" + UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func expectFailure(file: StaticString = #filePath, line: UInt = #line, _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected an error", file: file, line: line) }
        catch { }
    }

    func testSavedTextAndReadingPositionSurviveRestoringTheStore() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let text = "First paragraph\n\n第二段正文"
        try await store.save(url: url, title: "Article", text: text)
        let id = try XCTUnwrap(store.items.first).id
        try await store.updatePosition(id: id, paragraph: 1)
        let restoredStore = ReadingListStore(fileURL: fileURL)
        XCTAssertTrue(restoredStore.items.isEmpty, "Initialization does not synchronously load the archive")
        try await restoredStore.load()
        let restored = try XCTUnwrap(restoredStore.items.first)
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(restored.url, url)
        XCTAssertEqual(restored.title, "Article")
        XCTAssertEqual(restored.text, text)
        XCTAssertEqual(restored.paragraph, 1)
        XCTAssertNotNil(restored.lastOpenedAt)
    }

    func testSavingTheSameURLUpdatesInPlaceAndResetsTheOldPosition() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        try await store.save(url: url, title: "Before", text: "Original body")
        let previous = try XCTUnwrap(store.items.first)
        try await store.updatePosition(id: previous.id, paragraph: 6)
        try await store.save(url: url, title: "After", text: "Updated body")
        XCTAssertEqual(store.items.count, 1)
        let restored = ReadingListStore(fileURL: fileURL)
        try await restored.load()
        let updated = try XCTUnwrap(restored.items.first)
        XCTAssertEqual(updated.id, previous.id)
        XCTAssertEqual(updated.title, "After")
        XCTAssertEqual(updated.text, "Updated body")
        XCTAssertNil(updated.paragraph)
        XCTAssertGreaterThanOrEqual(updated.savedAt, previous.savedAt)
    }

    func testRemovingOnlyTheChosenArticleLeavesOtherRecordsAndSourceFilesIntact() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        let firstURL = try XCTUnwrap(URL(string: "https://example.com/one"))
        let secondURL = try XCTUnwrap(URL(string: "https://example.com/two"))
        try await store.save(url: firstURL, title: "One", text: "First article")
        let firstID = try XCTUnwrap(store.items.first).id
        try await store.save(url: secondURL, title: "Two", text: "Second article")
        let retainedID = try XCTUnwrap(store.items.first).id
        let unrelated = root.appendingPathComponent("ApplicationSupport/BookLibrary.json")
        let bytes = Data("unrelated saved library".utf8)
        try bytes.write(to: unrelated)
        try await store.remove(ids: [firstID, UUID()])
        let restored = ReadingListStore(fileURL: fileURL)
        try await restored.load()
        XCTAssertEqual(restored.items.map(\.id), [retainedID])
        XCTAssertEqual(restored.items.first?.url, secondURL)
        XCTAssertEqual(restored.items.first?.text, "Second article")
        XCTAssertEqual(try Data(contentsOf: unrelated), bytes)
    }

    func testInvalidInputDoesNotChangePreviouslySavedData() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        try await store.save(url: url, title: "Keep", text: "Saved article")
        let id = try XCTUnwrap(store.items.first).id
        let original = try Data(contentsOf: fileURL)
        for invalidURL in [URL(fileURLWithPath: "/tmp/article.txt"), try XCTUnwrap(URL(string: "http:broken"))] {
            await expectFailure { try await store.save(url: invalidURL, title: "Invalid", text: "Other article") }
        }
        await expectFailure { try await store.save(url: url, title: "Invalid", text: " \n\t") }
        await expectFailure { try await store.save(url: url, title: "Too large", text: String(repeating: "x", count: 2 * 1_024 * 1_024 + 1)) }
        await expectFailure { try await store.updatePosition(id: id, paragraph: -1) }
        XCTAssertEqual(store.items.map(\.id), [id])
        XCTAssertEqual(store.items.first?.title, "Keep")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testFailedWriteKeepsThePreviousInMemoryAndPersistedArticle() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        try await store.save(url: url, title: "Keep", text: "Saved article")
        let id = try XCTUnwrap(store.items.first).id
        let original = try Data(contentsOf: fileURL)
        let folder = fileURL.deletingLastPathComponent(), saved = root.appendingPathComponent("SavedSupport")
        try FileManager.default.moveItem(at: folder, to: saved)
        try Data("a file now occupies the destination folder".utf8).write(to: folder)
        await expectFailure { try await store.save(url: url, title: "Should not replace", text: "Another body") }
        XCTAssertEqual(store.items.map(\.id), [id])
        XCTAssertEqual(store.items.first?.title, "Keep")
        XCTAssertEqual(try Data(contentsOf: saved.appendingPathComponent("ReadingList.json")), original)
    }

    func testConcurrentSavesAndLoadsDoNotDropArticlesOrPublishAnOlderSnapshot() async throws {
        let store = ReadingListStore(fileURL: fileURL)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                let url = try XCTUnwrap(URL(string: "https://example.com/article/\(index)"))
                group.addTask { try await store.save(url: url, title: "Article \(index)", text: "Body \(index)") }
                group.addTask { try await store.load() }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(store.items.count, 24)
        XCTAssertEqual(Set(store.items.map(\.url)).count, 24)
        let restored = ReadingListStore(fileURL: fileURL)
        try await restored.load()
        XCTAssertEqual(Set(restored.items.map(\.id)), Set(store.items.map(\.id)))
    }

    func testTotalTextLimitRejectsAnAdditionalArticleWithoutChangingSavedData() async throws {
        let body = String(repeating: "x", count: 2 * 1_024 * 1_024)
        let articles = try (0..<10).map { index in
            SavedReadingItem(id: UUID(), url: try XCTUnwrap(URL(string: "https://example.com/large/\(index)")),
                title: "Article \(index)", text: body, savedAt: Date())
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(articles).write(to: fileURL, options: .atomic)
        let store = ReadingListStore(fileURL: fileURL)
        try await store.load()
        // Replacing an article at capacity must not count its previous text twice.
        try await store.save(url: articles[0].url, title: "Updated title", text: body)
        let original = try Data(contentsOf: fileURL)
        let extra = try XCTUnwrap(URL(string: "https://example.com/extra"))
        await expectFailure { try await store.save(url: extra, title: "Over capacity", text: "x") }
        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(store.items.first?.title, "Updated title")
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
    }

    func testUnreadableArchiveIsReportedAndNotReplacedByAFirstSave() async throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data("damaged archive".utf8)
        try invalid.write(to: fileURL)
        let store = ReadingListStore(fileURL: fileURL)
        await expectFailure { try await store.load() }
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        await expectFailure { try await store.save(url: url, title: "New", text: "New body") }
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(try Data(contentsOf: fileURL), invalid)
    }
}
