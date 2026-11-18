import SwiftUI
import WebKit

private enum StorageManagementRoute: Hashable, Identifiable {
    case group(StorageUsageGroup)
    case category(StorageUsageCategory)
    case site(WebsiteStorageEntry)
    case readingList, files, extensions, privacy, platforms, downloadTasks
    var id: Self { self }
}

enum StorageUsageGroup: String, CaseIterable, Identifiable {
    case websites, files, cache, saved, other
    var id: String { rawValue }
    var categories: Set<StorageUsageCategory> {
        switch self {
        case .websites: [.webData, .websiteStorage]
        case .files: [.downloads, .downloadTasks]
        case .cache: [.tabSnapshots, .favicons, .wallpaperCache, .otherCaches, .temporaryFiles, .ruleCache]
        case .saved: [.wallpapers, .readingData, .backups, .filterRules, .extensions, .personalData, .sharedData]
        case .other: [.otherData]
        }
    }
    @MainActor var title: String {
        switch self {
        case .websites: FeatureText.text("Website data")
        case .files: ToolText.text("storage_files_group")
        case .cache: ToolText.text("storage_cache_group")
        case .saved: ToolText.text("storage_saved_group")
        case .other: FeatureText.text("Other app data")
        }
    }
    var symbol: String {
        switch self {
        case .websites: "globe"
        case .files: "folder"
        case .cache: "externaldrive.badge.minus"
        case .saved: "tray.full"
        case .other: "square.stack.3d.up"
        }
    }
    var cleanupChoices: [StorageCleanupChoice] {
        switch self {
        case .websites: [.websiteData]
        case .files: [.cache(.downloadTasks), .downloadedFiles]
        case .cache: StorageUsageCategory.allCases.filter { categories.contains($0) && $0.canClear }.map(StorageCleanupChoice.cache)
        case .saved: [.wallpapers, .reading, .backups, .history, .bookmarks]
        case .other: [.systemCaches, .offlineMedia]
        }
    }
}

struct StorageUsageView: View {
    var group: StorageUsageGroup? = nil
    var onOpenInBrowser: ((URL) -> Void)? = nil
    @EnvironmentObject private var tabManager: TabManager
    @AppStorage(BrowsingHistoryExitPolicy.preferenceKey) private var clearBrowsingOnExit = false
    // Navigation must remain available while WebKit and disk estimates load.
    // Unknown sizes use a dash rather than presenting an empty, inert page.
    @State private var records = StorageUsageCategory.allCases.map {
        StorageUsageRecord(category: $0, bytes: 0, isEstimated: true)
    }
    @State private var inventory: StorageUsageInventory?
    @State private var clearing: StorageUsageCategory?
    @State private var refreshID = UUID()
    @State private var notice: String?
    @State private var error: String?
    @State private var loading = true
    @State private var bulkCleanup = false
    @State private var cleanupGroup: StorageUsageGroup? = nil

