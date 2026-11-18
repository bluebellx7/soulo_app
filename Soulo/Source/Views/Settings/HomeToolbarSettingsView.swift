import SwiftUI

/// Keep existing shortcuts and search routes opening the Home section.
struct HomeToolbarSettingsView: View {
    var body: some View { BrowserToolbarSettingsView(initialSection: .home) }
}

struct HomeToolbarEditor: View {
    @Binding var draft: [HomeToolbarAction]
    @Binding var layout: HomeToolbarLayout
    @EnvironmentObject private var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var direction
    @ObservedObject private var wallpaper = WallpaperManager.shared
    @AppStorage("home_title") private var title = "Soulo"
    @AppStorage("home_subtitle") private var subtitle = AppConstants.defaultHomeSubtitle
    @State private var section: Section = .style
    @State private var choiceSlot: Int?
    @State private var search = ""
    @GestureState private var placementDrag: CGSize = .zero
    @GestureState private var reorderDrag: ReorderDrag?

    private enum Section: String, CaseIterable {
        case style, position, buttons

        @MainActor var label: String {
            self == .style ? LanguageManager.shared.localizedString("appearance") : ToolText.text("home_toolbar_" + rawValue)
        }
        var icon: String {
            switch self {
            case .style: "paintbrush"
            case .position: "arrow.up.left.and.down.right"
            case .buttons: "square.grid.2x2"
            }
        }
    }

    private struct ReorderDrag {
        let slot: Int
        let offset: CGSize
    }

    private var wallpaperAppearance: WallpaperAppearance { WallpaperAppearance(colorScheme) }
    private var usesDarkInk: Bool { wallpaper.prefersDarkForeground(for: wallpaperAppearance) }
    private var previewInk: Color { usesDarkInk ? Color(hex: "242635") : .white }

    var body: some View {
        ViewThatFits(in: .vertical) {
            editorContents()
            ScrollView {
                editorContents(previewHeight: 240)
            }
        }
        .sheet(isPresented: Binding(get: { choiceSlot != nil }, set: { if !$0 { choiceSlot = nil } })) {
            if let slot = choiceSlot {
                actionPicker(for: slot)
            }
        }
    }

