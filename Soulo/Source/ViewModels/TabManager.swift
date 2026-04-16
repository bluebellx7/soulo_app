import SwiftUI
import WebKit
import Combine

// MARK: - BrowserTab Model

@MainActor
struct BrowserTab: Identifiable, Equatable {
    let id: UUID
    let webViewModel: WebViewModel
    var keyword: String?
    var platform: SearchPlatform?
    var createdAt: Date
    var isAlive: Bool = true
    var suspendedURL: URL?

    init(id: UUID = UUID(), keyword: String? = nil, platform: SearchPlatform? = nil) {
        self.id = id
        self.webViewModel = WebViewModel()
        self.keyword = keyword
        self.platform = platform
        self.createdAt = Date()
    }

    nonisolated static func == (lhs: BrowserTab, rhs: BrowserTab) -> Bool {
        lhs.id == rhs.id
    }

    var displayTitle: String {
        let title = webViewModel.pageTitle
        if !title.isEmpty { return title }
        if let host = webViewModel.currentURL?.host { return host }
        if let kw = keyword, !kw.isEmpty { return kw }
        return LanguageManager.shared.localizedString("tab_new_tab")
    }

    var displayURL: String {
        webViewModel.currentURL?.host ?? ""
    }
}

// MARK: - Recently Closed Tab

struct RecentlyClosedTab: Identifiable {
    let id: UUID
    let title: String
    let url: URL?
    let keyword: String?
    let platform: SearchPlatform?
    let closedAt: Date
}

// MARK: - Persistence Model

private struct SavedTab: Codable {
    let id: String
    let urlString: String?
    let keyword: String?
    let platformName: String?
}

private struct SavedState: Codable {
    let tabs: [SavedTab]
    let activeIndex: Int
}

// MARK: - TabManager

@MainActor
final class TabManager: ObservableObject {

    // MARK: - Published State

    @Published var tabs: [BrowserTab] = []
    @Published var activeTabIndex: Int = 0
    @Published var showTabOverview: Bool = false
    @Published var recentlyClosed: [RecentlyClosedTab] = []

    // Find in Page
    @Published var showFindInPage: Bool = false
    @Published var findText: String = ""
    @Published var findMatchCount: Int = 0

    // Desktop Mode (per-tab tracking)
    @Published var desktopModeTabs: Set<UUID> = []

    static let maxTabs = 20
    static let maxRecentlyClosed = 10
    static let aliveWindow = 2

    private static let storageKey = "soulo_saved_tabs"

    // MARK: - Init

    init() {
        restoreFromDisk()
        if tabs.isEmpty {
            createTab()
        }
    }

    // MARK: - Computed

    var activeTab: BrowserTab? {
        guard tabs.indices.contains(activeTabIndex) else { return nil }
        return tabs[activeTabIndex]
    }

    var activeWebViewModel: WebViewModel? {
        activeTab?.webViewModel
    }

    var tabCount: Int { tabs.count }

    var isDesktopMode: Bool {
        guard let tab = activeTab else { return false }
        return desktopModeTabs.contains(tab.id)
    }

    // MARK: - Tab Creation

    @discardableResult
    func createTab(url: URL? = nil, keyword: String? = nil, platform: SearchPlatform? = nil, switchTo: Bool = true) -> BrowserTab {
        let tab = BrowserTab(keyword: keyword, platform: platform)

        if tabs.count >= Self.maxTabs {
            // Evict the oldest non-active tab by creation date
            let oldestIndex = tabs.indices
                .filter { $0 != activeTabIndex }
                .min(by: { tabs[$0].createdAt < tabs[$1].createdAt }) ?? 0
            closeTab(at: oldestIndex, animated: false)
        }

        tabs.append(tab)

        if switchTo {
            activeTabIndex = tabs.count - 1
            manageTabLifecycles()
        }

        if let url = url {
            tab.webViewModel.loadURL(url)
        }

        saveToDisk()
        return tab
    }

    // MARK: - Tab Closing

