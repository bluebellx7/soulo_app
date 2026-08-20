import SwiftUI
import SwiftData
import PhotosUI
import StoreKit

struct SettingsView: View {
    private let neutralIconColor = Color(uiColor: .secondaryLabel)
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var searchVM: SearchViewModel
    @Environment(\.modelContext) private var modelContext

    @State private var selectedAppearance: String = ThemeManager.shared.appearance
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true
    @AppStorage("show_top_search_bar") private var showTopSearchBar = true
    @AppStorage(AppConstants.StorageKeys.keepFullscreenBrowsing) private var keepFullscreenBrowsing = false
    @AppStorage(AppConstants.StorageKeys.iCloudSyncEnabled) private var iCloudSyncEnabled = false
    @AppStorage(AppConstants.StorageKeys.shakeAction) private var shakeAction = BrowserShakeAction.none.rawValue
    @AppStorage(LiveActivityService.enabledKey) private var liveActivityEnabled: Bool = true
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("show_recent_searches_on_home") private var showRecentSearchesOnHome: Bool = true
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = ""
    @State private var showHomeTitleEdit = false
    @State private var showHomeSubtitleEdit = false
    @State private var editingHomeTitle = ""
    @State private var editingHomeSubtitle = ""
    @State private var showFeedback = false
    @State private var showClearCacheAlert = false
    @State private var clearingCache = false
    @State private var cacheCleared = false
    @State private var cacheSizeText: String?
    @Environment(\.requestReview) private var requestReview

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var currentLanguageName: String {
        LanguageManager.shared.currentLanguageName
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: colorScheme == .light
                        ? [
                            Color(red: 0.965, green: 0.965, blue: 0.975),
                            Color(red: 0.925, green: 0.925, blue: 0.945)
                        ]
                        : [
                            Color(uiColor: .systemBackground),
                            Color(uiColor: .secondarySystemBackground)
                        ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                List {
                    // MARK: - Platform Management
                    Section {
                        NavigationLink(destination: PlatformManagementView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_platforms"))
                            } icon: {
                                IconBadge(systemName: "square.grid.2x2.fill", color: neutralIconColor)
                            }
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_platforms"))
                    }

                    // MARK: - Appearance, Language & Background
                    Section {
                        VStack(alignment: .leading, spacing: 2) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_appearance"))
                            } icon: {
                                IconBadge(systemName: "paintbrush.fill", color: neutralIconColor)
                            }
                            .padding(.top, 2)

                            HStack(spacing: 6) {
                                ForEach(["system", "light", "dark"], id: \.self) { mode in
                                    let sel = selectedAppearance == mode
                                    let icon = mode == "system" ? "circle.lefthalf.filled" : mode == "light" ? "sun.max.fill" : "moon.fill"
                                    let name = LanguageManager.shared.localizedString("theme_\(mode)")
                                    Button {
                                        selectedAppearance = mode
                                        HapticsManager.selection()
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            ThemeManager.shared.setAppearance(mode)
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: icon)
                                                .font(.caption2)
                                            Text(name)
                                                .font(.caption2)
                                                .fontWeight(.semibold)
                                                .lineLimit(1)
                                        }
                                        .foregroundStyle(
                                            sel ? Color.accentColor : Color(uiColor: .secondaryLabel)
                                        )
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(
                                                    sel
                                                        ? Color.accentColor.opacity(0.14)
                                                        : Color(uiColor: .secondarySystemFill)
                                                )
                                        )
                                        .overlay {
                                            Capsule(style: .continuous)
                                                .stroke(
                                                    sel ? Color.accentColor.opacity(0.2) : Color.clear,
                                                    lineWidth: 0.5
                                                )
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .frame(minHeight: 34)
                                }
                            }
                            .padding(.leading, 42)
                        }
                        .padding(.vertical, 4)

                        NavigationLink(destination: LanguageSettingsView()) {
                            Label {
                                HStack {
                                    Text(LanguageManager.shared.localizedString("settings_language"))
                                    Spacer()
                                    Text(currentLanguageName)
                                        .foregroundStyle(.secondary)
                                        .font(.subheadline)
                                }
                            } icon: {
                                IconBadge(systemName: "globe", color: neutralIconColor)
                            }
                        }

                        NavigationLink(destination: WallpaperSettingsView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_wallpaper"))
                            } icon: {
                                IconBadge(systemName: "photo.fill", color: neutralIconColor)
                            }
                        }

                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_appearance"))
                    }

                    // MARK: - Home
                    Section {
                        Button { showHomeTitleEdit = true } label: {
                            SettingsDetailActionLabel(
                                icon: "pencil.line",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("edit_title"),
                                description: LanguageManager.shared.localizedString(
                                    "home_title_edit_desc"
                                ),
                                detail: homeTitle.isEmpty
                                    ? LanguageManager.shared.localizedString("none")
                                    : homeTitle
                            )
                        }
                        .buttonStyle(.plain)

                        Button { showHomeSubtitleEdit = true } label: {
                            SettingsDetailActionLabel(
                                icon: "text.alignleft",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("edit_subtitle"),
                                description: LanguageManager.shared.localizedString(
                                    "home_subtitle_edit_desc"
                                ),
                                detail: homeSubtitle.isEmpty
                                    ? LanguageManager.shared.localizedString("none")
                                    : homeSubtitle
                            )
                        }
                        .buttonStyle(.plain)

                        Toggle(isOn: $showBookmarksOnHome) {
                            SettingsDescriptionLabel(
                                icon: "bookmark.fill",
                                color: showBookmarksOnHome ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("show_bookmarks_home"),
                                description: LanguageManager.shared.localizedString("show_bookmarks_home_desc")
                            )
                        }
                        .tint(.blue)

                        Toggle(isOn: $showGroupPickerOnHome) {
                            SettingsDescriptionLabel(
                                icon: "folder.fill",
                                color: showGroupPickerOnHome ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("show_group_picker_home"),
                                description: LanguageManager.shared.localizedString("show_group_picker_home_desc")
                            )
                        }
                        .tint(.blue)

                        Toggle(isOn: $showRecentSearchesOnHome) {
                            SettingsDescriptionLabel(
                                icon: "clock.arrow.circlepath",
                                color: showRecentSearchesOnHome ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("show_recent_searches_home"),
                                description: LanguageManager.shared.localizedString("show_recent_searches_home_desc")
                            )
                        }
                        .tint(.blue)

                        Toggle(isOn: $liveActivityEnabled) {
                            SettingsDescriptionLabel(
                                icon: "dot.radiowaves.left.and.right",
                                color: liveActivityEnabled ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("live_activity"),
                                description: LanguageManager.shared.localizedString("live_activity_desc")
                            )
                        }
                        .tint(.blue)
                        .onChange(of: liveActivityEnabled) { _, enabled in
                            LiveActivityService.shared.setEnabled(enabled)
                        }

                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("home_screen"))
                    }

                    // MARK: - Browsing
                    Section {
                        Toggle(isOn: $showTopSearchBar) {
                            SettingsDescriptionLabel(
                                icon: "rectangle.topthird.inset.filled",
                                color: showTopSearchBar ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("show_top_search_bar"),
                                description: LanguageManager.shared.localizedString("show_top_search_bar_desc")
                            )
                        }
                        .tint(.blue)

                        Toggle(isOn: $keepFullscreenBrowsing) {
                            SettingsDescriptionLabel(
                                icon: "arrow.up.left.and.arrow.down.right",
                                color: keepFullscreenBrowsing ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("keep_fullscreen_browsing"),
                                description: LanguageManager.shared.localizedString("keep_fullscreen_browsing_desc")
                            )
                        }
                        .tint(.blue)

                        NavigationLink(destination: WebAppearanceSettingsView()) {
                            SettingsNavigationLabel(
                                icon: "circle.lefthalf.filled",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("web_appearance")
                            )
                        }

                        NavigationLink(destination: ShakeActionSettingsView()) {
                            HStack(alignment: .top, spacing: 12) {
                                IconBadge(systemName: "iphone.radiowaves.left.and.right", color: neutralIconColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(LanguageManager.shared.localizedString("shake_action"))
                                    Text(
                                        LanguageManager.shared.localizedString(
                                            BrowserShakeAction(rawValue: shakeAction)?.titleKey
                                                ?? BrowserShakeAction.none.titleKey
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.top, 2)
                            }
                        }

                        NavigationLink(destination: BrowserToolbarSettingsView()) {
                            SettingsNavigationLabel(
                                icon: "slider.horizontal.3",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("toolbar_customize")
                            )
                        }

                        Toggle(isOn: $adBlockEnabled) {
                            SettingsDescriptionLabel(
                                icon: adBlockEnabled ? "shield.checkered" : "shield.slash",
                                color: adBlockEnabled ? .green : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("ad_block"),
                                description: LanguageManager.shared.localizedString("ad_block_desc")
                            )
                        }
                        .tint(.green)

                        NavigationLink(destination: AdBlockManagementView(currentHost: nil)) {
                            SettingsNavigationLabel(
                                icon: "shield.lefthalf.filled",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("ad_block_management")
                            )
                        }

                        NavigationLink(destination: PrivacySettingsView()) {
                            SettingsNavigationLabel(
                                icon: "hand.raised.fill",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("settings_privacy")
                            )
                        }

                        NavigationLink(destination: ExtensionCenterView(onOpenInBrowser: { url in
                            tabManager.activeWebViewModel?.loadURL(url)
                            searchVM.isSearching = true
                            dismiss()
                        })) {
                            SettingsNavigationLabel(
                                icon: "puzzlepiece.extension.fill",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("userscripts")
                            )
                        }

                        CacheActionRow(
                            icon: "internaldrive.fill",
                            title: LanguageManager.shared.localizedString("privacy_clear_cache"),
                            description: LanguageManager.shared.localizedString("privacy_clear_cache_desc"),
                            detail: cacheSizeText,
                            isLoading: clearingCache,
                            isCompleted: cacheCleared
                        ) {
                            showClearCacheAlert = true
                        }
                        .alert(
                            LanguageManager.shared.localizedString("privacy_clear_cache_confirm_title"),
                            isPresented: $showClearCacheAlert
                        ) {
                            Button(
                                LanguageManager.shared.localizedString("privacy_clear_action"),
                                role: .destructive
                            ) {
                                clearBrowserCache()
                            }
                            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                        } message: {
                            Text(LanguageManager.shared.localizedString("privacy_clear_cache_confirm_message"))
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("browsing"))
                    }

                    // MARK: - Sync
                    Section {
                        Toggle(isOn: $iCloudSyncEnabled) {
                            SettingsDescriptionLabel(
                                icon: "icloud.fill",
                                color: iCloudSyncEnabled ? .blue : Color(uiColor: .systemGray3),
                                title: LanguageManager.shared.localizedString("icloud_settings_sync"),
                                description: LanguageManager.shared.localizedString("icloud_settings_sync_desc")
                            )
                        }
                        .tint(.blue)
                        .onChange(of: iCloudSyncEnabled) { _, enabled in
                            CloudSyncService.shared.setEnabled(enabled)
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_sync"))
                    }

                    // MARK: - About & Support
                    Section {
                        Button { requestReview() } label: {
                            SettingsActionLabel(
                                icon: "star.bubble.fill",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("settings_rate")
                            )
                        }
                        .buttonStyle(.plain)

                        Button { showFeedback = true } label: {
                            SettingsActionLabel(
                                icon: "envelope.fill",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("settings_feedback")
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            HelpCenterView()
                        } label: {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_help"))
                            } icon: {
                                IconBadge(systemName: "questionmark.circle.fill", color: neutralIconColor)
                            }
                        }

                        NavigationLink(destination: PrivacyPolicyView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_privacy_policy"))
                            } icon: {
                                IconBadge(systemName: "doc.text.fill", color: neutralIconColor)
                            }
                        }

                        NavigationLink(destination: TermsOfServiceView()) {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_terms"))
                            } icon: {
                                IconBadge(systemName: "checkmark.seal.fill", color: neutralIconColor)
                            }
                        }

                        HStack {
                            Label {
                                Text(LanguageManager.shared.localizedString("settings_version"))
                            } icon: {
                                IconBadge(systemName: "info.circle.fill", color: neutralIconColor)
                            }
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                                .font(.subheadline)
                                .monospacedDigit()
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_about_support"))
                    } footer: {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Soulo")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                Text("Made with \u{2764}\u{FE0F}")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(LanguageManager.shared.localizedString("settings_title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .alert(LanguageManager.shared.localizedString("edit_title"), isPresented: $showHomeTitleEdit) {
                TextField("Soulo", text: $editingHomeTitle)
                Button(LanguageManager.shared.localizedString("save")) {
                    homeTitle = editingHomeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            }
            .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showHomeSubtitleEdit) {
                TextField("", text: $editingHomeSubtitle)
                Button(LanguageManager.shared.localizedString("save")) {
                    homeSubtitle = editingHomeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            }
            .onAppear {
                editingHomeTitle = homeTitle
                editingHomeSubtitle = homeSubtitle
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackView()
            }
            .task {
                await refreshCacheSize()
            }
            // Appearance controlled by UIKit via ThemeManager.applyAppearance()
        }
    }

    private func clearBrowserCache() {
        clearingCache = true
        Task {
            await BrowserCacheService.clear(
                tabManager: tabManager,
                historyContext: modelContext
            )
            clearingCache = false
            cacheSizeText = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                cacheCleared = true
            }
        }
    }

    private func refreshCacheSize() async {
        let byteCount = await BrowserCacheService.currentSizeInBytes()
        cacheSizeText = BrowserCacheService.formattedSize(byteCount)
    }
}

// MARK: - Shared Sub-views

struct IconBadge: View {
    let systemName: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color.opacity(0.12))
                .frame(width: 30, height: 30)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(color.opacity(0.08), lineWidth: 0.5)
                }
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18, alignment: .center)
        }
        .frame(width: 32, height: 32, alignment: .top)
    }
}

struct SettingsNavigationLabel: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: icon, color: color)
            Text(title)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 3)
        }
        .padding(.vertical, 1)
    }
}

struct SettingsActionLabel: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(systemName: icon, color: color)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
    }
}

struct SettingsDetailActionLabel: View {
    let icon: String
    let color: Color
    let title: String
    let description: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: icon, color: color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 96, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct SettingsDescriptionLabel: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: icon, color: color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

// MARK: - Identifiable Image Wrapper

struct IdentifiableImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

#Preview {
    SettingsView()
}
