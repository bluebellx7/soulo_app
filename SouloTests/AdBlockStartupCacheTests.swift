import WebKit
import XCTest
@testable import Soulo

final class AdBlockStartupCacheTests: XCTestCase {
    func testAutomaticUpdateFastPathRequiresValidatedCurrentNonemptyArchive() throws {
        let suite = "AutomaticUpdateState-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("validated rules".utf8).write(to: archive)
        let now = Date(timeIntervalSince1970: 1_000_000)
        defaults.set(now.timeIntervalSince1970 - 100, forKey: "soulo_ad_block_subscription_auto_update_check")
        defaults.set(1, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        XCTAssertTrue(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now.addingTimeInterval(86400)))
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now.addingTimeInterval(-200)))
        defaults.set(2, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        defaults.set(1, forKey: "soulo_ad_block_subscription_rules_version")
        try Data("replaced archive with different content".utf8).write(to: archive, options: .atomic)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: false)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        let state = try XCTUnwrap(AdBlockAutomaticUpdateState.snapshot(archive: archive, defaults: defaults, hasRules: true))
        let staleParser = AdBlockAutomaticUpdateState(parserVersion: state.parserVersion - 1,
            revision: state.revision, modifiedAt: state.modifiedAt, size: state.size, hasRules: true)
        defaults.set(try JSONEncoder().encode(staleParser), forKey: AdBlockAutomaticUpdateState.storageKey)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        defaults.set(Data("{}".utf8), forKey: "soulo_ad_block_subscription_rules")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules")
        try FileManager.default.removeItem(at: archive)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
    }

    func testDiskEntriesRequireExactInputsAndSurviveNewCacheInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AdBlockStartupCache(directory: directory)
        cache.write("document.querySelector('.ad')", slot: .cosmeticScript, key: "revision-a")
        cache.write(["native-a", "native-b"], slot: .contentRuleIdentifiers, key: "revision-a")
        let reopened = AdBlockStartupCache(directory: directory)
        XCTAssertEqual(reopened.read(String.self, slot: .cosmeticScript, key: "revision-a"), "document.querySelector('.ad')")
        XCTAssertEqual(reopened.read([String].self, slot: .contentRuleIdentifiers, key: "revision-a"), ["native-a", "native-b"])
        XCTAssertNil(reopened.read(String.self, slot: .cosmeticScript, key: "revision-b"))
        cache.write("updated", slot: .cosmeticScript, key: "revision-b")
        XCTAssertNil(reopened.read(String.self, slot: .cosmeticScript, key: "revision-a"))
        XCTAssertEqual(reopened.read(String.self, slot: .cosmeticScript, key: "revision-b"), "updated")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testMissingCorruptAndWrongTypedEntriesAreCacheMisses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AdBlockStartupCache(directory: directory)
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        cache.write(["not a script"], slot: .cosmeticScript, key: "key")
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        try Data("{truncated".utf8).write(to: directory.appendingPathComponent("cosmeticScript.json"))
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        cache.write("recovered", slot: .cosmeticScript, key: "key")
        XCTAssertEqual(cache.read(String.self, slot: .cosmeticScript, key: "key"), "recovered")
        AdBlockStartupCache(directory: nil).write("ignored", slot: .cosmeticScript, key: "key")
    }

    func testCacheIdentityTracksAllowlistRulesAndDirectOverrides() throws {
        let defaults = UserDefaults.standard
        let keys = ["soulo_ad_block_subscription_rules", "soulo_ad_block_subscription_rules_version",
                    BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let original = try XCTUnwrap(AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        XCTAssertEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com", "example.com"], cosmetic: true))
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: [], cosmetic: true))
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: false))
        defaults.set(42, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules_version")
        // Include override bytes too: tests and migrations can change them
        // without bumping the UI store's revision.
        defaults.set(Data("{}".utf8), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: "soulo_ad_block_subscription_rules")
        XCTAssertNil(AdBlockService.startupCacheKey(allowlistedHosts: [], cosmetic: true))
        XCTAssertNil(AdBlockService.startupCacheKey(allowlistedHosts: []))
    }

    @MainActor
    func testMissingNativeCompiledArtifactRegeneratesCompleteRuleList() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "soulo_ad_block_subscription_rules")
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules")
        defer { defaults.set(saved, forKey: "soulo_ad_block_subscription_rules") }
        let cache = AdBlockStartupCache.shared
        let file = try XCTUnwrap(cache.directory?.appendingPathComponent("contentRuleIdentifiers.json"))
        let previousData = try? Data(contentsOf: file)
        defer {
            if let previousData { try? previousData.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
        }
        let allowlist = ["startup-cache-fixture.example"]
        let key = try XCTUnwrap(AdBlockService.startupCacheKey(allowlistedHosts: allowlist))
        let missingIdentifier = "SouloMissingFixture-" + UUID().uuidString
        cache.write([missingIdentifier], slot: .contentRuleIdentifiers, key: key)
        let generated = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
        let rules = try XCTUnwrap(generated)
        XCTAssertFalse(rules.isEmpty)
        XCTAssertFalse(rules.contains { $0.identifier == missingIdentifier })
        XCTAssertEqual(cache.read([String].self, slot: .contentRuleIdentifiers, key: key), rules.map(\.identifier))
        let reloaded = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
        XCTAssertEqual(reloaded?.map(\.identifier), rules.map(\.identifier))
    }
}
