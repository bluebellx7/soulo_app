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

    @State private var settingsQuery = ""
    @ObservedObject private var quickCleanup = StorageQuickCleanupService.shared
    @State private var quickClearNotice: String?

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
                Color.themeGroupedBg.ignoresSafeArea()

                List {
                    if isSearchingSettings {
                        if searchEntries.isEmpty && !showsQuickClearSearchResult {
                            CompatibleUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "magnifyingglass")
                        } else {
                            Section {
                                ForEach(searchEntries) { entry in
                                    if entry.destination == .defaultBrowser {
                                        Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                                            SettingsActionLabel(icon: entry.icon, color: neutralIconColor, title: settingsTitle(entry.key))
                                        }.buttonStyle(.plain).accessibilityIdentifier("settings.defaultBrowser")
                                    } else {
                                        NavigationLink(value: entry.destination) {
                                            SettingsNavigationLabel(icon: entry.icon, color: neutralIconColor, title: settingsTitle(entry.key))
                                        }.accessibilityIdentifier("settings." + String(describing: entry.destination))
                                    }
                                }
                                if showsQuickClearSearchResult { quickClearButton }
                            }
                        }
                    } else {
                        Section {
                            AppAppearanceSettingsRow()
                            settingsLink(.wallpaper, title: LText("settings_wallpaper"), icon: "photo", id: "wallpaper")
                            NavigationLink(value: Destination.language) {
                                HStack(spacing: 12) {
                                    SettingsNavigationLabel(icon: "globe", color: neutralIconColor, title: LanguageManager.shared.localizedString("settings_language"))
                                    Text(currentLanguageName).foregroundStyle(.secondary).font(.subheadline)
                                }
                            }.accessibilityIdentifier("settings.language")
                            settingsLink(.toolbar, title: ToolText.text("toolbar_settings"), icon: "slider.horizontal.3", id: "toolbar",
                                description: BrowserToolbarSettingsView.Section.allCases.map(\.title).joined(separator: " · "))
                        } header: { SectionHeader(title: ToolText.text("settings_personalization")) }

                        Section {
                            settingsLink(.platforms, title: LanguageManager.shared.localizedString("platform_management"), icon: "square.grid.2x2", id: "platforms")
                            settingsLink(.browsingDisplay, title: ToolText.text("browsing_display_settings"), icon: "rectangle.topthird.inset.filled", id: "browsingDisplay",
                                description: ["browsing_startup_tabs", "browsing_interface", "browsing_web_display"].map { ToolText.text($0) }.joined(separator: " · "))
                            settingsLink(.video, title: ToolText.text("video_settings"), icon: "play.rectangle", id: "video")
                            settingsLink(.interaction, title: ToolText.text("gestures_shortcuts_settings"), icon: "hand.draw", id: "interaction")
                            settingsLink(.adBlock, title: ToolText.text("settings_ads_and_privacy"), icon: "shield.lefthalf.filled", id: "protection")
                            settingsLink(.extensions, title: LanguageManager.shared.localizedString("userscripts"), icon: "puzzlepiece.extension", id: "extensions")
                        } header: { SectionHeader(title: LanguageManager.shared.localizedString("browsing")) }

                        Section {
                            settingsLink(.backups, title: ToolText.text("settings_sync_backup"), icon: "icloud", id: "backups")
                            settingsLink(.storage, title: FeatureText.text("Storage"), icon: "internaldrive", id: "storage")
                            quickClearButton
                        } header: { SectionHeader(title: ToolText.text("settings_data")) }

                        Section {
                            settingsLink(.version, title: ToolText.text("about_feedback_settings"), icon: "info.circle", id: "version")
                            settingsLink(.telegram, title: ToolText.text("feedback_telegram"), icon: "paperplane", id: "telegram")
                        } header: {
                            SectionHeader(title: LanguageManager.shared.localizedString("settings_section_support"))
                        } footer: {
                            VStack(spacing: 4) {
                                Text("Soulo \(appVersion)").font(.caption.weight(.semibold))
                                    .accessibilityIdentifier("settings.footer.version")
                                Text("Made with \u{2764}\u{FE0F}").font(.caption2)
                            }
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 8)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(LanguageManager.shared.localizedString("settings_title"))
            .navigationBarTitleDisplayMode(.inline)
            .alert(ToolText.text("storage_quick_clear"), isPresented: Binding(
                get: { quickClearNotice != nil }, set: { if !$0 { quickClearNotice = nil } }
            )) {
                Button(ToolText.text("done")) { quickClearNotice = nil }
            } message: { Text(quickClearNotice ?? "") }
            .searchable(text: $settingsQuery, prompt: LanguageManager.shared.localizedString("search"))
            .task { await quickCleanup.refreshSize() }
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

    private func settingsLink(_ destination: Destination, title: String, icon: String, id: String, description: String? = nil) -> some View {
        NavigationLink(value: destination) {
            if let description {
                SettingsDescriptionLabel(icon: icon, color: neutralIconColor, title: title, description: description)
            } else {
                SettingsNavigationLabel(icon: icon, color: neutralIconColor, title: title)
            }
        }.accessibilityIdentifier("settings." + id)
    }

    private struct SearchEntry: Identifiable {
        let destination: Destination
        let key: String
        let icon: String
        var id: Destination { destination }
    }
    private static let searchableEntries: [SearchEntry] = [
        .init(destination: .appearance, key: "settings_appearance", icon: "circle.lefthalf.filled"),
        .init(destination: .defaultBrowser, key: "settings_default_browser", icon: "globe"),
        .init(destination: .platforms, key: "platform_management", icon: "square.grid.2x2.fill"),
        .init(destination: .language, key: "settings_language", icon: "globe"),
        .init(destination: .wallpaper, key: "settings_wallpaper", icon: "photo"),
        .init(destination: .webAppearance, key: "web_appearance", icon: "circle.lefthalf.filled"),
        .init(destination: .video, key: "video_settings", icon: "play.rectangle"),
        .init(destination: .interaction, key: "gestures_shortcuts_settings", icon: "hand.draw"),
        .init(destination: .shake, key: "shake_action", icon: "iphone.radiowaves.left.and.right"),
        .init(destination: .gestures, key: "gesture_settings_title", icon: "hand.draw"),
        .init(destination: .feedbackPreferences, key: "feedback_settings", icon: "speaker.wave.2"),
        .init(destination: .websiteZoom, key: "page_zoom", icon: "text.magnifyingglass"),
        .init(destination: .toolbar, key: "toolbar_settings", icon: "slider.horizontal.3"),
        .init(destination: .homeDisplay, key: "home_toolbar_visibility_page", icon: "eye"),
        .init(destination: .browsingDisplay, key: "browsing_display_settings", icon: "rectangle.topthird.inset.filled"),
        .init(destination: .homeToolbar, key: "home_toolbar_customize", icon: "rectangle.split.2x2"),
        .init(destination: .adBlock, key: "settings_ads_and_privacy", icon: "shield.lefthalf.filled"),
        .init(destination: .extensions, key: "userscripts", icon: "puzzlepiece.extension"),
        .init(destination: .backups, key: "settings_sync_backup", icon: "icloud"),
        .init(destination: .quickActions, key: "app_icon_shortcuts", icon: "hand.tap"),
        .init(destination: .version, key: "about_feedback_settings", icon: "info.circle.fill"),
        .init(destination: .telegram, key: "feedback_telegram", icon: "paperplane.fill"),
        .init(destination: .storage, key: "Storage", icon: "internaldrive")
    ]
    private var isSearchingSettings: Bool { !settingsQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsQuickClearSearchResult: Bool {
        isSearchingSettings && matchesSettings(["Storage", "storage_quick_clear", "privacy_clear_cache"])
    }
    private var quickClearButton: some View {
        HStack(spacing: 10) {
            Button {
                guard !quickCleanup.isRunning else { return }
                Task {
                    guard !quickCleanup.isRunning else { return }
                    let report = await quickCleanup.clearDefaults(tabManager: tabManager)
                    if report.failures.isEmpty { HapticsManager.success() }
                }
            } label: {
                HStack(spacing: 12) {
                    SettingsNavigationLabel(icon: "eraser", color: neutralIconColor, title: ToolText.text("storage_quick_clear"))
                    Spacer(minLength: 4)
                    Text(quickCleanup.clearableBytes.map { "≈ " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                        .foregroundStyle(.secondary).font(.subheadline).monospacedDigit()
                        .accessibilityValue(quickCleanup.clearableBytes.map { String($0) } ?? "")
                        .accessibilityIdentifier("settings.quickClear.size")
                    if quickCleanup.isRunning { ProgressView().controlSize(.small) }
                    else if quickCleanup.didClear {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            .accessibilityLabel(ToolText.text("storage_quick_clear_done"))
                            .accessibilityIdentifier("settings.quickClear.success")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(quickCleanup.isRunning)
            .accessibilityIdentifier("settings.quickClear")
            if !quickCleanup.isRunning, let notice = quickCleanup.lastReport?.notice {
                Button { quickClearNotice = notice } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ToolText.text(quickCleanup.didClear ? "storage_quick_clear_done" : "error"))
                .accessibilityHint(notice)
                .accessibilityIdentifier("settings.quickClear.result")
            }
        }
    }
    private var searchEntries: [SearchEntry] {
        Self.searchableEntries.filter { entry in
            let aliases: [String]
            switch entry.destination {
            case .appearance: aliases = ["dynamic_theme", "settings_section_appearance", "theme_system", "theme_light", "theme_dark"]
            case .wallpaper: aliases = ["appearance_home_settings"]
            case .platforms: aliases = ["settings_platforms", "show_platform_bar", "auto_hide_platform_bar", "home_quick_search"]
            case .adBlock: aliases = ["ad_block_management", "settings_privacy"]
            case .storage: aliases = ["privacy_section_data", "privacy_clear_cache", "privacy_clear_history", "privacy_clear_bookmarks", "privacy_clear_browsing_on_exit"]
            case .gestures: aliases = ["gesture_title"]
            case .interaction: aliases = ["gestures_feedback_settings"]
            case .toolbar: aliases = ["toolbar_customize", "toolbar_more_panel", "home_toolbar_browser_tools"]
            case .feedbackPreferences: aliases = ["gesture_haptics", "gesture_sound"]
            case .homeDisplay: aliases = ["home_screen", "home_display_settings", "edit_title", "edit_subtitle", "show_bookmarks_home", "show_recent_searches_home", "live_activity"]
            case .browsingDisplay: aliases = ["browsing_display_settings_legacy", "screen_keep_awake", "browsing_startup_tabs", "browsing_interface", "browsing_web_display", "restore_last_page_on_launch", "keep_fullscreen_browsing", "extend_page_background", "page_background_gradient", "freeze_page_background_on_scroll", "keep_page_above_toolbar"]
            case .backups: aliases = ["settings_backups", "icloud_settings_sync", "icloud_bookmark_sync", "manual_settings_backups"]
            case .quickActions: aliases = ["quick_actions_title", "quick_actions_explanation"]
            case .version: aliases = ["settings_section_about_support", "settings_section_support", "settings_version", "settings_rate", "settings_feedback", "URL Scheme"]
            default: aliases = []
            }
            let group: String
            switch entry.destination {
            case .appearance, .language, .wallpaper, .homeDisplay, .toolbar, .homeToolbar:
                group = "settings_personalization"
            case .backups, .storage:
                group = "settings_data"
            case .version, .telegram:
                group = "settings_section_support"
            default:
                group = "browsing"
            }
            return matchesSettings([entry.key, group] + aliases)
        }
    }
    private func settingsTitle(_ key: String) -> String {
        let primary = LanguageManager.shared.localizedString(key)
        if primary != key { return primary }
        let tool = ToolText.text(key)
        return tool == key ? FeatureText.text(key) : tool
    }

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
        case appearance, defaultBrowser, platforms, language, wallpaper, webAppearance, video, shake, toolbar, homeToolbar
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
        case .appearance:
            AppAppearanceSettingsView()
                .navigationTitle(LanguageManager.shared.localizedString("settings_appearance"))
                .navigationBarTitleDisplayMode(.inline)
        case .defaultBrowser: BrowsingDisplaySettingsView()
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
        case .toolbar: BrowserToolbarSettingsView(initialSection: searchVM.isSearching ? .browsing : .home)
        case .homeToolbar: HomeToolbarSettingsView()
        case .homeDisplay: HomeToolbarSettingsView(startsAtVisibility: true)
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

private struct AppAppearanceSettingsRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    private var label: some View {
        SettingsNavigationLabel(icon: "circle.lefthalf.filled", color: Color(uiColor: .secondaryLabel),
            title: LanguageManager.shared.localizedString("settings_appearance"))
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                label.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                choices(fixedWidth: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                choices(fixedWidth: false)
            }
        }
    }

    private func choices(fixedWidth: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(["system", "light", "dark"], id: \.self) { mode in
                let selected = themeManager.appearance == mode
                Button {
                    HapticsManager.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { themeManager.setAppearance(mode) }
                } label: {
                    Text(LanguageManager.shared.localizedString("theme_" + mode))
                        .font(.caption.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: fixedWidth, vertical: true)
                        .frame(maxWidth: fixedWidth ? nil : .infinity)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .foregroundStyle(selected ? Color.themePrimary : .secondary)
                        .background(selected ? Color.themePrimary.opacity(0.14) : Color(uiColor: .secondarySystemFill), in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("settings.appearance." + mode)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

private struct AppAppearanceSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    ForEach(["system", "light", "dark"], id: \.self) { mode in
                        let selected = themeManager.appearance == mode
                        Button {
                            HapticsManager.selection()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { themeManager.setAppearance(mode) }
                        } label: {
                            VStack(spacing: 12) {
                                Image(systemName: mode == "system" ? "circle.lefthalf.filled" : mode == "light" ? "sun.max.fill" : "moon.fill")
                                    .font(.system(size: 24, weight: .medium)).frame(height: 30)
                                Text(LanguageManager.shared.localizedString("theme_" + mode))
                                    .font(.subheadline.weight(.medium)).multilineTextAlignment(.center)
                            }
                            .foregroundStyle(selected ? Color.themePrimary : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .padding(.horizontal, 4)
                            .background(selected ? Color.themePrimary.opacity(0.09) : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16))
                            .overlay { RoundedRectangle(cornerRadius: 16).stroke(selected ? Color.themePrimary : .clear, lineWidth: 1.5) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.appearance." + mode)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }.padding(.vertical, 4)
            } header: { Text(LanguageManager.shared.localizedString("dynamic_theme")) }
        }.listStyle(.insetGrouped)
    }
}

struct BrowsingDisplaySettingsView: View {
    @Environment(\.openURL) private var openURL
    @AppStorage(VideoScreenAwakeService.preferenceKey) private var keepScreenAwake = false
    @AppStorage(AppConstants.StorageKeys.extendPageBackground) private var extendPageBackground = BrowserInitialPreferences.extendPageBackground
    @AppStorage(AppConstants.StorageKeys.pageBackgroundGradient) private var pageBackgroundGradient = false
    @AppStorage(AppConstants.StorageKeys.freezePageBackgroundOnScroll) private var freezePageBackgroundOnScroll = false
    @State private var example: BrowsingDisplayExample?
    private let neutralIconColor = Color(uiColor: .secondaryLabel)
    @AppStorage(BrowserInitialPreferences.restoreLastPageKey) private var restoreLastPage = false
    @AppStorage(AppConstants.StorageKeys.keepFullscreenBrowsing) private var keepFullscreenBrowsing = false
    @AppStorage(AppConstants.StorageKeys.keepPageAboveToolbar) private var keepPageAboveToolbar = false

    var body: some View {
        List {
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    SettingsActionLabel(icon: "globe", color: neutralIconColor,
                        title: LanguageManager.shared.localizedString("settings_default_browser"))
                }
                .buttonStyle(.plain).accessibilityIdentifier("settings.defaultBrowser")
                .accessibilityHint(LanguageManager.shared.localizedString("settings_default_browser_hint"))
                Toggle(isOn: $restoreLastPage) {
                    SettingsDescriptionLabel(icon: "arrow.counterclockwise", color: restoreLastPage ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: ToolText.text("restore_last_page_on_launch"), description: ToolText.text("restore_last_page_on_launch_desc"))
                }
                .accessibilityIdentifier("settings.browsingDisplay.restoreLastPage")

            } header: { Text(ToolText.text("browsing_startup_tabs")) }
            Section {
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

            } header: { Text(ToolText.text("browsing_interface")) }
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
            } header: { Text(ToolText.text("browsing_web_display")) }
        }
        .listStyle(.insetGrouped).tint(.themePrimary)
        .navigationTitle(ToolText.text("browsing_display_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $example) { item in
            if let enabled = exampleBinding(item) {
                BrowsingDisplayGuide(example: item, enabled: enabled)
            }
        }
    }
    private func exampleBinding(_ item: BrowsingDisplayExample) -> Binding<Bool>? {
        switch item {
        case .platformBar: nil
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
