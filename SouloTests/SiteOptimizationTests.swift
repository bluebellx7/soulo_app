import Combine
import UIKit
import WebKit
import XCTest
@testable import Soulo

@MainActor
final class SiteOptimizationTests: XCTestCase {
    private func rule() throws -> SiteOptimizationRule {
        try XCTUnwrap(SiteOptimizationRules.all.first { $0.id == "baidu-search" })
    }
    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "SiteOptimizationTests." + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    private func wait(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out: " + script)
    }
    private let html = """
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <body style="background:white"><div id="results">
      <div class="c-result" id="web" tpl="www_index" data-log='{"mu":"https://example.com/first"}'>
        <h3><a id="title" href="/link?url=opaque" target="_blank">A useful result</a></h3>
        <div data-module="abstract">A readable summary</div>
        <a id="sitelink" href="https://example.org/separate">Separate subpage</a>
      </div>
      <div class="c-result" id="opaque" tpl="www_index"><h3><a href="/link?url=unknown">Unknown destination</a></h3></div>
      <div class="c-result" id="video" tpl="vid_recommend" data-log='{"mu":"https://example.com/video"}'>
        <h3>Video</h3><video controls></video><button id="play">Play</button>
      </div>
      <div class="c-result" tpl="recommend_list_san" id="related"><a class="c-invoke-class" data-rgitem-type="search" data-url="https://m.baidu.com/s?word=焗和蒸的区别" href="baiduboxapp://search"><button>焗和蒸的区别</button></a><div class="c-invoke-willshow-class">百度APP内打开</div></div>
    </div><aside id="app-promo" style="position:fixed;bottom:0;width:100%;height:52px"><span>今日金价速看</span><span ref="open">去看看</span></aside><div id="content_left"><div class="result c-container" tpl="se_com_default" mu="https://desktop.example/article"><h3><a id="desktop-title" href="/link?url=opaque">Desktop result</a></h3></div></div><input id="draft" value="kept"><script>window.identity=Math.random();</script>
    """

    func testBundledRuleHasExactSearchScopeAndIndependentResource() throws {
        let rule = try rule()
        XCTAssertTrue(rule.enabledByDefault)
        let script = rule.scriptRecord
        XCTAssertTrue(script.isBuiltIn == true)
        XCTAssertEqual(script.injectionTime, .documentStart)
        XCTAssertTrue(script.source.contains("// ==UserScript=="))
        XCTAssertTrue(script.source.contains("__souloSiteOptimization"))
        XCTAssertEqual(script.matchPatterns.count, 3)
        XCTAssertFalse(try XCTUnwrap(SiteOptimizationRules.sources[rule.resourceFile]).isEmpty)
        for url in ["https://baidu.com/s?wd=test", "https://www.baidu.com/s?wd=test",
                    "https://m.baidu.com/s?word=test", "https://m.baidu.com/from=home/s?word=test", "https://www.baidu.com/baidu?wd=test"] {
            XCTAssertTrue(rule.matches(URL(string: url)), url)
        }
        for url in ["https://baidu.com/", "https://m.baidu.com/s", "https://m.baidu.com/video?word=x",
                    "https://baidu.com.evil.test/s?wd=x", "https://evil.baidu.com/s?wd=x", "file:///s?wd=x"] {
            XCTAssertFalse(rule.matches(URL(string: url)), url)
        }
    }

    func testNativeRequestsValidateDestinationAndPreserveReferrerPrivacy() throws {
        let rule = try rule(), source = URL(string: "https://m.baidu.com/s?word=private+query")!
        let request = try XCTUnwrap(rule.navigationRequest(to: URL(string: "https://example.com/path")!, from: source))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://m.baidu.com/")
        XCTAssertNil(rule.navigationRequest(to: URL(string: "http://example.com/path")!, from: source)?.value(forHTTPHeaderField: "Referer"))
        for destination in ["javascript:alert(1)", "file:///etc/hosts", "https://user:password@example.com/", "soulo://settings"] {
            XCTAssertNil(rule.navigationRequest(to: URL(string: destination)!, from: source))
        }
        XCTAssertNil(rule.navigationRequest(to: URL(string: "https://example.com")!, from: URL(string: "https://evil.test/s?wd=x")!))
        XCTAssertNil(rule.navigationRequest(to: URL(string: "https://example.com/" + String(repeating: "a", count: 8200))!, from: source))
    }

