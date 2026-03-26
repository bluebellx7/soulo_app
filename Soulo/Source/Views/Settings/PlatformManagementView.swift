import SwiftUI

struct PlatformManagementView: View {
    @ObservedObject private var store = PlatformDataStore.shared
    @State private var showAddGroup = false
    @State private var newGroupName = ""
    @State private var editingPlatform: SearchPlatform? = nil
    @State private var deleteGroupConfirm: CustomGroup? = nil
    @State private var showResetConfirm = false
    @State private var addPlatformFromSection: GroupSection? = nil
    @State private var addPlatformToGroup: CustomGroup? = nil
    @State private var moveToRegion: RegionWrapper? = nil
    @State private var renameGroup: CustomGroup? = nil
    @State private var renamingRegion: PlatformRegion? = nil
    @State private var renameText = ""
    @State private var showBatchImport = false

    // All sections: built-in regions + custom groups
    private var sections: [GroupSection] {
        var result: [GroupSection] = []
        // Built-in regions
        for region in PlatformRegion.allCases {
            let platforms = store.platforms
                .filter { $0.region == region }
                .sorted { $0.sortOrder < $1.sortOrder }
            if !platforms.isEmpty {
                result.append(GroupSection(
                    id: region.rawValue,
                    name: store.regionDisplayName(for: region),
                    platforms: platforms,
                    isBuiltIn: true,
                    region: region,
                    customGroup: nil
                ))
            }
        }
        // Custom groups
        for group in store.customGroups {
            let platforms = store.platformsForGroup(group)
            result.append(GroupSection(
                id: group.id.uuidString,
                name: group.name,
                platforms: platforms,
                isBuiltIn: false,
                region: nil,
                customGroup: group
            ))
        }
        return result
    }

