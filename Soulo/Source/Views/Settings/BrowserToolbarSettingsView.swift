import SwiftUI

struct BrowserToolbarSettingsView: View {
    @ObservedObject private var service = BrowserToolbarConfigurationService.shared
    @State private var draftActions = BrowserToolbarConfigurationService.defaultActions
    @State private var draftAddressAction = BrowserToolbarConfigurationService.defaultAddressAction
    @State private var selectedSlot = 0
    @State private var showSaved = false
    @State private var showRestoreConfirmation = false

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(LanguageManager.shared.localizedString("toolbar_preview"))
                        .font(.headline)
                    toolbarPreview
                    slotPicker
                    Text(LanguageManager.shared.localizedString("toolbar_customize_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(LanguageManager.shared.localizedString("toolbar_replace_action"))
                            .font(.headline)
                        Spacer()
                        Text(selectedActionTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(availableActions) { action in
                            actionChoice(action)
                        }
                    }
                }

            }
            .padding(20)
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
        }
        .alert(LanguageManager.shared.localizedString("toolbar_saved"), isPresented: $showSaved) {
            Button(LanguageManager.shared.localizedString("done"), role: .cancel) {}
        }
        .alert(
            LanguageManager.shared.localizedString("toolbar_restore_confirm_title"),
            isPresented: $showRestoreConfirmation
        ) {
            Button(
                LanguageManager.shared.localizedString("toolbar_restore_default"),
                role: .destructive
            ) {
                restoreDefaults()
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        } message: {
            Text(LanguageManager.shared.localizedString("toolbar_restore_confirm_message"))
        }
    }

    private var bottomActionBar: some View {
        AdaptiveActionRow(spacing: 12) {
            Button {
                showRestoreConfirmation = true
            } label: {
                Label(LanguageManager.shared.localizedString("toolbar_restore_default"), systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(CompactActionButtonStyle(fillsHeight: true))

            Button {
                service.save(actions: draftActions, addressAction: draftAddressAction)
                showSaved = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label(LanguageManager.shared.localizedString("save"), systemImage: "checkmark")
            }
            .buttonStyle(CompactActionButtonStyle(prominent: true, fillsHeight: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func restoreDefaults() {
        service.reset()
        draftActions = service.actions
        draftAddressAction = service.addressAction
        selectedSlot = 0
        HapticsManager.selection()
    }

    private var toolbarPreview: some View {
        HStack(spacing: 4) {
            if draftActions[0] != .none {
                previewAction(draftActions[0], slot: 0)
            }
            if draftActions[1] != .none {
                previewAction(draftActions[1], slot: 1)
            }

            Button {
                selectedSlot = 4
                HapticsManager.selection()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("soulo.app")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if draftAddressAction != .none {
                        Image(systemName: draftAddressAction.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(.thinMaterial, in: Capsule())
                .overlay {
                    Capsule().stroke(selectedSlot == 4 ? Color.themePrimary : Color.primary.opacity(0.08), lineWidth: selectedSlot == 4 ? 2 : 0.5)
                }
            }
            .buttonStyle(.plain)

            if draftActions[2] != .none {
                previewAction(draftActions[2], slot: 2)
            }
            if draftActions[3] != .none {
                previewAction(draftActions[3], slot: 3)
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
            ForEach(0..<5, id: \.self) { index in
                Button {
                    selectedSlot = index
                    HapticsManager.selection()
                } label: {
                    Image(systemName: index == 4 ? "link" : "\(index + 1).circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 30)
                        .foregroundStyle(selectedSlot == index ? Color.themePrimary : .secondary)
                        .background(
                            selectedSlot == index
                                ? Color.themePrimary.opacity(0.12)
                                : Color.primary.opacity(0.045),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    index == 4
                        ? LanguageManager.shared.localizedString("browser_edit_address")
                        : "\(LanguageManager.shared.localizedString("toolbar_replace_action")) \(index + 1)"
                )
            }
        }
    }

    private func previewAction(_ action: BrowserToolbarAction, slot: Int) -> some View {
        Button {
            selectedSlot = slot
            HapticsManager.selection()
        } label: {
            ZStack {
                if action != .none {
                    Image(systemName: action.systemImage)
                        .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
            }
                .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
                .background(
                    selectedSlot == slot
                        ? Color.themePrimary.opacity(0.16)
                        : action == .none ? Color.clear : Color.primary.opacity(0.06),
                    in: Circle()
                )
                .overlay {
                    Circle().stroke(selectedSlot == slot ? Color.themePrimary : .clear, lineWidth: 1.5)
                }
                .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.localizedTitle)
    }

    private func actionChoice(_ action: BrowserToolbarAction) -> some View {
        let isSelected = selectedAction == action
        return Button {
            if selectedSlot == 4 {
                draftAddressAction = action
            } else {
                draftActions[selectedSlot] = action
            }
            HapticsManager.selection()
        } label: {
            VStack(spacing: 7) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(height: 22)
                Text(action.localizedTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .foregroundStyle(isSelected ? Color.themePrimary : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                isSelected ? Color.themePrimary.opacity(0.12) : Color(uiColor: .secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.themePrimary.opacity(0.75) : Color.primary.opacity(0.06), lineWidth: isSelected ? 1.5 : 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private var selectedAction: BrowserToolbarAction {
        selectedSlot == 4 ? draftAddressAction : draftActions[selectedSlot]
    }

    private var selectedActionTitle: String {
        selectedAction.localizedTitle
    }

    private var availableActions: [BrowserToolbarAction] {
        let visibleActions = BrowserToolbarAction.allCases.filter {
            !BrowserToolbarConfigurationService.temporarilyUnavailableActions.contains($0)
        }
        if selectedSlot == 4 {
            return visibleActions.filter { ![.more, .tabs].contains($0) }
        }
        return visibleActions
    }
}
