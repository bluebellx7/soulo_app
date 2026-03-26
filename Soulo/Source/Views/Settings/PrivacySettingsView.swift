import SwiftUI
import SwiftData
import WebKit

struct PrivacySettingsView: View {
    @Environment(\.modelContext) private var modelContext

    @AppStorage("is_incognito") private var isIncognito: Bool = false

    @State private var showClearHistoryAlert = false
    @State private var showClearBookmarksAlert = false
    @State private var showClearCacheAlert = false

    @State private var clearingHistory = false
    @State private var clearingBookmarks = false
    @State private var clearingCache = false

    @State private var historyCleared = false
    @State private var bookmarksCleared = false
    @State private var cacheCleared = false

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
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $isIncognito) {
                            Label {
                                Text(LanguageManager.shared.localizedString("privacy_incognito"))
                                    .font(.body)
                                    .fontWeight(.medium)
                            } icon: {
                                IconBadge(systemName: "theatermasks.fill", color: .purple)
                            }
                        }
                        .tint(.purple)

                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 1)
                            Text(LanguageManager.shared.localizedString("privacy_incognito_desc"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.leading, 2)
                    }
                    .padding(.vertical, 4)
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("privacy_section_browsing"))
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

                    // Clear WebView Cache
                    DestructiveActionRow(
                        icon: "internaldrive.fill",
                        title: LanguageManager.shared.localizedString("privacy_clear_cache"),
                        description: LanguageManager.shared.localizedString("privacy_clear_cache_desc"),
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
        .navigationBarTitleDisplayMode(.large)
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
        let dataTypes: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
            WKWebsiteDataTypeCookies,
            WKWebsiteDataTypeSessionStorage,
            WKWebsiteDataTypeLocalStorage
        ]
        WKWebsiteDataStore.default().removeData(
            ofTypes: dataTypes,
            modifiedSince: .distantPast
        ) {
            DispatchQueue.main.async {
                clearingCache = false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    cacheCleared = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { cacheCleared = false }
                }
            }
        }
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
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.1))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.red)
                }

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
