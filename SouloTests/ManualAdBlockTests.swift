import XCTest
import WebKit
import SwiftUI
import CoreData
@testable import Soulo

@MainActor
final class ManualAdBlockTests: XCTestCase {
    private var savedBuiltInOverrides: Data?
    private var savedBuiltInRevision: String?
    private var savedFiltering: Any?
    private var savedAllowlist: Any?
    private var savedPrivacy: Any?
    private var savedTemporaryHosts: [String] = []
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedBuiltInOverrides = defaults.data(forKey: BuiltInAdRuleStore.storageKey)
        savedBuiltInRevision = defaults.string(forKey: BuiltInAdRuleStore.versionKey)
        savedFiltering = defaults.object(forKey: "ad_block_enabled")
        savedAllowlist = defaults.object(forKey: "soulo_ad_block_allowlisted_hosts")
        savedPrivacy = defaults.object(forKey: "is_incognito")
        savedTemporaryHosts = AdBlockSettingsService.shared.temporaryAllowlistedHosts
        defaults.set(true, forKey: "ad_block_enabled")
        defaults.set([], forKey: "soulo_ad_block_allowlisted_hosts")
        // Match the nonpersistent store used by fixture(), so mounting the
        // production container does not replace it for a privacy-mode change.
        defaults.set(true, forKey: "is_incognito")
        AdBlockSettingsService.shared.clearTemporaryExceptions()
        AdBlockSettingsService.shared.reloadFromDefaults()
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
    }
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.set(savedBuiltInOverrides, forKey: BuiltInAdRuleStore.storageKey)
        defaults.set(savedBuiltInRevision, forKey: BuiltInAdRuleStore.versionKey)
        defaults.set(savedFiltering, forKey: "ad_block_enabled")
        defaults.set(savedAllowlist, forKey: "soulo_ad_block_allowlisted_hosts")
        defaults.set(savedPrivacy, forKey: "is_incognito")
        AdBlockSettingsService.shared.clearTemporaryExceptions()
        AdBlockSettingsService.shared.reloadFromDefaults()
        savedTemporaryHosts.forEach { AdBlockSettingsService.shared.temporarilyDisableFiltering(for: $0) }
        super.tearDown()
    }

    func testPBKanTiledOverlayIsScopedAndPreservesPlayerAndEpisodeLinks() async throws {
        let rule = try XCTUnwrap(AdBlockService.defaultBuiltInRules.first { $0.id == "pbkan-tiled-overlay" })
        let html = #"""
            <body><rntafp style="position:fixed;z-index:2147483646;display:block;width:40px;height:30px;
                background-position:0 20px;background-size:390px 120px"></rntafp>
            <iframe id="player" style="position:fixed;z-index:2147483646" srcdoc="<video controls></video>"></iframe>
            <ul id="play-box"><li><a href="/yun/241110-3-14.html">Episode 14</a></li></ul></body>
            """#
        for (name, allowlist, shouldHide) in [("www.pbkan.com", [String](), true), ("www.pbkan.com", ["pbkan.com"], false),
                                             ("pbkan.com.example.test", [String](), false)] {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(WKUserScript(source: AdBlockService.adHidingScript(allowlistedHosts: allowlist),
                injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
            web.loadHTMLString(html, baseURL: URL(string: "https://\(name)/yun/241110-3-14.html"))
            for _ in 0..<100 {
                if (try? await js("typeof window.__souloAdBlockRemoveAds === 'function' && !!document.querySelector('rntafp')", web)) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            let hidden = try await web.callAsyncJavaScript("""
                window.__souloAdBlockRemoveAds?.();
                return {matched:document.querySelectorAll(selector).length,
                    promo:getComputedStyle(document.querySelector('rntafp')).display === 'none',
                    player:getComputedStyle(document.getElementById('player')).display !== 'none',
                    episodes:document.querySelectorAll('#play-box a').length};
                """, arguments: ["selector": rule.pattern], in: nil, contentWorld: .page) as? [String: Any]
            XCTAssertEqual(hidden?["matched"] as? Int, 1)
            XCTAssertEqual(hidden?["promo"] as? Bool, shouldHide, name)
            XCTAssertEqual(hidden?["player"] as? Bool, true)
            XCTAssertEqual(hidden?["episodes"] as? Int, 1)
        }
    }

    func testLivePBKanHidesOverlayTilesWhilePlayerAndEpisodesStayAvailable() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_PBKAN_AD_QA"] == "1", "Opt-in live overlay inspection")
        let page = try XCTUnwrap(URL(string: "https://www.pbkan.com/yun/241110-3-14.html"))
        let rule = try XCTUnwrap(AdBlockService.defaultBuiltInRules.first { $0.id == "pbkan-tiled-overlay" })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), host = UIViewController()
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: host.view.bounds, configuration: configuration)
        web.customUserAgent = AppConstants.mobileWebViewUserAgent
        host.view.addSubview(web)
        web.load(URLRequest(url: page))
        func state() async -> [String: Int] {
            (try? await web.callAsyncJavaScript("""
                const found=[...document.querySelectorAll(selector)];
                const frame=document.querySelector('iframe[src*="/static/player/"]');
                const video=frame?.contentDocument?.querySelector('video');
                return {tiles:found.length, visible:found.filter(e=>e.getClientRects().length).length,
                    player:video ? 1 : 0, episodes:document.querySelectorAll('#play-box a').length};
                """, arguments: ["selector": rule.pattern], in: nil, contentWorld: .page)) as? [String: Int] ?? [:]
        }
        var before: [String: Int] = [:]
        for _ in 0..<100 {
            before = await state()
            if (before["visible"] ?? 0) > 0, before["player"] == 1 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        _ = try await web.evaluateJavaScript(AdBlockService.adHidingScript() + "\nnull")
        var after: [String: Int] = [:]
        for _ in 0..<30 {
            after = await state()
            if after["visible"] == 0, (after["tiles"] ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("PBKAN_AD before=\(before) after=\(after)")
        XCTAssertGreaterThan(before["visible"] ?? 0, 0)
        XCTAssertEqual(after["visible"], 0)
        XCTAssertEqual(after["player"], 1)
        XCTAssertEqual(after["episodes"], before["episodes"])
        XCTAssertGreaterThan(after["episodes"] ?? 0, 0)
    }

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

    func testRemoveDomainIncludesAllScopesAndBatchUndoPreservesOtherDomains() throws {
        let suite = "ManualAdDomain-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ManualAdBlockService(defaults: defaults)
        let url = try XCTUnwrap(URL(string: "https://example.com/story"))
        let wholeSite = try XCTUnwrap(service.save(url: url, selector: "#one", wholeSite: true))
        let page = try XCTUnwrap(service.save(url: url, selector: "#two", wholeSite: false))
        let subdomain = try XCTUnwrap(service.save(url: URL(string: "https://news.example.com/story")!, selector: "#one", wholeSite: true))
        let other = try XCTUnwrap(service.save(url: URL(string: "https://notexample.com/story")!, selector: "#one", wholeSite: true))
        let removed = service.remove(host: "EXAMPLE.COM")
        XCTAssertEqual(removed, [wholeSite, page])
        XCTAssertEqual(service.rules, [subdomain, other])
        XCTAssertEqual(ManualAdBlockService(defaults: defaults).rules, [subdomain, other])
        XCTAssertTrue(service.restore(removed))
        XCTAssertTrue(service.restore(removed))
        XCTAssertEqual(service.rules, [subdomain, other, wholeSite, page])
        XCTAssertEqual(ManualAdBlockService(defaults: defaults).rules, service.rules)
    }

    func testBatchUndoDoesNotPartiallyRestoreWhenCapacityIsExceeded() throws {
        let suite = "ManualAdBatchCapacity-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = (0..<499).map {
            ManualAdRule(host: "other.example.com", path: nil, selector: "#slot\($0)", createdAt: Date())
        }
        defaults.set(try JSONEncoder().encode(existing), forKey: ManualAdBlockService.storageKey)
        let service = ManualAdBlockService(defaults: defaults)
        let removed = [rule(path: "/one"), rule(path: "/two")]
        XCTAssertFalse(service.restore(removed))
        XCTAssertEqual(service.rules, existing)
        XCTAssertEqual(ManualAdBlockService(defaults: defaults).rules, existing)
        service.remove(existing[0].id)
        XCTAssertTrue(service.restore(removed))
        XCTAssertEqual(service.rules.count, 500)
    }

    func testProtectionPolicyAndBoundaryMatching() throws {
        func allowed(_ string: String, enabled: Bool = true, hosts: [String] = []) -> Bool {
            ManualAdBlockService.canUse(on: URL(string: string), enabled: enabled, allowlistedHosts: hosts)
        }
        XCTAssertTrue(allowed("https://example.com/story"))
        XCTAssertFalse(allowed("https://example.com/story", enabled: false))
        XCTAssertFalse(allowed("https://news.example.com/story", hosts: ["example.com"]))
        XCTAssertTrue(allowed("https://notexample.com/story", hosts: ["example.com"]))
        XCTAssertTrue(allowed("https://example.com/login"))
        XCTAssertTrue(allowed("https://www.xiaohongshu.com/explore/example"))
        XCTAssertFalse(allowed("https://example.com/mp/wappoc_appmsgcaptcha?poc_token=token"))
        XCTAssertTrue(allowed("https://weixin.qq.com/story"))
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

    func testFixedBottomAdRemainsReachableAbovePickerControls() async throws {
        // Use an unrecognized name so automatic filtering does not hide this
        // fixture before the user can manually select it.
        let page = """
        <!DOCTYPE html><meta name="viewport" content="width=device-width, initial-scale=1">
        <body><p>Fixture content</p>
        <aside id="bottom-promotion" style="position:fixed;bottom:0;left:0;width:100%;height:70px;z-index:999999;background:orange">Promotion</aside>
        </body>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data(page.utf8)])
        let url = try await server.start().appendingPathComponent("page")
        defer { server.stop() }
        let defaults = UserDefaults.standard
        let previousFiltering = defaults.object(forKey: "ad_block_enabled")
        defaults.set(true, forKey: "ad_block_enabled")
        defer { defaults.set(previousFiltering, forKey: "ad_block_enabled") }
        let model = WebViewModel()
        let container = try LibraryStore(inMemory: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            WebViewContainer(webViewModel: model, bookmarkViewModel: BookmarkViewModel(), isFullscreen: .constant(false))
                .environmentObject(SearchViewModel()).environment(\.managedObjectContext, (container).mainContext))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.cancelMarkingAdvertisement()
            window.isHidden = true; window.rootViewController = nil
            model.releaseWebViewRuntime(); previous?.makeKeyAndVisible()
        }
        model.loadURL(url)
        for _ in 0..<300 {
            if model.hasVisibleContent, model.webView?.window === window { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let web = try XCTUnwrap(model.webView)
        XCTAssertTrue(web.window === window, "The picker must target the displayed browser")
        XCTAssertTrue(model.canMarkAdvertisement, "Picking is disabled for \(String(describing: web.url))")
        let ready = try await js("Boolean(window.__souloManualAds && document.querySelector('#bottom-promotion'))", web) as? Bool
        XCTAssertEqual(ready, true)
        let heightBeforePicker = web.bounds.height
        model.beginMarkingAdvertisement()
        for _ in 0..<100 {
            if !model.manualAdBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try XCTUnwrap(model.manualAdSelection, "The live document must enter picking mode")
        var initialHeight: Double?
        for _ in 0..<500 {
            host.view.layoutIfNeeded()
            if let height = try await js("innerHeight", web) as? Double,
               height < heightBeforePicker - 100, abs(height - web.bounds.height) < 2 {
                initialHeight = height
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let reservedHeight = try XCTUnwrap(initialHeight, "WebKit must acknowledge the space reserved for picker controls")
        func adCenter() async throws -> CGPoint {
            let result = try await js("(() => { const r = document.querySelector('#bottom-promotion').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()", web)
            let coordinates = try XCTUnwrap(result as? [Double])
            return CGPoint(x: coordinates[0], y: coordinates[1])
        }
        for selected in [false, true] {
            if selected { await model.pickAdvertisement(at: try await adCenter()) }
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let currentHeight = try await js("innerHeight", web) as? Double
            XCTAssertEqual(currentHeight, reservedHeight, "Selecting must not resize the reserved web viewport")
            let point = web.convert(try await adCenter(), to: window)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
                "Picker hit: \(String(describing: hit)); point=\(point), webFrame=\(web.frame), webBounds=\(web.bounds), attached=\(web.window === window), selection=\(selected)")
            if hit !== web && hit?.isDescendant(of: web) != true {
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "manual-ad-hit-layout"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
        XCTAssertTrue(model.manualAdSelection?.hasSelection == true)
    }

    func testTextUpdatesAvoidAdRescansButInsertedAdsAreStillHidden() async throws {
        let web = try await fixture()
        try await js("document.body.insertAdjacentHTML('beforeend','<p id=ticker>0</p>');null", web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        try await Task.sleep(for: .milliseconds(300))
        try await js("window.scanCount=0;const original=window.__souloAdBlockRemoveAds;window.__souloAdBlockRemoveAds=()=>{window.scanCount++;return original()};null", web)
        for i in 0..<5 {
            try await js("document.getElementById('ticker').textContent='\(i)';null", web)
            try await Task.sleep(for: .milliseconds(130))
        }
        let count = try await js("window.scanCount", web)
        XCTAssertEqual(count as? Int, 0, "Video clocks must not trigger repeated whole-page advertisement scans")
        try await js("document.body.insertAdjacentHTML('beforeend','<aside id=float-bottom-ad style=\"display:block!important\">Ad</aside>');null", web)
        try await Task.sleep(for: .milliseconds(300))
        let hidden = try await js("getComputedStyle(document.getElementById('float-bottom-ad')).display==='none'", web)
        XCTAssertEqual(hidden as? Bool, true)
    }

    func testCosmeticPayloadPreservesQuotedSelectorsDomainScopesAndExceptions() async throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        let rules = ParsedAdBlockRules(cosmeticRules: [
            AdBlockCosmeticRule(selector: #".qa-quoted[data-note="推广/\"报价\""]"#, ifDomains: ["example.com"]),
            AdBlockCosmeticRule(selector: ".qa-other", ifDomains: ["other.example.com"]),
            AdBlockCosmeticRule(selector: ".qa-excluded", unlessDomains: ["news.example.com"]),
            AdBlockCosmeticRule(selector: ".qa-excepted")
        ], cosmeticExceptions: [AdBlockCosmeticRule(selector: ".qa-excepted", ifDomains: ["news.example.com"])])
        defaults.set(try JSONEncoder().encode(rules), forKey: key)
        let web = try await fixture()
        try await js("""
        document.body.insertAdjacentHTML('beforeend', `<aside class='qa-quoted' data-note='推广/"报价"'>Advertisement</aside><aside class='qa-other'>Other site</aside><aside class='qa-excluded'>Excluded site</aside><aside class='qa-excepted'>Exception</aside>`); null
        """, web)
        try await js(AdBlockService.adHidingScript() + "\nnull", web)
        let displays = try await js("['qa-quoted','qa-other','qa-excluded','qa-excepted'].map(c=>getComputedStyle(document.querySelector('.'+c)).display)", web) as? [String]
        XCTAssertEqual(displays?.first, "none")
        XCTAssertEqual(displays?.dropFirst().contains("none"), false,
            "Other-domain rules, excluded hosts and cosmetic exceptions must preserve content")
    }

    func testAllowlistedPageSkipsCosmeticPayloadAndCanEnableFilteringLater() async throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules(cosmeticSelectors: [".qa-lazy-ad"])), forKey: key)
        let web = try await fixture()
        try await js("document.body.insertAdjacentHTML('beforeend', '<aside class=qa-lazy-ad>Advertisement</aside>'); null", web)
        try await js(AdBlockService.adHidingScript(allowlistedHosts: ["example.com"]) + "\nnull", web)
        let skipped = try await js("window.__souloAdBlockConfig.subscriptionCosmeticRules.length === 0 && !window.__souloAdBlockInstalled && getComputedStyle(document.querySelector('.qa-lazy-ad')).display !== 'none'", web)
        XCTAssertEqual(skipped as? Bool, true)
        try await js(AdBlockService.adHidingScript() + "\nnull", web)
        let enabled = try await js("getComputedStyle(document.querySelector('.qa-lazy-ad')).display === 'none'", web)
        XCTAssertEqual(enabled as? Bool, true)
    }

    func testLateVerificationControlsRestoreTheirPreviouslyFilteredContainer() async throws {
        let defaults=UserDefaults.standard,key="soulo_ad_block_subscription_rules",saved=defaults.object(forKey:"soulo_ad_block_subscription_rules")
        defer { defaults.set(saved,forKey:key) }
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules(cosmeticSelectors:[".qa-dynamic-widget"])),forKey:key)
        let web=try await fixture()
        try await js("document.body.insertAdjacentHTML('beforeend', '<div id=widget class=qa-dynamic-widget style=\"height:40px\">Widget</div><aside id=other-ad class=qa-dynamic-widget>Advertisement</aside>');null",web)
        try await js(AdBlockService.adHidingScript()+"\nnull",web)
        let hidden=try await js("getComputedStyle(document.getElementById('widget')).display",web)
        XCTAssertEqual(hidden as? String,"none")
        try await js("document.getElementById('widget').insertAdjacentHTML('beforeend','<input type=hidden name=cf-turnstile-response>');null",web)
        for _ in 0..<100 {
            if (try await js("getComputedStyle(document.getElementById('widget')).display!=='none'",web)) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let result=try await js("getComputedStyle(document.getElementById('widget')).display!=='none' && getComputedStyle(document.getElementById('other-ad')).display==='none'",web)
        XCTAssertEqual(result as? Bool,true)
    }

    func testBottomAdFilteringHandlesLateInsertionWithoutHidingFooter() async throws {
        let web = try await fixture()
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        try await js("""
        document.body.insertAdjacentHTML('beforeend', '<footer id="site-footer">Copyright and navigation</footer><div id="float-bottom-ad" style="position:fixed;bottom:0;width:100%;height:70px;display:block!important">Advertisement</div>'); null
        """, web)
        for _ in 0..<100 {
            if try await js("getComputedStyle(document.querySelector('#float-bottom-ad')).display", web) as? String == "none" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let hidden = try await js("getComputedStyle(document.querySelector('#float-bottom-ad')).display", web)
        XCTAssertEqual(hidden as? String, "none")
        let footer = try await js("getComputedStyle(document.querySelector('#site-footer')).display", web)
        XCTAssertNotEqual(footer as? String, "none")
        let content = try await js("getComputedStyle(document.querySelector('#main')).display", web)
        XCTAssertNotEqual(content as? String, "none")
    }

    func testStartingPickerNeverRevealsAutomaticallyHiddenMosaics() async throws {
        let web = try await fixture()
        try await configure(web)
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        for _ in 0..<2 {
            try await js("window.__souloManualAds.begin('still-hidden')", web)
            let hidden = try await js("[...document.querySelectorAll('randomtile')].every(e=>getComputedStyle(e).clipPath!=='none'&&getComputedStyle(e).pointerEvents==='none')", web)
            XCTAssertEqual(hidden as? Bool, true)
            try await js("window.__souloManualAds.command('cancel')", web)
        }
    }

    func testFullScreenClickCatcherDoesNotPreventPickingUnderlyingMosaic() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await js("""
        document.body.insertAdjacentHTML('beforeend','<div id="click-catcher" style="position:fixed;inset:0;z-index:2147483647;background:transparent"></div>'); null
        """, web)
        try await configure(web)
        try await js("window.__souloManualAds.begin('covered')", web)
        let result = try await js("window.__souloManualAds.pickAtPoint(innerWidth/2,innerHeight-20)", web) as? [String: Any]
        XCTAssertEqual(result?["selector"] as? String, "[data-soulo-tiled-banner=\"bottom\"]")
        XCTAssertEqual(result?["selected"] as? Bool, true)
        try await js("window.__souloManualAds.command('preview')", web)
        let hidden = try await js("[...document.querySelectorAll('randomtile')].every(e=>getComputedStyle(e).display==='none')", web)
        XCTAssertEqual(hidden as? Bool, true)
        let content = try await js("getComputedStyle(document.querySelector('#main')).display", web)
        XCTAssertNotEqual(content as? String, "none")
    }

    func testTransparentHitLayerAndImageTilesAreMarkedTogether() async throws {
        let web = try await fixture()
        try await js("""
        for (let i = 0; i < 4; i++) {
          const tile = document.createElement('ad-piece');
          tile.style.cssText = 'position:fixed;bottom:0;height:80px;width:25%;z-index:100;background-image:linear-gradient(red,red);background-position:0 0;left:' + (i * 25) + '%';
          document.body.append(tile);
        }
        document.body.insertAdjacentHTML('beforeend', '<div id="tap-layer" style="position:fixed;bottom:0;left:0;width:100%;height:80px;z-index:101;background:transparent"></div>'); null
        """, web)
        try await configure(web)
        try await js("window.__souloManualAds.begin('tiles')", web)
        let selection = try await pick("#tap-layer", in: web)
        let selector = try XCTUnwrap(selection["selector"] as? String)
        XCTAssertTrue(ManualAdBlockService.validSelector(selector))
        XCTAssertEqual(selector, "[data-soulo-tiled-banner=\"bottom\"]")
        try await js("window.__souloManualAds.command('preview')", web)
        let preview = try await js("[...document.querySelectorAll('ad-piece,#tap-layer')].every(e => getComputedStyle(e).display === 'none')", web)
        XCTAssertEqual(preview as? Bool, true)
        try await js("window.__souloManualAds.command('cancel')", web)
        let restored = try await js("[...document.querySelectorAll('ad-piece,#tap-layer')].every(e => getComputedStyle(e).display !== 'none')", web)
        XCTAssertEqual(restored as? Bool, true)
        let rule = ManualAdRule(host: "news.example.com", path: nil, selector: selector, createdAt: Date())
        try await configure(web, rules: [rule])
        let hidden = try await js("[...document.querySelectorAll('ad-piece,#tap-layer')].every(e => getComputedStyle(e).display === 'none')", web)
        XCTAssertEqual(hidden as? Bool, true)
        let body = try await js("getComputedStyle(document.body).display", web)
        XCTAssertNotEqual(body as? String, "none")
    }

    private func addPairedImageBanner(_ web: WKWebView, runtime: String = "rt_123_456", valid: Bool = true, inline: Bool = false) async throws {
        try await js("""
        (() => {
          const runtime='\(runtime)', id='_s_sabc123_'+runtime;
          const root=document.createElement('div');root.id=id;
          root.style.cssText='\(inline ? "position:relative;margin:10px 0;width:100%;height:120px;z-index:99999998" : "position:fixed;bottom:0;left:0;width:100%;height:120px;z-index:99999998")';
          const close=document.createElement('div');close.setAttribute('onclick',`event.stopPropagation();window['_x_${runtime}']('${id}')`);
          const link=document.createElement('div');link.setAttribute('onclick',`window['_j_${runtime}']()`);
          const img=document.createElement('img');img.src='https://images.example.test/\(valid ? "navImgs/files/ad.gif" : "products/product.gif")';img.style.cssText='width:100%;height:120px';
          link.append(img);root.append(close,link);const wrapper=document.createElement('div');wrapper.append(root);document.body.append(wrapper);
          if (!\(inline ? "true" : "false")) { const mask=document.createElement('div');mask.id='mask_'+id;mask.style.cssText='position:fixed;bottom:0;left:0;width:100%;height:25vh;z-index:99999997';document.body.append(mask); }
        })()
        """, web)
    }

    func testInlinePairedImageBannerHidesWholeClickTarget() async throws {
        let web = try await fixture()
        try await configure(web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        try await addPairedImageBanner(web, inline: true)
        try await Task.sleep(for: .milliseconds(200))
        let hidden = try await js("""
          (() => { const root=document.querySelector('[id^="_s_"]');
            return root.hasAttribute('data-soulo-image-banner')
              && getComputedStyle(root).display === 'none'
              && !root.contains(document.elementFromPoint(150, 50)); })()
        """, web)
        XCTAssertEqual(hidden as? Bool, true)
    }

    func testPairedImageBannerAutoFilteringAndPickerCancel() async throws {
        let web = try await fixture()
        try await configure(web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        try await addPairedImageBanner(web)
        try await Task.sleep(for: .milliseconds(200))
        let hidden = try await js("[...document.querySelectorAll('[data-soulo-image-banner]')].filter(e=>getComputedStyle(e).display==='none').length", web)
        XCTAssertEqual(hidden as? Int, 2, "Both the image and transparent click layer must be hidden")
        try await js("window.__souloManualAds.begin('image')", web)
        let stillHidden = try await js("[...document.querySelectorAll('[data-soulo-image-banner]')].every(e=>getComputedStyle(e).display==='none')", web)
        XCTAssertEqual(stillHidden as? Bool, true)
        try await js("window.__souloManualAds.command('cancel')", web)
        let resumed = try await js("[...document.querySelectorAll('[data-soulo-image-banner]')].every(e=>getComputedStyle(e).display==='none')", web)
        XCTAssertEqual(resumed as? Bool, true)
    }

    func testPairedImageBannerMarkSurvivesRuntimeIDChangesAndRestoresBothLayers() async throws {
        let web = try await fixture()
        try await configure(web)
        try await addPairedImageBanner(web)
        try await js("window.__souloManualAds.begin('image')", web)
        let picked = try await pick("[id^=_s_]", in: web)
        let selector = try XCTUnwrap(picked["selector"] as? String)
        XCTAssertEqual(selector, "[data-soulo-image-banner=\"sabc123\"]")
        try await js("window.__souloManualAds.command('cancel')", web)
        try await configure(web, rules: [ManualAdRule(host: "news.example.com", path: nil, selector: selector, createdAt: Date())])
        try await js("document.querySelectorAll('[data-soulo-image-banner]').forEach(e=>e.remove())", web)
        try await addPairedImageBanner(web, runtime: "rt_987_654")
        try await Task.sleep(for: .milliseconds(200))
        let hidden = try await js("[...document.querySelectorAll('[data-soulo-image-banner]')].filter(e=>getComputedStyle(e).display==='none').length", web)
        XCTAssertEqual(hidden as? Int, 2)
        try await configure(web)
        let restored = try await js("[...document.querySelectorAll('[data-soulo-image-banner]')].every(e=>getComputedStyle(e).display!=='none')", web)
        XCTAssertEqual(restored as? Bool, true)
    }

    func testPairedImageBannerDetectionKeepsOrdinaryFixedImages() async throws {
        let web = try await fixture()
        try await configure(web)
        try await addPairedImageBanner(web, valid: false)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        let count = try await js("document.querySelectorAll('[data-soulo-image-banner]').length", web)
        XCTAssertEqual(count as? Int, 0)
        let visible = try await js("getComputedStyle(document.querySelector('[id^=_s_]')).display !== 'none'", web)
        XCTAssertEqual(visible as? Bool, true)
    }

    private func addDecodedRendererFixture(_ web: WKWebView) async throws {
        // React's host/component links are the regression fixture. Rendering
        // callbacks must never execute: some include navigation or telemetry.
        try await web.evaluateJavaScript(#"""
        (() => {
          window.rendererInvocations = 0;
          function promotion() { window.rendererInvocations++; request('index/countads', {category:'ads_index'}); }
          function carousel() { window.rendererInvocations++; request('index/countbanner', {category:'banner'}); }
          function gallery() { request('index/countbanner', {category:'gallery'}); }
          window.replaceRenderer = (root, render) => {
            const component = {type:render, child:{stateNode:root}}, host = {stateNode:root, return:component};
            root.querySelectorAll('img').forEach(image => {
              image.__reactFiber$fixture = {stateNode:image, return:host};
            });
          };
          const make = (id, tag, count, render, extra='') => {
            const root = document.createElement(tag); root.id=id;
            root.style.cssText='width:100%;min-height:60px';
            root.innerHTML = '<img style="width:100%;height:60px" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">'.repeat(count)+extra;
            document.body.append(root); window.replaceRenderer(root,render); return root;
          };
          make('decoded-carousel','div',4,carousel);
          make('decoded-inline','div',30,promotion);
          make('ordinary-gallery','div',4,gallery);
          make('ordinary-navigation','nav',6,promotion);
          make('ordinary-player','div',1,promotion,'<video controls></video>');
          make('ordinary-login','div',1,promotion,'<form><input type="password"></form>');
          const control=document.createElement('div');control.id='custom-control';control.style.cssText='cursor:pointer;height:44px';
          control.textContent='Open content';control.onclick=()=>window.controlClicked=true;document.body.append(control);
          window.controlClicked=false;
        })(); null
        """#)
    }

    func testDecodedPromotionsHideWithoutRemovingNavigationFormsOrVideo() async throws {
        let web = try await fixture()
        try await addDecodedRendererFixture(web)
        try await web.evaluateJavaScript(AdBlockService.adHidingScript(cosmetic: true) + "\nnull")
        let state = try await web.evaluateJavaScript("""
        (() => {
          const hidden=id=>getComputedStyle(document.getElementById(id)).display==='none';
          document.getElementById('custom-control').click();
          return {promotions:['decoded-carousel','decoded-inline'].every(hidden),
            content:['ordinary-gallery','ordinary-navigation','ordinary-player','ordinary-login','custom-control'].every(id=>!hidden(id)),
            invoked:window.rendererInvocations, control:window.controlClicked};
        })()
        """) as? [String:Any]
        XCTAssertEqual(state?["promotions"] as? Bool, true)
        XCTAssertEqual(state?["content"] as? Bool, true)
        XCTAssertEqual(state?["invoked"] as? Int, 0)
        XCTAssertEqual(state?["control"] as? Bool, true)
        // Reusing a previously promotional DOM node for ordinary content must
        // remove the marker rather than permanently hiding that component.
        try await web.evaluateJavaScript("window.replaceRenderer(document.getElementById('decoded-carousel'), function gallery(){return 'photos'}); window.__souloAdBlockRemoveAds(); null")
        let restored = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('decoded-carousel')).display!=='none'")
        XCTAssertEqual(restored as? Bool, true)
    }

    func testDecodedPromotionsRespectFilteringOffAndSiteExceptions() async throws {
        for (cosmetic, allowlist) in [(false,[String]()), (true,["example.com"])] {
            let web = try await fixture()
            try await addDecodedRendererFixture(web)
            try await web.evaluateJavaScript(AdBlockService.adHidingScript(cosmetic: cosmetic, allowlistedHosts: allowlist) + "\nnull")
            let visible = try await web.evaluateJavaScript("['decoded-carousel','decoded-inline'].every(id=>getComputedStyle(document.getElementById(id)).display!=='none')")
            XCTAssertEqual(visible as? Bool, true)
        }
    }

    func testDecodedPromotionsRespectDisabledBuiltInImageRule() async throws {
        var rule = try XCTUnwrap(BuiltInAdRuleStore.effectiveRules().first { $0.id == "paired-image-banner" })
        rule.isEnabled = false
        UserDefaults.standard.set(try JSONEncoder().encode([rule.id:rule]), forKey: BuiltInAdRuleStore.storageKey)
        let web = try await fixture()
        try await addDecodedRendererFixture(web)
        try await web.evaluateJavaScript(AdBlockService.adHidingScript(cosmetic: true) + "\nnull")
        let visible = try await web.evaluateJavaScript("['decoded-carousel','decoded-inline'].every(id=>getComputedStyle(document.getElementById(id)).display!=='none')")
        XCTAssertEqual(visible as? Bool, true)
    }

    @MainActor private final class LiveImageNavigation: NSObject, WKNavigationDelegate {
        var committed = false
        var error: NSError?
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.error = error as NSError
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.error = error as NSError
        }
    }

    func testLiveDecodedImagePromotions() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_IMAGE_AD_QA"] == "1" else {
            throw XCTSkip("Opt-in external-site image-ad verification")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let filtering = ProcessInfo.processInfo.environment["SOULO_LIVE_IMAGE_AD_FILTERING"] != "0"
        if filtering {
            configuration.userContentController.addUserScript(WKUserScript(
                source: AdBlockService.adHidingScript(cosmetic: true), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: CGRect(x:0,y:0,width:402,height:874), configuration:configuration)
        let navigation = LiveImageNavigation()
        web.navigationDelegate = navigation
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
        web.load(URLRequest(url: try XCTUnwrap(URL(string:"https://ggbgb.na42u.cc/home"))))
        defer { web.stopLoading() }
        for _ in 0..<150 {
            if navigation.error != nil { break }
            if (try? await web.evaluateJavaScript("document.images.length>100 && (\(filtering ? "false" : "true") || document.querySelectorAll('[data-soulo-image-banner=renderer]').length>=2)")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(300))
        }
        let result = try await web.evaluateJavaScript(#"""
        (() => {
          const visible=el=>{for(let n=el;n;n=n.parentElement){if(getComputedStyle(n).display==='none'||getComputedStyle(n).visibility==='hidden')return false;}return true;};
          const promotions=[...document.querySelectorAll('[data-soulo-image-banner]')];
          const menus=[...document.images].filter(image=>{
            const key=Object.getOwnPropertyNames(image).find(k=>k.startsWith('__reactFiber$'));let f=key&&image[key];
            for(let i=0;f&&i<4;i++,f=f.return)if(String(f.memoizedProps?.src||'').includes('/images/menu/menu-'))return true;
            return false;
          });
          return {images:document.images.length,renderers:promotions.filter(el=>el.dataset.souloImageBanner==='renderer').length,
            dismissible:promotions.filter(el=>el.dataset.souloImageBanner==='dismissible').length,
            hidden:promotions.every(el=>!visible(el)),menus:menus.length,visibleMenus:menus.filter(visible).length,
            bodyVisible:visible(document.body),readyState:document.readyState,htmlLength:document.documentElement.outerHTML.length,
            scriptInstalled:typeof window.__souloAdBlockRemoveAds==='function'};
        })()
        """#) as? [String:Any]
        print("LIVE_IMAGE_AD_QA filtering=\(filtering) committed=\(navigation.committed) url=\(web.url?.absoluteString ?? "nil") error=\(navigation.error?.domain ?? "none"):\(navigation.error?.code ?? 0) state=\(result ?? [:])")
        XCTAssertNil(navigation.error)
        XCTAssertGreaterThan(result?["images"] as? Int ?? 0, 100, "The page must load before the filtering result is evaluated")
        if filtering {
            XCTAssertGreaterThanOrEqual(result?["renderers"] as? Int ?? 0, 2)
            XCTAssertGreaterThanOrEqual(result?["dismissible"] as? Int ?? 0, 1)
        } else {
            XCTAssertEqual(result?["renderers"] as? Int, 0)
            XCTAssertEqual(result?["dismissible"] as? Int, 0)
        }
        XCTAssertEqual(result?["scriptInstalled"] as? Bool, filtering)
        XCTAssertEqual(result?["hidden"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(result?["visibleMenus"] as? Int ?? 0, 6)
        XCTAssertEqual(result?["bodyVisible"] as? Bool, true)
    }

    func testDismissibleImagePromotionKeepsOrdinaryFixedImagesAndDialogs() async throws {
        let web = try await fixture()
        try await web.evaluateJavaScript(#"""
        (() => {
          const image='data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
          for (const [id, close, dialog] of [['image-promotion',true,false],['ordinary-fixed',false,false],['domain-notice',true,true]]) {
            const root=document.createElement('div');root.id=id;
            root.style.cssText='position:fixed;bottom:0;left:0;width:100%;height:60px';
            if(dialog)root.setAttribute('role','dialog');
            root.innerHTML='<img src="'+image+'" style="width:calc(100% - 25px);height:60px"><img src="'+image+'" style="position:absolute;right:0;top:0;width:20px;height:20px">';
            const icon=root.lastElementChild;
            const props={src:close?'/assets/icons/close.png':'/assets/icons/next.png'};
            icon.__reactFiber$fixture={return:{memoizedProps:props}};
            document.body.append(root);
          }
        })();null
        """#)
        try await web.evaluateJavaScript(AdBlockService.adHidingScript(cosmetic: true) + "\nnull")
        let state = try await web.evaluateJavaScript("""
        ({promotion:getComputedStyle(document.getElementById('image-promotion')).display==='none',
          preserved:['ordinary-fixed','domain-notice'].every(id=>getComputedStyle(document.getElementById(id)).display!=='none')})
        """) as? [String:Any]
        XCTAssertEqual(state?["promotion"] as? Bool, true)
        XCTAssertEqual(state?["preserved"] as? Bool, true)
        try await web.evaluateJavaScript("document.getElementById('image-promotion').innerHTML='<video controls></video>'; window.__souloAdBlockRemoveAds(); null")
        let reused = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('image-promotion')).display!=='none'")
        XCTAssertEqual(reused as? Bool, true, "A reused promotion container must not hide a normal player")
    }

    private func addRandomBottomMosaic(_ web: WKWebView, tag: String) async throws {
        try await js("""
        for (let row = 0; row < 4; row++) for (let col = 0; col < 10; col++) {
          const tile = document.createElement('\(tag)');
          tile.style.cssText = 'position:fixed;height:31px;width:10%;z-index:2147483646;background-image:linear-gradient(red,red);background-position:' + (-col*39) + 'px ' + (-row*31) + 'px;left:' + col*10 + '%;bottom:' + row*31 + 'px';
          document.body.append(tile);
        }
        for (let col = 0; col < 10; col++) {
          const cover = document.createElement('div'); cover.className = 'qa-cover';
          cover.style.cssText = 'position:fixed;bottom:124px;height:60px;width:10%;z-index:2147483646;left:' + col*10 + '%';
          document.body.append(cover);
        }
        null
        """, web)
    }

    func testRandomTagMosaicAutoFiltersAndKeepsOrdinaryContent() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        for _ in 0..<100 {
            if try await js("getComputedStyle(document.querySelector('randomtile')).clipPath", web) as? String != "none" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let allHidden = try await js("[...document.querySelectorAll('randomtile,.qa-cover')].every(e => getComputedStyle(e).clipPath !== 'none')", web)
        XCTAssertEqual(allHidden as? Bool, true)
        let main = try await js("getComputedStyle(document.querySelector('#main')).display", web)
        XCTAssertNotEqual(main as? String, "none")
    }

    func testMosaicAlsoDisablesTransparentClickCover() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await js("""
          const sheet=document.createElement('style');sheet.textContent='.random-click-cover{position:fixed;bottom:0;left:0;width:100%;height:124px;z-index:2147483647;background:transparent}';document.head.append(sheet);
          const cover=document.createElement('div');cover.className='random-click-cover';document.body.append(cover);null
        """, web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        for _ in 0..<100 {
            if try await js("getComputedStyle(document.querySelector('.random-click-cover')).pointerEvents", web) as? String == "none" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let disabled = try await js("getComputedStyle(document.querySelector('.random-click-cover')).pointerEvents === 'none'", web)
        XCTAssertEqual(disabled as? Bool, true)
    }

    func testImageTilesUseSameMosaicDetection() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "img")
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        for _ in 0..<100 {
            if try await js("getComputedStyle(document.querySelector('img')).pointerEvents", web) as? String == "none" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let hidden = try await js("[...document.querySelectorAll('img')].every(e => getComputedStyle(e).pointerEvents === 'none')", web)
        XCTAssertEqual(hidden as? Bool, true)
    }

    func testMosaicDisablesCoverWithDefaultBodyOffset() async throws {
        let web = try await fixture()
        try await js("document.body.style.margin='8px'; null", web)
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await js("""
          const cover=document.createElement('div');cover.id='offset-cover';
          cover.style.cssText='position:fixed;bottom:0;width:'+innerWidth+'px;height:124px;z-index:2147483647;background:transparent';
          cover.addEventListener('touchstart',()=>{window.adJumped=true});document.body.append(cover);null
        """, web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        let disabled = try await js("getComputedStyle(document.querySelector('#offset-cover')).pointerEvents", web)
        let hidden = try await js("getComputedStyle(document.querySelector('#offset-cover')).clipPath !== 'none'", web)
        XCTAssertEqual(disabled as? String, "none")
        XCTAssertEqual(hidden as? Bool, true)
    }

    func testInlineImageBannerAlsoHidesItsSeparateFixedMask() async throws {
        let web = try await fixture()
        try await addPairedImageBanner(web, inline: true)
        try await js("""
          const root=document.querySelector('[id^="_s_"]'),mask=document.createElement('div');
          mask.id='mask_'+root.id;
          mask.style.cssText='position:fixed;top:50vh;left:0;width:100%;height:50vh;z-index:99999997;background:transparent';
          document.body.append(mask);null
        """, web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        let hidden = try await js("getComputedStyle(document.querySelector('[id^=mask_]')).display", web)
        XCTAssertEqual(hidden as? String, "none")
    }

    func testAutomaticMosaicDetectionKeepsAccessibleToolbar() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "toolbar-icon")
        try await js("document.querySelectorAll('toolbar-icon').forEach(e=>{e.setAttribute('role','button');e.setAttribute('aria-label','Player action')}); null", web)
        try await js(AdBlockService.adHidingScript(cosmetic: true) + "\nnull", web)
        try await Task.sleep(for: .milliseconds(200))
        let visible = try await js("[...document.querySelectorAll('toolbar-icon')].every(e=>getComputedStyle(e).display !== 'none')", web)
        XCTAssertEqual(visible as? Bool, true)
    }

    func testPickingOneRandomTilePersistsAcrossReplacementWithNewTag() async throws {
        let web = try await fixture()
        try await addRandomBottomMosaic(web, tag: "randomtile")
        try await configure(web)
        try await js("window.__souloManualAds.begin('random')", web)
        let selection = try await pick("randomtile", in: web)
        let selector = try XCTUnwrap(selection["selector"] as? String)
        XCTAssertEqual(selector, "[data-soulo-tiled-banner=\"bottom\"]")
        try await js("window.__souloManualAds.command('cancel')", web)
        let saved = ManualAdRule(host: "news.example.com", path: nil, selector: selector, createdAt: Date())
        try await configure(web, rules: [saved])
        try await js("document.querySelectorAll('randomtile,.qa-cover').forEach(e => e.remove()); null", web)
        try await addRandomBottomMosaic(web, tag: "newrandomname")
        for _ in 0..<100 {
            if try await js("getComputedStyle(document.querySelector('newrandomname')).display", web) as? String == "none" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let allHidden = try await js("[...document.querySelectorAll('newrandomname,.qa-cover')].every(e => getComputedStyle(e).display === 'none')", web)
        XCTAssertEqual(allHidden as? Bool, true)
    }

    func testMosaicSelectionSurvivesAuxiliaryRemovalAndTileReplacement() async throws {
        let web = try await fixture()
        // A visible view is required for WebKit to update fixed-position layout
        // together with innerHeight when the native frame changes.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.addSubview(web)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await addRandomBottomMosaic(web, tag: "oldrandomtile")
        try await configure(web)
        try await js("window.__souloManualAds.begin('moving')", web)
        // Mounting the previously offscreen WebView updates its viewport
        // asynchronously. Wait for matching hit-test geometry before selection.
        var mountedLayoutReady = false
        for _ in 0..<100 {
            mountedLayoutReady = try await js("(() => { const e=document.querySelector('oldrandomtile'), r=e.getBoundingClientRect(); return Math.abs(r.bottom-innerHeight)<1 && r.top >= 0; })()", web) as? Bool == true
            if mountedLayoutReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(mountedLayoutReady)
        let initial = try await pick("oldrandomtile", in: web)
        XCTAssertEqual(initial["selected"] as? Bool, true)
        // Rotation or responsive site scripts may rebuild the selected advertisement.
        let heightValue = try await js("innerHeight", web)
        let originalHeight = try XCTUnwrap(heightValue as? Double)
        web.frame.size.height = 540
        web.setNeedsLayout(); web.layoutIfNeeded()
        // WKWebView forwards viewport changes to its content process asynchronously.
        // Rebuild the responsive advertisement only after that viewport is current.
        var layoutReady = false
        for _ in 0..<100 {
            layoutReady = try await js("innerHeight < \(originalHeight) && Math.abs(document.querySelector('oldrandomtile').getBoundingClientRect().bottom - innerHeight) < 1", web) as? Bool == true
            if layoutReady { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(layoutReady)
        try await js("document.querySelectorAll('oldrandomtile,.qa-cover').forEach(e=>e.remove()); null", web)
        let duringReplacement = try await js("window.__souloManualAds.selection()", web)
        XCTAssertTrue(duringReplacement == nil || duringReplacement is NSNull,
            "A temporary gap in a responsive ad must not validate stale tiles")
        try await addRandomBottomMosaic(web, tag: "replacementtile")
        var selection: [String: Any]?
        for _ in 0..<100 {
            selection = try await js("window.__souloManualAds.selection()", web) as? [String: Any]
            if selection?["selector"] as? String == "[data-soulo-tiled-banner=\"bottom\"]" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(selection?["selector"] as? String, "[data-soulo-tiled-banner=\"bottom\"]")
        XCTAssertEqual(selection?["selected"] as? Bool, true)
        try await js("window.__souloManualAds.command('preview')", web)
        let hidden = try await js("[...document.querySelectorAll('replacementtile,.qa-cover')].every(e=>getComputedStyle(e).display==='none')", web)
        XCTAssertEqual(hidden as? Bool, true)
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
        let web = AccessibleWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
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
        try await web.evaluateCompatibleJavaScript(source, in: nil, contentWorld: ManualAdBlockRuntime.world)
    }
}
