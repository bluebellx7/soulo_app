import XCTest
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
