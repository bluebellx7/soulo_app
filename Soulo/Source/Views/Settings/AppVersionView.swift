import SwiftUI

struct AppVersionView: View {
    let version: String
    private let iconColor = Color(uiColor: .secondaryLabel)
    @State private var showFeedback = false
    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    ToolIllustration(scene: .about, height: 180)
                    Text("Soulo").font(.title2.bold())
                    Text(version).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 20)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                SettingsSubpageLink {
                    SouloWebsiteView()
                } label: {
                    SettingsNavigationLabel(icon: "globe", color: iconColor, title: ToolText.text("soulo_website"))
                }
                .accessibilityIdentifier("version.website")
            }.tint(.primary)
            Section {
                SettingsSubpageLink { AppReviewSupportView() } label: {
                    SettingsNavigationLabel(icon: "star.bubble.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_rate"))
                }.accessibilityIdentifier("settings.rate")
                Button { showFeedback = true } label: {
                    SettingsActionLabel(icon: "envelope.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_feedback"))
                }.buttonStyle(.plain).accessibilityIdentifier("settings.feedback")
                SettingsSubpageLink { URLSchemeGuideView() } label: {
                    SettingsNavigationLabel(icon: "link", color: iconColor, title: "URL Scheme")
                }.accessibilityIdentifier("settings.url-schemes")
            }.tint(.primary)
            Section {
                SettingsSubpageLink { PrivacyPolicyView() } label: {
                    SettingsNavigationLabel(icon: "hand.raised.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_privacy_policy"))
                }.accessibilityIdentifier("version.privacy")
                SettingsSubpageLink { ReadingToolsLicensesView() } label: {
                    SettingsNavigationLabel(icon: "text.book.closed", color: iconColor, title: ToolText.text("licenses"))
                }.accessibilityIdentifier("version.licenses")
                SettingsSubpageLink { TermsOfServiceView() } label: {
                    SettingsNavigationLabel(icon: "doc.text.fill", color: iconColor, title: LanguageManager.shared.localizedString("settings_terms"))
                }.accessibilityIdentifier("version.terms")
            }.tint(.primary)
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_section_about_support"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showFeedback) { FeedbackView() }
    }
}

/// A settings destination the user opens deliberately. The App Store owns
/// rating entry; this page never selects stars or presents a system prompt.
struct AppReviewSupportView: View {
    private let reviewURL = URL(string: "https://apps.apple.com/app/id6761165330?action=write-review")!

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    ToolIllustration(scene: .review, height: 200)
                    VStack(spacing: 12) {
                        Text("Soulo").font(.title2.bold())
                        Text(LanguageManager.shared.localizedString("review_support_message"))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Link(destination: reviewURL) {
                        Label(LanguageManager.shared.localizedString("review_open_app_store"), systemImage: "arrow.up.right")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(.white)
                            .background(Color.themePrimary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LanguageManager.shared.localizedString("review_open_app_store"))
                    .accessibilityIdentifier("review.write")
                    .padding(.top, 4)
                }
                .frame(maxWidth: 340)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, geometry.size.height - 48))
                .padding(24)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(LanguageManager.shared.localizedString("settings_rate"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SouloWebsiteView: View {
    @StateObject private var model = WebViewModel()
    @StateObject private var bookmarks = BookmarkViewModel()
    @State private var fullscreen = false
    var body: some View {
        WebViewContainer(webViewModel: model, bookmarkViewModel: bookmarks, isFullscreen: $fullscreen,
                         extendsPageUnderBottomSafeArea: true)
            .navigationTitle(ToolText.text("soulo_website"))
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if model.currentURL == nil, let url = URL(string: "https://soulo.dkluge.com") {
                    model.loadURL(url)
                }
            }
    }
}
