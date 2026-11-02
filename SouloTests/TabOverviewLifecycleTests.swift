import XCTest
import SwiftUI
import WebKit
import Vision
@testable import Soulo

@MainActor final class TabOverviewLifecycleTests: XCTestCase {
    func testDomainGroupsPreserveTabOrderAndDoNotMergeUnrelatedHosts() throws {
        let urls: [String?] = ["https://www.example.com/a", "https://other.test", "http://example.com:8080/b",
            "https://alpha.github.io", "https://beta.github.io", "https://m.example.com", nil,
            "file:///tmp/notes.html", "http://127.0.0.1", "http://127.0.0.2", "https://example.com./c"]
        let tabs = urls.map { value in
            let tab = BrowserTab()
            if let value { tab.webViewModel.loadCachedURL(URL(string: value)!) }
            return tab
        }
        let groups = TabOverviewDomainGroup.make(from: tabs)
        XCTAssertEqual(groups.map(\.id), ["host:example.com", "host:other.test", "host:alpha.github.io", "host:beta.github.io",
            "host:m.example.com", "new-tabs", "local-files", "host:127.0.0.1", "host:127.0.0.2"])
        XCTAssertEqual(groups.first?.tabs.map(\.id), [tabs[0].id, tabs[2].id, tabs[10].id])
        XCTAssertEqual(groups.flatMap(\.tabs).count, tabs.count)
        XCTAssertTrue(tabs.allSatisfy { $0.webViewModel.webView == nil }, "Grouping must only read metadata")
    }

    func testClosingTheNewestCardDoesNotMoveItsRemainingDomainGroup() {
        let tabs = ["https://first.example/new", "https://second.example/new", "https://first.example/old", "https://second.example/old"].map { address in
            let tab = BrowserTab(); tab.webViewModel.loadCachedURL(URL(string: address)!); return tab
        }
        let initialOrder = TabOverviewDomainGroup.make(from: tabs).map(\.id)
        let groups = TabOverviewDomainGroup.make(from: Array(tabs.dropFirst()), preservingGroupOrder: initialOrder)
        XCTAssertEqual(groups.map(\.id), initialOrder)
        XCTAssertEqual(groups.first?.tabs.map(\.id), [tabs[2].id])
        let removed = TabOverviewDomainGroup.make(from: [tabs[1], tabs[3]], preservingGroupOrder: initialOrder)
        XCTAssertEqual(removed.map(\.id), ["host:second.example"])
    }

