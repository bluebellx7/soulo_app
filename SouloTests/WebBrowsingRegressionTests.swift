import XCTest
import SwiftUI
import WebKit
import Network
@testable import Soulo

/// Real HTTP navigation through the production representable and its delegates.
@MainActor final class WebBrowsingRegressionTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["privacy_gpc_enabled", "privacy_gpc_header_enabled_sites",
                        "privacy_https_upgrade_enabled", "privacy_strip_tracking_parameters", "is_incognito", "ad_block_enabled",
                        "soulo_ad_block_subscription_rules", BrowserAutomaticNavigationPolicy.preferenceKey, BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in keys { saved[key] = defaults.object(forKey: key) }
        defaults.set(try? JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: "soulo_ad_block_subscription_rules")
        defaults.set(true, forKey: "privacy_gpc_enabled")
        defaults.set(["127.0.0.1"], forKey: "privacy_gpc_header_enabled_sites")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set(false, forKey: "privacy_strip_tracking_parameters")
        defaults.set(true, forKey: "is_incognito")
        defaults.set(true, forKey: "ad_block_enabled")
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
        // These regression fixtures drive navigation with synthetic JavaScript.
        defaults.set(true, forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        saved.removeAll()
        super.tearDown()
    }

    func testPrivacyHandlingPreservesAccountSidebarAndRejectsActualCookieBanner() async throws {
        let model = WebViewModel()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        model.webView = web
        defer { model.releaseWebViewRuntime() }
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>.overlay {position:fixed;left:0;top:0;width:280px;height:600px;z-index:200}</style>
        <button id="avatar" onclick="document.body.insertAdjacentHTML('beforeend', document.getElementById('drawerTemplate').innerHTML)">Account</button>
        <template id="drawerTemplate">
          <div id="drawer" role="dialog" class="overlay">
            <nav><a href="/profile">Profile</a><a href="/bookmarks">Bookmarks</a></nav>
            <div role="button">Settings and privacy</div>
            <footer><a href="/privacy">Privacy Policy</a><a href="/cookies">Cookie Policy</a></footer>
          </div>
          <aside id="chineseDrawer" class="overlay"><div role="button">设置与隐私</div></aside>
          <div id="consent-settings-menu" class="overlay"><a href="/reject-list" onclick="window.unrelatedClicks++;return false">Rejected requests</a><div>Settings and privacy</div></div>
        </template>
        <script>window.unrelatedClicks=0;window.rejectClicks=0;</script>
        """, baseURL: URL(string: "https://x.com/home"))
        try await wait(model, for: "!!document.getElementById('avatar')")
        _ = try await web.evaluateJavaScript(WebViewScripts.privacyProtection(gpcEnabled: true, cookieBannerHandling: true))
        _ = try await web.evaluateJavaScript("document.getElementById('avatar').click()")
        try await Task.sleep(for: .milliseconds(700))
        let visible = try await web.evaluateJavaScript("['drawer','chineseDrawer','consent-settings-menu'].map(id=>getComputedStyle(document.getElementById(id)).display !== 'none')")
        XCTAssertEqual(visible as? [Bool], [true, true, true], "Policy links and privacy settings must not turn an account menu into a cookie banner")
        let unrelatedClicks = try await web.evaluateJavaScript("window.unrelatedClicks") as? Int
        XCTAssertEqual(unrelatedClicks, 0, "A consent-like ID must not cause unrelated controls to be clicked")
        _ = try await web.evaluateJavaScript("""
          document.body.insertAdjacentHTML('beforeend', '<div id="cookie-banner" class="overlay" style="height:120px"><p>We use cookies to personalize content.</p><button onclick="window.rejectClicks++;this.parentElement.remove()">Reject optional cookies</button></div>');
        """)
        try await wait(model, for: "window.rejectClicks === 1")
        let drawerVisible = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('drawer')).display !== 'none'") as? Bool
        XCTAssertEqual(drawerVisible, true)
    }

    func testTextSelectionPreservesEditableAndControlSubtrees() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <p id="plain" style="-webkit-user-select:none;user-select:none">Copy this text</p>
        <button style="-webkit-user-select:none;user-select:none"><span id="buttonLabel">Action</span></button>
        <div contenteditable="" style="-webkit-user-select:all;user-select:all"><span id="editor">Editable</span></div>
        <div role="slider" style="-webkit-user-select:none;user-select:none"><span id="sliderLabel">Slider</span></div>
        """, baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('editor')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.evaluateJavaScript(WebViewScripts.textSelection, in: nil, contentWorld: .defaultClient)
        let styles = try await web.evaluateJavaScript("['plain','buttonLabel','editor','sliderLabel'].map(id=>getComputedStyle(document.getElementById(id)).webkitUserSelect)")
        XCTAssertEqual(styles as? [String], ["text", "none", "all", "none"])
    }

    private func host(_ model: WebViewModel) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        return (window, previous)
    }

    private func close(_ model: WebViewModel, _ window: UIWindow, _ previous: UIWindow?) {
        window.isHidden = true
        window.rootViewController = nil
        model.releaseWebViewRuntime()
        previous?.makeKeyAndVisible()
    }

    private func wait(_ model: WebViewModel, for script: String) async throws {
        for _ in 0..<160 {
            if let web = model.webView,
               (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Page condition timed out: \(script), URL: \(String(describing: model.currentURL)), error: \(String(describing: model.errorMessage))")
        throw ReadingToolError.invalid
    }

    func testRestoringTallSnapshotKeepsPageAndToolbarInsideViewport() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        model.snapshot = UIGraphicsImageRenderer(size: CGSize(width: 430, height: 1800), format: format).image { context in
            UIColor.systemGray5.setFill(); context.fill(CGRect(x: 0, y: 0, width: 430, height: 1800))
        }
        model.loadCachedURL(root.appendingPathComponent("unfinished-document"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { close(model, window, previous) }
        window.rootViewController = UIHostingController(rootView:
            VStack(spacing: 0) {
                Text("Platforms").frame(height: 48)
                WebViewContainer(webViewModel: model, bookmarkViewModel: BookmarkViewModel(),
                    isFullscreen: .constant(false), toolbarManuallyHiddenBinding: .constant(false))
            }
            .environmentObject(SearchViewModel())
        )
        window.makeKeyAndVisible()
        try await wait(model, for: "document.body && document.body.getBoundingClientRect().height > 0")
        try await Task.sleep(for: .milliseconds(250))
        window.layoutIfNeeded()
        let web = try XCTUnwrap(model.webView)
        XCTAssertTrue(model.isLoading)
        XCTAssertTrue(model.showSnapshotWhileRestoring)
        let frame = web.convert(web.bounds, to: window)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
        XCTAssertLessThanOrEqual(frame.maxY, window.bounds.maxY + 1,
            "A tall snapshot must not move page controls below the screen")
        XCTAssertLessThanOrEqual(frame.height, window.bounds.height)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "restoring-tab-loading-toolbar"; attachment.lifetime = .keepAlways; add(attachment)
        // Stop must work even when a parser-blocking resource never completes.
        model.reload()
        for _ in 0..<40 {
            if !model.isLoading { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.showSnapshotWhileRestoring)
    }

    func testOldWrapperCleanupCannotDisconnectRemountedPage() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("<html><body><input id='draft' value='kept'></body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('draft')")
        let old = try XCTUnwrap(web.navigationDelegate as? WebViewRepresentable.Coordinator)
        // Mount the retained view before dismantling the departing wrapper,
        // as an interrupted SwiftUI tab transition can do.
        let replacement = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        let replacementWindow = UIWindow(windowScene: try XCTUnwrap(window.windowScene))
        replacementWindow.rootViewController = replacement
        replacementWindow.makeKeyAndVisible()
        defer { replacementWindow.isHidden = true; replacementWindow.rootViewController = nil }
        for _ in 0..<40 {
            if web.navigationDelegate !== old { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let owner = try XCTUnwrap(web.navigationDelegate as? WebViewRepresentable.Coordinator)
        XCTAssertFalse(owner === old)
        WebViewRepresentable.dismantleUIView(web, coordinator: old)
        XCTAssertTrue(model.isWebViewRuntimeInstalled)
        model.beginPageNavigation()
        _ = try await web.evaluateJavaScript(
            "window.webkit.messageHandlers.souloPageReady.postMessage({visible:true});true",
            in: nil, contentWorld: .defaultClient)
        for _ in 0..<40 {
            if model.hasVisibleContent { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(model.hasVisibleContent, "Old cleanup must not remove the new page's bridge")
        let draft = try await web.evaluateJavaScript("document.getElementById('draft').value")
        XCTAssertEqual(draft as? String, "kept")
        withExtendedLifetime(replacement) {}
    }

    func testAppearanceUpdatesDoNotRescanAnUnchangedDocument() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("<html><body><p id='fixture' style='color:black;background:white'>Text</p></body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('fixture') && document.readyState === 'complete'")
        let script = WebViewScripts.applyWebAppearance(warmColorShift: false, forceDark: true,
            reduceMotion: false, underlineLinks: false)
        _ = try await web.evaluateJavaScript(script)
        _ = try await web.evaluateJavaScript("window.styleReads=0;const readStyle=window.getComputedStyle;window.getComputedStyle=(...args)=>{window.styleReads++;return readStyle(...args)};true")
        for _ in 0..<20 { _ = try await web.evaluateJavaScript(script) }
        let reads = try await web.evaluateJavaScript("window.styleReads")
        XCTAssertEqual(reads as? Int, 0, "Repeated progress updates must not scan the DOM again")
        _ = try await web.evaluateJavaScript("const p=document.createElement('p');p.id='added';p.style.cssText='color:black;background:white';document.body.append(p)")
        try await Task.sleep(for: .milliseconds(300))
        let color = try await web.evaluateJavaScript("document.getElementById('added').style.color")
        XCTAssertEqual(color as? String, "rgb(231, 231, 235)", "New content must still receive dark appearance")
        _ = try await web.evaluateJavaScript(WebViewScripts.applyWebAppearance(
            warmColorShift: false, forceDark: false, reduceMotion: false, underlineLinks: false))
        let original = try await web.evaluateJavaScript("document.getElementById('fixture').style.color")
        XCTAssertEqual(original as? String, "black")
    }

    func testRemountReappliesPreferencesAfterUnobservedNavigation() async throws {
        let appearance = WebAppearanceService.shared
        let saved = appearance.reducePageMotion
        appearance.reducePageMotion = false
        defer { appearance.reducePageMotion = saved }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("<html><body id='first'>First</body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('first') && document.readyState === 'complete'")
        appearance.reducePageMotion = true
        appearance.apply(to: web)
        try await wait(model, for: "!!document.getElementById('soulo-reduce-motion-style')")

        window.rootViewController = UIHostingController(rootView: Color.clear)
        for _ in 0..<100 {
            if !model.isWebViewRuntimeInstalled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isWebViewRuntimeInstalled)
        // Offscreen navigation may finish without any attached coordinator.
        web.navigationDelegate = nil
        web.loadHTMLString("<html><body id='second'>Second</body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('second') && document.readyState === 'complete'")
        let staleStyle = try await web.evaluateJavaScript("!!document.getElementById('soulo-reduce-motion-style')")
        XCTAssertEqual(staleStyle as? Bool, false, "The document-start script still holds the original preference")

        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        try await wait(model, for: "!!document.getElementById('soulo-reduce-motion-style')")
        XCTAssertTrue(model.webView === web)
    }

    func testRecycledDarkElementsRestoreOriginalStyles() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("<html><body><p id='recycled' style='color:black;background:white'>Text</p></body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('recycled') && document.readyState === 'complete'")
        _ = try await web.evaluateJavaScript(WebViewScripts.applyWebAppearance(
            warmColorShift: false, forceDark: true, reduceMotion: false, underlineLinks: false))
        _ = try await web.evaluateJavaScript("window.recycled=document.getElementById('recycled');window.recycled.remove();true")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript("document.body.append(window.recycled);true")
        try await Task.sleep(for: .milliseconds(300))
        _ = try await web.evaluateJavaScript(WebViewScripts.applyWebAppearance(
            warmColorShift: false, forceDark: false, reduceMotion: false, underlineLinks: false))
        let color = try await web.evaluateJavaScript("document.getElementById('recycled').style.color")
        XCTAssertEqual(color as? String, "black", "Virtualized pages must recover original styles after dark mode is disabled")
    }

    func testUnchangedAppearanceDoesNotCrossJavaScriptBridgeAgain() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("<html><body><p id='fixture'>Text</p></body></html>", baseURL: nil)
        try await wait(model, for: "!!document.getElementById('fixture') && document.readyState === 'complete'")
        // Drain navigation callbacks before counting ordinary view updates.
        try await Task.sleep(for: .milliseconds(200))
        WebAppearanceService.shared.apply(to: web, force: true)
        _ = try await web.evaluateJavaScript("window.appearanceCalls=0;const apply=window.__souloApplyWebAppearance;window.__souloApplyWebAppearance=c=>{window.appearanceCalls++;apply(c)};true")
        for _ in 0..<30 { WebAppearanceService.shared.apply(to: web) }
        let calls = try await web.evaluateJavaScript("window.appearanceCalls")
        XCTAssertEqual(calls as? Int, 0)
    }

    private func loadAIForm(_ model: WebViewModel, disabled: Bool = false) async throws -> WKWebView {
        try await wait(model, for: "true")
        let web = try XCTUnwrap(model.webView)
        web.loadHTMLString("""
        <html><body><form onsubmit="event.preventDefault()">
        <textarea id="prompt" onkeydown="if(event.key==='Enter') window.enters++"></textarea>
        <button type="submit" data-testid="send-button" aria-label="Send" \(disabled ? "disabled" : "")
          onclick="window.clicks++;this.setAttribute('aria-label','Stop generating')">Send</button>
        </form><script>window.clicks=0;window.enters=0;</script></body></html>
        """, baseURL: URL(string: "https://ai.fixture.test/"))
        try await wait(model, for: "document.readyState === 'complete' && !!document.getElementById('prompt')")
        return web
    }

    func testAIChatSubmitsOnceWithoutClickingStopGeneration() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let web = try await loadAIForm(model)
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.aiChatScript(query: "test query"))
        try await Task.sleep(for: .milliseconds(1900))
        let clicks = try await web.evaluateJavaScript("window.clicks")
        XCTAssertEqual(clicks as? Int, 1)
    }

    func testAIChatDoesNotForceEnableDisabledSendControl() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let web = try await loadAIForm(model, disabled: true)
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.aiChatScript(query: "test query"))
        try await Task.sleep(for: .milliseconds(2000))
        let clicks = try await web.evaluateJavaScript("window.clicks")
        let disabled = try await web.evaluateJavaScript("document.querySelector('button').disabled")
        XCTAssertEqual(clicks as? Int, 0)
        XCTAssertEqual(disabled as? Bool, true)
        AIPlatformInteractionService.cancelInteraction(in: web)
    }

    func testLeavingAIInteractionCancelsDelayedInputAndSubmission() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let web = try await loadAIForm(model)
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.aiChatScript(query: "old query"))
        AIPlatformInteractionService.cancelInteraction(in: web)
        try await Task.sleep(for: .milliseconds(1500))
        let value = try await web.evaluateJavaScript("document.getElementById('prompt').value")
        let clicks = try await web.evaluateJavaScript("window.clicks")
        XCTAssertEqual(value as? String, "")
        XCTAssertEqual(clicks as? Int, 0)
    }

    func testMetasoTextareaUsesCorrectSetterAndOneSubmitMethod() async throws {
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let web = try await loadAIForm(model)
        let query = "what's new?\n中文"
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.metasoSearchScript(query: query))
        try await Task.sleep(for: .milliseconds(1600))
        let value = try await web.evaluateJavaScript("document.getElementById('prompt').value")
        let clicks = try await web.evaluateJavaScript("window.clicks")
        let enters = try await web.evaluateJavaScript("window.enters")
        XCTAssertEqual(value as? String, query)
        XCTAssertEqual(clicks as? Int, 1)
        XCTAssertEqual(enters as? Int, 0, "Click and Enter must not submit the same query twice")
    }

    func testVisibleContentDoesNotWaitForHangingSubresource() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("visible-with-pending-resource"))
        for _ in 0..<100 {
            if model.hasVisibleContent { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        if !model.hasVisibleContent, let web = model.webView {
            let state = try? await web.evaluateJavaScript("({sent:window.__souloPageHasVisibleContent===true,ready:document.readyState,visibility:document.visibilityState,height:document.body?.getBoundingClientRect().height,url:location.href})", in: nil, contentWorld: .defaultClient)
            print("VISIBLE_CONTENT_DIAGNOSTIC", state ?? "nil", "frame", web.frame, "key", window.isKeyWindow, "scene", window.windowScene?.activationState.rawValue ?? -1)
        }
        XCTAssertTrue(model.hasVisibleContent)
        XCTAssertTrue(model.isLoading, "The request is still pending, but the visible page is usable")
        XCTAssertFalse(model.showSnapshotWhileRestoring)
    }

    func testParserBlockedPageDoesNotClaimToHavePaintedContent() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("unfinished-document"))
        try await wait(model, for: "document.body && document.body.getBoundingClientRect().height > 0")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(model.isLoading)
        XCTAssertFalse(model.hasVisibleContent, "Layout alone must not dismiss loading feedback before WebKit renders")
    }

    func testReturningToTabSynchronizesLoadFinishedWhileUnmounted() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("delayed-form"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        window.rootViewController = UIHostingController(rootView: Color.clear)
        for _ in 0..<100 {
            if !model.isWebViewRuntimeInstalled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<100 {
            if !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(web.isLoading)
        XCTAssertTrue(model.isLoading, "The wrapper was absent when the load finished")
        let requests = server.requests.count
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        for _ in 0..<100 {
            if !model.isLoading && model.isWebViewRuntimeInstalled { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(model.isLoading, "Returning must not leave a stale loading indicator")
        XCTAssertTrue(model.webView === web)
        XCTAssertEqual(server.requests.count, requests)
    }

    func testWarmTabsKeepDocumentsAndScriptsWithoutNetworkReloads() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let defaults = UserDefaults.standard
        let savedTabs = defaults.data(forKey: "soulo_saved_tabs")
        defer { defaults.set(savedTabs, forKey: "soulo_saved_tabs") }
        let manager = TabManager(storageKey: "warm-tabs-\(UUID())")
        let first = try XCTUnwrap(manager.activeWebViewModel)
        let (window, previous) = try host(first)
        defer {
            window.isHidden = true; window.rootViewController = nil
            manager.tabs.forEach { $0.webViewModel.releaseWebViewRuntime() }
            previous?.makeKeyAndVisible()
        }
        var views: [WKWebView] = []
        var scripts: [[ObjectIdentifier]] = []
        for i in 0..<TabManager.maxAliveTabs {
            let model = i == 0 ? first : manager.createTab().webViewModel
            window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
            model.loadURL(root.appendingPathComponent("form"))
            try await wait(model, for: "!!document.querySelector('input')")
            let web = try XCTUnwrap(model.webView)
            _ = try await web.evaluateJavaScript("document.querySelector('input').value='Draft \(i)';window.tabMarker=\(i)")
            views.append(web)
            scripts.append(web.configuration.userContentController.userScripts.map(ObjectIdentifier.init))
        }
        let requests = server.requests.filter { $0.path == "/form" }.count
        XCTAssertEqual(requests, TabManager.maxAliveTabs)
        let started = Date()
        for i in views.indices {
            manager.switchToTab(at: i)
            let model = try XCTUnwrap(manager.activeWebViewModel)
            window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
            try await wait(model, for: "window.tabMarker === \(i) && document.querySelector('input').value === 'Draft \(i)'")
            XCTAssertTrue(model.webView === views[i])
            XCTAssertEqual(views[i].configuration.userContentController.userScripts.map(ObjectIdentifier.init), scripts[i])
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/form" }.count, requests)
        print("WARM_TAB_ROUND_TRIP", views.count, Date().timeIntervalSince(started), "seconds; no document reloads")
    }

    func testAdFilteringStartsBeforeBlockedParserFinishes() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("unfinished-document"))
        try await wait(model, for: "document.querySelector('randompiece') && getComputedStyle(document.querySelector('randompiece')).clipPath !== 'none'")
        let readyState = try await model.webView?.evaluateJavaScript("document.readyState")
        XCTAssertEqual(readyState as? String, "loading")
        XCTAssertTrue(model.canMarkAdvertisement, "Slow subresources must not disable selection")
        model.beginMarkingAdvertisement()
        for _ in 0..<100 {
            if !model.manualAdBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.manualAdSelection)
        model.cancelMarkingAdvertisement()
        let content = try await model.webView?.evaluateJavaScript("getComputedStyle(document.querySelector('main')).display")
        XCTAssertNotEqual(content as? String, "none")
    }

    func testBuiltInToggleReloadsCurrentRulesWhilePageIsStillLoading() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("unfinished-document"))
        try await wait(model, for: "document.querySelector('randompiece') && getComputedStyle(document.querySelector('randompiece')).clipPath !== 'none'")
        let store = BuiltInAdRuleStore()
        var rule = try XCTUnwrap(store.rules.first { $0.kind == .tiledBanner })
        rule.isEnabled = false
        let saved = await store.save(rule)
        XCTAssertTrue(saved)
        WebViewRepresentable.reloadWithCurrentAdRules(model)
        try await wait(model, for: "document.querySelector('randompiece') && !window.__souloAdBlockConfig.tiledBanners && getComputedStyle(document.querySelector('randompiece')).clipPath === 'none'")
        for _ in 0..<100 {
            if server.requests.filter({ $0.path == "/unfinished-document" }).count == 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/unfinished-document" }.count, 2)
        rule.isEnabled = true
        let enabled = await store.save(rule)
        XCTAssertTrue(enabled)
        WebViewRepresentable.reloadWithCurrentAdRules(model)
        try await wait(model, for: "document.querySelector('randompiece') && window.__souloAdBlockConfig.tiledBanners && getComputedStyle(document.querySelector('randompiece')).clipPath !== 'none'")
    }

    func testConservativeBuiltInsPreserveOrdinaryResourcesAndStillBlockAds() async throws {
        let defaults = UserDefaults.standard
        let subscriptionKey = "soulo_ad_block_subscription_rules"
        let subscriptions = defaults.data(forKey: subscriptionKey)
        let versionKey = subscriptionKey + "_version"
        let version = defaults.object(forKey: versionKey)
        // Explicitly isolate built-ins now that production subscriptions live on disk.
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: subscriptionKey)
        defaults.set(Date().timeIntervalSince1970, forKey: versionKey)
        defer { defaults.set(subscriptions, forKey: subscriptionKey); defaults.set(version, forKey: versionKey) }
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        for _ in 0..<100 {
            if model.webView != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let compiled = await AdBlockService.compileRuleLists()
        let readyWeb = try XCTUnwrap(model.webView)
        WebViewRepresentable.applyContentRules(try XCTUnwrap(compiled), on: readyWeb, allowlist: [])
        model.loadURL(root.appendingPathComponent("conservative-rules"))
        do {
            try await wait(model, for: "window.fixtureScripts === 4 && window.fixtureFetches === 2 && document.querySelector('#portrait').naturalWidth > 0")
        } catch {
            print("RESOURCE_FIXTURE_REQUESTS", server.requests.map(\.path))
            print("RESOURCE_FIXTURE_STATE", try await readyWeb.evaluateJavaScript("JSON.stringify({scripts:window.fixtureScripts,fetches:window.fixtureFetches,image:document.querySelector('#portrait')?.naturalWidth})") as Any)
            throw error
        }
        let web = try XCTUnwrap(model.webView)
        let contentVisible = try await web.evaluateJavaScript("""
            ['download-panel','ggrid','normal-frame','portrait','player','login'].every(id => getComputedStyle(document.getElementById(id)).display !== 'none')
            """)
        XCTAssertEqual(contentVisible as? Bool, true)
        try await wait(model, for: "getComputedStyle(document.getElementById('float-bottom-ad')).display === 'none'")
        XCTAssertFalse(server.requests.contains { $0.path == "/ads/banner.js" }, "An explicit ads directory must still be blocked")
        XCTAssertTrue(server.requests.contains { $0.path == "/gg/player.js" })
        XCTAssertTrue(server.requests.contains { $0.path == "/adpic/portrait.svg" })
        XCTAssertNil(model.errorMessage)
    }

    func testGPCDoesNotReplaceTopPageWithIframe() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("iframe"))
        try await wait(model, for: "document.getElementById('frame')?.contentDocument?.getElementById('child')?.textContent === 'Embedded content'")
        XCTAssertEqual(model.webView?.url?.path, "/iframe")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(server.requests.filter { $0.path == "/iframe" }.count, 1)
        XCTAssertEqual(server.requests.first { $0.path == "/iframe" }?.gpc, "1")
    }

    func testPOSTRedirectHistoryAndNewWindowLinks() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.getElementById('form').submit()")
        try await wait(model, for: "!!document.getElementById('receipt')")
        let submissions = server.requests.filter { $0.path == "/submit" }
        XCTAssertEqual(submissions.count, 1, "POST must not be replayed while applying privacy headers")
        XCTAssertEqual(submissions.first?.method, "POST")
        XCTAssertEqual(submissions.first?.body, "query=a%2Bb+%26+c")
        XCTAssertEqual(web.url?.path, "/receipt")
        XCTAssertTrue(web.canGoBack)
        web.goBack()
        try await wait(model, for: "!!document.getElementById('form')")
        XCTAssertTrue(web.canGoForward)
        web.goForward()
        try await wait(model, for: "!!document.getElementById('receipt')")
        _ = try await web.evaluateJavaScript("document.getElementById('next').click()")
        try await wait(model, for: "!!document.getElementById('destination')")
        XCTAssertEqual(web.url?.path, "/destination")
        XCTAssertNil(model.errorMessage)
    }

    func testAdRuleChangesKeepOtherScriptsAndFollowSPARoutes() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let url = root.appendingPathComponent("dynamic")
        model.loadURL(url)
        try await wait(model, for: "!!document.getElementById('user-chosen-panel')")
        let web = try XCTUnwrap(model.webView)
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__regressionScript = (window.__regressionScript || 0) + 1;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let rule = try XCTUnwrap(ManualAdBlockService.shared.save(url: url, selector: "#user-chosen-panel", wholeSite: false))
        defer { ManualAdBlockService.shared.remove(rule.id) }
        try await wait(model, for: "getComputedStyle(document.getElementById('user-chosen-panel')).display === 'none'")
        _ = try await web.evaluateJavaScript("history.pushState({}, '', '/dynamic-next')")
        try await wait(model, for: "getComputedStyle(document.getElementById('user-chosen-panel')).display !== 'none'")
        web.reload()
        try await wait(model, for: "window.__regressionScript === 1 && !!document.getElementById('user-chosen-panel')")
        XCTAssertEqual(web.url?.path, "/dynamic-next")
        XCTAssertNil(model.errorMessage)
    }

    func testNewWindowPOSTKeepsSubmittedBody() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form-popup"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.getElementById('form').submit()")
        for _ in 0..<100 {
            if server.requests.contains(where: { $0.path == "/receipt" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let submissions = server.requests.filter { $0.path == "/submit" }
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.method, "POST")
        XCTAssertEqual(submissions.first?.body, "query=a%2Bb+%26+c", "New-window submissions must keep the original form body")
    }

    func testAuthenticationPopupSharesSessionAndReturnsToOpener() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("auth-parent"))
        try await wait(model, for: "!!document.getElementById('open-login')")
        let web = try XCTUnwrap(model.webView)
        // Use window.open rather than target=_blank (which has implicit noopener).
        _ = try await web.evaluateJavaScript("document.cookie='fixture_session=parent; path=/'; document.getElementById('open-login').click()")
        try await wait(model, for: "window.authResult === 'session-shared'")
        XCTAssertEqual(web.url?.path, "/auth-parent", "Popup login must leave the original page intact")
        let cookies = try await web.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(cookies?.contains("fixture_login=complete") == true)
        for _ in 0..<100 {
            if !web.subviews.contains(where: { $0.subviews.contains(where: { $0 is WKWebView }) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(web.subviews.contains(where: { $0.subviews.contains(where: { $0 is WKWebView }) }), "window.close must dismiss the authentication popup")
        XCTAssertNil(model.errorMessage)
    }

    func testRemountKeepsFormHistoryAndDoesNotDuplicateScripts() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("destination"))
        try await wait(model, for: "!!document.getElementById('destination')")
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.querySelector('input').value='Unsaved draft'; window.tabMarker=42")
        let scriptCount = web.configuration.userContentController.userScripts.count
        let scriptIDs = web.configuration.userContentController.userScripts.map(ObjectIdentifier.init)
        let requestCount = server.requests.count
        for _ in 0..<3 {
            window.rootViewController = UIHostingController(rootView: Color.clear)
            for _ in 0..<100 {
                if !model.isWebViewRuntimeInstalled { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.isWebViewRuntimeInstalled)
            XCTAssertEqual(web.configuration.userContentController.userScripts.map(ObjectIdentifier.init), scriptIDs)
            window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
            for _ in 0..<100 {
                if model.isWebViewRuntimeInstalled { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.isWebViewRuntimeInstalled)
            XCTAssertTrue(model.webView === web)
            try await wait(model, for: "window.tabMarker === 42 && document.querySelector('input')?.value === 'Unsaved draft'")
            XCTAssertEqual(web.configuration.userContentController.userScripts.count, scriptCount)
            XCTAssertTrue(web.canGoBack)
        }
        XCTAssertEqual(server.requests.count, requestCount, "Returning to an existing tab must not reload its page")
        web.goBack()
        try await wait(model, for: "!!document.getElementById('destination')")
    }

    func testSubscriptionRulesBlockAndAllowRealRequestsAcrossBatches() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let key = "soulo_ad_block_subscription_rules"
        let savedCache = UserDefaults.standard.data(forKey: key)
        defer { UserDefaults.standard.set(savedCache, forKey: key) }
        let rules = AdBlockRuleParser.parse("""
        ||127.0.0.1/subscription/
        /subscription/*
        @@/subscription/allowed|
        /scoped$domain=127.0.0.1|~localhost
        /excluded$domain=127.0.0.1|~127.0.0.1
        /CaseSensitive$match-case
        /image-exempt$~image
        ##.qa-hidden
        ##.qa-excepted
        127.0.0.1#@#.qa-excepted
        localhost#@#.qa-hidden
        127.0.0.1##.qa-site
        @@/document-exempt|$document
        @@/cosmetic-exempt|$elemhide
        @@/generic-exempt|$generichide
        """)
        UserDefaults.standard.set(try JSONEncoder().encode(rules), forKey: key)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Force several batches so exceptions must cancel blocks in every batch.
        let batches = AdBlockService.encodedContentRuleLists(batchSize: 40)
        XCTAssertGreaterThan(batches.count, 2)
        for (index, json) in batches.enumerated() {
            let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "subscription-execution-\(UUID())-\(index)", encodedContentRuleList: json)
            configuration.userContentController.add(try XCTUnwrap(list))
        }
        configuration.userContentController.addUserScript(WKUserScript(source: AdBlockService.adHidingScript(),
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let model = WebViewModel(); model.webView = web
        defer { model.releaseWebViewRuntime() }
        web.load(URLRequest(url: root.appendingPathComponent("destination")))
        try await wait(model, for: "!!document.getElementById('destination')")
        func fetch(_ path: String) async throws -> Bool {
            try await web.callAsyncJavaScript("try { return (await fetch(path, {cache:'no-store'})).ok; } catch (_) { return false; }",
                arguments: ["path": path], in: nil, contentWorld: .page) as? Bool == true
        }
        for (path, expected) in [("/subscription/blocked", false), ("/subscription/allowed", true),
                                 ("/normal?help=subscription", true), ("/scoped", false), ("/excluded", true),
                                 ("/CaseSensitive", false), ("/casesensitive", true), ("/image-exempt", false)] {
            let result = try await fetch(path)
            XCTAssertEqual(result, expected, path)
        }
        _ = try await web.evaluateJavaScript("""
            document.body.insertAdjacentHTML('beforeend', '<aside class="qa-hidden">Hidden ad</aside><aside class="qa-excepted">Allowed content</aside><img src="/image-exempt">');
            """)
        try await Task.sleep(for: .milliseconds(300))
        try await wait(model, for: "getComputedStyle(document.querySelector('.qa-hidden')).display === 'none'")
        let visible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.qa-excepted')).display !== 'none'")
        XCTAssertEqual(visible as? Bool, true)
        for _ in 0..<40 {
            if server.requests.contains(where: { $0.path == "/image-exempt" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.requests.contains { $0.path == "/image-exempt" }, "Negated image type must preserve an actual image request")
        XCTAssertFalse(server.requests.contains { $0.path == "/subscription/blocked" })
        XCTAssertTrue(server.requests.contains { $0.path == "/subscription/allowed" })
        // An exception scoped to 127.0.0.1 must not expose the ad on localhost.
        let localhost = try XCTUnwrap(URL(string: root.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/destination"))
        web.load(URLRequest(url: localhost))
        try await wait(model, for: "location.hostname === 'localhost' && !!document.getElementById('destination')")
        _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<aside class=qa-hidden>Allowed here</aside><aside class=qa-excepted>Hidden here</aside>')")
        try await wait(model, for: "getComputedStyle(document.querySelector('.qa-excepted')).display === 'none'")
        let localVisible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.qa-hidden')).display !== 'none'")
        XCTAssertEqual(localVisible as? Bool, true)
        let scopedAllowed = try await fetch("/scoped")
        XCTAssertTrue(scopedAllowed)
        for path in ["document-exempt", "cosmetic-exempt", "generic-exempt"] {
            web.load(URLRequest(url: root.appendingPathComponent(path)))
            try await wait(model, for: "location.pathname === '/\(path)' && !!document.getElementById('destination')")
            _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<aside class=qa-hidden>Generic</aside><aside class=qa-site>Site specific</aside>')")
            try await Task.sleep(for: .milliseconds(250))
            let styles = try await web.evaluateJavaScript("['.qa-hidden','.qa-site'].map(s => getComputedStyle(document.querySelector(s)).display !== 'none')") as? [Bool]
            XCTAssertEqual(styles, [true, path != "generic-exempt"], path)
            let allowed = try await fetch("/subscription/blocked")
            XCTAssertEqual(allowed, path == "document-exempt", path)
        }
    }

    func testLateCompiledRulesRespectDisabledFilterAndChallengePage() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let model = WebViewModel()
        model.webView = web
        defer { model.releaseWebViewRuntime() }
        web.load(URLRequest(url: root.appendingPathComponent("destination")))
        try await wait(model, for: "!!document.getElementById('destination')")
        let compiled = await AdBlockService.compileRuleLists()
        let rules = try XCTUnwrap(compiled)
        func canFetch() async throws -> Bool {
            let result = try await web.callAsyncJavaScript(
                "try { return (await fetch('/ads/probe', {cache:'no-store'})).ok; } catch (_) { return false; }",
                arguments: [:], in: nil, contentWorld: .page)
            return result as? Bool == true
        }
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let blocked = try await canFetch()
        XCTAssertFalse(blocked, "Control: the native rule must actually block this resource")
        UserDefaults.standard.set(false, forKey: "ad_block_enabled")
        // Deliver the compiled result after the preference changed.
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let disabled = try await canFetch()
        XCTAssertTrue(disabled, "Late compilation must not re-enable a disabled filter")
        UserDefaults.standard.set(true, forKey: "ad_block_enabled")
        web.load(URLRequest(url: root.appendingPathComponent("login")))
        try await wait(model, for: "location.pathname === '/login' && !!document.getElementById('destination')")
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let challenge = try await canFetch()
        XCTAssertTrue(challenge, "Late compilation must respect the current challenge page bypass")
    }

    func testAutomaticNavigationIsAllowedByDefaultAndSettingAppliesImmediately() async throws {
        UserDefaults.standard.removeObject(forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("automatic-location"))
        try await wait(model, for: "!!document.getElementById('destination')")
        UserDefaults.standard.set(false, forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
        let previousDestinationCount = server.requests.filter { $0.path == "/destination" }.count
        for path in ["automatic-location", "automatic-immediate", "automatic-meta", "automatic-popup", "automatic-link", "automatic-form", "automatic-frame"] {
            model.loadURL(root.appendingPathComponent(path))
            try await wait(model, for: "!!document.getElementById('automatic')")
            try await Task.sleep(for: .milliseconds(1300))
            XCTAssertEqual(model.webView?.url?.path, "/" + path)
            XCTAssertNil(model.errorMessage)
            XCTAssertFalse(model.webView?.subviews.contains(where: { $0.subviews.contains(where: { $0 is WKWebView }) }) == true)
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/destination" }.count, previousDestinationCount)
        XCTAssertFalse(server.requests.contains { $0.path == "/login-popup" })
        UserDefaults.standard.set(true, forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
        model.loadURL(root.appendingPathComponent("automatic-popup"))
        for _ in 0..<100 {
            if server.requests.contains(where: { $0.path == "/login-popup" }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertTrue(server.requests.contains { $0.path == "/login-popup" })
        model.loadURL(root.appendingPathComponent("automatic-location"))
        try await wait(model, for: "!!document.getElementById('destination')")
        UserDefaults.standard.set(false, forKey: BrowserAutomaticNavigationPolicy.preferenceKey)
        // Native navigation and its HTTP redirect must still work while blocking page scripts.
        model.loadURL(root.appendingPathComponent("submit"))
        try await wait(model, for: "!!document.getElementById('receipt')")
        model.loadURL(root.appendingPathComponent("automatic-location"))
        try await wait(model, for: "!!document.getElementById('automatic')")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(model.webView?.url?.path, "/automatic-location")
    }

    func testPullToRefreshRevalidatesCachedPageAndResources() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("cache-page"))
        try await wait(model, for: "document.getElementById('revision')?.textContent === '1' && window.fixtureRevision === 1")
        let web = try XCTUnwrap(model.webView)
        // Confirm the subresource is actually cached before exercising the gesture.
        _ = try await web.callAsyncJavaScript("""
            return await new Promise((resolve, reject) => {
                const script = document.createElement('script');
                script.src = '/cache-resource.js';
                script.onload = () => resolve(true);
                script.onerror = () => reject(new Error('Script failed to load'));
                document.head.append(script);
            });
            """,
            arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(server.requests.filter { $0.path == "/cache-resource.js" }.count, 1)
        let historyCount = web.backForwardList.backList.count
        let control = try XCTUnwrap(web.scrollView.refreshControl)
        control.beginRefreshing()
        control.sendActions(for: .valueChanged)
        try await wait(model, for: "document.getElementById('revision')?.textContent === '2' && window.fixtureRevision === 2")
        for _ in 0..<100 {
            if !control.isRefreshing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(server.requests.filter { $0.path == "/cache-page" }.count, 2)
        XCTAssertEqual(server.requests.filter { $0.path == "/cache-resource.js" }.count, 2)
        XCTAssertFalse(control.isRefreshing)
        XCTAssertEqual(web.backForwardList.backList.count, historyCount)
    }

    func testDesktopModeReloadsCurrentPageWithDesktopPreferences() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let manager = TabManager(storageKey: "desktop-mode-\(UUID())")
        let model = try XCTUnwrap(manager.activeWebViewModel)
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("destination"))
        try await wait(model, for: "!!document.getElementById('destination')")
        let web = try XCTUnwrap(model.webView)
        let historyCount = web.backForwardList.backList.count

        manager.setDesktopModeEnabled(true)
        for _ in 0..<100 {
            if server.requests.filter({ $0.path == "/destination" }).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await wait(model, for: "navigator.userAgent.includes('Macintosh')")
        XCTAssertEqual(web.configuration.defaultWebpagePreferences.preferredContentMode, .desktop)
        XCTAssertEqual(server.requests.filter { $0.path == "/destination" }.count, 2)

        manager.setDesktopModeEnabled(false)
        for _ in 0..<100 {
            if server.requests.filter({ $0.path == "/destination" }).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await wait(model, for: "navigator.userAgent.includes('iPhone')")
        XCTAssertEqual(web.configuration.defaultWebpagePreferences.preferredContentMode, .mobile)
        XCTAssertEqual(server.requests.filter { $0.path == "/destination" }.count, 3)
        XCTAssertEqual(web.backForwardList.backList.count, historyCount)
    }

    func testRapidNavigationRefreshAndRecoveryAfterNetworkFailure() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form"))
        model.loadURL(root.appendingPathComponent("destination"))
        try await wait(model, for: "!!document.getElementById('destination')")
        let web = try XCTUnwrap(model.webView)
        web.scrollView.refreshControl?.beginRefreshing()
        web.scrollView.refreshControl?.sendActions(for: .valueChanged)
        for _ in 0..<100 {
            if server.requests.filter({ $0.path == "/destination" }).count >= 2,
               web.scrollView.refreshControl?.isRefreshing == false { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(server.requests.filter { $0.path == "/destination" }.count, 2)
        XCTAssertEqual(web.scrollView.refreshControl?.isRefreshing, false)
        model.loadURL(root.appendingPathComponent("disconnect"))
        for _ in 0..<100 {
            if model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(model.errorMessage)
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(web.url?.path, "/form")
    }
}

private final class BrowsingHTTPFixture: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: String
        let gpc: String?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.browsing.fixture")
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    private var startupCompleted = false
    var requests: [Request] { queue.sync { recorded } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startupCompleted else { return }
                switch state {
                case .ready:
                    self.startupCompleted = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.startupCompleted = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffered
            if let data { bytes.append(data) }
            guard bytes.count < 1024 * 1024 else { connection.cancel(); return }
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if first.count >= 2, bytes.count - split.upperBound >= length {
                    let request = Request(method: String(first[0]), path: String(first[1]),
                        body: String(decoding: bytes[split.upperBound..<split.upperBound + length], as: UTF8.self), gpc: headers["sec-gpc"])
                    self.recorded.append(request)
                    self.respond(connection, to: request)
                    return
                }
            }
            if done || error != nil { connection.cancel() }
            else { self.receive(connection, buffered: bytes) }
        }
    }

    private func respond(_ connection: NWConnection, to request: Request) {
        let body: String
        var status = "200 OK"
        var extra = ""
        var contentType = "text/html; charset=utf-8"
        switch request.path {
        case "/conservative-rules": body = """
            <main id="download-panel"><span id="ggrid" class="gg gg-play not-popup-ad">Download</span>
            <img id="portrait" src="/adpic/portrait.svg"><video id="player" controls></video>
            <form id="login"><input type="password"></form></main>
            <iframe id="normal-frame" src="/child?source=doubleclick"></iframe>
            <aside id="float-bottom-ad">Advertisement</aside>
            <script>window.fixtureScripts=0;window.fixtureFetches=0;
            ['/data?ad=normal','/proxy?url=https://doubleclick.net/content'].forEach(url=>fetch(url).then(r=>{if(r.ok)window.fixtureFetches++}));</script>
            <script src="/gg/player.js"></script><script src="/union/member.js"></script>
            <script src="/gpt.js"></script><script src="/app.js?help=googlesyndication.com"></script>
            <script src="/ads/banner.js"></script>
            """
        case "/gg/player.js", "/union/member.js", "/gpt.js", "/app.js?help=googlesyndication.com", "/ads/banner.js":
            body = "window.fixtureScripts++;"
            contentType = "application/javascript"
        case "/adpic/portrait.svg":
            body = "<svg xmlns='http://www.w3.org/2000/svg' width='16' height='16'><rect width='16' height='16' fill='green'/></svg>"
            contentType = "image/svg+xml"
        case "/hanging-resource.js": return // Keep parsing blocked until fixture teardown.
        case "/visible-with-pending-resource": body = "<main>Visible content</main><script async src='/hanging-resource.js'></script>"
        case "/unfinished-document": body = """
            <main>Visible content</main><script>
            for (let i=0;i<10;i++) {
              const e=document.createElement('randompiece');
              e.style.cssText='position:fixed;bottom:0;width:10%;height:100px;z-index:2147483646;background-image:linear-gradient(red,red);background-position:0 0;left:'+i*10+'%';
              document.body.append(e);
            }
            </script><script src='/hanging-resource.js'></script>
            """
        case "/automatic-immediate": body = "<p id='automatic'>Stay here</p><script>location.href='/destination'</script>"
        case "/automatic-location": body = "<p id='automatic'>Stay here</p><script>setTimeout(() => location.href='/destination', 200)</script>"
        case "/automatic-meta": body = "<p id='automatic'>Stay here</p><meta http-equiv='refresh' content='1;url=/destination'>"
        case "/automatic-popup": body = "<p id='automatic'>Stay here</p><script>setTimeout(() => window.open('/login-popup'), 200)</script>"
        case "/automatic-link": body = "<p id='automatic'>Stay here</p><a id='go' href='/destination'>Next</a><script>setTimeout(() => document.getElementById('go').click(), 200)</script>"
        case "/automatic-form": body = "<p id='automatic'>Stay here</p><form id='go' action='/destination'></form><script>setTimeout(() => document.getElementById('go').submit(), 200)</script>"
        case "/automatic-frame": body = "<p id='automatic'>Stay here</p><iframe src='/automatic-child'></iframe>"
        case "/automatic-child": body = "<script>setTimeout(() => top.location.href='/destination', 200)</script>"
        case "/cache-page":
            body = "<p id='revision'>\(recorded.filter { $0.path == request.path }.count)</p><script src='/cache-resource.js'></script>"
            extra = "Cache-Control: public, max-age=86400\r\n"
        case "/cache-resource.js":
            body = "window.fixtureRevision = \(recorded.filter { $0.path == request.path }.count);"
            contentType = "application/javascript"
            extra = "Cache-Control: public, max-age=86400\r\n"
        case "/auth-parent": body = "<button id='open-login' onclick=\"window.open('/login-popup','fixture-auth')\">Sign in</button><script>addEventListener('message', e => { if (e.origin === location.origin) window.authResult = e.data; });</script>"
        case "/login-popup": body = "<script>const shared = document.cookie.includes('fixture_session=parent'); document.cookie='fixture_login=complete; path=/'; window.opener.postMessage(shared ? 'session-shared' : 'missing-session', location.origin); window.close();</script>"
        case "/disconnect": connection.cancel(); return
        case "/dynamic", "/dynamic-next": body = "<main>Article content</main><aside id='user-chosen-panel'>Selected panel</aside>"
        case "/iframe": body = "<h1 id='parent'>Parent page</h1><iframe id='frame' src='/child'></iframe>"
        case "/child": body = "<p id='child'>Embedded content</p>"
        case "/delayed-form": body = "<form id='form'><input></form><script src='/delayed.js'></script>"
        case "/delayed.js":
            queue.asyncAfter(deadline: .now() + 1) {
                connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: application/javascript\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        case "/form": body = "<form id='form' method='post' action='/submit'><input name='query' value='a+b &amp; c'><button>Submit</button></form>"
        case "/form-popup": body = "<form id='form' method='post' action='/submit' target='_blank'><input name='query' value='a+b &amp; c'><button>Submit</button></form>"
        case "/submit": body = "Redirecting"; status = "303 See Other"; extra = "Location: /receipt\r\n"
        case "/receipt": body = "<p id='receipt'>Submitted</p><a id='next' href='/destination' target='_blank'>Next page</a>"
        default: body = "<p id='destination'>Destination</p>"
        }
        let content = contentType != "text/html; charset=utf-8" ? body
            : "<!doctype html><html><head><meta name='viewport' content='width=device-width'><title>Browsing fixture</title></head><body>\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(content.utf8.count)\r\n\(extra)Connection: close\r\n\r\n\(content)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