    var body: some View {
        List {
            ForEach(sections) { section in
                Section {
                    // Platforms in this group (with drag reorder for built-in)
                    if section.platforms.isEmpty {
                        Text(LanguageManager.shared.localizedString("no_platforms_in_group"))
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    } else {
                        ForEach(section.platforms) { platform in
                            PlatformCompactRow(platform: platform) {
                                store.toggleVisibility(for: platform.id)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { editingPlatform = platform }
                            .listRowInsets(EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    withAnimation { store.deletePlatform(id: platform.id) }
                                } label: {
                                    Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                                }
                            }
                        }
                        .onMove { indices, destination in
                            if section.isBuiltIn, let region = section.region {
                                var regionPlatforms = store.platforms
                                    .filter { $0.region == region }
                                    .sorted { $0.sortOrder < $1.sortOrder }
                                regionPlatforms.move(fromOffsets: indices, toOffset: destination)
                                for (i, p) in regionPlatforms.enumerated() {
                                    store.movePlatform(id: p.id, toSortOrder: i)
                                }
                            }
                        }
                    }

                    // Action buttons at bottom of every section
                    // Add new platform — separate row
                    Button {
                        addPlatformFromSection = section
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text(LanguageManager.shared.localizedString("add_platform"))
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(.blue)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))

                    // Add existing — separate row
                    Button {
                        if let group = section.customGroup {
                            addPlatformToGroup = group
                        } else if let region = section.region {
                            moveToRegion = RegionWrapper(region: region)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.right.circle.fill")
                                .font(.system(size: 12))
                            Text(LanguageManager.shared.localizedString("add_existing"))
                                .font(.system(size: 12))
                            Spacer()
                        }
                        .foregroundStyle(.purple)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
                } header: {
                    HStack {
                        Text(section.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        Spacer()

                        // Rename
                        Button {
                            renameText = section.name
                            if let region = section.region {
                                renamingRegion = region
                            } else if let group = section.customGroup {
                                renameGroup = group
                            }
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        // Delete (custom groups only)
                        if !section.isBuiltIn, let group = section.customGroup {
                            Button(role: .destructive) {
                                deleteGroupConfirm = group
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(LanguageManager.shared.localizedString("platform_management"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        showAddGroup = true
                    } label: {
                        Label(LanguageManager.shared.localizedString("add_group"), systemImage: "folder.badge.plus")
                    }
                    Button {
                        addPlatformFromSection = GroupSection(id: "_toolbar_", name: "", platforms: [], isBuiltIn: true, region: .international, customGroup: nil)
                    } label: {
                        Label(LanguageManager.shared.localizedString("add_platform"), systemImage: "plus.circle")
                    }
                    Button {
                        showBatchImport = true
                    } label: {
                        Label(LanguageManager.shared.localizedString("batch_import"), systemImage: "square.and.arrow.down")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label(LanguageManager.shared.localizedString("reset_to_defaults"), systemImage: "arrow.counterclockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        // Delete group confirmation
        .alert(LanguageManager.shared.localizedString("confirm_delete_group"), isPresented: Binding(
            get: { deleteGroupConfirm != nil },
            set: { if !$0 { deleteGroupConfirm = nil } }
        )) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                if let group = deleteGroupConfirm {
                    withAnimation { store.deleteGroup(id: group.id) }
                }
                deleteGroupConfirm = nil
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { deleteGroupConfirm = nil }
        }
        // Reset all confirmation
        .alert(LanguageManager.shared.localizedString("confirm_reset"), isPresented: $showResetConfirm) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .destructive) {
                store.resetToDefaults()
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        // Add group alert
        .alert(LanguageManager.shared.localizedString("add_group"), isPresented: $showAddGroup) {
            TextField(LanguageManager.shared.localizedString("group_name"), text: $newGroupName)
            Button(LanguageManager.shared.localizedString("confirm")) {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { store.addGroup(name: name) }
                newGroupName = ""
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { newGroupName = "" }
        }
        // Rename group alert
        .alert(LanguageManager.shared.localizedString("edit"), isPresented: Binding(
            get: { renameGroup != nil },
            set: { if !$0 { renameGroup = nil } }
        )) {
            TextField("", text: $renameText)
            Button(LanguageManager.shared.localizedString("save")) {
                if let group = renameGroup {
                    store.renameGroup(id: group.id, name: renameText)
                }
                renameGroup = nil
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { renameGroup = nil }
        }
        // Rename built-in region alert
        .alert(LanguageManager.shared.localizedString("edit"), isPresented: Binding(
            get: { renamingRegion != nil },
            set: { if !$0 { renamingRegion = nil } }
        )) {
            TextField("", text: $renameText)
            Button(LanguageManager.shared.localizedString("save")) {
                if let region = renamingRegion {
                    store.renameRegion(region, to: renameText)
                }
                renamingRegion = nil
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { renamingRegion = nil }
        }
        // Edit platform sheet
        .sheet(item: $editingPlatform) { platform in
            EditPlatformView(platform: platform)
        }
        // Add custom platform sheet
        .sheet(item: $addPlatformFromSection) { section in
            AddCustomPlatformView(
                targetGroupID: section.customGroup?.id,
                defaultRegion: section.region
            )
        }
        // Add existing to custom group
        .sheet(item: $addPlatformToGroup) { group in
            AddPlatformToGroupSheet(group: group)
        }
        // Move platform to built-in region
        .sheet(item: $moveToRegion) { wrapper in
            MovePlatformToRegionSheet(targetRegion: wrapper.region)
        }
        // Batch import
        .sheet(isPresented: $showBatchImport) {
            BatchImportView()
        }
    }
}

// MARK: - Compact Row

private struct PlatformCompactRow: View {
    let platform: SearchPlatform
    let onToggleVisibility: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            PlatformIconView(platform: platform, size: 20)

            Text(LanguageManager.shared.localizedString(platform.name))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(platform.isVisible ? .primary : .tertiary)
                .lineLimit(1)

            if platform.requiresLogin {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button { onToggleVisibility() } label: {
                Image(systemName: platform.isVisible ? "eye.fill" : "eye.slash")
                    .font(.system(size: 13))
                    .foregroundStyle(platform.isVisible ? .blue : Color(UIColor.quaternaryLabel))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Group Section Model

private struct GroupSection: Identifiable {
    let id: String
    let name: String
    let platforms: [SearchPlatform]
    let isBuiltIn: Bool
    let region: PlatformRegion?
    let customGroup: CustomGroup?
}

// MARK: - Add Platform to Group Sheet

struct AddPlatformToGroupSheet: View {
    let group: CustomGroup
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PlatformDataStore.shared
    @State private var selectedIDs: Set<UUID>

    init(group: CustomGroup) {
        self.group = group
        self._selectedIDs = State(initialValue: Set(group.platformIDs))
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(PlatformRegion.allCases) { region in
                    Section(LanguageManager.shared.localizedString(region.nameKey)) {
                        ForEach(store.platforms(for: region)) { platform in
                            Button {
                                if selectedIDs.contains(platform.id) {
                                    selectedIDs.remove(platform.id)
                                } else {
                                    selectedIDs.insert(platform.id)
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    PlatformIconView(platform: platform, size: 18)
                                    Text(LanguageManager.shared.localizedString(platform.name))
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if selectedIDs.contains(platform.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.blue)
                                            .font(.system(size: 16))
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.tertiary)
                                            .font(.system(size: 16))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(group.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("save")) {
                        if let idx = store.customGroups.firstIndex(where: { $0.id == group.id }) {
                            store.customGroups[idx].platformIDs = Array(selectedIDs)
                            store.saveGroups()
                        }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}

// MARK: - Move Platform to Built-in Region Sheet

struct MovePlatformToRegionSheet: View {
    let targetRegion: PlatformRegion
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PlatformDataStore.shared

    private var otherPlatforms: [(region: PlatformRegion, platforms: [SearchPlatform])] {
        PlatformRegion.allCases
            .filter { $0 != targetRegion }
            .compactMap { region in
                let p = store.platforms(for: region)
                return p.isEmpty ? nil : (region, p)
            }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(otherPlatforms, id: \.region) { item in
                    Section(store.regionDisplayName(for: item.region)) {
                        ForEach(item.platforms) { platform in
                            Button {
                                movePlatform(platform)
                            } label: {
                                HStack(spacing: 10) {
                                    PlatformIconView(platform: platform, size: 18)
                                    Text(LanguageManager.shared.localizedString(platform.name))
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(store.regionDisplayName(for: targetRegion))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
    }

    private func movePlatform(_ platform: SearchPlatform) {
        if let idx = store.platforms.firstIndex(where: { $0.id == platform.id }) {
            store.platforms[idx].region = targetRegion
            store.platforms[idx].sortOrder = store.platforms(for: targetRegion).count
            store.savePlatforms()
        }
    }
}

// MARK: - Region Wrapper for sheet(item:)

struct RegionWrapper: Identifiable {
    let id = UUID()
    let region: PlatformRegion
}
