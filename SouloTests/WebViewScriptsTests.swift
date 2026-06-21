import XCTest
@testable import Soulo

final class WebViewScriptsTests: XCTestCase {
    func testLoginOverlayRemovalSkipsAuthenticatedAIPlatforms() {
        let script = WebViewScripts.loginOverlayRemoval

        XCTAssertTrue(script.contains("skipDomains"))
        XCTAssertTrue(script.contains("deepseek.com"))
        XCTAssertTrue(script.contains("removeOverlays"))
        XCTAssertTrue(script.contains("MutationObserver"))
    }

    func testAdHidingScriptPublishesHiddenElementStats() {
        let script = AdBlockService.adHidingScript(cosmetic: true, popups: true)

        XCTAssertTrue(script.contains("souloAdBlocker"))
        XCTAssertTrue(script.contains("hiddenCount"))
        XCTAssertTrue(script.contains("trackerHosts"))
        XCTAssertTrue(script.contains("location.hostname"))
    }

    func testAdHidingScriptCoversChineseVideoSiteFloatingAds() {
        let script = AdBlockService.adHidingScript(cosmetic: true, popups: true)

        XCTAssertTrue(script.contains(".cpcad"))
        XCTAssertTrue(script.contains("gudingwei"))
        XCTAssertTrue(script.contains("isLikelyFloatingAd"))
        XCTAssertTrue(script.contains("position !== 'fixed' && position !== 'absolute'"))
    }

    func testPrivacyProtectionScriptIncludesGPCResourceObservationAndCookieHandling() {
        let script = WebViewScripts.privacyProtection(
            gpcEnabled: true,
            cookieBannerHandling: true,
            disabledHosts: ["example.com"]
        )

        XCTAssertTrue(script.contains("globalPrivacyControl"))
        XCTAssertTrue(script.contains("souloPrivacy"))
        XCTAssertTrue(script.contains("resourceObserved"))
        XCTAssertTrue(script.contains("observations"))
        XCTAssertTrue(script.contains("resourceType"))
        XCTAssertTrue(script.contains("cookieBanner"))
        XCTAssertTrue(script.contains("example.com"))
        XCTAssertTrue(script.contains("MutationObserver"))
    }

    func testPrivacyProtectionScriptCanDisableGPCAndCookieHandling() {
        let script = WebViewScripts.privacyProtection(gpcEnabled: false, cookieBannerHandling: false)

        XCTAssertTrue(script.contains("var souloGPCEnabled = false"))
        XCTAssertTrue(script.contains("var souloCookieBannerHandling = false"))
    }

}
