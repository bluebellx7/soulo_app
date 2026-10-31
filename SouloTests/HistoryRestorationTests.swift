import SwiftUI
import WebKit
import XCTest
@testable import Soulo

@MainActor
final class HistoryRestorationTests: XCTestCase {
    func testNativeHistoryDoesNotRewriteAnExistingEntryAfterPrivacyPreferencesChange() async throws {
        let defaults = UserDefaults.standard
        let keys = ["privacy_gpc_enabled", "privacy_gpc_header_enabled_sites", "privacy_strip_tracking_parameters", "privacy_https_upgrade_enabled", "ad_block_enabled", "soulo_privacy_disabled_hosts"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(false, forKey: "privacy_gpc_enabled")
        defaults.set(false, forKey: "privacy_strip_tracking_parameters")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set(false, forKey: "ad_block_enabled")
        defaults.set([], forKey: "soulo_privacy_disabled_hosts")
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/first": Data("<html><body><h1 id='first'>First</h1><input id='draft'><script>window.marker=42</script></body></html>".utf8),
            "/second": Data("<html><body><h1 id='second'>Second</h1></body></html>".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let model = WebViewModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime(); previous?.makeKeyAndVisible() }
        model.loadURL(URL(string: root.appendingPathComponent("first").absoluteString + "?utm_source=history")!)
        try await wait(model, "!!document.getElementById('first')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("draft.value='Unsaved draft'; location.href='/second'")
        try await wait(model, "!!document.getElementById('second')")
        defaults.set(true, forKey: "privacy_gpc_enabled")
        defaults.set(["127.0.0.1"], forKey: "privacy_gpc_header_enabled_sites")
        defaults.set(true, forKey: "privacy_strip_tracking_parameters")
        web.goBack() // Same native traversal used by WebKit's edge gesture.
        try await wait(model, "!!document.getElementById('first')")
        XCTAssertEqual(web.url?.query, "utm_source=history")
        let draft = try await web.evaluateJavaScript("draft.value") as? String
        XCTAssertEqual(draft, "Unsaved draft")
        XCTAssertTrue(web.canGoForward, "Replacing history with load() discards forward history")
        web.goForward()
        try await wait(model, "!!document.getElementById('second')")
    }
    private func wait(_ model: WebViewModel, _ script: String) async throws {
        for _ in 0..<160 {
            if (try? await model.webView?.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Page did not reach expected state: \(script)")
        throw URLError(.timedOut)
    }
}
