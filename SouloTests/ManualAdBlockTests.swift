import XCTest
import WebKit
import SwiftUI
import SwiftData
@testable import Soulo

@MainActor
final class ManualAdBlockTests: XCTestCase {
    private var savedBuiltInOverrides: Data?
    private var savedBuiltInRevision: String?
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedBuiltInOverrides = defaults.data(forKey: BuiltInAdRuleStore.storageKey)
        savedBuiltInRevision = defaults.string(forKey: BuiltInAdRuleStore.versionKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
    }
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.set(savedBuiltInOverrides, forKey: BuiltInAdRuleStore.storageKey)
        defaults.set(savedBuiltInRevision, forKey: BuiltInAdRuleStore.versionKey)
        super.tearDown()
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

    func testFixedBottomAdRemainsReachableAbovePickerControls() async throws {
        let web = try await fixture()
        // Use an unrecognized name so automatic filtering does not hide this
        // fixture before the user can manually select it.
        try await js("""
        document.body.insertAdjacentHTML('beforeend', '<aside id="bottom-promotion" style="position:fixed;bottom:0;left:0;width:100%;height:70px;z-index:999999;background:orange">Promotion</aside>'); null
        """, web)
        let model = WebViewModel()
        model.webView = web
        model.updateCurrentURL(web.url)
        let container = try ModelContainer(for: BookmarkItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView:
            WebViewContainer(webViewModel: model, bookmarkViewModel: BookmarkViewModel(), isFullscreen: .constant(false))
                .environmentObject(SearchViewModel()).modelContainer(container))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            model.cancelMarkingAdvertisement()
            window.isHidden = true; window.rootViewController = nil
            model.releaseWebViewRuntime(); previous?.makeKeyAndVisible()
        }
        try await Task.sleep(for: .milliseconds(350))
        try await configure(web)
        for _ in 0..<100 {
            if let width = try await js("innerWidth", web) as? Double, abs(width - web.bounds.width) < 2 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        model.beginMarkingAdvertisement()
        for _ in 0..<100 {
            if !model.manualAdBusy { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(model.manualAdSelection)
        try await Task.sleep(for: .milliseconds(300))
        let initialHeight = try await js("innerHeight", web) as? Double
        for selected in [false, true] {
            if selected { _ = try await pick("#bottom-promotion", in: web) }
            try await Task.sleep(for: .milliseconds(300))
            host.view.layoutIfNeeded()
            let currentHeight = try await js("innerHeight", web) as? Double
            XCTAssertEqual(currentHeight, initialHeight, "Selecting must not resize the reserved web viewport")
            let result = try await js("(() => { const r = document.querySelector('#bottom-promotion').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2]; })()", web)
            let coordinates = try XCTUnwrap(result as? [Double])
            let point = web.convert(CGPoint(x: coordinates[0], y: coordinates[1]), to: window)
            let hit = window.hitTest(point, with: nil)
            XCTAssertTrue(hit === web || hit?.isDescendant(of: web) == true,
                "The picker must not cover a fixed bottom advertisement, selected=\(selected)")
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

    private func addPairedImageBanner(_ web: WKWebView, runtime: String = "rt_123_456", valid: Bool = true) async throws {
        try await js("""
        (() => {
          const runtime='\(runtime)', id='_s_sabc123_'+runtime;
          const root=document.createElement('div');root.id=id;
          root.style.cssText='position:fixed;bottom:0;left:0;width:100%;height:120px;z-index:99999998';
          const close=document.createElement('div');close.setAttribute('onclick',`event.stopPropagation();window['_x_${runtime}']('${id}')`);
          const link=document.createElement('div');link.setAttribute('onclick',`window['_j_${runtime}']()`);
          const img=document.createElement('img');img.src='https://images.example.test/\(valid ? "navImgs/files/ad.gif" : "products/product.gif")';img.style.cssText='width:100%;height:120px';
          link.append(img);root.append(close,link);const wrapper=document.createElement('div');wrapper.append(root);document.body.append(wrapper);
          const mask=document.createElement('div');mask.id='mask_'+id;mask.style.cssText='position:fixed;bottom:0;left:0;width:100%;height:25vh;z-index:99999997';document.body.append(mask);
        })()
        """, web)
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
        try await addRandomBottomMosaic(web, tag: "replacementtile")
        let selection = try await js("window.__souloManualAds.selection()", web) as? [String: Any]
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
        try await web.evaluateJavaScript(source, in: nil, contentWorld: ManualAdBlockRuntime.world)
    }
}
