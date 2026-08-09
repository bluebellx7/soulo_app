import XCTest
import JavaScriptCore
@testable import Soulo

final class WebViewScriptsTests: XCTestCase {
    func testAdHidingScriptPublishesHiddenElementStats() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertTrue(script.contains("souloAdBlocker"))
        XCTAssertTrue(script.contains("hiddenCount"))
        XCTAssertTrue(script.contains("trackerHosts"))
        XCTAssertTrue(script.contains("location.hostname"))
        XCTAssertTrue(script.contains("__souloAdBlockInstalled"))
        XCTAssertTrue(script.contains("__souloAdBlockObserver"))
        XCTAssertTrue(script.contains("__souloAdBlockRemoveAds"))
    }

    func testAdHidingScriptCoversChineseVideoSiteFloatingAds() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertTrue(script.contains(".cpcad"))
        XCTAssertTrue(script.contains("gudingwei"))
        XCTAssertFalse(script.contains("isLikelyFloatingAd"))
        XCTAssertFalse(script.contains("div, section, aside, iframe, a, img"))
        XCTAssertTrue(script.contains("isAuthenticationElement"))
        XCTAssertFalse(script.contains("text.includes('ad')"))
        XCTAssertFalse(script.contains("iframe[src*=\"ad\"]"))
        XCTAssertFalse(script.contains("img[src*=\"ad\"]"))
        XCTAssertFalse(script.contains("a[href*=\"ad\"]"))
        XCTAssertFalse(script.contains("[class*=\"interstitial\"]"))
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
        XCTAssertTrue(script.contains("isSensitiveChallengePage"))
        XCTAssertTrue(script.contains("observations"))
        XCTAssertTrue(script.contains("resourceType"))
        XCTAssertTrue(script.contains("__souloPrivacyProtectionInstalled"))
        XCTAssertTrue(script.contains("__souloPrivacyObserver"))
        XCTAssertTrue(script.contains("resourceURLForElement"))
        XCTAssertTrue(script.contains("observations.length < 120"))
        XCTAssertFalse(script.contains("a[href]"))
        XCTAssertTrue(script.contains("cookieBanner"))
        XCTAssertTrue(script.contains("isProtectedPageElement"))
        XCTAssertTrue(script.contains("hasCookieConsentLanguage"))
        XCTAssertTrue(script.contains("isOverlayLike"))
        XCTAssertFalse(script.contains("rect.bottom > window.innerHeight * 0.65"))
        XCTAssertFalse(script.contains("dialog, footer"))
        XCTAssertTrue(script.contains("example.com"))
        XCTAssertTrue(script.contains("MutationObserver"))
    }

    func testPrivacyProtectionScriptCanDisableGPCAndCookieHandling() {
        let script = WebViewScripts.privacyProtection(gpcEnabled: false, cookieBannerHandling: false)

        XCTAssertTrue(script.contains("var souloGPCEnabled = false"))
        XCTAssertTrue(script.contains("var souloCookieBannerHandling = false"))
    }

    func testDownloadBridgeCapturesGeneratedFilesAndReportsProgress() {
        let script = WebViewScripts.downloadBridge

        XCTAssertTrue(script.contains("souloDownload"))
        XCTAssertTrue(script.contains("blob:"))
        XCTAssertTrue(script.contains("data:"))
        XCTAssertTrue(script.contains("type: 'started'"))
        XCTAssertTrue(script.contains("type: 'chunk'"))
        XCTAssertTrue(script.contains("type: 'finished'"))
        XCTAssertTrue(script.contains("type: 'failed'"))
        XCTAssertTrue(script.contains("__souloCancelDownloads"))
        XCTAssertTrue(script.contains("blob.slice"))
        XCTAssertTrue(script.contains("FileReader"))
        XCTAssertFalse(script.contains("readAsDataURL"))
    }

    func testInjectedBrowserScriptsAreParsableJavaScript() {
        assertJavaScriptParses(AdBlockService.adHidingScript(cosmetic: true))
        assertJavaScriptParses(WebViewScripts.blankPageProbe)
        assertJavaScriptParses(WebViewScripts.privacyProtection(gpcEnabled: true, cookieBannerHandling: true))
        assertJavaScriptParses(WebViewScripts.downloadBridge)
    }

    private func assertJavaScriptParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = JSContext()!
        context.evaluateScript("new Function(\(javaScriptStringLiteral(script)))")
        XCTAssertNil(context.exception, file: file, line: line)
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayLiteral = String(data: data, encoding: .utf8)!
        return "(\(arrayLiteral))[0]"
    }

}
