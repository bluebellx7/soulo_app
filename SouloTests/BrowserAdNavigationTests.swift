import XCTest
import WebKit
@testable import Soulo

final class BrowserAdNavigationTests: XCTestCase {
    private let page = URL(string: "https://www.pbpbw.com/player/1-1-1.html")!
    private let ad = URL(string: "https://ad.example/landing")!

    func testBackgroundTapCannotAuthorizePopupOrCrossSiteReplacement() {
        for newWindow in [true, false] {
            XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .other,
                isNewWindow: newWindow, sourceIsMainFrame: true, hasRecentGesture: true,
                gestureDestination: nil, gestureIsControl: false))
        }
        XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .other,
            isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: false,
            gestureDestination: nil, gestureIsControl: false))
    }

    func testClickedLinkAuthorizesOnlyItsDestination() {
        for newWindow in [true, false] {
            XCTAssertFalse(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .linkActivated,
                isNewWindow: newWindow, sourceIsMainFrame: true, hasRecentGesture: true,
                gestureDestination: ad, gestureIsControl: false))
            XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .linkActivated,
                isNewWindow: newWindow, sourceIsMainFrame: true, hasRecentGesture: true,
                gestureDestination: URL(string: "https://www.pbpbw.com/html/2.html"), gestureIsControl: false))
        }
    }

    func testSameSitePlaybackAndExplicitAuthenticationStillWork() {
        XCTAssertFalse(BrowserAdNavigationPolicy.shouldBlock(url: page, sourceURL: page, navigationType: .other,
            isNewWindow: false, sourceIsMainFrame: true, hasRecentGesture: true,
            gestureDestination: nil, gestureIsControl: true))
        for destination in ["https://accounts.google.com/o/oauth2/auth", "about:blank"] {
            XCTAssertFalse(BrowserAdNavigationPolicy.shouldBlock(url: URL(string: destination)!, sourceURL: page, navigationType: .other,
                isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: true,
                gestureDestination: nil, gestureIsControl: true))
        }
        XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .other,
            isNewWindow: false, sourceIsMainFrame: false, hasRecentGesture: false,
            gestureDestination: nil, gestureIsControl: false))
    }

    func testWebKitLinkAndDelegatedResultCardRequestsRemainUsable() {
        for type in [WKNavigationType.linkActivated, .other] {
            XCTAssertFalse(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: type,
                isNewWindow: false, sourceIsMainFrame: true, hasRecentGesture: true,
                gestureDestination: nil, gestureIsControl: false, gestureIsLink: true))
            XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: type,
                isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: false,
                gestureDestination: nil, gestureIsControl: false, gestureIsLink: true))
        }
        XCTAssertFalse(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .formSubmitted,
            isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: true,
            gestureDestination: nil, gestureIsControl: true, gestureIsForm: true))
        XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: ad, sourceURL: page, navigationType: .other,
            isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: true,
            gestureDestination: page, gestureIsControl: false, gestureIsLink: true),
            "An unrelated script popup is not the link the user chose")
    }

    func testVerifiedLoaderRuleDoesNotMatchPlayerOrOtherSites() throws {
        let rule = try XCTUnwrap(AdBlockService.defaultBuiltInRules.first { $0.id == "pbpbw-click-ad-loader" })
        let expression = try NSRegularExpression(pattern: rule.pattern)
        func matches(_ address: String) -> Bool {
            expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
        }
        XCTAssertTrue(matches("https://www.pbpbw.com/assets/chunks/site-config.js?v=2"))
        XCTAssertFalse(matches("https://www.pbpbw.com/assets/chunks/site-render.js"))
        XCTAssertFalse(matches("https://www.pbpbw.com.evil.test/assets/chunks/site-config.js"))
        XCTAssertEqual(rule.resourceTypes, ["script"])
    }
}
