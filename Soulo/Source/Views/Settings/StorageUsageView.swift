import SwiftUI
import WebKit

private enum StorageManagementRoute: Hashable, Identifiable {
    case category(StorageUsageCategory)
    case site(WebsiteStorageEntry)
    case readingList, files, extensions, privacy, platforms, documents, downloadTasks
    var id: Self { self }
}

struct StorageUsageView: View {
    var onOpenInBrowser: ((URL) -> Void)? = nil
    @EnvironmentObject private var tabManager: TabManager
    // Navigation must remain available while WebKit and disk estimates load.
    // Unknown sizes use a dash rather than presenting an empty, inert page.
    @State private var records = StorageUsageCategory.allCases.map {
        StorageUsageRecord(category: $0, bytes: 0, isEstimated: true)
    }
    @State private var inventory: StorageUsageInventory?
    @State private var clearing: StorageUsageCategory?
    @State private var requested: StorageUsageCategory?
    @State private var error: String?
    @State private var loading = true
    @State private var bulkCleanup = false

    var body: some View {
        List {
            Section {
                sizeRow(FeatureText.text("App size"), bytes: inventory?.appBytes)
                HStack(spacing: 8) {
                    sizeRow(FeatureText.text("App data"), bytes: inventory?.dataBytes)
                    Button { bulkCleanup = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                        .buttonStyle(.borderless).accessibilityLabel(LanguageManager.shared.localizedString("privacy_clear_action"))
                        .accessibilityIdentifier("storage.cleanup")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(FeatureText.text("App size is the installed program and resources, not the App Store download size."))
                    Text(FeatureText.text("App data is the total of the categories below."))
                }
            }
            Section {
                Text(FeatureText.text("Cache cleanup keeps your downloads, reading progress, backups, history and website logins. Remove saved files from their own lists."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section(LanguageManager.shared.localizedString("quick_action_clear_cache")) {
                ForEach(records.filter(\.canClear)) { record in usageRow(record) }
            }
            Section(LanguageManager.shared.localizedString("extension_manage")) {
                ForEach(records.filter { !$0.canClear }) { record in usageRow(record) }
            }
            Section { Text(FeatureText.text("Manage saved content in its own list. Active temporary files and system cache databases are released when safe."))
                .font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(FeatureText.text("Storage"))
        .modifier(StorageManagementNavigation(onOpenInBrowser: onOpenInBrowser))
        .sheet(isPresented: $bulkCleanup, onDismiss: { Task { await refresh() } }) {
            StorageCleanupView(records: records) { await refresh() }
        }
        .overlay { if loading { ProgressView().allowsHitTesting(false) } }
        .disabled(clearing != nil)
        .task { await AdBlockSubscriptionService.shared.compactArchivesIfNeeded(); await refresh() }
        .refreshable { await AdBlockSubscriptionService.shared.compactArchivesIfNeeded(); await refresh() }
        .confirmationDialog(FeatureText.text("Clear this cache?"), isPresented: Binding(get: { requested != nil }, set: { if !$0 { requested = nil } }), presenting: requested) { category in
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                requested = nil; clearing = category
                Task {
                    do { try await StorageUsageService.clear(category, tabManager: tabManager) }
                    catch { self.error = error.localizedDescription }
                    clearing = nil; await refresh()
                }
            }
        } message: { category in Text(category.title) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func usageRow(_ record: StorageUsageRecord) -> some View {
        HStack(spacing: 8) {
            if record.category.hasManagementPage {
                managementLink(record)
                    .accessibilityIdentifier("storage.manage." + record.category.rawValue)
            } else { usageLabel(record) }
            if record.canClear {
                Button { requested = record.category } label: {
                    Image(systemName: "trash").frame(width: 44, height: 44)
                }
                .disabled(loading).buttonStyle(.borderless)
                .accessibilityIdentifier("storage.clearButton." + record.category.rawValue)
                .accessibilityLabel(LanguageManager.shared.localizedString("delete") + " " + record.category.title)
            }
        }
    }

    private func managementLink(_ record: StorageUsageRecord) -> some View {
        StorageManagementLink(route: .category(record.category), onOpenInBrowser: onOpenInBrowser) { usageLabel(record) }
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
    private func refresh() async {
        let result = await StorageUsageService.inventory()
        guard !Task.isCancelled else { return }
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
            .sheet(item: $legacyRoute) { destination in
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
        case .category(let category): categoryPage(category)
        case .site(let entry): WebsiteStorageDetail(entry: entry, onOpenInBrowser: onOpenInBrowser)
        case .readingList: ReadingListView()
        case .files: LibraryFilesView(directory: BookLibrary.directory)
        case .extensions: ExtensionCenterView(onOpenInBrowser: onOpenInBrowser)
        case .privacy: PrivacySettingsView()
        case .platforms: PlatformManagementView()
        case .documents: LibraryFilesView(directory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
        case .downloadTasks: DownloadManagerView()
        }
    }
    @ViewBuilder private func categoryPage(_ category: StorageUsageCategory) -> some View {
        switch category {
        case .webData: WebsiteStorageView(onOpenInBrowser: onOpenInBrowser)
        case .downloads: LibraryFilesView(directory: BookLibrary.directory)
        case .wallpapers: WallpaperSettingsView(showsFavoritesOnly: true)
        case .backups: SettingsBackupsView()
        case .filterRules: AdBlockManagementView(currentHost: nil)
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
        case .webData: FeatureText.text("Website data")
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
    @State private var confirming = false
    @State private var clearing = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                if category.canClear {
                    Button(LanguageManager.shared.localizedString("privacy_clear_action"), role: .destructive) { confirming = true }
                        .disabled(loading || clearing)
                        .accessibilityIdentifier("storage.clear." + category.rawValue)
                }
                if category == .extensions {
                    management(.extensions, title: LanguageManager.shared.localizedString("userscripts"))
                }
                if category == .downloadTasks {
                    management(.downloadTasks, title: LanguageManager.shared.localizedString("my_downloads"))
                    management(.files, title: ToolText.text("files"))
                }
                if [.personalData, .otherData].contains(category) {
                    management(.privacy, title: LanguageManager.shared.localizedString("settings_privacy"))
                    management(.platforms, title: LanguageManager.shared.localizedString("platform_management"))
                    management(.documents, title: ToolText.text("files"))
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
                    }
                }
                if entries.isEmpty && !loading { Text(LanguageManager.shared.localizedString("no_results")).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
        .overlay { if loading || clearing { ProgressView().allowsHitTesting(false) } }
        .task { await refresh() }.refreshable { await refresh() }
        .confirmationDialog(FeatureText.text("Clear this cache?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                clearing = true
                Task {
                    do { try await StorageUsageService.clear(category, tabManager: tabManager) }
                    catch { self.error = error.localizedDescription }
                    clearing = false; await refresh()
                }
            }
        } message: { Text(category.title) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func management(_ route: StorageManagementRoute, title: String) -> some View {
        StorageManagementLink(route: route, onOpenInBrowser: onOpenInBrowser) { Text(title) }
    }
    private func refresh() async {
        let result = await StorageUsageService.inventory()
        guard !Task.isCancelled else { return }
        entries = result.entries.filter { $0.category == category }; loading = false
    }
}

private struct WebsiteStorageView: View {
    var onOpenInBrowser: ((URL) -> Void)?
    @State private var entries: [WebsiteStorageEntry] = []
    @State private var loading = true
    @State private var clearingExtensions = false
    @State private var confirmExtensions = false
    @State private var error: String?
    private var databaseTotal: Int64? {
        guard entries.allSatisfy({ $0.indexedDBBytes != nil }) else { return nil }
        return entries.compactMap(\.indexedDBBytes).reduce(0, +)
    }
    var body: some View {
        List {
            Section {
                HStack { Text("IndexedDB"); Spacer(); Text(storageSize(databaseTotal)).monospacedDigit().foregroundStyle(.secondary) }
            } footer: { Text(FeatureText.text("Website data size is estimated. IndexedDB includes database files and media blobs. Unavailable sizes appear as —.")) }
            if #available(iOS 18.4, *) {
                Section {
                    Button { confirmExtensions = true } label: {
                        HStack {
                            Text(FeatureText.text("Extension temporary cache"))
                            Spacer()
                            if clearingExtensions { ProgressView() } else { Image(systemName: "trash") }
                        }
                    }.disabled(clearingExtensions)
                    .accessibilityIdentifier("storage.extension-cache")
                } footer: { Text(FeatureText.text("Removes temporary extension media data. Keeps settings, scripts, playback progress and downloaded files. Close extension and video pages and finish downloads first.")) }
            }
            ForEach(entries) { entry in
                StorageManagementLink(route: .site(entry), onOpenInBrowser: onOpenInBrowser) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(siteTitle(entry)).lineLimit(1).truncationMode(.middle); Spacer(); Text(storageSize(entry.bytes?.total)).foregroundStyle(.secondary).monospacedDigit().fixedSize() }
                        if entry.dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) {
                            Text("IndexedDB · " + storageSize(entry.indexedDBBytes)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.accessibilityIdentifier("storage.site." + entry.domain)
            }
            if entries.isEmpty && !loading {
                CompatibleUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "externaldrive")
            }
        }
        .navigationTitle(FeatureText.text("Website data"))
        .overlay { if loading { ProgressView() } }
        .task { await refresh() }.refreshable { await refresh() }
        .confirmationDialog(FeatureText.text("Clear this cache?"), isPresented: $confirmExtensions, titleVisibility: .visible) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                clearingExtensions = true
                Task {
                    if #available(iOS 18.4, *) {
                        do { try await NativeWebExtensionRuntime.shared.clearTemporaryCaches() }
                        catch { self.error = error.localizedDescription }
                    }
                    clearingExtensions = false; await refresh()
                }
            }
        } message: { Text(FeatureText.text("Removes temporary extension media data. Keeps settings, scripts, playback progress and downloaded files. Close extension and video pages and finish downloads first.")) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func refresh() async { entries = await WebsiteStorageService.entries(); loading = false }
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
                LabeledContent("IndexedDB", value: storageSize(entry.indexedDBBytes))
                if entry.dataTypes.contains(WKWebsiteDataTypeLocalStorage) {
                    LabeledContent("LocalStorage", value: storageSize(entry.bytes?.localStorage))
                }
                LabeledContent(FeatureText.text("Website cache"), value: storageSize(entry.bytes?.cache))
            } footer: { Text(FeatureText.text("Website data size is estimated. IndexedDB includes database files and media blobs. Unavailable sizes appear as —.")) }
            Section {
                Button(LanguageManager.shared.localizedString("privacy_clear_cache")) { requested = WebsiteStorageService.cacheTypes }
                if entry.bytes?.isExtension == true || UUID(uuidString: entry.domain) != nil {
                    StorageManagementLink(route: .extensions, onOpenInBrowser: onOpenInBrowser) { Text(LanguageManager.shared.localizedString("userscripts")) }
                } else {
                    if entry.dataTypes.contains(WKWebsiteDataTypeIndexedDBDatabases) {
                        Button(role: .destructive) { requested = [WKWebsiteDataTypeIndexedDBDatabases] } label: {
                            Text(LanguageManager.shared.localizedString("delete") + " IndexedDB")
                        }
                    }
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
    if let id = UUID(uuidString: entry.domain), let record = BrowserExtensionService.shared.webExtensions.first(where: { $0.id == id }) { return record.name }
    return entry.domain
}

/// Safe defaults never include saved content. Every saved-data batch requires
/// typed confirmation, preserving the bookmark/cloud deletion contract.
enum StorageCleanupChoice: Hashable, Identifiable {
    case cache(StorageUsageCategory)
    case websiteData, downloadedFiles, wallpapers, reading, backups, history, bookmarks
    static var safeDefaults: Set<Self> { Set(StorageUsageCategory.allCases.filter(\.canClear).map(Self.cache)) }
    static let saved: [Self] = [.websiteData, .downloadedFiles, .wallpapers, .reading, .backups, .history, .bookmarks]
    var id: String {
        if case let .cache(category) = self { return category.rawValue }
        return String(describing: self)
    }
    var isSavedData: Bool { if case .cache = self { return false }; return true }
    @MainActor var title: String {
        switch self {
        case .cache(let category): category == .webData ? FeatureText.text("Website cache") : category.title
        case .websiteData: FeatureText.text("Website data") + " · " + LanguageManager.shared.localizedString("clear_all_data")
        case .downloadedFiles: FeatureText.text("Downloaded files")
        case .wallpapers: LanguageManager.shared.localizedString("wallpaper_favorites")
        case .reading: FeatureText.text("Reading data")
        case .backups: FeatureText.text("Settings backups")
        case .history: LanguageManager.shared.localizedString("privacy_clear_history")
        case .bookmarks: LanguageManager.shared.localizedString("privacy_clear_bookmarks")
        }
    }
}

private struct StorageCleanupView: View {
    let records: [StorageUsageRecord]
    var onFinished: () async -> Void
    @EnvironmentObject private var tabManager: TabManager
    @EnvironmentObject private var searchVM: SearchViewModel
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var selected = StorageCleanupChoice.safeDefaults
    @State private var confirmation = ""
    @State private var confirms = false
    @State private var clearing = false
    @State private var current = ""
    @State private var error: String?
    private var includesSavedData: Bool { selected.contains(where: \.isSavedData) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(records.filter(\.canClear)) { record in choice(.cache(record.category), bytes: record.bytes) }
                } header: { Text(LanguageManager.shared.localizedString("quick_action_clear_cache")) }
                footer: { Text(FeatureText.text("Cache cleanup keeps your downloads, reading progress, backups, history and website logins. Remove saved files from their own lists.")) }
                Section {
                    ForEach(StorageCleanupChoice.saved) { item in choice(item, bytes: nil) }
                } header: { Text(LanguageManager.shared.localizedString("privacy_clear_action")) }
                footer: {
                    if selected.contains(.bookmarks) { Text(LanguageManager.shared.localizedString("privacy_clear_bookmarks_confirm_message")) }
                    if selected.contains(.bookmarks), UserDefaults.standard.bool(forKey: BookmarkCloudSyncService.enabledKey) {
                        Text(FeatureText.text("This deletion also syncs to your other devices."))
                    }
                }
                if includesSavedData {
                    Section {
                        Text(String(format: FeatureText.text("Type %@ to confirm."), "CLEAR"))
                        TextField("CLEAR", text: $confirmation).autocorrectionDisabled().textInputAutocapitalization(.characters)
                            .accessibilityIdentifier("storage.cleanup.confirmation")
                    }
                }
            }
            .navigationTitle(FeatureText.text("Storage")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("cancel")) { dismiss() }.disabled(clearing) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("privacy_clear_action"), role: .destructive) { confirms = true }
                        .disabled(selected.isEmpty || clearing || (includesSavedData && confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != "CLEAR"))
                        .accessibilityIdentifier("storage.cleanup.execute")
                }
            }
            .disabled(clearing)
            .overlay { if clearing { ProgressView(current).padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .confirmationDialog(LanguageManager.shared.localizedString("privacy_clear_action"), isPresented: $confirms, titleVisibility: .visible) {
                Button(LanguageManager.shared.localizedString("privacy_clear_action"), role: .destructive) { Task { await execute() } }
            } message: { Text(selected.map(\.title).sorted().joined(separator: "、")) }
            .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(ToolText.text("done")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private func choice(_ item: StorageCleanupChoice, bytes: Int64?) -> some View {
        Button {
            if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
        } label: {
            HStack(spacing: 12) {
                Text(item.title).foregroundStyle(item.isSavedData ? Color.red : Color.primary)
                Spacer(minLength: 8)
                if let bytes { Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
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
        guard !clearing, !includesSavedData || confirmation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "CLEAR" else { return }
        clearing = true
        let choices = selected
        var failures: [String] = []
        for item in choices.sorted(by: { $0.id < $1.id }) {
            current = item.title
            do {
                switch item {
                case .cache(let category): try await StorageUsageService.clear(category, tabManager: tabManager)
                case .websiteData:
                    let store = WKWebsiteDataStore.default()
                    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { c.resume() }
                    }
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
        if failures.isEmpty { dismiss() } else { error = failures.joined(separator: "\n") }
    }
}
