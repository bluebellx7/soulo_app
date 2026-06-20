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

    func testTreatsKnownUniversalLinkAsExternal() {
        let url = URL(string: "https://apps.apple.com/app/id123")!
        XCTAssertEqual(WebNavigationPolicyService.shared.decision(for: url), .external(url))
    }
}
