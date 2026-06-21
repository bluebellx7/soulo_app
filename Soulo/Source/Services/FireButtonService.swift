import Foundation
import WebKit

enum FireButtonService {
    @MainActor
    static func burn(tabManager: TabManager?, completion: @escaping () -> Void) {
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
