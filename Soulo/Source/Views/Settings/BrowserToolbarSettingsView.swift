import SwiftUI

struct BrowserToolbarSettingsView: View {
    enum Section: Int, CaseIterable {
        case home, browsing, more
        @MainActor var title: String {
            switch self {
            case .home: ToolText.text("toolbar_section_home")
            case .browsing: LanguageManager.shared.localizedString("browsing")
            case .more: LanguageManager.shared.localizedString("show_more")
            }
        }
    }
    private struct SaveFeedback {
        let id = UUID()
        let section: Section
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @ObservedObject private var homeService = HomeToolbarConfigurationService.shared
    @State private var draftHomeActions = Array(repeating: HomeToolbarAction.none, count: HomeToolbarConfigurationService.slotCount)
    @State private var draftHomeLayout = HomeToolbarLayout()
    @State private var draftSharedHomeVisibility: [HomePageElement: Bool] = [:]
    @State private var draftHomeDisplay = HomeDisplayDraft()
    @State private var selection: Section
    @State private var search = ""
    @State private var hasLoadedDrafts = false
    private let startsAtHomeVisibility: Bool
    private var editsMore: Bool { selection == .more }

    init(initialSection: Section = .browsing, startsAtHomeVisibility: Bool = false) {
        _selection = State(initialValue: initialSection)
        self.startsAtHomeVisibility = startsAtHomeVisibility
    }

    @ObservedObject private var service = BrowserToolbarConfigurationService.shared
    @State private var draftActions = BrowserToolbarConfigurationService.defaultActions
    @State private var draftLeadingAction = BrowserToolbarConfigurationService.defaultLeadingAction
    @State private var draftAddressAction = BrowserToolbarConfigurationService.defaultAddressAction
    @State private var draftMoreActions = BrowserToolbarConfigurationService.defaultMoreActions
    @State private var selectedToolbarSlot = 0
    @State private var selectedMoreSlot = 0
    @State private var saveFeedback: SaveFeedback?
    @State private var showRestoreConfirmation = false
    private var showsSaveFeedback: Bool { saveFeedback?.section == selection }
    private var saveMessage: String { LanguageManager.shared.localizedString("toolbar_saved") }

