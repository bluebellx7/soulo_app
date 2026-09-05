import SwiftUI
import SwiftData

struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var modelContext
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

    @State private var showClearHistoryAlert = false
    @State private var showClearBookmarksAlert = false
    @State private var showClearCacheAlert = false

    @State private var clearingHistory = false
    @State private var clearingBookmarks = false
    @State private var clearingCache = false

    @State private var historyCleared = false
    @State private var bookmarksCleared = false
    @State private var cacheCleared = false
    @State private var cacheSizeText: String?

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
                        icon: "link.badge.minus",
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

                // MARK: - Data Management
                Section {
                    // Clear Search History
                    DestructiveActionRow(
                        icon: "clock.arrow.circlepath",
                        title: LanguageManager.shared.localizedString("privacy_clear_history"),
                        description: LanguageManager.shared.localizedString("privacy_clear_history_desc"),
                        isLoading: clearingHistory,
                        isCompleted: historyCleared
                    ) {
                        showClearHistoryAlert = true
                    }
                    .alert(
                        LanguageManager.shared.localizedString("privacy_clear_history_confirm_title"),
                        isPresented: $showClearHistoryAlert
                    ) {
                        Button(
                            LanguageManager.shared.localizedString("privacy_clear_action"),
                            role: .destructive
                        ) {
                            clearSearchHistory()
                        }
                        Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                    } message: {
                        Text(LanguageManager.shared.localizedString("privacy_clear_history_confirm_message"))
                    }

                    // Clear Bookmarks
                    DestructiveActionRow(
                        icon: "bookmark.slash.fill",
                        title: LanguageManager.shared.localizedString("privacy_clear_bookmarks"),
                        description: LanguageManager.shared.localizedString("privacy_clear_bookmarks_desc"),
                        isLoading: clearingBookmarks,
                        isCompleted: bookmarksCleared
                    ) {
                        showClearBookmarksAlert = true
                    }
                    .alert(
                        LanguageManager.shared.localizedString("privacy_clear_bookmarks_confirm_title"),
                        isPresented: $showClearBookmarksAlert
                    ) {
                        Button(
                            LanguageManager.shared.localizedString("privacy_clear_action"),
                            role: .destructive
                        ) {
                            clearBookmarks()
                        }
                        Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                    } message: {
                        Text(LanguageManager.shared.localizedString("privacy_clear_bookmarks_confirm_message"))
                    }

                    // Clear browser cache without deleting account sessions.
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
                            clearWebViewCache()
                        }
                        Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                    } message: {
                        Text(LanguageManager.shared.localizedString("privacy_clear_cache_confirm_message"))
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("privacy_section_data"))
                } footer: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(LanguageManager.shared.localizedString("privacy_data_footer"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_privacy"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshCacheSize()
        }
        .onChange(of: isIncognito) { _, enabled in
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

    // MARK: - Actions

    private func clearSearchHistory() {
        clearingHistory = true
        Task {
            do {
                try SearchHistoryService.clearAll(in: modelContext)
                await MainActor.run {
                    clearingHistory = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        historyCleared = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { historyCleared = false }
                    }
                }
            } catch {
                await MainActor.run {
                    clearingHistory = false
                }
            }
        }
    }

    private func clearBookmarks() {
        clearingBookmarks = true
        Task {
            do {
                try BookmarkService.clearAll(in: modelContext)
                await MainActor.run {
                    clearingBookmarks = false
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        bookmarksCleared = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { bookmarksCleared = false }
                    }
                }
            } catch {
                await MainActor.run {
                    clearingBookmarks = false
                }
            }
        }
    }

    private func clearWebViewCache() {
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
