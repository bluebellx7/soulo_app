import UIKit
import XCTest
@testable import Soulo

@MainActor
final class FavoriteWallpaperImageStoreTests: XCTestCase {
    private var root: URL!
    private var support: URL { root.appendingPathComponent("ApplicationSupport") }
    private var caches: URL { root.appendingPathComponent("Caches") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("favorite-wallpaper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    private func jpeg() throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }.jpegData(compressionQuality: 0.9))
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testMigrationPreservesOriginalBytesAndReadsTheDurableCopy() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg()
        let old = store.legacyDirectory.appendingPathComponent("nature.jpg")
        try write(data, to: old)
        await store.reconcile(favoriteIDs: ["nature"], revision: 1)
        let saved = store.savedDirectory.appendingPathComponent("nature.jpg")
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let restored = await store.cachedData(for: "nature")
        XCTAssertEqual(restored, data)
    }

    func testFailedMigrationPreservesTheLegacyOriginalAndStillReadsIt() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg(), old = store.legacyDirectory.appendingPathComponent("nature.jpg")
        try write(data, to: old)
        try write(Data("occupied destination".utf8), to: store.savedDirectory)
        await store.reconcile(favoriteIDs: ["nature"], revision: 1)
        XCTAssertEqual(try Data(contentsOf: old), data)
        let fallback = await store.cachedData(for: "nature")
        XCTAssertEqual(fallback, data)
        XCTAssertEqual(try Data(contentsOf: store.savedDirectory), Data("occupied destination".utf8))
    }

    func testClearOperationsRefuseFavoriteDataAndLeaveTheIndexAndImagesIntact() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg(), saved = store.savedDirectory.appendingPathComponent("nature.jpg")
        let old = store.legacyDirectory.appendingPathComponent("older.jpg")
        try write(data, to: saved)
        try write(data, to: old)
        let suite = "favorite-wallpaper-index-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = RemoteWallpaper(id: "nature", url: "https://example.com/original.jpg", previewURL: "", source: "bing", isFavorite: true)
        let index = try JSONEncoder().encode([favorite])
        defaults.set(index, forKey: "wallpaper_favorites")
        let locations = StorageUsageLocations(downloads: root.appendingPathComponent("Downloads"), applicationSupport: support, caches: caches)
        XCTAssertThrowsError(try StorageUsageService.clearDiskCache(.wallpapers, locations: locations))
        do { try await StorageUsageService.clear(.wallpapers); XCTFail("Favorite data cannot be cleared as a cache") }
        catch { }
        XCTAssertEqual(defaults.data(forKey: "wallpaper_favorites"), index)
        XCTAssertEqual(try Data(contentsOf: saved), data)
        XCTAssertEqual(try Data(contentsOf: old), data)
    }

    func testOnlyExplicitUnfavoritingDeletesAndStaleDownloadsCannotRecreateTheImage() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg()
        try write(data, to: store.savedDirectory.appendingPathComponent("nature.jpg"))
        try write(data, to: store.legacyDirectory.appendingPathComponent("nature.jpg"))
        await store.reconcile(favoriteIDs: ["nature"], revision: 1)
        await store.reconcile(favoriteIDs: [], revision: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.savedDirectory.appendingPathComponent("nature.jpg").path))
        await store.reconcile(favoriteIDs: [], removingIDs: ["nature"], revision: 2)
        let stale = await store.saveImage(data, for: "nature", favoriteIDs: ["nature"], revision: 1)
        XCTAssertFalse(stale)
        for url in store.imageURLs(for: "nature") { XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)) }
    }

    func testLateRemovalStillRemovesAnUnfavoritedImageButCannotRemoveANewFavorite() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg(), saved = store.savedDirectory.appendingPathComponent("nature.jpg")
        try write(data, to: saved)
        await store.reconcile(favoriteIDs: ["other"], revision: 3)
        await store.reconcile(favoriteIDs: [], removingIDs: ["nature"], revision: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let stored = await store.saveImage(data, for: "nature", favoriteIDs: ["nature"], revision: 4)
        XCTAssertTrue(stored)
        await store.reconcile(favoriteIDs: [], removingIDs: ["nature"], revision: 2)
        XCTAssertEqual(try Data(contentsOf: saved), data)
    }

    func testEmptyFavoritesCannotEnableOrRestoreFavoriteOnlyMode() async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_only_favorites", "wallpaper_favorites"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set(true, forKey: "wallpaper_only_favorites")
        defaults.removeObject(forKey: "wallpaper_favorites")
        let storage = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let manager = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), favoriteImageStorage: storage)
        defer { manager.suspendAutomaticRefresh() }
        XCTAssertFalse(manager.onlyUseFavoriteWallpapers)
        manager.onlyUseFavoriteWallpapers = true
        XCTAssertFalse(manager.onlyUseFavoriteWallpapers)
        XCTAssertFalse(defaults.bool(forKey: "wallpaper_only_favorites"))
        manager.favorites = [RemoteWallpaper(id: "nature", url: "", previewURL: "", source: "bing")]
        manager.onlyUseFavoriteWallpapers = true
        XCTAssertTrue(manager.onlyUseFavoriteWallpapers)
        manager.favorites.removeAll()
        XCTAssertFalse(manager.onlyUseFavoriteWallpapers)
        defaults.set(true, forKey: "wallpaper_only_favorites")
        manager.reloadPreferencesFromDefaults()
        XCTAssertFalse(manager.onlyUseFavoriteWallpapers)
        XCTAssertFalse(defaults.bool(forKey: "wallpaper_only_favorites"))
    }

    func testUnsafeIDsAndImagePlaceholdersCannotWriteOutsideTheOwnedDirectory() async throws {
        let store = FavoriteWallpaperImageStore(applicationSupport: support, caches: caches)
        let data = try jpeg()
        for id in ["../outside", "/absolute", "", "nested/file"] {
            let result = await store.saveImage(data, for: id, favoriteIDs: [id], revision: 1)
            XCTAssertFalse(result)
            XCTAssertTrue(store.imageURLs(for: id).isEmpty)
        }
        let result = await store.saveImage(Data("<html>blocked</html>".utf8), for: "nature", favoriteIDs: ["nature"], revision: 2)
        XCTAssertFalse(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.savedDirectory.path))
    }
}
