import SwiftData
import SwiftUI
import XCTest
@testable import Soulo

@MainActor
final class AdaptiveWindowTests: XCTestCase {
    // Mirror the App's WindowGroup-owned container lifetime. SwiftUI can retain
    // a Query's context after unmounting a hosting controller; its mainContext
    // has a weak container reference and still receives save notifications.
    private static var layoutContainer: ModelContainer?

    private func makeLayoutContainer() throws -> ModelContainer {
        if let container = Self.layoutContainer { return container }
        let container = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration("AdaptiveWindowTests", isStoredInMemoryOnly: true))
        Self.layoutContainer = container
        return container
    }

    func testWallpaperExportFillsWideAndTallLocalCanvasesAtTheirDisplayScale() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 320)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 320))
        }
        for size in [CGSize(width: 400, height: 180), CGSize(width: 180, height: 400)] {
            let result = try XCTUnwrap(WallpaperCropRenderer.render(
                source, canvasSize: size, displayScale: 2, zoom: 1, offset: .zero
            ))
            XCTAssertEqual(result.size, size)
            let cgImage = try XCTUnwrap(result.cgImage)
            XCTAssertEqual(cgImage.width, Int(size.width * 2))
            XCTAssertEqual(cgImage.height, Int(size.height * 2))
            // A portrait image must fill even a wide canvas without black side bands.
            for point in [CGPoint(x: 2, y: 2), CGPoint(x: cgImage.width - 3, y: cgImage.height - 3)] {
                let pixel = try rgba(cgImage, at: point)
                XCTAssertGreaterThan(pixel[1], 245)
                XCTAssertLessThan(pixel[0], 10)
            }
        }
        XCTAssertNil(WallpaperCropRenderer.render(source, canvasSize: .zero, displayScale: 2, zoom: 1, offset: .zero))
    }

    func testWallpaperExportMatchesZoomedOutPreviewBackground() throws {
        let source = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let result = try XCTUnwrap(WallpaperCropRenderer.render(
            source, canvasSize: CGSize(width: 200, height: 200), displayScale: 1,
            zoom: 0.5, offset: CGSize(width: 20, height: 0)
        )?.cgImage)
        XCTAssertEqual(try rgba(result, at: CGPoint(x: 5, y: 100)), [0, 0, 0, 255])
        XCTAssertGreaterThan(try rgba(result, at: CGPoint(x: 100, y: 100))[1], 245)
    }

    func testWindowReaderUsesMountedWindowAndUpdatesAfterResize() async throws {
        let scene = try activeScene()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        var reportedWindow: UIWindow?
        var reportedBounds = CGRect.zero
        window.rootViewController = UIHostingController(rootView:
            Color.clear.background(ViewWindowReader { current in
                reportedWindow = current
                reportedBounds = current?.bounds ?? .zero
            })
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(reportedWindow === window)
        XCTAssertEqual(reportedBounds, window.bounds)
        window.frame.size = CGSize(width: 720, height: 500)
        window.setNeedsLayout()
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reportedBounds.size, CGSize(width: 720, height: 500))
        let diagnostics = FeedbackDiagnostics.capture(in: window).values
        XCTAssertTrue(try XCTUnwrap(diagnostics["screen"]).contains("window 720 × 500 pt"))
        XCTAssertEqual(FeedbackDiagnostics.capture().values["screen"], "unavailable")
    }

    func testHomeSearchKeepsFieldFocusAndSelectionAcrossSizeClassChanges() async throws {
        let scene = try activeScene()
        let previous = scene.keyWindow
        let wallpaper = WallpaperManager.shared
        let oldSource = wallpaper.source
        let savedSource = UserDefaults.standard.object(forKey: "wallpaper_source")
        wallpaper.source = .gradient
        let search = SearchViewModel()
        let storageKey = "adaptive-window-\(UUID().uuidString)"
        UserDefaults.standard.set(Data(), forKey: storageKey)
        let tabs = TabManager(storageKey: storageKey)
        let container = try makeLayoutContainer()
        let host = UIHostingController(rootView: AnyView(HomeView()
            .environmentObject(search)
            .environmentObject(tabs)
            .environmentObject(LanguageManager.shared)
            .environmentObject(ThemeManager.shared)
            .environmentObject(wallpaper)
            .modelContainer(container)))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            wallpaper.source = oldSource
            if let savedSource { UserDefaults.standard.set(savedSource, forKey: "wallpaper_source") }
            else { UserDefaults.standard.removeObject(forKey: "wallpaper_source") }
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        try await Task.sleep(for: .milliseconds(200))
        let field = try XCTUnwrap(findField(in: window))
        XCTAssertTrue(field.becomeFirstResponder())
        field.insertText("keep this query")
        field.sendActions(for: .editingChanged)
        let start = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 5))
        let end = try XCTUnwrap(field.position(from: field.beginningOfDocument, offset: 9))
        field.selectedTextRange = field.textRange(from: start, to: end)
        for (size, horizontal, vertical) in [
            (CGSize(width: 750, height: 400), UIUserInterfaceSizeClass.compact, UIUserInterfaceSizeClass.compact),
            (CGSize(width: 700, height: 950), .regular, .regular),
            (CGSize(width: 320, height: 600), .compact, .regular)
        ] {
            host.traitOverrides.horizontalSizeClass = horizontal
            host.traitOverrides.verticalSizeClass = vertical
            window.frame.size = size
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(findField(in: window) === field, "Resizing must not recreate the field")
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertEqual(search.searchText, "keep this query")
            XCTAssertEqual(field.text, "keep this query")
            let range = try XCTUnwrap(field.selectedTextRange)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: range.start), 5)
            XCTAssertEqual(field.offset(from: field.beginningOfDocument, to: range.end), 9)
        }
        // Unmount observations before restoring the previous application window.
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
    }

    func testFullscreenBrowserRespectsUnequalSideSafeAreas() async throws {
        struct Harness: View {
            @Namespace var namespace
            let speech = SpeechRecognitionService()
            var body: some View {
                SearchResultsView(searchBarNamespace: namespace, speechService: speech)
            }
        }
        let defaults = UserDefaults.standard
        let fullscreenKey = AppConstants.StorageKeys.keepFullscreenBrowsing
        let savedFullscreen = defaults.object(forKey: fullscreenKey)
        defaults.set(true, forKey: fullscreenKey)
        let storageKey = "adaptive-browser-\(UUID().uuidString)"
        defaults.set(Data(), forKey: storageKey)
        let tabs = TabManager(storageKey: storageKey)
        let search = SearchViewModel()
        search.currentKeyword = "layout fixture"
        search.isSelectionSearch = true
        search.selectedPlatform = nil // No external page request in a layout test.
        let container = try makeLayoutContainer()
        let host = UIHostingController(rootView: AnyView(Harness()
            .environmentObject(search)
            .environmentObject(tabs)
            .environmentObject(LanguageManager.shared)
            .environmentObject(ThemeManager.shared)
            .modelContainer(container)))
        let scene = try activeScene()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame.size = CGSize(width: 750, height: 450)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.rootView = AnyView(EmptyView())
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            if let savedFullscreen { defaults.set(savedFullscreen, forKey: fullscreenKey) }
            else { defaults.removeObject(forKey: fullscreenKey) }
            defaults.removeObject(forKey: storageKey)
        }
        for (left, right) in [(CGFloat(80), CGFloat(12)), (CGFloat(12), CGFloat(80))] {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: left, bottom: 0, right: right)
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let page = try XCTUnwrap(tabs.activeWebViewModel?.webView)
            let frame = page.convert(page.bounds, to: window)
            XCTAssertGreaterThan(frame.width, 200)
            XCTAssertGreaterThanOrEqual(frame.minX, left - 1)
            XCTAssertLessThanOrEqual(frame.maxX, window.bounds.width - right + 1)
        }
        host.rootView = AnyView(EmptyView())
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
    }

    private func activeScene() throws -> UIWindowScene {
        try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
    }

    private func findField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { self.findField(in: $0) }.first
    }

    private func rgba(_ image: CGImage, at point: CGPoint) throws -> [UInt8] {
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: -point.x, y: -point.y)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixel
    }
}