    func closeTab(at index: Int, animated: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        let tab = tabs[index]

        let closed = RecentlyClosedTab(
            id: tab.id,
            title: tab.displayTitle,
            url: tab.webViewModel.currentURL,
            keyword: tab.keyword,
            platform: tab.platform,
            closedAt: Date()
        )
        recentlyClosed.insert(closed, at: 0)
        if recentlyClosed.count > Self.maxRecentlyClosed {
            recentlyClosed = Array(recentlyClosed.prefix(Self.maxRecentlyClosed))
        }

        desktopModeTabs.remove(tab.id)
        tabs.remove(at: index)

        if tabs.isEmpty {
            createTab()
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        manageTabLifecycles()
        saveToDisk()
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index)
    }

    func closeAllTabs() {
        for tab in tabs {
            let closed = RecentlyClosedTab(
                id: tab.id, title: tab.displayTitle,
                url: tab.webViewModel.currentURL,
                keyword: tab.keyword, platform: tab.platform, closedAt: Date()
            )
            recentlyClosed.insert(closed, at: 0)
        }
        if recentlyClosed.count > Self.maxRecentlyClosed {
            recentlyClosed = Array(recentlyClosed.prefix(Self.maxRecentlyClosed))
        }
        desktopModeTabs.removeAll()
        tabs.removeAll()
        createTab()
    }

    func closeOtherTabs() {
        guard let current = activeTab else { return }
        for tab in tabs where tab.id != current.id {
            let closed = RecentlyClosedTab(
                id: tab.id, title: tab.displayTitle,
                url: tab.webViewModel.currentURL,
                keyword: tab.keyword, platform: tab.platform, closedAt: Date()
            )
            recentlyClosed.insert(closed, at: 0)
            desktopModeTabs.remove(tab.id)
        }
        if recentlyClosed.count > Self.maxRecentlyClosed {
            recentlyClosed = Array(recentlyClosed.prefix(Self.maxRecentlyClosed))
        }
        tabs = [current]
        activeTabIndex = 0
        manageTabLifecycles()
        saveToDisk()
    }

    // MARK: - Restore Closed Tab

    func restoreClosedTab(_ closed: RecentlyClosedTab) {
        recentlyClosed.removeAll { $0.id == closed.id }
        createTab(url: closed.url, keyword: closed.keyword, platform: closed.platform)
    }

    func restoreLastClosedTab() {
        guard let last = recentlyClosed.first else { return }
        restoreClosedTab(last)
    }

    // MARK: - Tab Switching

