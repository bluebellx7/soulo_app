import XCTest
@testable import Soulo

@MainActor
final class HomeToolbarConfigurationTests: XCTestCase {
    func testIndependentVisibilityRetainsOlderPreferencesAndSharesExistingKeys() throws {
        let name = "HomeToolbarVisibility." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["style": "capsule", "hidesTopShortcuts": true,
                      "visibility": ["toolbar": false, "wallpaper": false, "suggestions": false, "voice": false, "groups": true]],
                     forKey: HomeToolbarConfigurationService.layoutKey)
        defaults.set(true, forKey: HomePageElement.bookmarksKey)
        defaults.set(true, forKey: PlatformBarPreferences.homeQuickSearchKey)
        let service = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        var layout = service.layout
        XCTAssertEqual(layout.searchPlacement, .center)
        XCTAssertEqual(HomeToolbarLayout(["searchPlacement": "unknown"], showsButtonBackground: true).searchPlacement, .center)
        let legacy = HomeToolbarLayout(["searchPlacement": "lower", "placement": "belowSearch",
                                        "tabsPlacement": "bottom", "menuPlacement": "bottom"], showsButtonBackground: true)
        XCTAssertEqual(legacy.searchPlacement, .bottom)
        XCTAssertEqual(legacy.placement, .bottom)
        XCTAssertNil(legacy.propertyList["tabsPlacement"])
        XCTAssertNil(legacy.propertyList["menuPlacement"])
        XCTAssertEqual(HomeToolbarLayout(["searchPlacement": "upper"], showsButtonBackground: true).searchPlacement, .center)
        XCTAssertFalse(layout.shows(.tabs, in: [.tabs, .settings]))
        XCTAssertFalse(layout.shows(.menu, in: [.tabs, .settings]))
        XCTAssertTrue(layout.shows(.menu, in: [.tabs]))
        XCTAssertTrue(layout.shows(.search, in: []))
        XCTAssertEqual(layout.propertyList["visibility"] as? [String: Bool], [:])

