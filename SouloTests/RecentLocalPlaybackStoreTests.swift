import XCTest
@testable import Soulo

private final class RecentPlaybackCountingDefaults: UserDefaults {
    var writes = 0
    override func set(_ value: Any?, forKey defaultName: String) {
        writes += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
final class RecentLocalPlaybackStoreTests: XCTestCase {
    private var root: URL!
    private var downloads: URL!
    private var suite: String!
    private var defaults: RecentPlaybackCountingDefaults!

    override func setUpWithError() throws {
        suite = "recent-local-playback-" + UUID().uuidString
        defaults = RecentPlaybackCountingDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        downloads = root.appendingPathComponent("old-container/Documents/Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
        defaults = nil
        root = nil
        downloads = nil
        suite = nil
    }

    @discardableResult
    private func write(_ relative: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? downloads).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("test media".utf8).write(to: url)
        return url
    }

    func testRelativeMediaPathAndTitleSurviveAContainerMove() throws {
        let file = try write("Series/Season 1/episode #1.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: file, title: "Episode 1")
        let data = try XCTUnwrap(defaults.data(forKey: RecentLocalPlaybackStore.storageKey))
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(record["relativePath"], "Series/Season 1/episode #1.mp4")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("old-container"))
        let movedDownloads = root.appendingPathComponent("new-container/Documents/Downloads")
        try FileManager.default.createDirectory(at: movedDownloads.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: downloads, to: movedDownloads)
        let restored = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: movedDownloads)
        XCTAssertEqual(restored.latestURL?.path, movedDownloads.appendingPathComponent("Series/Season 1/episode #1.mp4").resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.title, "Episode 1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(restored.latestURL).path))
    }

    func testExternalURLsAndEscapingPathsLeaveThePreviousEntryUnchanged() throws {
        let file = try write("keep.mp3")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: file, title: "Keep")
        let original = defaults.data(forKey: RecentLocalPlaybackStore.storageKey)
        let external = try write("outside.mp4", in: root)
        let candidates: [URL] = [external, try XCTUnwrap(URL(string: "https://example.com/media.mp4")),
                    downloads.appendingPathComponent("../outside.mp4"),
                    downloads.deletingLastPathComponent().appendingPathComponent("Downloads-other/movie.mp4"), downloads]
        for url in candidates {
            store.record(url: url, title: "Should not replace")
        }
        XCTAssertEqual(store.latestURL?.path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "Keep")
        XCTAssertEqual(defaults.data(forKey: RecentLocalPlaybackStore.storageKey), original)
    }

    func testUnsafeOrDamagedStoredPathsAreIgnoredWithoutRewritingPreferences() throws {
        for path in ["", "../outside.mp4", "/absolute.mp4", "Series/../../outside.mp4", "Series//movie.mp4", "Series/./movie.mp4", "movie\u{0000}.mp4"] {
            let data = try JSONEncoder().encode(["relativePath": path, "title": "Unsafe"])
            defaults.set(data, forKey: RecentLocalPlaybackStore.storageKey)
            let before = defaults.writes
            let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
            XCTAssertNil(store.latestURL, path)
            XCTAssertNil(store.title, path)
            XCTAssertEqual(defaults.writes, before)
            XCTAssertEqual(defaults.data(forKey: RecentLocalPlaybackStore.storageKey), data)
        }
        let damaged = Data("broken record".utf8)
        defaults.set(damaged, forKey: RecentLocalPlaybackStore.storageKey)
        XCTAssertNil(RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads).latestURL)
        XCTAssertEqual(defaults.data(forKey: RecentLocalPlaybackStore.storageKey), damaged)
    }

