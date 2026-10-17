import XCTest
@testable import Soulo

@MainActor
private final class TestCloudSettingsStore: CloudSettingsStore {
    var dictionaryRepresentation: [String: Any] = [:]
    var writes: [String] = []
    var synchronizeResult = true
    func set(_ data: Data, forKey key: String) {
        dictionaryRepresentation[key] = data
        writes.append(key)
    }
    func synchronize() -> Bool { synchronizeResult }
}

@MainActor
final class CloudSyncSafetyTests: XCTestCase {
    private var suites: [String] = []
    private var directories: [URL] = []
    private let early = Date(timeIntervalSince1970: 1_000)
    private let later = Date(timeIntervalSince1970: 2_000)

    override func tearDown() {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private func defaults() -> UserDefaults {
        let suite = "CloudSyncSafety.\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func backupStore() -> CloudSettingsBackupStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncSafety-\(UUID().uuidString)")
        directories.append(url)
        return CloudSettingsBackupStore(directory: url)
    }

    private func service(_ defaults: UserDefaults, cloud: TestCloudSettingsStore,
                         id: String, backups: CloudSettingsBackupStore? = nil) -> CloudSyncService {
        CloudSyncService(defaults: defaults, store: cloud, backups: backups ?? backupStore(),
                         writerID: id, now: { self.later }, reload: {})
    }

    private func platform(_ name: String, id: UUID = UUID()) -> SearchPlatform {
        SearchPlatform(id: id, name: name, iconName: "globe", searchURLTemplate: "https://example.com/?q=%@",
                       homeURL: "https://example.com", region: .international, isBuiltIn: false,
                       isVisible: true, sortOrder: 100, usageCount: 0, isCustom: true)
    }

