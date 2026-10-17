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
    var lastAccessedAt = Date()

    init(id: UUID = UUID(), keyword: String? = nil, platform: SearchPlatform? = nil) {
        self.id = id
        let webViewModel = WebViewModel()
        webViewModel.configureSnapshotPersistence(id: id)
        self.webViewModel = webViewModel
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
    let pageTitle: String?
}

private struct SavedState: Codable {
    let tabs: [SavedTab]
    let activeIndex: Int
    let savedAt: Date?
}

// MARK: - TabManager

@MainActor
final class TabManager: ObservableObject {

    // MARK: - Published State

    @Published var tabs: [BrowserTab] = [] {
        didSet { synchronizePersistenceObservers() }
    }
    @Published var activeTabIndex: Int = 0
    @Published var showTabOverview: Bool = false
    @Published var recentlyClosed: [RecentlyClosedTab] = []

    private weak var findWebView: WKWebView?

    // Desktop mode is a browser preference; individual sites may additionally require it.
    @Published var desktopModeTabs: Set<UUID> = []
    @Published private(set) var prefersDesktopMode = false

    static let maxRecentlyClosed = 10
    /// Retain recent tabs, independent of their position in the tab bar.
    /// Older tabs keep their URL, snapshot and media checkpoint without WebKit.
    static let maxAliveTabs = ProcessInfo.processInfo.physicalMemory >= 4 * 1_024 * 1_024 * 1_024 ? 8 : 5
    private var memoryWarningObserver: AnyCancellable?
    private var desktopModeObserver: AnyCancellable?
    private var recentTabIDs: [UUID] = []
    private var saveTask: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?
    private var persistenceObservers: [UUID: AnyCancellable] = [:]

    private let storageKey: String
    private let desktopModeStorageKey: String
    private var isPrivateSession = UserDefaults.standard.bool(forKey: "is_incognito")

    // MARK: - Init

