import XCTest
@testable import Soulo

final class WebCompatibilityServiceTests: XCTestCase {
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
}
