import XCTest
@testable import Soulo

@MainActor
final class ElementBlockServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ElementBlockServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRulesMatchExactAndSubdomainHosts() {
        let service = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "#ad", label: "Ad")

        XCTAssertEqual(service.rules(for: "example.com").count, 1)
        XCTAssertEqual(service.rules(for: "news.example.com").count, 1)
        XCTAssertEqual(service.rules(for: "other.com").count, 0)
    }

    func testAddRuleDeduplicatesSelectorPerHost() {
        let service = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        service.addRule(host: "www.example.com", selector: "#ad", label: "Ad")
        service.addRule(host: "example.com", selector: "#ad", label: "Ad")

        XCTAssertEqual(service.rules.count, 1)
    }

    func testPersistenceRoundTripKeepsMetadata() {
        let first = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        first.addRule(
            host: "example.com",
            selector: "div[data-testid=\"ad\"]",
            xpath: "/html/body/div[2]",
            label: "Sponsored",
            pageTitle: "Example",
            pageURL: "https://example.com/page"
        )

        let second = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        XCTAssertEqual(second.rules.count, 1)
        XCTAssertEqual(second.rules.first?.selectorKind, "attribute")
        XCTAssertEqual(second.rules.first?.pageTitle, "Example")
        XCTAssertEqual(second.rules.first?.pageURL, "https://example.com/page")
        XCTAssertEqual(second.rules.first?.xpath, "/html/body/div[2]")
    }

    func testAddRuleAllowsXPathOnlyRules() {
        let service = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "", xpath: "/html/body/div[1]", label: "Hero")

        XCTAssertEqual(service.rules.count, 1)
        XCTAssertEqual(service.rules.first?.selectorKind, "xpath")
        XCTAssertTrue(service.makeApplyScript(for: "example.com").contains("document.evaluate"))
        XCTAssertTrue(service.makeApplyScript(for: "example.com").contains("body"))
    }

    func testDisabledHostKeepsRulesButStopsApplyingThem() {
        let service = ElementBlockService(storageKey: "rules", disabledHostsKey: "disabled", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "#ad,.promo", label: "Ad")

        XCTAssertEqual(service.rules(for: "example.com").count, 1)
        XCTAssertEqual(service.rules.first?.selectorCandidates, ["#ad", ".promo"])

        service.setDisabled(true, for: "example.com")
        XCTAssertTrue(service.isDisabled(for: "news.example.com"))
        XCTAssertEqual(service.rules.count, 1)
        XCTAssertEqual(service.rules(for: "news.example.com").count, 0)
        XCTAssertEqual(service.storedRules(for: "news.example.com").count, 1)

        service.setDisabled(false, for: "example.com")
        XCTAssertEqual(service.rules(for: "news.example.com").count, 1)
    }

    func testCSSForHostEmitsSeparateRulesSoOneSelectorCannotBreakAllHiding() {
        let service = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "#ad,.promo", label: "Ad")

        let css = service.cssForHost("example.com")

        XCTAssertTrue(css.contains("#ad{"))
        XCTAssertTrue(css.contains(".promo{"))
        XCTAssertFalse(css.contains("#ad,\n.promo{"))
        XCTAssertTrue(css.contains("max-height:0!important"))
        XCTAssertTrue(css.contains("content-visibility:hidden!important"))
    }

    func testApplyScriptFiltersInvalidSelectorsAndUsesSeparateCSSRules() {
        let service = ElementBlockService(storageKey: "rules", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "#ad,.promo", xpath: "/html/body/div[2]", label: "Ad")

        let script = service.makeApplyScript(for: "example.com")

        XCTAssertTrue(script.contains("isUsableSelector"))
        XCTAssertTrue(script.contains("document.querySelector(selector)"))
        XCTAssertTrue(script.contains("selectors.map(function(selector)"))
        XCTAssertTrue(script.contains("document.evaluate"))
        XCTAssertTrue(script.contains("clip-path"))
        XCTAssertTrue(script.contains("content-visibility"))
    }

    func testBulkRestoreClearsRulesAndPausedHosts() {
        let service = ElementBlockService(storageKey: "rules", disabledHostsKey: "disabled", userDefaults: defaults)
        service.addRule(host: "example.com", selector: "#ad", label: "Ad")
        service.addRule(host: "other.com", selector: ".promo", label: "Promo")
        service.setDisabled(true, for: "example.com")

        XCTAssertEqual(service.rules.count, 2)
        XCTAssertEqual(service.disabledHosts, ["example.com"])

        service.removeAllRules()
        service.enableAllHosts()

        XCTAssertTrue(service.rules.isEmpty)
        XCTAssertTrue(service.disabledHosts.isEmpty)
    }
}
