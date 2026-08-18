import SwiftUI

/// A beautiful landing page shown when a new tab has no content.
/// Quick links are automatically selected based on the user's language/region.
struct NewTabPageView: View {
    var tabManager: TabManager?
    var onNavigate: (URL) -> Void

    @State private var urlText: String = ""
    @FocusState private var isSearchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var wallpaperManager = WallpaperManager.shared
    @ObservedObject private var platformStore = PlatformDataStore.shared

    private var primaryTextColor: Color {
        wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47") : .white
    }

    private var secondaryTextColor: Color {
        primaryTextColor.opacity(0.62)
    }

    private var cardFillColor: Color {
        wallpaperManager.isCurrentWallpaperLight
            ? Color.white.opacity(0.68)
            : Color.white.opacity(0.1)
    }

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
        platformStore.visiblePlatforms(for: detectedRegion)
            .filter { $0.interactionType == .urlSearch }
    }

    /// A few international platforms to supplement when the primary region is small.
    private var supplementaryPlatforms: [SearchPlatform] {
        guard detectedRegion != .international else { return [] }
        return platformStore.visiblePlatforms(for: .international)
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
                        .accessibilityHidden(true)

                    Text(LanguageManager.shared.localizedString("tab_new_tab"))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(primaryTextColor)
                        .accessibilityAddTraits(.isHeader)
                }

                // Search / URL bar
                searchBar
                    .padding(.horizontal, 28)

                // Quick links (region-aware)
                if !quickLinkPlatforms.isEmpty {
                    quickLinksSection
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
        .onAppear { wallpaperManager.ensureLoaded() }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(secondaryTextColor)
                .accessibilityHidden(true)

            TextField(
                LanguageManager.shared.localizedString("search_placeholder"),
                text: $urlText
            )
            .font(.system(size: 15))
            .foregroundStyle(primaryTextColor)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.webSearch)
            .focused($isSearchFocused)
            .onSubmit { navigateToInput() }
            .accessibilityLabel(LanguageManager.shared.localizedString("search_placeholder"))

            if !urlText.isEmpty {
                Button {
                    urlText = ""
                } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(secondaryTextColor.opacity(0.75))
                }
                .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(cardFillColor)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSearchFocused
                        ? Color(hex: "6366F1").opacity(0.5)
                        : primaryTextColor.opacity(0.14),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Quick Links (Region-Aware)

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LanguageManager.shared.localizedString("ntp_quick_links"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

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
                                .foregroundStyle(primaryTextColor)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LanguageManager.shared.localizedString(platform.name))
                    .accessibilityHint(
                        LanguageManager.shared.localizedString("accessibility_open_platform_hint")
                    )
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
                .foregroundStyle(secondaryTextColor)
                .accessibilityAddTraits(.isHeader)
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
                            .foregroundStyle(secondaryTextColor)
                            .frame(width: 28, height: 28)
                            .background(
                                Color(UIColor.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(closed.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(primaryTextColor)
                                .lineLimit(1)
                            if let host = closed.url?.host {
                                Text(host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(secondaryTextColor.opacity(0.8))
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
                            .fill(cardFillColor)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(closed.title)
                .accessibilityValue(closed.url?.host ?? "")
                .accessibilityHint(
                    LanguageManager.shared.localizedString("accessibility_restore_tab_hint")
                )
            }
        }
    }

    // MARK: - Navigation

    private func navigateToInput() {
        guard let url = BrowserNavigationResolver.resolve(
            urlText,
            preferredSearchPlatform: primaryPlatforms.first
        ) else { return }
        onNavigate(url)
    }
}
