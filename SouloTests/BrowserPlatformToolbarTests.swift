import XCTest
@testable import Soulo

@MainActor
final class BrowserPlatformToolbarTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "PlatformToolbar." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testVisibilityDefaultsPreserveExistingAutoHidePreference() throws {
        let d = try defaults()
        XCTAssertTrue(PlatformBarPreferences.isVisible(in: d))
        XCTAssertNil(d.object(forKey: PlatformBarPreferences.visibilityKey))
        d.set(true, forKey: "auto_hide_platform_bar")
        XCTAssertTrue(PlatformBarPreferences.autoHides(in: d))
        d.set(false, forKey: PlatformBarPreferences.visibilityKey)
        XCTAssertFalse(PlatformBarPreferences.autoHides(in: d))
        XCTAssertTrue(d.bool(forKey: "auto_hide_platform_bar"))
        d.set(true, forKey: PlatformBarPreferences.visibilityKey)
        XCTAssertTrue(PlatformBarPreferences.autoHides(in: d))
    }

    func testMoreAndToolbarEditsAndResetsAreIndependent() throws {
        let d = try defaults(), service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(service.moreActions, BrowserToolbarConfigurationService.defaultMoreActions)
        XCTAssertNil(d.object(forKey: BrowserToolbarConfigurationService.moreActionsKey))
        service.save(actions: [.platforms, .newTab, .tabs, .more], addressAction: .reload,
                     moreActions: [.platforms, .none, .downloads])
        let more = service.moreActions
        service.reset()
        XCTAssertEqual(service.moreActions, more)
        service.save(actions: [.platforms, .back, .tabs, .more], addressAction: .platforms)
        service.resetMoreActions()
        XCTAssertEqual(service.actions, [.platforms, .back, .tabs, .more])
        XCTAssertEqual(service.addressAction, .platforms)
        XCTAssertFalse(BrowserToolbarAction.platforms.requiresPage)
        let restored = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(restored.actions, service.actions)
        XCTAssertEqual(restored.moreActions, BrowserToolbarConfigurationService.defaultMoreActions)
    }

    func testCorruptAndHiddenMoreSlotsHaveSafeStableFallbacks() throws {
        let d = try defaults()
        d.set(["more", "future-action", "books"], forKey: BrowserToolbarConfigurationService.moreActionsKey)
        let service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(Array(service.moreActions.prefix(3)), [.none, .reload, .files])
        XCTAssertEqual(service.moreActions.count, 12)
        service.saveMoreActions(Array(repeating: .none, count: 20))
        service.reloadFromDefaults()
        XCTAssertEqual(service.moreActions, Array(repeating: .none, count: 12))
    }

    func testLeadingActionMigrationPersistenceAndIndependentReset() throws {
        let d = try defaults(), service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(service.leadingAction, .siteInformation)
        XCTAssertNil(d.object(forKey: BrowserToolbarConfigurationService.leadingActionKey))
        service.save(actions: service.actions, addressAction: .reload, moreActions: [.siteInformation], leadingAction: .platforms)
        XCTAssertEqual(BrowserToolbarConfigurationService(defaults: d).leadingAction, .platforms)
        service.resetMoreActions()
        XCTAssertEqual(service.leadingAction, .platforms)
        service.save(actions: service.actions, addressAction: .reload)
        XCTAssertEqual(service.leadingAction, .platforms, "Older save callers must preserve the chosen leading action")
        service.reset()
        XCTAssertEqual(service.leadingAction, .siteInformation)
        d.set("future-action", forKey: BrowserToolbarConfigurationService.leadingActionKey)
        service.reloadFromDefaults()
        XCTAssertEqual(service.leadingAction, .siteInformation)
        XCTAssertEqual(BrowserToolbarConfigurationService.normalizedLeadingAction(.more), .siteInformation)
        XCTAssertEqual(BrowserToolbarConfigurationService.normalizedLeadingAction(BrowserToolbarAction.none), .none)
    }

    func testNewPreferencesAreIncludedInSyncAndBackups() throws {
        let d = try defaults()
        d.set(false, forKey: PlatformBarPreferences.visibilityKey)
        d.set(["platforms", "none"], forKey: BrowserToolbarConfigurationService.moreActionsKey)
        d.set("platforms", forKey: BrowserToolbarConfigurationService.leadingActionKey)
        let snapshot = CloudSettingsSyncEngine.snapshot(d)
        XCTAssertEqual(snapshot[BrowserToolbarConfigurationService.leadingActionKey] as? String, "platforms")
        XCTAssertEqual(snapshot[PlatformBarPreferences.visibilityKey] as? Bool, false)
        XCTAssertEqual(snapshot[BrowserToolbarConfigurationService.moreActionsKey] as? [String], ["platforms", "none"])
    }
}
