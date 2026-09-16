import XCTest
import WebKit
import SwiftUI
@testable import Soulo

@MainActor
final class ManualAdBlockTests: XCTestCase {
    func testPersistenceDeduplicationScopesAndRestore() throws {
        let suite = "ManualAdRules-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ManualAdBlockService(defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://news.example.com/story%20one?token=secret#private"))
        let pageRule = try XCTUnwrap(service.save(url: url, selector: "#sponsor", wholeSite: false))
        XCTAssertEqual(pageRule.path, "/story%20one")
        XCTAssertEqual(service.save(url: url, selector: "#sponsor", wholeSite: false)?.id, pageRule.id)
        XCTAssertNotNil(service.save(url: url, selector: "#sponsor", wholeSite: true))
        let restored = ManualAdBlockService(defaults: defaults)
        XCTAssertEqual(restored.rules.count, 2)
        let data = try XCTUnwrap(defaults.data(forKey: ManualAdBlockService.storageKey))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
        restored.remove(pageRule.id)
        XCTAssertEqual(ManualAdBlockService(defaults: defaults).rules.count, 1)
        XCTAssertNil(restored.save(url: url, selector: "body", wholeSite: true))
        XCTAssertNil(restored.save(url: url, selector: "#ad {color:red}", wholeSite: true))
    }

    func testUndoRestoresOriginalRuleWithoutDuplicatesOrChangingScope() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ManualAdUndo-\(UUID())"))
        let service = ManualAdBlockService(defaults: defaults)
        defer { defaults.removeObject(forKey: ManualAdBlockService.storageKey) }
        let url = try XCTUnwrap(URL(string: "https://example.com/story?private=1"))
        let rule = try XCTUnwrap(service.save(url: url, selector: "#sponsor", wholeSite: false))
        service.remove(rule.id)
        XCTAssertTrue(service.restore(rule))
        XCTAssertTrue(service.restore(rule))
        XCTAssertEqual(service.rules, [rule])
        XCTAssertEqual(ManualAdBlockService(defaults: defaults).rules, [rule])
        service.remove(rule.id)
        let replacement = try XCTUnwrap(service.save(url: url, selector: rule.selector, wholeSite: false))
        XCTAssertTrue(service.restore(rule))
        XCTAssertEqual(service.rules, [replacement])
    }

    func testProtectionPolicyAndBoundaryMatching() throws {
        func allowed(_ string: String, enabled: Bool = true, hosts: [String] = []) -> Bool {
            ManualAdBlockService.canUse(on: URL(string: string), enabled: enabled, allowlistedHosts: hosts)
        }
        XCTAssertTrue(allowed("https://example.com/story"))
        XCTAssertFalse(allowed("https://example.com/story", enabled: false))
        XCTAssertFalse(allowed("https://news.example.com/story", hosts: ["example.com"]))
        XCTAssertTrue(allowed("https://notexample.com/story", hosts: ["example.com"]))
        XCTAssertFalse(allowed("https://example.com/login"))
        XCTAssertFalse(allowed("https://weixin.qq.com/story"))
        XCTAssertFalse(allowed("file:///private/story.html"))
    }

    func testRulesHideDynamicElementsAndRestoreWithoutReloadOrStyleLoss() async throws {
        let web = try await fixture()
        try await configure(web, rules: [rule(path: "/story")])
        let hidden = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(hidden as? String, "none")
        try await js("document.querySelector('#sponsor').outerHTML = '<aside id=\"sponsor\" style=\"display:flex\">New ad</aside>'; null", web)
        let replacement = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(replacement as? String, "none")
        try await configure(web, rules: [])
        let restored = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(restored as? String, "flex")
    }

    func testRulesRespectExactHostPathAllowlistAndMasterSwitch() async throws {
        let web = try await fixture()
        for (rules, enabled, allowlist) in [
            ([rule(path: "/other")], true, [String]()),
            ([rule(host: "other.example.com")], true, []),
            ([rule()], false, []),
            ([rule()], true, ["example.com"])
        ] {
            try await configure(web, enabled: enabled, allowlist: allowlist, rules: rules)
            let value = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
            XCTAssertNotEqual(value as? String, "none")
        }
        try await configure(web, rules: [rule()])
        let value = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(value as? String, "none")
    }

    func testPickerPreviewCancelAndRangeDoNotChangeOriginalMarkup() async throws {
        let web = try await fixture()
        try await configure(web)
        let before = try await js("document.querySelector('#sponsor').outerHTML", web)
        let started = try await js("window.__souloManualAds.begin('test')", web)
        XCTAssertEqual(started as? Bool, true)
        let selected = try await pick("#label", in: web)
        XCTAssertEqual(selected["selector"] as? String, "#label")
        let enlarged = try await js("window.__souloManualAds.command('larger')", web) as? [String: Any]
        XCTAssertEqual(enlarged?["selector"] as? String, "#sponsor")
        try await js("window.__souloManualAds.command('preview')", web)
        let hidden = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(hidden as? String, "none")
        try await js("window.__souloManualAds.command('cancel')", web)
        let after = try await js("document.querySelector('#sponsor').outerHTML", web)
        XCTAssertEqual(before as? String, after as? String)
        let overlays = try await js("document.querySelectorAll('[aria-hidden=true]').length", web)
        XCTAssertEqual(overlays as? Int, 0)
    }

    func testPageCannotUseBridgeOrFakePickerTapAndProtectedContentIsRejected() async throws {
        let web = try await fixture()
        try await configure(web)
        let pageWorld = try await web.evaluateJavaScript("typeof window.__souloManualAds")
        XCTAssertEqual(pageWorld as? String, "undefined")
        try await js("window.__souloManualAds.begin('test')", web)
        let result = try await pick("#main", in: web)
        XCTAssertEqual(result["selected"] as? Bool, false)
        let form = try await pick("#password", in: web)
        XCTAssertEqual(form["selected"] as? Bool, false)
        try await js("document.querySelector('[aria-hidden=true]').dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:20,clientY:20})); null", web)
        let value = try await js("window.__souloManualAds.selection()", web)
        XCTAssertTrue(value == nil || value is NSNull)
    }

    func testCrossOriginFrameCanBeMarkedAsOneArea() async throws {
        let web = try await fixture()
        try await configure(web)
        try await js("window.__souloManualAds.begin('test')", web)
        let selected = try await pick("#frame", in: web)
        XCTAssertEqual(selected["selector"] as? String, "#frame")
        try await js("window.__souloManualAds.command('preview')", web)
        let hidden = try await js("getComputedStyle(document.querySelector('#frame')).display", web)
        XCTAssertEqual(hidden as? String, "none")
    }

    func testStrictPageStylePolicyDoesNotPreventManualHiding() async throws {
        let web = try await fixture(strictCSP: true)
        try await configure(web, rules: [rule()])
        let display = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(display as? String, "none")
    }

    func testInlineImportantAndDynamicReplacementRestoreOriginalDisplay() async throws {
        let web = try await fixture()
        try await js("document.querySelector('#sponsor').style.setProperty('display','flex','important'); null", web)
        try await configure(web, rules: [rule()])
        var display = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(display as? String, "none")
        try await js("document.querySelector('#sponsor').outerHTML = '<aside id=sponsor style=\"display:grid!important\">Replacement</aside>'; null", web)
        try await Task.sleep(for: .milliseconds(250))
        display = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(display as? String, "none")
        try await configure(web)
        display = try await js("getComputedStyle(document.querySelector('#sponsor')).display", web)
        XCTAssertEqual(display as? String, "grid")
        let priority = try await js("document.querySelector('#sponsor').style.getPropertyPriority('display')", web)
        XCTAssertEqual(priority as? String, "important")
    }

    func testProductionBridgeDeliversSelectionAndCancelsOnNavigation() async throws {
        let web = try await fixture()
        let model = WebViewModel()
        model.webView = web
        model.updateCurrentURL(web.url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        defer {
            model.cancelMarkingAdvertisement()
            window.isHidden = true
            window.rootViewController = nil
            model.releaseWebViewRuntime()
            previous?.makeKeyAndVisible()
        }
        for _ in 0..<100 {
            if (try? await js("!!window.__souloManualAds", web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        model.beginMarkingAdvertisement()
        for _ in 0..<100 {
            if !model.manualAdBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.manualAdSelection)
        _ = try await pick("#label", in: web)
        for _ in 0..<100 {
            if model.manualAdSelection?.hasSelection == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.manualAdSelection?.hasSelection, true)
        web.loadHTMLString("<p>Another page</p>", baseURL: URL(string: "https://news.example.com/next"))
        for _ in 0..<100 {
            if model.manualAdSelection == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.manualAdSelection)
    }

    private func rule(host: String = "news.example.com", path: String? = nil) -> ManualAdRule {
        ManualAdRule(host: host, path: path, selector: "#sponsor", createdAt: Date())
    }

    private func fixture(strictCSP: Bool = false) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        let ready = expectation(description: "Manual ad fixture navigation finished")
        let navigation = FixtureNavigation(ready: ready)
        web.navigationDelegate = navigation
        web.loadHTMLString("""
        <html><head>\(strictCSP ? "<meta http-equiv=\"Content-Security-Policy\" content=\"style-src 'none'\">" : "")<meta name="viewport" content="width=device-width, initial-scale=1"></head><body style="margin:0">
        <aside id="sponsor" style="height:90px;width:300px;background:#eee"><span id="label" style="display:block;width:120px;height:40px">Sponsor</span></aside>
        <main id="main" style="height:100px">Main content</main>
        <form><input id="password" type="password" style="height:40px"></form>
        <iframe id="frame" sandbox srcdoc="<p>Ad frame</p>" style="width:300px;height:80px"></iframe>
        </body></html>
        """, baseURL: URL(string: "https://news.example.com/story"))
        // Wait for this document's navigation event, rather than polling the
        // initial empty document while a WebContent process is still starting.
        await fulfillment(of: [ready], timeout: 20)
        web.navigationDelegate = nil
        if let error = navigation.error { throw error }
        guard navigation.finished else { web.stopLoading(); throw ReadingToolError.invalid }
        return web
    }

    @MainActor private final class FixtureNavigation: NSObject, WKNavigationDelegate {
        let ready: XCTestExpectation
        var finished = false
        var error: Error?
        init(ready: XCTestExpectation) { self.ready = ready }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { complete(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { complete(error) }
        private func complete(_ error: Error? = nil) {
            guard !finished else { return }
            self.error = error; finished = true; ready.fulfill()
        }
    }

    private func configure(_ web: WKWebView, enabled: Bool = true, allowlist: [String] = [], rules: [ManualAdRule] = []) async throws {
        try await js(ManualAdBlockRuntime.configuredScript(enabled: enabled, allowlistedHosts: allowlist, rules: rules) + "\nnull", web)
    }

    private func pick(_ selector: String, in web: WKWebView) async throws -> [String: Any] {
        let result = try await js("(() => { const r = document.querySelector('\(selector)').getBoundingClientRect(); return window.__souloManualAds.pickAtPoint(r.left + 10, r.top + 10); })()", web)
        return try XCTUnwrap(result as? [String: Any])
    }

    @discardableResult
    private func js(_ source: String, _ web: WKWebView) async throws -> Any? {
        try await web.evaluateJavaScript(source, in: nil, contentWorld: ManualAdBlockRuntime.world)
    }
}