    func testGroupedOverviewRendersBoundedPreviewsAcrossScreenSizesAndLanguages() async throws {
        let defaults = UserDefaults.standard
        let savedMode = defaults.object(forKey: "tab_overview_grouped")
        let savedPrivate = defaults.object(forKey: "is_incognito")
        let language = LanguageManager.shared.currentLanguage
        let key = "grouped-overview-\(UUID())"
        defaults.set(true, forKey: "tab_overview_grouped")
        defaults.set(false, forKey: "is_incognito")
        let manager = TabManager(storageKey: key)
        let sites: [(String, String, UIColor)] = [
            ("baidu.com", "城市漫游指南", .init(red: 0.28, green: 0.40, blue: 0.69, alpha: 1)),
            ("zhihu.com", "设计里的那些细节", .init(red: 0.16, green: 0.43, blue: 0.62, alpha: 1)),
            ("github.com", "SwiftUI collections", .init(red: 0.33, green: 0.32, blue: 0.45, alpha: 1)),
            ("wikipedia.org", "Architecture notes", .init(red: 0.48, green: 0.39, blue: 0.27, alpha: 1)),
            ("apple.com", "A closer look", .init(red: 0.31, green: 0.47, blue: 0.39, alpha: 1)),
            ("bilibili.com", "周末的观影清单", .init(red: 0.59, green: 0.34, blue: 0.43, alpha: 1)),
            ("douban.com", "Reading together", .init(red: 0.28, green: 0.46, blue: 0.38, alpha: 1)),
            ("developer.apple.com", "Platform documentation", .init(red: 0.35, green: 0.37, blue: 0.60, alpha: 1))]
        let directory = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("SouloTabSnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manager.tabs = sites.flatMap { host, title, color in
            (0..<8).map { index in
                let tab = BrowserTab()
                tab.webViewModel.loadCachedURL(URL(string: "https://\(host)/article/\(index)")!)
                tab.webViewModel.updateTitle(index == 0 ? title : "\(title) · \(index + 1)")
                let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 600)).image { context in
                    UIColor(white: 0.97, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 600))
                    color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 220))
                    (title as NSString).draw(in: CGRect(x: 22, y: 36, width: 276, height: 100), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 30, weight: .bold), .foregroundColor: UIColor.white])
                    (host as NSString).draw(at: CGPoint(x: 22, y: 166), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.white.withAlphaComponent(0.75)])
                    for line in 0..<7 {
                        UIColor(white: 0.82 + CGFloat(line % 2) * 0.05, alpha: 1).setFill()
                        context.fill(CGRect(x: 22, y: 250 + line * 27, width: line % 3 == 2 ? 190 : 276, height: 9))
                    }
                }
                try? image.jpegData(compressionQuality: 0.8)?.write(to: directory.appendingPathComponent("\(tab.id.uuidString).jpg"))
                return tab
            }
        }
        manager.activeTabIndex = manager.tabs.count - 1
        let firstPreview = try XCTUnwrap(manager.tabsForOverview.first?.webViewModel)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            manager.tabs.forEach { $0.webViewModel.deletePersistedSnapshot() }
            manager.saveToDisk(); defaults.removeObject(forKey: key)
            defaults.set(savedMode, forKey: "tab_overview_grouped")
            defaults.set(savedPrivate, forKey: "is_incognito")
            LanguageManager.shared.currentLanguage = language
        }
        for (code, size) in [("zh-Hans", CGSize(width: 402, height: 874)), ("en-US", CGSize(width: 320, height: 568)),
                             ("ar-SA", CGSize(width: 402, height: 874)), ("en-US", CGSize(width: 874, height: 402))] {
            manager.tabs.forEach { $0.webViewModel.releaseSnapshotMemory() }
            LanguageManager.shared.currentLanguage = code
            window.rootViewController = UIHostingController(rootView: TabSwitcherOverlay(
                tabManager: manager, onSelectTab: { _ in }, onNewTab: {}, onDismiss: {})
                .background(Color(red: 0.12, green: 0.13, blue: 0.16).ignoresSafeArea())
                .environment(\.colorScheme, .dark)
                .environment(\.layoutDirection, code == "ar-SA" ? .rightToLeft : .leftToRight)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: size.width, height: size.height))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(500))
            let view = try XCTUnwrap(window.rootViewController?.view)
            view.bounds = CGRect(origin: .zero, size: size); view.layoutIfNeeded()
            for _ in 0..<80 {
                if firstPreview.snapshot != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let image = UIGraphicsImageRenderer(size: size).image { _ in view.drawHierarchy(in: view.bounds, afterScreenUpdates: true) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            // The same domain is also printed inside every preview. Vision's
            // reading order can put a thumbnail before the actual section header.
            let header = request.results?.filter {
                $0.topCandidates(1).first?.string.lowercased().contains("developer.apple.com") == true
            }.max { $0.boundingBox.midY < $1.boundingBox.midY }
            XCTAssertNotNil(header, "The newest domain group must be visible on opening: \(code)")
            if let header { XCTAssertGreaterThan(header.boundingBox.midY, 0.70, "The newest domain starts at the top: \(code), \(size)") }
            let attachment = XCTAttachment(image: image)
            attachment.name = "grouped-tabs-\(code)-\(Int(size.width))"; attachment.lifetime = .keepAlways; add(attachment)
            XCTAssertTrue(manager.tabs.allSatisfy { $0.webViewModel.webView == nil }, "Previews cannot activate WebKit")
            XCTAssertNotNil(firstPreview.snapshot, "A new preview view must recover the first screenshot after the previous view is removed: \(code)")
            XCTAssertLessThan(manager.tabs.filter { $0.webViewModel.snapshot != nil }.count, manager.tabs.count / 2,
                "Offscreen groups and cards must not decode every screenshot")
        }
    }

    func testLazyTabStripKeepsCompactHeightWithManyTabs() async throws {
        let key = "tab-strip-\(UUID())"
        let manager = TabManager(storageKey: key)
        for _ in 1..<100 { manager.createTab(switchTo: false) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        var measuredHeight: CGFloat = 0
        window.rootViewController = UIHostingController(rootView: VStack(spacing: 0) {
            BrowserTabBar(tabManager: manager, onNewTab: {})
                .background(GeometryReader { proxy in
                    Color.clear.onAppear { measuredHeight = proxy.size.height }
                })
            Color.red
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            manager.saveToDisk(); UserDefaults.standard.removeObject(forKey: key)
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(measuredHeight, 30)
        XCTAssertLessThan(measuredHeight, 50, "Lazy tab layout must leave the page its vertical space")
    }

    func testSnapshotLoadsOnDemandAndCanBeEvictedWithoutLosingDiskPreview() async throws {
        let wasPrivate = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(wasPrivate, forKey: "is_incognito") }
        let id = UUID()
        // Save through the production queue after the privacy transition. A
        // direct fixture write can race the app's asynchronous snapshot purge.
        let fixture = try await snapshotFixture(id: id, privateMode: false)
        defer { closeSnapshotFixture(fixture); fixture.0.deletePersistedSnapshot() }
        await fixture.0.captureSnapshot()
        XCTAssertNotNil(fixture.0.snapshot)
        fixture.0.releaseSnapshotMemory()
        fixture.0.releaseWebViewRuntime()
        let directory = try XCTUnwrap(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .appendingPathComponent("SouloTabSnapshots", isDirectory: true)
        let file = directory.appendingPathComponent("\(id.uuidString).jpg")
        let model = WebViewModel()
        model.configureSnapshotPersistence(id: id)
        XCTAssertNil(model.snapshot, "Restoring tab metadata must not read every preview")
        await model.loadSnapshotIfNeeded()
        XCTAssertNotNil(model.snapshot)
        model.releaseSnapshotMemory()
        XCTAssertNil(model.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await model.loadSnapshotIfNeeded()
        XCTAssertNotNil(model.snapshot, "A visible card must recover its preview after eviction")
        model.releaseSnapshotMemory()
        model.loadCachedURL(try XCTUnwrap(URL(string: "https://example.com/restored")))
        await model.loadSnapshotIfNeeded(forRestoration: true)
        XCTAssertTrue(model.showSnapshotWhileRestoring, "The active restored page keeps its preview until content appears")
    }

    func testVisitedTabPreviewSurvivesRuntimeEvictionAndRestart() async throws {
        let savedMode = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(savedMode, forKey: "is_incognito") }
        let id = UUID()
        let fixture = try await snapshotFixture(id: id, privateMode: false)
        let (model, web, window, previous) = fixture
        defer { closeSnapshotFixture(fixture); model.deletePersistedSnapshot() }
        await model.captureSnapshot()
        XCTAssertNotNil(model.snapshot)
        model.releaseSnapshotMemory()
        model.releaseWebViewRuntime()
        web.removeFromSuperview()
        let restored = WebViewModel()
        restored.configureSnapshotPersistence(id: id)
        await restored.loadSnapshotIfNeeded()
        XCTAssertNotNil(restored.snapshot, "A suspended or restarted tab must recover its screenshot without loading the website")
        XCTAssertLessThanOrEqual(restored.snapshot?.size.width ?? 1_000, 640)
        let cg = try XCTUnwrap(restored.snapshot?.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let center = (cg.height / 2 * cg.width + cg.width / 2) * 4
        XCTAssertGreaterThan(Int(pixels[center + 2]), Int(pixels[center]) + 20,
            "The persisted screenshot must contain the purple page, not an empty WebKit frame")
        XCTAssertLessThan(Int(pixels[center + 1]), Int(pixels[center]) - 20)
        let attachment = XCTAttachment(image: try XCTUnwrap(restored.snapshot))
        attachment.name = "persisted-tab-preview"; attachment.lifetime = .keepAlways; add(attachment)
        withExtendedLifetime((window, previous)) {}
    }

    func testPrivatePreviewSurvivesMemoryEvictionWithoutWritingToDisk() async throws {
        let savedMode = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(true, forKey: "is_incognito")
        defer { UserDefaults.standard.set(savedMode, forKey: "is_incognito") }
        let id = UUID()
        let fixture = try await snapshotFixture(id: id, privateMode: true)
        let (model, _, _, _) = fixture
        defer { closeSnapshotFixture(fixture); model.deletePersistedSnapshot() }
        await model.captureSnapshot()
        model.releaseSnapshotMemory()
        model.releaseWebViewRuntime()
        await model.loadSnapshotIfNeeded()
        XCTAssertNotNil(model.snapshot, "Private cards retain a compressed in-memory preview")
        for directory in [FileManager.SearchPathDirectory.cachesDirectory, .applicationSupportDirectory] {
            let base = try XCTUnwrap(FileManager.default.urls(for: directory, in: .userDomainMask).first)
            XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("SouloTabSnapshots/\(id.uuidString).jpg").path))
        }
        let fresh = WebViewModel(); fresh.configureSnapshotPersistence(id: id)
        await fresh.loadSnapshotIfNeeded()
        XCTAssertNil(fresh.snapshot, "A separate private runtime must not recover disk data")
    }

    private typealias SnapshotFixture = (WebViewModel, WKWebView, UIWindow, UIWindow?)

    func testFirstPaintSavesCoverWhileAResourceKeepsThePageLoading() async throws {
        let savedMode = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(savedMode, forKey: "is_incognito") }
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/page.html": Data("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Visible before load</title><body style="background:#663399;color:white;min-height:100vh">
            <h1>Content is already visible</h1><img src="/pending.jpg" width="10" height="10"></body>
            """.utf8), "/pending.jpg": Data([0])], heldPaths: ["/pending.jpg"])
        let url = try await server.start().appendingPathComponent("page.html")
        defer { server.stop() }
        let id = UUID()
        let model = WebViewModel(); model.configureSnapshotPersistence(id: id); model.loadURL(url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        defer {
            model.releaseWebViewRuntime(); model.deletePersistedSnapshot()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        // This checks capture before didFinish, not a five-second load budget.
        // A cold simulator may still be launching WebKit and GPU processes.
        for _ in 0..<600 {
            if model.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.hasVisibleContent)
        XCTAssertTrue(model.webView?.isLoading == true, "The held image must prevent didFinish")
        XCTAssertNotNil(model.snapshot, "A painted page needs a cover even if didFinish never arrives")
        model.releaseWebViewRuntime(); model.releaseSnapshotMemory()
        let restored = WebViewModel(); restored.configureSnapshotPersistence(id: id)
        await restored.loadSnapshotIfNeeded()
        XCTAssertNotNil(restored.snapshot, "First-paint covers must survive restart without opening the page")
        XCTAssertNil(restored.webView)
    }

    func testPendingFirstPaintCaptureIsCancelledWhenDocumentChanges() async throws {
        let fixture = try await snapshotFixture(id: UUID(), privateMode: true)
        let model = fixture.0
        defer { closeSnapshotFixture(fixture); model.deletePersistedSnapshot() }
        model.hasInstalledWebViewScripts = true
        model.markPageContentVisible()
        model.beginPageNavigation()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(model.snapshot, "The previous document's delayed capture must not run in a new navigation")
        model.markPageContentVisible()
        for _ in 0..<600 {
            if model.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(model.snapshot)
    }

    func testEvictionDuringCaptureStillSavesCoverWithoutRetainingDecodedImage() async throws {
        let savedMode = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
        defer { UserDefaults.standard.set(savedMode, forKey: "is_incognito") }
        let fixture = try await snapshotFixture(id: UUID(), privateMode: false)
        let model = fixture.0
        defer { closeSnapshotFixture(fixture); model.deletePersistedSnapshot() }
        let captured = expectation(description: "Captured after eviction")
        model.takeSnapshot { captured.fulfill() }
        model.releaseSnapshotMemory()
        await fulfillment(of: [captured], timeout: 5)
        XCTAssertNil(model.snapshot, "A completed capture must respect decoded-image eviction")
        await model.loadSnapshotIfNeeded()
        XCTAssertNotNil(model.snapshot, "Evicting during a capture must not lose the only cover")
    }

    func testFailedPageCoverPersistsAndPrivateErrorsStayInMemory() async throws {
        let savedMode = UserDefaults.standard.object(forKey: "is_incognito")
        defer { UserDefaults.standard.set(savedMode, forKey: "is_incognito") }
        for privateMode in [false, true] {
            UserDefaults.standard.set(privateMode, forKey: "is_incognito")
            let id = UUID()
            let model = WebViewModel(); model.configureSnapshotPersistence(id: id)
            defer { model.deletePersistedSnapshot() }
            model.loadCachedURL(try XCTUnwrap(URL(string: "https://unreachable.example/article?query=full-address")))
            model.setError(LanguageManager.shared.localizedString("error_ssl"))
            await model.captureSnapshot()
            let image = try XCTUnwrap(model.snapshot, "Native failure pages need a cover even without a WebView")
            try assertCoverContainsAddress(image, host: "unreachable.example")
            let attachment = XCTAttachment(image: image)
            attachment.name = privateMode ? "private-error-cover" : "saved-error-cover"
            attachment.lifetime = .keepAlways; add(attachment)
            model.releaseSnapshotMemory()
            await model.loadSnapshotIfNeeded()
            XCTAssertNotNil(model.snapshot)
            let restored = WebViewModel(); restored.configureSnapshotPersistence(id: id)
            await restored.loadSnapshotIfNeeded()
            XCTAssertEqual(restored.snapshot != nil, !privateMode)
            XCTAssertNil(restored.webView)
        }
    }

    func testFailureReplacesAnInFlightWebPageCapture() async throws {
        let fixture = try await snapshotFixture(id: UUID(), privateMode: true)
        let model = fixture.0
        defer { closeSnapshotFixture(fixture); model.deletePersistedSnapshot() }
        model.takeSnapshot()
        model.setError(LanguageManager.shared.localizedString("error_ssl"))
        await model.captureSnapshot()
        let image = try XCTUnwrap(model.snapshot, "A rejected stale capture must not swallow the pending error cover")
        try assertCoverContainsAddress(image, host: "preview.example")
        XCTAssertNotNil(model.errorMessage)
    }

    private func assertCoverContainsAddress(_ image: UIImage, host: String) throws {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
        XCTAssertTrue(text.lowercased().contains(host), "A cover must contain the rendered address, not an empty bitmap: \(text)")
    }

    private func snapshotFixture(id: UUID, privateMode: Bool) async throws -> SnapshotFixture {
        let model = WebViewModel(); model.configureSnapshotPersistence(id: id)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = privateMode ? .nonPersistent() : .default()
        config.setURLSchemeHandler(SnapshotFixtureSchemeHandler(), forURLScheme: "soulo-snapshot")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController()
        var delivered = false
        defer {
            if !delivered {
                model.releaseWebViewRuntime(); web.removeFromSuperview()
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            }
        }
        window.rootViewController?.view.addSubview(web); window.makeKeyAndVisible()
        model.webView = web
        web.load(URLRequest(url: URL(string: "soulo-snapshot://preview.example/article")!))
        var loaded = false
        for _ in 0..<1200 {
            if !web.isLoading, web.url?.host == "preview.example",
               (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent==='Saved tab'")) as? Bool == true {
                loaded = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(loaded, "The snapshot fixture must finish loading before capture")
        guard loaded else { throw URLError(.timedOut) }
        model.updateCurrentURL(web.url)
        try await Task.sleep(for: .milliseconds(150))
        delivered = true
        return (model, web, window, previous)
    }

    private func closeSnapshotFixture(_ fixture: SnapshotFixture) {
        fixture.0.releaseWebViewRuntime(); fixture.1.removeFromSuperview()
        fixture.2.isHidden = true; fixture.2.rootViewController = nil; fixture.3?.makeKeyAndVisible()
    }

    @MainActor private final class State: ObservableObject {
        @Published var isOverview = false
        let web = WKWebView()
        var created = 0
        var dismantled = 0
    }
    private struct Page: UIViewRepresentable {
        let state: State
        func makeCoordinator() -> State { state }
        func makeUIView(context: Context) -> WKWebView {
            state.created += 1
            return state.web
        }
        func updateUIView(_ view: WKWebView, context: Context) {}
        static func dismantleUIView(_ view: WKWebView, coordinator: State) {
            coordinator.dismantled += 1
        }
    }
    private struct Screen: View {
        @ObservedObject var state: State
        var body: some View { Page(state: state).tabOverviewScale(isActive: state.isOverview) }
    }

    private struct SafeAreaScreen: View {
        let fullscreen: Bool
        var body: some View {
            ZStack {
                Color.blue.ignoresSafeArea()
                VStack { Color.red }
                    .ignoresSafeArea(.container, edges: fullscreen ? .all : .bottom)
                    .tabOverviewScale(isActive: false)
            }
        }
    }

    func testInactiveOverviewDoesNotCropContentOutsideSafeArea() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for fullscreen in [false, true] {
            window.rootViewController = UIHostingController(rootView: SafeAreaScreen(fullscreen: fullscreen))
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(250))
            window.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = fullscreen ? "safearea-fullscreen" : "safearea-bottom"
            attachment.lifetime = .keepAlways; add(attachment)
            var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            let rows = fullscreen ? [10, cgImage.height - 10] : [cgImage.height - 10]
            for row in rows {
                let offset = (row * cgImage.width + cgImage.width / 2) * 4
                XCTAssertGreaterThan(pixels[offset], 200, "Safe-area content must remain visible")
                XCTAssertLessThan(pixels[offset + 2], 100, "Root clipping must not expose the blue backdrop")
            }
        }
    }

    func testOverviewAnimationKeepsWebViewMountedAndPageStateIntact() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let state = State()
        window.rootViewController = UIHostingController(rootView: Screen(state: state))
        window.makeKeyAndVisible()
        state.web.loadHTMLString("<html><body><p id='text'>Selected words</p><textarea id='input'>Unsubmitted draft</textarea></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await state.web.evaluateJavaScript("!!document.getElementById('input')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await state.web.evaluateJavaScript("const range=document.createRange();range.selectNodeContents(document.getElementById('text'));getSelection().removeAllRanges();getSelection().addRange(range);window.pageMarker=42")
        let parent = try XCTUnwrap(state.web.superview)
        let originalBounds = state.web.bounds
        let originalSafeArea = state.web.safeAreaInsets
        for _ in 0..<3 {
            for showing in [true, false] {
                withAnimation(.easeInOut(duration: 0.05)) { state.isOverview = showing }
                try await Task.sleep(for: .milliseconds(180))
                XCTAssertEqual(state.created, 1, "Opening overview must not recreate the WebView wrapper")
                XCTAssertEqual(state.dismantled, 0, "Overview must not tear down a live page/selection responder")
                XCTAssertTrue(state.web.superview === parent)
                XCTAssertTrue(state.web.window === window)
                XCTAssertEqual(state.web.bounds, originalBounds, "Overview animation must not resize the page or shift its toolbars")
                XCTAssertEqual(state.web.safeAreaInsets, originalSafeArea, "Safe-area geometry stays stable throughout presentation")
            }
        }
        let selection = try await state.web.evaluateJavaScript("getSelection().toString()") as? String
        let draft = try await state.web.evaluateJavaScript("document.getElementById('input').value") as? String
        let marker = try await state.web.evaluateJavaScript("window.pageMarker") as? Int
        XCTAssertEqual(selection, "Selected words")
        XCTAssertEqual(draft, "Unsubmitted draft")
        XCTAssertEqual(marker, 42)
    }
}

/// Preview persistence tests need a painted document, not a network session.
private final class SnapshotFixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        let data = Data("<body style='background:#663399;color:white'><h1>Saved tab</h1><p>Preview stays available</p></body>".utf8)
        urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count,
            textEncodingName: "utf-8"))
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
