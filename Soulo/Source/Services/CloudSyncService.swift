import Foundation
import Combine
import UIKit

struct CloudSettingsPayload: Codable {
    let version: Int
    let modifiedAt: Date
    let propertyList: Data
    let missingKeys: [String]
}

enum CloudSettingsPayloadCodec {
    static func encode(
        defaults: UserDefaults,
        keys: [String],
        date: Date = Date()
    ) throws -> Data {
        var values: [String: Any] = [:]
        var missingKeys: [String] = []

        for key in keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missingKeys.append(key)
            }
        }

        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        return try JSONEncoder().encode(
            CloudSettingsPayload(
                version: 2,
                modifiedAt: date,
                propertyList: propertyList,
                missingKeys: missingKeys
            )
        )
    }

    @discardableResult
    static func apply(
        _ data: Data,
        defaults: UserDefaults,
        allowedKeys: Set<String>
    ) throws -> CloudSettingsPayload {
        let payload = try JSONDecoder().decode(CloudSettingsPayload.self, from: data)
        guard payload.version == 2 else {
            throw CocoaError(.coderReadCorrupt)
        }

        guard let values = try PropertyListSerialization.propertyList(
            from: payload.propertyList,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }

        for (key, value) in values where allowedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        // Legacy absence does not prove an intentional deletion. Never let a
        // newly installed or older device use missingKeys to erase local data.
        return payload
    }
}

@MainActor
protocol CloudSettingsStore: AnyObject {
    var dictionaryRepresentation: [String: Any] { get }
    func set(_ data: Data, forKey key: String)
    @discardableResult func synchronize() -> Bool
}

@MainActor
final class UbiquitousCloudSettingsStore: CloudSettingsStore {
    private lazy var store = NSUbiquitousKeyValueStore.default
    var dictionaryRepresentation: [String: Any] { store.dictionaryRepresentation }
    func set(_ data: Data, forKey key: String) { store.set(data, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}

@MainActor
final class CloudSyncService: NSObject, ObservableObject {
    static let shared = CloudSyncService()
    static let journalPrefix = "soulo_settings_v3."
    static let legacyPayloadKey = "soulo_settings_payload_v2"
    private static let localJournalKey = "soulo.settings.local.journal.v3"
    private static let localSnapshotKey = "soulo.settings.local.snapshot.v3"
    private let defaults: UserDefaults
    private let store: any CloudSettingsStore
    private let backups: CloudSettingsBackupStore
    private let writerID: String
    private let reload: (() -> Void)?
    private let now: () -> Date
    private var defaultsObserver: NSObjectProtocol?
    private var remoteObserver: NSObjectProtocol?
    private var pendingUpload: DispatchWorkItem?
    private var uploadGeneration = 0
    private var isApplyingRemote = false
    private var lastObserved: CloudSettingsSyncEngine.Values = [:]
    private var journal: CloudSettingsJournal?
    private(set) var isStarted = false
    @Published private(set) var hasSyncIssue = false
    @Published private(set) var backupRevision = 0

    /// Intentionally excludes history, bookmarks, cache, cookies, downloads,
    /// private-browsing state, tab state, wallpaper images, and usage statistics.
    static let syncedKeys: [String] = [
        "appearance",
        "theme_color",
        "app_language",
        "dynamic_theme",
        "home_title",
        "home_subtitle",
        "show_bookmarks_on_home",
        "show_group_picker_on_home",
        "show_recent_searches_on_home",
        "show_top_search_bar",
        "keep_fullscreen_browsing",
        "web_follows_app_color_scheme",
        "web_warm_color_shift",
        "web_force_dark_pages",
        "web_reduce_page_motion",
        "web_underline_links",
        "browser_shake_action",
        "browser_shake_intensity",
        "browser_toolbar_actions",
        HomeToolbarConfigurationService.storageKey,
        GroupDefaultSearchService.storageKey,
        "browser_toolbar_address_action",
        "ad_block_enabled",
        LiveActivityService.enabledKey,
        "privacy_https_upgrade_enabled",
        "privacy_strip_tracking_parameters",
        "privacy_gpc_enabled",
        "privacy_cookie_banner_enabled",
        "privacy_https_upgrade_excluded_hosts",
        "soulo_privacy_disabled_hosts",
        "soulo_ad_block_allowlisted_hosts",
        "soulo_ad_block_subscriptions",
        "soulo_external_navigation_blocked_hosts",
        "soulo_external_navigation_suppress_prompts",
        ExternalNavigationService.promptEnabledKey,
        "wallpaper_source",
        "wallpaper_gradient_id",
        "wallpaper_solid_color",
        "wallpaper_topic",
        "wallpaper_vibe_tags",
        "wallpaper_refresh_interval",
        "wallpaper_auto_random_sources",
        "wallpaper_auto_sources",
        "wallpaper_auto_random_topics",
        "wallpaper_only_favorites",
        "last_selected_region",
        "last_selected_group_id",
        "platform_config",
        "custom_groups",
        "region_name_overrides"
    ]

    init(defaults: UserDefaults = .standard,
         store: (any CloudSettingsStore)? = nil,
         backups: CloudSettingsBackupStore? = nil,
         writerID: String? = nil, now: @escaping () -> Date = Date.init,
         reload: (() -> Void)? = nil) {
        self.defaults = defaults
        self.store = store ?? UbiquitousCloudSettingsStore()
        self.backups = backups ?? CloudSettingsBackupStore()
        self.now = now
        self.reload = reload
        // Backups may clone UserDefaults onto another device. Include the
        // device's vendor identifier so two installations never share a writer.
        let identityKey = "soulo.settings.installation.id"
        let installation = defaults.string(forKey: identityKey) ?? UUID().uuidString
        defaults.set(installation, forKey: identityKey)
        self.writerID = writerID ?? installation + "." + (UIDevice.current.identifierForVendor?.uuidString ?? "local")
        super.init()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.processLocalChanges() }
        }
        // Starting later avoids re-entering ThemeManager during singleton init.
    }

