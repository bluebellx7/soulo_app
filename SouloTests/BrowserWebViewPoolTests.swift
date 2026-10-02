import SwiftUI
import WebKit
import XCTest
@testable import Soulo

@MainActor
final class BrowserWebViewPoolTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for WebView lifecycle")
        throw CancellationError()
    }

    func testWarmupHasNoNavigationScriptsOrHistoryAndIsClaimedOnlyOnce() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .seconds(60))
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        let spare = try XCTUnwrap(pool.preparedWebView)
        XCTAssertNil(spare.url)
        XCTAssertNil(spare.backForwardList.currentItem)
        XCTAssertTrue(spare.configuration.userContentController.userScripts.isEmpty)
        XCTAssertTrue(spare.configuration.websiteDataStore.isPersistent)
        pool.activate(isIncognito: false)
        XCTAssertTrue(pool.preparedWebView === spare)
        let first = pool.makeWebView(isIncognito: false, for: URL(string: "https://example.com"))
        let second = pool.makeWebView(isIncognito: false, for: nil)
        XCTAssertTrue(first === spare)
        XCTAssertFalse(second === spare)
        XCTAssertNil(first.navigationDelegate)
        XCTAssertNil(pool.preparedWebView)
        XCTAssertTrue(first.configuration.allowsInlineMediaPlayback)
        XCTAssertTrue(first.configuration.preferences.isElementFullscreenEnabled)
        if #available(iOS 18.4, *) {
            XCTAssertTrue(first.configuration.webExtensionController === NativeWebExtensionRuntime.shared.controller)
        }
    }

    func testPrivacyChangeDiscardsSpareAndPrivateTabsKeepSeparateStores() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .seconds(60))
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        weak var normalSpare = pool.preparedWebView
        // Acquisition also checks mode, before SwiftUI's onChange can run.
        let privateWeb = pool.makeWebView(isIncognito: true, for: nil)
        XCTAssertFalse(privateWeb.configuration.websiteDataStore.isPersistent)
        XCTAssertNil(pool.preparedWebView)
        try await waitUntil { normalSpare == nil }
        let anotherPrivateWeb = pool.makeWebView(isIncognito: true, for: nil)
        XCTAssertFalse(privateWeb.configuration.websiteDataStore === anotherPrivateWeb.configuration.websiteDataStore)
        if #available(iOS 18.4, *) { XCTAssertNil(privateWeb.configuration.webExtensionController) }
        pool.suspend()
        pool.activate(isIncognito: true)
        try await waitUntil { pool.isPreparedWebViewReady }
        let privateSpare = try XCTUnwrap(pool.preparedWebView)
        XCTAssertFalse(privateSpare.configuration.websiteDataStore.isPersistent)
        XCTAssertTrue(pool.makeWebView(isIncognito: true, for: nil) === privateSpare)
        pool.activate(isIncognito: false)
        let normalWeb = pool.makeWebView(isIncognito: false, for: nil)
        XCTAssertFalse(normalWeb === privateSpare)
        XCTAssertTrue(normalWeb.configuration.websiteDataStore.isPersistent)
    }

    func testExtensionOriginBypassesSpare() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .seconds(60))
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        let spare = try XCTUnwrap(pool.preparedWebView)
        let extensionWeb = pool.makeWebView(isIncognito: false, for: URL(string: "webkit-extension://test/options.html"))
        XCTAssertFalse(extensionWeb === spare)
        XCTAssertTrue(pool.preparedWebView === spare)
        XCTAssertTrue(pool.makeWebView(isIncognito: false, for: URL(string: "https://example.com")) === spare)
    }

    func testInstalledExtensionPageLoadsWithItsOwningConfiguration() async throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Requires native extensions") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"manifest_version":3,"name":"Warmup configuration fixture","version":"1.0"}"#.utf8)
            .write(to: directory.appendingPathComponent("manifest.json"))
        try Data("<title>Extension configuration</title><p>Ready</p>".utf8)
            .write(to: directory.appendingPathComponent("options.html"))
        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        let controller = NativeWebExtensionRuntime.shared.controller
        try controller.load(context)
        defer { try? controller.unload(context) }
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .seconds(60))
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        let spare = try XCTUnwrap(pool.preparedWebView)
        let url = context.baseURL.appendingPathComponent("options.html")
        let web = pool.makeWebView(isIncognito: false, for: url)
        XCTAssertFalse(web === spare)
        web.load(URLRequest(url: url))
        try await waitUntil { web.title == "Extension configuration" && !web.isLoading }
        XCTAssertEqual(web.url, url)
        XCTAssertTrue(pool.preparedWebView === spare)
    }

    func testMemoryWarningReleasesOnlySpareAndSuppressesRefillUntilForeground() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .zero)
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        let claimed = pool.makeWebView(isIncognito: false, for: nil)
        _ = try await claimed.evaluateJavaScript("window.tabState = 42")
        try await waitUntil { pool.isPreparedWebViewReady }
        weak var spare = pool.preparedWebView
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        XCTAssertNil(pool.preparedWebView)
        try await waitUntil { spare == nil }
        pool.activate(isIncognito: false)
        _ = pool.makeWebView(isIncognito: false, for: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pool.preparedWebView)
        let state = try await claimed.evaluateJavaScript("window.tabState") as? Int
        XCTAssertEqual(state, 42)
        pool.suspend()
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
    }

    func testBackgroundCancelsPendingWarmupAndReleasesReadySpare() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .milliseconds(50))
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(pool.preparedWebView)
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        weak var spare = pool.preparedWebView
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertNil(pool.preparedWebView)
        try await waitUntil { spare == nil }
    }

    func testTerminatedSpareIsDiscardedWithoutTouchingClaimedView() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .zero)
        defer { pool.suspend() }
        pool.activate(isIncognito: false)
        try await waitUntil { pool.isPreparedWebViewReady }
        let first = pool.makeWebView(isIncognito: false, for: nil)
        try await waitUntil { pool.isPreparedWebViewReady }
        let spare = try XCTUnwrap(pool.preparedWebView)
        pool.webViewWebContentProcessDidTerminate(first)
        XCTAssertTrue(pool.preparedWebView === spare)
        pool.webViewWebContentProcessDidTerminate(spare)
        XCTAssertNil(pool.preparedWebView)
        let fallback = pool.makeWebView(isIncognito: false, for: nil)
        XCTAssertFalse(fallback === spare)
    }

    func testClaimDuringWarmupDoesNotLetCompletionReclaimTab() async throws {
        let pool = BrowserWebViewPool(warmupDelay: .zero, refillDelay: .seconds(60))
        defer { pool.suspend() }
        pool.activate(isIncognito: true)
        try await waitUntil { pool.preparedWebView != nil }
        let spare = try XCTUnwrap(pool.preparedWebView)
        let claimed = pool.makeWebView(isIncognito: true, for: nil)
        XCTAssertTrue(claimed === spare)
        _ = try await claimed.evaluateJavaScript("42")
        XCTAssertNil(pool.preparedWebView)
        XCTAssertFalse(pool.isPreparedWebViewReady)
        XCTAssertNil(claimed.navigationDelegate)
    }

    func testFirstSearchUsesWarmViewAndInstallsCurrentRuntimeBeforeNavigation() async throws {
        try await verifyProductionHandoff(isIncognito: false, restoring: false)
    }

    func testRestoredPrivateTabUsesWarmViewWithoutBlankBackItem() async throws {
        try await verifyProductionHandoff(isIncognito: true, restoring: true)
    }

    private func verifyProductionHandoff(isIncognito: Bool, restoring: Bool) async throws {
        let defaults = UserDefaults.standard
        let keys = ["is_incognito", "ad_block_enabled", "privacy_gpc_enabled"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(isIncognito, forKey: "is_incognito")
        defaults.set(false, forKey: "ad_block_enabled")
        defaults.set(false, forKey: "privacy_gpc_enabled")
        let pool = BrowserWebViewPool.shared
        pool.suspend()
        defer { pool.suspend() }
        pool.activate(isIncognito: isIncognito)
        try await waitUntil { pool.isPreparedWebViewReady }
        let spare = try XCTUnwrap(pool.preparedWebView)
        // Settings may change while the spare is idle; install live preferences.
        defaults.set(true, forKey: "privacy_gpc_enabled")
        // A page-world probe verifies scripts added after engine startup still
        // run before inline page code. Production selection scripts deliberately
        // use an isolated world and must not expose their globals to the page.
        spare.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.warmupDocumentStartProbe = true",
            injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
        let html = "<title>Warm page</title><p id='content'>First page</p><script>window.firstDocumentRuntime = window.warmupDocumentStartProbe === true;</script>"
        let url = try XCTUnwrap(URL(string: "data:text/html;base64," + Data(html.utf8).base64EncodedString()))
        let model = WebViewModel()
        if restoring { model.loadCachedURL(url) } else { model.loadURL(url) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            model.releaseWebViewRuntime()
            previous?.makeKeyAndVisible()
        }
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        try await waitUntil { model.webView != nil && model.pageTitle == "Warm page" && !model.isLoading }
        let web = try XCTUnwrap(model.webView)
        XCTAssertTrue(web === spare)
        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.hasInstalledWebViewScripts)
        XCTAssertTrue(model.isStreamingDownloadHandlerInstalled)
        XCTAssertFalse(web.configuration.userContentController.userScripts.isEmpty)
        let runtime = try await web.evaluateJavaScript("window.firstDocumentRuntime") as? Bool
        XCTAssertEqual(runtime, true, "Document-start runtime must precede the pending first request")
        let selectionRuntime = try await web.evaluateJavaScript("window.__souloTextSelection === true", in: nil, contentWorld: .defaultClient) as? Bool
        XCTAssertEqual(selectionRuntime, true)
        let pageHasSelectionGlobal = try await web.evaluateJavaScript("window.__souloTextSelection === true") as? Bool
        XCTAssertEqual(pageHasSelectionGlobal, false, "Keep native script globals isolated from page code")
        let gpc = try await web.evaluateJavaScript("navigator.globalPrivacyControl") as? Bool
        XCTAssertEqual(gpc, true, "Use the privacy preference at handoff, not at warmup")
        XCTAssertTrue(web.backForwardList.backList.isEmpty)
        XCTAssertFalse(model.canGoBack)
        XCTAssertNil(model.errorMessage)
        // Remounting an existing tab must preserve its JS state and instance,
        // even after the pool has replenished its spare.
        _ = try await web.evaluateJavaScript("window.retainedTabState = 42")
        window.rootViewController = nil
        try await waitUntil { pool.isPreparedWebViewReady }
        let nextSpare = try XCTUnwrap(pool.preparedWebView)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.webView === web)
        XCTAssertTrue(pool.preparedWebView === nextSpare)
        let retained = try await web.evaluateJavaScript("window.retainedTabState") as? Int
        XCTAssertEqual(retained, 42)
    }
}
