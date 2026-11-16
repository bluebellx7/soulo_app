import SwiftUI
import CoreData
import PhotosUI

struct SettingsView: View {
    private let neutralIconColor = Color(uiColor: .secondaryLabel)
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var tabManager: TabManager
    @EnvironmentObject var searchVM: SearchViewModel
    @Environment(\.managedObjectContext) private var modelContext

    @State private var selectedAppearance: String = ThemeManager.shared.appearance
    @AppStorage(VideoScreenAwakeService.preferenceKey) private var keepScreenAwake = false
    @State private var settingsQuery = ""

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var currentLanguageName: String {
        LanguageManager.shared.currentLanguageName
    }

    private func setAppearance(_ mode: String) {
        selectedAppearance = mode
        HapticsManager.selection()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { ThemeManager.shared.setAppearance(mode) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.themeGroupedBg.ignoresSafeArea()

                List {
                    if isSearchingSettings && !searchEntries.isEmpty {
                        Section {
                            ForEach(searchEntries) { entry in
                                NavigationLink(value: entry.destination) {
                                    SettingsNavigationLabel(icon: entry.icon, color: neutralIconColor, title: settingsTitle(entry.key))
                                }.accessibilityIdentifier("settings." + String(describing: entry.destination))
                            }
                        }
                    }
                    if isSearchingSettings && !matchesSettings(Self.sectionSearchKeys.flatMap { $0 }) {
                        CompatibleUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "magnifyingglass")
                    }
                    // MARK: - Platform Management
                    if matchesSettings(Self.sectionSearchKeys[0]) && (!isSearchingSettings || searchEntries.isEmpty) {
                    Section {
                        NavigationLink(value: Destination.platforms) {
                            SettingsNavigationLabel(icon: "square.grid.2x2.fill", color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_platforms"))
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_platforms"))
                    }

                    }

                    // MARK: - Appearance, Language & Background
                    if matchesSettings(Self.sectionSearchKeys[1]) && (!isSearchingSettings || searchEntries.isEmpty || matchesSettings(["settings_section_appearance", "settings_appearance", "screen_keep_awake"])) {
                    Section {
                        HStack(spacing: 12) {
                            SettingsNavigationLabel(icon: "paintbrush.fill", color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_appearance"))
                            Spacer(minLength: 4)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 4) {
                                    ForEach(["system", "light", "dark"], id: \.self) { mode in
                                        Button { setAppearance(mode) } label: {
                                            Text(LanguageManager.shared.localizedString("theme_\(mode)"))
                                                .font(.caption.weight(.semibold))
                                                .fixedSize()
                                                .padding(.horizontal, 8).padding(.vertical, 7)
                                                .foregroundStyle(selectedAppearance == mode ? Color.themePrimary : .secondary)
                                                .background(selectedAppearance == mode ? Color.themePrimary.opacity(0.14) : Color(uiColor: .secondarySystemFill), in: Capsule())
                                        }.buttonStyle(.plain).frame(minHeight: 44)
                                    }
                                }.fixedSize()
                                Picker("", selection: Binding(get: { selectedAppearance }, set: setAppearance)) {
                                    ForEach(["system", "light", "dark"], id: \.self) { mode in
                                        Text(LanguageManager.shared.localizedString("theme_\(mode)")).tag(mode)
                                    }
                                }.labelsHidden().pickerStyle(.menu)
                            }
                        }

                        NavigationLink(value: Destination.language) {
                            HStack(spacing: 12) {
                                SettingsNavigationLabel(icon: "globe", color: neutralIconColor,
                                    title: LanguageManager.shared.localizedString("settings_language"))
                                Text(currentLanguageName).foregroundStyle(.secondary).font(.subheadline)
                            }
                        }

                        NavigationLink(value: Destination.wallpaper) {
                            SettingsNavigationLabel(icon: HomeToolbarAction.wallpaper.listSymbol, color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_wallpaper"))
                        }
                        .accessibilityIdentifier("settings.wallpaper")

                        Toggle(isOn: $keepScreenAwake) {
                            SettingsDescriptionLabel(icon: "sun.max.fill",
                                color: keepScreenAwake ? Color.themePrimary : Color(uiColor: .systemGray3),
                                title: ToolText.text("screen_keep_awake"), description: ToolText.text("screen_keep_awake_desc"))
                        }
                        .tint(Color.themePrimary)
                        .accessibilityIdentifier("settings.keepScreenAwake")
                        .onCompatibleChange(of: keepScreenAwake) { _, _ in
                            VideoScreenAwakeService.shared.reloadUserPreference()
                        }

                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_appearance"))
                    }

                    }

                    // MARK: - Home
                    if matchesSettings(Self.sectionSearchKeys[2]) && (!isSearchingSettings || searchEntries.isEmpty || matchesSettings(["home_screen"])) {
                    Section {
                        NavigationLink(value: Destination.homeToolbar) {
                            SettingsNavigationLabel(icon: "rectangle.split.2x2", color: neutralIconColor, title: ToolText.text("home_toolbar_customize"))
                        }.accessibilityIdentifier("settings.homeToolbar")

                        NavigationLink(value: Destination.homeDisplay) {
                            SettingsNavigationLabel(icon: "rectangle", color: neutralIconColor, title: ToolText.text("home_display_settings"))
                        }.accessibilityIdentifier("settings.homeDisplay")
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("home_screen"))
                    }

                    }

                    // MARK: - Browsing
                    if matchesSettings(Self.sectionSearchKeys[3]) && (!isSearchingSettings || searchEntries.isEmpty || matchesSettings(["browsing", "settings_default_browser"])) {
                    Section {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            SettingsActionLabel(
                                icon: "globe",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("settings_default_browser")
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.defaultBrowser")
                        .accessibilityHint(LanguageManager.shared.localizedString("settings_default_browser_hint"))

                        NavigationLink(value: Destination.browsingDisplay) {
                            SettingsNavigationLabel(icon: "rectangle.topthird.inset.filled", color: neutralIconColor, title: ToolText.text("browsing_display_settings"))
                        }.accessibilityIdentifier("settings.browsingDisplay")

                        NavigationLink(value: Destination.video) {
                            SettingsNavigationLabel(icon: "play.rectangle", color: neutralIconColor,
                                title: ToolText.text("video_settings"))
                        }
                        .accessibilityIdentifier("settings.video")

                        NavigationLink(value: Destination.interaction) {
                            SettingsNavigationLabel(icon: "hand.draw", color: neutralIconColor, title: ToolText.text("gestures_feedback_settings"))
                        }.accessibilityIdentifier("settings.interaction")

                        NavigationLink(value: Destination.toolbar) {
                            SettingsNavigationLabel(
                                icon: "slider.horizontal.3",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("toolbar_customize")
                            )
                        }

                        NavigationLink(value: Destination.adBlock) {
                            SettingsNavigationLabel(icon: "shield.lefthalf.filled", color: neutralIconColor,
                                title: ToolText.text("settings_ads_and_privacy"))
                        }.accessibilityIdentifier("settings.protection")

                        NavigationLink(value: Destination.extensions) {
                            SettingsNavigationLabel(
                                icon: "puzzlepiece.extension",
                                color: neutralIconColor,
                                title: LanguageManager.shared.localizedString("userscripts")
                            )
                        }

                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("browsing"))
                    }

                    }

                    // MARK: - Other
                    if matchesSettings(Self.sectionSearchKeys[4]) && (!isSearchingSettings || searchEntries.isEmpty || matchesSettings(["settings_other"])) {
                    Section {
                        NavigationLink(value: Destination.backups) {
                            SettingsNavigationLabel(icon: "clock.arrow.circlepath", color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_backups"))
                        }
                        .accessibilityIdentifier("settings.backups")
                        NavigationLink(value: Destination.quickActions) {
                            SettingsNavigationLabel(icon: "hand.tap", color: neutralIconColor, title: ToolText.text("quick_actions_title"))
                        }.accessibilityIdentifier("settings.quick-actions")
                        NavigationLink(value: Destination.storage) {
                            SettingsNavigationLabel(icon: "internaldrive", color: neutralIconColor, title: FeatureText.text("Storage"))
                        }.accessibilityIdentifier("settings.storage")

                    } header: {
                        SectionHeader(title: ToolText.text("settings_other"))
                    }

                    }

                    // MARK: - About & Support
                    if matchesSettings(Self.sectionSearchKeys[5]) && (!isSearchingSettings || searchEntries.isEmpty || matchesSettings(["settings_section_about_support"])) {
                    Section {
                        NavigationLink(value: Destination.version) {
                            SettingsNavigationLabel(icon: "info.circle.fill", color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_section_about_support"))
                        }.accessibilityIdentifier("settings.version")

                        NavigationLink(value: Destination.telegram) {
                            SettingsNavigationLabel(icon: "paperplane.fill", color: neutralIconColor, title: ToolText.text("feedback_telegram"))
                        }
                        .accessibilityIdentifier("settings.telegram")

                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("settings_section_about_support"))
                    } footer: {
                        HStack {
                            Spacer()
                            VStack(spacing: 4) {
                                Text("Soulo \(appVersion)")
                                    .accessibilityIdentifier("settings.footer.version")
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
                    }                    }


                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(LanguageManager.shared.localizedString("settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $settingsQuery, prompt: LanguageManager.shared.localizedString("search"))
            .navigationDestination(for: Destination.self) { [tabManager, searchVM, dismiss, appVersion] destination in
                SettingsDestinationView(destination: destination, tabManager: tabManager,
                    searchVM: searchVM, dismiss: dismiss, appVersion: appVersion)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            // Appearance controlled by UIKit via ThemeManager.applyAppearance()
        }
    }

    private struct SearchEntry: Identifiable {
        let destination: Destination
        let key: String
        let icon: String
        var id: Destination { destination }
    }
    private static let searchableEntries: [SearchEntry] = [
        .init(destination: .platforms, key: "settings_platforms", icon: "square.grid.2x2.fill"),
        .init(destination: .language, key: "settings_language", icon: "globe"),
        .init(destination: .wallpaper, key: "settings_wallpaper", icon: "photo"),
        .init(destination: .webAppearance, key: "web_appearance", icon: "circle.lefthalf.filled"),
        .init(destination: .video, key: "video_settings", icon: "play.rectangle"),
        .init(destination: .interaction, key: "gestures_feedback_settings", icon: "hand.draw"),
        .init(destination: .shake, key: "shake_action", icon: "iphone.radiowaves.left.and.right"),
        .init(destination: .gestures, key: "gesture_settings_title", icon: "hand.draw"),
        .init(destination: .feedbackPreferences, key: "feedback_settings", icon: "speaker.wave.2"),
        .init(destination: .websiteZoom, key: "page_zoom", icon: "text.magnifyingglass"),
        .init(destination: .toolbar, key: "toolbar_customize", icon: "slider.horizontal.3"),
        .init(destination: .homeDisplay, key: "home_display_settings", icon: "rectangle"),
        .init(destination: .browsingDisplay, key: "browsing_display_settings", icon: "rectangle.topthird.inset.filled"),
        .init(destination: .homeToolbar, key: "home_toolbar_customize", icon: "rectangle.split.2x2"),
        .init(destination: .adBlock, key: "settings_ads_and_privacy", icon: "shield.lefthalf.filled"),
        .init(destination: .extensions, key: "userscripts", icon: "puzzlepiece.extension"),
        .init(destination: .backups, key: "settings_backups", icon: "clock.arrow.circlepath"),
        .init(destination: .quickActions, key: "quick_actions_title", icon: "hand.tap"),
        .init(destination: .version, key: "settings_section_about_support", icon: "info.circle.fill"),
        .init(destination: .telegram, key: "feedback_telegram", icon: "paperplane.fill"),
        .init(destination: .storage, key: "Storage", icon: "internaldrive")
    ]
    private var isSearchingSettings: Bool { !settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var searchEntries: [SearchEntry] {
        Self.searchableEntries.filter { entry in
            let aliases: [String]
            switch entry.destination {
            case .adBlock: aliases = ["ad_block_management", "settings_privacy"]
            case .storage: aliases = ["privacy_section_data", "privacy_clear_cache", "privacy_clear_history", "privacy_clear_bookmarks", "privacy_clear_browsing_on_exit"]
            case .gestures: aliases = ["gesture_title"]
            case .feedbackPreferences: aliases = ["gesture_haptics", "gesture_sound"]
            case .homeDisplay: aliases = ["home_screen", "home_display_settings", "edit_title", "edit_subtitle", "show_bookmarks_home", "show_group_picker_home", "show_recent_searches_home", "live_activity"]
            case .browsingDisplay: aliases = ["show_platform_bar", "show_top_search_bar", "keep_fullscreen_browsing", "extend_page_background", "page_background_gradient", "freeze_page_background_on_scroll", "keep_page_above_toolbar"]
            case .backups: aliases = ["icloud_settings_sync"]
            case .quickActions: aliases = ["quick_actions_explanation"]
            case .version: aliases = ["settings_version", "settings_rate", "settings_feedback", "URL Scheme"]
            default: aliases = []
            }
            return matchesSettings([entry.key] + aliases)
        }
    }
    private func settingsTitle(_ key: String) -> String {
        let primary = LanguageManager.shared.localizedString(key)
        if primary != key { return primary }
        let tool = ToolText.text(key)
        return tool == key ? FeatureText.text(key) : tool
    }

    private static let sectionSearchKeys: [[String]] = [
        ["settings_platforms"],
        ["settings_section_appearance", "settings_appearance", "settings_language", "settings_wallpaper", "screen_keep_awake"],
        ["home_screen", "home_display_settings", "edit_title", "edit_subtitle", "home_toolbar_customize", "show_bookmarks_home", "show_group_picker_home", "show_recent_searches_home", "live_activity"],
        ["browsing", "settings_ads_and_privacy", "browsing_display_settings", "settings_default_browser", "show_top_search_bar", "extend_page_background", "keep_page_above_toolbar", "keep_fullscreen_browsing", "video_settings", "web_appearance", "gestures_feedback_settings", "shake_action", "gesture_title", "gesture_settings_title", "page_zoom", "toolbar_customize", "ad_block_management", "settings_privacy", "userscripts"],
        ["settings_other", "Storage", "privacy_clear_cache", "feedback_settings", "gesture_haptics", "gesture_sound", "icloud_settings_sync", "settings_backups", "quick_actions_title"],
        ["settings_section_about_support", "settings_rate", "settings_feedback", "settings_version", "feedback_telegram", "URL Scheme"],
    ]

    private func matchesSettings(_ keys: [String]) -> Bool {
        let query = settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || keys.contains { key in
            LanguageManager.shared.localizedString(key).localizedCaseInsensitiveContains(query)
                || ToolText.text(key).localizedCaseInsensitiveContains(query)
                || FeatureText.text(key).localizedCaseInsensitiveContains(query)
        }
    }

    // Value-based links defer service/archive initialization until a subpage
    // is actually opened, instead of constructing every destination at once.
    fileprivate enum Destination: Hashable {
        case platforms, language, wallpaper, webAppearance, video, shake, toolbar, homeToolbar
        case gestures, websiteZoom, feedbackPreferences, homeDisplay, browsingDisplay, interaction
        case adBlock, privacy, extensions, backups, quickActions, version, storage, telegram
    }


}

/// Destination identity depends on its route and stable dependencies, not
/// settings search, cache-size scans, appearance controls or other local state.
private struct SettingsDestinationView: View {
    let destination: SettingsView.Destination
    let tabManager: TabManager
    let searchVM: SearchViewModel
    let dismiss: DismissAction
    let appVersion: String
    @ViewBuilder var body: some View {
        switch destination {
        case .platforms: PlatformManagementView()
        case .language: LanguageSettingsView()
        case .wallpaper: WallpaperSettingsView()
        case .webAppearance: WebAppearanceSettingsView()
        case .video: VideoSettingsView()
        case .interaction: GesturesFeedbackSettingsView()
        case .shake: ShakeActionSettingsView()
        case .gestures: BrowserGestureSettingsView()
        case .feedbackPreferences: AppFeedbackSettingsView()
        case .websiteZoom: WebsiteZoomSettingsView()
        case .toolbar: BrowserToolbarSettingsView()
        case .homeToolbar: HomeToolbarSettingsView()
        case .homeDisplay: HomeDisplaySettingsView()
        case .browsingDisplay: BrowsingDisplaySettingsView()
        case .adBlock: ProtectionSettingsView()
        case .privacy: ProtectionSettingsView(initialPage: .privacy)
        case .extensions:
            ExtensionCenterView(onOpenInBrowser: { [tabManager, searchVM, dismiss] url in
                tabManager.openURLFromBrowserControls(url, searchID: searchVM.searchID, inNewTab: true)
                searchVM.isSearching = true
                dismiss()
            })
        case .backups: SettingsBackupsView()
        case .quickActions: AppQuickActionSettingsView()
        case .version: AppVersionView(version: appVersion)
        case .telegram: TelegramFeedbackView()
        case .storage:
            StorageUsageView(onOpenInBrowser: { [tabManager, searchVM, dismiss] url in
                tabManager.openURLFromBrowserControls(url, searchID: searchVM.searchID, inNewTab: true)
                searchVM.isSearching = true
                dismiss()
            })
        }
    }

}

struct HomeDisplaySettingsView: View {
    private let neutralIconColor = Color(uiColor: .secondaryLabel)
    @AppStorage(LiveActivityService.enabledKey) private var liveActivityEnabled: Bool = true
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("show_recent_searches_on_home") private var showRecentSearchesOnHome: Bool = true
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = AppConstants.defaultHomeSubtitle
    @State private var showHomeTitleEdit = false
    @State private var showHomeSubtitleEdit = false
    @State private var editingHomeTitle = ""
    @State private var editingHomeSubtitle = ""

    var body: some View {
        List {
            Section {
                Button { editingHomeTitle = homeTitle; showHomeTitleEdit = true } label: {
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
                .accessibilityIdentifier("settings.homeDisplay.title")

                Button { editingHomeSubtitle = homeSubtitle; showHomeSubtitleEdit = true } label: {
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
                .accessibilityIdentifier("settings.homeDisplay.subtitle")

                Toggle(isOn: $showBookmarksOnHome) {
                    SettingsDescriptionLabel(
                        icon: "bookmark.fill",
                        color: showBookmarksOnHome ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("show_bookmarks_home"),
                        description: LanguageManager.shared.localizedString("show_bookmarks_home_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.homeDisplay.bookmarks")

                Toggle(isOn: $showGroupPickerOnHome) {
                    SettingsDescriptionLabel(
                        icon: "folder.fill",
                        color: showGroupPickerOnHome ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("show_group_picker_home"),
                        description: LanguageManager.shared.localizedString("show_group_picker_home_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.homeDisplay.groups")

                Toggle(isOn: $showRecentSearchesOnHome) {
                    SettingsDescriptionLabel(
                        icon: "clock.arrow.circlepath",
                        color: showRecentSearchesOnHome ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("show_recent_searches_home"),
                        description: LanguageManager.shared.localizedString("show_recent_searches_home_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.homeDisplay.recentSearches")

                Toggle(isOn: $liveActivityEnabled) {
                    SettingsDescriptionLabel(
                        icon: "dot.radiowaves.left.and.right",
                        color: liveActivityEnabled ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("live_activity"),
                        description: LanguageManager.shared.localizedString("live_activity_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.homeDisplay.liveActivity")
                .onCompatibleChange(of: liveActivityEnabled) { _, enabled in
                    LiveActivityService.shared.setEnabled(enabled)
                }

            }
        }
        .listStyle(.insetGrouped).tint(.themePrimary)
        .navigationTitle(ToolText.text("home_display_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(LanguageManager.shared.localizedString("edit_title"), isPresented: $showHomeTitleEdit) {
            TextField("Soulo", text: $editingHomeTitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeTitle = editingHomeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button(LanguageManager.shared.localizedString("platform_reset_defaults")) { homeTitle = "Soulo" }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showHomeSubtitleEdit) {
            TextField("", text: $editingHomeSubtitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeSubtitle = editingHomeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button(LanguageManager.shared.localizedString("platform_reset_defaults")) { homeSubtitle = AppConstants.defaultHomeSubtitle }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .onAppear {
            editingHomeTitle = homeTitle
            editingHomeSubtitle = homeSubtitle
        }
    }
}

struct BrowsingDisplaySettingsView: View {
    var focusPlatformBar = false
    @AppStorage(PlatformBarPreferences.visibilityKey) private var showPlatformBar = true
    @AppStorage(AppConstants.StorageKeys.extendPageBackground) private var extendPageBackground = BrowserInitialPreferences.extendPageBackground
    @AppStorage(AppConstants.StorageKeys.pageBackgroundGradient) private var pageBackgroundGradient = false
    @AppStorage(AppConstants.StorageKeys.freezePageBackgroundOnScroll) private var freezePageBackgroundOnScroll = false
    @State private var example: BrowsingDisplayExample?
    private let neutralIconColor = Color(uiColor: .secondaryLabel)
    @AppStorage("show_top_search_bar") private var showTopSearchBar = BrowserInitialPreferences.showTopSearchBar
    @AppStorage(AppConstants.StorageKeys.keepFullscreenBrowsing) private var keepFullscreenBrowsing = false
    @AppStorage(AppConstants.StorageKeys.keepPageAboveToolbar) private var keepPageAboveToolbar = false

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                Toggle(isOn: Binding(get: { showPlatformBar }, set: {
                    showPlatformBar = $0
                    if !$0 { example = .platformBar }
                })) {
                    SettingsDescriptionLabel(icon: "square.grid.2x2", color: showPlatformBar ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: ToolText.text("show_platform_bar"), description: PlatformBarPreferences.hiddenHint)
                }
                .id("platform-bar-setting")
                .accessibilityIdentifier("settings.browsingDisplay.platformBar")

                Toggle(isOn: Binding(get: { showTopSearchBar }, set: { showTopSearchBar = $0; if $0 { example = .topSearch } })) {
                    SettingsDescriptionLabel(
                        icon: "rectangle.topthird.inset.filled",
                        color: showTopSearchBar ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("show_top_search_bar"),
                        description: LanguageManager.shared.localizedString("show_top_search_bar_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.browsingDisplay.topSearchBar")

                Toggle(isOn: Binding(get: { keepFullscreenBrowsing }, set: { keepFullscreenBrowsing = $0; if $0 { example = .fullscreen } })) {
                    SettingsDescriptionLabel(
                        icon: "arrow.up.left.and.arrow.down.right",
                        color: keepFullscreenBrowsing ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("keep_fullscreen_browsing"),
                        description: LanguageManager.shared.localizedString("keep_fullscreen_browsing_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.browsingDisplay.fullscreen")
            }
            Section {
                Toggle(isOn: Binding(get: { extendPageBackground }, set: { extendPageBackground = $0; if $0 { example = .background } })) {
                    SettingsDescriptionLabel(icon: "paintpalette", color: extendPageBackground ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: ToolText.text("extend_page_background"), description: ToolText.text("extend_page_background_desc"))
                }
                .accessibilityIdentifier("settings.browsingDisplay.backgroundExtension")

                if extendPageBackground {
                    Toggle(isOn: $pageBackgroundGradient) {
                        SettingsDescriptionLabel(icon: "rectangle.lefthalf.filled", color: pageBackgroundGradient ? Color.themePrimary : Color(uiColor: .systemGray3),
                            title: ToolText.text("page_background_gradient"), description: ToolText.text("page_background_gradient_desc"))
                    }
                    .tint(.themePrimary)
                    .accessibilityIdentifier("settings.browsingDisplay.backgroundGradient")
                    Toggle(isOn: $freezePageBackgroundOnScroll) {
                        SettingsDescriptionLabel(icon: "lock.fill", color: freezePageBackgroundOnScroll ? Color.themePrimary : Color(uiColor: .systemGray3),
                            title: ToolText.text("freeze_page_background_on_scroll"), description: ToolText.text("freeze_page_background_on_scroll_desc"))
                    }
                    .tint(.themePrimary)
                    .accessibilityIdentifier("settings.browsingDisplay.freezeBackgroundOnScroll")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { keepPageAboveToolbar }, set: { keepPageAboveToolbar = $0; if $0 { example = .aboveToolbar } })) {
                    SettingsDescriptionLabel(
                        icon: "rectangle.bottomthird.inset.filled",
                        color: keepPageAboveToolbar ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("keep_page_above_toolbar"),
                        description: LanguageManager.shared.localizedString("keep_page_above_toolbar_desc")
                    )
                }
                .tint(Color.themePrimary)
                .accessibilityIdentifier("settings.browsingDisplay.pageAboveToolbar")

                SettingsSubpageLink {
                    WebsiteZoomSettingsView()
                } label: {
                    SettingsNavigationLabel(icon: "text.magnifyingglass", color: neutralIconColor, title: ToolText.text("page_zoom"))
                }.accessibilityIdentifier("settings.websiteZoom")
                SettingsSubpageLink {
                    WebAppearanceSettingsView()
                } label: {
                    SettingsNavigationLabel(icon: "circle.lefthalf.filled", color: neutralIconColor, title: LanguageManager.shared.localizedString("web_appearance"))
                }.accessibilityIdentifier("settings.webAppearance")
            }
        }
        .onAppear {
            if focusPlatformBar { DispatchQueue.main.async { proxy.scrollTo("platform-bar-setting", anchor: .top) } }
        }
        }
        .listStyle(.insetGrouped).tint(.themePrimary)
        .navigationTitle(ToolText.text("browsing_display_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $example) { item in
            BrowsingDisplayGuide(example: item, enabled: exampleBinding(item))
        }
    }
    private func exampleBinding(_ item: BrowsingDisplayExample) -> Binding<Bool> {
        switch item {
        case .platformBar: $showPlatformBar
        case .topSearch: $showTopSearchBar
        case .fullscreen: $keepFullscreenBrowsing
        case .background: $extendPageBackground
        case .aboveToolbar: $keepPageAboveToolbar
        }
    }

}

// MARK: - Shared Sub-views

/// Keep nested settings pages usable on iOS 16, where pushing another page
/// inside a settings NavigationStack can repeatedly invalidate the parent.
struct SettingsSubpageLink<Destination: View, Label: View>: View {
    private let destination: () -> Destination
    private let label: () -> Label
    @State private var showsDestination = false

    init(@ViewBuilder destination: @escaping () -> Destination,
         @ViewBuilder label: @escaping () -> Label) {
        self.destination = destination
        self.label = label
    }

    var body: some View {
        if #available(iOS 17.0, *) {
            NavigationLink(destination: destination, label: label)
        } else {
            Button { showsDestination = true } label: {
                HStack {
                    label()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showsDestination) {
                NavigationStack {
                    destination().toolbar {
                        ToolbarItem(placement: .cancellationAction) { SettingsDetailDoneButton() }
                    }
                }
            }
        }
    }
}

private struct SettingsDetailDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button(LanguageManager.shared.localizedString("done")) { dismiss() }
    }
}

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
        .frame(width: 32, height: 32)
    }
}

struct SettingsNavigationLabel: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        SettingsRowLabel(icon: icon, color: color, title: title)
    }
}

struct SettingsActionLabel: View {
    let icon: String
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SettingsNavigationLabel(icon: icon, color: color, title: title)
                .foregroundStyle(.primary)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            SettingsRowLabel(icon: icon, color: color, title: title, description: description)

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
            .padding(.top, 7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct SettingsDescriptionLabel: View {
    let icon: String
    let color: Color
    let title: String
    let description: String

    var body: some View {
        SettingsRowLabel(icon: icon, color: color, title: title, description: description)
    }
}

/// Every settings row reserves the same icon column and title origin.
/// Navigation, buttons and toggles share this layout, including multiline text.
struct SettingsRowLabel: View {
    let icon: String
    let color: Color
    let title: String
    var description: String? = nil
    private var hasDescription: Bool { description?.isEmpty == false }

    var body: some View {
        HStack(alignment: hasDescription ? .top : .center, spacing: 12) {
            IconBadge(systemName: icon, color: color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let description, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, hasDescription ? 2 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 44 }
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
