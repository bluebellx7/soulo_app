import XCTest
@testable import Soulo

@MainActor
final class ExternalNavigationServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ExternalNavigationServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRememberBlockSuppressesFuturePromptsForHost() {
        let service = ExternalNavigationService(
            blockedHostsKey: "hosts",
            suppressPromptsKey: "suppress",
            userDefaults: defaults
        )
        let url = URL(string: "https://apps.apple.com/app/id123")!

        XCTAssertFalse(service.shouldSilentlyBlock(url))
        service.rememberBlock(for: url)

        XCTAssertTrue(service.shouldSilentlyBlock(url))
        XCTAssertTrue(service.blockedHosts.contains("apps.apple.com"))
    }

    func testRemoveHostRestoresPromptForThatHost() {
        let service = ExternalNavigationService(
            blockedHostsKey: "hosts",
            suppressPromptsKey: "suppress",
            userDefaults: defaults
        )
        let url = URL(string: "https://apps.apple.com/app/id123")!
        service.rememberBlock(for: url)
        service.removeHost("apps.apple.com")

        XCTAssertFalse(service.shouldSilentlyBlock(url))
    }

    func testAppPromptsDefaultToEnabledRegardlessOfLegacyBlockingPreference() {
        defaults.set(true, forKey: "suppress")
        let service = ExternalNavigationService(suppressPromptsKey: "suppress", userDefaults: defaults)
        XCTAssertTrue(service.promptEnabled)
    }

    func testAppPromptPreferencePersistsAcrossServiceInstances() {
        let service = ExternalNavigationService(userDefaults: defaults)
        service.promptEnabled = false
        XCTAssertFalse(ExternalNavigationService(userDefaults: defaults).promptEnabled)
        service.promptEnabled = true
        XCTAssertTrue(ExternalNavigationService(userDefaults: defaults).promptEnabled)
    }

    func testFoundationBooleanStringsAreRespected() {
        defaults.set("NO", forKey: ExternalNavigationService.promptEnabledKey)
        let service = ExternalNavigationService(userDefaults: defaults)
        XCTAssertFalse(service.promptEnabled)
        defaults.set("YES", forKey: ExternalNavigationService.promptEnabledKey)
        service.reloadFromDefaults()
        XCTAssertTrue(service.promptEnabled)
    }

    func testReloadAppliesSyncedPromptPreferenceAndMissingValueDefaultsToEnabled() {
        let service = ExternalNavigationService(userDefaults: defaults)
        defaults.set(false, forKey: ExternalNavigationService.promptEnabledKey)
        service.reloadFromDefaults()
        XCTAssertFalse(service.promptEnabled)
        defaults.removeObject(forKey: ExternalNavigationService.promptEnabledKey)
        service.reloadFromDefaults()
        XCTAssertTrue(service.promptEnabled)
    }
}
