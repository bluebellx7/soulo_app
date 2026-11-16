import SwiftUI

struct ProtectionPageTitle: ViewModifier {
    let embedded: Bool
    let title: String
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content }
        else { content.navigationTitle(title).navigationBarTitleDisplayMode(.inline) }
    }
}

struct ProtectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    enum Page: Int, CaseIterable {
        case ads, privacy
        @MainActor var title: String { LanguageManager.shared.localizedString(self == .ads ? "ad_block_management" : "settings_privacy") }
    }
    @State private var selection: Page
    var currentHost: String? = nil
    var showsDoneButton = false
    var currentURL: URL? = nil
    var onMarkAdvertisement: (() -> Void)? = nil
    var onChanged: (() -> Void)? = nil

    init(initialPage: Page = .ads, currentHost: String? = nil, showsDoneButton: Bool = false,
         currentURL: URL? = nil, onMarkAdvertisement: (() -> Void)? = nil, onChanged: (() -> Void)? = nil) {
        _selection = State(initialValue: initialPage)
        self.currentHost = currentHost; self.showsDoneButton = showsDoneButton; self.currentURL = currentURL
        self.onMarkAdvertisement = onMarkAdvertisement; self.onChanged = onChanged
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(ToolText.text("settings_ads_and_privacy"), selection: $selection) {
                ForEach(Page.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 20).padding(.vertical, 12)
            .accessibilityIdentifier("protection.section")
            TabView(selection: $selection) {
                AnyView(AdBlockManagementView(currentHost: currentHost,
                    currentURL: currentURL, onMarkAdvertisement: onMarkAdvertisement, onChanged: onChanged, embedded: true))
                    .tag(Page.ads)
                AnyView(PrivacySettingsView(embedded: true)).tag(Page.privacy)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(selection.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
    }
}

struct PrivacySettingsView: View {
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var searchVM: SearchViewModel

    @AppStorage("is_incognito") private var isIncognito: Bool = false
    @AppStorage("privacy_https_upgrade_enabled")
    private var httpsUpgradeEnabled = PrivacyFeatureDefaults.httpsUpgradeEnabled
    @AppStorage("privacy_strip_tracking_parameters")
    private var stripTrackingParameters = PrivacyFeatureDefaults.stripTrackingParameters
    @AppStorage("privacy_gpc_enabled")
    private var gpcEnabled = PrivacyFeatureDefaults.gpcEnabled
    @AppStorage("privacy_cookie_banner_enabled")
    private var cookieBannerEnabled = PrivacyFeatureDefaults.cookieBannerHandling

    var embedded = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(uiColor: .systemBackground),
                    Color(uiColor: .secondarySystemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            List {
                // MARK: - Incognito Mode
                Section {
                    PrivacyToggleRow(
                        icon: "eye.slash.fill",
                        color: .teal,
                        title: LanguageManager.shared.localizedString("privacy_incognito"),
                        description: LanguageManager.shared.localizedString("privacy_incognito_desc"),
                        isOn: $isIncognito
                    )
                } header: {
                    SectionHeader(
                        title: LanguageManager.shared.localizedString(
                            "privacy_section_private_browsing"
                        )
                    )
                }

                // MARK: - Browsing Protection
                Section {
                    PrivacyToggleRow(
                        icon: "lock.fill",
                        color: .green,
                        title: LanguageManager.shared.localizedString("privacy_https_upgrade"),
                        description: LanguageManager.shared.localizedString("privacy_https_upgrade_desc"),
                        isOn: $httpsUpgradeEnabled
                    )

                    PrivacyToggleRow(
                        icon: "link",
                        color: Color.themePrimary,
                        title: LanguageManager.shared.localizedString("privacy_strip_tracking"),
                        description: LanguageManager.shared.localizedString("privacy_strip_tracking_desc"),
                        isOn: $stripTrackingParameters
                    )

                    PrivacyToggleRow(
                        icon: "hand.raised.fill",
                        color: Color.themePrimary,
                        title: LanguageManager.shared.localizedString("privacy_gpc"),
                        description: LanguageManager.shared.localizedString("privacy_gpc_desc"),
                        isOn: $gpcEnabled
                    )

                    PrivacyToggleRow(
                        icon: "birthday.cake.fill",
                        color: .pink,
                        title: LanguageManager.shared.localizedString("privacy_cookie_banners"),
                        description: LanguageManager.shared.localizedString("privacy_cookie_banners_desc"),
                        isOn: $cookieBannerEnabled
                    )
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("privacy_section_browsing"))
                } footer: {
                    Text(LanguageManager.shared.localizedString("privacy_global_scope_desc"))
                }

                Section {
                    NavigationLink {
                        StorageUsageView()
                    } label: {
                        Label(FeatureText.text("Storage"), systemImage: "internaldrive")
                    }.accessibilityIdentifier("privacy.storage")
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("privacy_section_data"))
                }

            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .modifier(ProtectionPageTitle(embedded: embedded, title: LanguageManager.shared.localizedString("settings_privacy")))
        .onCompatibleChange(of: isIncognito) { _, enabled in
            let wasBrowsing = searchVM.isSearching
            let pageURL = tabManager.activeWebViewModel?.currentURL
            tabManager.resetTabsForPrivacy()
            searchVM.showClipboardPrompt = false
            LiveActivityService.shared.end()

            if wasBrowsing {
                if let pageURL {
                    tabManager.activeWebViewModel?.loadURL(pageURL)
                }
                searchVM.isSearching = true
            } else if !enabled {
                searchVM.clearSearch()
            }
        }
    }

}

struct PrivacyToggleRow: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 14) {
                IconBadge(
                    systemName: icon,
                    color: isOn ? color : Color(uiColor: .systemGray3)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            .padding(.vertical, 4)
        }
        .tint(color)
    }
}

// MARK: - Destructive Action Row

struct DestructiveActionRow: View {
    let icon: String
    let title: String
    let description: String
    let isLoading: Bool
    let isCompleted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemName: icon, color: .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)

                Spacer()

                Group {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.85)
                            .tint(.red)
                    } else if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 24, height: 24)
                .padding(.top, 3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCompleted)
        .animation(.default, value: isLoading)
    }
}

struct CacheActionRow: View {
    let icon: String
    let title: String
    let description: String
    let detail: String?
    let isLoading: Bool
    let isCompleted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                IconBadge(systemName: icon, color: Color(uiColor: .secondaryLabel))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.top, 2)

                Spacer()

                HStack(spacing: 7) {
                    if let detail, !isLoading, !isCompleted {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.85)
                            .tint(Color.themePrimary)
                    } else if isCompleted {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.green)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(minHeight: 24)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.top, 3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isCompleted)
        .animation(.default, value: isLoading)
    }
}

#Preview {
    NavigationStack {
        PrivacySettingsView()
    }
}
