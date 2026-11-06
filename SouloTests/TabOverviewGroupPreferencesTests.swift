import XCTest
@testable import Soulo

@MainActor
final class TabOverviewGroupPreferencesTests: XCTestCase {
    private var originalPrivateMode: Any?
    private var managers: [(String, TabManager)] = []

    override func setUp() {
        super.setUp()
        originalPrivateMode = UserDefaults.standard.object(forKey: "is_incognito")
        UserDefaults.standard.set(false, forKey: "is_incognito")
    }

    override func tearDown() {
        for (key, manager) in managers {
            manager.tabs.forEach { $0.webViewModel.releaseWebViewRuntime() }
            manager.saveToDisk()
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: key + ".desktop_mode")
            UserDefaults.standard.removeObject(forKey: key + ".overview_groups")
        }
        managers.removeAll()
        UserDefaults.standard.set(originalPrivateMode, forKey: "is_incognito")
        super.tearDown()
    }

    private func makeManager(restoring key: String? = nil) -> (String, TabManager) {
        let storageKey = key ?? "overview-group-preferences-\(UUID())"
        if key == nil {
            // Avoid the legacy default-window migration in an isolated test.
            UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: storageKey)
        }
        let manager = TabManager(storageKey: storageKey)
        managers.append((storageKey, manager))
        return (storageKey, manager)
    }

    func testNamesAndPinningRestoreWithoutChangingTabsOrOpeningWebViews() throws {
        let (key, manager) = makeManager()
        manager.createTab(url: URL(string: "https://example.com/one"))
        manager.createTab(url: URL(string: "https://www.example.com/two"))
        manager.createTab(url: URL(string: "https://other.test/current"))
        let stripOrder = manager.tabs.map(\.id), overviewOrder = manager.tabsForOverview.map(\.id)
        let groupIDs = TabOverviewDomainGroup.make(from: manager.tabsForOverview).map(\.id)
        let active = manager.activeTab?.id
        let visits = Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0.lastAccessedAt) })

        manager.renameOverviewGroup("host:example.com", to: " \n" + String(repeating: "集", count: 100) + " \n")
        manager.togglePinnedOverviewGroup("host:example.com")
        XCTAssertEqual(manager.overviewGroupNames["host:example.com"], String(repeating: "集", count: 80))
        XCTAssertEqual(manager.pinnedOverviewGroupIDs, ["host:example.com"])
        XCTAssertEqual(manager.tabs.map(\.id), stripOrder)
        XCTAssertEqual(manager.tabsForOverview.map(\.id), overviewOrder)
        XCTAssertEqual(TabOverviewDomainGroup.make(from: manager.tabsForOverview).map(\.id), groupIDs)
        XCTAssertEqual(manager.activeTab?.id, active)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: manager.tabs.map { ($0.id, $0.lastAccessedAt) }), visits)
        XCTAssertTrue(manager.tabs.allSatisfy { $0.webViewModel.webView == nil })

        manager.saveToDisk()
        let (_, restored) = makeManager(restoring: key)
        XCTAssertEqual(restored.overviewGroupNames, manager.overviewGroupNames)
        XCTAssertEqual(restored.pinnedOverviewGroupIDs, manager.pinnedOverviewGroupIDs)
        XCTAssertEqual(restored.tabs.map(\.id), stripOrder)
        restored.renameOverviewGroup("host:example.com", to: " \t\n")
        restored.togglePinnedOverviewGroup("host:example.com")
        let (_, reset) = makeManager(restoring: key)
        XCTAssertNil(reset.overviewGroupNames["host:example.com"], "Empty names restore the site's original display title")
        XCTAssertTrue(reset.pinnedOverviewGroupIDs.isEmpty)
    }

    func testGroupPreferencesAreIsolatedByWindowStorageKey() {
        let (firstKey, first) = makeManager(), (secondKey, second) = makeManager()
        first.createTab(url: URL(string: "https://example.com/one"))
        second.createTab(url: URL(string: "https://example.com/two"))
        first.renameOverviewGroup("host:example.com", to: "First window")
        first.togglePinnedOverviewGroup("host:example.com")
        XCTAssertTrue(second.overviewGroupNames.isEmpty)
        XCTAssertTrue(second.pinnedOverviewGroupIDs.isEmpty)
        second.renameOverviewGroup("host:example.com", to: "Second window")
        first.saveToDisk(); second.saveToDisk()

        let (_, restoredFirst) = makeManager(restoring: firstKey)
        let (_, restoredSecond) = makeManager(restoring: secondKey)
        XCTAssertEqual(restoredFirst.overviewGroupNames["host:example.com"], "First window")
        XCTAssertEqual(restoredFirst.pinnedOverviewGroupIDs, ["host:example.com"])
        XCTAssertEqual(restoredSecond.overviewGroupNames["host:example.com"], "Second window")
        XCTAssertTrue(restoredSecond.pinnedOverviewGroupIDs.isEmpty)
    }

    func testPrivateGroupChoicesNeverReplaceOrdinaryPreferencesAndAreDiscardedOnExit() throws {
        let (key, manager) = makeManager()
        manager.createTab(url: URL(string: "https://example.com/ordinary"))
        manager.renameOverviewGroup("host:example.com", to: "Ordinary name")
        manager.togglePinnedOverviewGroup("host:example.com")
        let normalData = try XCTUnwrap(UserDefaults.standard.data(forKey: key + ".overview_groups"))

        UserDefaults.standard.set(true, forKey: "is_incognito")
        XCTAssertTrue(manager.synchronizePrivacyMode())
        XCTAssertTrue(manager.overviewGroupNames.isEmpty)
        XCTAssertTrue(manager.pinnedOverviewGroupIDs.isEmpty)
        manager.createTab(url: URL(string: "https://example.com/private"))
        manager.createTab(url: URL(string: "https://secret.test/sensitive"))
        manager.renameOverviewGroup("host:example.com", to: "Private choice")
        manager.renameOverviewGroup("host:secret.test", to: "Secret name")
        manager.togglePinnedOverviewGroup("host:secret.test")
        manager.saveToDisk()
        XCTAssertEqual(manager.overviewGroupNames["host:example.com"], "Private choice")
        XCTAssertEqual(UserDefaults.standard.data(forKey: key + ".overview_groups"), normalData)
        XCTAssertNil(UserDefaults.standard.data(forKey: key), "Private tabs themselves must not be saved either")
        let (_, privateRestart) = makeManager(restoring: key)
        XCTAssertTrue(privateRestart.overviewGroupNames.isEmpty)
        XCTAssertTrue(privateRestart.pinnedOverviewGroupIDs.isEmpty)

        UserDefaults.standard.set(false, forKey: "is_incognito")
        XCTAssertTrue(manager.synchronizePrivacyMode())
        XCTAssertEqual(manager.overviewGroupNames, ["host:example.com": "Ordinary name"])
        XCTAssertEqual(manager.pinnedOverviewGroupIDs, ["host:example.com"])
        XCTAssertTrue(privateRestart.synchronizePrivacyMode())
        XCTAssertEqual(privateRestart.overviewGroupNames, manager.overviewGroupNames)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key + ".overview_groups"), normalData)
    }

    func testDelayedOrdinaryWindowActionCannotPersistPrivateNamesOrCreateAnArbitraryGroup() throws {
        let (key, manager) = makeManager()
        manager.createTab(url: URL(string: "https://example.com/ordinary"))
        manager.renameOverviewGroup("host:example.com", to: "Kept")
        let normalData = try XCTUnwrap(UserDefaults.standard.data(forKey: key + ".overview_groups"))
        let tabIDs = manager.tabs.map(\.id)
        manager.renameOverviewGroup("host:missing.test", to: "Not a group")
        manager.togglePinnedOverviewGroup("host:missing.test")
        XCTAssertEqual(manager.tabs.map(\.id), tabIDs)
        XCTAssertEqual(manager.overviewGroupNames, ["host:example.com": "Kept"])
        XCTAssertTrue(manager.pinnedOverviewGroupIDs.isEmpty)

        UserDefaults.standard.set(true, forKey: "is_incognito")
        manager.renameOverviewGroup("host:example.com", to: "Delayed private action")
        manager.togglePinnedOverviewGroup("host:example.com")
        XCTAssertTrue(manager.overviewGroupNames.isEmpty, "The ordinary group's delayed action must reconcile privacy before editing")
        XCTAssertTrue(manager.pinnedOverviewGroupIDs.isEmpty)
        XCTAssertEqual(UserDefaults.standard.data(forKey: key + ".overview_groups"), normalData)
    }
}
