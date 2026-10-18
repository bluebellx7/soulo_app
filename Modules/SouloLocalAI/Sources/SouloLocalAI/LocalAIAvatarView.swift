#if canImport(UIKit)
import SwiftUI

public struct LocalAIFloatingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var store = LocalAIModelStore.shared
    @AppStorage("soulo.localAI.enabled") private var enabled = false
    @AppStorage("soulo.localAI.floating") private var floating = false
    @AppStorage("soulo.localAI.avatar") private var avatar = "orbit"
    @AppStorage("soulo.localAI.floating.x") private var positionX = 1.0
    @AppStorage("soulo.localAI.floating.y") private var positionY = 0.85
    @GestureState private var drag: CGSize = .zero
    private let action: @MainActor () -> Void
    public init(action: @escaping @MainActor () -> Void) { self.action = action }
    public var body: some View {
        if floating && enabled && store.selectedModelURL != nil {
            GeometryReader { geometry in
                let visual = LocalAICompanionLayout.center(in: geometry.size, right: positionX >= 0.5, fraction: positionY, drag: drag)
                let hit = LocalAICompanionLayout.hitCenter(visual, in: geometry.size)
                Button(action: action) {
                    LocalAIAnimatedAvatar(avatar: avatar, isDragging: drag != .zero)
                        .frame(width: 38, height: 38).padding(5)
                        .background(.regularMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
                        .offset(x: visual.x - hit.x)
                        .frame(width: 44, height: 64).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .position(hit)
                    .highPriorityGesture(DragGesture(minimumDistance: 10).updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let end = LocalAICompanionLayout.center(in: geometry.size, right: positionX >= 0.5, fraction: positionY, drag: value.translation)
                            withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85)) {
                                positionX = end.x < geometry.size.width / 2 ? 0 : 1
                                positionY = min(1, max(0, (end.y - 32) / max(1, geometry.size.height - 64)))
                            }
                        })
                    .onAppear { positionX = positionX < 0.5 ? 0 : 1 }
                    .accessibilityLabel(AIL10n.text("title")).accessibilityIdentifier("localAI.floating")
            }.clipped().ignoresSafeArea(edges: .horizontal)
        }
    }
}
private struct LocalAIAnimatedAvatar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let avatar: String
    let isDragging: Bool
    var body: some View {
        let animates = !reduceMotion && scenePhase == .active && !isDragging
        LocalAIAvatar(avatar: avatar).phaseAnimator(animates ? [false, true] : [false]) { content, phase in
            content.scaleEffect(animates && phase ? 1.04 : 1)
                .rotationEffect(.degrees(animates ? (phase ? 2 : -2) : 0))
                .offset(y: animates ? (phase ? -1.5 : 1.5) : 0)
        } animation: { _ in animates ? .easeInOut(duration: 2.6) : .linear(duration: 0) }
    }
}
struct LocalAIAvatar: View {
    let avatar: String
    private var color: Color { avatar == "cat" ? .orange : avatar == "sprout" ? .mint : avatar == "robot" ? .cyan : LocalAIStyle.accent }
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            ZStack {
                if avatar == "cat" {
                    HStack { ear; Spacer(); ear }.frame(width: size * 0.65, height: size * 0.3).offset(y: -size * 0.27)
                }
                if avatar == "sprout" {
                    Capsule().fill(.green).frame(width: size * 0.34, height: size * 0.16).rotationEffect(.degrees(-30)).offset(x: size * 0.13, y: -size * 0.33)
                }
                if avatar == "robot" {
                    Capsule().fill(color).frame(width: size * 0.09, height: size * 0.22).offset(y: -size * 0.35)
                    Circle().fill(color).frame(width: size * 0.13).offset(y: -size * 0.44)
                }
                RoundedRectangle(cornerRadius: avatar == "robot" ? size * 0.22 : size * 0.42)
                    .fill(color).frame(width: size * 0.82, height: size * 0.76)
                    .overlay(alignment: .topLeading) { Ellipse().fill(.white.opacity(0.4)).frame(width: size * 0.32, height: size * 0.16).rotationEffect(.degrees(-25)).offset(x: size * 0.12, y: size * 0.07) }
                HStack(spacing: size * 0.15) {
                    Capsule().fill(Color.black.opacity(0.78)).frame(width: size * 0.075, height: size * 0.16)
                    Capsule().fill(Color.black.opacity(0.78)).frame(width: size * 0.075, height: size * 0.16)
                }.offset(y: size * 0.01)
                Capsule().fill(Color.black.opacity(0.55)).frame(width: size * 0.13, height: size * 0.035).offset(y: size * 0.18)
            }.frame(width: proxy.size.width, height: proxy.size.height)
        }.accessibilityHidden(true)
    }
    private var ear: some View { RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 20).rotationEffect(.degrees(30)) }
}
struct LocalAIAvatarSettingsView: View {
    @AppStorage("soulo.localAI.avatar") private var avatar = "orbit"
    @AppStorage("soulo.localAI.floating") private var floating = false
    private let variants = ["orbit", "cat", "sprout", "robot"]
    var body: some View {
        Form {
            Section { Toggle(AIL10n.text("floating"), isOn: $floating).accessibilityIdentifier("localAI.floating.enable") }
            Section {
                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 16) {
                    ForEach(variants, id: \.self) { variant in
                        Button { avatar = variant } label: {
                            VStack(spacing: 12) {
                                LocalAIAvatar(avatar: variant).frame(width: 72, height: 72)
                                HStack(spacing: 6) {
                                    Text(AIL10n.text("avatar_" + variant))
                                    if avatar == variant { Image(systemName: "checkmark.circle.fill") }
                                }.font(.subheadline)
                            }.frame(maxWidth: .infinity).padding(.vertical, 18)
                                .background(avatar == variant ? LocalAIStyle.accent.opacity(0.10) : Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain).accessibilityIdentifier("localAI.avatar.\(variant)")
                    }
                }.listRowBackground(Color.clear).listRowInsets(.init())
            } header: { Text(AIL10n.text("avatar")) }
        }.navigationTitle(AIL10n.text("assistant_style")).navigationBarTitleDisplayMode(.inline).tint(LocalAIStyle.accent)
    }
}
#endif
