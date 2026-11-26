import UIKit
import SwiftUI
import XCTest
@testable import Soulo

@MainActor
final class FavoriteWallpaperImageStoreTests: XCTestCase {
    func testHomeRefreshUsesAnotherBingCandidateWithoutReloadingTheArchive() async throws {
        WallpaperPreviewProtocol.state.reset([
            "www.bing.com/HPImageArchive.aspx": try JSONSerialization.data(withJSONObject: ["images": [
                ["startdate": "today", "url": "/today.png"], ["startdate": "yesterday", "url": "/yesterday.png"]
            ]]),
            "www.bing.com/today.png": try png(.blue),
            "www.bing.com/yesterday.png": try png(.red)
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WallpaperPreviewProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await withLocalManager(session: session) { manager in
            manager.autoRandomizeRemoteSources = false
            await manager.selectSource(.bing)
            XCTAssertEqual(manager.currentImageID, "today")
            XCTAssertEqual(WallpaperPreviewProtocol.state.requestCount, 2)
            await manager.refreshRandom(appearance: .light)
            XCTAssertEqual(manager.currentImageID, "yesterday")
            XCTAssertEqual(WallpaperPreviewProtocol.state.requestCount, 3)
        }
    }

    func testManualSourceSelectionKeepsTheChosenSourceInFavoriteOnlyMode() async throws {
        let imageURL = "https://preview.test/source.png"
        WallpaperPreviewProtocol.state.reset([
            "api.pexels.com/v1/search": try JSONSerialization.data(withJSONObject: ["photos": [["id": "chosen-pexels", "src": ["original": imageURL, "medium": imageURL]]]]),
            "pixabay.com/api": try JSONSerialization.data(withJSONObject: ["hits": [["id": "chosen-pixabay", "largeImageURL": imageURL, "previewURL": imageURL]]]),
            "www.bing.com/HPImageArchive.aspx": try JSONSerialization.data(withJSONObject: ["images": [["startdate": "chosen-bing", "url": "/source.png"]]])
        ])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WallpaperPreviewProtocol.self]; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await withLocalManager(session: session) { manager in
            manager.source = .pixabay
            manager.favorites = [RemoteWallpaper(id: "favorite-pixabay", url: "", previewURL: "", source: "pixabay")]
            manager.onlyUseFavoriteWallpapers = true
            let home = try XCTUnwrap(UIImage(data: png(.blue)))
            manager.currentImage = home; manager.currentImageID = "favorite-pixabay"
            for chosen in [WallpaperSource.pexels, .bing, .pixabay] {
                await manager.selectSource(chosen)
                XCTAssertEqual(manager.source, chosen, "A manual source selection must not refresh back to a favorite's source")
                let savedSource = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.dkluge.Soulo")?["wallpaper_source"] as? String
                XCTAssertEqual(savedSource, chosen.rawValue)
                XCTAssertEqual(manager.candidateWallpapers.first?.source, chosen.rawValue)
                XCTAssertTrue(manager.onlyUseFavoriteWallpapers)
                XCTAssertTrue(manager.currentImage === home, "Browsing another source must preserve the favorite-only Home wallpaper")
                XCTAssertEqual(manager.currentImageID, "favorite-pixabay")
            }
        }
    }

    func testSourcePreviewsAreIndependentDeduplicatedCachedAndRespectBlocking() async throws {
        let pexels = "https://preview.test/pexels.png", pixabay = "https://preview.test/pixabay.png"
        let fixture: [String: Data] = [
            "api.pexels.com/v1/search": try JSONSerialization.data(withJSONObject: ["photos": [["id": "preview-pexels", "src": ["original": pexels, "medium": pexels]]]]),
            "pixabay.com/api": try JSONSerialization.data(withJSONObject: ["hits": [["id": "preview-pixabay", "largeImageURL": pixabay, "previewURL": pixabay]]]),
            "www.bing.com/HPImageArchive.aspx": try JSONSerialization.data(withJSONObject: ["images": [["startdate": "preview-bing", "url": "/preview-bing.png"]]]),
            "preview.test/pexels.png": try png(.red), "preview.test/pixabay.png": try png(.blue), "www.bing.com/preview-bing.png": try png(.green)
        ]
        WallpaperPreviewProtocol.state.reset(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WallpaperPreviewProtocol.self]; configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        try await withLocalManager(session: session) { manager in
            let home = try XCTUnwrap(UIImage(data: png(.yellow)))
            manager.currentImage = home; manager.currentImageID = "home-sentinel"
            let topic = manager.searchTopic, appearance = manager.displayAppearance
            async let first: Void = manager.loadSourcePreview(for: .pexels)
            async let duplicate: Void = manager.loadSourcePreview(for: .pexels)
            async let second: Void = manager.loadSourcePreview(for: .pixabay)
            async let third: Void = manager.loadSourcePreview(for: .bing)
            _ = await (first, duplicate, second, third)
            XCTAssertEqual(manager.sourcePreviewImages.count, 3)
            XCTAssertEqual(WallpaperPreviewProtocol.state.requestCount, 6, "Concurrent callers share a metadata/image request pair")
            XCTAssertTrue(manager.currentImage === home); XCTAssertEqual(manager.currentImageID, "home-sentinel")
            XCTAssertEqual(manager.source, .gradient); XCTAssertEqual(manager.searchTopic, topic)
            XCTAssertEqual(manager.displayAppearance, appearance); XCTAssertTrue(manager.candidateWallpapers.isEmpty)
            XCTAssertFalse(manager.networkLoading); XCTAssertTrue(manager.lastRemoteError.isEmpty)
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), session: session,
                favoriteImageStorage: FavoriteWallpaperImageStore(applicationSupport: support, caches: caches), photoDirectory: root)
            defer { restored.suspendAutomaticRefresh() }
            for source in [WallpaperSource.pexels, .pixabay, .bing] {
                await restored.loadSourcePreview(for: source)
                XCTAssertNotNil(restored.sourcePreviewImage(for: source), source.rawValue)
            }
            XCTAssertEqual(WallpaperPreviewProtocol.state.requestCount, 6, "Fresh cached thumbnails restore without networking")
            manager.blockWallpaper(RemoteWallpaper(id: "preview-pexels", url: pexels, previewURL: pexels, source: "pexels"))
            await manager.loadSourcePreview(for: .pexels)
            XCTAssertNil(manager.sourcePreviewImage(for: .pexels), "A blocked image cannot reappear from the preview cache")
        }
    }

    func testSourceSamplesShowMaskAndBlurWhileSolidColorsStayExact() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let pattern = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 192), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 256, height: 192))
            UIColor.black.setFill()
            for x in stride(from: 0, to: 256, by: 16) { context.fill(CGRect(x: x, y: 0, width: 8, height: 192)) }
        }
        func render(_ source: WallpaperSource, mask: Double, blur: CGFloat, color: String = "#FFFFFF") throws -> [Double] {
            let view = WallpaperSourceSample(source: source, appearance: .light, image: pattern,
                gradient: GradientPreset.presets[0], solidColor: color, overlayOpacity: mask, blurRadius: blur)
                .frame(width: 160, height: 120)
            let renderer = ImageRenderer(content: view); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage?.cgImage)
            var pixels = [UInt8](repeating: 0, count: 160 * 120 * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 160, height: 120, bitsPerComponent: 8,
                    bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 160, height: 120))
            }
            return (10..<150).map { Double(pixels[(60 * 160 + $0) * 4]) / 255 }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        func variance(_ values: [Double]) -> Double { let m = mean(values); return mean(values.map { ($0 - m) * ($0 - m) }) }
        let raw = try render(.photo, mask: 0, blur: 0)
        XCTAssertLessThan(mean(try render(.photo, mask: 0.8, blur: 0)), mean(raw) * 0.5)
        XCTAssertLessThan(variance(try render(.photo, mask: 0, blur: 30)), variance(raw) * 0.5)
        XCTAssertGreaterThan(mean(try render(.solid, mask: 0.8, blur: 30)), 0.98)
        XCTAssertLessThan(mean(try render(.solid, mask: 0.8, blur: 30, color: "#000000")), 0.02)
    }
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
            defer { restored.source = .gradient; restored.suspendAutomaticRefresh() }
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

    func testImageContrastUsesRenderedWallpaperPosition() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 200), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 100, width: 100, height: 100))
        }
        let sample = try XCTUnwrap(WallpaperContrast.ImageSample(try XCTUnwrap(image.cgImage)))
        let frame = CGRect(x: 40, y: 100, width: 200, height: 120)
        XCTAssertEqual(sample.prefersDarkText(in: CGRect(x: 130, y: 110, width: 20, height: 20),
            wallpaperFrame: frame, overlayAmount: 0, blurRadius: 0), true)
        XCTAssertEqual(sample.prefersDarkText(in: CGRect(x: 130, y: 190, width: 20, height: 20),
            wallpaperFrame: frame, overlayAmount: 0, blurRadius: 0), false)
        XCTAssertNil(sample.prefersDarkText(in: CGRect(x: 0, y: 0, width: 20, height: 20),
            wallpaperFrame: frame, overlayAmount: 0, blurRadius: 0))
    }

    func testToolbarStylesKeepContrastOnBothSidesOfAWallpaper() throws {
        let dark = Color(red: 0.18, green: 0.22, blue: 0.28)
        func toolbar(_ style: HomeToolbarLayout.Style, darkInk: Bool) -> some View {
            let appearance = HomeToolbarAppearance(lightWallpaper: darkInk, source: .photo)
            return HomeToolbarStrip(indices: [0], metrics: HomeToolbarMetrics(width: 64, count: 1, style: style),
                style: style, appearance: appearance) { _ in
                Button {} label: { HomeToolbarButtonFace(action: .settings, appearance: appearance) }
                    .buttonStyle(HomeToolbarButtonStyle(appearance: appearance, showsBackground: style == .tiles))
            }
            .frame(width: 64, height: 64)
        }
        let styles = HomeToolbarLayout.Style.allCases
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            ForEach(styles, id: \.self) { style in
                HStack(spacing: 0) {
                    toolbar(style, darkInk: false).background(dark)
                    toolbar(style, darkInk: true).background(.white)
                }
            }
        })
        renderer.scale = 3
        let screenshot = try XCTUnwrap(renderer.uiImage)
        let image = try XCTUnwrap(screenshot.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(didDraw)
        let rowHeight = height / styles.count
        for row in styles.indices {
            var lightPixelsOverDark = 0
            var darkPixelsOverLight = 0
            for y in (row * rowHeight)..<((row + 1) * rowHeight) {
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let rgb = pixels[index..<(index + 3)]
                    if x < width / 2 && rgb.allSatisfy({ $0 > 240 }) { lightPixelsOverDark += 1 }
                    if x >= width / 2 && rgb.allSatisfy({ $0 < 75 }) { darkPixelsOverLight += 1 }
                }
            }
            XCTAssertGreaterThan(lightPixelsOverDark, 100)
            XCTAssertGreaterThan(darkPixelsOverLight, 30)
        }
        XCTAssertEqual(Array(pixels[0..<3]), [46, 56, 71])
        XCTAssertEqual(Array(pixels[(width / 2 * 4)..<(width / 2 * 4 + 3)]), [255, 255, 255])
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = "toolbar-styles-contrast"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testImageOverlayDefaultsPersistsAndDoesNotTintSolidColors() async throws {
        try await withLocalManager { manager in
            XCTAssertTrue(manager.imageOverlayEnabled)
            XCTAssertEqual(manager.imageOverlayAmount, 0.30)
            manager.source = .photo
            XCTAssertTrue(manager.showsWallpaperOverlay)
            manager.imageOverlayAmount = 0.65
            XCTAssertEqual(manager.imageOverlayOpacity, 0.65)
            manager.currentImage = UIImage(data: try png(UIColor(white: 0.6, alpha: 1)))
            for _ in 0..<100 where manager.imagePrefersDarkText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(manager.prefersDarkForeground(for: .dark))
            manager.imageOverlayEnabled = false
            XCTAssertFalse(manager.showsWallpaperOverlay)
            XCTAssertTrue(manager.prefersDarkForeground(for: .dark), "Removing the tint must also update foreground contrast")
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), photoDirectory: root)
            defer { restored.source = .gradient; restored.suspendAutomaticRefresh() }
            XCTAssertFalse(restored.imageOverlayEnabled)
            XCTAssertEqual(restored.imageOverlayAmount, 0.65)
            let saved = try CloudSettingsSyncEngine.values(CloudSettingsSyncEngine.propertyList(CloudSettingsSyncEngine.snapshot(.standard)))
            XCTAssertEqual(saved["wallpaper_image_overlay_amount"] as? Double, 0.65)
            manager.imageOverlayAmount = 2
            XCTAssertEqual(manager.imageOverlayAmount, 1)
            manager.imageOverlayAmount = -1
            XCTAssertEqual(manager.imageOverlayAmount, 0)
            manager.imageOverlayAmount = .nan
            XCTAssertEqual(manager.imageOverlayAmount, 0.30)
            UserDefaults.standard.set(0.8, forKey: "wallpaper_image_overlay_amount")
            manager.reloadPreferencesFromDefaults()
            XCTAssertEqual(manager.imageOverlayAmount, 0.8)
            manager.source = .solid
            for enabled in [false, true] {
                manager.imageOverlayEnabled = enabled
                XCTAssertFalse(manager.showsWallpaperOverlay)
                XCTAssertEqual(manager.imageOverlayOpacity, 0)
            }
            manager.source = .gradient
            XCTAssertTrue(manager.showsWallpaperOverlay, "The image-only setting must preserve the existing gradient treatment")
        }
    }

    func testLightImageOverlayHasFullSurfaceTintAndSamplesTheTintedContrast() async throws {
        try await withLocalManager { manager in
            manager.source = .photo
            manager.setDisplayAppearance(.light)
            try await manager.saveCustomPhoto(png(UIColor(white: 0.6, alpha: 1)), for: .light)
            for _ in 0..<100 where manager.imagePrefersDarkText.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.imageOverlayOpacity, 0.30)
            XCTAssertFalse(manager.prefersDarkForeground(for: .light), "The black mask makes this gray image a dark surface")
            manager.imageOverlayAmount = 0
            XCTAssertFalse(manager.showsWallpaperOverlay)
            XCTAssertTrue(manager.prefersDarkForeground(for: .light))
            for _ in 0..<100 where manager.imagePrefersDarkText[.light] != true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.imagePrefersDarkText[.light], true)
            manager.imageOverlayAmount = 0.8
            for _ in 0..<100 where manager.prefersDarkForeground(for: .light) { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(manager.prefersDarkForeground(for: .light), "Text contrast follows the adjustable mask")
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
            defer { restored.source = .gradient; restored.suspendAutomaticRefresh() }
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

    func testPhotoWallpaperIsVisibleSynchronouslyOnColdRestoreAndThemeSwitch() async throws {
        try await withLocalManager { manager in
            let defaults = UserDefaults.standard
            let appearance = defaults.object(forKey: "appearance")
            let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
            var writableArguments = arguments; writableArguments.removeValue(forKey: "wallpaper_source")
            defaults.setVolatileDomain(writableArguments, forName: UserDefaults.argumentDomain)
            defer { defaults.set(appearance, forKey: "appearance"); defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
            defaults.set("light", forKey: "appearance")
            let data = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 2400)).image { context in
                UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1600, height: 2400))
            }.jpegData(compressionQuality: 0.8))
            try await manager.saveCustomPhoto(data, for: .light)
            manager.source = .photo
            manager.setDisplayAppearance(.light)
            XCTAssertNotNil(manager.customImage, "No task or timer should be needed for the first image")
            let restored = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { false }), photoDirectory: root)
            defer { restored.source = .gradient; restored.suspendAutomaticRefresh() }
            let first = try XCTUnwrap(restored.customImage?.cgImage)
            XCTAssertLessThanOrEqual(max(first.width, first.height), 512)
            XCTAssertTrue(FileManager.default.fileExists(atPath: WallpaperImageDecoder.previewURL(for: restored.customPhotoFile(for: .light)).path))
            try await manager.saveCustomPhoto(data, for: .dark)
            restored.setDisplayAppearance(.dark)
            XCTAssertNotNil(restored.customImage, "Theme switching also uses the cached preview synchronously")
        }
    }

    func testLegacyRemoteWallpaperHasAFirstFrameBeforeFullDecode() async throws {
        try await withLocalManager { manager in
            let defaults = UserDefaults.standard
            let keys = ["wallpaper_current_cache_file", "wallpaper_current_cache_id", "wallpaper_current_cache_url"]
            let values = keys.map { defaults.object(forKey: $0) }
            defer { for (key, value) in zip(keys, values) { defaults.set(value, forKey: key) } }
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("CurrentWallpaper")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString + ".image")
            try png(.systemGreen).write(to: file)
            defer { manager.source = .gradient; try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: WallpaperImageDecoder.previewURL(for: file)) }
            defaults.set(file.lastPathComponent, forKey: keys[0]); defaults.set("cached-first-frame", forKey: keys[1])
            manager.source = .bing
            XCTAssertEqual(manager.currentImageID, "cached-first-frame")
            XCTAssertNotNil(manager.currentImage, "Legacy caches also avoid an empty first frame")
        }
    }

    func testWallpaperAppearanceUsesAppPreferenceAndSystemDefault() {
        for dark in [false, true] {
            XCTAssertEqual(WallpaperAppearance.appPreference("light", systemIsDark: dark), .light)
            XCTAssertEqual(WallpaperAppearance.appPreference("dark", systemIsDark: dark), .dark)
            XCTAssertEqual(WallpaperAppearance.appPreference("system", systemIsDark: dark), dark ? .dark : .light)
            XCTAssertEqual(WallpaperAppearance.appPreference(nil, systemIsDark: dark), dark ? .dark : .light)
        }
    }

    func testBrowserChromeAppearanceCannotSwitchTheHomePhotoPreset() async throws {
        try await withLocalManager { manager in
            try await manager.saveCustomPhoto(png(.red), for: .light)
            try await manager.saveCustomPhoto(png(.blue), for: .dark)
            manager.source = .photo
            let revision = manager.customPhotoRevision
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let root = WallpaperBackground(isAnimating: false, appearanceOverride: .light, wallpaperManager: manager)
            let host = UIHostingController(rootView: root.environment(\.colorScheme, .dark))
            let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible(); manager.source = .gradient }
            for _ in 0..<50 where manager.displayAppearance != .light { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(manager.displayAppearance, .light)
            for scheme in [ColorScheme.light, .dark, .light, .dark] {
                host.rootView = root.environment(\.colorScheme, scheme)
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertEqual(manager.displayAppearance, .light)
                XCTAssertEqual(manager.currentImageID, "custom_light")
            }
            XCTAssertEqual(manager.customPhotoRevision, revision)
            XCTAssertEqual(manager.source, .photo)
        }
    }

    private func png(_ color: UIColor) throws -> Data {
        try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }.pngData())
    }

    private func withLocalManager(session: URLSession = .shared, _ check: (WallpaperManager) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let keys = ["wallpaper_source", "wallpaper_refresh_interval", "wallpaper_only_favorites", "wallpaper_favorites",
            "wallpaper_gradient_id", "wallpaper_solid_color", "wallpaper_gradient_id_light", "wallpaper_gradient_id_dark",
            "wallpaper_solid_color_light", "wallpaper_solid_color_dark", "wallpaper_last_auto_refresh_at", "wallpaper_image_overlay", "wallpaper_image_overlay_amount", "wallpaper_image_blur", "wallpaper_image_blur_amount", "wallpaper_blocked", "wallpaper_auto_random_sources"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set("aurora", forKey: "wallpaper_gradient_id")
        defaults.set("#123456", forKey: "wallpaper_solid_color")
        let manager = WallpaperManager(resources: BrowserResourcePolicy(readAllowance: { true }), session: session,
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

private final class WallpaperPreviewProtocol: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: Data] = [:]
        private var count = 0
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        func reset(_ values: [String: Data]) { lock.lock(); defer { lock.unlock() }; responses = values; count = 0 }
        func data(for url: URL) -> Data? {
            lock.lock(); defer { lock.unlock() }; count += 1
            return responses[(url.host ?? "") + url.path]
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let data = Self.state.data(for: url),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": url.path.hasSuffix(".png") ? "image/png" : "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