    init(storageKey: String = "soulo_saved_tabs") {
        self.storageKey = storageKey
        desktopModeStorageKey = storageKey.hasPrefix("soulo_saved_tabs")
            ? "soulo_desktop_mode"
            : "\(storageKey).desktop_mode"
        prefersDesktopMode = UserDefaults.standard.bool(forKey: desktopModeStorageKey)
        if storageKey != "soulo_saved_tabs",
           UserDefaults.standard.data(forKey: storageKey) == nil,
           let legacy = UserDefaults.standard.data(forKey: "soulo_saved_tabs") {
            UserDefaults.standard.set(legacy, forKey: storageKey)
            UserDefaults.standard.removeObject(forKey: "soulo_saved_tabs")
        }
        memoryWarningObserver = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.releaseInactiveTabsForMemoryPressure() }
            }
        desktopModeObserver = NotificationCenter.default.publisher(for: .souloDesktopModeChanged)
            .sink { [weak self] _ in
                Task { @MainActor in self?.synchronizeDesktopMode() }
            }
        backgroundObserver = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.activeWebViewModel?.takeSnapshot()
                    self?.saveToDisk()
                }
            }
        restoreFromDisk()
        if tabs.isEmpty {
            createTab()
        }
        manageTabLifecycles()
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
        activeWebViewModel?.isDesktopModeEnabled ?? prefersDesktopMode
    }

    // MARK: - Snapshots

    func refreshSnapshotsForSwitcher() {
        // Background pages retain their last snapshot; no simultaneous WebKit
        // captures across every warm tab when opening the switcher.
        activeWebViewModel?.takeSnapshot()
        saveToDisk()
    }

    // MARK: - Tab Creation

    /// Home begins a separate browsing task unless the active tab is still empty.
    func prepareTabForHomeSearch() -> BrowserTab? {
        if let tab = activeTab,
           tab.webViewModel.currentURL == nil,
           tab.suspendedURL == nil,
           tab.keyword?.isEmpty != false {
            return tab
        }

        activeWebViewModel?.takeSnapshot()
        dismissFindInPage()
        return createTab()
    }

    @discardableResult
    func createTab(url: URL? = nil, keyword: String? = nil, platform: SearchPlatform? = nil, switchTo: Bool = true) -> BrowserTab {
        var tab = BrowserTab(keyword: keyword, platform: platform)
        if switchTo {
            activeWebViewModel?.takeSnapshot()
            dismissFindInPage()
        }
        tab.webViewModel.setDesktopModeEnabled(prefersDesktopMode)
        if !switchTo {
            tab.lastAccessedAt = .distantPast
            tab.isAlive = false
        }
        tabs.append(tab)

        if switchTo {
            activeTabIndex = tabs.count - 1
        }
        manageTabLifecycles()

        if let url = url {
            tab.webViewModel.loadURL(url)
        }

        scheduleSaveToDisk()
        return tab
    }

    /// Cancel the held navigation and open its address in a separate tab.
    @discardableResult
    func openDomainNavigationInNewTab(from source: WebViewModel, confirmationID: UUID) -> Bool {
        guard let confirmation = source.domainNavigationConfirmation,
              confirmation.id == confirmationID else { return false }
        let request = confirmation.requestForNewTab
        source.resolveDomainNavigationConfirmation(id: confirmationID, allowed: false)
        createTab().webViewModel.loadRequest(request)
        return true
    }

    // MARK: - Tab Closing

    func closeTab(at index: Int, animated: Bool = true) {
        guard tabs.indices.contains(index) else { return }
        if index == activeTabIndex { dismissFindInPage() }
        let tab = tabs[index]
        unregisterWebExtensionTab(tab)
        tab.webViewModel.releaseWebViewRuntime()
        tab.webViewModel.deletePersistedSnapshot()

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
        recentTabIDs.removeAll { $0 == tab.id }
        tabs.remove(at: index)

        if tabs.isEmpty {
            createTab()
        } else if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }

        manageTabLifecycles()
        scheduleSaveToDisk()
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTab(at: index)
    }

    func closeAllTabs() {
        closeAllTabs(addingToRecentlyClosed: true)
    }

    /// All windows share the browsing-mode preference. Reconcile each window
    /// once so a private search can never reuse a persistent WKWebView.
    @discardableResult
    func synchronizePrivacyMode() -> Bool {
        let isPrivate = UserDefaults.standard.bool(forKey: "is_incognito")
        guard isPrivate != isPrivateSession else { return false }
        resetTabsForPrivacy()
        return true
    }

    func resetTabsForPrivacy() {
        isPrivateSession = UserDefaults.standard.bool(forKey: "is_incognito")
        closeAllTabs(addingToRecentlyClosed: false)
        recentlyClosed.removeAll()
        WebViewModel.deleteAllPersistedSnapshots()
        UserDefaults.standard.removeObject(forKey: storageKey)
        scheduleSaveToDisk()
    }

    private func closeAllTabs(addingToRecentlyClosed: Bool) {
        for tab in tabs {
            unregisterWebExtensionTab(tab)
            tab.webViewModel.releaseWebViewRuntime()
            tab.webViewModel.deletePersistedSnapshot()
            if addingToRecentlyClosed {
                let closed = RecentlyClosedTab(
                    id: tab.id,
                    title: tab.displayTitle,
                    url: tab.webViewModel.currentURL,
                    keyword: tab.keyword,
                    platform: tab.platform,
                    closedAt: Date()
                )
                recentlyClosed.insert(closed, at: 0)
            }
        }
        if addingToRecentlyClosed, recentlyClosed.count > Self.maxRecentlyClosed {
            recentlyClosed = Array(recentlyClosed.prefix(Self.maxRecentlyClosed))
        }
        desktopModeTabs.removeAll()
        recentTabIDs.removeAll()
        tabs.removeAll()
        createTab()
    }

    func closeOtherTabs() {
        guard let current = activeTab else { return }
        for tab in tabs where tab.id != current.id {
            unregisterWebExtensionTab(tab)
            tab.webViewModel.releaseWebViewRuntime()
            tab.webViewModel.deletePersistedSnapshot()
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
        recentTabIDs = [current.id]
        activeTabIndex = 0
        manageTabLifecycles()
        scheduleSaveToDisk()
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
        guard index != activeTabIndex else {
            showTabOverview = false
            return
        }
        // Snapshot the tab we're leaving
        activeWebViewModel?.takeSnapshot()
        dismissFindInPage()
        activeTabIndex = index
        showTabOverview = false
        manageTabLifecycles()
        scheduleSaveToDisk()
    }

    func focusTabInSwitcher(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activeWebViewModel?.takeSnapshot()
        dismissFindInPage()
        activeTabIndex = index
        manageTabLifecycles()
        scheduleSaveToDisk()
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
        scheduleSaveToDisk()
    }

    // MARK: - Memory Management

    private func manageTabLifecycles() {
        guard tabs.indices.contains(activeTabIndex) else { return }
        tabs[activeTabIndex].lastAccessedAt = Date()
        let activeID = tabs[activeTabIndex].id
        recentTabIDs.removeAll { $0 == activeID }
        recentTabIDs.insert(activeID, at: 0)
        recentTabIDs = Array(recentTabIDs.prefix(Self.maxAliveTabs))
        let warmIDs = Set(recentTabIDs)
        let previewRange = max(0, activeTabIndex - 3)...min(tabs.count - 1, activeTabIndex + 3)
        for i in tabs.indices {
            if !previewRange.contains(i) { tabs[i].webViewModel.releaseSnapshotMemory() }
            tabs[i].webViewModel.mediaSession.setActive(i == activeTabIndex)
            if i == activeTabIndex {
                if !tabs[i].isAlive { restoreTabMemory(at: i) }
            } else if !warmIDs.contains(tabs[i].id), tabs[i].isAlive,
                      !tabs[i].webViewModel.isDownloading, tabs[i].webViewModel.activeDownloadCount == 0 {
                suspendTab(at: i)
            }
        }
    }

    func releaseInactiveTabsForMemoryPressure() {
        recentTabIDs = activeTab.map { [$0.id] } ?? []
        for i in tabs.indices where i != activeTabIndex {
            tabs[i].webViewModel.releaseSnapshotMemory()
            guard tabs[i].isAlive, !tabs[i].webViewModel.isDownloading,
                  tabs[i].webViewModel.activeDownloadCount == 0 else { continue }
            suspendTab(at: i)
        }
    }

    private func suspendTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let tabID = tabs[index].id
        let webViewModel = tabs[index].webViewModel
        unregisterWebExtensionTab(tabs[index])
        tabs[index].suspendedURL = tabs[index].webViewModel.currentURL
        tabs[index].isAlive = false
        Task { @MainActor [weak self, weak webViewModel] in
            guard let webViewModel else { return }
            await webViewModel.captureSnapshot()
            await webViewModel.mediaSession.capture()
            guard let self, let currentIndex = self.tabs.firstIndex(where: { $0.id == tabID }),
                  !self.tabs[currentIndex].isAlive else { return }
            webViewModel.releaseWebViewRuntime()
        }
    }

    private func unregisterWebExtensionTab(_ tab: BrowserTab) {
        guard BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
              let webView = tab.webViewModel.webView else { return }
        if #available(iOS 18.4, *) {
            NativeWebExtensionRuntime.shared.unregister(webView)
        }
    }

    private func restoreTabMemory(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs[index].isAlive = true
        // A quick switch back can beat asynchronous checkpoint capture. Reuse
        // the original runtime in that case, rather than reloading its page.
        if let url = tabs[index].suspendedURL, tabs[index].webViewModel.webView == nil {
            let model = tabs[index].webViewModel
            model.loadCachedURL(url)
            Task { @MainActor [weak model] in
                await model?.loadSnapshotIfNeeded(forRestoration: true)
            }
        }
        tabs[index].suspendedURL = nil
    }

    // MARK: - Find in Page

    func startFindInPage() {
        dismissFindInPage()
        guard let webView = activeWebViewModel?.webView, webView.window != nil else { return }
        webView.isFindInteractionEnabled = true
        findWebView = webView
        webView.findInteraction?.searchText = ""
        webView.findInteraction?.presentFindNavigator(showingReplace: false)
    }

    func dismissFindInPage() {
        findWebView?.findInteraction?.dismissFindNavigator()
        findWebView = nil
    }

    // MARK: - Desktop Mode

    func toggleDesktopMode() {
        setDesktopModeEnabled(!prefersDesktopMode)
    }

    func setDesktopModeEnabled(_ enabled: Bool, reload: Bool = true) {
        applyDesktopMode(enabled, reload: reload)
        UserDefaults.standard.set(enabled, forKey: desktopModeStorageKey)
        NotificationCenter.default.post(name: .souloDesktopModeChanged, object: self)
    }

    func synchronizeDesktopMode() {
        let enabled = UserDefaults.standard.bool(forKey: desktopModeStorageKey)
        guard enabled != prefersDesktopMode else { return }
        applyDesktopMode(enabled, reload: true)
    }

    private func applyDesktopMode(_ enabled: Bool, reload: Bool) {
        let activeModel = activeWebViewModel
        let activeChanged = activeModel?.isDesktopModeEnabled != enabled
        prefersDesktopMode = enabled
        for tab in tabs {
            tab.webViewModel.setDesktopModeEnabled(enabled)
        }
        desktopModeTabs = enabled ? Set(tabs.map(\.id)) : []
        if reload, activeChanged, let activeModel, let url = activeModel.currentURL {
            activeModel.webView?.stopLoading()
            activeModel.loadURL(url, cachePolicy: .reloadIgnoringLocalCacheData)
        }
    }

    /// Compatibility requirements affect the next page without overwriting the user's preference.
    func setDesktopModeForCurrentNavigation(_ required: Bool) {
        guard let tab = activeTab else { return }
        let enabled = prefersDesktopMode || required
        tab.webViewModel.setDesktopModeEnabled(enabled)
        if enabled { desktopModeTabs.insert(tab.id) }
        else { desktopModeTabs.remove(tab.id) }
    }

    // MARK: - Persistence

    private func synchronizePersistenceObservers() {
        let ids = Set(tabs.map(\.id))
        persistenceObservers = persistenceObservers.filter { ids.contains($0.key) }
        for tab in tabs where persistenceObservers[tab.id] == nil {
            persistenceObservers[tab.id] = tab.webViewModel.$currentURL
                .combineLatest(tab.webViewModel.$pageTitle)
                .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    // Domain groups and home controls also depend on child
                    // metadata, including redirects that finish offscreen.
                    self?.objectWillChange.send()
                    self?.scheduleSaveToDisk()
                }
        }
    }

    /// Coalesce bursts of tab creation, closing and switching into one write.
    private func scheduleSaveToDisk() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.saveToDisk()
        }
    }

    /// Flush immediately when the app backgrounds or a caller needs a checkpoint.
    func saveToDisk() {
        saveTask?.cancel()
        saveTask = nil
        guard !UserDefaults.standard.bool(forKey: "is_incognito") else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }

        // WKWebExtension origins are scoped to the loaded extension context.
        // Persisting them across launches restores a stale, unresolvable page.
        // Keep those tabs for the current session only.
        let restorableTabs = tabs.filter { tab in
            Self.isRestorableAcrossLaunches(tab.webViewModel.currentURL ?? tab.suspendedURL)
        }
        let saved = restorableTabs.map { tab in
            SavedTab(
                id: tab.id.uuidString,
                urlString: (tab.webViewModel.currentURL ?? tab.suspendedURL)?.absoluteString,
                keyword: tab.keyword,
                platformName: tab.platform?.name,
                pageTitle: tab.webViewModel.pageTitle
            )
        }
        let restoredActiveIndex: Int
        if let activeID = activeTab?.id,
           let index = restorableTabs.firstIndex(where: { $0.id == activeID }) {
            restoredActiveIndex = index
        } else {
            let restorableBeforeActive = tabs.prefix(activeTabIndex).filter { tab in
                Self.isRestorableAcrossLaunches(tab.webViewModel.currentURL ?? tab.suspendedURL)
            }.count
            restoredActiveIndex = max(0, min(restorableBeforeActive, restorableTabs.count - 1))
        }
        let state = SavedState(tabs: saved, activeIndex: restoredActiveIndex, savedAt: Date())
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    /// Recover the last normal window when older versions generated a new
    /// default window identity on each cold launch. Other windows stay intact.
    static func mostRecentSavedWindowID(userDefaults: UserDefaults = .standard) -> UUID? {
        guard !userDefaults.bool(forKey: "is_incognito") else { return nil }
        let prefix = "soulo_saved_tabs."
        let candidates = userDefaults.dictionaryRepresentation().compactMap { key, value -> (UUID, Date, Int)? in
            guard key.hasPrefix(prefix), let id = UUID(uuidString: String(key.dropFirst(prefix.count))),
                  let data = value as? Data, let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return nil }
            let count = state.tabs.filter { tab in
                guard let url = tab.urlString.flatMap(URL.init(string:)) else { return false }
                return Self.isRestorableAcrossLaunches(url)
            }.count
            guard count > 0 else { return nil }
            return (id, state.savedAt ?? .distantPast, count)
        }
        return candidates.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.uuidString < $1.0.uuidString
        }.first?.0
    }

    /// Restore tabs from UserDefaults. Called once at init.
    private func restoreFromDisk() {
        guard !UserDefaults.standard.bool(forKey: "is_incognito") else {
            UserDefaults.standard.removeObject(forKey: storageKey)
            return
        }

        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }

        let allPlatforms = PlatformDataStore.shared.allPlatforms()

        var restoredTabs: [BrowserTab] = []
        restoredTabs.reserveCapacity(state.tabs.count)
        for saved in state.tabs {
            let restoredURL = saved.urlString.flatMap(URL.init(string:))
            guard Self.isRestorableAcrossLaunches(restoredURL) else { continue }
            let platform = saved.platformName.flatMap { name in
                allPlatforms.first { $0.name == name }
            }
            var tab = BrowserTab(
                id: UUID(uuidString: saved.id) ?? UUID(),
                keyword: saved.keyword,
                platform: platform
            )
            tab.webViewModel.setDesktopModeEnabled(prefersDesktopMode)
            tab.webViewModel.updateTitle(saved.pageTitle)
            if let url = restoredURL {
                tab.webViewModel.loadCachedURL(url)
            }
            tab.isAlive = false
            tab.suspendedURL = restoredURL
            restoredTabs.append(tab)
        }
        tabs = restoredTabs

        if state.activeIndex >= 0 && state.activeIndex < tabs.count {
            activeTabIndex = state.activeIndex
        }
    }

    private static func isRestorableAcrossLaunches(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() != "webkit-extension"
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
    static let souloDesktopModeChanged = Notification.Name("souloDesktopModeChanged")
    static let openInNewTab = Notification.Name("soulo.openInNewTab")
    static let closeUserScriptTab = Notification.Name("soulo.closeUserScriptTab")
    static let closeUserScriptCurrentTab = Notification.Name("soulo.closeUserScriptCurrentTab")
    static let focusUserScriptCurrentTab = Notification.Name("soulo.focusUserScriptCurrentTab")
    static let cancelActiveDownloads = Notification.Name("soulo.cancelActiveDownloads")
    static let linkCopied = Notification.Name("soulo.linkCopied")
    static let browserDownloadFailed = Notification.Name("soulo.browserDownloadFailed")
}
