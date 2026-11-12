import XCTest
@testable import Soulo

final class BrowserAdNavigationTests: XCTestCase {
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
