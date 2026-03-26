import SwiftUI

struct SearchSuggestionsView: View {
    let recentSearches: [String]
    var onTap: (String) -> Void
    var onDelete: (String) -> Void

    @EnvironmentObject var languageManager: LanguageManager
    @State private var showAll = false

    var body: some View {
        if !recentSearches.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header
                HStack {
                    Text(languageManager.localizedString("recent_searches"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))

                    Spacer()

                    if recentSearches.count > 6 {
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                showAll.toggle()
                            }
                        } label: {
                            Text(languageManager.localizedString(showAll ? "show_less" : "show_more"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(.horizontal, 30)

                // Tags
                FlowLayout(spacing: 8) {
                    ForEach(displayedSearches, id: \.self) { keyword in
                        SuggestionChip(
                            text: keyword,
                            onTap: { onTap(keyword) },
                            onDelete: { onDelete(keyword) }
                        )
                    }
                }
                .padding(.horizontal, 30)
            }
        }
    }

    private var displayedSearches: [String] {
        showAll ? recentSearches : Array(recentSearches.prefix(6))
    }
}

// MARK: - Suggestion Chip

private struct SuggestionChip: View {
    let text: String
    let onTap: () -> Void
    let onDelete: () -> Void

    @State private var showDelete = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 10))

                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 150)

                if showDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .padding(2)
                    }
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.06))
            .foregroundStyle(.white.opacity(0.7))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onLongPressGesture {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showDelete.toggle()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
