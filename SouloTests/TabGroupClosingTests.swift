import XCTest
@testable import Soulo

@MainActor final class TabGroupClosingTests: XCTestCase {
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
        }
        managers.removeAll()
        UserDefaults.standard.set(originalPrivateMode, forKey: "is_incognito")
        super.tearDown()
    }

    private func makeManager() -> TabManager {
        let key = "group-close-" + UUID().uuidString
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        let manager = TabManager(storageKey: key)
        manager.tabs.removeAll()
        managers.append((key, manager))
        return manager
    }

    private func group(_ host: String, in manager: TabManager) throws -> TabOverviewDomainGroup {
        try XCTUnwrap(TabOverviewDomainGroup.make(from: manager.tabsForOverview).first { $0.id == "host:" + host })
    }

    func testClosesOnlyTheChosenGroupAndPreservesCurrentTabAndOrder() throws {
        let manager = makeManager()
        let first = manager.createTab(url: URL(string: "https://example.com/one"))
        let current = manager.createTab(url: URL(string: "https://other.test/current"))
        let second = manager.createTab(url: URL(string: "https://www.example.com/two"))
        let separateSubdomain = manager.createTab(url: URL(string: "https://news.example.com/three"))
        manager.switchToTab(id: current.id)
        let visit = manager.activeTab?.lastAccessedAt
        manager.desktopModeTabs = [first.id, current.id, second.id]
        let requested = try group("example.com", in: manager)
        manager.closeTabs(ids: requested.tabIDsStillInGroup(manager.tabs))
        XCTAssertEqual(manager.tabs.map(\.id), [current.id, separateSubdomain.id])
        XCTAssertEqual(manager.activeTab?.id, current.id)
        XCTAssertEqual(manager.activeTab?.lastAccessedAt, visit)
        XCTAssertEqual(manager.desktopModeTabs, [current.id])
        XCTAssertEqual(Set(manager.recentlyClosed.map(\.id)), [first.id, second.id])
    }

    func testClosingCurrentGroupActivatesRecentSurvivorWithoutIntermediateVisits() throws {
        let manager = makeManager()
        let first = manager.createTab(url: URL(string: "https://example.com/one"))
        let older = manager.createTab(url: URL(string: "https://older.test/"))
        let recent = manager.createTab(url: URL(string: "https://recent.test/"))
        manager.createTab(url: URL(string: "https://example.com/two"))
        manager.switchToTab(id: first.id)
        let olderVisit = manager.tabs.first { $0.id == older.id }?.lastAccessedAt
        let requested = try group("example.com", in: manager)
        manager.closeTabs(ids: requested.tabIDsStillInGroup(manager.tabs))
        XCTAssertEqual(manager.activeTab?.id, recent.id)
        XCTAssertEqual(manager.tabs.first { $0.id == older.id }?.lastAccessedAt, olderVisit)
        XCTAssertEqual(manager.recentlyClosed.first?.id, first.id)
    }

    func testClosingTheLastGroupCreatesExactlyOneBlankTab() throws {
        let manager = makeManager()
        let first = manager.createTab(url: URL(string: "https://example.com/one"))
        let second = manager.createTab(url: URL(string: "https://example.com/two"))
        manager.showTabOverview = true
        manager.closeTabs(ids: try group("example.com", in: manager).tabIDsStillInGroup(manager.tabs))
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNil(manager.activeTab?.webViewModel.currentURL)
        XCTAssertEqual(manager.activeTabIndex, 0)
        XCTAssertTrue(manager.showTabOverview)
        XCTAssertEqual(Set(manager.recentlyClosed.map(\.id)), [first.id, second.id])
    }

    func testEmptyOrStaleIdentifiersDoNotCloseAnythingOrCreateBlankTabs() {
        let manager = makeManager()
        let current = manager.createTab(url: URL(string: "https://example.com/"))
        let visit = manager.activeTab?.lastAccessedAt
        manager.closeTabs(ids: [])
        manager.closeTabs(ids: [UUID()])
        XCTAssertEqual(manager.tabs.map(\.id), [current.id])
        XCTAssertEqual(manager.activeTab?.lastAccessedAt, visit)
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
    }

    func testConfirmationSnapshotDoesNotCloseNewOrMovedTabs() throws {
        let manager = makeManager()
        let moved = manager.createTab(url: URL(string: "https://example.com/one"))
        let original = manager.createTab(url: URL(string: "https://example.com/two"))
        let requested = try group("example.com", in: manager)
        moved.webViewModel.currentURL = URL(string: "https://other.test/moved")
        let added = manager.createTab(url: URL(string: "https://example.com/new"))
        let ids = requested.tabIDsStillInGroup(manager.tabs)
        XCTAssertEqual(ids, [original.id])
        manager.closeTabs(ids: ids)
        XCTAssertEqual(manager.tabs.map(\.id), [moved.id, added.id])
        XCTAssertTrue(requested.tabIDsStillInGroup(manager.tabs).isEmpty)
    }

    func testOrdinaryGroupClosurePersistsSurvivorsAndCanRestoreClosedTabs() throws {
        let manager = makeManager()
        let closed = manager.createTab(url: URL(string: "https://example.com/article"))
        let survivor = manager.createTab(url: URL(string: "https://other.test/current"))
        manager.closeTabs(ids: [closed.id])
        manager.saveToDisk()
        let restored = TabManager(storageKey: try XCTUnwrap(managers.first?.0))
        XCTAssertEqual(restored.tabs.map(\.id), [survivor.id])
        XCTAssertEqual(restored.activeTab?.id, survivor.id)
        let record = try XCTUnwrap(manager.recentlyClosed.first)
        manager.restoreClosedTab(record)
        XCTAssertEqual(manager.activeTab?.webViewModel.currentURL, URL(string: "https://example.com/article"))
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
    }

    func testPrivateGroupClosureDoesNotRecordRecentlyClosedOrPersistPrivateTabs() throws {
        UserDefaults.standard.set(true, forKey: "is_incognito")
        let manager = makeManager()
        let closed = manager.createTab(url: URL(string: "https://private.example/sensitive"))
        manager.closeTabs(ids: [closed.id])
        manager.saveToDisk()
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
        XCTAssertEqual(manager.tabs.count, 1)
        XCTAssertNil(UserDefaults.standard.data(forKey: try XCTUnwrap(managers.first?.0)))
    }

    func testGroupClosureKeepsTheExistingRecentlyClosedLimit() throws {
        let manager = makeManager()
        for index in 0..<15 { manager.createTab(url: URL(string: "https://example.com/\(index)")) }
        let survivor = manager.createTab(url: URL(string: "https://other.test/"))
        manager.closeTabs(ids: try group("example.com", in: manager).tabIDsStillInGroup(manager.tabs))
        XCTAssertEqual(manager.tabs.map(\.id), [survivor.id])
        XCTAssertEqual(manager.recentlyClosed.count, TabManager.maxRecentlyClosed)
        XCTAssertTrue(manager.recentlyClosed.allSatisfy { $0.url?.host == "example.com" })
    }
}
