import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let platformDragType = UTType(exportedAs: "com.dkluge.soulo.platform", conformingTo: .plainText)

private enum PlatformManagementLayout: String {
    case list
    case grid
}

struct PlatformManagementView: View {
    @EnvironmentObject private var tabManager: TabManager
    @ObservedObject private var defaultSearch = GroupDefaultSearchService.shared
    @State private var searchGroup: GroupSection?
    @State private var draggedPlatform: UUID?
    @State private var draggedSection: String?
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
    @State private var showAutoHidePlatformHint = false
    @State private var showPlatformBarGuide = false
    @AppStorage(PlatformBarPreferences.visibilityKey) private var showPlatformBar = true
    @AppStorage("auto_hide_platform_bar") private var autoHidePlatformBar = false
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
            do {
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
        .sheet(item: $searchGroup) { section in
            GroupSearchSettingsView(scope: section.region.map(SearchGroupScope.region) ?? .custom(section.customGroup!.id), originalName: section.name) { name in
                if let region = section.region { store.renameRegion(region, to: name) }
                else if let group = section.customGroup { store.renameGroup(id: group.id, name: name) }
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("platform_management"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPlatformBarGuide) {
            BrowsingDisplayGuide(example: .platformBar, enabled: $showPlatformBar)
        }
        .alert(ToolText.text("auto_hide_platform_bar"), isPresented: $showAutoHidePlatformHint) {
            Button(ToolText.text("done"), role: .cancel) { }
        } message: {
            Text(ToolText.text("auto_hide_platform_bar_hint"))
        }
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
                .accessibilityIdentifier("platform.layout")
                .accessibilityLabel(
                    LanguageManager.shared.localizedString(
                        layout == .list ? "platform_grid_view" : "platform_list_view"
                    )
                )

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
        PlatformNativeList(
            sections: sections,
            autoHideControl: AnyView(autoHidePlatformToggle),
            autoHideEnabled: autoHidePlatformBar && showPlatformBar,
            hint: showPlatformBar ? ToolText.text("auto_hide_platform_bar_hint") : "",
            requestControl: AnyView(platformRequestButton),
            headerNames: sections.map { defaultSearch.engine(for: $0.scope).name },
            header: { AnyView(platformSectionHeader($0)) },
            makeProvider: { beginPlatformDrag($0, in: $1) },
            move: moveDraggedPlatform,
            dragEnded: { draggedPlatform = nil; draggedSection = nil },
            edit: { editingPlatform = $0 },
            toggle: { store.toggleVisibility(for: $0) },
            delete: { store.deletePlatform(id: $0) },
            add: { addPlatformFromSection = $0 },
            addExisting: addExistingPlatform
        )
    }

    private var autoHidePlatformToggle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(ToolText.text("show_platform_bar"), isOn: Binding(
                get: { showPlatformBar },
                set: { enabled in
                    showPlatformBar = enabled
                    for tab in tabManager.tabs { tab.webViewModel.resetPlatformBarAutoHide() }
                    if !enabled { showPlatformBarGuide = true }
                }
            ))
            .accessibilityIdentifier("platform.show-platform-bar")
            if showPlatformBar {
                Divider()
                Toggle(ToolText.text("auto_hide_platform_bar"), isOn: Binding(
                    get: { autoHidePlatformBar },
                    set: { enabled in
                        autoHidePlatformBar = enabled
                        for tab in tabManager.tabs { tab.webViewModel.resetPlatformBarAutoHide() }
                        if enabled { showAutoHidePlatformHint = true }
                    }
                ))
                .accessibilityIdentifier("platform.auto-hide-platforms")
            }
            Divider()
            HomeQuickSearchToggle()
        }
    }

    private func beginPlatformDrag(_ platform: SearchPlatform, in section: GroupSection) -> NSItemProvider {
        draggedPlatform = platform.id; draggedSection = section.id
        #if SOULO_ACCEPTANCE
        NSLog("[SouloPlatformDrag] start %@ in %@ (%@)", platform.id.uuidString, section.id, layoutRawValue)
        #endif
        let provider = NSItemProvider(), data = Data(platform.id.uuidString.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: platformDragType.identifier, visibility: .ownProcess) { completion in
            completion(data, nil); return nil
        }
        return provider
    }

