import XCTest
import Combine
import SwiftData
@testable import Soulo

private final class CountingDefaults: UserDefaults {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
private final class PerformanceClipboard: ClipboardReading {
    var changeCount = 77
    var readCount = 0
    var pendingDetection: CheckedContinuation<Bool, Never>?
    var holdsDetection = false
    var holdsRead = false
    var pendingRead: CheckedContinuation<String?, Never>?
    func hasSearchableContent() async -> Bool {
        if !holdsDetection { return true }
        return await withCheckedContinuation { pendingDetection = $0 }
    }
    func readText() async -> String? {
        readCount += 1
        if holdsRead { return await withCheckedContinuation { pendingRead = $0 } }
        return "Clipboard search fixture"
    }
}

@MainActor final class PerformanceRegressionTests: XCTestCase {
    private var savedClipboardDefaults: [String: Any] = [:]
    private let clipboardKeys = ["last_clipboard_change_count", "last_clipboard_hash"]

    override func setUp() {
        super.setUp()
        for key in clipboardKeys { savedClipboardDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in clipboardKeys { UserDefaults.standard.set(savedClipboardDefaults[key], forKey: key) }
        savedClipboardDefaults.removeAll()
        super.tearDown()
    }

    func testRepeatedClipboardSearchCoalescesAndDismissalCancelsItsResult() async throws {
        let clipboard = PerformanceClipboard()
        clipboard.holdsRead = true
        let model = SearchViewModel(clipboardReader: clipboard)
        var searches = 0
        model.searchFromClipboard { searches += 1 }
        model.searchFromClipboard { searches += 1 }
        for _ in 0..<100 {
            if clipboard.pendingRead != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(clipboard.readCount, 1)
        let read = try XCTUnwrap(clipboard.pendingRead)
        model.dismissClipboard()
        read.resume(returning: "Canceled clipboard search")
        clipboard.pendingRead = nil
        await Task.yield()
        XCTAssertEqual(searches, 0)
        XCTAssertTrue(model.searchText.isEmpty)
        XCTAssertFalse(model.isReadingClipboard)
    }

    func testRecentSearchKeywordsPagePastDuplicatesAndExcludeWebVisits() throws {
        let container = try ModelContainer(for: SearchHistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        for index in 0..<200 {
            context.insert(SearchHistoryItem(keyword: "Page \(index)", timestamp: Date(timeIntervalSince1970: Double(index + 1_000)),
                visitedURLString: "https://example.com/\(index)"))
        }
        for index in 0..<90 {
            context.insert(SearchHistoryItem(keyword: "duplicate", timestamp: Date(timeIntervalSince1970: Double(index + 100))))
        }
        for index in 0..<20 {
            context.insert(SearchHistoryItem(keyword: "query \(index)", timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        try context.save()
        let expected = ["duplicate"] + (1...19).reversed().map { "query \($0)" }
        XCTAssertEqual(SearchHistoryService.recentSearchKeywords(context: context), expected)
        XCTAssertTrue(SearchHistoryService.recentSearchKeywords(limit: 0, context: context).isEmpty)
    }

    func testClipboardDetectionWaitsForExplicitSearchBeforeReadingText() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "last_clipboard_change_count")
        defer { defaults.set(saved, forKey: "last_clipboard_change_count") }
        defaults.set(0, forKey: "last_clipboard_change_count")
        let clipboard = PerformanceClipboard()
        let model = SearchViewModel(clipboardReader: clipboard)
        model.detectClipboard()
        for _ in 0..<100 {
            if model.showClipboardPrompt { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.showClipboardPrompt)
        XCTAssertNil(model.clipboardContent)
        XCTAssertEqual(clipboard.readCount, 0, "Foreground activation must not request paste permission")
        var searches = 0
        model.searchFromClipboard { searches += 1 }
        for _ in 0..<100 {
            if searches == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(searches, 1)
        XCTAssertEqual(clipboard.readCount, 1)
        XCTAssertEqual(model.searchText, "Clipboard search fixture")
        XCTAssertFalse(model.showClipboardPrompt)
        model.clearSuggestions()
    }

    func testClipboardDismissalWinsAgainstPendingDetection() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "last_clipboard_change_count")
        defer { defaults.set(saved, forKey: "last_clipboard_change_count") }
        defaults.set(0, forKey: "last_clipboard_change_count")
        let clipboard = PerformanceClipboard()
        clipboard.holdsDetection = true
        let model = SearchViewModel(clipboardReader: clipboard)
        model.detectClipboard()
        for _ in 0..<100 {
            if clipboard.pendingDetection != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let detection = try XCTUnwrap(clipboard.pendingDetection)
        model.dismissClipboard()
        detection.resume(returning: true)
        clipboard.pendingDetection = nil
        await Task.yield()
        XCTAssertFalse(model.showClipboardPrompt)
        XCTAssertEqual(clipboard.readCount, 0)
    }

    func testWebHistoryRecordingWithLargeLibrary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-performance-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = try ModelContainer(for: SearchHistoryItem.self,
            configurations: ModelConfiguration(url: directory.appendingPathComponent("history.sqlite")))
        let seed = ModelContext(container)
        let now = Date()
        for index in 0..<5_000 {
            seed.insert(SearchHistoryItem(keyword: "Page \(index)", timestamp: now.addingTimeInterval(-Double(index)),
                visitedURLString: "https://example.com/articles/\(index)?topic=reading"))
        }
        seed.insert(SearchHistoryItem(keyword: "Expired page",
            timestamp: now.addingTimeInterval(-SearchHistoryService.browsingHistoryLifetime - 1),
            visitedURLString: "https://expired.example.com"))
        seed.insert(SearchHistoryItem(keyword: "Preserved search", timestamp: .distantPast))
        try seed.save()
        let context = ModelContext(container)
        var durations: [Double] = []
        for index in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            SearchHistoryService.recordWebVisit(url: URL(string: "https://new.example.com/page/\(index)")!,
                title: "New page \(index)", visitedAt: now, context: context)
            durations.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        print("PERF history 5000: median_ms=\(durations.sorted()[2]), samples_ms=\(durations)")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<SearchHistoryItem>()), 5_006)
        XCTAssertEqual(SearchHistoryService.fetchRecent(limit: 1, context: context).first?.timestamp, now)
    }

    func testDownloadProgressBurst() throws {
        let suite = "SouloPerformance-\(UUID())"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let service = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let (item, _) = service.beginDownload(suggestedFilename: "performance.bin", sourceURL: nil, transport: .background)
        defaults.writes = 0
        var publications = 0
        let observer = service.objectWillChange.sink { publications += 1 }
        let start = CFAbsoluteTimeGetCurrent()
        for value in 1...1000 { service.updateProgress(id: item.id, completed: Int64(value), total: 2000) }
        service.markPaused(id: item.id)
        print("PERF download burst: ms=\((CFAbsoluteTimeGetCurrent()-start)*1000), writes=\(defaults.writes), publications=\(publications)")
        XCTAssertEqual(service.downloads.first?.receivedBytes, 1000)
        XCTAssertEqual(service.downloads.first?.progress, 0.5)
        XCTAssertEqual(defaults.writes, 1, "Progress must be saved once when pausing, not per network packet")
        XCTAssertLessThanOrEqual(publications, 1003, "Each progress callback should publish one coherent item")
        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertEqual(restored.downloads.first?.receivedBytes, 1000)
        withExtendedLifetime(observer) {}
    }

    func testPrivacyStatisticsBurst() throws {
        let suite = "SouloPerformance-\(UUID())"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PrivacyProtectionService(userDefaults: defaults)
        defaults.writes = 0
        let start = CFAbsoluteTimeGetCurrent()
        for value in 0..<500 { service.recordHiddenElementCount(1, for: "site\(value % 100).example") }
        service.flushPendingStatistics()
        print("PERF privacy burst: ms=\((CFAbsoluteTimeGetCurrent()-start)*1000), writes=\(defaults.writes)")
        XCTAssertEqual(service.summary(for: "site0.example").hiddenElementCount, 5)
        XCTAssertEqual(defaults.writes, 1)
        XCTAssertEqual(PrivacyProtectionService(userDefaults: defaults).summary(for: "site0.example").hiddenElementCount, 5)
    }

    func testDeferredPersistenceFlushesLatestValueOnBackgroundAndDoesNotResurrectCanceledWrites() async throws {
        let notifications = NotificationCenter()
        let persistence = DeferredPersistence(delay: .milliseconds(30), notificationCenter: notifications)
        var saved: [Int] = []
        for value in 0..<100 { persistence.schedule { saved.append(value) } }
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertEqual(saved, [99])
        persistence.schedule { saved.append(100) }
        persistence.cancel()
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(saved, [99])
        persistence.schedule { saved.append(101) }
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(saved, [99, 101])
    }

    func testResetStatisticsCancelsPendingSave() async throws {
        let suite = "SouloPerformance-\(UUID())"
        let defaults = try XCTUnwrap(CountingDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PrivacyProtectionService(userDefaults: defaults)
        service.recordHiddenElementCount(5, for: "example.com")
        service.resetAllSummaries()
        service.flushPendingStatistics()
        XCTAssertTrue(PrivacyProtectionService(userDefaults: defaults).summariesByHost.isEmpty)
    }

    func testRecentHistoryLimitsResultsAndPreservesDuplicateRules() throws {
        let container = try ModelContainer(for: SearchHistoryItem.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        for index in 0..<1000 {
            context.insert(SearchHistoryItem(keyword: "query \(index)", timestamp: Date(timeIntervalSince1970: Double(index))))
        }
        try context.save()
        XCTAssertEqual(SearchHistoryService.fetchRecent(limit: 3, context: context).map(\.keyword), ["query 999", "query 998", "query 997"])
        XCTAssertTrue(SearchHistoryService.fetchRecent(limit: 0, context: context).isEmpty)
        SearchHistoryService.addEntry(keyword: "unique", platformID: nil, context: context)
        SearchHistoryService.addEntry(keyword: "unique", platformID: nil, context: context)
        XCTAssertEqual(SearchHistoryService.fetchRecent(limit: 2, context: context).map(\.keyword), ["unique", "query 999"])
    }

    func testLongUnicodeTextIsChunkedWithoutLosingCharacters() {
        let text = String(repeating: "中文👨‍👩‍👧‍👦e\u{301}", count: 60_000)
        let chunks = TextBookDecoder.chapters(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text + "\n")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 24_001 })
    }

    func testScannerHonorsCancellationBeforeStartingRecognition() async {
        let task = Task.detached { () throws -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ScannedContent.decodeImage(Data())
        }
        do { _ = try await task.value; XCTFail("Canceled recognition should not return a result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReadingProgressFlushPreservesLatestLocation() throws {
        let metadata = FileManager.default.temporaryDirectory.appendingPathComponent("performance-books-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: metadata) }
        let book = LibraryBook(id: "fixture", name: "Fixture", fileName: "fixture.txt")
        try JSONEncoder().encode([book]).write(to: metadata)
        let library = BookLibrary(metadata: metadata)
        for index in 1...1000 { library.update(book.id, location: "location-\(index)", fraction: Double(index)/2000) }
        XCTAssertEqual(BookLibrary(metadata: metadata).books.first?.location, "")
        library.flushReadingProgress()
        let restored = BookLibrary(metadata: metadata)
        XCTAssertEqual(restored.books.first?.location, "location-1000")
        XCTAssertEqual(restored.books.first?.fraction, 0.5)
    }
}
