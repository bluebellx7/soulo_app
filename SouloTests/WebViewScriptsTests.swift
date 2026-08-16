import XCTest
import JavaScriptCore
import WebKit
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

    func testAccessibilityEnhancementsAreConservativeAndIdempotent() {
        let script = WebViewScripts.accessibilityEnhancements

        XCTAssertTrue(script.contains("__souloAccessibilityInstalled"))
        XCTAssertTrue(script.contains("__souloAccessibilityScan"))
        XCTAssertTrue(script.contains("MutationObserver"))
        XCTAssertTrue(script.contains("data-soulo-accessible-result"))
        XCTAssertTrue(script.contains("aria-label"))
        XCTAssertTrue(script.contains("aria-level"))
        XCTAssertTrue(script.contains("role', 'button"))
        XCTAssertFalse(script.contains("style.display = '"))
        XCTAssertFalse(script.contains("style.setProperty"))
        XCTAssertFalse(script.contains("removeChild"))
    }

    func testAccessibilityPlatformNavigationStopsAtBoundaries() {
        XCTAssertEqual(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 1,
                count: 3,
                direction: .previous
            ),
            0
        )
        XCTAssertEqual(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 1,
                count: 3,
                direction: .next
            ),
            2
        )
        XCTAssertNil(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 0,
                count: 3,
                direction: .previous
            )
        )
        XCTAssertNil(
            PlatformAccessibilityNavigation.adjacentIndex(
                currentIndex: 2,
                count: 3,
                direction: .next
            )
        )
    }

    func testAccessibilityWebPagingClampsAndReportsPosition() {
        XCTAssertEqual(
            WebAccessibilityPaging.targetOffset(
                current: 100,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            ),
            510
        )
        XCTAssertEqual(
            WebAccessibilityPaging.targetOffset(
                current: 900,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            ),
            1_000
        )
        XCTAssertNil(
            WebAccessibilityPaging.targetOffset(
                current: 1_000,
                minimum: 0,
                maximum: 1_000,
                viewportHeight: 500,
                direction: .forward
            )
        )

        let position = WebAccessibilityPaging.pagePosition(
            offset: 820,
            minimum: 0,
            maximum: 1_640,
            viewportHeight: 500
        )
        XCTAssertEqual(position.current, 3)
        XCTAssertEqual(position.total, 5)
    }

    func testInjectedBrowserScriptsAreParsableJavaScript() {
        assertJavaScriptParses(AdBlockService.adHidingScript(cosmetic: true))
        assertJavaScriptParses(WebViewScripts.blankPageProbe)
        assertJavaScriptParses(WebViewScripts.privacyProtection(gpcEnabled: true, cookieBannerHandling: true))
        assertJavaScriptParses(WebViewScripts.downloadBridge)
        assertJavaScriptParses(WebViewScripts.extensionInstallBridge)
        assertJavaScriptParses(WebViewScripts.accessibilityEnhancements)
        assertJavaScriptParses(WebViewScripts.webAppearanceBootstrap)
        assertJavaScriptParses(WebViewScripts.applyWebAppearance(warmColorShift: true, forceDark: true))
        assertJavaScriptParses(WebViewScripts.synchronizeViewport)
        assertJavaScriptParses(WebViewScripts.compensatePageZoomWidth(scale: 1.2))
    }

    func testPageZoomCompensationKeepsTheRenderedDocumentAtViewportWidth() {
        let enlarged = WebViewScripts.compensatePageZoomWidth(scale: 1.2)
        let reset = WebViewScripts.compensatePageZoomWidth(scale: 1)

        XCTAssertTrue(enlarged.contains("var scale = 1.20000"))
        XCTAssertTrue(enlarged.contains("100 / scale"))
        XCTAssertTrue(enlarged.contains("root.style.setProperty('width'"))
        XCTAssertTrue(enlarged.contains("'important'"))
        XCTAssertTrue(reset.contains("Math.abs(scale - 1)"))
        XCTAssertTrue(reset.contains("delete window[stateKey]"))
    }

    func testUserScriptURLMatchingSupportsManifestGlobsAndAllURLs() {
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://news.example.com/article/42")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "http://localhost/page")!,
                patterns: ["<all_urls>"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com/article")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertFalse(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.org/")!,
                patterns: ["*://*.example.com/*"]
            )
        )
        XCTAssertTrue(UserScriptURLMatcher.isValid(pattern: "/^https:\\/\\/example\\.com\\//"))
        XCTAssertFalse(UserScriptURLMatcher.isValid(pattern: "ftp://example.com/*"))
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com:8443/path")!,
                patterns: ["*://example.com/*"]
            )
        )
        XCTAssertTrue(
            UserScriptURLMatcher.matches(
                url: URL(string: "https://example.com/path")!,
                patterns: ["http*://example.com/*"]
            )
        )
    }

    func testUserScriptCompatibilityBridgeAndDocumentEndSchedulingAreValidJavaScript() {
        let script = UserScriptRecord(
            name: "Load Timing",
            source: "window.onload = function() { window.__loaded = true; };",
            injectionTime: .documentEnd
        )
        let bridgeToken = "private-token"
        let bootstrap = UserScriptRuntime.compatibilityBootstrap(
            bridgeToken: bridgeToken,
            scriptID: script.id,
            allowsXMLHTTPRequests: true
        )
        let wrapped = UserScriptRuntime.wrappedSource(for: script, bridgeToken: bridgeToken)

        XCTAssertTrue(wrapped.contains("DOMContentLoaded"))
        XCTAssertTrue(wrapped.contains("document.readyState === 'loading'"))
        XCTAssertTrue(wrapped.contains("__souloIncludes"))
        XCTAssertTrue(bootstrap.contains("GM_xmlhttpRequest"))
        XCTAssertTrue(bootstrap.contains("souloUserScriptXHR"))
        XCTAssertTrue(bootstrap.contains("unsafeWindow"))
        XCTAssertTrue(bootstrap.contains(bridgeToken))
        XCTAssertFalse(bootstrap.contains("window.GM_xmlhttpRequest"))
        assertJavaScriptParses(wrapped)
        assertJavaScriptParses(bootstrap)
    }

    @MainActor
    func testFullPageCapturePreparationLoadsLazyResourcesAndRestoresScrollPosition() {
        let script = WebPageCaptureService.resourcePreparationScript

        XCTAssertTrue(script.contains("document.images"))
        XCTAssertTrue(script.contains("document.fonts"))
        XCTAssertTrue(script.contains("window.scrollTo(originalX, originalY)"))
        assertAsyncJavaScriptParses(script)
    }

    @MainActor
    func testUserScriptRuntimeActuallyExecutesInsideWKWebView() async throws {
        let webView = WKWebView(frame: .zero)
        _ = try await evaluate("globalThis.__souloUserScriptProbe = 0", in: webView)
        let script = UserScriptRecord(
            name: "Runtime Probe",
            source: "globalThis.__souloUserScriptProbe += 1;",
            matchPatterns: ["*"]
        )

        let result: Result<Any?, Error> = await withCheckedContinuation { continuation in
            UserScriptRuntime.execute(script, on: webView) { result in
                continuation.resume(returning: result)
            }
        }
        if case let .failure(error) = result { throw error }

        let value = try await evaluate("globalThis.__souloUserScriptProbe", in: webView)
        XCTAssertEqual((value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testUserScriptInstallParsesMetadataAndEnableSwitchControlsSelection() throws {
        let marker = UUID().uuidString
        let source = """
        // ==UserScript==
        // @name Selection Probe \(marker)
        // @namespace com.soulo.tests.\(marker)
        // @version 1.2.3
        // @match https://example.com/*
        // @exclude https://example.com/private/*
        // @grant GM_xmlhttpRequest
        // @connect api.example.com
        // @run-at document-start
        // ==/UserScript==
        globalThis.__souloSelectionProbe = true;
        """
        let service = BrowserExtensionService.shared
        let record = try service.saveUserScript(
            id: nil,
            fallbackName: "Fallback",
            source: source,
            explicitPatterns: nil,
            injectionTime: nil
        )
        defer { service.deleteUserScript(record.id) }

        XCTAssertEqual(record.name, "Selection Probe \(marker)")
        XCTAssertEqual(record.namespace, "com.soulo.tests.\(marker)")
        XCTAssertEqual(record.version, "1.2.3")
        XCTAssertEqual(record.excludePatterns, ["https://example.com/private/*"])
        XCTAssertEqual(record.grants, ["GM_xmlhttpRequest"])
        XCTAssertEqual(record.connectDomains, ["api.example.com"])
        XCTAssertEqual(record.injectionTime, .documentStart)
        XCTAssertTrue(service.scripts(
            for: URL(string: "https://example.com/article")!,
            at: .documentStart
        ).contains { $0.id == record.id })
        XCTAssertFalse(service.scripts(
            for: URL(string: "https://example.com/private/account")!,
            at: .documentStart
        ).contains { $0.id == record.id })

        service.setUserScriptEnabled(record.id, enabled: false)
        XCTAssertFalse(service.scripts(
            for: URL(string: "https://example.com/article")!,
            at: .documentStart
        ).contains { $0.id == record.id })
    }

    @MainActor
    func testUserScriptReinstallUpdatesNamespacedRecordWithoutCreatingADuplicate() throws {
        let marker = UUID().uuidString
        let service = BrowserExtensionService.shared
        let firstSource = """
        // ==UserScript==
        // @name Update Probe \(marker)
        // @namespace com.soulo.update.\(marker)
        // @version 1.0
        // @match https://example.com/*
        // ==/UserScript==
        globalThis.__version = 1;
        """
        let first = try service.saveUserScript(
            id: nil,
            fallbackName: "Probe",
            source: firstSource,
            explicitPatterns: nil,
            injectionTime: nil
        )
        defer { service.deleteUserScript(first.id) }

        let updated = try service.saveUserScript(
            id: nil,
            fallbackName: "Probe",
            source: firstSource.replacingOccurrences(of: "@version 1.0", with: "@version 2.0"),
            explicitPatterns: nil,
            injectionTime: nil
        )

        XCTAssertEqual(updated.id, first.id)
        XCTAssertEqual(updated.version, "2.0")
        XCTAssertEqual(service.userScripts.filter { $0.id == first.id }.count, 1)
    }

    @MainActor
    func testUserScriptRejectsInvalidWebsiteRule() {
        XCTAssertThrowsError(
            try BrowserExtensionService.shared.saveUserScript(
                id: nil,
                fallbackName: "Invalid",
                source: "globalThis.invalid = true;",
                explicitPatterns: ["ftp://example.com/*"],
                injectionTime: .documentEnd
            )
        )
    }

    func testUserScriptConnectPolicyHonorsDeclaredDomains() {
        let script = UserScriptRecord(
            name: "Network",
            source: "",
            connectDomains: ["api.example.com", "self"]
        )
        XCTAssertTrue(UserScriptConnectPolicy.allows(
            url: URL(string: "https://v2.api.example.com/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertTrue(UserScriptConnectPolicy.allows(
            url: URL(string: "https://www.example.org/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptConnectPolicy.allows(
            url: URL(string: "https://tracker.invalid/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptHTTPBridge.isAllowedTarget(
            URL(string: "http://127.0.0.1/private")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
        XCTAssertFalse(UserScriptHTTPBridge.isAllowedTarget(
            URL(string: "https://api.example.com.evil.invalid/data")!,
            script: script,
            pageURL: URL(string: "https://www.example.org")!
        ))
    }

    private func assertJavaScriptParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = JSContext()!
        context.evaluateScript("new Function(\(javaScriptStringLiteral(script)))")
        XCTAssertNil(context.exception, file: file, line: line)
    }

    private func assertAsyncJavaScriptParses(_ script: String, file: StaticString = #filePath, line: UInt = #line) {
        let context = JSContext()!
        let wrapped = "return (async () => {\n\(script)\n})();"
        context.evaluateScript("new Function(\(javaScriptStringLiteral(wrapped)))")
        XCTAssertNil(context.exception, file: file, line: line)
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayLiteral = String(data: data, encoding: .utf8)!
        return "(\(arrayLiteral))[0]"
    }

    @MainActor
    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: value)
                }
            }
        }
    }

}
