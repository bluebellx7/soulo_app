import XCTest
import SwiftUI
import WebKit
@testable import Soulo

final class WebCompatibilityServiceTests: XCTestCase {
    func testCloudflareChallengeURLsAreScopedToVerificationResources() throws {
        let expressions = try WebCompatibilityService.cloudflareChallengeURLFilters.map { filter in
            XCTAssertEqual(AdBlockService.sanitizedContentBlockerURLFilter(filter), filter)
            return try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        }
        for address in ["https://challenges.cloudflare.com/turnstile/v0/api.js",
            "https://probe.challenges.cloudflare.com/check", "https://www.diyihuisuo.com/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1"] {
            XCTAssertTrue(WebCompatibilityService.isCloudflareChallengeURL(URL(string: address)), address)
            XCTAssertTrue(WebCompatibilityService.shouldBypassWebProtection(for: URL(string: address)), address)
            XCTAssertTrue(expressions.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil }, address)
        }
        for address in ["https://cloudflare.com/", "https://static.cloudflareinsights.com/beacon.min.js",
            "https://challenges.cloudflare.com.evil.test/script.js", "https://example.com/help?url=https://challenges.cloudflare.com/"] {
            XCTAssertFalse(WebCompatibilityService.isCloudflareChallengeURL(URL(string: address)), address)
            XCTAssertFalse(expressions.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil }, address)
        }
        XCTAssertTrue(WebCompatibilityService.isSensitiveChallengeURL(URL(string: "https://example.com/?__cf_chl_rt_tk=token")))
        XCTAssertFalse(WebCompatibilityService.isSensitiveChallengeURL(URL(string: "https://www.diyihuisuo.com/")), "An unmarked root URL requires response/DOM detection")
        XCTAssertFalse(WebCompatibilityService.shouldBypassWebProtection(for: URL(string: "https://brandverse.ai/user/login?refer=huski.ai")))
    }

    func testOrdinaryURLKeywordsDoNotDisableProtection() {
        for word in ["login", "auth", "passport", "security", "captcha", "verify", "verification", "challenge", "wappoc"] {
            for address in ["https://example.com/\(word)", "https://\(word).example.com/", "https://example.com/?ref=\(word)", "https://example.com/#\(word)"] {
                XCTAssertFalse(WebCompatibilityService.shouldBypassWebProtection(for: URL(string: address)), address)
            }
        }
        XCTAssertFalse(WebCompatibilityService.isSensitiveChallengeURL(URL(string: "https://example.com/?redirect=%3F__cf_chl_rt_tk%3Dtoken")))
        XCTAssertFalse(WebCompatibilityService.isSensitiveChallengeURL(URL(string: "https://example.com/#?__cf_chl_rt_tk=token")))
        XCTAssertTrue(WebCompatibilityService.isSensitiveChallengeURL(URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=token")))
    }

    func testVerificationProviderExceptionsStayScopedToTheirResources() throws {
        let expressions = try WebCompatibilityService.verificationResourceURLFilters.map { filter in
            XCTAssertEqual(AdBlockService.sanitizedContentBlockerURLFilter(filter), filter)
            return try NSRegularExpression(pattern: filter)
        }
        for address in ["https://www.google.com/recaptcha/api.js", "https://www.gstatic.com/recaptcha/releases/v1/recaptcha.js",
            "https://www.recaptcha.net/recaptcha/api2/anchor", "https://newassets.hcaptcha.com/captcha/v1/widget"] {
            XCTAssertTrue(WebCompatibilityService.isVerificationResourceURL(URL(string: address)))
            XCTAssertTrue(expressions.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil })
        }
        for address in ["https://www.google.com/analytics/script.js", "https://www.google.com/search?q=recaptcha",
            "https://newassets.hcaptcha.com.evil.test/widget", "https://example.com/?redirect=https://challenges.cloudflare.com/widget"] {
            XCTAssertFalse(WebCompatibilityService.isVerificationResourceURL(URL(string: address)))
            XCTAssertFalse(expressions.contains { $0.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil })
        }
    }

    @MainActor func testEmbeddedVerificationKeepsLoginControlsVisibleWhileAdvertisementsAreFiltered() async throws {
        let defaults = UserDefaults.standard, key = "soulo_ad_block_subscription_rules"
        let saved = defaults.object(forKey: key); defer { defaults.set(saved, forKey: key) }
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules(cosmeticSelectors: [".qa-filter-target"])), forKey: key)
        let compiled = await AdBlockService.compileRuleLists()
        let rules = try XCTUnwrap(compiled)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        rules.forEach(config.userContentController.add)
        config.userContentController.addUserScript(WKUserScript(source: AdBlockService.adHidingScript(nativeCosmeticFiltering: true), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        web.loadHTMLString("""
        <form id='login' class='qa-filter-target'><label>Email<input name='email'></label><input type='password'>
        <div id='turnstile' class='qa-filter-target'>Verify<input type='hidden' name='cf-turnstile-response' id='cf-chl-widget-fixture_response'></div></form>
        <div id='hcaptcha' class='qa-filter-target'><div class='h-captcha'>Verify</div></div>
        <div id='recaptcha' class='qa-filter-target'><div class='g-recaptcha'>Verify</div></div>
        <aside id='advert' class='qa-filter-target'>Advertisement</aside>
        """, baseURL: URL(string: "https://brandverse.ai/user/login?refer=huski.ai"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.__souloAdBlockInstalled")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let visible = try await web.evaluateJavaScript("['login','turnstile','hcaptcha','recaptcha'].every(id=>getComputedStyle(document.getElementById(id)).display!=='none')")
        let advert = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('advert')).display")
        let enabled = try await web.evaluateJavaScript("!document.documentElement.hasAttribute('data-soulo-native-ads-disabled')")
        XCTAssertEqual(visible as? Bool, true)
        XCTAssertEqual(advert as? String, "none")
        XCTAssertEqual(enabled as? Bool, true, "An embedded widget must not bypass the whole login document")
    }

    @MainActor func testVerificationFramesKeepNativeAPIsAndOrdinaryLoginKeepsProtection() async throws {
        let pages = [
            ("https://challenges.cloudflare.com/cdn-cgi/challenge-platform/widget", true),
            ("https://newassets.hcaptcha.com/captcha/v1/widget", true),
            ("https://www.google.com/recaptcha/api2/anchor", true),
            ("https://www.recaptcha.net/recaptcha/api2/anchor", true),
            ("https://brandverse.ai/user/login?refer=huski.ai", false),
            ("https://challenges.cloudflare.com.evil.test/turnstile/widget", false)
        ]
        for (address, verification) in pages {
            let web = WKWebView()
            web.loadHTMLString("""
            <script>window.originalFetch=fetch;window.originalXHROpen=XMLHttpRequest.prototype.open;window.originalCopy=Document.prototype.execCommand;</script><p id='ready'>Ready</p>
            """, baseURL: URL(string: address))
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            _ = try await web.evaluateJavaScript(WebViewScripts.clipboardProtection + "\n" + WebViewScripts.mediaResourceTracking + "\n" + WebViewScripts.textSelection + "\nnull")
            let value = try await web.evaluateJavaScript("({fetchNative:fetch===originalFetch,xhrNative:XMLHttpRequest.prototype.open===originalXHROpen,copyNative:Document.prototype.execCommand===originalCopy,selection:!!window.__souloTextSelection})") as? [String: Bool]
            XCTAssertEqual(value?["fetchNative"], verification, address)
            XCTAssertEqual(value?["xhrNative"], verification, address)
            XCTAssertEqual(value?["copyNative"], verification, address)
            XCTAssertEqual(value?["selection"], !verification, address)
        }
    }

    func testCloudflareResponseRequiresTheChallengeHeader() throws {
        let url = try XCTUnwrap(URL(string: "https://www.diyihuisuo.com/"))
        let challenge = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["cf-mitigated": "challenge"]))
        let ordinary = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 403, httpVersion: nil, headerFields: ["Server": "cloudflare"]))
        XCTAssertTrue(WebCompatibilityService.isCloudflareChallengeResponse(challenge))
        XCTAssertFalse(WebCompatibilityService.isCloudflareChallengeResponse(ordinary))
    }

    @MainActor func testCloudflareDocumentDetectionDoesNotBypassOrdinaryJSDOrBrandverseAssets() async throws {
        let web = WKWebView()
        web.loadHTMLString("<h1>Page</h1>", baseURL: URL(string: "https://example.com/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState")) as? String == "complete" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let detector = WebCompatibilityService.sensitiveChallengeDetectionScript + "\nisSensitiveChallengePage();"
        for (markup, expected) in [
            ("<form id='challenge-form'>Verification</form>", false),
            ("<script type='application/json' src='/cdn-cgi/challenge-platform/h/g/orchestrate/chl_page/v1'></script>", true),
            ("<script type='application/json' src='/cdn-cgi/challenge-platform/h/g/scripts/jsd/main.js'></script>", false),
            ("<script type='application/json' src='https://challenges.cloudflare.com/turnstile/v0/api.js'></script><p>Article</p>", false)
        ] {
            _ = try await web.callAsyncJavaScript("document.body.innerHTML=markup;", arguments: ["markup": markup], in: nil, in: .page)
            let value = try await web.evaluateJavaScript(detector)
            XCTAssertEqual(value as? Bool, expected, markup)
        }
        for address in ["https://brandverse.ai/user/login?refer=huski.ai",
            "https://dm4yoby2qwi1x.cloudfront.net/prod/88de010f/_next/static/chunks/app/user/login/page-eb13f46850453ed7.js"] {
            XCTAssertFalse(WebCompatibilityService.isCloudflareChallengeURL(URL(string: address)))
        }
    }

    @MainActor func testCloudflareResponsePausesCosmeticsOnlyUntilTheNextDocument() async throws {
        let defaults = UserDefaults.standard
        let keys = ["ad_block_enabled", "is_incognito", "soulo_ad_block_subscription_rules", "soulo_ad_block_subscription_rules_version"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(true, forKey: "ad_block_enabled"); defaults.set(true, forKey: "is_incognito")
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules(networkURLFilters: [], cosmeticSelectors: [".qa-verification"])), forKey: "soulo_ad_block_subscription_rules")
        defaults.set(Date().timeIntervalSince1970, forKey: "soulo_ad_block_subscription_rules_version")
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/checkpoint": Data("<h1 id='verification' class='qa-verification'>Verification</h1>".utf8),
            "/cdn-cgi/challenge-platform/h/g/return": Data("<script>parent.location.replace('/checkpoint?verified=1');</script>".utf8),
            "/ordinary": Data("<p id='article'>Article</p><aside id='advert' class='qa-verification'>Advertisement</aside>".utf8)
        ], responseHeaders: ["/checkpoint": ["cf-mitigated": "challenge"]])
        let root = try await server.start(); defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene), model = WebViewModel()
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model)); window.makeKeyAndVisible()
        defer { model.releaseWebViewRuntime(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for _ in 0..<100 where model.webView == nil { try await Task.sleep(for: .milliseconds(20)) }
        let web = try XCTUnwrap(model.webView)
        let compiled = await AdBlockService.compileRuleLists()
        let lists = try XCTUnwrap(compiled)
        WebViewRepresentable.applyContentRules(lists, on: web, allowlist: [])
        func wait(_ expression: String) async throws {
            for _ in 0..<160 {
                if (try? await web.evaluateJavaScript(expression)) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Timed out: \(expression)")
        }
        model.loadURL(root.appendingPathComponent("checkpoint"))
        try await wait("!!document.getElementById('verification') && document.documentElement.hasAttribute('data-soulo-cloudflare-challenge') && getComputedStyle(document.getElementById('verification')).display!=='none'")
        XCTAssertTrue(defaults.bool(forKey: "ad_block_enabled"))
        _ = try await web.evaluateJavaScript("document.body.insertAdjacentHTML('beforeend', '<iframe src=\"/cdn-cgi/challenge-platform/h/g/return\"></iframe>');null")
        try await wait("location.search==='?verified=1' && !!document.getElementById('verification')")
        model.loadURL(root.appendingPathComponent("ordinary"))
        try await wait("!!document.getElementById('article') && !document.documentElement.hasAttribute('data-soulo-cloudflare-challenge') && getComputedStyle(document.getElementById('advert')).display==='none'")
        XCTAssertTrue(defaults.bool(forKey: "ad_block_enabled"))
    }

    func testXiaohongshuBypassesWebProtectionToPreserveAuthenticationUI() {
        XCTAssertTrue(
            WebCompatibilityService.shouldBypassWebProtection(
                for: URL(string: "https://www.xiaohongshu.com/search_result/?keyword=test")
            )
        )
        XCTAssertTrue(WebCompatibilityService.protectionBypassHosts().contains("xiaohongshu.com"))
    }

    func testOnlyXiaohongshuRequiresDesktopModeByHost() {
        XCTAssertTrue(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://www.xiaohongshu.com/search_result?keyword=test")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://www.baidu.com/s?wd=test")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.requiresDesktopMode(
                for: URL(string: "https://weixin.qq.com")
            )
        )
    }

    func testDetectsAuthenticatedXiaohongshuSessionCookie() throws {
        let authenticated = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".xiaohongshu.com",
                .path: "/",
                .name: "web_session",
                .value: "active-session",
                .secure: "TRUE",
            ])
        )
        let anonymous = try XCTUnwrap(
            HTTPCookie(properties: [
                .domain: ".xiaohongshu.com",
                .path: "/",
                .name: "a1",
                .value: "anonymous-device",
                .secure: "TRUE",
            ])
        )

        XCTAssertTrue(
            WebCompatibilityService.hasAuthenticatedXiaohongshuSession(in: [authenticated])
        )
        XCTAssertFalse(
            WebCompatibilityService.hasAuthenticatedXiaohongshuSession(in: [anonymous])
        )
    }

    func testBypassesProtectionForWeixinSubdomains() {
        let url = URL(string: "https://mp.weixin.qq.com/s/example")!

        XCTAssertTrue(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testBypassesProtectionForSensitiveChallengeURLs() {
        let url = URL(string: "https://example.com/mp/wappoc_appmsgcaptcha?poc_token=abc")!

        XCTAssertTrue(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testDoesNotBypassProtectionForNormalPages() {
        let url = URL(string: "https://example.com/articles/webview")!

        XCTAssertFalse(WebCompatibilityService.shouldBypassWebProtection(for: url))
    }

    func testNativeViewportInsetRecognizesDouyinVideoSurfaces() {
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://www.douyin.com/video/7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas&actv_aid=7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://www.douyin.com/search/vitas?modal_id=7670376559123115750")
            )
        )
        XCTAssertTrue(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas&aweme_id=7670376559123115750")
            )
        )
    }

    func testNativeViewportInsetRejectsOrdinaryAndNonDouyinPages() {
        XCTAssertFalse(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://so.douyin.com/s?keyword=vitas")
            )
        )
        XCTAssertFalse(
            WebCompatibilityService.isDouyinVideoSurface(
                URL(string: "https://example.com/video/7670376559123115750")
            )
        )
        XCTAssertFalse(WebCompatibilityService.isDouyinVideoSurface(nil))
    }
}