    var body: some View {
        List {
            if group == nil {
                Section {
                    sizeRow(FeatureText.text("App size"), bytes: inventory?.appBytes)
                    HStack(spacing: 8) {
                        sizeRow(FeatureText.text("App data"), bytes: inventory?.dataBytes)
                        Button { cleanupGroup = nil; bulkCleanup = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(LanguageManager.shared.localizedString("privacy_clear_action"))
                            .accessibilityIdentifier("storage.cleanup")
                            .disabled(clearing != nil)
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(FeatureText.text("App size is the installed program and resources, not the App Store download size."))
                        Text(FeatureText.text("App data is the total of the categories below."))
                    }
                }
                Section {
                    ForEach(StorageUsageGroup.allCases) { group in groupRow(group) }
                }
            } else if let group {
                if !group.cleanupChoices.isEmpty {
                    Section {
                        Button(LanguageManager.shared.localizedString("privacy_clear_action")) {
                            cleanupGroup = group; bulkCleanup = true
                        }.accessibilityIdentifier("storage.group.cleanup")
                    }
                }
                Section {
                    ForEach(records.filter { group.categories.contains($0.category) }) { record in usageRow(record) }
                }
            }
            if group == nil {
                Section {
                    PrivacyToggleRow(icon: "clock.badge.xmark", color: .orange,
                        title: LanguageManager.shared.localizedString("privacy_clear_browsing_on_exit"),
                        description: LanguageManager.shared.localizedString("privacy_clear_browsing_on_exit_desc"),
                        isOn: $clearBrowsingOnExit)
                        .accessibilityIdentifier("privacy.clear-browsing-on-exit")
                } header: { Text(LanguageManager.shared.localizedString("privacy_section_data")) }
            }
            if group == nil {
                Section {
                    Text(ToolText.text("storage_auto_cleanup_desc"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("storage.autoCleanup.rules")
                } header: {
                    Text(ToolText.text("storage_auto_cleanup"))
                }
            } else {
                Section {
                    Text(FeatureText.text("Manage saved content in its own list. Active temporary files and system cache databases are released when safe."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(group?.title ?? FeatureText.text("Storage"))
        .modifier(StorageManagementNavigation(onOpenInBrowser: onOpenInBrowser))
        .sheet(isPresented: $bulkCleanup, onDismiss: { Task { await refresh() } }) {
            StorageCleanupView(records: records, choices: cleanupGroup?.cleanupChoices) { StorageUsageService.invalidateInventory() }
                .id(cleanupGroup?.rawValue ?? "all")
        }
        .overlay { if loading || clearing != nil { ProgressView().allowsHitTesting(false) } }
        .onAppear { Task { await refresh() } }
        .refreshable { await refresh() }
        .alert(ToolText.text("done"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done")) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func groupRow(_ group: StorageUsageGroup) -> some View {
        let bytes = records.filter { group.categories.contains($0.category) }.reduce(Int64(0)) { $0 + $1.bytes }
        let route: StorageManagementRoute = group == .websites ? .category(.websiteStorage) : group == .other ? .category(.otherData) : .group(group)
        return HStack(spacing: 8) {
            StorageManagementLink(route: route, onOpenInBrowser: onOpenInBrowser,
                onReturn: { StorageUsageService.invalidateInventory(); Task { await refresh() } }) {
                HStack(spacing: 12) {
                    Image(systemName: group.symbol).foregroundStyle(Color.themePrimary).frame(width: 28)
                    Text(group.title)
                    Spacer(minLength: 8)
                    Text(loading ? "—" : storageSize(bytes)).foregroundStyle(.secondary).monospacedDigit()
                }.frame(minHeight: 48)
            }
            .accessibilityIdentifier("storage.group." + group.rawValue)
            .accessibilityValue(loading ? "" : String(bytes))
            if group == .websites {
                StorageCacheClearButton(title: group.title, identifier: "storage.clear.websites",
                    enabled: !loading && clearing == nil, confirmationTitle: LanguageManager.shared.localizedString("clear_all_data"),
                    confirmationMessage: FeatureText.text("Deleting website data can sign you out and remove offline content.") + "\n\n" + ToolText.text("storage_website_clear_scope")) {
                        clearWebsites()
                    }
            } else if !group.cleanupChoices.isEmpty {
                Button { cleanupGroup = group; bulkCleanup = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                    .buttonStyle(.borderless).accessibilityLabel(LanguageManager.shared.localizedString("privacy_clear_action") + " " + group.title)
                    .accessibilityIdentifier("storage.group.clear." + group.rawValue)
                    .disabled(clearing != nil)
            }
        }
    }
    private func clearWebsites() {
        guard clearing == nil else { return }
        refreshID = UUID()
        clearing = .websiteStorage
        Task {
            notice = await StorageUsageService.clearWebsiteData().notice
            await refresh(); clearing = nil
        }
    }

    private func usageRow(_ record: StorageUsageRecord) -> some View {
        HStack(spacing: 8) {
            if record.category.hasManagementPage {
                managementLink(record)
                    .accessibilityIdentifier("storage.manage." + record.category.rawValue)
                    .accessibilityValue(loading ? "" : String(record.bytes))
            } else { usageLabel(record) }
            if record.canClear {
                StorageCacheClearButton(title: record.category.title,
                    identifier: "storage.clearButton." + record.category.rawValue,
                    enabled: !loading && clearing == nil && record.bytes > 0) {
                        clear(record.category)
                    }
            }
        }
    }

    private func managementLink(_ record: StorageUsageRecord) -> some View {
        StorageManagementLink(route: .category(record.category), onOpenInBrowser: onOpenInBrowser,
            onReturn: { StorageUsageService.invalidateInventory(); Task { await refresh() } }) { usageLabel(record) }
    }
    private func usageLabel(_ record: StorageUsageRecord) -> some View {
        HStack {
            Text(record.category.title)
            Spacer()
            if clearing == record.category { ProgressView() }
            else if loading { Text("—").foregroundStyle(.secondary) }
            else { Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit() }
        }.frame(minHeight: 44).contentShape(Rectangle())
    }
    private func sizeRow(_ title: String, bytes: Int64?) -> some View {
        HStack { Text(title); Spacer(); Text(bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                .foregroundStyle(.secondary).monospacedDigit() }
    }
    private func clear(_ category: StorageUsageCategory) {
        guard clearing == nil else { return }
        clearing = category
        Task {
            do { notice = try await StorageUsageService.clear(category, tabManager: tabManager).notice }
            catch { self.error = error.localizedDescription }
            await refresh()
            clearing = nil
        }
    }
    private func refresh() async {
        let id = UUID(); refreshID = id
        if inventory == nil, let cached = StorageUsageService.cachedInventory {
            inventory = cached; records = cached.records; loading = false
        }
        let result = await StorageUsageService.inventory(forceRefresh: true)
        guard !Task.isCancelled, refreshID == id else { return }
        inventory = result; records = result.records; loading = false
    }
}

private struct StorageManagementNavigation: ViewModifier {
    var onOpenInBrowser: ((URL) -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.navigationDestination(for: StorageManagementRoute.self) { [onOpenInBrowser] route in
                StorageManagementDestination(route: route, onOpenInBrowser: onOpenInBrowser)
            }
        } else { content }
    }
}

/// iOS 16 must not register even an unused value destination on a legacy
/// parent. Every management level gets its own host, matching rule management.
private struct StorageManagementLink<Label: View>: View {
    let route: StorageManagementRoute
    var onOpenInBrowser: ((URL) -> Void)? = nil
    var onReturn: (() -> Void)? = nil
    @ViewBuilder var label: () -> Label
    @State private var legacyRoute: StorageManagementRoute?
    @ViewBuilder var body: some View {
        if #available(iOS 17.0, *) {
            NavigationLink(value: route, label: label)
        } else {
            Button { legacyRoute = route } label: {
                HStack {
                    label().frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .sheet(item: $legacyRoute, onDismiss: { onReturn?() }) { destination in
                NavigationStack {
                    // WKWebExtension data needs the browser callback on 18.4+;
                    // legacy hosts stay independent of the parent's dismissal.
                    StorageManagementDestination(route: destination, onOpenInBrowser: nil)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { StorageManagementDoneButton() } }
                }
            }
        }
    }
}

private struct StorageManagementDoneButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View { Button(ToolText.text("done")) { dismiss() } }
}

private struct StorageManagementDestination: View {
    let route: StorageManagementRoute
    var onOpenInBrowser: ((URL) -> Void)?
    var body: some View {
        switch route {
        case .group(let group): StorageUsageView(group: group, onOpenInBrowser: onOpenInBrowser)
        case .category(let category): categoryPage(category)
        case .site(let entry): WebsiteStorageDetail(entry: entry, onOpenInBrowser: onOpenInBrowser)
        case .readingList: ReadingListView()
        case .files: LibraryFilesView(directory: BookLibrary.directory)
        case .extensions: ExtensionCenterView(onOpenInBrowser: onOpenInBrowser)
        case .privacy: ProtectionSettingsView(initialPage: .privacy)
        case .platforms: PlatformManagementView()
        case .downloadTasks: DownloadManagerView()
        }
    }
    @ViewBuilder private func categoryPage(_ category: StorageUsageCategory) -> some View {
        switch category {
        case .webData, .websiteStorage: WebsiteStorageView(onOpenInBrowser: onOpenInBrowser)
        case .downloads: LibraryFilesView(directory: BookLibrary.directory)
        case .wallpapers: WallpaperSettingsView(showsFavoritesOnly: true)
        case .backups: SettingsBackupsView()
        case .filterRules: ProtectionSettingsView()
        case .readingData: ReadingStorageView(onOpenInBrowser: onOpenInBrowser)
        case .wallpaperCache, .otherCaches, .temporaryFiles, .ruleCache, .extensions, .personalData, .sharedData, .otherData, .downloadTasks:
            AdditionalStorageView(category: category, onOpenInBrowser: onOpenInBrowser)
        case .tabSnapshots, .favicons: EmptyView()
        }
    }
}

private struct ReadingStorageView: View {
    var onOpenInBrowser: ((URL) -> Void)?
    var body: some View {
        List {
            Section {
                StorageManagementLink(route: .readingList, onOpenInBrowser: onOpenInBrowser) { Text(FeatureText.text("Reading list")) }
                StorageManagementLink(route: .files, onOpenInBrowser: onOpenInBrowser) { Text(ToolText.text("files")) }
            } footer: { Text(FeatureText.text("Reading data includes saved article text, the book index, covers and reading progress. Book files are counted under downloaded files.")) }
        }.navigationTitle(FeatureText.text("Reading data"))
    }
}

extension StorageUsageCategory {
    var hasManagementPage: Bool { ![.tabSnapshots, .favicons].contains(self) }
    @MainActor var title: String {
        switch self {
        case .webData: FeatureText.text("Website cache")
        case .websiteStorage: FeatureText.text("Website data")
        case .tabSnapshots: FeatureText.text("Tab previews")
        case .favicons: FeatureText.text("Website icons")
        case .wallpapers: LanguageManager.shared.localizedString("settings_wallpaper")
        case .downloads: FeatureText.text("Downloaded files")
        case .readingData: FeatureText.text("Reading data")
        case .backups: FeatureText.text("Settings backups")
        case .filterRules: FeatureText.text("Filter rules")
        case .extensions: LanguageManager.shared.localizedString("userscripts")
        case .ruleCache: LanguageManager.shared.localizedString("ad_block_subscription_rules")
        case .wallpaperCache: FeatureText.text("Wallpaper cache")
        case .otherCaches: FeatureText.text("Other caches")
        case .temporaryFiles: FeatureText.text("Temporary files")
        case .downloadTasks: FeatureText.text("Download task data")
        case .personalData: FeatureText.text("Settings and records")
        case .sharedData: FeatureText.text("Shared app data")
        case .otherData: FeatureText.text("Other app data")
        }
    }
}

/// Every file outside the bundle remains visible, including unclassified system
/// files. Persistent content is removed through its owner, never by unlinking a
/// live SQLite database or a cloud journal containing deletion tombstones.
private struct AdditionalStorageView: View {
    let category: StorageUsageCategory
    var onOpenInBrowser: ((URL) -> Void)?
    @EnvironmentObject private var tabManager: TabManager
    @State private var entries: [StorageDiskEntry] = []
    @State private var loading = true
    @State private var clearing = false
    @State private var notice: String?
    @State private var error: String?
    @State private var cleanup = false
    var body: some View {
        List {
            Section {
                if category.canClear {
                    StorageCacheClearButton(title: category.title,
                        identifier: "storage.clear." + category.rawValue,
                        textLabel: LanguageManager.shared.localizedString("privacy_clear_action"),
                        enabled: !loading && !clearing && !entries.isEmpty) { clear() }
                }
                if category == .temporaryFiles {
                    StorageCacheClearButton(title: category.title, identifier: "storage.clear.released-temporary",
                        textLabel: ToolText.text("stop") + " · " + LanguageManager.shared.localizedString("privacy_clear_action"), enabled: !loading && !clearing,
                        confirmationMessage: ToolText.text("storage_clear_active_temp_warning")) {
                            clearMedia()
                        }
                }
                if category == .otherData {
                    Button(LanguageManager.shared.localizedString("privacy_clear_action")) { cleanup = true }
                        .accessibilityIdentifier("storage.other.cleanup")
                }
                if category == .extensions {
                    management(.extensions, title: LanguageManager.shared.localizedString("userscripts"))
                }
                if category == .downloadTasks {
                    management(.downloadTasks, title: LanguageManager.shared.localizedString("my_downloads"))
                    management(.files, title: ToolText.text("files"))
                }
                if category == .personalData {
                    management(.privacy, title: LanguageManager.shared.localizedString("settings_privacy"))
                    management(.platforms, title: LanguageManager.shared.localizedString("platform_management"))
                }
            } footer: {
                Text(FeatureText.text("Manage saved content in its own list. Active temporary files and system cache databases are released when safe."))
            }
            Section {
                ForEach(entries) { entry in
                    HStack {
                        Text(entry.displayPath).font(.subheadline).lineLimit(3)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))
                            .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                        if category == .otherData, StorageMediaCleanup.isManagedContainer(entry.url, locations: .current) {
                            StorageCacheClearButton(title: entry.displayPath,
                                identifier: "storage.clear.managed." + entry.url.lastPathComponent,
                                enabled: !loading && !clearing,
                                confirmationTitle: LanguageManager.shared.localizedString("delete"),
                                confirmationMessage: entry.displayPath + "\n\n" + ToolText.text("storage_clear_offline_remnants_warning")) {
                                    clearMedia(container: entry.url)
                                }
                        } else if category == .otherData, StorageOtherCleanup.canClearCache(entry.url, locations: .current) {
                            StorageCacheClearButton(title: entry.displayPath,
                                identifier: "storage.clear.system." + entry.url.lastPathComponent,
                                enabled: !loading && !clearing,
                                confirmationMessage: entry.displayPath + "\n\n" + ToolText.text("storage_system_data_retained")) {
                                    clearSystemCache(entry.url)
                                }
                        }
                    }
                }
                if entries.isEmpty && !loading { Text(LanguageManager.shared.localizedString("no_results")).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $cleanup, onDismiss: { Task { await refresh() } }) {
            StorageCleanupView(records: [], choices: StorageUsageGroup.other.cleanupChoices) {
                StorageUsageService.invalidateInventory()
            }
        }
        .overlay { if loading || clearing { ProgressView().allowsHitTesting(false) } }
        .onAppear { Task { await refresh() } }.refreshable { await refresh() }
        .alert(ToolText.text("done"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done")) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func management(_ route: StorageManagementRoute, title: String) -> some View {
        StorageManagementLink(route: route, onOpenInBrowser: onOpenInBrowser,
            onReturn: { StorageUsageService.invalidateInventory(); Task { await refresh() } }) { Text(title) }
    }
    private func clear() {
        guard !clearing else { return }
        clearing = true
        Task {
            do { notice = try await StorageUsageService.clear(category, tabManager: tabManager).notice }
            catch { self.error = error.localizedDescription }
            await refresh(); clearing = false
        }
    }
    private func clearMedia(container: URL? = nil) {
        guard !clearing else { return }
        clearing = true
        Task {
            do { notice = try await StorageMediaCleanup.clear(container: container, preservingReferencedMedia: container != nil).notice }
            catch { self.error = error.localizedDescription }
            await refresh(); clearing = false
        }
    }
    private func clearSystemCache(_ entry: URL) {
        guard !clearing else { return }
        clearing = true
        Task {
            do { notice = try await StorageOtherCleanup.clearCaches(entry: entry).notice }
            catch { self.error = error.localizedDescription }
            await refresh(); clearing = false
        }
    }
    private func refresh() async {
        let result = await StorageUsageService.inventory(forceRefresh: true)
        guard !Task.isCancelled else { return }
        entries = result.entries.filter { $0.category == category }; loading = false
    }
}

private struct WebsiteStorageView: View {
    var onOpenInBrowser: ((URL) -> Void)?
    @State private var entries: [WebsiteStorageEntry] = []
    @State private var totalBytes: Int64?
    @State private var unattributedBytes: Int64?
    @State private var loading = true
    @State private var clearingExtensions = false
    @State private var refreshID = UUID()
    @State private var error: String?
    @State private var notice: String?
    var body: some View {
        List {
            Section {
                HStack {
                    Text(FeatureText.text("Website data")); Spacer()
                    Text(storageSize(totalBytes)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(FeatureText.text("Website data"))
                .accessibilityValue(totalBytes.map(String.init) ?? "")
                .accessibilityIdentifier("storage.websites.total")
                StorageCacheClearButton(title: FeatureText.text("Website data"), identifier: "storage.websites.clear-all",
                    textLabel: LanguageManager.shared.localizedString("clear_all_data"), enabled: !loading && !clearingExtensions,
                    confirmationTitle: LanguageManager.shared.localizedString("clear_all_data"),
                    confirmationMessage: FeatureText.text("Deleting website data can sign you out and remove offline content.") + "\n\n" + ToolText.text("storage_website_clear_scope")) {
                        refreshID = UUID()
                        clearingExtensions = true
                        Task {
                            notice = await StorageUsageService.clearWebsiteData().notice
                            await refresh(afterCleanup: true); clearingExtensions = false
                        }
                    }
            } footer: { Text(ToolText.text("storage_website_clear_scope")) }
            if #available(iOS 18.4, *) {
                Section {
                    StorageCacheClearButton(title: FeatureText.text("Extension temporary cache"),
                        identifier: "storage.extension-cache",
                        textLabel: FeatureText.text("Extension temporary cache"),
                        enabled: !clearingExtensions) {
                            refreshID = UUID()
                            clearingExtensions = true
                            Task {
                                if #available(iOS 18.4, *) {
                                    do { try await NativeWebExtensionRuntime.shared.clearTemporaryCaches() }
                                    catch { self.error = error.localizedDescription }
                                }
                                StorageUsageService.invalidateInventory()
                                clearingExtensions = false; await refresh()
                            }
                        }
                } footer: { Text(FeatureText.text("Removes temporary extension media data. Keeps settings, scripts, playback progress and downloaded files. Close extension and video pages and finish downloads first.")) }
            }
            ForEach(entries) { entry in
                StorageManagementLink(route: .site(entry), onOpenInBrowser: onOpenInBrowser,
                    onReturn: { StorageUsageService.invalidateInventory(); Task { await refresh() } }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(siteTitle(entry)).lineLimit(1).truncationMode(.middle); Spacer(); Text(storageSize(entry.bytes?.total)).foregroundStyle(.secondary).monospacedDigit().fixedSize() }

                    }
                }.accessibilityIdentifier("storage.site." + entry.domain)
                    .accessibilityValue(entry.bytes.map { String($0.total) } ?? "")
                    .disabled(clearingExtensions)
            }
            if let unattributedBytes, unattributedBytes > 0 {
                Section {
                    HStack {
                        Text(ToolText.text("storage_website_shared")); Spacer()
                        Text(storageSize(unattributedBytes)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(ToolText.text("storage_website_shared"))
                    .accessibilityValue(String(unattributedBytes))
                    .accessibilityIdentifier("storage.websites.shared")
                } footer: { Text(ToolText.text("storage_website_shared_desc")) }
            }
            if entries.isEmpty && !loading && unattributedBytes == 0 {
                CompatibleUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "externaldrive")
            }
        }
        .navigationTitle(FeatureText.text("Website data"))
        .overlay { if loading || clearingExtensions { ProgressView().allowsHitTesting(false) } }
        .task { await refresh() }.refreshable { await refresh() }
        .alert(ToolText.text("done"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done")) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func refresh(afterCleanup: Bool = false) async {
        guard !clearingExtensions || afterCleanup else { return }
        let id = UUID(); refreshID = id
        let updated = await WebsiteStorageService.snapshot { list in
            guard refreshID == id, !list.isEmpty else { return }
            entries = list; loading = false
        }
        guard refreshID == id, !Task.isCancelled else { return }
        entries = updated.entries; totalBytes = updated.totalBytes
        unattributedBytes = updated.unattributedBytes; loading = false
    }
}

private struct WebsiteStorageDetail: View {
    @State var entry: WebsiteStorageEntry
    var onOpenInBrowser: ((URL) -> Void)?
    @State private var requested: Set<String>?
    @State private var clearing = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                LabeledContent(FeatureText.text("Website data"), value: storageSize(entry.bytes?.total))
                if entry.dataTypes.contains(WKWebsiteDataTypeLocalStorage) {
                    LabeledContent("LocalStorage", value: storageSize(entry.bytes?.localStorage))
                }
                LabeledContent(FeatureText.text("Website cache"), value: storageSize(entry.bytes?.cache))
            } footer: { Text(FeatureText.text("Clearing this site's data may sign you out. Sites sharing the same domain can be affected.")) }
            Section {
                Button(LanguageManager.shared.localizedString("privacy_clear_cache")) { requested = WebsiteStorageService.cacheTypes }
                if entry.bytes?.isExtension == true || UUID(uuidString: entry.domain) != nil {
                    StorageManagementLink(route: .extensions, onOpenInBrowser: onOpenInBrowser) { Text(LanguageManager.shared.localizedString("userscripts")) }
                } else {
                    Button(LanguageManager.shared.localizedString("delete"), role: .destructive) { requested = WKWebsiteDataStore.allWebsiteDataTypes() }
                }
            }
        }
        .navigationTitle(siteTitle(entry)).navigationBarTitleDisplayMode(.inline)
        .disabled(clearing)
        .confirmationDialog(LanguageManager.shared.localizedString("delete") + " · " + siteTitle(entry), isPresented: Binding(get: { requested != nil }, set: { if !$0 { requested = nil } }), titleVisibility: .visible) {
            if let types = requested {
                Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                    requested = nil; clearing = true
                    Task {
                        do { try await WebsiteStorageService.clear(entry, types: types) }
                        catch { self.error = error.localizedDescription }
                        let updated = await WebsiteStorageService.entries()
                        entry = updated.first { $0.id == entry.id } ?? .init(domain: entry.domain, dataTypes: [], bytes: .init())
                        clearing = false
                    }
                }
            }
        } message: {
            if requested == WebsiteStorageService.cacheTypes { Text(FeatureText.text("Cache cleanup keeps your downloads, reading progress, backups, history and website logins. Remove saved files from their own lists.")) }
            else { Text(FeatureText.text("Deleting website data can sign you out and remove offline content.")) }
        }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private func storageSize(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
}

@MainActor private func siteTitle(_ entry: WebsiteStorageEntry) -> String {
    if let id = UUID(uuidString: entry.domain), let record = BrowserExtensionService.existingShared?.webExtensions.first(where: { $0.id == id }) { return record.name }
    return entry.domain
}

/// Safe defaults never include saved content. Offline remnants need a tap
/// confirmation; bookmarks and other saved-data batches retain typed approval.
enum StorageCleanupChoice: Hashable, Identifiable, Sendable {
    case cache(StorageUsageCategory)
    case websiteData, downloadedFiles, wallpapers, reading, backups, history, bookmarks, systemCaches, offlineMedia
    static var safeDefaults: Set<Self> {
        Set(StorageUsageCategory.allCases.filter { $0.canClear && ![.tabSnapshots, .favicons].contains($0) }.map(Self.cache))
            .union([.systemCaches])
    }
    static let saved: [Self] = [.history, .offlineMedia, .websiteData, .downloadedFiles, .wallpapers, .reading, .backups, .bookmarks]
    var id: String {
        if case let .cache(category) = self { return category.rawValue }
        return String(describing: self)
    }
    var isSavedData: Bool { if case .cache = self { return false }; return self != .systemCaches }
    var requiresTypedConfirmation: Bool { isSavedData && self != .offlineMedia }
    @MainActor var title: String {
        switch self {
        case .cache(let category): category == .webData ? FeatureText.text("Website cache") : category.title
        case .websiteData: FeatureText.text("Website data")
        case .downloadedFiles: FeatureText.text("Downloaded files")
        case .wallpapers: FeatureText.text("Favorite wallpapers")
        case .reading: FeatureText.text("Reading data")
        case .backups: FeatureText.text("Settings backups")
        case .history: LanguageManager.shared.localizedString("search_history")
        case .bookmarks: LanguageManager.shared.localizedString("bookmarks")
        case .systemCaches: ToolText.text("storage_system_caches")
        case .offlineMedia: ToolText.text("storage_offline_media")
        }
    }
}

private struct StorageCleanupView: View {
    let records: [StorageUsageRecord]
    let choices: [StorageCleanupChoice]?
    var onFinished: () async -> Void
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var searchVM: SearchViewModel
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<StorageCleanupChoice>
    @State private var confirmation = ""
    @State private var confirms = false
    @State private var clearing = false
    @State private var current = ""
    @State private var retainedNotice: String?
    @State private var error: String?
    @State private var estimates: [StorageCleanupChoice: StorageCleanupEstimate] = [:]
    @FocusState private var confirmationFocused: Bool
    init(records: [StorageUsageRecord], choices: [StorageCleanupChoice]? = nil, onFinished: @escaping () async -> Void) {
        self.records = records; self.choices = choices; self.onFinished = onFinished
        let defaults = StorageCleanupChoice.safeDefaults
        _selected = State(initialValue: choices.map { Set($0).intersection(defaults) } ?? defaults)
    }
    private var cacheRecords: [StorageUsageRecord] {
        records.filter { $0.canClear && (choices == nil || choices!.contains(.cache($0.category))) }
    }
    private var savedChoices: [StorageCleanupChoice] { StorageCleanupChoice.saved.filter { choices == nil || choices!.contains($0) } }
    private var selectedChoices: Set<StorageCleanupChoice> {
        let available = choices.map(Set.init) ?? Set(cacheRecords.map { .cache($0.category) } + [.systemCaches] + savedChoices)
        return selected.intersection(available)
    }
    private var requiresTypedConfirmation: Bool { selectedChoices.contains(where: \.requiresTypedConfirmation) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(cacheRecords) { record in
                        choice(.cache(record.category), bytes: record.isEstimated && record.bytes == 0 ? nil : record.bytes,
                            isEstimated: record.isEstimated)
                    }
                    if choices == nil || choices!.contains(.systemCaches) { choice(.systemCaches, bytes: nil) }
                } header: { Text(LanguageManager.shared.localizedString("quick_action_clear_cache")) }
                footer: { Text(FeatureText.text("Cache cleanup keeps your downloads, reading progress, backups, history and website logins. Remove saved files from their own lists.")) }
                Section {
                    ForEach(savedChoices) { item in choice(item, bytes: nil) }
                } header: { Text(LanguageManager.shared.localizedString("privacy_clear_action")) }
                footer: {
                    if selectedChoices.contains(.offlineMedia) { Text(ToolText.text("storage_clear_offline_remnants_warning")) }
                    if selectedChoices.contains(.bookmarks) { Text(LanguageManager.shared.localizedString("privacy_clear_bookmarks_confirm_message")) }
                    if selectedChoices.contains(.bookmarks), UserDefaults.standard.bool(forKey: BookmarkCloudSyncService.enabledKey) {
                        Text(FeatureText.text("This deletion also syncs to your other devices."))
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if requiresTypedConfirmation { typedConfirmation }
            }
            .navigationTitle(FeatureText.text("Storage")).navigationBarTitleDisplayMode(.inline)
            .task(id: records.map { "\($0.bytes):\($0.isEstimated)" }) {
                let result = await StorageCleanupEstimateService.estimates(records: records, context: modelContext)
                guard !Task.isCancelled else { return }
                estimates = result
            }
            .onCompatibleChange(of: requiresTypedConfirmation) { _, needed in
                if !needed { confirmationFocused = false }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("cancel")) { dismiss() }.disabled(clearing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("privacy_clear_action"), role: .destructive) { confirms = true }
                        .disabled(selectedChoices.isEmpty || clearing || (requiresTypedConfirmation && confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "CLEAR"))
                        .accessibilityIdentifier("storage.cleanup.execute")
                }
            }
            .disabled(clearing)
            .overlay { if clearing { ProgressView(current).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog(LanguageManager.shared.localizedString("privacy_clear_action"), isPresented: $confirms, titleVisibility: .visible) {
                Button(LanguageManager.shared.localizedString("privacy_clear_action"), role: .destructive) { Task { await execute() } }
            } message: { Text(selectedChoices.map(\.title).sorted().joined(separator: "、")) }
            .alert(ToolText.text("done"), isPresented: Binding(get: { retainedNotice != nil }, set: { if !$0 { retainedNotice = nil; dismiss() } })) {
                Button(ToolText.text("done")) { retainedNotice = nil; dismiss() }
            } message: { Text(retainedNotice ?? "") }
            .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(ToolText.text("done")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private var typedConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: FeatureText.text("Type %@ to confirm."), "CLEAR"))
                .font(.footnote).foregroundStyle(.secondary)
            TextField("CLEAR", text: $confirmation)
                .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.characters)
                .focused($confirmationFocused).submitLabel(.done).onSubmit { confirmationFocused = false }
                .accessibilityIdentifier("storage.cleanup.confirmation")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
    private func choice(_ item: StorageCleanupChoice, bytes: Int64?, isEstimated: Bool = false) -> some View {
        let value = bytes ?? estimates[item]?.bytes
        let approximate = bytes == nil ? estimates[item]?.isEstimated == true : isEstimated
        let size = value.map { (approximate ? "≈ " : "") + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
        return Button {
            if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
        } label: {
            HStack(spacing: 12) {
                Text(item.title).foregroundStyle(item.isSavedData ? Color.red : Color.primary)
                Spacer(minLength: 8)
                Text(size).font(.subheadline).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                Image(systemName: selected.contains(item) ? "checkmark.circle.fill" : "circle")
                    .font(.title3).foregroundStyle(selected.contains(item) ? Color.themePrimary : Color.secondary)
                    .accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selected.contains(item) ? "1" : "0")
        .accessibilityIdentifier("storage.cleanup.choice." + item.id)
    }
    @MainActor private func execute() async {
        guard !clearing, !requiresTypedConfirmation || confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CLEAR" else { return }
        clearing = true
        let choices = selectedChoices
        var failures: [String] = []
        var report = StorageCleanupReport()
        for item in choices.sorted(by: { $0.id < $1.id }) {
            current = item.title
            do {
                switch item {
                case .cache(let category): report.merge(try await StorageUsageService.clear(category, tabManager: tabManager))
                case .websiteData:
                    report.merge(await StorageUsageService.clearWebsiteData())
                case .systemCaches: report.merge(try await StorageOtherCleanup.clearCaches())
                case .offlineMedia: report.merge(try await StorageOtherCleanup.clearOfflineMedia())
                case .backups: try CloudSyncService.shared.clearBackups()
                case .wallpapers:
                    for wallpaper in WallpaperManager.shared.favorites { WallpaperManager.shared.toggleFavorite(wallpaper) }
                case .reading:
                    let store = ReadingListStore.shared
                    try await store.load(); try await store.remove(ids: Set(store.items.map(\.id)))
                    for book in BookLibrary.shared.books { BookLibrary.shared.remove(book.id) }
                case .history: try SearchHistoryService.clearAll(in: modelContext); searchVM.recentSearches = []
                case .bookmarks: try BookmarkService.clearAll(in: modelContext)
                case .downloadedFiles:
                    guard !DownloadManagerService.shared.downloads.contains(where: { [.inProgress, .paused].contains($0.status) }) else { throw WebExtensionTemporaryCacheError.inUse }
                    guard FileManager.default.fileExists(atPath: BookLibrary.directory.path) else { continue }
                    let files = try FileManager.default.contentsOfDirectory(at: BookLibrary.directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles])
                        .filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false }
                    if let playing = MediaSession.shared.url, LibraryFileActions.contains(playing, in: files) { MediaSession.shared.stop() }
                    try await Task.detached(priority: .utility) { try LibraryFileActions.delete(files, in: BookLibrary.directory) }.value
                    for file in files { DownloadManagerService.shared.didDeleteLocalFile(at: file) }
                    DownloadManagerService.shared.removeMissingFiles()
                }
            } catch { failures.append(item.title + " · " + error.localizedDescription) }
        }
        await onFinished()
        clearing = false
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
        else if let notice = report.notice { retainedNotice = notice }
        else { dismiss() }
    }
}

/// Keep destructive confirmation outside popover layout/lifecycle callbacks.
/// Starting cleanup from onDisappear can overlap a List presentation update.
private struct StorageCacheClearButton: View {
    let title: String
    let identifier: String
    var textLabel: String? = nil
    var enabled = true
    var confirmationTitle: String? = nil
    var confirmationMessage: String? = nil
    let onConfirm: () -> Void
    @State private var confirming = false

    var body: some View {
        Button { confirming = true } label: {
            if let textLabel { Text(textLabel).frame(minHeight: 44) }
            else { Image(systemName: "trash").frame(width: 44, height: 44) }
        }
        .buttonStyle(.borderless).disabled(!enabled)
        .accessibilityLabel(LanguageManager.shared.localizedString("delete") + " " + title)
        .accessibilityIdentifier(identifier)
        .alert(confirmationTitle ?? FeatureText.text("Clear this cache?"), isPresented: $confirming) {
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { }
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                onConfirm()
            }
            .accessibilityIdentifier("storage.confirm.delete")
        } message: { Text(confirmationMessage ?? title) }
    }
}
