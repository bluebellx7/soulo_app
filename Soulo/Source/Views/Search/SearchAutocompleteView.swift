import SwiftUI

/// Beautiful frosted-glass dropdown showing live search suggestions.
/// Designed to match the app's dark wallpaper background.
struct SearchAutocompleteView: View {
    let suggestions: [String]
    let query: String
    /// Dark variant (for home page over wallpaper) vs light variant (for search results).
    var darkVariant: Bool = true
    var onSelect: (String) -> Void
    /// Called when user wants to fill the input without searching.
    var onFill: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                row(suggestion: suggestion, index: index)
                if index < suggestions.count - 1 {
                    Divider()
                        .background(dividerColor)
                        .padding(.leading, 40)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, darkVariant ? .dark : .light)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(darkVariant ? 0.3 : 0.08), radius: 16, y: 6)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Row

    private func row(suggestion: String, index: Int) -> some View {
        Button {
            HapticsManager.light()
            onSelect(suggestion)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                // Highlighted query part
                highlightedText(suggestion)

                Spacer(minLength: 4)

                // Arrow to fill input (edit before searching)
                Button {
                    HapticsManager.light()
                    onFill(suggestion)
                } label: {
                    Image(systemName: "arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(iconColor)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Highlighted text

    /// Highlights the query portion (matches) vs the rest (suggested addition).
    private func highlightedText(_ suggestion: String) -> some View {
        buildHighlightedText(suggestion)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private func buildHighlightedText(_ suggestion: String) -> Text {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lower = suggestion.lowercased()
        guard !q.isEmpty, let range = lower.range(of: q) else {
            return Text(suggestion)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(textColor)
        }

        let prefix = String(suggestion[suggestion.startIndex..<range.lowerBound])
        let middle = String(suggestion[range])
        let suffix = String(suggestion[range.upperBound..<suggestion.endIndex])

        let prefixText = Text(prefix).font(.system(size: 14)).foregroundColor(addendumColor)
        let middleText = Text(middle).font(.system(size: 14, weight: .semibold)).foregroundColor(textColor)
        let suffixText = Text(suffix).font(.system(size: 14)).foregroundColor(addendumColor)
        return prefixText + middleText + suffixText
    }

    // MARK: - Colors

    private var textColor: Color {
        darkVariant ? Color.white.opacity(0.95) : Color(UIColor.label)
    }

    private var addendumColor: Color {
        darkVariant ? Color.white.opacity(0.55) : Color(UIColor.secondaryLabel)
    }

    private var iconColor: Color {
        darkVariant ? Color.white.opacity(0.55) : Color(UIColor.secondaryLabel)
    }

    private var dividerColor: Color {
        darkVariant ? Color.white.opacity(0.08) : Color(UIColor.separator).opacity(0.3)
    }

    private var borderColor: Color {
        darkVariant ? Color.white.opacity(0.1) : Color(UIColor.separator).opacity(0.3)
    }
}
