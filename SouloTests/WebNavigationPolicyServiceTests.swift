import XCTest
import WebKit
@testable import Soulo

final class WebNavigationPolicyServiceTests: XCTestCase {
    func testBilibiliUniversalAppLinksHaveExactHostAndWebFallback() throws {
        let policy = WebNavigationPolicyService.shared
        for raw in ["https://www.bilibili.com/video/BV1test", "https://m.bilibili.com/video/BV1test", "https://b23.tv/example"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(policy.universalAppScheme(for: url), "bilibili")
            XCTAssertEqual(policy.decision(for: url), .allow, "A user-chosen web fallback must stay navigable")
        }
        for raw in ["https://bilibili.com.evil.test/video/BV1test", "https://hdslb.com/video/a", "https://www.bilibili.com/favicon.ico"] {
            XCTAssertNil(policy.universalAppScheme(for: try XCTUnwrap(URL(string: raw))))
        }
    }
    func testMainFrameCrossSiteNavigationPreservesWebKitRequestAndHistory() {
        let source = URL(string: "https://cn.bing.com/videos/search?q=eggs")!
        let destination = URL(string: "https://www.bilibili.com/video/BV1example")!
        for type in [WKNavigationType.other, .linkActivated] {
            XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
                navigationType: type, targetsMainFrame: true, method: "GET", nativeRequest: false),
                "Main-frame clicks and location.replace must not be canceled and reissued as app loads")
        }
        XCTAssertTrue(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
            navigationType: .linkActivated, targetsMainFrame: nil, method: "GET", nativeRequest: false))
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
            navigationType: .other, targetsMainFrame: true, method: "GET", nativeRequest: true),
            "The app's replacement request must load once without a cancellation loop")
    }

    func testBrowserLinkRoutingPreservesFramesFormsHistoryAndFragments() {
        let source = URL(string: "https://example.com/article")!
        let destination = URL(string: "https://other.test/page")!
        for type in [WKNavigationType.backForward, .reload] {
            XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
                navigationType: type, targetsMainFrame: true, method: "GET", nativeRequest: false))
        }
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
            navigationType: .linkActivated, targetsMainFrame: false, method: "GET", nativeRequest: false))
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
            navigationType: .formSubmitted, targetsMainFrame: nil, method: "POST", nativeRequest: false))
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination, sourceURL: source,
            navigationType: .formSubmitted, targetsMainFrame: nil, method: "GET", nativeRequest: false))
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: URL(string: "https://example.com/article#part")!, sourceURL: source,
            navigationType: .linkActivated, targetsMainFrame: true, method: "GET", nativeRequest: false))
    }

    func testBaiduSDKAppHandoffResolvesToItsAppScheme() throws {
        let appURL = try XCTUnwrap(URL(string: "baiduboxapp://video/invokeVideoDetail?params=%7B%22name%22%3A%22a%2Bb%22%7D"))
        var wrapper = try XCTUnwrap(URLComponents(string: "https://boxer.baidu.com/scheme"))
        wrapper.queryItems = [URLQueryItem(name: "scheme", value: appURL.absoluteString),
                              URLQueryItem(name: "target", value: "https://apps.apple.com/app/id123")]
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: try XCTUnwrap(wrapper.url)), .external(appURL))
    }

    func testBaiduHandoffDoesNotMatchOtherHostsPathsOrEmbeddedWebLinks() throws {
        for address in [
            "https://boxer.baidu.com.evil.test/scheme?scheme=baiduboxapp%3A%2F%2Fvideo",
            "https://boxer.baidu.com/other?scheme=baiduboxapp%3A%2F%2Fvideo",
            "https://boxer.baidu.com/scheme?scheme=https%3A%2F%2Fevil.test",
            "https://boxer.baidu.com/scheme?scheme=javascript%3Aalert(1)",
            "https://boxer.baidu.com/scheme?scheme=baiduboxapp%3A%2F%2Fvideo&scheme=otherapp%3A%2F%2Fopen"
        ] {
            XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: try XCTUnwrap(URL(string: address))), .allow)
        }
    }

    @MainActor
    func testExtensionInstallBannerUsesBundledSouloLogo() throws {
        let dataURL = WebExtensionInstallBrandAssets.logoDataURL
        let prefix = "data:image/png;base64,"

        XCTAssertTrue(dataURL.hasPrefix(prefix))
        let encoded = String(dataURL.dropFirst(prefix.count))
        XCTAssertGreaterThan(try XCTUnwrap(Data(base64Encoded: encoded)).count, 1_000)
    }

    func testChromeStoreLinkResolvesToNativeCRXDownload() throws {
        let package = try WebExtensionStoreLinkResolver.resolve(
            "https://chromewebstore.google.com/detail/example/cjpalhdlnbpafiamejdnhcphjbkeiagm"
        )

        XCTAssertEqual(package.store, .chrome)
        XCTAssertEqual(package.fileExtension, "crx")
        XCTAssertEqual(package.downloadURL.host, "clients2.google.com")
        XCTAssertTrue(package.downloadURL.absoluteString.contains("cjpalhdlnbpafiamejdnhcphjbkeiagm"))
    }

    func testEdgeAndFirefoxStoreLinksResolveWithoutUsingStoreGetButton() throws {
        let edge = try WebExtensionStoreLinkResolver.resolve(
            "https://microsoftedge.microsoft.com/addons/detail/example/odfafepnkmbhccpbejgmiehpchacaeak"
        )
        let firefox = try WebExtensionStoreLinkResolver.resolve(
            "https://addons.mozilla.org/en-US/firefox/addon/ublock-origin/"
        )

        XCTAssertEqual(edge.store, .edge)
        XCTAssertEqual(edge.downloadURL.host, "edge.microsoft.com")
        XCTAssertEqual(firefox.store, .firefox)
        XCTAssertEqual(firefox.downloadURL.path, "/firefox/downloads/latest/ublock-origin/latest.xpi")
    }

    func testExtensionStoreResolverRejectsCategoryAndInsecureLinks() {
        XCTAssertThrowsError(try WebExtensionStoreLinkResolver.resolve(
            "https://chromewebstore.google.com/category/extensions"
        ))
        XCTAssertThrowsError(try WebExtensionStoreLinkResolver.resolve(
            "http://example.com/extension.zip"
        ))
    }

    func testExtensionRedirectPolicyOnlyAllowsMicrosoftEdgeDownloadCDNOverHTTP() {
        let microsoftCDN = URL(string: "http://msedgeextensions.f.tlu.dl.delivery.mp.microsoft.com/file.crx")!
        let unrelatedHTTP = URL(string: "http://example.com/file.crx")!
        let secureDownload = URL(string: "https://example.com/file.crx")!

        XCTAssertTrue(WebExtensionStoreRedirectPolicy.allows(microsoftCDN, store: .edge))
        XCTAssertFalse(WebExtensionStoreRedirectPolicy.allows(microsoftCDN, store: .chrome))
        XCTAssertFalse(WebExtensionStoreRedirectPolicy.allows(unrelatedHTTP, store: .edge))
        XCTAssertTrue(WebExtensionStoreRedirectPolicy.allows(secureDownload, store: .direct))
    }

    func testExtensionStorePageBridgeInjectsOneTapInstallBar() {
        let script = WebViewScripts.extensionInstallBridge(
            title: "Install with Soulo",
            message: "Install directly.",
            installButton: "Install",
            installingButton: "Installing…",
            logoDataURL: "data:image/png;base64,AA=="
        )

        XCTAssertTrue(script.contains("__soulo-extension-install-host"))
        XCTAssertTrue(script.contains("chromewebstore.google.com"))
        XCTAssertTrue(script.contains("microsoftedge.microsoft.com"))
        XCTAssertTrue(script.contains("addons.mozilla.org"))
        XCTAssertTrue(script.contains("handler.postMessage({ pageURL:"))
        XCTAssertTrue(script.contains("MutationObserver(scheduleSync)"))
        XCTAssertTrue(script.contains("data:image/png;base64,AA=="))
        XCTAssertTrue(script.contains("document.createElement('img')"))
        XCTAssertFalse(script.contains("icon.textContent = 'S'"))
        XCTAssertFalse(script.contains("clients2.google.com/service/update2/crx"))
    }

    func testAllowsNormalWebURL() {
        let url = URL(string: "https://example.com")!
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: url), .allow)
    }

    func testAllowsWebKitExtensionPagesInsideTheBrowser() {
        let url = URL(string: "webkit-extension://fixture/captured.html")!
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: url), .allow)
    }

    func testTreatsCustomSchemeAsExternal() {
        let url = URL(string: "weixin://scan")!
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: url), .external(url))
    }

    func testExternalDestinationUsesAppNameInsteadOfInternalRouteHost() {
        let url = URL(string: "baiduboxapp://v1/easybrowse")!

        XCTAssertEqual(
            WebNavigationPolicyService.shared.externalDestinationName(for: url),
            "百度 App"
        )
    }

    func testTreatsKnownUniversalLinkAsExternal() {
        let url = URL(string: "https://apps.apple.com/app/id123")!
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: url), .external(url))
    }

    func testRecognizesOnlyRealAppleAppStoreHostsForDirectOpening() {
        XCTAssertTrue(WebNavigationPolicyService.shared.isAppleAppStoreURL(
            URL(string: "https://apps.apple.com/cn/app/id1032287195")!
        ))
        XCTAssertTrue(WebNavigationPolicyService.shared.isAppleAppStoreURL(
            URL(string: "https://itunes.apple.com/app/id1032287195")!
        ))
        XCTAssertFalse(WebNavigationPolicyService.shared.isAppleAppStoreURL(
            URL(string: "https://apps.apple.com.example.com/app/id1032287195")!
        ))
    }

    func testRecognizesAppleAppStoreCustomScheme() {
        XCTAssertTrue(WebNavigationPolicyService.shared.isAppleAppStoreURL(
            URL(string: "itms-apps://itunes.apple.com/app/id1032287195")!
        ))
        XCTAssertFalse(WebNavigationPolicyService.shared.isAppleAppStoreURL(
            URL(string: "itms-apps://itunes.apple.com.example.com/app/id1032287195")!
        ))
    }

    func testSafariCompatibilityModeOnlyAcceptsHostedWebPages() {
        let service = WebNavigationPolicyService.shared

        XCTAssertTrue(service.canUseSafariCompatibilityMode(for: URL(string: "https://example.com/path")))
        XCTAssertTrue(service.canUseSafariCompatibilityMode(for: URL(string: "http://localhost:8080")))
        XCTAssertFalse(service.canUseSafariCompatibilityMode(for: URL(string: "itms-apps://apps.apple.com/app/id123")))
        XCTAssertFalse(service.canUseSafariCompatibilityMode(for: URL(string: "soulo://search?q=test")))
        XCTAssertFalse(service.canUseSafariCompatibilityMode(for: URL(string: "about:blank")))
        XCTAssertFalse(service.canUseSafariCompatibilityMode(for: nil))
    }

    func testOnlyAuthenticationWindowsPreservePopupContext() {
        let webURL = URL(string: "https://accounts.example.com/oauth")!
        XCTAssertTrue(BrowserPopupPolicy.shouldPreserveJavaScriptContext(
            navigationType: .other,
            url: webURL
        ))
        XCTAssertTrue(BrowserPopupPolicy.shouldPreserveJavaScriptContext(
            navigationType: .linkActivated,
            url: URL(string: "about:blank")!
        ))
        XCTAssertFalse(BrowserPopupPolicy.shouldPreserveJavaScriptContext(
            navigationType: .linkActivated,
            url: URL(string: "https://example.com/article")!
        ))
        XCTAssertFalse(BrowserPopupPolicy.shouldPreserveJavaScriptContext(
            navigationType: .other,
            url: URL(string: "https://example.com/script-created-page")!
        ))
        XCTAssertTrue(BrowserPopupPolicy.shouldPreserveJavaScriptContext(
            navigationType: .linkActivated,
            url: URL(string: "https://accounts.google.com/o/oauth2/auth")!
        ))
    }

    func testExpectedWebKitPolicyInterruptionIsNotPresentedAsPageFailure() {
        let interruption = NSError(
            domain: "WebKitErrorDomain",
            code: 102,
            userInfo: [NSLocalizedDescriptionKey: "Frame load interrupted"]
        )

        XCTAssertTrue(WebNavigationErrorClassifier.isExpectedInterruption(interruption))
        XCTAssertTrue(WebNavigationErrorClassifier.isExpectedInterruption(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
        XCTAssertFalse(WebNavigationErrorClassifier.isExpectedInterruption(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        ))
    }

    func testPageRequestedDownloadUsesNativeDownload() {
        XCTAssertTrue(BrowserDownloadPolicy.shouldDownload(requestedByPage: true))
        XCTAssertTrue(BrowserDownloadPolicy.shouldDownloadNavigationAction(
            requestedByPage: true,
            nativeRequest: false
        ))
        XCTAssertFalse(BrowserDownloadPolicy.shouldDownloadNavigationAction(
            requestedByPage: true,
            nativeRequest: true
        ))
    }

    func testAttachmentResponseDownloadsEvenWhenMIMETypeCanBeDisplayed() {
        XCTAssertTrue(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: true,
            mimeType: "image/png",
            contentDisposition: "attachment; filename=chart.png"
        ))
    }

    func testResponseWithUnsupportedMIMETypeDownloads() {
        XCTAssertTrue(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: false,
            mimeType: "application/x-custom-binary"
        ))
    }

    func testNormalHTMLResponseRemainsNavigable() {
        XCTAssertFalse(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: true,
            mimeType: "text/html",
            contentDisposition: "inline"
        ))
        XCTAssertFalse(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: false,
            mimeType: "text/html; charset=utf-8"
        ))
        XCTAssertFalse(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: false,
            mimeType: "text/html",
            responseURL: URL(string: "https://example.com/extension.xpi")
        ))
        XCTAssertTrue(BrowserDownloadPolicy.shouldDownload(
            canShowMIMEType: true,
            mimeType: "text/javascript",
            responseURL: URL(string: "https://example.com/helper.user.js")
        ))
    }

    func testUserScriptAndNativeWebExtensionInstallURLsAreRecognized() {
        XCTAssertTrue(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/tools/helper.user.js")!
        ))
        XCTAssertEqual(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/extension.xpi")!
        ), BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled)
        XCTAssertEqual(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://clients2.google.com/service/update2/crx?response=redirect")!
        ), BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled)
        XCTAssertFalse(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/app.js")!
        ))
    }
}
