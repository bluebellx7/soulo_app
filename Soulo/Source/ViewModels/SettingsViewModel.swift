import SwiftUI
import SwiftData
import WebKit

@MainActor
class SettingsViewModel: ObservableObject {
    @AppStorage("is_incognito") var isIncognito = false
    @AppStorage("icloud_sync_enabled") var iCloudSyncEnabled = false

    func clearSearchHistory(context: ModelContext) {
        SearchHistoryService.clearAll(context: context)
    }

    func clearBookmarks(context: ModelContext) {
        let bookmarks = BookmarkService.fetchAll(context: context)
        for bookmark in bookmarks {
            BookmarkService.delete(bookmark, context: context)
        }
    }

    func clearWebViewCache() {
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let since = Date.distantPast
        dataStore.removeData(ofTypes: dataTypes, modifiedSince: since) {}
    }

    func clearAllData(context: ModelContext) {
        clearSearchHistory(context: context)
        clearBookmarks(context: context)
        clearWebViewCache()
        PlatformDataStore.shared.resetToDefaults()
    }
}
