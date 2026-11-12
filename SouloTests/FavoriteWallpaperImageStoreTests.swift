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

    func testAppearancePresetsPersistSeparatelyAndLegacyValuesRemainFallbacks() async throws {
        try await withLocalManager { manager in
            XCTAssertEqual(manager.solidColor(for: .light), "#123456")
            XCTAssertEqual(manager.solidColor(for: .dark), "#123456")
            XCTAssertEqual(manager.gradientID(for: .dark), "aurora")
            manager.setSolidColor("#FFFFFF", for: .light)
            manager.setSolidColor("000000", for: .dark)
            manager.setGradient("serenity", for: .light)
            manager.setGradient("forest", for: .dark)
            manager.setSolidColor("invalid", for: .dark)
            manager.setGradient("missing", for: .dark)
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), photoDirectory: root)
            defer { restored.suspendAutomaticRefresh() }
            XCTAssertEqual(restored.solidColor(for: .light), "#FFFFFF")
            XCTAssertEqual(restored.solidColor(for: .dark), "#000000")
            restored.setDisplayAppearance(.light)
            XCTAssertEqual(restored.currentGradient.id, "serenity")
            restored.setDisplayAppearance(.dark)
            XCTAssertEqual(restored.currentGradient.id, "forest")
            restored.source = .solid
            XCTAssertTrue(restored.prefersDarkForeground(for: .light))
            XCTAssertFalse(restored.prefersDarkForeground(for: .dark))
        }
    }

    func testLocalSourcesNeverResumeHiddenRemoteRefreshOrChangeSource() async throws {
        try await withLocalManager { manager in
            manager.autoRefreshInterval = .min1
            for source in [WallpaperSource.gradient, .solid, .photo] {
                manager.source = source
                manager.setupAutoRefreshTimer()
                manager.refreshIfNeededAfterForeground()
                XCTAssertFalse(manager.hasAutomaticRefreshWork)
                await manager.refreshRandom()
                XCTAssertEqual(manager.source, source)
            }
            // Merely changing the preference schedules timers; it does not fetch.
            manager.source = .bing
            XCTAssertTrue(manager.hasAutomaticRefreshWork)
            manager.source = .photo
            XCTAssertFalse(manager.hasAutomaticRefreshWork)
            XCTAssertEqual(manager.autoRefreshInterval, .min1)
        }
    }

    func testPhotoExportDoesNotOfferAnImageLeftOverFromAnotherSource() async throws {
        try await withLocalManager { manager in
            manager.currentImage = UIImage(data: try jpeg())
            manager.source = .photo
            XCTAssertNil(manager.customImage)
            XCTAssertFalse(manager.canPreviewCurrentWallpaper)
            XCTAssertNil(manager.exportPreview())
        }
    }

    func testOriginalPhotosRemainSeparateAndLegacyPhotoIsNotOverwritten() async throws {
        try await withLocalManager { manager in
            let original = try jpeg()
            let legacy = root.appendingPathComponent("custom_wallpaper.jpg")
            try original.write(to: legacy)
            XCTAssertEqual(manager.customPhotoFile(for: .light), legacy)
            XCTAssertEqual(manager.customPhotoFile(for: .dark), legacy)
            manager.setDisplayAppearance(.light)
            manager.source = .photo
            let light = try png(.white), dark = try png(.black)
            try await manager.saveCustomPhoto(light, for: .light)
            let activeID = manager.currentImageID
            try await manager.saveCustomPhoto(dark, for: .dark)
            XCTAssertEqual(manager.currentImageID, activeID, "Editing the other appearance must not replace the displayed photo")
            XCTAssertEqual(try Data(contentsOf: manager.customPhotoFile(for: .light)), light)
            XCTAssertEqual(try Data(contentsOf: manager.customPhotoFile(for: .dark)), dark)
            XCTAssertEqual(try Data(contentsOf: legacy), original)
            manager.setDisplayAppearance(.dark)
            for _ in 0..<100 where manager.customImage == nil { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertNotNil(manager.customImage)
            XCTAssertEqual(manager.currentImageID, "custom_dark")
            let preview = try XCTUnwrap(manager.exportPreview())
            await preview.prepare()
            let file = try XCTUnwrap(preview.file)
            XCTAssertEqual(try Data(contentsOf: file.url), dark, "Export must use the selected appearance's original bytes")
            try await manager.saveCustomPhoto(light, for: .dark)
            XCTAssertEqual(try Data(contentsOf: file.url), dark, "An open preview must keep its original after changing the wallpaper")
        }
    }

    func testInvalidOrCancelledPhotoCannotOverwriteSavedOriginal() async throws {
        try await withLocalManager { manager in
            let original = try jpeg()
            try await manager.saveCustomPhoto(original, for: .light)
            do { try await manager.saveCustomPhoto(Data("broken".utf8), for: .light); XCTFail("Invalid image accepted") }
            catch { }
            let replacement = try png(.red)
            let task = Task { try await manager.saveCustomPhoto(replacement, for: .light) }
            task.cancel()
            do { try await task.value; XCTFail("Cancelled selection accepted") }
            catch is CancellationError { }
            XCTAssertEqual(try Data(contentsOf: manager.customPhotoFile(for: .light)), original)
        }
    }

    func testExportPreservesOriginalAndReportsSaveFailureBeforeSuccess() async throws {
        let source = root.appendingPathComponent("original.wrong-extension")
        let bytes = try png(.blue)
        try bytes.write(to: source)
        var attempts = 0
        let model = WallpaperExportPreviewModel(localFiles: [source]) { url in
            XCTAssertEqual(try Data(contentsOf: url), bytes)
            attempts += 1
            if attempts == 1 { throw WebResourceDownloadError.photoAccessDenied }
        }
        await model.prepare()
        XCTAssertFalse(model.saved)
        XCTAssertEqual(attempts, 0, "Opening a preview must not write to Photos")
        let file = try XCTUnwrap(model.file)
        XCTAssertEqual(file.url.pathExtension, "png")
        try FileManager.default.removeItem(at: source)
        await model.saveToPhotos()
        XCTAssertFalse(model.saved)
        XCTAssertNotNil(model.saveError)
        XCTAssertFalse(model.isSaving)
        await model.saveToPhotos()
        XCTAssertTrue(model.saved)
        XCTAssertNil(model.saveError)
        await model.saveToPhotos()
        XCTAssertEqual(attempts, 2, "Ignore repeated saves after success")
    }

    func testMissingOriginalFallsBackToDisplayedImageAndCleansUpExport() async throws {
        var model: WallpaperExportPreviewModel? = WallpaperExportPreviewModel(localFiles: [], image: UIImage(data: try jpeg()))
        await model?.prepare()
        let url = try XCTUnwrap(model?.file?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(model?.image)
        model = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let empty = WallpaperExportPreviewModel(localFiles: [])
        await empty.prepare()
        XCTAssertTrue(empty.loadFailed)
        XCTAssertNil(empty.file)
    }

    func testContrastAdaptsToSaturatedColorsAndPhotoBrightness() async throws {
        XCTAssertTrue(WallpaperContrast.prefersDarkText(hex: "FFFFFF"))
        XCTAssertTrue(WallpaperContrast.prefersDarkText(hex: "FFFF00"))
        XCTAssertTrue(WallpaperContrast.prefersDarkText(hex: "00FF00"))
        XCTAssertFalse(WallpaperContrast.prefersDarkText(hex: "000000"))
        XCTAssertFalse(WallpaperContrast.prefersDarkText(hex: "18243E"))
        XCTAssertFalse(WallpaperContrast.prefersDarkText(hex: "0000FF"))
        try await withLocalManager { manager in
            manager.source = .photo
            manager.currentImage = UIImage(data: try png(.black))
            for _ in 0..<100 where manager.imagePrefersDarkText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(manager.prefersDarkForeground(for: .light), "A dark photo needs white text even in light appearance")
            manager.currentImage = UIImage(data: try png(.white))
            for _ in 0..<100 where !manager.prefersDarkForeground(for: .light) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(manager.prefersDarkForeground(for: .light))
            XCTAssertTrue(manager.prefersDarkForeground(for: .dark))
        }
    }

    func testImageOverlayDefaultsPersistsAndDoesNotTintSolidColors() async throws {
        try await withLocalManager { manager in
            XCTAssertTrue(manager.imageOverlayEnabled)
            manager.source = .photo
            XCTAssertTrue(manager.showsWallpaperOverlay)
            manager.currentImage = UIImage(data: try png(UIColor(white: 0.6, alpha: 1)))
            for _ in 0..<100 where manager.imagePrefersDarkText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(manager.prefersDarkForeground(for: .dark))
            manager.imageOverlayEnabled = false
            XCTAssertFalse(manager.showsWallpaperOverlay)
            XCTAssertTrue(manager.prefersDarkForeground(for: .dark), "Removing the tint must also update foreground contrast")
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), photoDirectory: root)
            defer { restored.suspendAutomaticRefresh() }
            XCTAssertFalse(restored.imageOverlayEnabled)
            manager.source = .solid
            for enabled in [false, true] {
                manager.imageOverlayEnabled = enabled
                XCTAssertFalse(manager.showsWallpaperOverlay)
            }
            manager.source = .gradient
            XCTAssertTrue(manager.showsWallpaperOverlay, "The image-only setting must preserve the existing gradient treatment")
        }
    }

    func testPlatformSearchNavigationTracksFinalRootBackAndNewSearch() {
        let model = WebViewModel()
        model.beginPlatformSearchTracking()
        model.updateCurrentURL(URL(string: "https://search.test/s?q=one"))
        model.updateCurrentURL(URL(string: "https://search.test/results?q=one"))
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch, "Initial redirects must not hide the platform bar")
        model.pageDidFinishLoading()
        model.updateCurrentURL(URL(string: "https://search.test/results?q=one#anchor"))
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch)
        model.updateCurrentURL(URL(string: "https://search.test/detail/42"))
        model.pageDidFinishLoading()
        XCTAssertTrue(model.hasNavigatedFromPlatformSearch)
        model.updateCurrentURL(URL(string: "https://search.test/results?q=one"))
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch)
        model.updateCurrentURL(URL(string: "https://search.test/detail/42"))
        XCTAssertTrue(model.hasNavigatedFromPlatformSearch)
        model.beginPlatformSearchTracking()
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch)
        model.updateCurrentURL(URL(string: "https://another.test/search?q=two"))
        model.pageDidFinishLoading()
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch)
        model.resetPlatformSearchTracking()
        model.updateCurrentURL(URL(string: "https://another.test/page"))
        XCTAssertFalse(model.hasNavigatedFromPlatformSearch)
    }

    func testLightImageOverlayHasFullSurfaceTintAndSamplesTheTintedContrast() async throws {
        try await withLocalManager { manager in
            manager.source = .photo
            manager.setDisplayAppearance(.light)
            try await manager.saveCustomPhoto(png(UIColor(white: 0.6, alpha: 1)), for: .light)
            for _ in 0..<100 where manager.imagePrefersDarkText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(WallpaperContrast.lightOverlayOpacity, 0.24)
            XCTAssertFalse(manager.prefersDarkForeground(for: .light), "The black mask makes this gray image a dark surface")
            manager.imageOverlayEnabled = false
            XCTAssertTrue(manager.prefersDarkForeground(for: .light), "The original image needs its own contrast choice")
        }
    }

    func testImageBlurPersistsClampsAndOnlyAppliesToImages() async throws {
        try await withLocalManager { manager in
            manager.source = .photo
            XCTAssertFalse(manager.imageBlurEnabled)
            XCTAssertEqual(manager.imageBlurRadius, 0)
            manager.imageBlurEnabled = true
            manager.imageBlurAmount = 0.5
            XCTAssertEqual(manager.imageBlurRadius, 15)
            manager.imageOverlayEnabled = false
            XCTAssertEqual(manager.imageBlurRadius, 15, "Blur and mask are independent")
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), photoDirectory: root)
            defer { restored.suspendAutomaticRefresh() }
            XCTAssertTrue(restored.imageBlurEnabled)
            XCTAssertEqual(restored.imageBlurAmount, 0.5)
            manager.imageBlurAmount = 8
            XCTAssertEqual(manager.imageBlurAmount, 1)
            manager.imageBlurAmount = -3
            XCTAssertEqual(manager.imageBlurAmount, 0)
            manager.imageBlurAmount = .nan
            XCTAssertEqual(manager.imageBlurAmount, 0.35)
            manager.source = .solid
            XCTAssertEqual(manager.imageBlurRadius, 0)
            manager.source = .gradient
            XCTAssertEqual(manager.imageBlurRadius, 0)
            manager.source = .bing
            XCTAssertEqual(manager.imageBlurRadius, 10.5)
            UserDefaults.standard.set(false, forKey: "wallpaper_image_blur")
            UserDefaults.standard.set(0.8, forKey: "wallpaper_image_blur_amount")
            manager.reloadPreferencesFromDefaults()
            XCTAssertFalse(manager.imageBlurEnabled)
            XCTAssertEqual(manager.imageBlurAmount, 0.8)
        }
    }

    func testSolidDefaultsAreWhiteAndBlackWithoutOverwritingCustomChoices() async throws {
        try await withLocalManager { manager in
            manager.solidColor = "#FFFFFF"
            XCTAssertEqual(manager.solidColor(for: .light), "#FFFFFF")
            XCTAssertEqual(manager.solidColor(for: .dark), "#000000")
            manager.setSolidColor("#AABBCC", for: .dark)
            XCTAssertEqual(manager.solidColor(for: .dark), "#AABBCC")
            XCTAssertEqual(manager.solidColor(for: .light), "#FFFFFF")
            manager.solidColor = "#123456"
            XCTAssertEqual(manager.solidColor(for: .light), "#123456", "Legacy custom colors stay intact")
        }
    }

    private func png(_ color: UIColor) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
    }

    private func withLocalManager(_ check: (WallpaperManager) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_only_favorites", "wallpaper_favorites",
            "wallpaper_gradient_id", "wallpaper_solid_color", "wallpaper_gradient_id_light", "wallpaper_gradient_id_dark",
            "wallpaper_solid_color_light", "wallpaper_solid_color_dark", "wallpaper_last_auto_refresh_at", "wallpaper_image_overlay", "wallpaper_image_blur", "wallpaper_image_blur_amount"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set("aurora", forKey: "wallpaper_gradient_id")
        defaults.set("#123456", forKey: "wallpaper_solid_color")
        let manager = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { true }),
            favoriteImageStorage: FavoriteWallpaperImageStore(applicationSupport: support, caches: caches), photoDirectory: root)
        defer { manager.suspendAutomaticRefresh() }
        try await check(manager)
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
