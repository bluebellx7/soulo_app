import SwiftUI

private enum PlatformManagementLayout: String {
    case list
    case grid
}

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
    @State private var showPlatformRequestFeedback = false
    @AppStorage("platform_management_layout") private var layoutRawValue = PlatformManagementLayout.list.rawValue

    private var layout: PlatformManagementLayout {
        PlatformManagementLayout(rawValue: layoutRawValue) ?? .list
    }

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
        Group {
            if layout == .grid {
                gridContent
            } else {
                listContent
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("platform_management"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        layoutRawValue = layout == .list
                            ? PlatformManagementLayout.grid.rawValue
                            : PlatformManagementLayout.list.rawValue
                    }
                } label: {
                    Image(systemName: layout == .list ? "square.grid.2x2" : "list.bullet")
                }
                .accessibilityLabel(
                    LanguageManager.shared.localizedString(
                        layout == .list ? "platform_grid_view" : "platform_list_view"
                    )
                )

                if layout == .list {
                    EditButton()
                }

                managementMenu
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
        .sheet(isPresented: $showPlatformRequestFeedback) {
            FeedbackView(
                initialType: "feature",
                initialContent: LanguageManager.shared.localizedString("platform_request_feedback_template")
            )
        }
    }

    private var listContent: some View {
        List {
            ForEach(sections) { section in
                platformListSection(section)
            }

            Section {
                platformRequestButton
            }
        }
        .listStyle(.insetGrouped)
    }

    private var gridContent: some View {
        ScrollView {
            LazyVStack(spacing: 22) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        platformSectionHeader(section)

                        if section.platforms.isEmpty {
                            Text(LanguageManager.shared.localizedString("no_platforms_in_group"))
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 82, maximum: 118), spacing: 10)],
                                spacing: 10
                            ) {
                                ForEach(section.platforms) { platform in
                                    PlatformGridCard(
                                        platform: platform,
                                        onEdit: { editingPlatform = platform },
                                        onToggleVisibility: { store.toggleVisibility(for: platform.id) }
                                    )
                                }
                            }
                        }

                        platformSectionActions(section)
                    }
                    .padding(14)
                    .background(
                        Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                }

                platformRequestButton
                    .padding(.top, 2)
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func platformListSection(_ section: GroupSection) -> some View {
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
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint(
                        LanguageManager.shared.localizedString("accessibility_edit_platform_hint")
                    )
                    .accessibilityAction { editingPlatform = platform }
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
                        store.movePlatform(from: indices, to: destination, within: region)
                    } else if let groupID = section.customGroup?.id {
                        store.movePlatform(from: indices, to: destination, withinGroup: groupID)
                    }
                }
            }

            Button {
                addPlatformFromSection = section
            } label: {
                Label(LanguageManager.shared.localizedString("add_platform"), systemImage: "plus.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themePrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 2, trailing: 16))

            Button {
                addExistingPlatform(to: section)
            } label: {
                Label(LanguageManager.shared.localizedString("add_existing"), systemImage: "arrow.right.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.themePrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16))
        } header: {
            platformSectionHeader(section)
        }
    }

    private func platformSectionHeader(_ section: GroupSection) -> some View {
        HStack {
            Text(section.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Spacer()

            Button {
                beginRenaming(section)
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel(LanguageManager.shared.localizedString("edit"))

            if !section.isBuiltIn, let group = section.customGroup {
                Button(role: .destructive) {
                    deleteGroupConfirm = group
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.7))
                        .frame(width: 28, height: 28)
                }
            }
        }
    }

    private func platformSectionActions(_ section: GroupSection) -> some View {
        HStack(spacing: 10) {
            Button {
                addPlatformFromSection = section
            } label: {
                Label(LanguageManager.shared.localizedString("add_platform"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color.themePrimary)

            Button {
                addExistingPlatform(to: section)
            } label: {
                Label(LanguageManager.shared.localizedString("add_existing"), systemImage: "arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .tint(Color.themePrimary)
        }
        .font(.system(size: 12, weight: .semibold))
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var platformRequestButton: some View {
        Button {
            showPlatformRequestFeedback = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                Text(LanguageManager.shared.localizedString("platform_not_found"))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var managementMenu: some View {
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

    private func beginRenaming(_ section: GroupSection) {
        renameText = section.name
        if let region = section.region {
            renamingRegion = region
        } else if let group = section.customGroup {
            renameGroup = group
        }
    }

    private func addExistingPlatform(to section: GroupSection) {
        if let group = section.customGroup {
            addPlatformToGroup = group
        } else if let region = section.region {
            moveToRegion = RegionWrapper(region: region)
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
                    .foregroundStyle(platform.isVisible ? Color.themePrimary : Color(UIColor.quaternaryLabel))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                LanguageManager.shared.localizedString("accessibility_platform_visibility")
            )
            .accessibilityValue(
                LanguageManager.shared.localizedString(
                    platform.isVisible ? "accessibility_enabled" : "accessibility_disabled"
                )
            )
        }
    }
}

// MARK: - Grid Card

private struct PlatformGridCard: View {
    let platform: SearchPlatform
    let onEdit: () -> Void
    let onToggleVisibility: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                PlatformIconView(platform: platform, size: 34)
                    .frame(maxWidth: .infinity)

                Button(action: onToggleVisibility) {
                    Image(systemName: platform.isVisible ? "eye.fill" : "eye.slash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(platform.isVisible ? Color.themePrimary : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(.thinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .accessibilityLabel(
                    LanguageManager.shared.localizedString("accessibility_platform_visibility")
                )
            }

            HStack(spacing: 3) {
                Text(LanguageManager.shared.localizedString(platform.name))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(platform.isVisible ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if platform.requiresLogin {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 82)
        .background(
            Color(uiColor: .tertiarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(platform.isVisible ? 0.08 : 0.04), lineWidth: 0.5)
        }
        .opacity(platform.isVisible ? 1 : 0.62)
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onTapGesture(perform: onEdit)
        .accessibilityElement(children: .contain)
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_platform_hint"))
        .accessibilityAction { onEdit() }
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
    @State private var selectedIDs: [UUID]

    init(group: CustomGroup) {
        self.group = group
        self._selectedIDs = State(initialValue: group.platformIDs)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(PlatformRegion.allCases) { region in
                    Section(LanguageManager.shared.localizedString(region.nameKey)) {
                        ForEach(store.platforms(for: region)) { platform in
                            Button {
                                if selectedIDs.contains(platform.id) {
                                    selectedIDs.removeAll { $0 == platform.id }
                                } else {
                                    selectedIDs.append(platform.id)
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
                                            .foregroundStyle(Color.themePrimary)
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
                        store.setPlatforms(selectedIDs, inGroup: group.id)
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
