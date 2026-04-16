import SwiftUI
import SwiftData

/// A beautiful landing page shown when a new tab has no content.
/// Quick links are automatically selected based on the user's language/region.
struct NewTabPageView: View {
    var tabManager: TabManager?
    var onNavigate: (URL) -> Void

    @Query(sort: \BookmarkItem.dateAdded, order: .reverse) private var bookmarks: [BookmarkItem]
    @State private var urlText: String = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    /// Detect the best region based on the current language.
    private var detectedRegion: PlatformRegion {
        let lang = LanguageManager.shared.currentLanguage
        switch lang {
        case "zh-Hans", "zh-Hant": return .china
        case "ja":                 return .japan
        case "ru":                 return .russia
        default:                   return .international
        }
    }

    /// Platforms for the primary (detected) region — shown first.
    private var primaryPlatforms: [SearchPlatform] {
        PlatformDataStore.shared.visiblePlatforms(for: detectedRegion)
            .filter { $0.interactionType == .urlSearch }
    }

    /// A few international platforms to supplement when the primary region is small.
    private var supplementaryPlatforms: [SearchPlatform] {
        guard detectedRegion != .international else { return [] }
        return PlatformDataStore.shared.visiblePlatforms(for: .international)
            .filter { $0.interactionType == .urlSearch }
            .prefix(4)
            .map { $0 }
    }

    /// Combined quick links: primary region first, then international supplement, max 8.
    private var quickLinkPlatforms: [SearchPlatform] {
        var result = primaryPlatforms
        // Supplement smaller regions with international links
        if result.count < 8 {
            let existing = Set(result.map(\.name))
            let extras = supplementaryPlatforms.filter { !existing.contains($0.name) }
            result.append(contentsOf: extras)
        }
        return Array(result.prefix(8))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 40)

                // Logo + branding
                VStack(spacing: 10) {
                    Image(systemName: "globe.desk")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(hex: "6366F1"), Color(hex: "A855F7")],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text(LanguageManager.shared.localizedString("tab_new_tab"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                }

                // Search / URL bar
                searchBar
                    .padding(.horizontal, 28)

                // Quick links (region-aware)
                if !quickLinkPlatforms.isEmpty {
                    quickLinksSection
                        .padding(.horizontal, 20)
                }

                // Bookmarks
                if !bookmarks.isEmpty {
                    bookmarksSection
                        .padding(.horizontal, 20)
                }

                // Recently closed
                if let tm = tabManager, !tm.recentlyClosed.isEmpty {
                    recentlyClosedSection(tm)
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 60)
            }
        }
        .background(Color(UIColor.systemBackground))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(
                LanguageManager.shared.localizedString("search_placeholder"),
                text: $urlText
            )
            .font(.system(size: 15))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .focused($isSearchFocused)
            .onSubmit { navigateToInput() }

            if !urlText.isEmpty {
                Button {
                    urlText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSearchFocused
                        ? Color(hex: "6366F1").opacity(0.5)
                        : Color(UIColor.separator).opacity(0.3),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Quick Links (Region-Aware)

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LanguageManager.shared.localizedString("ntp_quick_links"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 16) {
                ForEach(quickLinkPlatforms) { platform in
                    Button {
                        if let url = URL(string: platform.homeURL) {
                            HapticsManager.light()
                            onNavigate(url)
                        }
                    } label: {
                        VStack(spacing: 8) {
                            PlatformIconView(platform: platform, size: 44)

                            Text(LanguageManager.shared.localizedString(platform.name))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Bookmarks Section

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(
                    LanguageManager.shared.localizedString("bookmarks"),
                    systemImage: "bookmark.fill"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(bookmarks.prefix(12)) { bookmark in
                        Button {
                            if let url = bookmark.url {
                                HapticsManager.light()
                                onNavigate(url)
                            }
                        } label: {
                            VStack(spacing: 6) {
                                BookmarkFaviconView(urlString: bookmark.urlString, size: 36)

                                Text(bookmark.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 56)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Recently Closed

    private func recentlyClosedSection(_ tm: TabManager) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    LanguageManager.shared.localizedString("tab_recently_closed"),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ForEach(tm.recentlyClosed.prefix(5)) { closed in
                Button {
                    HapticsManager.selection()
                    tm.restoreClosedTab(closed)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .background(
                                Color(UIColor.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(closed.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if let host = closed.url?.host {
                                Text(host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: "6366F1"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(UIColor.secondarySystemBackground))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Navigation

    private func navigateToInput() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let url: URL
        if trimmed.isValidURL, let parsed = trimmed.asURL {
            url = parsed
        } else if trimmed.contains(".") && !trimmed.contains(" "),
                  let parsed = URL(string: "https://\(trimmed)") {
            url = parsed
        } else {
            // Search with the first platform from the detected region
            if let platform = primaryPlatforms.first,
               let searchURL = platform.searchURL(for: trimmed) {
                url = searchURL
            } else {
                let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
                guard let fallbackURL = URL(string: "https://www.google.com/search?q=\(encoded)") else { return }
                url = fallbackURL
            }
        }

        onNavigate(url)
    }
}
