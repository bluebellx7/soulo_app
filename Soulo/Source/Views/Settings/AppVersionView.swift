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
                NavigationLink(destination: PrivacyPolicyView()) {
                    Label { Text(LanguageManager.shared.localizedString("settings_privacy_policy")) } icon: {
                        IconBadge(systemName: "hand.raised.fill", color: iconColor)
                    }
                }.accessibilityIdentifier("version.privacy")
                NavigationLink(destination: ReadingToolsLicensesView()) {
                    Label { Text(ToolText.text("licenses")) } icon: {
                        IconBadge(systemName: "text.book.closed", color: iconColor)
                    }
                }.accessibilityIdentifier("version.licenses")
                NavigationLink(destination: TermsOfServiceView()) {
                    Label { Text(LanguageManager.shared.localizedString("settings_terms")) } icon: {
                        IconBadge(systemName: "doc.text.fill", color: iconColor)
                    }
                }.accessibilityIdentifier("version.terms")
            }.tint(.primary)
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_version"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