    func switchToTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        // Snapshot the tab we're leaving
        activeWebViewModel?.takeSnapshot()
        activeTabIndex = index
        showTabOverview = false
        dismissFindInPage()
        manageTabLifecycles()
        saveToDisk()
    }

    func switchToTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switchToTab(at: index)
    }

    func switchToNextTab() {
        let next = (activeTabIndex + 1) % tabs.count
        switchToTab(at: next)
    }

    func switchToPreviousTab() {
        let prev = activeTabIndex > 0 ? activeTabIndex - 1 : tabs.count - 1
        switchToTab(at: prev)
    }

    // MARK: - Tab Reordering

    func moveTab(from source: IndexSet, to destination: Int) {
        guard let currentID = activeTab?.id else { return }
        tabs.move(fromOffsets: source, toOffset: destination)
        if let newIndex = tabs.firstIndex(where: { $0.id == currentID }) {
            activeTabIndex = newIndex
        }
        saveToDisk()
    }

    // MARK: - Memory Management

    private func manageTabLifecycles() {
        guard tabs.count > Self.aliveWindow * 2 + 1 else {
            for i in tabs.indices where !tabs[i].isAlive {
                restoreTabMemory(at: i)
            }
            return
        }

        let active = activeTabIndex
        let lo = max(0, active - Self.aliveWindow)
        let hi = min(tabs.count - 1, active + Self.aliveWindow)

        for i in tabs.indices {
            if (lo...hi).contains(i) {
                if !tabs[i].isAlive { restoreTabMemory(at: i) }
            } else {
                if tabs[i].isAlive { suspendTab(at: i) }
            }
        }
    }

    private func suspendTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].suspendedURL = tabs[index].webViewModel.currentURL
        tabs[index].webViewModel.webView?.stopLoading()
        tabs[index].webViewModel.webView?.loadHTMLString("", baseURL: nil)
        tabs[index].isAlive = false
    }

    private func restoreTabMemory(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isAlive = true
        if let url = tabs[index].suspendedURL {
            tabs[index].webViewModel.loadURL(url)
            tabs[index].suspendedURL = nil
        }
    }

    // MARK: - Find in Page

    func startFindInPage() {
        showFindInPage = true
        findText = ""
        findMatchCount = 0
    }

    func dismissFindInPage() {
        showFindInPage = false
        findText = ""
        findMatchCount = 0
        activeWebViewModel?.webView?.evaluateJavaScript(
            "window.getSelection().removeAllRanges();", completionHandler: nil
        )
    }

    func findNext() {
        guard !findText.isEmpty else { return }
        activeWebViewModel?.webView?.evaluateJavaScript(
            "window.find('\(findText.escapedForJS)', false, false, true)"
        ) { [weak self] _, _ in
            self?.updateFindCount()
        }
    }

    func findPrevious() {
        guard !findText.isEmpty else { return }
        activeWebViewModel?.webView?.evaluateJavaScript(
            "window.find('\(findText.escapedForJS)', false, true, true)"
        ) { [weak self] _, _ in
            self?.updateFindCount()
        }
    }

    func performFind() {
        guard !findText.isEmpty else {
            findMatchCount = 0
            return
        }
        updateFindCount()
        findNext()
    }

    private func updateFindCount() {
        guard !findText.isEmpty else { return }
        let js = """
        (function() {
            var text = '\(findText.escapedForJS)';
            var body = document.body.innerText || '';
            var regex = new RegExp(text.replace(/[.*+?^${}()|[\\]\\\\]/g, '\\\\$&'), 'gi');
            var matches = body.match(regex);
            return matches ? matches.length : 0;
        })()
        """
        activeWebViewModel?.webView?.evaluateJavaScript(js) { [weak self] result, _ in
            Task { @MainActor in
                self?.findMatchCount = (result as? Int) ?? 0
            }
        }
    }

    // MARK: - Desktop Mode

    func toggleDesktopMode() {
        guard let tab = activeTab, let webView = tab.webViewModel.webView else { return }

        if desktopModeTabs.contains(tab.id) {
            desktopModeTabs.remove(tab.id)
            webView.customUserAgent = AppConstants.webViewUserAgent
        } else {
            desktopModeTabs.insert(tab.id)
            webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        }
        webView.reload()
    }

    // MARK: - Persistence

    /// Save current tab state to UserDefaults.
    func saveToDisk() {
        let saved = tabs.map { tab in
            SavedTab(
                id: tab.id.uuidString,
                urlString: (tab.webViewModel.currentURL ?? tab.suspendedURL)?.absoluteString,
                keyword: tab.keyword,
                platformName: tab.platform?.name
            )
        }
        let state = SavedState(tabs: saved, activeIndex: activeTabIndex)
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Restore tabs from UserDefaults. Called once at init.
    private func restoreFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }

        let allPlatforms = PlatformDataStore.shared.allPlatforms()

        for saved in state.tabs {
            let platform = saved.platformName.flatMap { name in
                allPlatforms.first { $0.name == name }
            }
            let tab = BrowserTab(
                id: UUID(uuidString: saved.id) ?? UUID(),
                keyword: saved.keyword,
                platform: platform
            )
            if let urlStr = saved.urlString, let url = URL(string: urlStr) {
                tab.webViewModel.loadURL(url)
            }
            tabs.append(tab)
        }

        if state.activeIndex >= 0 && state.activeIndex < tabs.count {
            activeTabIndex = state.activeIndex
        }
    }
}

// MARK: - String JS Escaping

extension String {
    var escapedForJS: String {
        self.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}

// MARK: - Notification for Opening New Tabs

extension Notification.Name {
    static let openInNewTab = Notification.Name("soulo.openInNewTab")
}