        layout.setVisibility(true, for: .tabs)
        layout.setVisibility(false, for: .menu)
        layout.setVisibility(false, for: .title)
        service.save([.tabs, .settings], layout: layout,
                     sharedVisibility: [.bookmarks: false, .recentSearches: false])
        let reopened = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        XCTAssertEqual(reopened.layout, layout)
        XCTAssertTrue(reopened.layout.shows(.tabs, in: reopened.actions))
        XCTAssertFalse(reopened.layout.shows(.menu, in: []))
        XCTAssertFalse(reopened.layout.shows(.title, in: []))
        XCTAssertTrue(reopened.layout.shows(.subtitle, in: []))
        XCTAssertFalse(defaults.bool(forKey: HomePageElement.bookmarksKey))
        XCTAssertFalse(defaults.bool(forKey: HomePageElement.recentSearchesKey))
        XCTAssertTrue(defaults.bool(forKey: PlatformBarPreferences.homeQuickSearchKey))
    }

    func testCustomLayoutPersistsAndClampsUnderWindowResize() throws {
        let name = "HomeToolbarLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let service = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        var layout = service.layout
        layout.style = .capsule
        layout.placement = .free
        layout.searchPlacement = .bottom
        let strip = CGSize(width: 168, height: 60)
        layout.move(by: CGSize(width: -1000, height: -1000), in: CGSize(width: 360, height: 570), strip: strip)
        service.save([.settings, .files, .tabs], layout: layout)
        let reopened = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 8)
        XCTAssertEqual(reopened.layout, layout)
        XCTAssertEqual(reopened.layout.searchPlacement, .bottom)
        XCTAssertEqual(reopened.layout.center(in: CGSize(width: 230, height: 160), strip: strip), CGPoint(x: 84, y: 30))
        let decoded = try CloudSettingsSyncEngine.flattened(CloudSettingsSyncEngine.snapshot(defaults))
        XCTAssertNotNil(decoded["setting." + HomeToolbarConfigurationService.layoutKey])
    }

    func testHiddenByDefaultAndFiveSlotsPersistAcrossReload() {
        let name = "HomeToolbarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        XCTAssertFalse(service.isVisible)
        XCTAssertTrue(service.showsButtonBackground)
        XCTAssertEqual(service.actions, Array(repeating: .none, count: 5))
        service.save([.downloads, .files, .bookmarks, .history, .wallpaper], showsButtonBackground: true)
        let restored = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        XCTAssertTrue(restored.isVisible)
        XCTAssertTrue(restored.showsButtonBackground)
        XCTAssertEqual(restored.actions, [.downloads, .files, .bookmarks, .history, .wallpaper])
        defaults.set(false, forKey: HomeToolbarConfigurationService.backgroundKey)
        restored.reloadFromDefaults()
        XCTAssertFalse(restored.showsButtonBackground)
        XCTAssertFalse(HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5).showsButtonBackground)
        XCTAssertEqual(restored.actions, [.downloads, .files, .bookmarks, .history, .wallpaper])
        defaults.removeObject(forKey: HomeToolbarConfigurationService.backgroundKey)
        restored.reloadFromDefaults()
        XCTAssertTrue(restored.showsButtonBackground)
        restored.save([])
        XCTAssertFalse(HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5).isVisible)
    }

    func testFreeToolbarAvoidsSearchAndDragsFromItsVisiblePosition() throws {
        var layout = HomeToolbarLayout()
        layout.placement = .free
        let area = CGSize(width: 360, height: 500)
        let strip = CGSize(width: 168, height: 60)
        let bottomSearch = CGRect(x: 28, y: 440, width: 304, height: 46)
        XCTAssertEqual(layout.freeCenter(in: area, strip: strip, avoiding: []), CGPoint(x: 180, y: 470))
        XCTAssertEqual(layout.freeCenter(in: area, strip: strip, avoiding: [bottomSearch]), CGPoint(x: 180, y: 402))
        XCTAssertEqual(layout.freeCenter(in: area, strip: strip, avoiding: [bottomSearch], translation: CGSize(width: 0, height: 90)), CGPoint(x: 180, y: 402))
        XCTAssertEqual(layout.freeCenter(in: area, strip: strip, avoiding: [bottomSearch], dockAtBottom: true), CGPoint(x: 180, y: 402))
        layout.move(by: CGSize(width: 0, height: -24), in: area, strip: strip, avoiding: [bottomSearch])
        let saved = HomeToolbarLayout(layout.propertyList, showsButtonBackground: true)
        let center = try XCTUnwrap(saved.freeCenter(in: area, strip: strip, avoiding: [bottomSearch]))
        XCTAssertEqual(center.y, 378, accuracy: 0.001)

        let centeredSearch = CGRect(x: 28, y: 180, width: 304, height: 46)
        XCTAssertEqual(saved.freeCenter(in: area, strip: strip, avoiding: [centeredSearch]), center)
        XCTAssertNil(saved.freeCenter(in: CGSize(width: 188, height: 80), strip: strip,
            avoiding: [CGRect(x: 20, y: 20, width: 150, height: 46)]))

        layout.move(by: CGSize(width: 0, height: 200), in: area, strip: strip, avoiding: [centeredSearch], dockAtBottom: true)
        XCTAssertTrue(layout.freeToolbarAtBottom)
    }

    func testFreeToolbarKeepsDetailsClearAndReachesBottom() throws {
        var layout = HomeToolbarLayout()
        layout.style = .capsule
        layout.placement = .free
        layout.x = 0
        layout.y = 0.8
        let area = CGSize(width: 350, height: 480)
        let strip = HomeToolbarMetrics(width: area.width, count: 3, style: layout.style).size
        let details = CGRect(x: 16, y: 350, width: 306, height: 62)
        let obstacles = [details]
        let resting = try XCTUnwrap(layout.freeCenter(in: area, strip: strip, avoiding: obstacles))
        XCTAssertLessThanOrEqual(resting.y + strip.height / 2 + HomeToolbarLayout.searchClearance, details.minY)
        layout.move(by: CGSize(width: 0, height: 200), in: area, strip: strip, avoiding: obstacles, dockAtBottom: true)
        let docked = try XCTUnwrap(layout.freeCenter(in: area, strip: strip, avoiding: obstacles, dockAtBottom: true))
        XCTAssertTrue(layout.freeToolbarAtBottom)
        XCTAssertEqual(docked.y + strip.height / 2, area.height)
        let toolbarRect = CGRect(x: docked.x - strip.width / 2, y: docked.y - strip.height / 2,
            width: strip.width, height: strip.height)
        XCTAssertFalse(obstacles.contains { toolbarRect.intersects($0) })
    }
    func testUnknownSavedActionsLeaveTheirSlotsEmptyWithoutMovingOthers() {
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "future-action", "wallpaper", "files", "settings"], slotLimit: 5),
                       [.downloads, .none, .wallpaper, .files, .settings])
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["history"], slotLimit: 5), [.history, .none, .none, .none, .none])
    }
    func testRetiredHelpEntryLeavesOtherSavedSlotsAndSettingsIntact() {
        let name = "HomeToolbarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["help", "backups", "quickActions", "files", "settings"], forKey: HomeToolbarConfigurationService.storageKey)
        defaults.set(false, forKey: HomeToolbarConfigurationService.backgroundKey)
        let service = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        XCTAssertNil(HomeToolbarAction(rawValue: "help"))
        XCTAssertEqual(service.actions, [.none, .backups, .quickActions, .files, .settings])
        XCTAssertFalse(service.showsButtonBackground)
        service.save(service.actions)
        XCTAssertEqual(defaults.stringArray(forKey: HomeToolbarConfigurationService.storageKey),
                       ["none", "backups", "quickActions", "files", "settings"])
    }
    func testFourSlotUpgradeKeepsExistingChoicesAndRejectsASixthSlot() {
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "files", "bookmarks", "history"], slotLimit: 5),
                       [.downloads, .files, .bookmarks, .history, .none])
        XCTAssertEqual(HomeToolbarConfigurationService.resolve(["downloads", "files", "bookmarks", "history", "wallpaper", "settings"], slotLimit: 5),
                       [.downloads, .files, .bookmarks, .history, .wallpaper])
    }
    func testIPadSupportsEightSlotsAndPhoneEditsKeepTheLastThree() {
        let name = "HomeToolbarPad." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let pad = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 8)
        let choices: [HomeToolbarAction] = [.settings, .files, .downloads, .tabs, .bookmarks, .extensions, .history, .newTab]
        pad.save(choices)
        XCTAssertEqual(HomeToolbarConfigurationService(defaults: defaults, slotLimit: 8).actions, choices)
        let phone = HomeToolbarConfigurationService(defaults: defaults, slotLimit: 5)
        XCTAssertEqual(phone.actions, Array(choices.prefix(5)))
        phone.save([.settings, .files])
        XCTAssertEqual(Array(HomeToolbarConfigurationService(defaults: defaults, slotLimit: 8).actions.suffix(3)), Array(choices.suffix(3)))
    }

    func testEveryActionHasALocalizedLabelAndSymbol() {
        for action in HomeToolbarAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertNotNil(UIImage(systemName: action.symbol), action.rawValue)
            XCTAssertNotNil(UIImage(systemName: action.listSymbol), action.rawValue)
            XCTAssertFalse(action.title.contains("_"), "Unresolved localization key: " + action.rawValue)
        }
    }
}
