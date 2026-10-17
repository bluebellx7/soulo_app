import XCTest
import WebKit
@testable import Soulo

@MainActor final class WebAdOverlayCleanupTests: XCTestCase {
    private func page(_ content: String, host: String = "m.mgtv.com", privacy: Bool = false, filterAds: Bool = true) async throws -> WKWebView {
        let web = WKWebView(frame:CGRect(x:0,y:0,width:390,height:700))
        web.loadHTMLString("""
        <html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>
        body{margin:0;min-height:2000px}.ReactModal__Body--open{overflow:hidden}
        .ReactModal__Overlay{position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:999}
        .ReactModal__Content{position:absolute;top:200px;left:30px;width:300px;background:white}
        </style></head><body class='ReactModal__Body--open' style='overflow:hidden'>
        <main id='__next' aria-hidden='true'><button id='underlying' style='position:fixed;top:20px;left:20px;width:120px;height:44px'>Page action</button></main>
        \(content)</body></html>
        """,baseURL:URL(string:"https://\(host)/home"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete'&&!!document.getElementById('underlying')")) as? Bool == true { break }
            try await Task.sleep(for:.milliseconds(25))
        }
        let defaults=UserDefaults.standard,saved=defaults.data(forKey:"soulo_ad_block_subscription_rules")
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules.empty),forKey:"soulo_ad_block_subscription_rules")
        defer{defaults.set(saved,forKey:"soulo_ad_block_subscription_rules")}
        if filterAds { _ = try await web.evaluateJavaScript(AdBlockService.adHidingScript()) }
        if privacy { _ = try await web.evaluateJavaScript(WebViewScripts.privacyProtection(gpcEnabled: true, cookieBannerHandling: true)) }
        return web
    }

    func testFilteredReactModalReleasesItsOrphanMaskScrollLockAndAccessibility() async throws {
        let web=try await page("<div class='ReactModal__Overlay'><div class='ReactModal__Content'><div class='popup-ad'>Advertisement</div></div></div>")
        let result=try await web.evaluateJavaScript("""
        getComputedStyle(document.querySelector('.ReactModal__Overlay')).display==='none'
          && document.elementFromPoint(40,40)===document.getElementById('underlying')
          && getComputedStyle(document.body).overflow!=='hidden'
          && !document.getElementById('__next').hasAttribute('aria-hidden')
        """)
        XCTAssertEqual(result as? Bool,true)
    }

    func testVisibleAuthenticationAndOtherDialogsKeepTheirOwnMasksAndScrollLocks() async throws {
        let web=try await page("""
        <div id='advert' class='ReactModal__Overlay'><div class='ReactModal__Content'><div class='popup-ad'>Advertisement</div></div></div>
        <div id='legitimate' class='ReactModal__Overlay'><div class='ReactModal__Content' role='dialog'><p>Account sign in</p><input type='password'><button>Sign in</button></div></div>
        """)
        let result=try await web.evaluateJavaScript("""
        getComputedStyle(document.getElementById('advert')).display==='none'
          && getComputedStyle(document.getElementById('legitimate')).display!=='none'
          && getComputedStyle(document.body).overflow==='hidden'
          && document.getElementById('__next').getAttribute('aria-hidden')==='true'
        """)
        XCTAssertEqual(result as? Bool,true)
    }

    func testServiceAgreementIsVisibleAndNeverAutomaticallyAcceptedOrRejected() async throws {
        for content in [
            "<h3>个人信息保护政策</h3><p>在您使用芒果TV前，请详细阅读<a href='/terms'>《芒果TV用户服务协议》</a>。如您点击【同意】，即代表您已确认同意以上全部约定。</p><div onclick='window.choice=true'>不同意</div><div onclick='window.choice=true'>同意</div>",
            "<h3>Privacy policy</h3><p>Please read our <a href='/terms'>Terms of Service</a> before using this service. By clicking accept you agree to these terms.</p><button onclick='window.choice=true'>Decline</button><button onclick='window.choice=true'>Accept</button>"
        ] {
            let web=try await page("<div class='ReactModal__Overlay'><div class='ReactModal__Content' role='dialog'>"+content+"</div></div>",privacy:true)
            let preserved=try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ReactModal__Content')).display!=='none'&&!window.choice")
            XCTAssertEqual(preserved as? Bool,true)
        }
    }

    func testCookieOnlyModalClearsBackdropWithoutAdFiltering() async throws {
        let web=try await page("<div class='ReactModal__Overlay'><div class='ReactModal__Content' role='dialog'><p>We use cookies to personalize content.</p><p>Choose your cookie privacy preferences.</p></div></div>",privacy:true,filterAds:false)
        let cleared=try await web.evaluateJavaScript("getComputedStyle(document.querySelector('.ReactModal__Overlay')).display==='none'&&document.elementFromPoint(40,40)===document.getElementById('underlying')&&getComputedStyle(document.body).overflow!=='hidden'")
        XCTAssertEqual(cleared as? Bool,true)
    }

    func testCookieCleanupPreservesAnotherVisibleAuthenticationModal() async throws {
        let web=try await page("<div id='cookies' class='ReactModal__Overlay'><div class='ReactModal__Content' role='dialog'><p>We use cookies.</p><p>Cookie privacy preferences</p></div></div><div id='login' class='ReactModal__Overlay'><div class='ReactModal__Content' role='dialog'><input type='password'><p>Account sign in</p></div></div>",privacy:true,filterAds:false)
        let protected=try await web.evaluateJavaScript("getComputedStyle(document.getElementById('cookies')).display==='none'&&getComputedStyle(document.getElementById('login')).display!=='none'&&getComputedStyle(document.body).overflow==='hidden'")
        XCTAssertEqual(protected as? Bool,true)
    }

    func testMgtvSiblingMaskIsClearedOnlyForAnAlreadyFilteredDialog() async throws {
        let web=try await page("<style>.styles_mask__test{position:fixed;inset:0;background:#0009}.styles_dialog__test{position:fixed;top:200px;left:30px;width:300px}</style><div id='app-promo' class='styles_mgui-dialog__test'><div class='styles_dialog__test'><div class='popup-ad'>Promotion</div></div><div class='styles_mask__test'></div></div>")
        let cleared=try await web.evaluateJavaScript("getComputedStyle(document.getElementById('app-promo')).display==='none'&&document.elementFromPoint(40,40)===document.getElementById('underlying')")
        XCTAssertEqual(cleared as? Bool,true)
    }

    func testVideoToolbarMutationsDoNotTriggerWholePageFilters() async throws {
        let web=try await page("",privacy:true)
        _ = try await web.evaluateJavaScript("""
        window.adScans=0;window.privacyScans=0;
        const adScan=window.__souloAdBlockRemoveAds,privacyScan=window.__souloPrivacyScan;
        window.__souloAdBlockRemoveAds=()=>{adScans++;adScan()};
        window.__souloPrivacyScan=()=>{privacyScans++;privacyScan()};
        const toolbar=document.createElement('div');toolbar.setAttribute('data-soulo-video-rotate','');document.body.append(toolbar);
        toolbar.innerHTML='<button><svg><path></path></svg></button>';
        toolbar.firstElementChild.setAttribute('aria-expanded','true');
        const badge=document.createElement('div');badge.setAttribute('data-soulo-hold-speed','');badge.textContent='2×';document.body.append(badge);badge.remove();
        """)
        try await Task.sleep(for:.milliseconds(400))
        let unnecessary=try await web.evaluateJavaScript("adScans+privacyScans")
        XCTAssertEqual(unnecessary as? Int,0,"Opening Soulo controls must not rescan the website")
        _ = try await web.evaluateJavaScript(#"document.body.insertAdjacentHTML('beforeend','<div class=popup-ad>Advertisement</div><div id=cookie-banner style="position:fixed;top:0;width:300px;height:100px">We use cookies to personalize content.</div>')"#)
        try await Task.sleep(for:.milliseconds(500))
        let normalFiltering=try await web.evaluateJavaScript("adScans>0&&privacyScans>0&&getComputedStyle(document.querySelector('.popup-ad')).display==='none'&&getComputedStyle(document.getElementById('cookie-banner')).display==='none'")
        XCTAssertEqual(normalFiltering as? Bool,true,"Actual page changes must still be filtered")
    }

    func testMgtvPromotionUsesContinueInBrowserWithoutOpeningTheApp() async throws {
        let html="""
        <div class='OpenAppDialog_container__test'><p>打开方式</p><p onclick="window.dismissed=true;this.parentElement.remove()">继续使用浏览器</p><button onclick="window.appOpened=true">打开</button></div>
        """
        let web=try await page(html)
        let dismissed=try await web.evaluateJavaScript("window.dismissed===true&&!window.appOpened&&!document.querySelector('[class*=OpenAppDialog_container__]')")
        XCTAssertEqual(dismissed as? Bool,true)
        let other=try await page(html,host:"example.com")
        let unchanged=try await other.evaluateJavaScript("!window.dismissed&&!window.appOpened&&!!document.querySelector('[class*=OpenAppDialog_container__]')")
        XCTAssertEqual(unchanged as? Bool,true)
    }
}
