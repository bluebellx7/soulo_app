import SwiftUI

struct GroupManagementView: View {
    @State private var groups: [CustomGroup] = PlatformDataStore.shared.customGroups
    @State private var showAddGroup = false
    @State private var newGroupName = ""
    @State private var editingGroup: CustomGroup? = nil

    var body: some View {
        List {
            if groups.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("no_groups"),
                    systemImage: "folder.badge.plus",
                    description: Text(LanguageManager.shared.localizedString("no_groups_desc"))
                )
            } else {
                ForEach(groups) { group in
                    Button {
                        editingGroup = group
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(group.name)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.primary)
                                Text("\(group.platformIDs.count) \(LanguageManager.shared.localizedString("platforms_count"))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .swipeActions {
                        Button(role: .destructive) {
                            PlatformDataStore.shared.deleteGroup(id: group.id)
                            groups = PlatformDataStore.shared.customGroups
                        } label: {
                            Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LanguageManager.shared.localizedString("custom_groups"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddGroup = true } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert(LanguageManager.shared.localizedString("add_group"), isPresented: $showAddGroup) {
            TextField(LanguageManager.shared.localizedString("group_name"), text: $newGroupName)
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { newGroupName = "" }
            Button(LanguageManager.shared.localizedString("confirm")) {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    PlatformDataStore.shared.addGroup(name: name)
                    groups = PlatformDataStore.shared.customGroups
                }
                newGroupName = ""
            }
        }
        .sheet(item: $editingGroup) { group in
            GroupEditView(group: group, onDismiss: {
                editingGroup = nil
                groups = PlatformDataStore.shared.customGroups
            })
        }
    }
}

// MARK: - Edit Group (add/remove platforms)

struct GroupEditView: View {
    let group: CustomGroup
    var onDismiss: () -> Void
    @State private var selectedIDs: Set<UUID>
    @Environment(\.dismiss) private var dismiss

    init(group: CustomGroup, onDismiss: @escaping () -> Void) {
        self.group = group
        self.onDismiss = onDismiss
        self._selectedIDs = State(initialValue: Set(group.platformIDs))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(PlatformRegion.allCases) { region in
                    Section(LanguageManager.shared.localizedString(region.nameKey)) {
                        ForEach(PlatformDataStore.shared.platforms(for: region)) { platform in
                            Button {
                                togglePlatform(platform.id)
                            } label: {
                                HStack(spacing: 12) {
                                    PlatformIconView(platform: platform, size: 22)
                                    Text(LanguageManager.shared.localizedString(platform.name))
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedIDs.contains(platform.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss(); onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("save")) {
                        saveChanges()
                        dismiss()
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func togglePlatform(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func saveChanges() {
        // Update the group's platform IDs
        if let idx = PlatformDataStore.shared.customGroups.firstIndex(where: { $0.id == group.id }) {
            PlatformDataStore.shared.customGroups[idx].platformIDs = Array(selectedIDs)
            PlatformDataStore.shared.saveGroups()
        }
    }
}