    private var isEnabled: Bool { defaults.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled) }

    func startIfEnabled() {
        guard isEnabled, !isStarted else { return }
        do {
            lastObserved = CloudSettingsSyncEngine.snapshot(defaults)
            try backups.save(lastObserved, initial: true, date: now())
            try backups.save(lastObserved, date: now())
            if let data = defaults.data(forKey: Self.localJournalKey) {
                let saved = try JSONDecoder().decode(CloudSettingsJournal.self, from: data)
                if saved.writerID == writerID {
                    journal = try CloudSettingsSyncEngine.decodeJournal(data, expectedWriter: writerID)
                    if let snapshot = defaults.data(forKey: Self.localSnapshotKey), var next = journal {
                        let before = try CloudSettingsSyncEngine.values(snapshot)
                        if try CloudSettingsSyncEngine.recordEdits(from: before, to: lastObserved, in: &next, date: now()) {
                            try self.backups.save(before, date: now())
                            journal = next
                        }
                    }
                } else {
                    journal = try CloudSettingsSyncEngine.seed(lastObserved, writerID: writerID, date: now())
                }
            } else {
                journal = try CloudSettingsSyncEngine.seed(lastObserved, writerID: writerID, date: now())
            }
            isStarted = true
            remoteObserver = NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil, queue: .main
            ) { [weak self] notification in
                let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
                Task { @MainActor in
                    guard let self, self.isEnabled, self.isStarted else { return }
                    self.handleCloudChange(reason: reason)
                }
            }
            store.synchronize()
            processRemoteChanges()
            scheduleUpload()
            backupRevision += 1
        } catch { hasSyncIssue = true }
    }

    func setEnabled(_ enabled: Bool) {
        if isEnabled != enabled { defaults.set(enabled, forKey: AppConstants.StorageKeys.iCloudSyncEnabled) }
        if enabled { startIfEnabled() }
        else {
            cancelUpload()
            isStarted = false
            if let remoteObserver { NotificationCenter.default.removeObserver(remoteObserver) }
            remoteObserver = nil
        }
    }

    func handleCloudChange(reason: Int?) {
        guard isEnabled, isStarted else { return }
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            setEnabled(false)
            hasSyncIssue = true
        } else if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            hasSyncIssue = true
        } else { processRemoteChanges() }
    }

    /// Diff against the last applied snapshot, not a complete fresh payload.
    /// Defaults notifications for downloads, usage counts and remote reloads do
    /// not become user edits and cannot re-publish another device's data.
    func processLocalChanges() {
        guard isEnabled, isStarted, !isApplyingRemote, var journal else { return }
        let current = CloudSettingsSyncEngine.snapshot(defaults)
        do {
            guard try CloudSettingsSyncEngine.recordEdits(from: lastObserved, to: current, in: &journal, date: now()) else {
                lastObserved = current
                return
            }
            try backups.save(lastObserved, date: now())
            self.journal = journal
            lastObserved = current
            try persistJournal()
            backupRevision += 1
            scheduleUpload()
        } catch { hasSyncIssue = true }
    }

    func processRemoteChanges() {
        guard isEnabled, isStarted, !isApplyingRemote else { return }
        processLocalChanges()
        guard CloudSettingsSyncEngine.equal(lastObserved, CloudSettingsSyncEngine.snapshot(defaults)) else { return }
        guard let journal else { return }
        do {
            var journals = [journal]
            let cloud = store.dictionaryRepresentation
            if let data = cloud[Self.legacyPayloadKey] as? Data {
                let payload = try JSONDecoder().decode(CloudSettingsPayload.self, from: data)
                guard payload.version == 2 else { throw CocoaError(.coderReadCorrupt) }
                let legacy = try CloudSettingsSyncEngine.values(payload.propertyList)
                    .filter { Self.syncedKeys.contains($0.key) }
                // Old snapshots are import baselines only. Their missingKeys
                // cannot delete anything, and they never outrank explicit v3 edits.
                journals.append(try CloudSettingsSyncEngine.seed(legacy, writerID: "legacy", date: payload.modifiedAt))
            }
            for (key, value) in cloud where key.hasPrefix(Self.journalPrefix) {
                guard let data = value as? Data else { throw CocoaError(.coderReadCorrupt) }
                journals.append(try CloudSettingsSyncEngine.decodeJournal(data, expectedWriter: String(key.dropFirst(Self.journalPrefix.count))))
            }
            let local = CloudSettingsSyncEngine.snapshot(defaults)
            let merged = try CloudSettingsSyncEngine.merged(journals, onto: local)
            guard !CloudSettingsSyncEngine.equal(local, merged) else { return }
            // Fail closed: a disk/backup error must not discard the only good copy.
            try backups.save(local, date: now())
            isApplyingRemote = true
            defer { isApplyingRemote = false }
            CloudSettingsSyncEngine.write(merged, to: defaults)
            if let reload { reload() } else { reloadRuntimeSettings() }
            lastObserved = CloudSettingsSyncEngine.snapshot(defaults)
            try persistJournal()
            backupRevision += 1
        } catch { hasSyncIssue = true }
    }

    func refresh() {
        guard isEnabled else { return }
        startIfEnabled()
        store.synchronize()
        processRemoteChanges()
        flushUpload()
    }

    func listBackups() throws -> [CloudSettingsBackup] { try backups.list() }

    func saveBackup() throws {
        try backups.save(CloudSettingsSyncEngine.snapshot(defaults), date: now())
        backupRevision += 1
    }

    func restoreBackup(_ backup: CloudSettingsBackup) throws {
        let restored = try backups.values(for: backup)
        let local = CloudSettingsSyncEngine.snapshot(defaults)
        try backups.save(local, date: now())
        var next: CloudSettingsJournal
        if let journal { next = journal }
        else { next = try CloudSettingsSyncEngine.seed(local, writerID: writerID, date: now()) }
        _ = try CloudSettingsSyncEngine.recordEdits(from: local, to: restored, in: &next, date: now())
        let data = try CloudSettingsSyncEngine.encodeJournal(next)
        setEnabled(false)
        defaults.set(false, forKey: AppConstants.StorageKeys.iCloudSyncEnabled)
        defaults.set(data, forKey: Self.localJournalKey)
        journal = next
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        CloudSettingsSyncEngine.write(restored, to: defaults)
        if let reload { reload() } else { reloadRuntimeSettings() }
        lastObserved = CloudSettingsSyncEngine.snapshot(defaults)
        try persistJournal()
        backupRevision += 1
        hasSyncIssue = false
    }

    private func persistJournal() throws {
        if let journal { defaults.set(try CloudSettingsSyncEngine.encodeJournal(journal), forKey: Self.localJournalKey) }
        defaults.set(try CloudSettingsSyncEngine.propertyList(lastObserved), forKey: Self.localSnapshotKey)
    }

    private func cancelUpload() {
        uploadGeneration += 1
        pendingUpload?.cancel()
        pendingUpload = nil
    }

    private func scheduleUpload() {
        cancelUpload()
        let generation = uploadGeneration
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, self.uploadGeneration == generation else { return }
                self.flushUpload()
            }
        }
        pendingUpload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func flushUpload() {
        cancelUpload()
        guard isEnabled, isStarted, !isApplyingRemote, let journal else { return }
        do {
            let data = try CloudSettingsSyncEngine.encodeJournal(journal)
            let key = Self.journalPrefix + writerID
            let cloud = store.dictionaryRepresentation
            if (cloud[key] as? Data) == data { return }
            let total = cloud.filter { $0.key != key }.values.reduce(0) { sum, value in
                sum + ((value as? Data)?.count ?? (try? PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0).count) ?? 0)
            }
            guard total + data.count < 950_000 else { hasSyncIssue = true; return }
            try persistJournal()
            store.set(data, forKey: key)
            hasSyncIssue = !store.synchronize()
        } catch { hasSyncIssue = true }
    }

    private func reloadRuntimeSettings() {
        let appearance = defaults.string(forKey: AppConstants.StorageKeys.appearance) ?? "system"
        ThemeManager.shared.setAppearance(appearance)

        if let language = defaults.string(forKey: AppConstants.StorageKeys.selectedLanguage) {
            let canonicalLanguage = AppConstants.canonicalLanguageCode(language)
            if canonicalLanguage != language {
                defaults.set(canonicalLanguage, forKey: AppConstants.StorageKeys.selectedLanguage)
            }
            LanguageManager.shared.setLanguage(canonicalLanguage)
        }

        WebAppearanceService.shared.refreshFromDefaults()
        PlatformDataStore.shared.reloadFromDefaults()
        WallpaperManager.shared.reloadPreferencesFromDefaults()
        AdBlockSettingsService.shared.reloadFromDefaults()
        PrivacyProtectionService.shared.reloadFromDefaults()
        ExternalNavigationService.shared.reloadFromDefaults()
        AdBlockSubscriptionService.shared.reloadFromDefaults()
        BrowserToolbarConfigurationService.shared.reloadFromDefaults()
        HomeToolbarConfigurationService.shared.reloadFromDefaults()
        GroupDefaultSearchService.shared.reloadFromDefaults()

        let liveActivityEnabled = defaults.object(forKey: LiveActivityService.enabledKey) as? Bool ?? true
        LiveActivityService.shared.setEnabled(liveActivityEnabled)
    }
}
