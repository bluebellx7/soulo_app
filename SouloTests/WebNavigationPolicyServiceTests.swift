import XCTest
@testable import Soulo

final class WebNavigationPolicyServiceTests: XCTestCase {
    func testAllowsNormalWebURL() {
        let url = URL(string: "https://example.com")!
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

    func testOnlyUserScriptInstallURLsAreRecognizedWhileWebExtensionsAreHidden() {
        XCTAssertTrue(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/tools/helper.user.js")!
        ))
        XCTAssertFalse(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/extension.xpi")!
        ))
        XCTAssertFalse(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://clients2.google.com/service/update2/crx?response=redirect")!
        ))
        XCTAssertFalse(BrowserExtensionInstallCandidate.recognizedDownloadURL(
            URL(string: "https://example.com/app.js")!
        ))
    }
}
