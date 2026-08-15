import XCTest
@testable import Soulo

final class AdBlockSubscriptionServiceTests: XCTestCase {
    func testParserConvertsABPNetworkAndCosmeticRules() {
        let sample = """
        ! comment
        ||ads.example.com^
        /cpcad.js
        @@||allowed.example.com^
        ##.ad-banner
        example.com##.site-specific
        #@#.exception
        """

        let parsed = AdBlockRuleParser.parse(sample)

        XCTAssertTrue(parsed.networkURLFilters.contains("ads\\.example\\.com"))
        XCTAssertTrue(parsed.networkURLFilters.contains("/cpcad\\.js"))
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("allowed") })
        XCTAssertTrue(parsed.cosmeticSelectors.contains(".ad-banner"))
        XCTAssertFalse(parsed.cosmeticSelectors.contains(".site-specific"))
        XCTAssertTrue(parsed.cosmeticRules.contains {
            $0.selector == ".site-specific" && $0.ifDomains.contains("*example.com")
        })
        XCTAssertFalse(parsed.cosmeticSelectors.contains(".exception"))
    }

    func testParserPreservesResourceTypesLoadTypesAndDomainOptions() {
        let sample = """
        ||tracker.example^$script,image,third-party,domain=example.com|~admin.example.com
        """

        let parsed = AdBlockRuleParser.parse(sample)
        let rule = parsed.networkRules.first { $0.urlFilter == "tracker\\.example" }

        XCTAssertEqual(rule?.resourceTypes.sorted(), ["image", "script"])
        XCTAssertEqual(rule?.loadTypes, ["third-party"])
        XCTAssertTrue(rule?.ifDomains.contains("*example.com") == true)
        XCTAssertTrue(rule?.unlessDomains.contains("*admin.example.com") == true)
    }

    func testParserDoesNotEmitWebKitUnsupportedDisjunctions() {
        let sample = """
        /waWQiOjE*=eyJ.js^
        """

        let parsed = AdBlockRuleParser.parse(sample)

        XCTAssertFalse(parsed.networkURLFilters.isEmpty)
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("|") })
        XCTAssertFalse(parsed.networkURLFilters.contains { $0.contains("([\\\\/:?&=]|$)") })
    }

    func testAdBlockServiceMergesCachedSubscriptionRules() throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let oldData = defaults.data(forKey: key)
        defer {
            if let oldData {
                defaults.set(oldData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let cached = ParsedAdBlockRules(
            networkURLFilters: ["ads\\.subscription\\.test"],
            cosmeticSelectors: [".subscription-ad"]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertTrue(json.contains("ads\\\\.subscription\\\\.test"))
        XCTAssertTrue(json.contains(".subscription-ad"))
    }

    @MainActor
    func testSubscriptionCacheMergePreservesStructuredConstraints() throws {
        let suiteName = "AdBlockSubscriptionServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let subscriptionsKey = "subscriptions"
        let cacheKey = "rules"
        let subscriptions = [
            AdBlockSubscription(
                id: "test",
                name: "Test",
                urlString: "https://example.com/list.txt",
                isEnabled: true,
                lastUpdatedAt: nil,
                networkRuleCount: 1,
                cosmeticRuleCount: 1,
                errorMessage: ""
            )
        ]
        defaults.set(try JSONEncoder().encode(subscriptions), forKey: subscriptionsKey)
        let networkRule = AdBlockNetworkRule(
            urlFilter: "tracker\\.example",
            resourceTypes: ["script"],
            loadTypes: ["third-party"],
            ifDomains: ["*example.com"]
        )
        let cosmeticRule = AdBlockCosmeticRule(selector: ".sponsor", ifDomains: ["*example.com"])
        let stored = [
            "test": ParsedAdBlockRules(
                networkURLFilters: [networkRule.urlFilter],
                networkRules: [networkRule],
                cosmeticRules: [cosmeticRule]
            )
        ]
        defaults.set(try JSONEncoder().encode(stored), forKey: "\(cacheKey)_by_id")

        let service = AdBlockSubscriptionService(
            subscriptionsKey: subscriptionsKey,
            cachedRulesKey: cacheKey,
            versionKey: "version",
            autoUpdateCheckKey: "update",
            userDefaults: defaults
        )

        XCTAssertEqual(service.enabledRuleSummary.networkRules, [networkRule])
        XCTAssertEqual(service.enabledRuleSummary.cosmeticRules, [cosmeticRule])
    }
}