    private func moveDraggedPlatform(_ source: UUID, from sourceID: String, to destinationID: String, at index: Int) -> Bool {
        guard let origin = sections.first(where: { $0.id == sourceID }),
              let destination = sections.first(where: { $0.id == destinationID }),
              (0...destination.platforms.count).contains(index) else { return false }
        var target = index < destination.platforms.count ? destination.platforms[index].id : nil
        if origin.id == destination.id, let old = destination.platforms.firstIndex(where: { $0.id == source }), old < index, index > 0 {
            target = destination.platforms[index - 1].id
        }
        return store.movePlatform(source, from: origin.scope, to: destination.scope, relativeTo: target)
    }

    private func platformDrop(target: UUID? = nil, in destination: GroupSection) -> PlatformGridDropDelegate {
        PlatformGridDropDelegate(target: target, dragged: $draggedPlatform, draggedSection: $draggedSection) { source, sourceSection, target in
            guard let origin = sections.first(where: { $0.id == sourceSection }) else { return false }
            return withAnimation(.easeInOut(duration: 0.18)) {
                store.movePlatform(source, from: origin.scope, to: destination.scope, relativeTo: target)
            }
        }
    }

    private var gridContent: some View {
        ScrollView {
            // Each section already owns a lazy grid. Nesting a vertical lazy
            // stack around those grids can keep re-estimating their heights
            // indefinitely after an import changes the offscreen sections.
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    autoHidePlatformToggle
                        .padding(14)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    if showPlatformBar { Text(ToolText.text("auto_hide_platform_bar_hint"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                    }
                }
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
                                    .accessibilityIdentifier("platform.grid.\(platform.id.uuidString)")
                                    .onDrag { beginPlatformDrag(platform, in: section) }
                                    .onDrop(of: [platformDragType], delegate: platformDrop(target: platform.id, in: section))
                                }
                            }
                        }

