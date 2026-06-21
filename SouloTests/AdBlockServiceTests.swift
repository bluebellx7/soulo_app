import XCTest
import WebKit
@testable import Soulo

final class AdBlockServiceTests: XCTestCase {
    func testEncodedContentRulesAreValidAndContainBlockActions() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "block"
        })
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "css-display-none"
        })
    }

    func testNetworkBlockRulesDoNotTargetMainDocuments() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        let blockRules = rules.filter { rule in
            (rule["action"] as? [String: Any])?["type"] as? String == "block"
        }

        XCTAssertFalse(blockRules.isEmpty)
        for rule in blockRules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let resourceTypes = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(resourceTypes.contains("document"))
        }
    }

    func testEncodedContentRulesCompileWithWebKit() async throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let identifier = "SouloTests-\(UUID().uuidString)"

        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesSanitizeLegacyUnsupportedURLFilters() async throws {
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
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: #"/waWQiOjE.*=eyJ\.js([\\/:?&=]|$)"#,
                    resourceTypes: ["script"]
                )
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertFalse(json.contains(#"([\\/:?&=]|$)"#))
        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SouloLegacyFilterTest-\(UUID().uuidString)",
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesIncludeAllowlistDomains() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList(allowlistedHosts: ["www.example.com"]))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let firstTrigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let unlessDomain = try XCTUnwrap(firstTrigger["unless-domain"] as? [String])

        XCTAssertTrue(unlessDomain.contains("*example.com"))
        XCTAssertTrue(unlessDomain.contains("example.com"))
    }

    func testEncodedContentRulesPreserveStructuredSubscriptionConditions() throws {
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
            networkURLFilters: ["tracker\\.example"],
            cosmeticSelectors: [],
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: "tracker\\.example",
                    resourceTypes: ["script"],
                    loadTypes: ["third-party"],
                    ifDomains: ["*example.com"],
                    unlessDomains: ["*admin.example.com"]
                )
            ],
            cosmeticRules: [
                AdBlockCosmeticRule(selector: ".site-ad", ifDomains: ["*example.com"])
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]])

        XCTAssertTrue(rules.contains { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (trigger["url-filter"] as? String) == "tracker\\.example"
                && (trigger["resource-type"] as? [String]) == ["script"]
                && (trigger["load-type"] as? [String]) == ["third-party"]
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
                && ((trigger["unless-domain"] as? [String])?.contains("*admin.example.com") == true)
        })

        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any],
                  let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (action["type"] as? String) == "css-display-none"
                && (action["selector"] as? String) == ".site-ad"
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
        })
    }

    func testEncodedContentRulesCoverChineseVideoSiteAdPatterns() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertTrue(json.contains("cpcad"))
        XCTAssertTrue(json.contains("gudingwei"))
        XCTAssertTrue(json.contains("jioeidd"))
        XCTAssertTrue(json.contains("tuiguang"))
        XCTAssertTrue(json.contains("adpic"))
        XCTAssertTrue(json.contains("floatad"))
        XCTAssertTrue(json.contains("popupad"))
        XCTAssertTrue(json.contains("cqlkxq1wc"))
    }

    func testAdHidingScriptCoversLowerZIndexFloatingAdsAndImageAnchors() {
        let script = AdBlockService.adHidingScript(cosmetic: true, popups: true)

        XCTAssertTrue(script.contains("z < 999"))
        XCTAssertTrue(script.contains("div, section, aside, iframe, a, img"))
        XCTAssertTrue(script.contains("hideAdElement"))
        XCTAssertTrue(script.contains("isProtectedPageElement"))
        XCTAssertFalse(script.contains("el.remove()"))
        XCTAssertTrue(script.contains("adpic"))
        XCTAssertTrue(script.contains("adimg"))
        XCTAssertTrue(script.contains("floatad"))
    }

    func testAdHidingScriptChecksRuntimeAllowlist() {
        let script = AdBlockService.adHidingScript(
            cosmetic: true,
            popups: true,
            allowlistedHosts: ["example.com"]
        )

        XCTAssertTrue(script.contains("souloAllowlistedHosts"))
        XCTAssertTrue(script.contains("isSouloAllowlisted"))
        XCTAssertTrue(script.contains("example.com"))
    }
}
