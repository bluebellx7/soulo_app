import SwiftUI

struct PlatformTabBar: View {
    let platforms: [SearchPlatform]
    @Binding var selectedPlatform: SearchPlatform?
    @EnvironmentObject var languageManager: LanguageManager
    @Namespace private var platformNamespace

    var body: some View {
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
                .padding(.horizontal, 16)
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
                .opacity(isSelected ? 1.0 : 0.45)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color(hex: "6366F1"))
                            .frame(height: 2)
                            .offset(y: 4)
                            .matchedGeometryEffect(id: "platformTab", in: namespace)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
