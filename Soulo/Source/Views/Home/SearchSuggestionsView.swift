import SwiftUI

struct SearchSuggestionsView: View {
    let recentSearches: [String]
    var onTap: ((String) -> Void)? = nil
    var onDelete: ((String) -> Void)? = nil
    var horizontalInset = HomeLandingSpacing.contentInset
    var contrast: WallpaperRegionContrast? = nil

    @EnvironmentObject var languageManager: LanguageManager
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAll = false

    private var isLight: Bool { wallpaperManager.prefersDarkForeground(for: WallpaperAppearance(colorScheme)) }

    var body: some View {
        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    wallpaperLabel(languageManager.localizedString("recent_searches"), size: 13)
                        .accessibilityIdentifier("home.recent.title")

                    Spacer()

                    if recentSearches.count > 6, onTap != nil {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showAll.toggle()
                            }
                        } label: {
                            wallpaperLabel(languageManager.localizedString(showAll ? "show_less" : "show_more"), size: 12)
                        }
                    }
                }
                .padding(.horizontal, horizontalInset)

                // Tags
                FlowLayout(spacing: 8) {
                    ForEach(displayedSearches, id: \.self) { keyword in
                        if let onTap, let onDelete {
                            SuggestionChip(text: keyword, lightWallpaper: isLight, contrast: contrast,
                                onTap: { onTap(keyword) }, onDelete: { onDelete(keyword) })
                        } else {
                            SuggestionChipLabel(text: keyword, lightWallpaper: isLight, contrast: contrast)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("home.recent.terms")
                .padding(.horizontal, horizontalInset)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayedSearches: [String] {
        showAll ? recentSearches : Array(recentSearches.prefix(6))
    }

    private func wallpaperLabel(_ text: String, size: CGFloat) -> some View {
        WallpaperForegroundRegion(contrast: contrast, fallbackDarkInk: isLight) { darkInk in
            Text(text)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle((darkInk ? Color(hex: "2E2A47") : .white).opacity(contrast == nil ? 0.8 : 1))
                .shadow(color: (darkInk ? Color.white : .black).opacity(contrast == nil ? 0 : 0.7), radius: 1.2)
        }
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let lightWallpaper: Bool
    let contrast: WallpaperRegionContrast?
    let onTap: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            SuggestionChipLabel(text: text, lightWallpaper: lightWallpaper, contrast: contrast)
        }
        // Let the system arbitrate the context menu and the normal Button tap.
        // A high-priority custom long press consumes short taps on iOS 17.4.
        .contextMenu {
            Button(role: .destructive, action: onDelete) {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            AppAccessibility.formatted("accessibility_recent_search", text)
        )
        .accessibilityHint(
            LanguageManager.shared.localizedString("accessibility_recent_search_hint")
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text(LanguageManager.shared.localizedString("delete"))) {
            onDelete()
        }
    }
}

private struct SuggestionChipLabel: View {
    let text: String
    let lightWallpaper: Bool
    let contrast: WallpaperRegionContrast?

    var body: some View {
        WallpaperForegroundRegion(contrast: contrast, fallbackDarkInk: lightWallpaper) { darkInk in
            let color = darkInk ? Color(hex: "2E2A47") : .white
            let fill = if contrast != nil {
                darkInk ? Color.white.opacity(0.66) : Color.black.opacity(0.56)
            } else {
                darkInk ? Color.black.opacity(0.04) : Color.white.opacity(0.06)
            }
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(color.opacity(contrast == nil ? 0.75 : 1))
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.12), lineWidth: 0.5))
            .contentShape(Capsule())
        }
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(subviews: subviews, width: proposal.width ?? 0)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, width: bounds.width)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: .unspecified
            )
        }
    }

    private func layout(subviews: Subviews, width: CGFloat) -> (size: CGSize, positions: [CGPoint]) {
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }

            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxWidth = max(maxWidth, x)
        }

        return (CGSize(width: maxWidth, height: y + rowHeight), positions)
    }
}
