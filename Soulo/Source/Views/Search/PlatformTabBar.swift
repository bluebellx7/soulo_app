import SwiftUI

struct PlatformTabBar: View {
    let platforms: [SearchPlatform]
    @Binding var selectedPlatform: SearchPlatform?
    let onEnterFullscreen: () -> Void
    var usesContrastingControlSurface: Bool = false
    @EnvironmentObject var languageManager: LanguageManager
    @Namespace private var platformNamespace

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(platforms) { platform in
                            PlatformTab(
                                platform: platform,
                                isSelected: selectedPlatform?.id == platform.id,
                                namespace: platformNamespace
                            ) {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    selectedPlatform = platform
                                }
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                            .id(platform.id)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 8)
                    .padding(.vertical, 6)
                }
                .onChange(of: selectedPlatform) { _, newValue in
                    if let id = newValue?.id {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            Button(action: onEnterFullscreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(
                        usesContrastingControlSurface
                            ? Color(uiColor: .systemGray).opacity(0.88)
                            : Color.primary.opacity(0.58)
                    )
                    .frame(width: 32, height: 32)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("enter_fullscreen"))
            .padding(.trailing, 4)
        }
    }
}

private struct PlatformTab: View {
    let platform: SearchPlatform
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Button(action: action) {
            PlatformIconView(platform: platform, size: 18)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .saturation(isSelected ? 1.0 : 0.0)
                .opacity(isSelected ? 1.0 : 0.48)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color(hex: "6366F1"))
                            .frame(height: 2)
                            .offset(y: 4)
                            .matchedGeometryEffect(id: "platformTab", in: namespace)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
