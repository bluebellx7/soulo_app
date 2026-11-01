import XCTest
import SwiftUI
import WebKit
@testable import Soulo

final class TabManagerTests: XCTestCase {
    private let storageKey = "soulo_saved_tabs"

    @MainActor
    func testOverviewUsesRecentVisitsWithoutReorderingTheTabStripAndSurvivesRestart() throws {
        let key = "recent-overview-\(UUID())"
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let first = manager.createTab(url: URL(string: "https://first.example/article"))
        let second = manager.createTab(url: URL(string: "https://second.example/article"))
        let third = manager.createTab(url: URL(string: "https://third.example/article"))
        let stripOrder = manager.tabs.map(\.id)
        manager.switchToTab(id: first.id)
        XCTAssertEqual(Array(manager.tabsForOverview.prefix(3)).map(\.id), [first.id, third.id, second.id])
        XCTAssertEqual(manager.tabs.map(\.id), stripOrder)
        let lastVisit = try XCTUnwrap(manager.activeTab?.lastAccessedAt)
        let background = manager.createTab(url: URL(string: "https://background.example/"), switchTo: false)
        XCTAssertEqual(manager.activeTab?.lastAccessedAt, lastVisit, "A background operation is not a new visit")
        manager.closeTab(id: background.id)
        XCTAssertEqual(manager.activeTab?.lastAccessedAt, lastVisit)
        manager.saveToDisk()
        let restored = TabManager(storageKey: key)
        XCTAssertEqual(restored.tabsForOverview.map(\.id), manager.tabsForOverview.map(\.id))
        XCTAssertEqual(restored.tabs.map(\.id), stripOrder)
        XCTAssertTrue(restored.tabs.allSatisfy { $0.webViewModel.webView == nil }, "Sorting and restoring must not load webpages")
    }

    @MainActor
    func testClosingTheCurrentOverviewTabActivatesItsRecentSuccessorDirectly() throws {
        let key = "recent-tab-close-\(UUID())"
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let first = manager.createTab(keyword: "first")
        let middle = manager.createTab(keyword: "middle")
        let newest = manager.createTab(keyword: "newest")
        manager.switchToTab(id: first.id)
        let middleVisit = try XCTUnwrap(manager.tabs.first { $0.id == middle.id }?.lastAccessedAt)
        let next = try XCTUnwrap(manager.tabsForOverview.dropFirst().first)
        XCTAssertEqual(next.id, newest.id)
        manager.closeTab(at: try XCTUnwrap(manager.tabs.firstIndex { $0.id == first.id }), nextActiveTabID: next.id)
        XCTAssertEqual(manager.activeTab?.id, newest.id)
        XCTAssertEqual(manager.tabs.first { $0.id == middle.id }?.lastAccessedAt, middleVisit, "Do not activate an intermediate page")
        XCTAssertEqual(manager.recentlyClosed.first?.id, first.id)
        XCTAssertFalse(manager.tabs.contains { $0.id == first.id })
    }

