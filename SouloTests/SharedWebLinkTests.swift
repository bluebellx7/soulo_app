import XCTest
@testable import Soulo

final class SharedWebLinkTests: XCTestCase {
    func testWebURLSharingPreservesEncodingAndSelectsDirectNavigation() throws {
        let target = "https://example.com/a%2Fb?q=a%26b%2Bc#part%201"
        let action = try XCTUnwrap(SouloSharedContent.action(for: target))
        XCTAssertEqual(action.kind, .openURL)
        XCTAssertEqual(action.text, target)
    }

    func testTitleAndURLTextUsesWebPageInsteadOfSearchingTitle() throws {
        let action = try XCTUnwrap(SouloSharedContent.action(for: "A股技术面筛选器\nhttps://app.workbuddy.host/?q=a%26b#result"))
        XCTAssertEqual(action.kind, .openURL)
        XCTAssertEqual(action.text, "https://app.workbuddy.host/?q=a%26b#result")
        XCTAssertEqual(SouloSharedContent.action(for: "Some search text")?.kind, .search)
        XCTAssertNil(SouloSharedContent.action(for: "  \n "))
        XCTAssertNil(SouloSharedContent.webURL(in: "javascript:alert(1)"))
    }

    func testPendingLinkIsConsumedExactlyOnceAndMismatchedIDDoesNotLoseIt() throws {
        let storage = try temporaryStorage()
        let action = try XCTUnwrap(SouloSharedContent.action(for: "https://example.com/?q=a%26b#result"))
        XCTAssertTrue(storage.store(action))
        // A fresh reader has no in-memory preferences or writer state.
        let reader = SouloSharedActionFileStore(directory: storage.fileURL.deletingLastPathComponent())
        XCTAssertNil(reader.consume(matchingID: UUID()))
        XCTAssertEqual(reader.consume(matchingID: action.id), action)
        XCTAssertNil(storage.consume())
    }

    func testExpiredHandoffIsDiscarded() throws {
        let storage = try temporaryStorage()
        let action = SouloSharedAction(kind: .openURL, text: "https://example.com")
        XCTAssertTrue(storage.store(action))
        XCTAssertNil(storage.consume(now: action.createdAt.addingTimeInterval(8 * 24 * 3600)))
        XCTAssertNil(storage.consume(now: action.createdAt))
    }

    func testCancellingAnOlderRequestPreservesTheNewerLink() throws {
        let storage = try temporaryStorage()
        let older = SouloSharedAction(kind: .openURL, text: "https://example.com/older")
        let newer = SouloSharedAction(kind: .openURL, text: "https://example.com/newer")
        XCTAssertTrue(storage.store(older))
        XCTAssertTrue(storage.store(newer))
        storage.discard(matchingID: older.id)
        XCTAssertEqual(storage.consume(), newer)
        XCTAssertNil(storage.consume(matchingID: older.id))
    }

    func testLegacyPreferencesCannotReplayAfterFileConsumption() throws {
        let storage = try temporaryStorage()
        let suite = "SharedWebLinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let action = SouloSharedAction(kind: .openURL, text: "https://example.com/legacy")
        let data = try JSONEncoder().encode(action)
        defaults.set(data, forKey: SouloSharedConstants.pendingActionKey)
        XCTAssertNil(storage.consume(matchingID: UUID(), legacyDefaults: defaults))
        XCTAssertEqual(storage.consume(legacyDefaults: defaults), action)
        // Model a stale persisted preferences record after a failed flush.
        defaults.set(data, forKey: SouloSharedConstants.pendingActionKey)
        let reader = SouloSharedActionFileStore(directory: storage.fileURL.deletingLastPathComponent())
        XCTAssertNil(reader.consume(legacyDefaults: defaults))
    }

    func testConcurrentReadersConsumeOnlyOnce() throws {
        let storage = try temporaryStorage()
        let action = SouloSharedAction(kind: .openURL, text: "https://example.com/concurrent")
        XCTAssertTrue(storage.store(action))
        let results = SharedActionResults()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let reader = SouloSharedActionFileStore(directory: storage.fileURL.deletingLastPathComponent())
            if let action = reader.consume() { results.append(action) }
        }
        XCTAssertEqual(results.actions, [action])
    }

    func testFailedFileWriteIsReportedRatherThanClaimingAQueuedLink() throws {
        let storage = try temporaryStorage()
        let blocker = storage.fileURL.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data().write(to: blocker)
        let invalidStorage = SouloSharedActionFileStore(directory: blocker)
        XCTAssertFalse(invalidStorage.store(SouloSharedAction(kind: .openURL, text: "https://example.com")))
    }

    private func temporaryStorage() throws -> SouloSharedActionFileStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SharedWebLinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return SouloSharedActionFileStore(directory: directory)
    }
}

private final class SharedActionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SouloSharedAction] = []
    func append(_ action: SouloSharedAction) { lock.lock(); values.append(action); lock.unlock() }
    var actions: [SouloSharedAction] { lock.lock(); defer { lock.unlock() }; return values }
}
