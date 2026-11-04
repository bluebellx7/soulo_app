import SwiftUI

struct AppVersionView: View {
    let version: String
    @Environment(\.colorScheme) private var colorScheme
    private let iconColor = Color(uiColor: .secondaryLabel)
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image("SouloLogo")
                        .resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .contrast(colorScheme == .light ? 1.3 : 1)
                        .brightness(colorScheme == .light ? -0.035 : 0)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                        }
                        .accessibilityLabel("Soulo Logo")
                        .accessibilityIdentifier("version.logo")
                    Text("Soulo").font(.title2.bold())
                    Text(version).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            Section {
                NavigationLink {
                    SouloWebsiteView()
                } label: {
                    SettingsNavigationLabel(icon: "globe", color: iconColor, title: ToolText.text("soulo_website"))
                }
                .accessibilityIdentifier("version.website")
                Link(destination: URL(string: "https://t.me/soulobrowser")!) {
                    HStack(spacing: 12) {
                        SettingsNavigationLabel(icon: "paperplane.fill", color: iconColor, title: ToolText.text("feedback_telegram"))
                        Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                }.accessibilityIdentifier("version.telegram")
            }.tint(.primary)
            Section {
                NavigationLink(destination: PrivacyPolicyView()) {
                    SettingsNavigationLabel(icon: "hand.raised.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_privacy_policy"))
                }.accessibilityIdentifier("version.privacy")
                NavigationLink(destination: ReadingToolsLicensesView()) {
                    SettingsNavigationLabel(icon: "text.book.closed", color: iconColor, title: ToolText.text("licenses"))
                }.accessibilityIdentifier("version.licenses")
                NavigationLink(destination: TermsOfServiceView()) {
                    SettingsNavigationLabel(icon: "doc.text.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_terms"))
                }.accessibilityIdentifier("version.terms")
            }.tint(.primary)
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_version"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SouloWebsiteView: View {
    @StateObject private var model = WebViewModel()
    @StateObject private var bookmarks = BookmarkViewModel()
    @State private var fullscreen = false
    var body: some View {
        WebViewContainer(webViewModel: model, bookmarkViewModel: bookmarks, isFullscreen: $fullscreen)
            .navigationTitle(ToolText.text("soulo_website"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if model.currentURL == nil, let url = URL(string: "https://soulo.dkluge.com") {
                    model.loadURL(url)
                }
            }
    }
}
