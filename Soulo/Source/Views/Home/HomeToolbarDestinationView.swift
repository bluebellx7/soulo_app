import SwiftUI

/// Standalone entry pages. Content-dependent readers remain reachable through Files.
struct HomeToolbarDestinationView: View {
    let action: HomeToolbarAction
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var searchVM: SearchViewModel
    var body: some View {
        NavigationStack {
            destination
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button(ToolText.text("done")) { dismiss() } }
                }
        }
    }
    @ViewBuilder private var destination: some View {
        switch action {
        case .wallpaper: WallpaperSettingsView()
        case .help: HelpCenterView()
        case .language: LanguageSettingsView()
        case .webAppearance: WebAppearanceSettingsView()
        case .browserToolbar: BrowserToolbarSettingsView()
        case .homeToolbar: HomeToolbarSettingsView()
        case .privacy: PrivacySettingsView()
        case .adBlock: AdBlockManagementView(currentHost: nil)
        case .backups: SettingsBackupsView()
        case .quickActions: AppQuickActionSettingsView()
        case .urlSchemes: URLSchemeGuideView()
        case .shake: ShakeActionSettingsView()
        case .wifiTransfer: WiFiTransferView(directory: BookLibrary.directory)
        case .feedback: FeedbackView()
        case .version:
            AppVersionView(version: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") + " (" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") + ")")
        default: EmptyView()
        }
    }
}
