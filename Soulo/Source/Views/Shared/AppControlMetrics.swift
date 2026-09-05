import SwiftUI

enum AppControlMetrics {
    static let iconDiameter: CGFloat = 34
    static let iconSize: CGFloat = 13
    static let minimumHitSize: CGFloat = 44
    static let actionHeight: CGFloat = 44
}

/// Standard actions share shape, typography, state feedback and the inherited tint.
struct CompactActionButtonStyle: ButtonStyle {
    var prominent = false
    var fillsHeight = false
    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 15
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        let destructive = configuration.role == .destructive
        configuration.label
            .font(.system(size: labelSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .frame(minHeight: AppControlMetrics.actionHeight)
            .frame(maxHeight: fillsHeight ? .infinity : nil)
            .foregroundStyle(prominent ? Color.white : destructive ? Color.red : Color.primary)
            .background {
                Capsule().fill(prominent
                    ? (destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tint))
                    : AnyShapeStyle(Color(uiColor: .tertiarySystemFill)))
            }
            .overlay { if !prominent { Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) } }
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

/// For standalone icon actions in content rows; navigation bars supply their own background.
struct CompactIconLabel: View {
    let systemImage: String
    var emphasized = false
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
            .foregroundStyle(emphasized ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
            .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
            .contentShape(Rectangle())
    }
}

/// Equal columns when labels fit; stacked actions for narrow screens and large text.
struct AdaptiveActionRow: Layout {
    var spacing: CGFloat = 12
    @Environment(\.layoutDirection) private var layoutDirection

    private func measurement(width: CGFloat?, subviews: Subviews) -> (width: CGFloat, stacked: Bool, sizes: [CGSize]) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let totalSpacing = spacing * CGFloat(max(0, subviews.count - 1))
        let available = max(0, width ?? (ideal.map(\.width).reduce(0, +) + totalSpacing))
        let stacked = (ideal.map(\.width).max() ?? 0) * CGFloat(subviews.count) + totalSpacing > available + 0.5
        let column = stacked ? available : max(0, (available - totalSpacing) / CGFloat(max(1, subviews.count)))
        return (available, stacked, subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)) })
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let m = measurement(width: proposal.width, subviews: subviews)
        let height = m.stacked
            ? m.sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1))
            : m.sizes.map(\.height).max() ?? 0
        return CGSize(width: m.width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let m = measurement(width: bounds.width, subviews: subviews)
        var origin = bounds.origin
        for (index, view) in subviews.enumerated() {
            let size = CGSize(width: m.sizes[index].width, height: m.stacked ? m.sizes[index].height : bounds.height)
            let x = !m.stacked && layoutDirection == .rightToLeft
                ? bounds.maxX - (origin.x - bounds.minX) - size.width : origin.x
            view.place(at: CGPoint(x: x, y: origin.y), anchor: .topLeading, proposal: ProposedViewSize(size))
            if m.stacked { origin.y += size.height + spacing } else { origin.x += size.width + spacing }
        }
    }
}

enum CaptureActionLayout {
    static func verticalPadding(bottomSafeArea: CGFloat) -> CGFloat { max(12, bottomSafeArea) }
}
