import Foundation
import WebKit

enum FireButtonService {
    @MainActor
    static func burn(tabManager: TabManager?, completion: @escaping () -> Void) {
        NotificationCenter.default.post(name: .cancelActiveDownloads, object: nil)
        DownloadManagerService.shared.cancelAllDownloads()
        URLSession.shared.configuration.urlCache?.removeAllCachedResponses()
        URLCache.shared.removeAllCachedResponses()

        tabManager?.closeAllTabs()
        AdBlockSettingsService.shared.resetStats()
        PrivacyProtectionService.shared.resetAllSummaries()

        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        WKWebsiteDataStore.default().removeData(ofTypes: dataTypes, modifiedSince: .distantPast) {
            DispatchQueue.main.async {
                completion()
            }
        }
    }
}
