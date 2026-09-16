import SwiftUI

struct AppQuickActionSettingsView: View {
    @State private var actions = AppQuickAction.resolvedOrder(UserDefaults.standard.stringArray(forKey: AppQuickAction.orderKey))
    private var available: [AppQuickAction] { AppQuickAction.availableActions.filter { !actions.contains($0) } }

    var body: some View {
        List {
            Section {
                if actions.isEmpty {
                    Text(ToolText.text("quick_actions_empty")).foregroundStyle(.secondary)
                }
                ForEach(actions, id: \.rawValue) { action in
                    HStack(spacing: 12) {
                        Button {
                            actions.removeAll { $0 == action }
                            save()
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red).frame(width: 28, height: 40)
                        }.buttonStyle(.borderless)
                            .accessibilityLabel(ToolText.text("quick_actions_remove") + " · " + action.title)
                            .accessibilityIdentifier("quick-action.remove." + action.rawValue)
                        actionLabel(action)
                    }
                    .moveDisabled(false)
                    .accessibilityAction(named: Text(ToolText.text("quick_actions_up"))) { shift(action, by: -1) }
                    .accessibilityAction(named: Text(ToolText.text("quick_actions_down"))) { shift(action, by: 1) }
                }
                .onMove { source, destination in
                    actions.move(fromOffsets: source, toOffset: destination)
                    save()
                }
            } header: {
                Text(String(format: ToolText.text("quick_actions_selected"), actions.count, AppQuickAction.maximumCount))
            } footer: { Text(ToolText.text("quick_actions_hint")) }

            if !available.isEmpty {
                Section {
                    ForEach(available, id: \.rawValue) { action in
                        Button {
                            guard actions.count < AppQuickAction.maximumCount else { return }
                            actions.append(action)
                            save()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(actions.count < AppQuickAction.maximumCount ? Color.primary : .secondary)
                                    .frame(width: 28, height: 40)
                                actionLabel(action)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(actions.count >= AppQuickAction.maximumCount)
                            .accessibilityIdentifier("quick-action.add." + action.rawValue)
                    }.moveDisabled(true)
                } header: { Text(ToolText.text("quick_actions_available")) }
                footer: {
                    if actions.count >= AppQuickAction.maximumCount { Text(ToolText.text("quick_actions_limit")) }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle(ToolText.text("quick_actions_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ToolText.text("quick_actions_reset")) {
                    actions = AppQuickAction.defaultOrder
                    save()
                }.disabled(actions == AppQuickAction.defaultOrder)
            }
        }
    }

    private func actionLabel(_ action: AppQuickAction) -> some View {
        Label { Text(action.title).foregroundStyle(.primary) } icon: {
            IconBadge(systemName: action.symbol, color: Color(uiColor: .secondaryLabel))
        }
    }

    private func save() { AppQuickActionService.shared.saveOrder(actions) }
    private func shift(_ action: AppQuickAction, by offset: Int) {
        guard let index = actions.firstIndex(of: action), actions.indices.contains(index + offset) else { return }
        actions.swapAt(index, index + offset)
        save()
    }
}
