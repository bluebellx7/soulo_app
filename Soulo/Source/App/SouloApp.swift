import SwiftUI
import SwiftData
import CoreSpotlight

@main
struct SouloApp: App {
    @StateObject private var languageManager = LanguageManager.shared
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var searchVM = SearchViewModel()
    @StateObject private var wallpaperVM = BingWallpaperService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(languageManager)
                .environmentObject(themeManager)
                .environmentObject(searchVM)
                .environmentObject(wallpaperVM)
                .environment(\.locale, languageManager.locale)
                .preferredColorScheme(themeManager.preferredColorScheme)
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        searchVM.detectClipboard()
                        // Clean up leftover Live Activities from previous sessions
                        if !searchVM.isSearching {
                            LiveActivityService.shared.cleanupStaleActivities()
                        }
                    } else if newPhase == .background {
                        // End Live Activity when app goes to background
                        LiveActivityService.shared.end()
                    }
                }
                // Handle URL scheme (soulo://search from widget)
                .onOpenURL { url in
                    if url.scheme == "soulo" && url.host == "search" {
                        searchVM.clearSearch()
                    }
                }
                // F1: Handle Siri intent notifications
                .onReceive(NotificationCenter.default.publisher(for: .souloSearchFromIntent)) { notification in
                    let query = notification.userInfo?["query"] as? String ?? ""
                    let platform = notification.userInfo?["platform"] as? String
                    if !query.isEmpty {
                        searchVM.performIntentSearch(query: query, platformName: platform)
                    }
                }
                // F2: Handle Spotlight continuation
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    if identifier.hasPrefix("search-history-") {
                        // Re-run the search — we need to find the keyword from history
                        // The keyword is stored in the activity's content attribute
                        if let keyword = activity.contentAttributeSet?.title {
                            searchVM.searchText = keyword
                            searchVM.performSearch()
                        }
                    } else if identifier.hasPrefix("bookmark-") {
                        if let url = activity.contentAttributeSet?.contentDescription {
                            searchVM.searchText = url
                            searchVM.performSearch()
                        }
                    }
                }
        }
        .modelContainer(for: [SearchHistoryItem.self, BookmarkItem.self])
    }

}
