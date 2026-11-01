import SwiftUI

struct HomeToolbarSettingsView: View {
    @ObservedObject private var service = HomeToolbarConfigurationService.shared
    @State private var draft = Array(repeating: HomeToolbarAction.none, count: HomeToolbarConfigurationService.slotCount)
    @State private var slot = 0
    @State private var draftShowsBackground = false
    @State private var saved = false
    @State private var restore = false
    @State private var search = ""
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
                                    .modifier(HomeToolbarButtonSurface(visible: draftShowsBackground, radius: 20))
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
                    Toggle(ToolText.text("home_toolbar_button_background"), isOn: $draftShowsBackground)
                        .tint(Color.themePrimary)
                        .accessibilityIdentifier("home-toolbar.background")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(LanguageManager.shared.localizedString("toolbar_replace_action")).font(.headline)
                    LazyVGrid(columns: ToolbarActionPickerLayout.columns, spacing: 10) {
                        ForEach(actions) { action in
                            Button { draft[slot] = action; HapticsManager.selection() } label: {
                                ToolbarActionChoiceLabel(symbol: action.listSymbol, title: action.title, isSelected: draft[slot] == action)
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
                Button { service.save(draft, showsButtonBackground: draftShowsBackground); saved = true; HapticsManager.selection() } label: {
                    Label(LanguageManager.shared.localizedString("save"), systemImage: "checkmark")
                }.buttonStyle(CompactActionButtonStyle(prominent: true, fillsHeight: true))
                    .accessibilityIdentifier("home-toolbar.save")
            }.padding(.horizontal, 16).padding(.vertical, 12).background(.regularMaterial)
        }
        .navigationTitle(ToolText.text("home_toolbar_customize")).navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = service.actions; draftShowsBackground = service.showsButtonBackground }
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
    var isActive = false
    var isLoading = false
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: action == .none ? "\(placeholder ?? 1).circle" : action == .privateBrowsing && isActive ? "eye.slash.fill" : action.symbol)
                }
            }
            .font(.system(size: showsTitle ? 22 : 20, weight: .medium)).frame(height: 25)
            if showsTitle { Text(action.title).font(.caption2.weight(.medium)).lineLimit(1) }
        }
        .foregroundStyle(lightWallpaper ? Color(hex: "242635").opacity(0.85) : .white.opacity(0.85))
        .frame(maxWidth: showsTitle ? .infinity : nil)
        .frame(width: showsTitle ? nil : 50, height: showsTitle ? 68 : 48)
        .padding(.horizontal, showsTitle ? 4 : 0)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
struct HomeToolbarButtonStyle: ButtonStyle {
    var lightWallpaper = false
    var showsBackground = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HomeToolbarButtonSurface(visible: showsBackground || configuration.isPressed,
                lightWallpaper: lightWallpaper))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
    }
}

private struct HomeToolbarButtonSurface: ViewModifier {
    let visible: Bool
    var lightWallpaper = false
    var radius: CGFloat = 16
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if visible {
                    if reduceTransparency {
                        shape.fill(lightWallpaper ? Color(hex: "F0F1F5") : Color(hex: "252734"))
                    } else if lightWallpaper {
                        shape.fill(Color.black.opacity(0.04))
                    } else {
                        shape.fill(.ultraThinMaterial.opacity(0.3))
                    }
                }
            }

    }
}
