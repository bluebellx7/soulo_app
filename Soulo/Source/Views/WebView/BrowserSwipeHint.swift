import SwiftUI

/// Only this small view observes touch samples. The webpage stays interactive
/// around the hint, and no dimming layer or full-screen panel is presented.
struct BrowserSwipeHint: View {
    @ObservedObject var request: BrowserSwipeRequest
    var menu: [BrowserSwipeAction] = BrowserSwipePreferences.defaultMenu
    var isAvailable: (BrowserSwipeAction) -> Bool = { _ in true }
    var automaticallyExecute = true
    let onAction: (BrowserSwipeAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var hintSize: CGSize = .zero

    var body: some View {
        GeometryReader { geometry in
            let maximumWidth = min(250, max(180, geometry.size.width - 72))
            let follow = reduceMotion ? 0 : min(12, request.motion.distance * 0.08)
            let isMenu = request.action == .menu
            let maximumHeight = max(100, geometry.size.height - 32)
            let halfHeight: CGFloat = hintSize.height > 0 ? min(maximumHeight, hintSize.height) / 2 : (isMenu ? min(geometry.size.height / 2 - 16, CGFloat(menu.count) * 31) : (dynamicTypeSize.isAccessibilitySize ? 100 : 44))
            let fingerY = request.motion.windowY.map { $0 - geometry.frame(in: .global).minY }
                ?? request.motion.verticalFraction * geometry.size.height
            let y = min(geometry.size.height - halfHeight - 12, max(halfHeight + 12, fingerY - halfHeight - 24))
            HStack(spacing: 0) {
                if request.direction == .left { Spacer(minLength: 0) }
                hintContent(maximumWidth: maximumWidth, maximumHeight: maximumHeight)
                    .environment(\.layoutDirection, layoutDirection)
                if request.direction == .right { Spacer(minLength: 0) }
            }
            .environment(\.layoutDirection, .leftToRight)
            .padding(.horizontal, 10 + follow)
            .frame(width: geometry.size.width)
            .onPreferenceChange(SwipeHintSizeKey.self) { if $0 != .zero && $0 != hintSize { hintSize = $0 } }
            .opacity(request.phase == .dragging ? 0.45 + Double(request.motion.progress) * 0.55 : 1)
            .scaleEffect(reduceMotion ? 1 : 0.92 + request.motion.progress * 0.08)
            .position(x: geometry.size.width / 2, y: y)
        }
        .onAppear(perform: executeIfReady)
        .onCompatibleChange(of: request.phase) { _, _ in executeIfReady() }
    }

    @ViewBuilder
    private func hintContent(maximumWidth: CGFloat, maximumHeight: CGFloat) -> some View {
        let content = rows(maximumWidth: maximumWidth)
            .fixedSize(horizontal: true, vertical: true)
            .background(GeometryReader { proxy in Color.clear.preference(key: SwipeHintSizeKey.self, value: proxy.size) })
        if request.action == .menu && hintSize.height > maximumHeight {
            ScrollView { content }.compatibleSizeBasedBounce()
                .frame(width: min(maximumWidth, hintSize.width), height: maximumHeight)
        } else { content }
    }

    private func rows(maximumWidth: CGFloat) -> some View {
        let physicalLeading = (request.direction == .right) == (layoutDirection == .leftToRight)
        return VStack(alignment: physicalLeading ? .leading : .trailing, spacing: 6) {
            ForEach(request.action == .menu ? menu : [request.action]) { action in
                Button { if request.phase == .ready { onAction(action) } } label: {
                    SwipeHintContentLayout(maximumWidth: maximumWidth) {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.themePrimary.opacity(request.motion.progress >= 1 ? 1 : 0.1))
                            Circle().stroke(Color.themePrimary.opacity(0.16), lineWidth: 2)
                            Circle().trim(from: 0, to: request.motion.progress)
                                .stroke(Color.themePrimary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Image(systemName: action == .closeTab ? "xmark" : action.symbol)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(request.motion.progress >= 1 ? Color.white : Color.themePrimary)
                                .scaleEffect(request.phase == .executing && action == .closeTab ? 0.2 : 1)
                                .opacity(request.phase == .executing && action == .closeTab ? 0 : 1)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: request.phase)
                            if request.phase == .executing && action == .closeTab && !reduceMotion { SwipeCloseBurst() }
                        }
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                        Text(action.title).font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    }
                    .modifier(SwipeHintGlass())
                    .opacity(isAvailable(action) ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .allowsHitTesting(request.phase == .ready && isAvailable(action))
                .accessibilityLabel(action.title)
                .accessibilityValue("\(Int((request.motion.progress * 100).rounded()))%")
                .accessibilityHint(request.execution.title)
                .accessibilityIdentifier("browser.gesture.action.\(action.rawValue)")
            }
        }.padding(4)
    }

    private func executeIfReady() {
        guard automaticallyExecute, request.phase == .ready, request.execution == .release,
              request.action != .menu else { return }
        onAction(request.action)
    }
}

private struct SwipeHintSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct SwipeHintContentLayout: Layout {
    let maximumWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        return content.sizeThatFits(.init(width: min(maximumWidth, ideal.width), height: nil))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

private struct SwipeHintGlass: ViewModifier {
    func body(content: Content) -> some View {
        content.background { Capsule().fill(.ultraThinMaterial).opacity(0.82) }
            .overlay(Capsule().stroke(.primary.opacity(0.07), lineWidth: 0.7))
            .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

private struct SwipeCloseBurst: View {
    @State private var progress: CGFloat = 0
    private let colors: [Color] = [.themePrimary, .purple, .cyan]
    var body: some View {
        ZStack {
            ForEach(0..<14) { index in
                let angle = Double(index) * .pi * 2 / 14
                let radius = (26 + CGFloat(index % 3) * 7) * progress
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(colors[index % colors.count])
                    .frame(width: index.isMultiple(of: 3) ? 4 : 3, height: index.isMultiple(of: 2) ? 7 : 4)
                    .rotationEffect(.degrees(Double(index * 37) + Double(progress) * 90))
                    .offset(x: CGFloat(cos(angle)) * radius, y: CGFloat(sin(angle)) * radius + 10 * progress * progress)
                    .scaleEffect(1 - progress * 0.4).opacity(Double(1 - progress))
            }
        }
        .onAppear { withAnimation(.easeOut(duration: 0.28)) { progress = 1 } }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}