                        platformSectionActions(section)
                    }
                    .padding(14)
                    .contentShape(Rectangle())
                    .onDrop(of: [platformDragType], delegate: platformDrop(in: section))
                    .accessibilityIdentifier("platform.group." + section.id)
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
        .accessibilityIdentifier("platform.groups.grid")
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func platformSectionHeader(_ section: GroupSection) -> some View {
        HStack {
            Text(section.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Button { searchGroup = section } label: {
                let scope = section.region.map(SearchGroupScope.region) ?? .custom(section.customGroup!.id)
                Text(ToolText.text("group_default_search") + " · " + LanguageManager.shared.localizedString(defaultSearch.engine(for: scope).name))
                    .font(.caption).lineLimit(1).foregroundStyle(Color.themePrimary)
            }.buttonStyle(.plain)
                .accessibilityIdentifier("platform.default-search.\(section.id)")

            Spacer(minLength: 4)

            Button {
                searchGroup = section
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
        .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
        .accessibilityIdentifier("platform.managementMenu")
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

private struct HomeQuickSearchToggle: View {
    @AppStorage(PlatformBarPreferences.homeQuickSearchKey) private var enabled = false

    var body: some View {
        Toggle(LanguageManager.shared.localizedString("home_quick_search"), isOn: $enabled)
            .accessibilityIdentifier("platform.home-quick-search")
    }
}

// Native table drag/drop owns the entire list gesture. SwiftUI List's per-group
// reordering cannot transfer an item to a different dynamic section on iOS 16.
private struct PlatformNativeList: UIViewControllerRepresentable {
    let sections: [GroupSection]
    let autoHideControl: AnyView
    let autoHideEnabled: Bool
    let hint: String
    let requestControl: AnyView
    let headerNames: [String]
    let header: (GroupSection) -> AnyView
    let makeProvider: (SearchPlatform, GroupSection) -> NSItemProvider
    let move: (UUID, String, String, Int) -> Bool
    let dragEnded: () -> Void
    let edit: (SearchPlatform) -> Void
    let toggle: (UUID) -> Void
    let delete: (UUID) -> Void
    let add: (GroupSection) -> Void
    let addExisting: (GroupSection) -> Void

    private var signature: Int {
        var hash = Hasher()
        hash.combine(autoHideEnabled); hash.combine(hint); hash.combine(headerNames)
        for section in sections {
            hash.combine(section.id); hash.combine(section.name)
            for item in section.platforms {
                hash.combine(item.id); hash.combine(item.name); hash.combine(item.iconName)
                hash.combine(item.faviconURL); hash.combine(item.homeURL)
                hash.combine(item.isVisible); hash.combine(item.requiresLogin)
            }
        }
        return hash.finalize()
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UITableViewController {
        let controller = UITableViewController(style: .insetGrouped)
        let table: UITableView = controller.tableView
        table.accessibilityIdentifier = "platform.groups.list"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "platform")
        table.register(UITableViewHeaderFooterView.self, forHeaderFooterViewReuseIdentifier: "group")
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 50
        table.sectionHeaderHeight = UITableView.automaticDimension
        table.estimatedSectionHeaderHeight = 46
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.dragDelegate = context.coordinator; table.dropDelegate = context.coordinator
        table.dragInteractionEnabled = true
        context.coordinator.table = table
        return controller
    }
    func updateUIViewController(_ controller: UITableViewController, context: Context) {
        context.coordinator.owner = self
        controller.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        context.coordinator.applyLatest()
    }
    static func dismantleUIViewController(_ controller: UITableViewController, coordinator: Coordinator) {
        controller.tableView.dragDelegate = nil; controller.tableView.dropDelegate = nil
        controller.tableView.delegate = nil; controller.tableView.dataSource = nil
    }

    @MainActor final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate, UITableViewDragDelegate, UITableViewDropDelegate {
        var owner: PlatformNativeList
        var sections: [GroupSection]
        var renderedSignature: Int
        weak var table: UITableView?
        private var dragging = false
        private struct DragToken { let platform: UUID; let section: String }
        init(_ owner: PlatformNativeList) {
            self.owner = owner; sections = owner.sections; renderedSignature = owner.signature
        }
        func applyLatest() {
            guard !dragging, let table, !table.hasActiveDrop, renderedSignature != owner.signature else { return }
            sections = owner.sections; renderedSignature = owner.signature
            table.reloadData()
        }
        private func section(at index: Int) -> GroupSection? {
            sections.indices.contains(index - 1) ? sections[index - 1] : nil
        }
        private func platform(at index: IndexPath) -> SearchPlatform? {
            guard let group = section(at: index.section), group.platforms.indices.contains(index.row) else { return nil }
            return group.platforms[index.row]
        }
        func numberOfSections(in tableView: UITableView) -> Int { sections.count + 2 }
        func tableView(_ tableView: UITableView, numberOfRowsInSection index: Int) -> Int {
            guard let group = section(at: index) else { return 1 }
            return max(1, group.platforms.count) + 2
        }
        func tableView(_ tableView: UITableView, cellForRowAt index: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "platform", for: index)
            cell.accessibilityIdentifier = nil; cell.isAccessibilityElement = false
            cell.selectionStyle = .none
            if index.section == 0 {
                let control = owner.autoHideControl
                cell.contentConfiguration = UIHostingConfiguration { control }.margins(.horizontal, 16).margins(.vertical, 12)
            } else if let group = section(at: index.section) {
                if let item = platform(at: index) {
                    let onToggle = owner.toggle, onEdit = owner.edit
                    cell.accessibilityIdentifier = "platform.row." + item.id.uuidString
                    cell.contentConfiguration = UIHostingConfiguration {
                        PlatformCompactRow(platform: item) { onToggle(item.id) }
                            .frame(minHeight: 44).contentShape(Rectangle())
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("platform.row." + item.id.uuidString)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_platform_hint"))
                            .accessibilityAction { onEdit(item) }
                    }.margins(.horizontal, 16).margins(.vertical, 3)
                } else if group.platforms.isEmpty && index.row == 0 {
                    cell.contentConfiguration = UIHostingConfiguration {
                        Text(LanguageManager.shared.localizedString("no_platforms_in_group"))
                            .font(.system(size: 13)).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.margins(.horizontal, 16).margins(.vertical, 3)
                } else {
                    let isAdd = index.row == max(1, group.platforms.count)
                    cell.contentConfiguration = UIHostingConfiguration {
                        Label(LanguageManager.shared.localizedString(isAdd ? "add_platform" : "add_existing"),
                              systemImage: isAdd ? "plus.circle.fill" : "arrow.right.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(Color.themePrimary)
                            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
                    }.margins(.horizontal, 16).margins(.vertical, 3)
                    cell.accessibilityTraits = .button
                }
            } else {
                let control = owner.requestControl
                cell.contentConfiguration = UIHostingConfiguration { control }.margins(.horizontal, 16).margins(.vertical, 4)
            }
            return cell
        }
        func tableView(_ tableView: UITableView, viewForHeaderInSection index: Int) -> UIView? {
            guard let group = section(at: index),
                  let view = tableView.dequeueReusableHeaderFooterView(withIdentifier: "group") else { return nil }
            let content = owner.header(group)
            view.accessibilityIdentifier = "platform.group." + group.id
            view.contentConfiguration = UIHostingConfiguration { content }
                .margins(.horizontal, 16).margins(.top, 14).margins(.bottom, 6)
            return view
        }
        func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
            section == 0 ? owner.hint : nil
        }
        func tableView(_ tableView: UITableView, didSelectRowAt index: IndexPath) {
            guard let group = section(at: index.section) else { return }
            if let item = platform(at: index) { owner.edit(item) }
            else if index.row == max(1, group.platforms.count) { owner.add(group) }
            else if index.row > max(1, group.platforms.count) { owner.addExisting(group) }
        }
        func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt index: IndexPath) -> UISwipeActionsConfiguration? {
            guard let item = platform(at: index) else { return nil }
            let action = UIContextualAction(style: .destructive, title: LanguageManager.shared.localizedString("delete")) { [weak self] _, _, completion in
                self?.owner.delete(item.id); completion(true)
            }
            action.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [action])
        }
        func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at index: IndexPath) -> [UIDragItem] {
            guard let item = platform(at: index), let group = section(at: index.section) else { return [] }
            let drag = UIDragItem(itemProvider: owner.makeProvider(item, group))
            drag.localObject = DragToken(platform: item.id, section: group.id)
            session.localContext = self
            return [drag]
        }
        func tableView(_ tableView: UITableView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        func tableView(_ tableView: UITableView, dragSessionWillBegin session: UIDragSession) { dragging = true }
        func tableView(_ tableView: UITableView, dragSessionDidEnd session: UIDragSession) {
            dragging = false; owner.dragEnded()
            DispatchQueue.main.async { [weak self] in self?.applyLatest() }
        }
        func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
            (session.localDragSession?.localContext as? Coordinator) === self
        }
        func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
                       withDestinationIndexPath destination: IndexPath?) -> UITableViewDropProposal {
            let allowed = self.tableView(tableView, canHandle: session) && destination.flatMap { section(at: $0.section) } != nil
            return UITableViewDropProposal(operation: allowed ? .move : .forbidden, intent: .insertAtDestinationIndexPath)
        }
        func tableView(_ tableView: UITableView, performDropWith drop: UITableViewDropCoordinator) {
            guard self.tableView(tableView, canHandle: drop.session), let index = drop.destinationIndexPath,
                  let group = section(at: index.section), let item = drop.items.first,
                  let token = item.dragItem.localObject as? DragToken else { return }
            let row = min(max(0, index.row), group.platforms.count)
            if owner.move(token.platform, token.section, group.id, row) {
                drop.drop(item.dragItem, toRowAt: IndexPath(row: row, section: index.section))
            }
        }
        func tableView(_ tableView: UITableView, dropSessionDidEnd session: UIDropSession) {
            DispatchQueue.main.async { [weak self] in self?.applyLatest() }
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
    var scope: SearchGroupScope {
        if let region { return .region(region) }
        return .custom(customGroup!.id)
    }
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

private struct PlatformGridDropDelegate: DropDelegate {
    let target: UUID?
    @Binding var dragged: UUID?
    @Binding var draggedSection: String?
    let move: (UUID, String, UUID?) -> Bool
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && draggedSection != nil && info.hasItemsConforming(to: [platformDragType]) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info), let source = dragged, let origin = draggedSection else { return false }
        let moved = move(source, origin, target)
        dragged = nil; draggedSection = nil
        return moved
    }
}