    func testDefaultOnPreservesExplicitChoiceAndCloudBackupRoundTrip() throws {
        let rule = try rule(), (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SiteOptimizationSettings(defaults: defaults)
        XCTAssertTrue(settings.isEnabled(rule))
        XCTAssertEqual(SiteOptimizationRules.preferenceDefaults[rule.preferenceKey] as? Bool, true)
        XCTAssertTrue(CloudSyncService.syncedKeys.contains(rule.preferenceKey))
        var changes = 0
        let observer = settings.$values.dropFirst().sink { _ in changes += 1 }
        defer { observer.cancel() }
        defaults.set("unrelated", forKey: "test-other-setting"); settings.reload()
        XCTAssertEqual(changes, 0)
        settings.setEnabled(false, for: rule)
        XCTAssertFalse(SiteOptimizationSettings(defaults: defaults).isEnabled(rule), "Preserve an explicit existing opt-out")
        XCTAssertEqual(changes, 1)
        let backup = try CloudSettingsSyncEngine.propertyList(CloudSettingsSyncEngine.snapshot(defaults))
        XCTAssertEqual(try CloudSettingsSyncEngine.values(backup)[rule.preferenceKey] as? Bool, false)
        settings.setEnabled(true, for: rule)
        XCTAssertTrue(SiteOptimizationSettings(defaults: defaults).isEnabled(rule))
        defaults.set("NO", forKey: rule.preferenceKey); settings.reload()
        XCTAssertFalse(settings.isEnabled(rule))
    }

    func testRuleDoesNotInstallObserversOrStylesOnOtherWebsites() async throws {
        let rule = try rule(), web = WKWebView()
        let controller = SiteOptimizationController()
        controller.synchronize(on: web, navigationEnabled: true) { _ in XCTFail("Unexpected navigation"); return false }
        defer { controller.detach() }
        web.loadHTMLString("<p id='ready'>Other website</p>", baseURL: URL(string: "https://example.com/article"))
        try await wait(web, "!!document.getElementById('ready')")
        let installed = try await web.evaluateJavaScript("!!globalThis.__souloSiteOptimization", in: nil, contentWorld: rule.world)
        XCTAssertEqual(installed as? Bool, false)
        let styled = try await web.evaluateJavaScript("document.documentElement.hasAttribute('data-soulo-baidu-search')")
        XCTAssertEqual(styled as? Bool, false)
    }

    func testRuleStylesWithoutRewritingLinksAndCanRestoreWithoutReload() async throws {
        let rule = try rule(), (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SiteOptimizationSettings(defaults: defaults), controller = SiteOptimizationController(settings: settings)
        settings.setEnabled(true, for: rule)
        let web = WKWebView()
        controller.synchronize(on: web, navigationEnabled: true) { _ in XCTFail("Synthetic click must not navigate"); return false }
        defer { controller.detach() }
        web.loadHTMLString(html, baseURL: URL(string: "https://m.baidu.com/s?word=test"))
        try await wait(web, "!!document.getElementById('soulo-baidu-search-style')")
        let pageBackground = try await web.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String
        XCTAssertEqual(pageBackground, "rgb(255, 255, 255)")
        let hiddenPromo = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('app-promo')).display") as? String
        XCTAssertEqual(hiddenPromo, "none")
        let relatedTarget = try await web.evaluateJavaScript("document.querySelector('#related a').href") as? String
        XCTAssertTrue(relatedTarget?.hasPrefix("baiduboxapp:") == true)
        let desktopTarget = try await web.evaluateJavaScript("document.getElementById('desktop-title').href") as? String
        XCTAssertTrue(desktopTarget?.contains("/link?url=opaque") == true)
        let identity = try await web.evaluateJavaScript("identity") as? Double
        let original = try await web.evaluateJavaScript("[title.href,sitelink.href,document.querySelector('#opaque a').getAttribute('href'),video.hasAttribute('data-soulo-baidu-card')]") as? [Any]
        XCTAssertTrue((original?[0] as? String)?.contains("/link?url=opaque") == true)
        XCTAssertEqual(original?[1] as? String, "https://example.org/separate")
        XCTAssertEqual(original?[2] as? String, "/link?url=unknown")
        XCTAssertEqual(original?[3] as? Bool, false)
        _ = try await web.evaluateJavaScript("document.getElementById('web').setAttribute('data-log',JSON.stringify({mu:'https://second.example/new'}));true")
        let unchanged = try await web.evaluateJavaScript("title.getAttribute('href')") as? String
        XCTAssertEqual(unchanged, "/link?url=opaque")
        _ = try await web.evaluateJavaScript("title.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true}));true")
        settings.setEnabled(false, for: rule)
        controller.synchronize(on: web, navigationEnabled: true) { _ in false }
        try await wait(web, "!document.documentElement.hasAttribute('data-soulo-baidu-search')")
        let restored = try await web.evaluateJavaScript("[title.getAttribute('href'),title.target,document.querySelectorAll('.soulo-baidu-source').length,identity,draft.value]") as? [Any]
        XCTAssertEqual(restored?[0] as? String, "/link?url=opaque")
        XCTAssertEqual(restored?[1] as? String, "_blank")
        XCTAssertEqual(restored?[2] as? Int, 0)
        XCTAssertEqual(restored?[3] as? Double, identity)
        XCTAssertEqual(restored?[4] as? String, "kept")
    }

    func testBridgeIsIsolatedAndRejectsUnsafeDestinations() async throws {
        let rule = try rule(), web = WKWebView(), (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = SiteOptimizationSettings(defaults: defaults)
        settings.setEnabled(true, for: rule)
        let controller = SiteOptimizationController(settings: settings)
        var navigations: [URLRequest] = []
        controller.synchronize(on: web, navigationEnabled: true) { navigations.append($0); return false }
        defer { controller.detach() }
        web.loadHTMLString(html, baseURL: URL(string: "https://www.baidu.com/s?wd=test"))
        try await wait(web, "!!document.getElementById('soulo-baidu-search-style')")
        let pageAccess = try await web.evaluateJavaScript("!!globalThis.webkit?.messageHandlers?.souloSiteOptimizationNavigate")
        XCTAssertEqual(pageAccess as? Bool, false)
        _ = try await web.evaluateJavaScript("webkit.messageHandlers.souloSiteOptimizationNavigate.postMessage({url:'javascript:alert(1)'});true", in: nil, contentWorld: rule.world)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertTrue(navigations.isEmpty)
        _ = try await web.evaluateJavaScript("webkit.messageHandlers.souloSiteOptimizationNavigate.postMessage({url:'https://example.com/direct'});true", in: nil, contentWorld: rule.world)
        for _ in 0..<50 where navigations.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(navigations.first?.url?.absoluteString, "https://example.com/direct")
        let scriptCount = web.configuration.userContentController.userScripts.count
        controller.synchronize(on: web, navigationEnabled: true) { _ in false }
        XCTAssertEqual(web.configuration.userContentController.userScripts.count, scriptCount)
        let scripts = web.configuration.userContentController.userScripts.map(ObjectIdentifier.init)
        controller.detach()
        controller.synchronize(on: web, navigationEnabled: true) { _ in false }
        XCTAssertEqual(web.configuration.userContentController.userScripts.map(ObjectIdentifier.init), scripts,
                       "Remounting must reuse unchanged scripts and preserve their order")
    }

    func testCachedSearchPageReadsLatestPluginPreferenceOnBack() async throws {
        var rule = try rule(); rule.hosts = ["127.0.0.1"]
        let (defaults, name) = isolatedDefaults(); defer { defaults.removePersistentDomain(forName: name) }
        let settings = SiteOptimizationSettings(defaults: defaults, rules: [rule])
        settings.setEnabled(true, for: rule)
        let controller = SiteOptimizationController(rules: [rule], settings: settings)
        let server = try DownloadPlaybackHTTPFixture(files: ["/s":Data(html.utf8), "/article":Data("<h1 id='article'>Article</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let web = WKWebView(frame: CGRect(x: 0,y: 0,width: 390,height: 700))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let host = UIViewController(); window.rootViewController = host; window.makeKeyAndVisible(); host.view.addSubview(web)
        defer { controller.detach(); window.isHidden = true; previous?.makeKeyAndVisible() }
        controller.synchronize(on: web, navigationEnabled: true) { _ in false }
        web.load(URLRequest(url: root.appendingPathComponent("s").appending(queryItems: [URLQueryItem(name: "wd", value: "test")])))
        try await wait(web, "!!document.getElementById('soulo-baidu-search-style')")
        let identity = try await web.evaluateJavaScript("identity") as? Double
        _ = try await web.evaluateJavaScript("draft.value='kept on back';true")
        web.load(URLRequest(url: root.appendingPathComponent("article")))
        try await wait(web, "!!document.getElementById('article')")
        settings.setEnabled(false, for: rule)
        controller.synchronize(on: web, navigationEnabled: true) { _ in false }
        web.goBack()
        try await wait(web, "!!document.getElementById('draft') && !document.documentElement.hasAttribute('data-soulo-baidu-search')")
        let returnedIdentity = try await web.evaluateJavaScript("identity") as? Double
        let returnedDraft = try await web.evaluateJavaScript("draft.value") as? String
        XCTAssertEqual(returnedIdentity, identity)
        XCTAssertEqual(returnedDraft, "kept on back")
    }
}
