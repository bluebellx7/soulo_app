import XCTest
import SwiftUI
@testable import Soulo

final class TabManagerTests: XCTestCase {
    private let storageKey = "soulo_saved_tabs"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        super.tearDown()
    }

    @MainActor
    func testCreateTabWithoutURLCreatesBlankTab() {
        let manager = TabManager()
        let originalURL = URL(string: "https://example.com/article")!

        manager.activeWebViewModel?.loadURL(originalURL)
        manager.tabs[0].keyword = "original search"

        let newTab = manager.createTab()

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeTabIndex, 1)
        XCTAssertEqual(manager.activeTab?.id, newTab.id)
        XCTAssertNil(newTab.webViewModel.currentURL)
        XCTAssertNil(newTab.keyword)
        XCTAssertNil(newTab.platform)
        XCTAssertTrue(newTab.webViewModel.pageTitle.isEmpty)
    }

    @MainActor
    func testCreateTabWithURLLoadsRequestedURL() {
        let manager = TabManager()
        let targetURL = URL(string: "https://example.com/new")!

        let newTab = manager.createTab(url: targetURL, keyword: "new", platform: nil)

        XCTAssertEqual(manager.tabs.count, 2)
        XCTAssertEqual(manager.activeTabIndex, 1)
        XCTAssertEqual(newTab.webViewModel.currentURL, targetURL)
        XCTAssertEqual(newTab.keyword, "new")
    }

    @MainActor
    func testTabLimitNeverSilentlyEvictsExistingTab() {
        let manager = TabManager()
        for index in 1..<TabManager.maxTabs {
            manager.createTab(url: URL(string: "https://example.com/\(index)"))
        }
        let idsBeforeAttempt = manager.tabs.map(\.id)
        let activeID = manager.activeTab?.id

        let returnedTab = manager.createTab(url: URL(string: "https://example.com/overflow"))

        XCTAssertEqual(manager.tabs.count, TabManager.maxTabs)
        XCTAssertEqual(manager.tabs.map(\.id), idsBeforeAttempt)
        XCTAssertEqual(returnedTab.id, activeID)
        XCTAssertTrue(manager.didReachTabLimit)
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
    }

    @MainActor
    func testManyTabsSuspendDistantWebKitSessions() {
        let manager = TabManager()
        for index in 1...6 {
            manager.createTab(url: URL(string: "https://example.com/\(index)"))
        }

        XCTAssertEqual(manager.tabs.count, 7)
        XCTAssertTrue(manager.tabs[0...3].allSatisfy { !$0.isAlive })
        XCTAssertTrue(manager.tabs[4...6].allSatisfy(\.isAlive))
    }
}

@MainActor
final class PlatformDataStoreTests: XCTestCase {
    func testXiaohongshuIsAvailableAsBuiltInChinaPlatform() throws {
        let platform = try XCTUnwrap(
            PlatformDataStore.shared.allPlatforms().first { $0.name == "platform_xiaohongshu" }
        )

        XCTAssertEqual(platform.region, .china)
        XCTAssertEqual(platform.iconName, "icon_xiaohongshu")
        XCTAssertTrue(platform.isBuiltIn)
        XCTAssertTrue(platform.isVisible)
        XCTAssertTrue(platform.requiresLogin)
        XCTAssertTrue(platform.requiresDesktopMode)

        let url = try XCTUnwrap(platform.searchURL(for: "上海 咖啡"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "www.xiaohongshu.com")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "keyword" })?.value, "上海 咖啡")
    }

    func testOnlyXiaohongshuRequiresDesktopMode() throws {
        let store = PlatformDataStore.shared
        let xiaohongshu = try XCTUnwrap(store.allPlatforms().first { $0.name == "platform_xiaohongshu" })

        XCTAssertTrue(xiaohongshu.requiresDesktopMode)
        XCTAssertEqual(
            store.allPlatforms().filter(\.requiresDesktopMode).map(\.name),
            ["platform_xiaohongshu"]
        )
    }

    func testManualRegionOrderIsAppliedAtomicallyAndRemainsCanonical() throws {
        let store = PlatformDataStore.shared
        let originalPlatforms = store.platforms
        defer {
            store.platforms = originalPlatforms
            store.savePlatforms()
        }

        let before = store.platforms(for: .china)
        XCTAssertGreaterThan(before.count, 2)

        store.movePlatform(
            from: IndexSet(integer: 0),
            to: before.count,
            within: .china
        )

        let after = store.platforms(for: .china)
        XCTAssertEqual(after.map(\.id), Array(before.dropFirst()).map(\.id) + [try XCTUnwrap(before.first).id])
        XCTAssertEqual(after.map(\.sortOrder), Array(after.indices))
    }

    func testHomeSearchRefreshesStaleSelectionAfterManualReordering() throws {
        let store = PlatformDataStore.shared
        let originalPlatforms = store.platforms
        defer {
            store.platforms = originalPlatforms
            store.savePlatforms()
        }

        let before = store.visiblePlatforms(for: .china)
        XCTAssertGreaterThan(before.count, 1)

        let viewModel = SearchViewModel()
        viewModel.selectRegion(.china)
        XCTAssertEqual(viewModel.selectedPlatform?.id, before[0].id)

        store.movePlatform(
            from: IndexSet(integer: 1),
            to: 0,
            within: .china
        )
        let reorderedFirst = try XCTUnwrap(store.visiblePlatforms(for: .china).first)
        XCTAssertNotEqual(viewModel.selectedPlatform?.id, reorderedFirst.id)

        viewModel.prepareForHomeSearch(preferredRegion: .china, customGroup: nil)

        XCTAssertEqual(viewModel.selectedPlatform?.id, reorderedFirst.id)
    }

    func testCustomGroupOrderSurvivesSelectionAndDragReordering() throws {
        let store = PlatformDataStore.shared
        let originalGroups = store.customGroups
        defer {
            store.customGroups = originalGroups
            store.saveGroups()
        }

        let platforms = Array(store.allPlatforms().prefix(3))
        XCTAssertEqual(platforms.count, 3)
        let group = CustomGroup(name: "Ordering Test")
        store.customGroups.append(group)
        store.setPlatforms(platforms.map(\.id), inGroup: group.id)
        store.movePlatform(from: IndexSet(integer: 0), to: 3, withinGroup: group.id)

        XCTAssertEqual(
            store.platformsForGroup(try XCTUnwrap(store.customGroups.first { $0.id == group.id })).map(\.id),
            [platforms[1].id, platforms[2].id, platforms[0].id]
        )
    }
}
