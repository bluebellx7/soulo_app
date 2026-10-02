import XCTest
import SwiftUI
import SwiftData
import WebKit
@testable import Soulo

@MainActor final class SelectionSearchNavigationTests: XCTestCase {
    private struct ResultsHost: View {
        @Namespace private var namespace
        @StateObject private var speech = SpeechRecognitionService()
        @EnvironmentObject private var search: SearchViewModel
        var useHome = false
        var onlyWhenSearching = false
        var body: some View {
            if useHome {
                HomeView()
            } else {
                NavigationStack {
                    if !onlyWhenSearching || search.isSearching {
                        SearchResultsView(searchBarNamespace: namespace, speechService: speech)
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }

    private final class CountingWebView: WKWebView {
        var loads = 0
        override func load(_ request: URLRequest) -> WKNavigation? {
            loads += 1
            return super.load(request)
        }
    }

    func testHomeSearchReusesWebViewAndPlatformStatisticsDoNotRestartNavigation() async throws {
        let defaults = UserDefaults.standard
        let keys = ["last_selected_region", "last_selected_group_id", "is_incognito"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("", forKey: "last_selected_region")
        defaults.set("", forKey: "last_selected_group_id")
        defaults.set(true, forKey: "is_incognito")
        let key = "soulo.test.home-search.\(UUID())"
        defer { defaults.removeObject(forKey: key) }
        let tabs = TabManager(storageKey: key)
        let model = try XCTUnwrap(tabs.activeWebViewModel)
        let web = CountingWebView()
        model.webView = web
        let html = "<html><body><p id='result'>Search loaded</p></body></html>"
        let platform = SearchPlatform(id: UUID(), name: "Search fixture", iconName: "globe",
            searchURLTemplate: "data:text/html;base64,\(Data(html.utf8).base64EncodedString())#%@",
            homeURL: "https://example.com", region: .international, isBuiltIn: false,
            isVisible: true, sortOrder: 999, usageCount: 0, isCustom: true)
        let search = SearchViewModel()
        search.selectedRegion = .international
        search.selectedPlatform = platform
        let container = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ResultsHost(onlyWhenSearching: true)
            .environmentObject(search).environmentObject(tabs)
            .environmentObject(LanguageManager.shared).modelContainer(container))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            model.releaseWebViewRuntime(); previous?.makeKeyAndVisible()
        }
        for attempt in 1...2 {
            search.searchText = "query \(attempt)"
            search.performSearch()
            for _ in 0..<120 {
                if model.isWebViewRuntimeInstalled, !model.isLoading, web.loads >= attempt { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(model.webView === web)
            XCTAssertEqual(web.loads, attempt, "One submission must issue exactly one navigation")
            var updated = platform
            updated.usageCount = attempt
            search.selectedPlatform = updated
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(web.loads, attempt, "Usage statistics must not cancel and restart a search")
            search.clearSearch()
            for _ in 0..<80 {
                if !model.isWebViewRuntimeInstalled { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(model.webView === web, "Returning home must retain the existing web view")
        }
        window.isHidden = true; window.rootViewController = nil
        try await Task.sleep(for: .milliseconds(150))
        withExtendedLifetime(container) {}
    }

    func testPreparedSelectionSearchRendersWithoutRestoringAnotherPlatform() async throws {
        try await verifySelectionSearch(useHome: false)
    }

    func testSelectionFromAnOpenPageRendersAndPreservesSourcePage() async throws {
        try await verifySelectionSearch(useHome: true)
    }

    private func verifySelectionSearch(useHome: Bool) async throws {
        let defaults = UserDefaults.standard
        let keys = ["last_selected_region", "last_selected_group_id", "is_incognito"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set("international", forKey: "last_selected_region")
        defaults.set("", forKey: "last_selected_group_id")
        defaults.set(true, forKey: "is_incognito")

        let storageKey = "soulo.test.selection.\(UUID())"
        defer { defaults.removeObject(forKey: storageKey) }
        let tabs = TabManager(storageKey: storageKey)
        let original = try XCTUnwrap(tabs.activeTab)
        let originalURL = URL(string: "https://example.com/original")!
        original.webViewModel.loadURL(originalURL)

        // A deterministic result document verifies actual rendering, without
        // mistaking a new tab or its address label for a successfully loaded page.
        let html = "<html><head><title>Selection result loaded</title></head><body><p id='result'></p><script>document.getElementById('result').textContent=decodeURIComponent(location.hash.slice(1));</script></body></html>"
        let template = "data:text/html;base64,\(Data(html.utf8).base64EncodedString())#%@"
        let platform = SearchPlatform(id: UUID(), name: "Selection fixture", iconName: "globe",
            searchURLTemplate: template, homeURL: "https://example.com", region: .international,
            isBuiltIn: false, isVisible: true, sortOrder: 999, usageCount: 0, isCustom: true)
        let search = SearchViewModel()
        search.selectedRegion = .international
        search.selectedPlatform = platform
        search.searchText = "example.com/path?q=中文 & a+b"
        search.performSearch()
        search.isSelectionSearch = true
        let target = try XCTUnwrap(platform.searchURL(for: search.currentKeyword))
        let tab = tabs.createTab(url: target, keyword: search.currentKeyword, platform: platform)

        let container = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        func tearDownHost() {
            window.isHidden = true
            window.rootViewController = nil
            for tab in tabs.tabs {
                tab.webViewModel.webView?.navigationDelegate = nil
                tab.webViewModel.releaseWebViewRuntime()
            }
            previous?.makeKeyAndVisible()
        }
        defer { tearDownHost() }
        window.rootViewController = UIHostingController(rootView: ResultsHost(useHome: useHome)
            .environmentObject(search).environmentObject(tabs)
            .environmentObject(LanguageManager.shared)
            .environmentObject(ThemeManager.shared)
            .environmentObject(WallpaperManager.shared).modelContainer(container))
        window.makeKeyAndVisible()
        for _ in 0..<120 {
            if !tab.webViewModel.isLoading, tab.webViewModel.webView != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(search.selectedPlatform?.id, platform.id, "Appearing results must preserve the selection search's platform")
        // WebKit abbreviates long data URLs in its exposed URL property.
        XCTAssertEqual(tab.webViewModel.currentURL?.scheme, "data", "Saved group restoration must not replace the prepared request")
        let web = try XCTUnwrap(tab.webViewModel.webView)
        let text = try await web.evaluateJavaScript("document.getElementById('result')?.textContent || ''") as? String
        XCTAssertEqual(text, search.currentKeyword)
        XCTAssertNil(tab.webViewModel.errorMessage)
        XCTAssertEqual(tab.webViewModel.pageTitle, "Selection result loaded")
        XCTAssertEqual(tabs.tabs.count, 2)
        XCTAssertEqual(original.webViewModel.currentURL, originalURL)

        if useHome {
            let nextQuery = "second selection 中文 & a+b"
            _ = try await web.evaluateJavaScript("""
                document.getElementById('result').textContent = '\(nextQuery.escapedForJS)';
                const range = document.createRange();
                range.selectNodeContents(document.getElementById('result'));
                getSelection().removeAllRanges(); getSelection().addRange(range);
                window.sourceMarker = 'preserved';
                """)
            SelectionWebSearch.search(in: web)
            for _ in 0..<160 {
                if tabs.tabs.count == 3, let next = tabs.activeWebViewModel?.webView, next !== web,
                   (try? await next.evaluateJavaScript("document.getElementById('result')?.textContent || ''")) as? String == nextQuery {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(tabs.tabs.count, 3)
            let next = try XCTUnwrap(tabs.activeWebViewModel?.webView)
            let nextText = try await next.evaluateJavaScript("document.getElementById('result')?.textContent || ''") as? String
            XCTAssertEqual(nextText, nextQuery)
            XCTAssertEqual(search.selectedPlatform?.id, platform.id)
            XCTAssertNil(tabs.activeWebViewModel?.errorMessage)
            XCTAssertNotNil(next.window, "The loaded result must be mounted on screen")
            XCTAssertGreaterThan(next.bounds.height, 0)
            let marker = try await web.evaluateJavaScript("window.sourceMarker") as? String
            XCTAssertEqual(marker, "preserved", "The originating page must not be reloaded")
        }
        // Flush SwiftUI's pending query/navigation updates while the temporary
        // SwiftData container is still alive, before restoring shared defaults.
        tearDownHost()
        try await Task.sleep(for: .milliseconds(150))
        withExtendedLifetime(container) {}
    }
}
