import SwiftUI

/// Keep existing shortcuts and search routes opening the Home section.
struct HomeToolbarSettingsView: View {
    var startsAtVisibility = false
    var body: some View { BrowserToolbarSettingsView(initialSection: .home, startsAtHomeVisibility: startsAtVisibility) }
}

struct HomeDisplayDraft {
    var title: String?
    var subtitle: String?
    var liveActivityEnabled: Bool?
}

struct HomeToolbarEditor: View {
    @Binding var draft: [HomeToolbarAction]
    @Binding var layout: HomeToolbarLayout
    @Binding var sharedVisibility: [HomePageElement: Bool]
    @Binding var displayDraft: HomeDisplayDraft
    @EnvironmentObject private var tabManager: TabManager
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.layoutDirection) private var direction
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var visibilityIconHeight: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var visibilityLabelHeight: CGFloat = 31
    @ObservedObject private var wallpaper = WallpaperManager.shared
    @AppStorage("home_title") private var storedTitle = "Soulo"
    @AppStorage("home_subtitle") private var storedSubtitle = AppConstants.defaultHomeSubtitle
    @AppStorage(LiveActivityService.enabledKey) private var storedLiveActivityEnabled = true
    @AppStorage(HomePageElement.bookmarksKey) private var showsBookmarks = HomePageElement.bookmarks.defaultVisibility
    @AppStorage(HomePageElement.recentSearchesKey) private var showsRecentSearches = HomePageElement.recentSearches.defaultVisibility
    @State private var section: Section
    @State private var headingEditor: HeadingField?
    @State private var editingHeadingText = ""
    @State private var choiceSlot: Int?
    @State private var search = ""
    @State private var previewExamplesHeight: CGFloat = 0
    @State private var wallpaperFrame: CGRect = .zero
    @GestureState private var placementDrag: CGSize = .zero
    @GestureState private var reorderDrag: ReorderDrag?

    init(draft: Binding<[HomeToolbarAction]>, layout: Binding<HomeToolbarLayout>,
         sharedVisibility: Binding<[HomePageElement: Bool]>, displayDraft: Binding<HomeDisplayDraft>,
         startsAtVisibility: Bool) {
        _draft = draft
        _layout = layout
        _sharedVisibility = sharedVisibility
        _displayDraft = displayDraft
        _section = State(initialValue: startsAtVisibility ? .visibility : .buttons)
    }

    private enum HeadingField: String, Identifiable {
        case title, subtitle
        var id: String { rawValue }

        @MainActor var label: String {
            LanguageManager.shared.localizedString(self == .title ? "edit_title" : "edit_subtitle")
        }
        var defaultText: String { self == .title ? "Soulo" : AppConstants.defaultHomeSubtitle }
    }

    private enum Section: String, CaseIterable {
        case buttons, visibility, position

        @MainActor var label: String {
            ToolText.text("home_toolbar_" + rawValue)
        }
        var icon: String {
            switch self {
            case .position: "arrow.up.left.and.down.right"
            case .buttons: "square.grid.2x2"
            case .visibility: "eye"
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
    private var title: String { displayDraft.title ?? storedTitle }
    private var subtitle: String { displayDraft.subtitle ?? storedSubtitle }
    private var liveActivityEnabled: Bool { displayDraft.liveActivityEnabled ?? storedLiveActivityEnabled }

    var body: some View {
        GeometryReader { geometry in
            let panelHeight = min(176, max(0, geometry.size.height - 60) * 0.4)
            VStack(spacing: 8) {
                preview
                    .frame(maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("home-toolbar.preview")
                sectionPicker
                ScrollView {
                    sectionControls
                }
                .frame(height: panelHeight)
                .id(section)
                .accessibilityIdentifier("home-toolbar.content")
            }
            .frame(maxWidth: 420)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: Binding(get: { choiceSlot != nil }, set: { if !$0 { choiceSlot = nil } })) {
            if let slot = choiceSlot {
                actionPicker(for: slot)
            }
        }
        .sheet(item: $headingEditor) { field in
            headingEditorSheet(field)
        }
    }

    private func headingEditorSheet(_ field: HeadingField) -> some View {
        NavigationStack {
            Form {
                TextField(field.defaultText, text: $editingHeadingText)
                    .accessibilityIdentifier("home-toolbar.heading.input")
                    .onSubmit { finishHeadingEdit(editingHeadingText, for: field) }
                Button(LText("platform_reset_defaults")) { finishHeadingEdit(field.defaultText, for: field) }
                    .accessibilityIdentifier("home-toolbar.heading.reset")
            }
            .navigationTitle(field.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LText("cancel")) { headingEditor = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LText("done")) { finishHeadingEdit(editingHeadingText, for: field) }
                        .accessibilityIdentifier("home-toolbar.heading.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func finishHeadingEdit(_ text: String, for field: HeadingField) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch field {
        case .title: displayDraft.title = value
        case .subtitle: displayDraft.subtitle = value
        }
        headingEditor = nil
    }

    private func shows(_ element: HomePageElement) -> Bool {
        if let edited = sharedVisibility[element] { return edited }
        switch element {
        case .bookmarks: return showsBookmarks
        case .recentSearches: return showsRecentSearches
        default: return layout.shows(element, in: draft)
        }
    }

    private var preview: some View {
        GeometryReader { geometry in
            let availableWidth = max(0, geometry.size.width - 2 * HomeLandingSpacing.toolbarSideInset)
            let visible = draft.indices.filter { draft[$0] != .none }
            let addSlot = section != .visibility && (section == .buttons || visible.isEmpty) ? draft.firstIndex(of: .none) : nil
            let slots = visible + (addSlot.map { [$0] } ?? [])
            let metrics = HomeToolbarMetrics(width: availableWidth, count: slots.count, style: layout.style)
            let topInset: CGFloat = shows(.tabs) || shows(.menu) ? 42 : 14
            let bottomInset = HomeLandingSpacing.toolbarSafeInset
                + (layout.placement == .bottom && !slots.isEmpty ? HomeLandingSpacing.bottomToolbarLift : 0)
            let availableHeight = max(0, geometry.size.height - topInset - bottomInset)
            let examples = section == .visibility ? [HomePageElement.bookmarks, .recentSearches].filter(shows) : []
            let examplesHeight = examples.isEmpty ? 0 : previewExamplesHeight
            let searchAtBottom = shows(.search) && layout.searchPlacement == .bottom
            let hasSubtitle = shows(.subtitle) && !subtitle.isEmpty
            let hasTitle = shows(.title) && !title.isEmpty
            let headingGap = HomeLandingSpacing.headingGap(for: verticalSizeClass, showsSubtitle: hasSubtitle)
            let detailsGap = HomeLandingSpacing.detailsGap(for: verticalSizeClass)
            let headingHeight: CGFloat = (hasTitle ? 46 : 0) + (hasSubtitle ? 16 : 0) + (hasTitle && hasSubtitle ? 6 : 0)
            let toolbarInset = HomeLandingSpacing.bottomToolbarTopInset
                + (searchAtBottom ? HomeLandingSpacing.searchAboveToolbarInset : 0)
            let fixedToolbarHeight = layout.placement == .bottom && !slots.isEmpty ? metrics.size.height + toolbarInset : 0
            let freeToolbarRoom = layout.placement == .free && !slots.isEmpty
                ? metrics.size.height + HomeToolbarLayout.searchClearance : 0
            let detailsBottomInset = freeToolbarRoom > 0 ? freeToolbarRoom + 2 : 0
            let minimumHeight = headingHeight + headingGap + (shows(.search) ? 46 : 0)
                + (examples.isEmpty ? 0 : detailsGap + examplesHeight) + max(fixedToolbarHeight, detailsBottomInset) + 6
            let scale = min(1, max(1, availableHeight) / max(1, minimumHeight))
            let width = availableWidth / scale
            let height = availableHeight / scale
            let usable = CGSize(width: width, height: height)
            let drag = CGSize(width: placementDrag.width / scale, height: placementDrag.height / scale)
            let freeDock = freeToolbarRoom > 0 && (drag == .zero ? layout.freeToolbarAtBottom
                : layout.reachesBottom(in: usable, strip: metrics.size, translation: drag))
            let bottomToolbarHeight = freeDock && searchAtBottom ? freeToolbarRoom : fixedToolbarHeight
            let landingHeight = max(0, height - bottomToolbarHeight)
            let searchWidth = max(1, min(width * 0.88, 380))
            ZStack(alignment: .topLeading) {
                WallpaperBackground(isAnimating: false, appearanceOverride: wallpaperAppearance,
                    onFrameChange: { wallpaperFrame = $0 })
                VStack(spacing: 0) {
                    if shows(.tabs) || shows(.menu) { previewShortcutBar }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HomeLandingSpacing.toolbarSideInset)
                .padding(.vertical, 8)
                .allowsHitTesting(false)
                SearchLandingLayout(viewportHeight: landingHeight,
                    headingGap: headingGap, detailsGap: detailsGap, searchOffsetRatio: -0.5,
                    searchAtBottom: searchAtBottom, centeredDetailsBottomInset: detailsBottomInset) {
                    previewHeading
                        .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
                        .frame(width: searchWidth)
                    previewSearchField.frame(width: searchWidth)
                    HomePreviewExamples(elements: examples, lightWallpaper: usesDarkInk, contrast: wallpaper.contrast(in: wallpaperFrame))
                        .frame(width: searchWidth)
                        .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { previewExamplesHeight = $0 }
                }
                .frame(width: width, height: landingHeight, alignment: .top)
                .frame(width: width, height: height, alignment: .top)
                .overlayPreferenceValue(HomeToolbarContentBounds.self) { bounds in
                    GeometryReader { canvas in
                        let obstacles = bounds.map { canvas[$0] }
                        if !slots.isEmpty, let center = previewCenter(in: usable, strip: metrics.size,
                            avoiding: obstacles, drag: drag, dockAtBottom: freeDock) {
                            if section == .position, layout.placement == .free, placementDrag != .zero {
                                previewGuides(in: usable, center: center).allowsHitTesting(false)
                            }
                            previewStrip(slots, metrics: metrics, in: usable, avoiding: obstacles, scale: scale)
                                .position(center)
                        }
                    }
                }
                .scaleEffect(scale, anchor: .top)
                .frame(width: geometry.size.width, height: availableHeight, alignment: .top)
                .offset(y: topInset)
            }
        }
        .background(Color(hex: "19202F"))
        .clipShape(RoundedRectangle(cornerRadius: 30))
        .overlay { RoundedRectangle(cornerRadius: 30).strokeBorder(.primary.opacity(0.12), lineWidth: 1).allowsHitTesting(false) }
    }

    private var previewShortcutBar: some View {
        HStack {
            if shows(.tabs) {
                Image(systemName: HomePageElement.tabs.symbol)
                    .accessibilityLabel(HomePageElement.tabs.label)
                    .accessibilityIdentifier("home-toolbar.preview.tabs")
            }
            Spacer()
            if shows(.menu) {
                Image(systemName: HomePageElement.menu.symbol)
                    .accessibilityLabel(HomePageElement.menu.label)
                    .accessibilityIdentifier("home-toolbar.preview.menu")
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(previewInk.opacity(0.78))
        .frame(height: 24)
    }

    private var previewHeading: some View {
        VStack(spacing: 6) {
            if shows(.title) && !title.isEmpty {
                Text(title).font(.system(size: 38, weight: .bold, design: .rounded)).lineLimit(1)
            }
            if shows(.subtitle) && !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 13, weight: .medium)).tracking(1.5).lineLimit(1)
            }
        }
        .foregroundStyle(previewInk)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-toolbar.preview.heading")
    }

    private var previewSearchField: some View {
        VStack(spacing: 0) {
            if shows(.search) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 26)
                    Text(LanguageManager.shared.localizedString("search_placeholder"))
                        .font(.system(size: 15))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Rectangle().fill(previewInk.opacity(0.15)).frame(width: 1, height: 16)
                    Image(systemName: "mic")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 26)
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(previewInk.opacity(0.14), in: Capsule())
                .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(HomePageElement.search.label)
                .accessibilityIdentifier("home-toolbar.preview.search")
            }
        }
        .foregroundStyle(previewInk)
    }

    private func previewCenter(in area: CGSize, strip: CGSize, avoiding obstacles: [CGRect],
                               drag: CGSize, dockAtBottom: Bool) -> CGPoint? {
        switch layout.placement {
        case .free: return layout.freeCenter(in: area, strip: strip, avoiding: obstacles, translation: drag,
            dockAtBottom: dockAtBottom)
        case .bottom:
            var bottom = layout
            bottom.x = layout.alignment.physicalFraction(rightToLeft: direction == .rightToLeft)
            bottom.y = 1
            return bottom.center(in: area, strip: strip)
        }
    }

    private func previewGuides(in area: CGSize, center: CGPoint) -> some View {
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
    private func previewStrip(_ slots: [Int], metrics: HomeToolbarMetrics, in area: CGSize,
                              avoiding obstacles: [CGRect], scale: CGFloat) -> some View {
        if section == .position, layout.placement == .free {
            strip(slots, metrics: metrics, editable: false)
                .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.75), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
                .contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($placementDrag) { value, drag, _ in drag = value.translation }
                    .onEnded { value in
                        let drag = CGSize(width: value.translation.width / scale, height: value.translation.height / scale)
                        moveFreeToolbar(by: drag, in: area, strip: metrics.size, avoiding: obstacles)
                    })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ToolText.text("home_toolbar_free"))
                .accessibilityIdentifier("home-toolbar.drag")
                .accessibilityActions {
                    nudge("left", dx: -24, dy: 0, in: area, strip: metrics.size, avoiding: obstacles)
                    nudge("right", dx: 24, dy: 0, in: area, strip: metrics.size, avoiding: obstacles)
                    nudge("up", dx: 0, dy: -24, in: area, strip: metrics.size, avoiding: obstacles)
                    nudge("down", dx: 0, dy: 24, in: area, strip: metrics.size, avoiding: obstacles)
                }
        } else {
            strip(slots, metrics: metrics, editable: true)
        }
    }

    private func nudge(_ direction: String, dx: CGFloat, dy: CGFloat, in area: CGSize,
                       strip: CGSize, avoiding obstacles: [CGRect]) -> some View {
        Button(LanguageManager.shared.localizedString("accessibility_move_" + direction)) {
            moveFreeToolbar(by: CGSize(width: dx, height: dy), in: area, strip: strip, avoiding: obstacles)
        }
    }

    private func moveFreeToolbar(by translation: CGSize, in area: CGSize, strip: CGSize, avoiding obstacles: [CGRect]) {
        let docks = layout.reachesBottom(in: area, strip: strip, translation: translation)
        layout.move(by: translation, in: area, strip: strip, avoiding: obstacles, dockAtBottom: docks)
    }

    private func strip(_ slots: [Int], metrics: HomeToolbarMetrics, editable: Bool) -> some View {
        WallpaperForegroundRegion(contrast: wallpaper.contrast(in: wallpaperFrame),
            fallbackDarkInk: wallpaper.source == .solid && usesDarkInk) { darkInk in
            let appearance = HomeToolbarAppearance(lightWallpaper: darkInk, source: wallpaper.source)
            toolbarStrip(slots, metrics: metrics, editable: editable, appearance: appearance)
        }
    }

    private func toolbarStrip(_ slots: [Int], metrics: HomeToolbarMetrics, editable: Bool,
                              appearance: HomeToolbarAppearance) -> some View {
        HomeToolbarStrip(indices: slots, metrics: metrics, style: layout.style, appearance: appearance) { slot in
            let action = draft[slot]
            Button {
                section = .buttons
                search = ""
                choiceSlot = slot
                HapticsManager.selection()
            } label: {
                if action == .none {
                    let border = RoundedRectangle(cornerRadius: 12)
                    Image(systemName: "plus.circle")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(appearance.ink)
                        .frame(maxWidth: .infinity, minHeight: HomeToolbarMetrics.rowHeight)
                        .background(appearance.outline.opacity(0.16), in: border)
                        .overlay { border.strokeBorder(appearance.ink.opacity(0.8), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])) }
                        .contentShape(border)
                } else {
                    HomeToolbarButtonFace(action: action, appearance: appearance, tabCount: tabManager.tabCount)
                }
            }
            .buttonStyle(HomeToolbarButtonStyle(appearance: appearance, showsBackground: layout.style == .tiles && action != .none))
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

    @ViewBuilder private var sectionControls: some View {
        switch section {
        case .position:
            positionControls
        case .buttons:
            VStack(spacing: 8) {
                optionGroup(ToolText.text("home_toolbar_style"), symbol: "paintbrush", selection: $layout.style,
                    options: HomeToolbarLayout.Style.allCases, identifier: "home-toolbar.style") {
                    ToolText.text("home_toolbar_" + $0.rawValue)
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
                Text(ToolText.text("home_toolbar_drag_buttons"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        case .visibility:
            visibilityControls
        }
    }

    private var positionControls: some View {
        VStack(spacing: 6) {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 0) {
                optionGroup(HomePageElement.search.label, symbol: HomePageElement.search.symbol, selection: $layout.searchPlacement,
                    options: HomeToolbarLayout.SearchPlacement.allCases, identifier: "home-toolbar.search-position", compact: true) {
                    ToolText.text($0 == .center ? "home_toolbar_center" : "home_toolbar_search_bottom")
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                optionGroup(ToolText.text("home_toolbar_home_tools"), symbol: "rectangle.bottomthird.inset.filled", selection: $layout.placement,
                    options: HomeToolbarLayout.Placement.allCases, identifier: "home-toolbar.position", compact: true) {
                    ToolText.text("home_toolbar_" + $0.rawValue)
                }
                if layout.placement == .bottom && draft.contains(where: { $0 != .none }) {
                    Divider().gridCellUnsizedAxes(.horizontal)
                    optionGroup(ToolText.text("home_toolbar_alignment"), symbol: "align.horizontal.center", selection: $layout.alignment,
                        options: HomeToolbarLayout.EdgeAlignment.allCases, identifier: "home-toolbar.alignment", compact: true) {
                        ToolText.text("home_toolbar_" + $0.rawValue)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            if layout.placement == .free && draft.contains(where: { $0 != .none }) {
                Text(ToolText.text("home_toolbar_drag_position"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func optionGroup<Option: RawRepresentable & Hashable>(_ label: String, symbol: String,
            selection: Binding<Option>, options: [Option], identifier: String,
            compact: Bool = false,
            title: @escaping (Option) -> String) -> some View where Option.RawValue == String {
        let inline = compact && !dynamicTypeSize.isAccessibilitySize
        let optionLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 6))
        let heading = Label {
            Text(label).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(Color.themePrimary)
                .accessibilityHidden(true)
        }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(identifier)
        let choices = optionLayout {
            ForEach(options, id: \.self) { option in
                let selected = selection.wrappedValue == option
                Button {
                    selection.wrappedValue = option
                    HapticsManager.selection()
                } label: {
                    Text(title(option))
                        .font(.footnote.weight(selected ? .semibold : .medium))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(selected ? Color.themePrimary : Color.primary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, minHeight: inline ? 36 : 44, maxHeight: .infinity)
                        .background(selected ? Color.themePrimary.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                            in: RoundedRectangle(cornerRadius: 9))
                        .padding(.vertical, inline ? 4 : 0)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(identifier + "." + option.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        if inline {
            GridRow {
                heading
                choices
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                heading
                choices
            }
            .padding(.horizontal, compact ? 0 : 10)
            .padding(.vertical, 7)
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 3) {
            ForEach(Section.allCases, id: \.self) { item in
                Button {
                    section = item
                    HapticsManager.selection()
                } label: {
                    ViewThatFits(in: .horizontal) {
                        Text(item.label).fixedSize(horizontal: true, vertical: false)
                        Image(systemName: item.icon)
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 1)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(section == item ? Color.themePrimary : Color.secondary)
                    .background {
                        if section == item {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.themePrimary.opacity(0.12))
                                .padding(.vertical, 4)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.label)
                .accessibilityIdentifier("home-toolbar.editor." + item.rawValue)
                .accessibilityAddTraits(section == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var visibilityControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            visibilityGroup("home_toolbar_visibility_page", elements: [.tabs, .menu, .title, .subtitle],
                            hint: shows(.menu) ? nil : "home_toolbar_visibility_recovery")
            Divider().padding(.horizontal, 2)
            visibilityGroup("home_toolbar_visibility_search_area", elements: [.search, .bookmarks, .recentSearches],
                            hint: shows(.search) ? nil : "home_toolbar_visibility_search_hint", includesLiveActivity: true)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var liveActivityControl: some View {
        Button {
            displayDraft.liveActivityEnabled = !liveActivityEnabled
            HapticsManager.selection()
        } label: {
            visibilityTileLabel(LText("live_activity"), shown: liveActivityEnabled) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 9, weight: .semibold))
                    Circle().fill(.white.opacity(0.7)).frame(width: 4, height: 4)
                }
                .foregroundStyle(.white)
                .frame(width: 36, height: 16)
                .background(liveActivityEnabled ? Color.black : Color(uiColor: .systemGray), in: Capsule())
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(liveActivityEnabled ? .isSelected : [])
        .accessibilityIdentifier("home-toolbar.visibility.liveActivity")
        .accessibilityHint(LText("live_activity_desc"))
    }

    private func visibilityGroup(_ heading: String, elements: [HomePageElement], hint: String?,
                                 includesLiveActivity: Bool = false) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6),
                            count: dynamicTypeSize.isAccessibilitySize ? 2 : 4)
        return VStack(alignment: .leading, spacing: 4) {
            Text(ToolText.text(heading))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 3)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(heading)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(elements) { element in
                    visibilityTile(element)
                }
                if includesLiveActivity { liveActivityControl }
            }

            if let hint {
                Text(ToolText.text(hint))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(colorScheme == .dark ? Color.themePrimary : Color(hex: "075AB5"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 3)
            }
        }
    }

    private func visibilityTile(_ element: HomePageElement) -> some View {
        let shown = shows(element)
        return Button {
            if element.sharedPreferenceKey != nil { sharedVisibility[element] = !shown }
            else { layout.setVisibility(!shown, for: element) }
            HapticsManager.selection()
        } label: {
            visibilityTileLabel(element.label, shown: shown) {
                Image(systemName: element.symbol).font(.subheadline.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(element.label)
        .accessibilityAddTraits(shown ? .isSelected : [])
        .accessibilityIdentifier("home-toolbar.visibility." + element.rawValue)
        .overlay(alignment: .topLeading) {
            if let field = HeadingField(rawValue: element.rawValue) {
                Button {
                    editingHeadingText = field == .title ? title : subtitle
                    headingEditor = field
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.themePrimary)
                        .frame(width: 18, height: 18)
                        .background(Color.themePrimary.opacity(0.1), in: Circle())
                        .frame(width: 28, height: 28, alignment: .topLeading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(4)
                .accessibilityLabel(field.label)
                .accessibilityIdentifier("home-toolbar.heading.edit." + field.rawValue)
            }
        }
    }

    private func visibilityTileLabel<Symbol: View>(_ label: String, shown: Bool,
                                                    @ViewBuilder symbol: () -> Symbol) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return VStack(spacing: 2) {
            symbol()
                .frame(height: visibilityIconHeight)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(shown ? Color.themePrimary : Color.secondary)
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .frame(height: visibilityIconHeight + visibilityLabelHeight + 10)
        .background(shown ? Color.themePrimary.opacity(0.12) : Color(uiColor: .tertiarySystemFill), in: shape)
        .overlay(alignment: .topTrailing) {
            if shown {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.themePrimary)
                    .padding(5)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(shape)
    }

    private func actionPicker(for slot: Int) -> some View {
        NavigationStack {
            VStack(spacing: 0) {
                ToolbarActionSearchField(query: $search, identifier: "home-toolbar.action-search")
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
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
                .accessibilityIdentifier("home-toolbar.action-list")
            }
            .background(Color(uiColor: .systemGroupedBackground))
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

private extension HomePageElement {
    @MainActor var label: String {
        let language = LanguageManager.shared
        switch self {
        case .tabs: return language.localizedString("browser_tabs")
        case .menu: return language.localizedString("show_more")
        case .title, .subtitle, .search: return ToolText.text("home_toolbar_visibility_" + rawValue)
        case .bookmarks: return language.localizedString("bookmarks")
        case .recentSearches: return language.localizedString("recent_searches")
        }
    }

    var symbol: String {
        switch self {
        case .tabs: "square.on.square"
        case .menu: "ellipsis"
        case .title: "textformat.size.larger"
        case .subtitle: "text.alignleft"
        case .search: "magnifyingglass"
        case .bookmarks: "bookmark"
        case .recentSearches: "clock.arrow.circlepath"
        }
    }
}

/// Bundled samples keep this preview useful before the user has saved anything.
private struct HomePreviewExamples: View {
    let elements: [HomePageElement]
    let lightWallpaper: Bool
    let contrast: WallpaperRegionContrast?
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private static let bookmarks = [
        (icon: "icon_bilibili", nameKey: "platform_bilibili"),
        (icon: "icon_wikipedia", nameKey: "platform_wikipedia"),
        (icon: "icon_github", nameKey: "platform_github")
    ]

    var body: some View {
        VStack(spacing: HomeLandingSpacing.detailsGap(for: verticalSizeClass)) {
            ForEach(elements) { element in
                example(for: element)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("home-toolbar.preview." + element.rawValue)
                    .padding(.top, element == .recentSearches ? HomeLandingSpacing.recentSearchInset : 0)
            }
        }
    }

    @ViewBuilder
    private func example(for element: HomePageElement) -> some View {
        switch element {
        case .bookmarks:
            HStack(spacing: HomeLandingSpacing.bookmarkSpacing) {
                ForEach(Self.bookmarks, id: \.icon) { bookmark in
                    HomeBookmarkTile(title: LanguageManager.shared.localizedString(bookmark.nameKey), lightWallpaper: lightWallpaper) {
                        Image(bookmark.icon)
                            .resizable().scaledToFit()
                            .frame(width: HomeLandingSpacing.bookmarkIconSize, height: HomeLandingSpacing.bookmarkIconSize)
                            .background(.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityHidden(true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .recentSearches:
            let keywords = ["SwiftUI", LanguageManager.shared.localizedString("settings_wallpaper")]
            SearchSuggestionsView(recentSearches: keywords, horizontalInset: 0, contrast: contrast)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(keywords.joined(separator: ", "))
        default:
            EmptyView()
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
    let count: Int
    let columns: Int
    let spacing: CGFloat
    let buttonWidth: CGFloat
    let horizontalInset: CGFloat
    let verticalInset: CGFloat

    init(width: CGFloat, count: Int, style: HomeToolbarLayout.Style) {
        self.count = count
        horizontalInset = style == .capsule ? 6 : 0
        verticalInset = style == .capsule ? 3 : 0
        let available = max(0, width - 2 * horizontalInset)
        let minSpacing: CGFloat = style == .capsule ? 0 : 4
        let maxSpacing: CGFloat = style == .capsule ? 4 : 18
        columns = max(1, min(count, Int((available + minSpacing) / (44 + minSpacing))))
        buttonWidth = min(50, max(44, (available - CGFloat(columns - 1) * minSpacing) / CGFloat(columns)))
        spacing = columns > 1 ? min(maxSpacing, max(minSpacing, (available - CGFloat(columns) * buttonWidth) / CGFloat(columns - 1))) : 0
    }

    var rows: Int { (count + columns - 1) / columns }
    var size: CGSize {
        CGSize(width: CGFloat(columns) * buttonWidth + CGFloat(columns - 1) * spacing + 2 * horizontalInset,
               height: CGFloat(rows) * Self.rowHeight + CGFloat(max(0, rows - 1)) * Self.rowSpacing + 2 * verticalInset)
    }

    func target(from source: Int, translation: CGSize, count: Int, rightToLeft: Bool) -> Int {
        guard count > 0 else { return 0 }
        let horizontal = translation.width * (rightToLeft ? -1 : 1)
        let column = min(columns - 1, max(0, source % columns + Int((horizontal / (buttonWidth + spacing)).rounded())))
        let row = min(rows - 1, max(0, source / columns + Int((translation.height / (Self.rowHeight + Self.rowSpacing)).rounded())))
        return min(count - 1, row * columns + column)
    }
}

struct HomeToolbarAppearance {
    let lightWallpaper: Bool
    let source: WallpaperSource

    var usesWallpaperContrast: Bool { source != .solid }

    var ink: Color {
        (lightWallpaper ? Color(hex: "242635") : .white).opacity(usesWallpaperContrast ? 1 : 0.85)
    }

    var outline: Color { lightWallpaper ? .white : .black }
}

struct HomeToolbarStrip<Cell: View>: View {
    let indices: [Int]
    let metrics: HomeToolbarMetrics
    let style: HomeToolbarLayout.Style
    let appearance: HomeToolbarAppearance
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
        .padding(.horizontal, metrics.horizontalInset)
        .padding(.vertical, metrics.verticalInset)
        .modifier(HomeToolbarButtonSurface(visible: style == .capsule, appearance: appearance, radius: 26, shared: true))
        .frame(width: metrics.size.width, height: metrics.size.height)
    }
}

struct HomeToolbarButtonFace: View {
    let action: HomeToolbarAction
    let appearance: HomeToolbarAppearance
    var isActive = false
    var isLoading = false
    var tabCount = 2

    @ViewBuilder
    private var glyph: some View {
        if action == .tabs {
            TabCountSymbol(count: tabCount)
        } else {
            Image(systemName: action == .none ? "plus" : action == .privateBrowsing && isActive ? "eye.slash.fill" : action.symbol)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView().tint(appearance.ink)
            } else {
                glyph.foregroundStyle(appearance.ink)
                    .background {
                        if appearance.usesWallpaperContrast {
                            let edge = glyph.foregroundStyle(appearance.outline.opacity(0.9))
                            ZStack {
                                edge.offset(x: -1)
                                edge.offset(x: 1)
                                edge.offset(y: -1)
                                edge.offset(y: 1)
                            }
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                        }
                    }
            }
        }
        .font(.system(size: 20, weight: .medium))
        .frame(height: 25)
        .frame(minWidth: 44, maxWidth: .infinity)
        .frame(height: HomeToolbarMetrics.rowHeight)
        .contentShape(RoundedRectangle(cornerRadius: 20))
    }
}
struct HomeToolbarButtonStyle: ButtonStyle {
    let appearance: HomeToolbarAppearance
    var showsBackground = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(HomeToolbarButtonSurface(visible: showsBackground || configuration.isPressed,
                appearance: appearance))
            .modifier(HomePressFeedback(isPressed: configuration.isPressed))
    }
}

private struct HomeToolbarButtonSurface: ViewModifier {
    let visible: Bool
    let appearance: HomeToolbarAppearance
    var radius: CGFloat = 16
    var shared = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                if visible {
                    if reduceTransparency {
                        shape.fill(appearance.lightWallpaper ? Color(hex: "F0F1F5") : Color(hex: "252734"))
                    } else if appearance.usesWallpaperContrast {
                        shape.fill(appearance.outline.opacity(shared ? 0.42 : 0.32))
                            .overlay { shape.strokeBorder(appearance.ink.opacity(0.18), lineWidth: 1) }
                    } else if appearance.lightWallpaper {
                        shape.fill(Color.black.opacity(shared ? 0.16 : 0.04))
                    } else {
                        shape.fill(.ultraThinMaterial.opacity(shared ? 0.72 : 0.3))
                    }
                }
            }

    }
}
