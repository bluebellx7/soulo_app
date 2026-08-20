import CoreSpotlight
import SwiftData
import SwiftUI

private struct BrowserWindowConfiguration: Codable, Hashable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
}

@main
struct SouloApp: App {
    @UIApplicationDelegateAdaptor(SouloAppDelegate.self) private var appDelegate
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var themeManager: ThemeManager
    @StateObject private var wallpaperManager = WallpaperManager.shared

    init() {
        UserDefaults.standard.register(defaults: [AppConstants.StorageKeys.appearance: "dark"])
        let savedLanguage = UserDefaults.standard.string(
            forKey: AppConstants.StorageKeys.selectedLanguage
        )
        let language = savedLanguage.map(AppConstants.canonicalLanguageCode)
            ?? AppConstants.preferredLanguageCode()
        if savedLanguage != language {
            LanguageManager.shared.setLanguage(language)
        }
        LanguageManager.shared.appGroupID = SouloSharedConstants.appGroupIdentifier
        _themeManager = StateObject(wrappedValue: ThemeManager.shared)
    }

    var body: some Scene {
        WindowGroup(for: BrowserWindowConfiguration.self) { configuration in
            SouloWindowRoot(windowID: configuration.wrappedValue.id)
                .environmentObject(languageManager)
                .environmentObject(themeManager)
                .environmentObject(wallpaperManager)
                .environment(\.locale, languageManager.locale)
        } defaultValue: {
            BrowserWindowConfiguration()
        }
        .modelContainer(for: [SearchHistoryItem.self, BookmarkItem.self])
    }
}

private struct SouloWindowRoot: View {
    @EnvironmentObject private var languageManager: LanguageManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var wallpaperManager: WallpaperManager
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var searchVM: SearchViewModel
    @StateObject private var tabManager: TabManager
    @State private var activationTask: Task<Void, Never>?

    init(windowID: UUID) {
        _searchVM = StateObject(wrappedValue: SearchViewModel())
        _tabManager = StateObject(
            wrappedValue: TabManager(storageKey: "soulo_saved_tabs.\(windowID.uuidString)")
        )
    }

    var body: some View {
        HomeView()
            .environmentObject(searchVM)
            .environmentObject(tabManager)
            .task {
                CloudSyncService.shared.startIfEnabled()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    handlePendingSharedAction()
                    AppQuickActionService.shared.configureShortcuts()
                    applyWebAppearanceToOpenTabs()
                    schedulePostActivationWork()
                } else if newPhase == .background {
                    activationTask?.cancel()
                    LiveActivityService.shared.end()
                    tabManager.saveToDisk()
                }
            }
            .onChange(of: themeManager.appearance) { _, _ in
                applyWebAppearanceToOpenTabs()
            }
            .onOpenURL { url in
                if url.scheme == "soulo" && url.host == "action" {
                    handlePendingSharedAction()
                } else if url.scheme == "soulo" && url.host == "search" {
                    searchVM.clearSearch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .souloSharedActionRequested)) { _ in
                handlePendingSharedAction()
            }
            .onContinueUserActivity(CSSearchableItemActionType) { activity in
                guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                if identifier.hasPrefix("search-history-"), let keyword = activity.contentAttributeSet?.title {
                    searchVM.searchText = keyword
                    searchVM.performSearch()
                } else if identifier.hasPrefix("bookmark-"), let url = activity.contentAttributeSet?.contentDescription {
                    searchVM.searchText = url
                    searchVM.performSearch()
                }
            }
    }

    @MainActor
    private func handlePendingSharedAction() {
        guard let action = SouloSharedAction.consume() else { return }
        let suppliedText = action.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action.kind {
        case .openHome:
            searchVM.clearSearch()
        case .openDownloads:
            NotificationCenter.default.post(name: .openSouloDownloads, object: nil)
        case .privateSearch:
            searchVM.isIncognito = true
            searchVM.clearSearch()
            if let suppliedText, !suppliedText.isEmpty {
                searchVM.searchText = suppliedText
                searchVM.performSearch()
            }
        case .search:
            let value = suppliedText.flatMap { $0.isEmpty ? nil : $0 }
                ?? UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            searchVM.isIncognito = false
            if let value, !value.isEmpty {
                searchVM.performIntentSearch(query: value, platformName: action.platformName)
            } else {
                searchVM.clearSearch()
            }
        }
    }

    @MainActor
    private func schedulePostActivationWork() {
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            searchVM.detectClipboard()
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            wallpaperManager.refreshIfNeededAfterForeground()
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, !searchVM.isSearching else { return }
            LiveActivityService.shared.cleanupStaleActivities()
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            WebViewRepresentable.preWarm()
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await AdBlockSubscriptionService.shared.updateEnabledSubscriptionsIfNeeded()
        }
    }

    @MainActor
    private func applyWebAppearanceToOpenTabs() {
        for tab in tabManager.tabs {
            if let webView = tab.webViewModel.webView { WebAppearanceService.shared.apply(to: webView) }
        }
    }
}

extension Notification.Name {
    static let openSouloDownloads = Notification.Name("soulo.openDownloads")
}
