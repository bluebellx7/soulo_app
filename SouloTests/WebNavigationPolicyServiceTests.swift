import XCTest
@testable import Soulo

final class WebNavigationPolicyServiceTests: XCTestCase {
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
    }

    func testUserScriptAndNativeWebExtensionInstallURLsAreRecognized() {
        XCTAssertTrue(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/tools/helper.user.js")!
        ))
        XCTAssertTrue(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/extension.xpi")!
        ))
        XCTAssertTrue(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://clients2.google.com/service/update2/crx?response=redirect")!
        ))
        XCTAssertFalse(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/app.js")!
        ))
    }
}