    @MainActor
    func testOldSessionKeepsActiveIdentityAndDeterministicOverviewOrder() throws {
        let key = "legacy-tab-order-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let ids = (0..<4).map { _ in UUID().uuidString }
        let state: [String: Any] = ["tabs": [
            ["id": ids[0], "urlString": "https://old.example/first"],
            ["id": ids[1], "urlString": "webkit-extension://expired/page"],
            ["id": ids[2].lowercased(), "urlString": "https://old.example/current"],
            ["id": ids[3], "urlString": "https://other.example/"]
        ], "activeIndex": 2, "savedAt": 100.0]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: state), forKey: key)
        let manager = TabManager(storageKey: key)
        XCTAssertEqual(manager.activeTab?.id.uuidString, ids[2])
        XCTAssertEqual(manager.tabsForOverview.map { $0.id.uuidString }, [ids[2], ids[0], ids[3]])
        manager.saveToDisk()
        XCTAssertEqual(TabManager(storageKey: key).tabsForOverview.map(\.id), manager.tabsForOverview.map(\.id))
    }

    @MainActor
    func testSystemFindCountsNavigatesAndDismissesWithoutPageScripts() async throws {
        let key = "native-find-\(UUID())"
        let manager = TabManager(storageKey: key)
        let model = try XCTUnwrap(manager.activeWebViewModel)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        model.webView = web
        defer {
            manager.dismissFindInPage(); model.releaseWebViewRuntime()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            manager.saveToDisk(); UserDefaults.standard.removeObject(forKey: key)
        }
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <p>needle one</p><p style="margin-top:1000px">needle two</p>
        <p>a+b's [draft]</p><p style="display:none">a+b's [draft]</p>
        <script>window.find=undefined;window.pageMarker=42;</script>
        """, baseURL: URL(string: "https://example.com/find"))
        for _ in 0..<100 {
            if !web.isLoading, web.url != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        manager.startFindInPage()
        let interaction = try XCTUnwrap(web.findInteraction)
        for _ in 0..<100 {
            if interaction.activeFindSession != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(interaction.isFindNavigatorVisible)
        let session = try XCTUnwrap(interaction.activeFindSession)
        interaction.searchText = "needle"
        session.performSearch(query: "needle", options: nil)
        for _ in 0..<100 {
            if session.resultCount == 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(session.resultCount, 2)
        session.highlightNextResult(in: .forward)
        try await Task.sleep(for: .milliseconds(150))
        let first = session.highlightedResultIndex
        session.highlightNextResult(in: .forward)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotEqual(session.highlightedResultIndex, first)
        session.highlightNextResult(in: .backward)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.highlightedResultIndex, first)
        session.performSearch(query: "a+b's [draft]", options: nil)
        for _ in 0..<100 {
            if session.resultCount == 1 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(session.resultCount, 1)
        XCTAssertTrue(web.configuration.userContentController.userScripts.isEmpty)
        let marker = try await web.evaluateJavaScript("window.pageMarker")
        XCTAssertEqual(marker as? Int, 42)
        manager.createTab()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(interaction.isFindNavigatorVisible)
    }

    @MainActor
    func testDefaultWindowIdentityRestoresLatestWindowAndNewWindowsRemainIndependent() throws {
        let suite = "window-identity-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let older = UUID(), latest = UUID()
        for (id, date) in [(older, 10.0), (latest, 20.0)] {
            let state: [String: Any] = ["tabs": [["id": UUID().uuidString, "urlString": "https://example.com/article"]],
                "activeIndex": 0, "savedAt": date]
            defaults.set(try JSONSerialization.data(withJSONObject: state), forKey: "soulo_saved_tabs.\(id.uuidString)")
        }
        XCTAssertEqual(TabManager.mostRecentSavedWindowID(userDefaults: defaults), latest)
        let restored = BrowserWindowConfiguration.primaryID(userDefaults: defaults)
        XCTAssertEqual(restored, latest)
        XCTAssertEqual(BrowserWindowConfiguration.primaryID(userDefaults: defaults), restored)
        XCTAssertNotEqual(BrowserWindowConfiguration().id, restored)
        defaults.set(true, forKey: "is_incognito")
        XCTAssertNil(TabManager.mostRecentSavedWindowID(userDefaults: defaults))
        XCTAssertNotNil(defaults.data(forKey: "soulo_saved_tabs.\(older.uuidString)"), "Migrating the default window must preserve other windows")
    }

    @MainActor
    func testSavedTabsRestoreTheirTitlesWithoutCreatingWebViews() async throws {
        let key = "tab-titles-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        manager.activeWebViewModel?.loadURL(url)
        manager.activeWebViewModel?.updateTitle("Saved article")
        try await Task.sleep(for: .milliseconds(400))
        let restored = TabManager(storageKey: key)
        XCTAssertEqual(restored.activeWebViewModel?.pageTitle, "Saved article")
        XCTAssertEqual(restored.activeWebViewModel?.currentURL, url)
        XCTAssertNil(restored.activeWebViewModel?.webView)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.set(false, forKey: "is_incognito")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: storageKey)
        UserDefaults.standard.removeObject(forKey: "is_incognito")
        super.tearDown()
    }

    @MainActor
    func testPrivateEntryReleasesNormalRuntimeAndDoesNotResetTwice() throws {
        let manager = TabManager()
        let search = SearchViewModel()
        let old = try XCTUnwrap(manager.activeWebViewModel)
        old.webView = WKWebView()
        search.searchText = "previous query"
        search.currentKeyword = "previous query"
        search.suggestions = ["previous suggestion"]
        search.showClipboardPrompt = true

        XCTAssertTrue(search.setPrivateBrowsing(true, tabManager: manager))
        XCTAssertTrue(search.isIncognito)
        XCTAssertNil(old.webView)
        XCTAssertNil(manager.activeWebViewModel?.currentURL)
        XCTAssertTrue(search.suggestions.isEmpty)
        XCTAssertFalse(search.showClipboardPrompt)
        let privateTab = try XCTUnwrap(manager.activeTab)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        privateTab.webViewModel.webView = WKWebView(frame: .zero, configuration: configuration)
        XCTAssertFalse(manager.synchronizePrivacyMode(), "A later SwiftUI update must not discard the new request")
        XCTAssertEqual(manager.activeTab?.id, privateTab.id)
        XCTAssertNotNil(privateTab.webViewModel.webView)

        XCTAssertTrue(search.setPrivateBrowsing(false, tabManager: manager))
        XCTAssertNil(privateTab.webViewModel.webView)
        XCTAssertNotEqual(manager.activeTab?.id, privateTab.id)
    }

    @MainActor
    func testPrivateModeChangeAlsoReconcilesOtherWindow() throws {
        let first = TabManager(storageKey: "privacy-first-\(UUID())")
        let second = TabManager(storageKey: "privacy-second-\(UUID())")
        let old = try XCTUnwrap(second.activeWebViewModel)
        old.webView = WKWebView()
        let search = SearchViewModel()
        search.setPrivateBrowsing(true, tabManager: first)
        XCTAssertTrue(second.synchronizePrivacyMode())
        XCTAssertNil(old.webView)
        XCTAssertFalse(second.synchronizePrivacyMode())
    }

    @MainActor
    func testHomeSearchPreservesOriginalPageAndBrowserSearchReusesNewTab() throws {
        UserDefaults.standard.set(true, forKey: "is_incognito")
        let manager = TabManager()
        let search = SearchViewModel()
        let original = try XCTUnwrap(manager.activeTab)
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        original.webViewModel.loadURL(originalURL)
        manager.tabs[0].keyword = "original query"

        search.searchText = "new query"
        XCTAssertTrue(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        let result = try XCTUnwrap(manager.activeTab)
        XCTAssertEqual(manager.tabCount, 2)
        XCTAssertNotEqual(result.id, original.id)
        XCTAssertEqual(original.webViewModel.currentURL, originalURL)
        XCTAssertEqual(manager.tabs[0].keyword, "original query")
        XCTAssertEqual(result.keyword, "new query")
        XCTAssertTrue(search.isSearching)

        search.searchText = "refined query"
        search.performSearch()
        XCTAssertEqual(manager.activeTab?.id, result.id)
        XCTAssertEqual(manager.tabCount, 2)

        // A search waiting for its first WebKit load is already an occupied tab.
        search.clearSearch()
        search.searchText = "another home query"
        XCTAssertTrue(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        XCTAssertEqual(manager.tabCount, 3)
        XCTAssertNotEqual(manager.activeTab?.id, result.id)
        XCTAssertEqual(manager.tabs[1].keyword, "new query")
    }

    @MainActor
    func testHomeSearchReusesActiveBlankTabWithOtherPagesOpen() throws {
        UserDefaults.standard.set(true, forKey: "is_incognito")
        let manager = TabManager()
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        manager.activeWebViewModel?.loadURL(originalURL)
        let blank = manager.createTab()
        let search = SearchViewModel()
        search.searchText = "reuse blank"

        XCTAssertTrue(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        XCTAssertEqual(manager.tabCount, 2)
        XCTAssertEqual(manager.activeTab?.id, blank.id)
        XCTAssertEqual(manager.tabs[0].webViewModel.currentURL, originalURL)
        XCTAssertEqual(manager.activeTab?.keyword, "reuse blank")
    }

    @MainActor
    func testHomeSearchCreatesNewTabBeyondFormerLimitAndReusesBlankTab() throws {
        UserDefaults.standard.set(true, forKey: "is_incognito")
        let manager = TabManager()
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        manager.activeWebViewModel?.loadURL(originalURL)
        for index in 1..<100 { manager.createTab(keyword: "pending query \(index)") }
        let ids = manager.tabs.map(\.id)
        let search = SearchViewModel()
        search.searchText = "new home query"

        XCTAssertTrue(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        XCTAssertEqual(manager.tabCount, 101)
        XCTAssertEqual(Array(manager.tabs.prefix(100)).map(\.id), ids)
        XCTAssertEqual(manager.tabs[0].webViewModel.currentURL, originalURL)
        XCTAssertEqual(manager.activeTab?.keyword, "new home query")
        let blank = manager.createTab()
        search.clearSearch()
        search.searchText = "reuse blank"
        XCTAssertTrue(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        XCTAssertEqual(manager.tabCount, 102)
        XCTAssertEqual(manager.activeTab?.id, blank.id)
    }

    @MainActor
    func testEmptyHomeSearchLeavesExistingPageAlone() throws {
        UserDefaults.standard.set(true, forKey: "is_incognito")
        let manager = TabManager()
        let originalURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        manager.activeWebViewModel?.loadURL(originalURL)
        let activeID = manager.activeTab?.id
        let search = SearchViewModel()
        search.searchText = " \n\t "

        XCTAssertFalse(search.performHomeSearch(tabManager: manager, preferredRegion: .international, customGroup: nil))
        XCTAssertEqual(manager.tabCount, 1)
        XCTAssertEqual(manager.activeTab?.id, activeID)
        XCTAssertEqual(manager.activeWebViewModel?.currentURL, originalURL)
        XCTAssertFalse(search.isSearching)
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
    func testDesktopPreferenceAppliesToLaterTabsAndRestoredSession() throws {
        let key = "desktop-preference-\(UUID())"
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: "\(key).desktop_mode")
        }
        let manager = TabManager(storageKey: key)
        manager.setDesktopModeEnabled(true, reload: false)
        XCTAssertTrue(manager.createTab().webViewModel.isDesktopModeEnabled)

        manager.setDesktopModeForCurrentNavigation(false)
        XCTAssertTrue(manager.isDesktopMode, "A regular site must not undo the user's preference")
        manager.saveToDisk()

        let restored = TabManager(storageKey: key)
        XCTAssertTrue(restored.prefersDesktopMode)
        XCTAssertTrue(try XCTUnwrap(restored.activeWebViewModel).isDesktopModeEnabled)

        restored.setDesktopModeEnabled(false, reload: false)
        XCTAssertFalse(restored.createTab().webViewModel.isDesktopModeEnabled)
    }

    @MainActor
    func testDesktopPreferenceIsSharedAcrossBrowserWindows() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "soulo_desktop_mode")
        defaults.set(false, forKey: "soulo_desktop_mode")
        defer {
            if let previous { defaults.set(previous, forKey: "soulo_desktop_mode") }
            else { defaults.removeObject(forKey: "soulo_desktop_mode") }
        }

        let first = TabManager(storageKey: "soulo_saved_tabs.\(UUID())")
        let second = TabManager(storageKey: "soulo_saved_tabs.\(UUID())")
        first.setDesktopModeEnabled(true, reload: false)
        second.synchronizeDesktopMode()
        XCTAssertTrue(second.prefersDesktopMode)
        XCTAssertTrue(second.createTab().webViewModel.isDesktopModeEnabled)
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
    func testHundredsOfTabsKeepTheirIdentityAndRestoreWithoutLoadingWebKit() throws {
        let key = "many-tabs-\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        for index in 1..<500 {
            manager.createTab(url: URL(string: "https://example.com/\(index)"), keyword: "Query \(index)")
        }
        XCTAssertEqual(manager.tabCount, 500)
        XCTAssertTrue(manager.recentlyClosed.isEmpty)
        XCTAssertLessThanOrEqual(manager.tabs.filter(\.isAlive).count, TabManager.maxAliveTabs)
        XCTAssertTrue(manager.tabs.allSatisfy { $0.webViewModel.webView == nil })
        manager.switchToTab(at: 247)
        let ids = manager.tabs.map(\.id)
        manager.saveToDisk()
        let restored = TabManager(storageKey: key)
        XCTAssertEqual(restored.tabs.map(\.id), ids)
        XCTAssertEqual(restored.activeTabIndex, 247)
        XCTAssertEqual(restored.activeTab?.keyword, "Query 247")
        XCTAssertEqual(restored.tabs.filter(\.isAlive).count, 1)
        XCTAssertTrue(restored.tabs.allSatisfy { $0.webViewModel.webView == nil && $0.webViewModel.snapshot == nil })
        for index in [1, 247, 499] {
            XCTAssertEqual(restored.tabs[index].webViewModel.currentURL?.path, "/\(index)")
        }
        restored.switchToTab(at: 499)
        XCTAssertEqual(restored.activeWebViewModel?.currentURL?.path, "/499")
        XCTAssertTrue(restored.tabs[499].isAlive)
        restored.closeTab(at: 10)
        XCTAssertEqual(restored.activeTab?.id, ids[499])
        XCTAssertEqual(restored.tabCount, 499)
        // Leave no pending debounced writes after the storage fixture is removed.
        restored.saveToDisk()
    }

    @MainActor
    func testManyTabsSuspendDistantWebKitSessions() {
        let manager = TabManager()
        for index in 1..<(TabManager.maxAliveTabs + 4) {
            manager.createTab(url: URL(string: "https://example.com/\(index)"))
        }

        XCTAssertEqual(manager.tabs.count, TabManager.maxAliveTabs + 4)
        XCTAssertTrue(manager.tabs.prefix(4).allSatisfy { !$0.isAlive })
        XCTAssertTrue(manager.tabs.dropFirst(4).allSatisfy(\.isAlive))
    }

    @MainActor
    func testRecentDistantTabKeepsRuntimeAndMemoryWarningReleasesOnlyBackground() async throws {
        let manager = TabManager()
        let first = manager.activeTab!
        let web = WKWebView()
        first.webViewModel.webView = web
        manager.createTab()
        manager.switchToTab(at: 0)
        XCTAssertTrue(first.webViewModel.webView === web)
        for _ in 0..<18 { manager.createTab() }
        XCTAssertEqual(manager.tabs.count, 20)
        XCTAssertLessThanOrEqual(manager.tabs.filter(\.isAlive).count, TabManager.maxAliveTabs)
        manager.switchToTab(at: 0)
        let active = manager.activeTab!
        manager.releaseInactiveTabsForMemoryPressure()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(manager.tabs.filter(\.isAlive).map(\.id), [active.id])
        XCTAssertEqual(manager.tabs.count, 20, "Memory pressure must not discard tabs")
        XCTAssertTrue(manager.tabs.dropFirst().allSatisfy { $0.webViewModel.webView == nil })
    }

    @MainActor
    func testRecentTabStaysWarmRegardlessOfPositionAndRapidSwitchDoesNotReload() async throws {
        let manager = TabManager()
        for _ in 0..<8 { manager.createTab() }
        manager.switchToTab(at: 0)
        let web = WKWebView()
        manager.activeWebViewModel?.webView = web
        manager.switchToTab(at: 8)
        manager.switchToTab(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(manager.activeWebViewModel?.webView === web)
        XCTAssertTrue(manager.tabs[8].isAlive)
        XCTAssertLessThanOrEqual(manager.tabs.filter(\.isAlive).count, TabManager.maxAliveTabs)
    }

    @MainActor
    func testMediaDownloadSurvivesTabEvictionAndMemoryPressure() async throws {
        let manager = TabManager()
        let model = try XCTUnwrap(manager.activeWebViewModel)
        let web = WKWebView(); model.webView = web
        let url = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
        XCTAssertTrue(model.beginMediaDownload(url: url, name: "Video"))
        for _ in 0..<TabManager.maxAliveTabs + 1 { manager.createTab() }
        manager.releaseInactiveTabsForMemoryPressure()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.webView === web)
        model.finishMediaDownload(url: url)
        manager.releaseInactiveTabsForMemoryPressure()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.webView)
    }

    @MainActor
    func testIndependentWindowStorageKeepsTabSessionsSeparate() {
        let firstKey = "soulo_saved_tabs.window-a.\(UUID().uuidString)"
        let secondKey = "soulo_saved_tabs.window-b.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: firstKey)
            UserDefaults.standard.removeObject(forKey: secondKey)
        }

        let first = TabManager(storageKey: firstKey)
        first.createTab(url: URL(string: "https://example.com/window-a"))
        first.saveToDisk()

        let second = TabManager(storageKey: secondKey)
        XCTAssertEqual(second.tabs.count, 1)
        XCTAssertNil(second.activeWebViewModel?.currentURL)

        let restoredFirst = TabManager(storageKey: firstKey)
        XCTAssertEqual(restoredFirst.tabs.count, 2)
        XCTAssertEqual(restoredFirst.activeWebViewModel?.currentURL?.absoluteString, "https://example.com/window-a")
    }

    @MainActor
    func testWebExtensionPageTabsAreSessionOnly() {
        let key = "soulo_saved_tabs.extension-pages.\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        manager.createTab(url: URL(string: "https://example.com/article"))
        manager.createTab(
            url: URL(string: "webkit-extension://temporary/options/options.html")
        )

        manager.saveToDisk()
        let restored = TabManager(storageKey: key)

        XCTAssertEqual(restored.tabs.count, 2)
        XCTAssertEqual(
            restored.tabs.compactMap { $0.webViewModel.currentURL?.absoluteString },
            ["https://example.com/article"]
        )
        XCTAssertEqual(restored.activeWebViewModel?.currentURL?.absoluteString, "https://example.com/article")
    }
}

@MainActor
final class PlatformDataStoreTests: XCTestCase {
    func testShenmaDefaultsPrecedeBaiduAndUseTheOfficialSearchURL() throws {
        let china = PlatformDataStore.defaultPlatforms().filter { $0.region == .china }.sorted { $0.sortOrder < $1.sortOrder }
        let baidu = try XCTUnwrap(china.firstIndex { $0.name == "platform_baidu" })
        let shenma = china[baidu - 1]
        XCTAssertEqual(shenma.name, "platform_shenma")
        XCTAssertTrue(shenma.isVisible)
        XCTAssertFalse(shenma.requiresLogin)
        XCTAssertNotNil(UIImage(named: shenma.iconName))
        let url = try XCTUnwrap(shenma.searchURL(for: "黑夜传说"))
        XCTAssertEqual(url.host, "m.sm.cn")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "黑夜传说")
    }

    func testShenmaUpgradePreservesUserOrderAndManualVisibility() throws {
        let defaults = UserDefaults.standard, store = PlatformDataStore.shared
        let data = defaults.data(forKey: "platform_config"), version = defaults.object(forKey: "platform_config_version")
        defer {
            defaults.set(data, forKey: "platform_config"); defaults.set(version, forKey: "platform_config_version"); store.reloadFromDefaults()
        }
        var old = PlatformDataStore.defaultPlatforms().filter { $0.name != "platform_shenma" }
        let chinaIDs = old.filter { $0.region == .china }.reversed().map(\.id)
        for (order, id) in chinaIDs.enumerated() {
            let index = try XCTUnwrap(old.firstIndex { $0.id == id })
            old[index].sortOrder = order
            if old[index].name == "platform_bilibili" { old[index].isVisible = false }
        }
        defaults.set(try JSONEncoder().encode(old), forKey: "platform_config")
        defaults.set(43, forKey: "platform_config_version"); store.reloadFromDefaults()
        let china = store.platforms(for: .china)
        let baidu = try XCTUnwrap(china.firstIndex { $0.name == "platform_baidu" })
        let shenma = china[baidu - 1]
        XCTAssertEqual(shenma.name, "platform_shenma")
        XCTAssertEqual(china.filter { $0.id != shenma.id }.map(\.id), chinaIDs)
        for platform in old {
            XCTAssertEqual(store.platforms.first { $0.id == platform.id }?.isVisible, platform.isVisible)
        }
        store.toggleVisibility(for: shenma.id); store.reloadFromDefaults()
        XCTAssertEqual(store.platforms.filter { $0.name == "platform_shenma" }.count, 1)
        XCTAssertFalse(try XCTUnwrap(store.platforms.first { $0.id == shenma.id }).isVisible)
    }

    func testShenmaUpgradeKeepsAnEntirelyDisabledChinaGroupDisabled() throws {
        let defaults = UserDefaults.standard, store = PlatformDataStore.shared
        let data = defaults.data(forKey: "platform_config"), version = defaults.object(forKey: "platform_config_version")
        defer {
            defaults.set(data, forKey: "platform_config"); defaults.set(version, forKey: "platform_config_version"); store.reloadFromDefaults()
        }
        let old = PlatformDataStore.defaultPlatforms().filter { $0.name != "platform_shenma" }.map { platform in
            var platform = platform
            if platform.region == .china { platform.isVisible = false }
            return platform
        }
        defaults.set(try JSONEncoder().encode(old), forKey: "platform_config")
        defaults.set(43, forKey: "platform_config_version"); store.reloadFromDefaults()
        XCTAssertNotNil(store.platforms.first { $0.name == "platform_shenma" })
        XCTAssertTrue(store.visiblePlatforms(for: .china).isEmpty)
    }

    func testBingIsAvailableInChinaAndInternationalGroups() throws {
        let platforms = PlatformDataStore.shared.allPlatforms()
            .filter { $0.isBuiltIn && $0.name == "platform_bing" }

        XCTAssertEqual(Set(platforms.map(\.region)), Set([.china, .international]))
        XCTAssertTrue(platforms.allSatisfy(\.isVisible))
        XCTAssertEqual(Set(platforms.map(\.id)).count, 2)
        for platform in platforms {
            let url = try XCTUnwrap(platform.searchURL(for: "中国 搜索"))
            XCTAssertEqual(url.host, "www.bing.com")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "q" })?.value, "中国 搜索")
        }
    }

    func testEveryBuiltInPlatformProducesARealSecureSearchURL() throws {
        let query = "Soulo browser test"
        let encodedQuery = "Soulo%20browser%20test"
        let platforms = PlatformDataStore.shared.allPlatforms().filter(\.isBuiltIn)

        XCTAssertGreaterThanOrEqual(platforms.count, 49)
        XCTAssertFalse(platforms.contains { $0.name == "platform_phind" })
        for platform in platforms {
            let url = try XCTUnwrap(
                platform.searchURL(for: query),
                "Invalid search URL for \(platform.name)"
            )
            XCTAssertEqual(url.scheme, "https", "Insecure search URL for \(platform.name)")
            XCTAssertNotNil(url.host, "Missing search host for \(platform.name)")
            XCTAssertFalse(url.absoluteString.contains("%@"), "Unexpanded query for \(platform.name)")
            switch platform.interactionType {
            case .urlSearch:
                XCTAssertTrue(
                    url.absoluteString.contains(encodedQuery),
                    "Search query was not encoded into \(platform.name)"
                )
            case .aiChat:
                XCTAssertTrue(platform.requiresLogin)
                XCTAssertEqual(url, platform.homePageURL)
            }

            let homeURL = try XCTUnwrap(
                platform.homePageURL,
                "Invalid home URL for \(platform.name)"
            )
            XCTAssertEqual(homeURL.scheme, "https", "Insecure home URL for \(platform.name)")
            XCTAssertNotNil(homeURL.host, "Missing home host for \(platform.name)")
        }
    }

    func testKoreanSearchPlatformsUseRealQueryURLs() throws {
        let koreanPlatforms = PlatformDataStore.shared.platforms(for: .korea)

        XCTAssertEqual(
            Set(koreanPlatforms.map(\.name)),
            Set([
                "platform_naver",
                "platform_daum",
                "platform_google_kr",
                "platform_youtube_kr"
            ])
        )
        XCTAssertTrue(koreanPlatforms.allSatisfy { $0.isBuiltIn && $0.isVisible })
        for platform in koreanPlatforms {
            let url = try XCTUnwrap(platform.searchURL(for: "서울 카페"))
            XCTAssertEqual(url.scheme, "https")
            XCTAssertFalse(url.absoluteString.contains("%@"))
            XCTAssertTrue(url.absoluteString.contains("%EC%84%9C%EC%9A%B8"))
        }
    }

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

    func testZhihuUsesOfficialContentSearchAndRequiresLogin() throws {
        let platform = try XCTUnwrap(
            PlatformDataStore.shared.allPlatforms().first { $0.name == "platform_zhihu" }
        )

        XCTAssertTrue(platform.isBuiltIn)
        XCTAssertTrue(platform.requiresLogin)

        let url = try XCTUnwrap(platform.searchURL(for: "搜索"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "www.zhihu.com")
        XCTAssertEqual(url.path, "/search")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "type" })?.value, "content")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "搜索")
    }

    func testZLibraryUsesInternationalBookSearch() throws {
        let platform = try XCTUnwrap(
            PlatformDataStore.shared.allPlatforms().first { $0.name == "platform_zlibrary" }
        )

        XCTAssertTrue(platform.isBuiltIn)
        XCTAssertTrue(platform.isVisible)
        XCTAssertEqual(platform.region, .international)

        let url = try XCTUnwrap(platform.searchURL(for: "Swift 编程"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.host, "z-library.sk")
        XCTAssertEqual(url.path, "/s/book")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "keyword" })?.value, "Swift 编程")
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