    func testSymlinksCannotRecordOrRestoreAnOutsideFile() throws {
        let external = root.appendingPathComponent("outside")
        let file = try write("movie.mp4", in: external)
        let link = downloads.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: link.appendingPathComponent(file.lastPathComponent), title: "Outside")
        XCTAssertNil(store.latestURL)
        let forged = try JSONEncoder().encode(["relativePath": "Linked/movie.mp4", "title": "Outside"])
        defaults.set(forged, forKey: RecentLocalPlaybackStore.storageKey)
        XCTAssertNil(RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads).latestURL)
    }

    func testPrivateAndRepeatedPositionTicksDoNotWriteOrReplaceTheOrdinaryEntry() throws {
        let first = try write("one.mp4"), second = try write("two.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: first, title: "One")
        let before = defaults.writes
        for _ in 0..<20 { store.record(url: first, title: " One \n") }
        store.record(url: second, title: "Private", persistPosition: false)
        XCTAssertEqual(defaults.writes, before)
        XCTAssertEqual(store.latestURL?.path, first.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "One")
        let restored = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        restored.record(url: first, title: "One")
        XCTAssertEqual(defaults.writes, before)
        store.record(url: first, title: "Renamed title")
        XCTAssertEqual(defaults.writes, before + 1)
        XCTAssertEqual(store.title, "Renamed title")
    }

    func testDeletionOnlyClearsTheMatchingFileOrParentAfterRemoval() throws {
        let file = try write("Videos/one.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: file, title: "One")
        store.clearIfContained(in: [root, downloads.appendingPathComponent("Videos 2"), downloads.appendingPathComponent("other.mp4")])
        XCTAssertNotNil(store.latestURL)
        let folder = file.deletingLastPathComponent()
        try FileManager.default.removeItem(at: folder)
        store.clearIfContained(in: [folder])
        XCTAssertNil(store.latestURL)
        XCTAssertNil(store.title)
        XCTAssertNil(defaults.data(forKey: RecentLocalPlaybackStore.storageKey))
        XCTAssertNil(RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads).latestURL)
    }

    func testRenamingTheRecentFileUpdatesItsFilenameTitleAndResumePosition() throws {
        let old = try write("before.mp4"), next = downloads.appendingPathComponent("after.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: old, title: old.lastPathComponent)
        defaults.set(125.0, forKey: MediaSession.positionKey(old))
        try FileManager.default.moveItem(at: old, to: next)
        store.relocate(from: old, to: next)
        XCTAssertEqual(store.latestURL?.path, next.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "after.mp4")
        XCTAssertNil(defaults.object(forKey: MediaSession.positionKey(old)))
        XCTAssertEqual(defaults.double(forKey: MediaSession.positionKey(next)), 125)
        let restored = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        XCTAssertEqual(restored.latestURL?.path, next.resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.title, "after.mp4")
    }

    func testMovingTheParentDirectoryRetainsTheCustomTitleAndNestedPosition() throws {
        let old = try write("Series/Season 1/episode.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: old, title: "Custom episode title")
        defaults.set(66.0, forKey: MediaSession.positionKey(old))
        let source = downloads.appendingPathComponent("Series"), destination = downloads.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: source, to: destination)
        store.relocate(from: source, to: destination)
        let next = destination.appendingPathComponent("Season 1/episode.mp4")
        XCTAssertEqual(store.latestURL?.path, next.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "Custom episode title")
        XCTAssertEqual(defaults.double(forKey: MediaSession.positionKey(next)), 66)
        XCTAssertNil(defaults.object(forKey: MediaSession.positionKey(old)))
    }

    func testRelocationIgnoresUnrelatedFoldersAndRejectsOutsideOrSymlinkTargets() throws {
        let old = try write("Videos 2/episode.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: old, title: "Keep")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let link = downloads.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
        let before = defaults.writes
        store.relocate(from: downloads.appendingPathComponent("Videos"), to: downloads.appendingPathComponent("Other"))
        store.relocate(from: old, to: external.appendingPathComponent("episode.mp4"))
        store.relocate(from: old, to: link.appendingPathComponent("episode.mp4"))
        store.relocate(from: root, to: downloads.appendingPathComponent("Other"))
        XCTAssertEqual(defaults.writes, before)
        XCTAssertEqual(store.latestURL?.path, old.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "Keep")
    }

    func testRelocationCanFollowAFileOperationRollbackWithoutLosingTheEntry() throws {
        let old = try write("before.mp4"), next = downloads.appendingPathComponent("after.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: old, title: old.lastPathComponent)
        defaults.set(42.0, forKey: MediaSession.positionKey(old))
        try FileManager.default.moveItem(at: old, to: next)
        store.relocate(from: old, to: next)
        try FileManager.default.moveItem(at: next, to: old)
        store.relocate(from: next, to: old)
        XCTAssertEqual(store.latestURL?.path, old.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, old.lastPathComponent)
        XCTAssertEqual(defaults.double(forKey: MediaSession.positionKey(old)), 42)
        XCTAssertNil(defaults.object(forKey: MediaSession.positionKey(next)))
    }

    func testALatePositionTickCannotRecreateTheEntryAfterItsFileWasDeleted() throws {
        let file = try write("deleted.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: file, title: "Deleted")
        try FileManager.default.removeItem(at: file)
        store.clearIfContained(in: [file])
        let before = defaults.writes
        store.record(url: file, title: "Late player callback")
        XCTAssertNil(store.latestURL)
        XCTAssertNil(defaults.data(forKey: RecentLocalPlaybackStore.storageKey))
        XCTAssertEqual(defaults.writes, before)
    }

    func testRelocatingBeforeTheTargetExistsDoesNotMoveTheEntryOrPosition() throws {
        let file = try write("before.mp4"), missing = downloads.appendingPathComponent("missing.mp4")
        let store = RecentLocalPlaybackStore(userDefaults: defaults, rootURL: downloads)
        store.record(url: file, title: "Keep")
        defaults.set(20.0, forKey: MediaSession.positionKey(file))
        let before = defaults.writes
        store.relocate(from: file, to: missing)
        XCTAssertEqual(store.latestURL?.path, file.resolvingSymlinksInPath().path)
        XCTAssertEqual(store.title, "Keep")
        XCTAssertEqual(defaults.double(forKey: MediaSession.positionKey(file)), 20)
        XCTAssertNil(defaults.object(forKey: MediaSession.positionKey(missing)))
        XCTAssertEqual(defaults.writes, before)
    }
}
