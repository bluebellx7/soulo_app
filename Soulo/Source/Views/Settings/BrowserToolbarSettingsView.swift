import SwiftUI

struct BrowserToolbarSettingsView: View {
    @ObservedObject private var service = BrowserToolbarConfigurationService.shared
    @State private var draftActions = BrowserToolbarConfigurationService.defaultActions
    @State private var draftLeadingAction = BrowserToolbarConfigurationService.defaultLeadingAction
    @State private var draftAddressAction = BrowserToolbarConfigurationService.defaultAddressAction
    @State private var draftMoreActions = BrowserToolbarConfigurationService.defaultMoreActions
    @State private var editsMore = false
    @State private var selectedToolbarSlot = 0
    @State private var selectedMoreSlot = 0
    @State private var showSaved = false
    @State private var showRestoreConfirmation = false


    var body: some View {
        VStack(spacing: 0) {
            Picker(ToolText.text("home_toolbar_browser_tools"), selection: $editsMore) {
                Text(ToolText.text("home_toolbar_browser_tools")).tag(false)
                Text(ToolText.text("toolbar_more_panel")).tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .accessibilityIdentifier("browser-toolbar.section")

            TabView(selection: $editsMore) {
                editorPage(isMore: false).tag(false)
                editorPage(isMore: true).tag(true)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActionBar
        }
        .navigationTitle(LanguageManager.shared.localizedString("toolbar_customize"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draftActions = service.actions
            draftAddressAction = service.addressAction
            draftLeadingAction = service.leadingAction
            draftMoreActions = service.moreActions
            selectedToolbarSlot = 0
            selectedMoreSlot = 0
        }
        .alert(LanguageManager.shared.localizedString("toolbar_saved"), isPresented: $showSaved) {
            Button(LanguageManager.shared.localizedString("done"), role: .cancel) {}
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

    /// Each page owns its vertical scroll position. Native paging leaves
    /// button taps and any nested horizontal controls to their own gestures.
    private func editorPage(isMore: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(isMore ? ToolText.text("toolbar_more_panel") : LanguageManager.shared.localizedString("toolbar_preview"))
                        .font(.headline)
                    if isMore {
                        morePreview
                    } else {
                        toolbarPreview
                        slotPicker
                        Text(LanguageManager.shared.localizedString("toolbar_customize_hint"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !isMore {
                    Menu {
                        Button(FeatureText.text("Standard")) { applyPreset([.home, .back, .tabs, .more], address: .darkMode) }
                        Button(FeatureText.text("Browsing")) { applyPreset([.back, .forward, .tabs, .more], address: .reload) }
                        Button(FeatureText.text("Reading")) { applyPreset([.back, .readerMode, .bookmark, .more], address: .darkMode) }
                        Button(FeatureText.text("Media")) { applyPreset([.back, .resources, .downloads, .more], address: .reload) }
                    } label: { Label(FeatureText.text("Toolbar presets"), systemImage: "rectangle.3.group") }
                    .accessibilityIdentifier("browser-toolbar.presets")
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(LanguageManager.shared.localizedString("toolbar_replace_action"))
                            .font(.headline)
                        Spacer()
                        Text(selectedAction(isMore: isMore).localizedTitle)
                            .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: ToolbarActionPickerLayout.columns, spacing: 10) {
                        ForEach(availableActions(isMore: isMore)) { action in
                            actionChoice(action, isMore: isMore)
                        }
                    }
                }
            }.padding(20)
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

            Button {
                service.save(actions: draftActions, addressAction: draftAddressAction, moreActions: draftMoreActions, leadingAction: draftLeadingAction)
                showSaved = true
                HapticsManager.success()
            } label: {
                Label(LanguageManager.shared.localizedString("save"), systemImage: "checkmark")
            }
            .buttonStyle(CompactActionButtonStyle(prominent: true, fillsHeight: true))
            .accessibilityIdentifier("browser-toolbar.save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func applyPreset(_ actions: [BrowserToolbarAction], address: BrowserToolbarAction) {
        draftActions = actions; draftAddressAction = address; draftLeadingAction = .siteInformation; selectedToolbarSlot = 0
        HapticsManager.selection()
    }

    private func restoreDefaults() {
        if editsMore {
            service.resetMoreActions(); draftMoreActions = service.moreActions
        } else {
            service.reset(); draftActions = service.actions; draftAddressAction = service.addressAction; draftLeadingAction = service.leadingAction
        }
        if editsMore { selectedMoreSlot = 0 } else { selectedToolbarSlot = 0 }
        HapticsManager.selection()
    }

    private var morePreview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 4), spacing: 4) {
            ForEach(draftMoreActions.indices, id: \.self) { index in
                let action = draftMoreActions[index]
                Button { selectedMoreSlot = index; HapticsManager.selection() } label: {
                    BrowserMoreShortcutLabel(symbol: action.systemImage, title: action.localizedTitle,
                        tabCount: action == .tabs ? 2 : nil)
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
        .padding(10)
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
        .accessibilityIdentifier(isMore == editsMore ? "browser-toolbar.action.\(action.rawValue)" : "browser-toolbar.inactive-action.\(action.rawValue)")
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
