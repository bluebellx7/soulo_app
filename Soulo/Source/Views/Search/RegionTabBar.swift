import SwiftUI

struct RegionTabBar: View {
    @Binding var selectedRegion: PlatformRegion
    @EnvironmentObject var languageManager: LanguageManager
    @Namespace private var tabNamespace

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(PlatformRegion.allCases) { region in
                    RegionTab(
                        region: region,
                        isSelected: selectedRegion == region,
                        namespace: tabNamespace
                    ) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedRegion = region
                        }
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

private struct RegionTab: View {
    let region: PlatformRegion
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @EnvironmentObject var languageManager: LanguageManager

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(languageManager.localizedString(region.nameKey))
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(hex: "4F46E5"), Color(hex: "7C3AED")],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .matchedGeometryEffect(id: "regionTab", in: namespace)
                } else {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.1), lineWidth: 0.5)
                        )
                }
            }
            .foregroundStyle(isSelected ? .white : Color(UIColor.label))
        }
        .buttonStyle(.plain)
    }
}
