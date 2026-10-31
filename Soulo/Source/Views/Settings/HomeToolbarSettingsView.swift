import SwiftUI

struct HomeToolbarSettingsView: View {
    @ObservedObject private var service = HomeToolbarConfigurationService.shared
    @State private var draft = Array(repeating: HomeToolbarAction.none, count: HomeToolbarConfigurationService.slotCount)
    @State private var slot = 0
    @State private var saved = false
    @State private var restore = false
    @State private var search = ""
    @ScaledMetric(relativeTo: .caption) private var minimumWidth: CGFloat = 92
    private var actions: [HomeToolbarAction] {
        HomeToolbarAction.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(LanguageManager.shared.localizedString("toolbar_preview")).font(.headline)
                    HStack(spacing: 8) {
                        ForEach(0..<HomeToolbarConfigurationService.slotCount, id: \.self) { index in
                            Button { slot = index; HapticsManager.selection() } label: {
                                HomeToolbarButtonFace(action: draft[index], lightWallpaper: false, placeholder: index + 1, showsTitle: true)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 20).stroke(slot == index ? Color.themePrimary : .clear, lineWidth: 2)
                                    }
                            }.buttonStyle(.plain).accessibilityIdentifier("home-toolbar.slot.\(index)")
                                .accessibilityLabel(String(format: ToolText.text("home_toolbar_slot"), index + 1) + ", " + draft[index].title)
                                .accessibilityAddTraits(slot == index ? .isSelected : [])
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(Color(hex: "28374B"), in: RoundedRectangle(cornerRadius: 26))
                    Text(String(format: ToolText.text("home_toolbar_hint"), HomeToolbarConfigurationService.slotCount)).font(.footnote).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(LanguageManager.shared.localizedString("toolbar_replace_action")).font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumWidth), spacing: 10)], spacing: 10) {
                        ForEach(actions) { action in
                            Button { draft[slot] = action; HapticsManager.selection() } label: {
                                VStack(spacing: 10) {
                                    Image(systemName: action.symbol).font(.system(size: 23, weight: .medium)).frame(height: 28)
                                    Text(action.title).font(.caption.weight(.medium)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 92).padding(.horizontal, 8).padding(.vertical, 10)
                                .foregroundStyle(draft[slot] == action ? Color.themePrimary : .primary)
                                .background(draft[slot] == action ? Color.themePrimary.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                                .overlay { RoundedRectangle(cornerRadius: 18).stroke(draft[slot] == action ? Color.themePrimary : .clear, lineWidth: 2) }
                            }.buttonStyle(.plain).accessibilityIdentifier("home-toolbar.action.\(action.rawValue)")
                                .accessibilityAddTraits(draft[slot] == action ? .isSelected : [])
                        }
                    }
                }
            }.padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .searchable(text: $search, prompt: ToolText.text("home_toolbar_search"))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            AdaptiveActionRow(spacing: 12) {
                Button { restore = true } label: { Label(ToolText.text("home_toolbar_reset"), systemImage: "arrow.counterclockwise") }
                    .buttonStyle(CompactActionButtonStyle(fillsHeight: true))
                Button { service.save(draft); saved = true; HapticsManager.selection() } label: {
                    Label(LanguageManager.shared.localizedString("save"), systemImage: "checkmark")
                }.buttonStyle(CompactActionButtonStyle(prominent: true, fillsHeight: true))
                    .accessibilityIdentifier("home-toolbar.save")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
        }
        .navigationTitle(ToolText.text("home_toolbar_customize")).navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = service.actions }
        .alert(LanguageManager.shared.localizedString("toolbar_saved"), isPresented: $saved) {
            Button(ToolText.text("done"), role: .cancel) {}
        }
        .confirmationDialog(ToolText.text("home_toolbar_reset"), isPresented: $restore, titleVisibility: .visible) {
            Button(ToolText.text("home_toolbar_reset"), role: .destructive) { draft = Array(repeating: .none, count: HomeToolbarConfigurationService.slotCount); service.save(draft) }
        } message: { Text(ToolText.text("home_toolbar_default_hint")) }
    }
}

struct HomeToolbarButtonFace: View {
    let action: HomeToolbarAction
    let lightWallpaper: Bool
    var placeholder: Int?
    var showsTitle = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: action == .none ? "\(placeholder ?? 1).circle" : action.symbol)
                .font(.system(size: showsTitle ? 22 : 20, weight: .medium)).frame(height: 25)
            if showsTitle { Text(action.title).font(.caption2.weight(.medium)).lineLimit(1) }
        }
        .foregroundStyle(lightWallpaper ? Color(hex: "242635") : .white)
        .frame(maxWidth: showsTitle ? .infinity : nil)
        .frame(width: showsTitle ? nil : 50, height: showsTitle ? 68 : 48)
        .padding(.horizontal, showsTitle ? 4 : 0)
        .modifier(HomeToolbarGlass(light: lightWallpaper, opaque: reduceTransparency, radius: showsTitle ? 20 : 16))
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
private struct HomeToolbarGlass: ViewModifier {
    let light: Bool
    let opaque: Bool
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        if opaque {
            content.background(light ? Color(uiColor: .secondarySystemGroupedBackground) : Color(hex: "252734"), in: RoundedRectangle(cornerRadius: radius))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: radius))
        } else {
            content.background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).stroke(.white.opacity(light ? 0.4 : 0.18), lineWidth: 0.7) }
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        }
    }
}