    private func setPlatforms(_ platforms: [SearchPlatform], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(platforms), forKey: "platform_config")
    }

    private func platforms(in defaults: UserDefaults) throws -> [SearchPlatform] {
        try JSONDecoder().decode([SearchPlatform].self, from: XCTUnwrap(defaults.data(forKey: "platform_config")))
    }

    func testFreshInstallBeforeInitialDownloadDoesNotReplaceLegacyOrDeleteOldData() throws {
        let old = defaults(), fresh = defaults(), cloud = TestCloudSettingsStore()
        let site = platform("My custom search")
        try setPlatforms([site], in: old)
        old.set("My title", forKey: "home_title")
        old.set("light", forKey: "appearance")
        let legacy = try CloudSettingsPayloadCodec.encode(defaults: old, keys: CloudSyncService.syncedKeys, date: early)
        fresh.set("Soulo", forKey: "home_title")
        fresh.set("dark", forKey: "appearance")
        let newService = service(fresh, cloud: cloud, id: "new")
        newService.setEnabled(true)
        newService.flushUpload()
        XCTAssertEqual(cloud.writes, [CloudSyncService.journalPrefix + "new"])
        XCTAssertNil(cloud.dictionaryRepresentation[CloudSyncService.legacyPayloadKey])
        // Simulate iCloud's initial download arriving after the fresh-device write.
        cloud.dictionaryRepresentation[CloudSyncService.legacyPayloadKey] = legacy
        newService.processRemoteChanges()
        XCTAssertEqual(fresh.string(forKey: "home_title"), "My title")
        XCTAssertEqual(fresh.string(forKey: "appearance"), "light")
        XCTAssertEqual(try platforms(in: fresh).map(\.id), [site.id])
        let oldService = service(old, cloud: cloud, id: "old")
        oldService.setEnabled(true)
        XCTAssertEqual(old.string(forKey: "home_title"), "My title")
        XCTAssertEqual(try platforms(in: old).map(\.id), [site.id])
        XCTAssertEqual(cloud.dictionaryRepresentation[CloudSyncService.legacyPayloadKey] as? Data, legacy)
    }

    func testLegacyDefaultSnapshotCannotClearExistingSitesGroupsOrCustomSettings() throws {
        let local = defaults(), empty = defaults(), cloud = TestCloudSettingsStore()
        let site = platform("Kept site"), group = CustomGroup(name: "Kept group")
        try setPlatforms([site], in: local)
        local.set(try JSONEncoder().encode([group]), forKey: "custom_groups")
        local.set("Customized", forKey: "home_title")
        empty.set("Soulo", forKey: "home_title")
        empty.set(try JSONEncoder().encode([SearchPlatform]()), forKey: "platform_config")
        cloud.dictionaryRepresentation[CloudSyncService.legacyPayloadKey] = try CloudSettingsPayloadCodec.encode(
            defaults: empty, keys: CloudSyncService.syncedKeys, date: early)
        let sync = service(local, cloud: cloud, id: "old")
        sync.setEnabled(true)
        XCTAssertEqual(local.string(forKey: "home_title"), "Customized")
        XCTAssertEqual(try platforms(in: local).map(\.id), [site.id])
        XCTAssertEqual(try JSONDecoder().decode([CustomGroup].self, from: XCTUnwrap(local.data(forKey: "custom_groups"))).map(\.id), [group.id])
    }

    func testDifferentSettingsEditedConcurrentlyConvergeWithoutWholeSnapshotReplacement() throws {
        let a = defaults(), b = defaults(), cloud = TestCloudSettingsStore()
        a.set("Soulo", forKey: "home_title"); a.set("dark", forKey: "appearance")
        b.set("Soulo", forKey: "home_title"); b.set("dark", forKey: "appearance")
        let first = service(a, cloud: cloud, id: "a"), second = service(b, cloud: cloud, id: "b")
        first.setEnabled(true); first.flushUpload()
        second.setEnabled(true); second.flushUpload()
        a.set("New title", forKey: "home_title")
        b.set("light", forKey: "appearance")
        first.processLocalChanges(); second.processLocalChanges()
        first.flushUpload(); second.flushUpload()
        first.processRemoteChanges(); second.processRemoteChanges()
        for values in [a, b] {
            XCTAssertEqual(values.string(forKey: "home_title"), "New title")
            XCTAssertEqual(values.string(forKey: "appearance"), "light")
        }
    }

    func testConcurrentSiteAddsMergeAndExplicitDeleteDoesNotResurrectFromLegacy() throws {
        let a = defaults(), b = defaults(), cloud = TestCloudSettingsStore()
        let original = platform("Original"), extraA = platform("Added A"), extraB = platform("Added B")
        try setPlatforms([original], in: a); try setPlatforms([original], in: b)
        cloud.dictionaryRepresentation[CloudSyncService.legacyPayloadKey] = try CloudSettingsPayloadCodec.encode(defaults: a, keys: CloudSyncService.syncedKeys, date: early)
        let first = service(a, cloud: cloud, id: "a"), second = service(b, cloud: cloud, id: "b")
        first.setEnabled(true); first.flushUpload(); second.setEnabled(true); second.flushUpload()
        try setPlatforms([original, extraA], in: a); try setPlatforms([original, extraB], in: b)
        first.processLocalChanges(); second.processLocalChanges(); first.flushUpload(); second.flushUpload()
        first.processRemoteChanges(); second.processRemoteChanges()
        XCTAssertEqual(Set(try platforms(in: a).map(\.id)), Set([original.id, extraA.id, extraB.id]))
        XCTAssertEqual(Set(try platforms(in: b).map(\.id)), Set([original.id, extraA.id, extraB.id]))
        try setPlatforms(try platforms(in: a).filter { $0.id != original.id }, in: a)
        first.processLocalChanges(); first.flushUpload(); second.processRemoteChanges()
        XCTAssertFalse(try platforms(in: b).contains { $0.id == original.id })
        second.processRemoteChanges()
        XCTAssertFalse(try platforms(in: b).contains { $0.id == original.id })
    }

    func testBuiltInIDsAreRemappedForSyncedGroupsWithoutDuplicatingSites() throws {
        let a = defaults(), b = defaults()
        let remote = try XCTUnwrap(PlatformDataStore.defaultPlatforms().first)
        let local = try XCTUnwrap(PlatformDataStore.defaultPlatforms().first)
        XCTAssertNotEqual(remote.id, local.id)
        let group = CustomGroup(name: "Synced group", platformIDs: [remote.id])
        try setPlatforms([remote], in: a); try setPlatforms([local], in: b)
        a.set(try JSONEncoder().encode([group]), forKey: "custom_groups")
        let journals = [try CloudSettingsSyncEngine.seed(CloudSettingsSyncEngine.snapshot(a), writerID: "a", date: early),
                        try CloudSettingsSyncEngine.seed(CloudSettingsSyncEngine.snapshot(b), writerID: "b", date: later)]
        let result = try CloudSettingsSyncEngine.merged(journals, onto: CloudSettingsSyncEngine.snapshot(b))
        let sites = try JSONDecoder().decode([SearchPlatform].self, from: XCTUnwrap(result["platform_config"] as? Data))
        let groups = try JSONDecoder().decode([CustomGroup].self, from: XCTUnwrap(result["custom_groups"] as? Data))
        XCTAssertEqual(sites.map(\.id), [local.id])
        XCTAssertEqual(groups.first?.platformIDs, [local.id])
    }

    func testUsageCountersAndUnrelatedDefaultsDoNotCreateEditsOrUploads() throws {
        let local = defaults(), cloud = TestCloudSettingsStore()
        var site = platform("Original")
        try setPlatforms([site], in: local)
        let sync = service(local, cloud: cloud, id: "a")
        sync.setEnabled(true); sync.flushUpload()
        let initialWrites = cloud.writes.count
        site.usageCount += 1
        try setPlatforms([site], in: local)
        local.set(0.5, forKey: "download_progress")
        sync.processLocalChanges(); sync.flushUpload()
        XCTAssertEqual(cloud.writes.count, initialWrites)
        let journal = try CloudSettingsSyncEngine.decodeJournal(try XCTUnwrap(cloud.dictionaryRepresentation[CloudSyncService.journalPrefix + "a"] as? Data), expectedWriter: "a")
        XCTAssertFalse(journal.records.values.contains(where: \.isExplicit))
    }

    func testFreshFactoryPreferencesNeverBecomeCloudChanges() throws {
        let local = defaults()
        local.set("Soulo", forKey: "home_title")
        local.set("dark", forKey: "appearance")
        local.set(false, forKey: "show_bookmarks_on_home")
        try setPlatforms(PlatformDataStore.defaultPlatforms(), in: local)
        local.set(try JSONEncoder().encode(AdBlockSubscriptionService.defaultSubscriptions()), forKey: "soulo_ad_block_subscriptions")
        let journal = try CloudSettingsSyncEngine.seed(CloudSettingsSyncEngine.snapshot(local), writerID: "fresh", date: later)
        XCTAssertTrue(journal.records.isEmpty)
        XCTAssertFalse(journal.platformAliases.isEmpty)
    }

    func testFoundationBooleanStringPreferencesCanBeBackedUp() throws {
        let local = defaults(), backups = backupStore()
        local.set("NO", forKey: "privacy_https_upgrade_enabled")
        local.set("YES", forKey: "keep_fullscreen_browsing")
        let snapshot = CloudSettingsSyncEngine.snapshot(local)
        XCTAssertEqual(snapshot["privacy_https_upgrade_enabled"] as? Bool, false)
        XCTAssertEqual(snapshot["keep_fullscreen_browsing"] as? Bool, true)
        let backup = try backups.save(snapshot)
        XCTAssertEqual(try backups.values(for: backup)["privacy_https_upgrade_enabled"] as? Bool, false)
    }

    func testSubscriptionCacheUpdatesDoNotUploadAndCustomSubscriptionsMerge() throws {
        let a = defaults(), b = defaults(), cloud = TestCloudSettingsStore()
        var cached = try XCTUnwrap(AdBlockSubscriptionService.defaultSubscriptions().first)
        a.set(try JSONEncoder().encode([cached]), forKey: "soulo_ad_block_subscriptions")
        let first = service(a, cloud: cloud, id: "a"), second = service(b, cloud: cloud, id: "b")
        first.setEnabled(true); first.flushUpload(); second.setEnabled(true); second.flushUpload()
        let initialWrites = cloud.writes.count
        cached.lastUpdatedAt = later; cached.networkRuleCount = 1_234; cached.errorMessage = "local cache status"
        a.set(try JSONEncoder().encode([cached]), forKey: "soulo_ad_block_subscriptions")
        first.processLocalChanges(); first.flushUpload()
        XCTAssertEqual(cloud.writes.count, initialWrites)
        let customA = AdBlockSubscription(id: "custom-a", name: "A", urlString: "https://example.com/a.txt", isEnabled: true,
            lastUpdatedAt: nil, networkRuleCount: 0, cosmeticRuleCount: 0, errorMessage: "")
        let customB = AdBlockSubscription(id: "custom-b", name: "B", urlString: "https://example.com/b.txt", isEnabled: true,
            lastUpdatedAt: nil, networkRuleCount: 0, cosmeticRuleCount: 0, errorMessage: "")
        a.set(try JSONEncoder().encode([cached, customA]), forKey: "soulo_ad_block_subscriptions")
        b.set(try JSONEncoder().encode([customB]), forKey: "soulo_ad_block_subscriptions")
        first.processLocalChanges(); second.processLocalChanges(); first.flushUpload(); second.flushUpload()
        first.processRemoteChanges(); second.processRemoteChanges()
        for local in [a, b] {
            let subscriptions = try JSONDecoder().decode([AdBlockSubscription].self, from: XCTUnwrap(local.data(forKey: "soulo_ad_block_subscriptions")))
            XCTAssertTrue(Set(subscriptions.map(\.id)).isSuperset(of: ["custom-a", "custom-b"]))
        }
        let subscriptions = try JSONDecoder().decode([AdBlockSubscription].self, from: XCTUnwrap(a.data(forKey: "soulo_ad_block_subscriptions")))
        XCTAssertEqual(subscriptions.first { $0.id == cached.id }?.networkRuleCount, 1_234)
    }

    func testGroupAddedAfterSyncStartsRetainsBuiltInReferences() throws {
        let a = defaults(), b = defaults(), cloud = TestCloudSettingsStore()
        let remote = try XCTUnwrap(PlatformDataStore.defaultPlatforms().first)
        let local = try XCTUnwrap(PlatformDataStore.defaultPlatforms().first)
        try setPlatforms([remote], in: a); try setPlatforms([local], in: b)
        let first = service(a, cloud: cloud, id: "a"), second = service(b, cloud: cloud, id: "b")
        first.setEnabled(true); first.flushUpload(); second.setEnabled(true); second.flushUpload()
        a.set(try JSONEncoder().encode([CustomGroup(name: "New group", platformIDs: [remote.id])]), forKey: "custom_groups")
        first.processLocalChanges(); first.flushUpload(); second.processRemoteChanges()
        let groups = try JSONDecoder().decode([CustomGroup].self, from: XCTUnwrap(b.data(forKey: "custom_groups")))
        XCTAssertEqual(groups.first?.platformIDs, [local.id])
    }

    func testRestorePreservesCurrentCopyDisablesSyncAndDoesNotUpload() throws {
        let local = defaults(), cloud = TestCloudSettingsStore(), backups = backupStore()
        local.set("Original", forKey: "home_title")
        let sync = service(local, cloud: cloud, id: "a", backups: backups)
        sync.setEnabled(true); sync.flushUpload()
        let original = try XCTUnwrap(backups.list().first)
        local.set("Changed", forKey: "home_title")
        sync.processLocalChanges(); sync.flushUpload()
        let writes = cloud.writes.count
        try sync.restoreBackup(original)
        XCTAssertEqual(local.string(forKey: "home_title"), "Original")
        XCTAssertFalse(local.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled))
        XCTAssertFalse(sync.isStarted)
        sync.flushUpload(); sync.processRemoteChanges()
        XCTAssertEqual(cloud.writes.count, writes)
        XCTAssertTrue(try backups.list().contains { (try? CloudSettingsSyncEngine.values($0.propertyList)["home_title"] as? String) == "Changed" })
        sync.setEnabled(true); sync.flushUpload()
        XCTAssertEqual(local.string(forKey: "home_title"), "Original")
    }

    func testPinnedPreMigrationBackupSurvivesRotation() throws {
        let backups = backupStore()
        let original = try backups.save(["home_title": "Original"], initial: true, date: early)
        for index in 0..<30 {
            try backups.save(["home_title": "Change \(index)"], date: later.addingTimeInterval(Double(index)))
        }
        let retained = try backups.list()
        XCTAssertEqual(retained.count, 21)
        XCTAssertTrue(retained.contains { $0.id == original.id })
        XCTAssertEqual(try backups.values(for: original)["home_title"] as? String, "Original")
    }

    func testBackupFailurePreventsRemoteOverwriteAndUpload() throws {
        let local = defaults(), cloud = TestCloudSettingsStore()
        local.set("Local", forKey: "home_title")
        let backup = backupStore()
        // A regular file cannot be used as the backup directory.
        try Data("blocked".utf8).write(to: backup.directory)
        let sync = service(local, cloud: cloud, id: "a", backups: backup)
        sync.setEnabled(true); sync.flushUpload(); sync.processRemoteChanges()
        XCTAssertEqual(local.string(forKey: "home_title"), "Local")
        XCTAssertTrue(sync.hasSyncIssue)
        XCTAssertFalse(sync.isStarted)
        XCTAssertTrue(cloud.writes.isEmpty)
    }

    func testCorruptJournalCannotPartiallyApplyOtherSettings() throws {
        let local = defaults(), cloud = TestCloudSettingsStore()
        local.set("Local", forKey: "home_title")
        let sync = service(local, cloud: cloud, id: "a")
        sync.setEnabled(true)
        let good = try CloudSettingsSyncEngine.propertyList(["value": "Remote"])
        let bad = try CloudSettingsSyncEngine.propertyList(["value": "invalid boolean"])
        let remote = CloudSettingsJournal(writerID: "b", records: [
            "setting.home_title": CloudSettingsRecord(value: good, isExplicit: true, modifiedAt: later, sequence: 1),
            "setting.show_bookmarks_on_home": CloudSettingsRecord(value: bad, isExplicit: true, modifiedAt: later, sequence: 2)
        ])
        cloud.dictionaryRepresentation[CloudSyncService.journalPrefix + "b"] = try JSONEncoder().encode(remote)
        sync.processRemoteChanges()
        XCTAssertEqual(local.string(forKey: "home_title"), "Local")
        XCTAssertTrue(sync.hasSyncIssue)
    }

    func testQuotaAndAccountChangeRetainLocalData() throws {
        let local = defaults(), cloud = TestCloudSettingsStore()
        local.set("Local", forKey: "home_title")
        let sync = service(local, cloud: cloud, id: "a")
        sync.setEnabled(true)
        cloud.dictionaryRepresentation["occupied"] = Data(repeating: 1, count: 960_000)
        sync.flushUpload()
        XCTAssertTrue(sync.hasSyncIssue)
        XCTAssertTrue(cloud.writes.isEmpty)
        sync.handleCloudChange(reason: NSUbiquitousKeyValueStoreAccountChange)
        XCTAssertFalse(sync.isStarted)
        XCTAssertFalse(local.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled))
        XCTAssertEqual(local.string(forKey: "home_title"), "Local")
    }

    func testOfflineChangesWhileDisabledSurviveRestartAndReenable() throws {
        let local = defaults(), cloud = TestCloudSettingsStore(), backup = backupStore()
        local.set("Original", forKey: "home_title")
        let first = service(local, cloud: cloud, id: "a", backups: backup)
        first.setEnabled(true); first.flushUpload(); first.setEnabled(false)
        local.set("Offline edit", forKey: "home_title")
        let restarted = service(local, cloud: cloud, id: "a", backups: backup)
        restarted.setEnabled(true); restarted.flushUpload()
        XCTAssertEqual(local.string(forKey: "home_title"), "Offline edit")
        let other = defaults(), receiver = service(other, cloud: cloud, id: "b")
        receiver.setEnabled(true)
        XCTAssertEqual(other.string(forKey: "home_title"), "Offline edit")
    }

    func testDisableCancelsQueuedUpload() async throws {
        let local = defaults(), cloud = TestCloudSettingsStore()
        local.set("Original", forKey: "home_title")
        let sync = service(local, cloud: cloud, id: "a")
        sync.setEnabled(true)
        local.set("Changed", forKey: "home_title")
        sync.processLocalChanges(); sync.setEnabled(false)
        try await Task.sleep(nanoseconds: 900_000_000)
        XCTAssertTrue(cloud.writes.isEmpty)
    }
}