    var body: some View {
        VStack(spacing: 0) {
            Picker(ToolText.text("toolbar_settings"), selection: $selection) {
                ForEach(Section.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .accessibilityIdentifier("browser-toolbar.section")

            // Only editing controls live inside the pager. Navigation destinations
            // remain with the owning settings stack, above this lazy boundary.
            TabView(selection: $selection) {
                HomeToolbarEditor(draft: $draftHomeActions, layout: $draftHomeLayout,
                                  sharedVisibility: $draftSharedHomeVisibility, displayDraft: $draftHomeDisplay,
                                  startsAtVisibility: startsAtHomeVisibility)
                    .tag(Section.home)
                editorPage(isMore: false).tag(Section.browsing)
                editorPage(isMore: true).tag(Section.more)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .overlay(alignment: .bottom) {
                if showsSaveFeedback { saveFeedbackNotice }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsSaveFeedback)

            bottomActionBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        // Anchor the shared footer to the sheet edge across all three tabs.
        .ignoresSafeArea(.container, edges: .bottom)
        .navigationTitle(ToolText.text("toolbar_settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !hasLoadedDrafts else { return }
            hasLoadedDrafts = true
            draftHomeActions = homeService.actions
            draftHomeLayout = homeService.layout
            draftActions = service.actions
            draftAddressAction = service.addressAction
            draftLeadingAction = service.leadingAction
            draftMoreActions = service.moreActions
            selectedToolbarSlot = 0
            selectedMoreSlot = 0
        }
        .task(id: saveFeedback?.id) {
            guard let id = saveFeedback?.id else { return }
            do { try await Task.sleep(for: .seconds(voiceOverEnabled ? 6 : 3)) } catch { return }
            if saveFeedback?.id == id { saveFeedback = nil }
        }
        .alert(
            editsMore ? ToolText.text("toolbar_restore") : LanguageManager.shared.localizedString("toolbar_restore_confirm_title"),
            isPresented: $showRestoreConfirmation
        ) {
            Button(
                ToolText.text("toolbar_restore"),
                role: .destructive
            ) {
                restoreDefaults()
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        } message: {
            if !editsMore { Text(LanguageManager.shared.localizedString("toolbar_restore_confirm_message")) }
        }
    }

    private func editorPage(isMore: Bool) -> some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 350
            VStack(alignment: .leading, spacing: 12) {
                if geometry.size.height >= 180 {
                    editorPreview(isMore: isMore, compact: compact)
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                }
                ScrollView {
                    actionEditor(isMore: isMore)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                }
                .accessibilityIdentifier(isMore ? "browser-toolbar.more-actions" : "browser-toolbar.browsing-actions")
            }
        }
    }

    private func editorPreview(isMore: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                Text(isMore ? ToolText.text("toolbar_more_panel") : LanguageManager.shared.localizedString("toolbar_preview"))
                    .font(.headline)
            }
            if isMore {
                morePreview(compact: compact)
            } else {
                toolbarPreview
                slotPicker
            }
        }
    }

    private func actionEditor(isMore: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isMore {
                Text(LanguageManager.shared.localizedString("toolbar_customize_hint"))
                    .font(.footnote).foregroundStyle(.secondary)
                Menu {
                    Button(FeatureText.text("Standard")) { applyPreset([.home, .back, .tabs, .more], address: .darkMode) }
                    Button(FeatureText.text("Browsing")) { applyPreset([.back, .forward, .tabs, .more], address: .reload) }
                    Button(FeatureText.text("Reading")) { applyPreset([.back, .readerMode, .bookmark, .more], address: .darkMode) }
                    Button(FeatureText.text("Media")) { applyPreset([.back, .resources, .downloads, .more], address: .reload) }
                } label: { Label(FeatureText.text("Toolbar presets"), systemImage: "rectangle.3.group") }
                .accessibilityIdentifier("browser-toolbar.presets")
            }

            HStack {
                Text(LanguageManager.shared.localizedString("toolbar_replace_action"))
                    .font(.headline)
                Spacer()
                Text(selectedAction(isMore: isMore).localizedTitle)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            }
            ToolbarActionSearchField(query: $search, identifier: "browser-toolbar.action-search")
            LazyVGrid(columns: ToolbarActionPickerLayout.columns, spacing: 10) {
                ForEach(availableActions(isMore: isMore)) { action in
                    actionChoice(action, isMore: isMore)
                }
            }
        }
    }

    private var bottomActionBar: some View {
        AdaptiveActionRow(spacing: 12) {
            Button {
                showRestoreConfirmation = true
            } label: {
                Label(ToolText.text("toolbar_restore"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(CompactActionButtonStyle(fillsHeight: true))
            .accessibilityIdentifier("toolbar.restore")

            Button {
                // Saving one section must not persist pending edits in another.
                switch selection {
                case .home: saveHomeDraft()
                case .browsing: service.save(actions: draftActions, addressAction: draftAddressAction, leadingAction: draftLeadingAction)
                case .more: service.saveMoreActions(draftMoreActions)
                }
                saveFeedback = SaveFeedback(section: selection)
                AppAccessibility.announce(saveMessage)
                HapticsManager.success()
            } label: {
                Label(LanguageManager.shared.localizedString(showsSaveFeedback ? "web_capture_saved" : "save"),
                      systemImage: showsSaveFeedback ? "checkmark.circle.fill" : "checkmark")
                    .contentTransition(.opacity)
            }
            .buttonStyle(CompactActionButtonStyle(prominent: true, fillsHeight: true))
            .tint(showsSaveFeedback ? Color(red: 0.04, green: 0.44, blue: 0.29) : nil)
            .accessibilityIdentifier(selection == .home ? "home-toolbar.save" : "browser-toolbar.save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsSaveFeedback)
    }

    private var saveFeedbackNotice: some View {
        Label {
            Text(saveMessage)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
            .font(.body.weight(.semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(uiColor: .label), in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.22), radius: 10, y: 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("toolbar.saved")
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    private func applyPreset(_ actions: [BrowserToolbarAction], address: BrowserToolbarAction) {
        draftActions = actions; draftAddressAction = address; draftLeadingAction = .siteInformation; selectedToolbarSlot = 0
        HapticsManager.selection()
    }

    private func saveHomeDraft() {
        homeService.save(draftHomeActions, layout: draftHomeLayout, sharedVisibility: draftSharedHomeVisibility)
        draftSharedHomeVisibility.removeAll()
        if let title = draftHomeDisplay.title { UserDefaults.standard.set(title, forKey: "home_title") }
        if let subtitle = draftHomeDisplay.subtitle { UserDefaults.standard.set(subtitle, forKey: "home_subtitle") }
        if let enabled = draftHomeDisplay.liveActivityEnabled { LiveActivityService.shared.setEnabled(enabled) }
        draftHomeDisplay = HomeDisplayDraft()
    }

    private func restoreDefaults() {
        saveFeedback = nil
        switch selection {
        case .home:
            draftHomeDisplay = HomeDisplayDraft()
            draftHomeActions = Array(repeating: .none, count: HomeToolbarConfigurationService.slotCount)
            draftHomeLayout = HomeToolbarLayout()
            draftSharedHomeVisibility = Dictionary(uniqueKeysWithValues: HomePageElement.allCases.compactMap { element in
                element.sharedPreferenceKey.map { _ in (element, element.defaultVisibility) }
            })
            saveHomeDraft()
        case .browsing:
            service.reset()
            draftActions = service.actions
            draftAddressAction = service.addressAction
            draftLeadingAction = service.leadingAction
            selectedToolbarSlot = 0
        case .more:
            service.resetMoreActions()
            draftMoreActions = service.moreActions
            selectedMoreSlot = 0
        }
        HapticsManager.selection()
    }

    private func morePreview(compact: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 4) {
            ForEach(draftMoreActions.indices, id: \.self) { index in
                let action = draftMoreActions[index]
                Button { selectedMoreSlot = index; HapticsManager.selection() } label: {
                    Group {
                        if compact {
                            Image(systemName: action.systemImage)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 32)
                        } else {
                            BrowserMoreShortcutLabel(symbol: action.systemImage, title: action.localizedTitle,
                                tabCount: action == .tabs ? 2 : nil)
                        }
                    }
                        .contentShape(Rectangle())
                        .background(selectedMoreSlot == index ? Color.themePrimary.opacity(0.1) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10).stroke(selectedMoreSlot == index ? Color.themePrimary : .clear, lineWidth: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser-toolbar.more-slot.\(index)")
                .accessibilityLabel(String(format: ToolText.text("home_toolbar_slot"), index + 1) + ", " + action.localizedTitle)
            }
        }
        .padding(compact ? 6 : 10)
        .frame(maxWidth: 336)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay { RoundedRectangle(cornerRadius: 26).stroke(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .frame(maxWidth: .infinity)
    }

    private var toolbarPreview: some View {
        HStack(spacing: 4) {
            if toolbarAction(at: 0) != .none {
                previewAction(toolbarAction(at: 0), slot: 0)
            }
            if toolbarAction(at: 1) != .none {
                previewAction(toolbarAction(at: 1), slot: 1)
            }

            HStack(spacing: 0) {
                Button {
                    selectedToolbarSlot = 5; HapticsManager.selection()
                } label: {
                    Image(systemName: draftLeadingAction.systemImage)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 30, height: 36)
                        .foregroundStyle(selectedToolbarSlot == 5 ? Color.themePrimary : .secondary)
                        .background(selectedToolbarSlot == 5 ? Color.themePrimary.opacity(0.12) : .clear, in: Capsule())
                }
                .accessibilityLabel(draftLeadingAction.localizedTitle)
                .accessibilityIdentifier("browser-toolbar.leading-preview")
                Button {
                    selectedToolbarSlot = 4; HapticsManager.selection()
                } label: {
                    HStack(spacing: 4) {
                        Text("soulo.dkluge.com").font(.caption.weight(.medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if draftAddressAction != .none {
                            Image(systemName: draftAddressAction.systemImage).font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .padding(.trailing, 10).frame(maxWidth: .infinity, minHeight: 36)
                    .contentShape(Capsule())
                }
                .accessibilityLabel(draftAddressAction.localizedTitle)
            }
            .buttonStyle(.plain)
            .background(.thinMaterial, in: Capsule())
            .overlay {
                Capsule().stroke([4, 5].contains(selectedToolbarSlot) ? Color.themePrimary : Color.primary.opacity(0.08), lineWidth: [4, 5].contains(selectedToolbarSlot) ? 2 : 0.5)
            }

            if toolbarAction(at: 2) != .none {
                previewAction(toolbarAction(at: 2), slot: 2)
            }
            if toolbarAction(at: 3) != .none {
                previewAction(toolbarAction(at: 3), slot: 3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
    }

    /// Keeps every configurable position reachable even after its visible action
    /// has been removed from the live preview and browser toolbar.
    private var slotPicker: some View {
        HStack(spacing: 8) {
            ForEach(0..<6, id: \.self) { index in
                Button {
                    selectedToolbarSlot = index
                    HapticsManager.selection()
                } label: {
                    Image(systemName: index == 5 ? "lock" : index == 4 ? "link" : "\(index + 1).circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(selectedToolbarSlot == index ? Color.themePrimary : .secondary)
                        .background(
                            selectedToolbarSlot == index
                                ? Color.themePrimary.opacity(0.12)
                                : Color.primary.opacity(0.045),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser-toolbar.slot.\(index)")
                .accessibilityLabel(
                    index == 5 ? LanguageManager.shared.localizedString("site_information") : index == 4
                        ? LanguageManager.shared.localizedString("browser_edit_address")
                        : "\(LanguageManager.shared.localizedString("toolbar_replace_action")) \(index + 1)"
                )
            }
        }
    }

    private func previewAction(_ action: BrowserToolbarAction, slot: Int) -> some View {
        Button {
            selectedToolbarSlot = slot
            HapticsManager.selection()
        } label: {
            ZStack {
                if action != .none {
                    if action == .tabs { TabCountSymbol(count: 2) }
                    else { Image(systemName: action.systemImage).font(.system(size: AppControlMetrics.iconSize, weight: .semibold)) }
                }
            }
                .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
                .background(
                    selectedToolbarSlot == slot
                        ? Color.themePrimary.opacity(0.16)
                        : action == .none ? Color.clear : Color.primary.opacity(0.06),
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(selectedToolbarSlot == slot ? Color.themePrimary : .clear, lineWidth: 1.5)
                }
                .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.localizedTitle)
        .accessibilityIdentifier("browser-toolbar.preview-slot.\(slot)")
    }

    private func actionChoice(_ action: BrowserToolbarAction, isMore: Bool) -> some View {
        let isSelected = selectedAction(isMore: isMore) == action
        return Button {
            if isMore {
                guard draftMoreActions.indices.contains(selectedMoreSlot) else { return }
                draftMoreActions[selectedMoreSlot] = action
            } else if selectedToolbarSlot == 5 {
                draftLeadingAction = action
            } else if selectedToolbarSlot == 4 {
                draftAddressAction = action
            } else {
                guard draftActions.indices.contains(selectedToolbarSlot) else { return }
                draftActions[selectedToolbarSlot] = action
            }
            HapticsManager.selection()
        } label: {
            ToolbarActionChoiceLabel(symbol: action.systemImage, title: action.localizedTitle, isSelected: isSelected,
                tabCount: action == .tabs ? 2 : nil)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(selection == (isMore ? .more : .browsing) ? "browser-toolbar.action.\(action.rawValue)" : "browser-toolbar.inactive-action.\(action.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedAction(isMore: Bool) -> BrowserToolbarAction {
        if isMore {
            return draftMoreActions.indices.contains(selectedMoreSlot) ? draftMoreActions[selectedMoreSlot] : .none
        }
        if selectedToolbarSlot == 5 { return draftLeadingAction }
        if selectedToolbarSlot == 4 { return draftAddressAction }
        return toolbarAction(at: selectedToolbarSlot)
    }

    private func toolbarAction(at index: Int) -> BrowserToolbarAction {
        draftActions.indices.contains(index) ? draftActions[index] : .none
    }

    private func availableActions(isMore: Bool) -> [BrowserToolbarAction] {
        let visibleActions = BrowserToolbarAction.allCases.filter {
            !BrowserToolbarConfigurationService.temporarilyUnavailableActions.contains($0)
                && (search.isEmpty || $0.localizedTitle.localizedCaseInsensitiveContains(search))
        }
        if isMore { return visibleActions.filter { $0 != .more } }
        if selectedToolbarSlot == 4 || selectedToolbarSlot == 5 {
            return visibleActions.filter { ![.more, .tabs].contains($0) }
        }
        return visibleActions
    }
}


// Both toolbar editors use the same four-column picker and selection treatment.
enum ToolbarActionPickerLayout {
    static var columns: [GridItem] { Array(repeating: GridItem(.flexible(), spacing: 10), count: 4) }
}

struct ToolbarActionSearchField: View {
    @Binding var query: String
    let identifier: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(LanguageManager.shared.localizedString("search"), text: $query)
                .accessibilityIdentifier(identifier)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct ToolbarActionChoiceLabel: View {
    let symbol: String
    let title: String
    let isSelected: Bool
    var tabCount: Int?
    @ScaledMetric(relativeTo: .caption) private var titleHeight: CGFloat = 32
    var body: some View {
        VStack(spacing: 7) {
            Group {
                if let tabCount { TabCountSymbol(count: tabCount) }
                else { Image(systemName: symbol).font(.system(size: 17, weight: .semibold)) }
            }.frame(height: 22)
            Text(title)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .frame(height: titleHeight)
        }
        .foregroundStyle(isSelected ? Color.themePrimary : .primary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 10)
        .frame(minHeight: 82)
        .background(isSelected ? Color.themePrimary.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.themePrimary.opacity(0.75) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Shared by the live More panel and its editor, including icon and caption metrics.
struct BrowserMoreShortcutLabel: View {
    let symbol: String
    let title: String
    var tabCount: Int?
    var tint: Color = .primary

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let tabCount { TabCountSymbol(count: tabCount) }
                else { Image(systemName: symbol).font(.system(size: 19, weight: .regular)) }
            }
            .foregroundStyle(tint).frame(height: 23)
            Text(title).font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary).lineLimit(1).allowsTightening(true)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 57)
        .contentShape(Rectangle())
    }
}