    private func editorContents(previewHeight: CGFloat? = nil) -> some View {
        VStack(spacing: 14) {
            preview.frame(minHeight: previewHeight ?? 196, maxHeight: previewHeight ?? 570)
            controls.fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    private var preview: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 28)
            let normalHeight = max(0, geometry.size.height - 56)
            let height = normalHeight + (layout.placement == .free ? 14 : 0)
            let visible = draft.indices.filter { draft[$0] != .none }
            let nextSlot = draft.firstIndex(of: .none)
            let addSlot = (section == .buttons || visible.isEmpty) ? nextSlot : nil
            let slots = visible + (addSlot.map { [$0] } ?? [])
            let metrics = HomeToolbarMetrics(width: width, height: height, count: slots.count, style: layout.style)
            let usable = CGSize(width: width, height: height)
            let searchBottom = max(96, normalHeight * 0.46)
            ZStack(alignment: .topLeading) {
                WallpaperBackground(isAnimating: false, appearanceOverride: wallpaperAppearance)
                VStack {
                    HStack {
                        Image(systemName: "square.on.square")
                        Spacer()
                        Image(systemName: "ellipsis")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(previewInk.opacity(0.78))
                    Spacer()
                }
                .padding(16)
                .accessibilityHidden(true)
                ZStack(alignment: .topLeading) {
                    previewHome(width: width)
                        .frame(height: 96, alignment: .bottom)
                        .position(x: width / 2, y: searchBottom - 48)
                        .accessibilityHidden(true)
                    if section == .position, layout.placement == .free, placementDrag != .zero {
                        previewGuides(in: usable, strip: metrics.size)
                            .allowsHitTesting(false)
                    }
                    if !slots.isEmpty {
                        previewStrip(slots, metrics: metrics)
                            .position(previewCenter(in: usable, strip: metrics.size, searchBottom: searchBottom))
                    }
                }
                .frame(width: width, height: height)
                .offset(x: 14, y: 42)
            }
        }
        .background(Color(hex: "19202F"))
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .overlay { RoundedRectangle(cornerRadius: 30).strokeBorder(.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
    }

    private func previewHome(width: CGFloat) -> some View {
        VStack(spacing: 7) {
            if !title.isEmpty {
                Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).lineLimit(1)
            }
            if !subtitle.isEmpty {
                Text(subtitle).font(.caption.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                Text(LanguageManager.shared.localizedString("search_placeholder")).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .frame(height: 37)
            .background(previewInk.opacity(0.14), in: Capsule())
            .padding(.top, 3)
        }
        .foregroundStyle(previewInk)
        .frame(width: max(1, min(width * 0.88, 380)))
    }

    private func previewCenter(in area: CGSize, strip: CGSize, searchBottom: CGFloat) -> CGPoint {
        switch layout.placement {
        case .free: return layout.center(in: area, strip: strip, translation: placementDrag)
        case .belowSearch: return CGPoint(x: area.width / 2, y: min(area.height - strip.height / 2, searchBottom + 10 + strip.height / 2))
        case .bottom:
            var bottom = layout
            bottom.x = layout.alignment.physicalFraction(rightToLeft: direction == .rightToLeft)
            bottom.y = 1
            return bottom.center(in: area, strip: strip)
        }
    }

    private func previewGuides(in area: CGSize, strip: CGSize) -> some View {
        let center = layout.center(in: area, strip: strip, translation: placementDrag)
        return ZStack {
            if abs(center.x - area.width / 2) < 10 {
                Rectangle().fill(.white.opacity(0.72)).frame(width: 1, height: area.height)
            }
            if abs(center.y - area.height / 2) < 10 {
                Rectangle().fill(.white.opacity(0.72)).frame(width: area.width, height: 1)
            }
        }.frame(width: area.width, height: area.height)
    }

    @ViewBuilder
    private func previewStrip(_ slots: [Int], metrics: HomeToolbarMetrics) -> some View {
        if section == .position, layout.placement == .free {
            strip(slots, metrics: metrics, editable: false)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($placementDrag) { value, drag, _ in drag = value.translation }
                    .onEnded { value in
                        layout.move(by: value.translation, in: metrics.area, strip: metrics.size)
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ToolText.text("home_toolbar_free"))
                .accessibilityIdentifier("home-toolbar.drag")
                .accessibilityActions {
                    nudge("left", dx: -24, dy: 0, metrics: metrics)
                    nudge("right", dx: 24, dy: 0, metrics: metrics)
                    nudge("up", dx: 0, dy: -24, metrics: metrics)
                    nudge("down", dx: 0, dy: 24, metrics: metrics)
                }
        } else {
            strip(slots, metrics: metrics, editable: true)
        }
    }

    private func nudge(_ direction: String, dx: CGFloat, dy: CGFloat, metrics: HomeToolbarMetrics) -> some View {
        Button(LanguageManager.shared.localizedString("accessibility_move_" + direction)) {
            layout.move(by: CGSize(width: dx, height: dy), in: metrics.area, strip: metrics.size)
        }
    }

    private func strip(_ slots: [Int], metrics: HomeToolbarMetrics, editable: Bool) -> some View {
        HomeToolbarStrip(indices: slots, metrics: metrics, style: layout.style, lightWallpaper: usesDarkInk) { slot in
            let action = draft[slot]
            Button {
                section = .buttons
                search = ""
                choiceSlot = slot
                HapticsManager.selection()
            } label: {
                HomeToolbarButtonFace(action: action, lightWallpaper: usesDarkInk, tabCount: tabManager.tabCount)
            }
            .buttonStyle(HomeToolbarButtonStyle(lightWallpaper: usesDarkInk, showsBackground: layout.style == .tiles))
            .accessibilityLabel(action == .none ? LanguageManager.shared.localizedString("userscripts_install") :
                String(format: ToolText.text("home_toolbar_slot"), slot + 1) + ", " + action.title)
            .accessibilityIdentifier("home-toolbar.slot.\(slot)")
            .disabled(!editable)
            .offset(reorderDrag?.slot == slot ? reorderDrag?.offset ?? .zero : .zero)
            .zIndex(reorderDrag?.slot == slot ? 1 : 0)
            .highPriorityGesture(
                DragGesture(minimumDistance: 14, coordinateSpace: .global)
                    .updating($reorderDrag) { value, drag, _ in drag = ReorderDrag(slot: slot, offset: value.translation) }
                    .onEnded { value in
                        guard let source = slots.firstIndex(of: slot) else { return }
                        let visible = slots.filter { draft[$0] != .none }
                        let target = metrics.target(from: source, translation: value.translation, count: visible.count,
                            rightToLeft: direction == .rightToLeft)
                        if visible.indices.contains(target) { reorder(slot, to: visible[target]) }
                    },
                including: editable && section == .buttons && action != .none ? .all : .none
            )
            .accessibilityActions {
                if section == .buttons, action != .none {
                    let visible = slots.filter { draft[$0] != .none }
                    if let index = visible.firstIndex(of: slot) {
                        if index > 0 { Button(ToolText.text("quick_actions_up")) { reorder(slot, to: visible[index - 1]) } }
                        if index + 1 < visible.count { Button(ToolText.text("quick_actions_down")) { reorder(slot, to: visible[index + 1]) } }
                    }
                }
            }
        }
    }

    private func reorder(_ source: Int, to destination: Int) {
        guard source != destination else { return }
        let action = draft.remove(at: source)
        draft.insert(action, at: destination)
        HapticsManager.selection()
    }

    private var controls: some View {
        VStack(spacing: 10) {
            switch section {
            case .style:
                HStack(spacing: 5) {
                    ForEach(HomeToolbarLayout.Style.allCases, id: \.self) { style in
                        choice(ToolText.text("home_toolbar_" + style.rawValue), selected: layout.style == style,
                            identifier: "home-toolbar.style." + style.rawValue) {
                            layout.style = style
                        } icon: { styleSample(style) }
                    }
                }
            case .position:
                HStack(spacing: 5) {
                    ForEach(HomeToolbarLayout.Placement.allCases, id: \.self) { placement in
                        choice(ToolText.text("home_toolbar_" + placement.rawValue),
                            selected: layout.placement == placement, identifier: "home-toolbar.position." + placement.rawValue) {
                            layout.placement = placement
                        } icon: {
                            Image(systemName: placement == .bottom ? "rectangle.bottomthird.inset.filled"
                                : placement == .belowSearch ? "rectangle.center.inset.filled" : "arrow.up.and.down.and.arrow.left.and.right")
                        }
                    }
                }
                if layout.placement == .bottom {
                    HStack(spacing: 10) {
                        alignmentButton(.leading, icon: "align.horizontal.left", key: "home_toolbar_leading")
                        alignmentButton(.center, icon: "align.horizontal.center", key: "home_toolbar_center")
                        alignmentButton(.trailing, icon: "align.horizontal.right", key: "home_toolbar_trailing")
                    }
                } else if layout.placement == .free {
                    Text(ToolText.text("home_toolbar_drag_position")).font(.footnote).foregroundStyle(.secondary)
                }
            case .buttons:
                Text(ToolText.text("home_toolbar_drag_buttons"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 40)
            }

            HStack(spacing: 6) {
                ForEach(Section.allCases, id: \.self) { item in
                    Button {
                        section = item
                        HapticsManager.selection()
                    } label: {
                        Label(item.label, systemImage: item.icon)
                            .font(.subheadline.weight(.semibold))
                            .labelStyle(.titleAndIcon)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(section == item ? Color.themePrimary : Color.secondary)
                            .background(section == item ? Color.themePrimary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("home-toolbar.editor." + item.rawValue)
                    .accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private func alignmentButton(_ alignment: HomeToolbarLayout.EdgeAlignment, icon: String, key: String) -> some View {
        Button { layout.alignment = alignment; HapticsManager.selection() } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .foregroundStyle(layout.alignment == alignment ? Color.themePrimary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ToolText.text(key))
        .accessibilityAddTraits(layout.alignment == alignment ? .isSelected : [])
    }

    private func choice<Icon: View>(_ title: String, selected: Bool, identifier: String,
                                    action: @escaping () -> Void, @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            action()
            HapticsManager.selection()
        } label: {
            VStack(spacing: 5) {
                icon().frame(height: 24)
                Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(selected ? Color.themePrimary : Color.secondary)
            .background(selected ? Color.themePrimary.opacity(0.10) : Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func styleSample(_ style: HomeToolbarLayout.Style) -> some View {
        HStack(spacing: 3) {
            ForEach(["gearshape", "folder", "square.on.square"], id: \.self) { icon in
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 15, height: 17)
                    .background(style == .tiles ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(3)
        .background(style == .capsule ? Color.primary.opacity(0.09) : .clear, in: Capsule())
        .accessibilityHidden(true)
    }

    private func actionPicker(for slot: Int) -> some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: ToolbarActionPickerLayout.columns, spacing: 10) {
                    ForEach(HomeToolbarAction.allCases.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { action in
                        Button {
                            if draft[slot] == .none, action != .none {
                                let ordered = draft.filter { $0 != .none } + [action]
                                draft = ordered + Array(repeating: .none, count: draft.count - ordered.count)
                            } else {
                                draft[slot] = action
                            }
                            choiceSlot = nil
                            HapticsManager.selection()
                        } label: {
                            ToolbarActionChoiceLabel(symbol: action.listSymbol, title: action.title, isSelected: draft[slot] == action,
                                tabCount: action == .tabs ? tabManager.tabCount : nil)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-toolbar.action." + action.rawValue)
                        .accessibilityAddTraits(draft[slot] == action ? .isSelected : [])
                    }
                }
                .padding(16)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .searchable(text: $search, prompt: LanguageManager.shared.localizedString("search"))
            .navigationTitle(LanguageManager.shared.localizedString("toolbar_replace_action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { choiceSlot = nil }
                }
            }
        }
    }
}

extension HomeToolbarLayout.EdgeAlignment {
    var frameAlignment: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    func physicalFraction(rightToLeft: Bool) -> Double {
        switch self {
        case .leading: rightToLeft ? 1 : 0
        case .center: 0.5
        case .trailing: rightToLeft ? 0 : 1
        }
    }
}

struct HomeToolbarMetrics {
    static let rowHeight: CGFloat = 48
    static let rowSpacing: CGFloat = 8
    let area: CGSize
    let count: Int
    let columns: Int
    let spacing: CGFloat
    let buttonWidth: CGFloat
    let inset: CGFloat

    init(width: CGFloat, height: CGFloat = 0, count: Int, style: HomeToolbarLayout.Style) {
        area = CGSize(width: width, height: height)
        self.count = count
        inset = style == .capsule ? 6 : 0
        let available = max(0, width - 2 * inset)
        let minSpacing: CGFloat = style == .capsule ? 0 : 4
        let maxSpacing: CGFloat = style == .capsule ? 4 : 18
        columns = max(1, min(count, Int((available + minSpacing) / (44 + minSpacing))))
        buttonWidth = min(50, max(44, (available - CGFloat(columns - 1) * minSpacing) / CGFloat(columns)))
        spacing = columns > 1 ? min(maxSpacing, max(minSpacing, (available - CGFloat(columns) * buttonWidth) / CGFloat(columns - 1))) : 0
    }

    var rows: Int { (count + columns - 1) / columns }
    var size: CGSize {
        CGSize(width: CGFloat(columns) * buttonWidth + CGFloat(columns - 1) * spacing + 2 * inset,
               height: CGFloat(rows) * Self.rowHeight + CGFloat(max(0, rows - 1)) * Self.rowSpacing + 2 * inset)
    }

    func target(from source: Int, translation: CGSize, count: Int, rightToLeft: Bool) -> Int {
        guard count > 0 else { return 0 }
        let horizontal = translation.width * (rightToLeft ? -1 : 1)
        let column = min(columns - 1, max(0, source % columns + Int((horizontal / (buttonWidth + spacing)).rounded())))
        let row = min(rows - 1, max(0, source / columns + Int((translation.height / (Self.rowHeight + Self.rowSpacing)).rounded())))
        return min(count - 1, row * columns + column)
    }
}

struct HomeToolbarStrip<Cell: View>: View {
    let indices: [Int]
    let metrics: HomeToolbarMetrics
    let style: HomeToolbarLayout.Style
    let lightWallpaper: Bool
    @ViewBuilder let cell: (Int) -> Cell

    var body: some View {
        VStack(spacing: HomeToolbarMetrics.rowSpacing) {
            ForEach(0..<metrics.rows, id: \.self) { row in
                let start = row * metrics.columns
                let end = min(indices.count, start + metrics.columns)
                HStack(spacing: metrics.spacing) {
                    ForEach(indices[start..<end], id: \.self) { index in
                        cell(index)
                            .frame(width: metrics.buttonWidth, height: HomeToolbarMetrics.rowHeight)
                    }
                }
            }
        }
        .padding(metrics.inset)
        .modifier(HomeToolbarButtonSurface(visible: style == .capsule, lightWallpaper: lightWallpaper, radius: 26, shared: true))
        .frame(width: metrics.size.width, height: metrics.size.height)
    }
}

struct HomeToolbarButtonFace: View {
    let action: HomeToolbarAction
    let lightWallpaper: Bool
    var isActive = false
    var isLoading = false
    var tabCount = 2
    var body: some View {
        VStack(spacing: 6) {
            Group {
                if isLoading {
                    ProgressView()
                } else if action == .tabs {
                    TabCountSymbol(count: tabCount)
                } else {
                    Image(systemName: action == .none ? "plus" : action == .privateBrowsing && isActive ? "eye.slash.fill" : action.symbol)
                }
            }
            .font(.system(size: 20, weight: .medium)).frame(height: 25)
        }
        .foregroundStyle(lightWallpaper ? Color(hex: "242635").opacity(0.85) : .white.opacity(0.85))
        .frame(minWidth: 44, maxWidth: .infinity)
        .frame(height: 48)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
struct HomeToolbarButtonStyle: ButtonStyle {
    var lightWallpaper = false
    var showsBackground = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HomeToolbarButtonSurface(visible: showsBackground || configuration.isPressed,
                lightWallpaper: lightWallpaper))
            .modifier(HomePressFeedback(isPressed: configuration.isPressed))
    }
}

private struct HomeToolbarButtonSurface: ViewModifier {
    let visible: Bool
    var lightWallpaper = false
    var radius: CGFloat = 16
    var shared = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if visible {
                    if reduceTransparency {
                        shape.fill(lightWallpaper ? Color(hex: "F0F1F5") : Color(hex: "252734"))
                    } else if lightWallpaper {
                        shape.fill(Color.black.opacity(shared ? 0.16 : 0.04))
                    } else {
                        shape.fill(.ultraThinMaterial.opacity(shared ? 0.72 : 0.3))
                    }
                }
            }

    }
}
