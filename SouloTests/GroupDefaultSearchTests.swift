import XCTest
@testable import Soulo

@MainActor
final class GroupDefaultSearchTests: XCTestCase {
    func testWebPlayerTakeoverIsOptInAndIncludedInSettingsSync() throws {
        let suite = "VideoTakeover." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(VideoPlaybackPreferences.takesOverWebPlayers(in: defaults))
        defaults.set(true, forKey: VideoPlaybackPreferences.takesOverWebPlayersKey)
        XCTAssertTrue(VideoPlaybackPreferences.takesOverWebPlayers(in: defaults))
        XCTAssertTrue(CloudSyncService.syncedKeys.contains(VideoPlaybackPreferences.takesOverWebPlayersKey))
        let values = CloudSettingsSyncEngine.snapshot(defaults)
        XCTAssertEqual(values[VideoPlaybackPreferences.takesOverWebPlayersKey] as? Bool, true)
        defaults.set(false, forKey: VideoPlaybackPreferences.takesOverWebPlayersKey)
        XCTAssertFalse(VideoPlaybackPreferences.takesOverWebPlayers(in: defaults))
    }

    func testPlatformAIExportRoundTripsAllLinksAndReplacementBacksUpBeforeWriting() throws {
        let store = PlatformDataStore.shared
        let original = (store.platforms, store.customGroups, store.regionNameOverrides)
        defer {
            store.platforms = original.0; store.customGroups = original.1; store.regionNameOverrides = original.2
            store.savePlatforms(); store.saveGroups(); store.saveRegionNames()
        }
        store.platforms = PlatformDataStore.defaultPlatforms()
        store.platforms[0].isVisible = false
        let a = store.platforms[0], b = store.platforms[1]
        let group = CustomGroup(name: "Export group", platformIDs: [b.id, a.id])
        store.customGroups = [group]; store.savePlatforms(); store.saveGroups()
        let data = try store.exportPlatformLinks()
        let document = try PlatformImportDocument.parse(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(document.rejectedPlatforms, 0)
        let roundTrip = try store.replacementPlan(document)
        XCTAssertEqual(Set(roundTrip.platforms.map(\.id)), Set(store.platforms.map(\.id)), "Every existing link survives export and parse")
        XCTAssertEqual(roundTrip.platforms.first { $0.id == a.id }?.isVisible, false)
        XCTAssertEqual(roundTrip.groups.first?.id, group.id)
        XCTAssertEqual(roundTrip.groups.first?.platformIDs, [b.id, a.id])
        let appended = store.applyImport(document, groupName: nil)
        XCTAssertEqual(appended.addedPlatforms, 0)
        XCTAssertEqual(store.customGroups.count, 1, "Regional export entries must not create duplicate custom groups")
        let object: [String: Any] = ["groups": [["id": group.id.uuidString, "name": "Reorganized", "platforms": [
            ["name": b.name, "url": b.searchURLTemplate, "id": b.id.uuidString],
            ["name": "New link", "url": "https://new.example/search?q=%@"]]]]]
        let source = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        let replacement = try PlatformImportDocument.parse(source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backups = CloudSettingsBackupStore(directory: directory)
        let before = CloudSettingsSyncEngine.snapshot(.standard)
        let peer = try CloudSettingsSyncEngine.seed(before, writerID: "peer", date: Date(timeIntervalSince1970: 1))
        var local = try CloudSettingsSyncEngine.seed(before, writerID: "local", date: Date(timeIntervalSince1970: 1))
        let result = try store.replacePlatforms(replacement, backupStore: backups)
        XCTAssertTrue(result.hasChanges); XCTAssertEqual(store.platforms.count, 2)
        XCTAssertEqual(store.platforms.first?.id, b.id, "Regrouping preserves matching identities and icons")
        XCTAssertEqual(store.platforms.first?.iconName, b.iconName)
        XCTAssertEqual(store.customGroups.first?.id, group.id)
        XCTAssertEqual(store.customGroups.first?.name, "Reorganized")
        XCTAssertFalse(store.platforms.contains { $0.id == a.id })
        let saved = try XCTUnwrap(backups.list().first)
        let values = try backups.values(for: saved)
        let previous = try JSONDecoder().decode([SearchPlatform].self, from: XCTUnwrap(values["platform_config"] as? Data))
        XCTAssertEqual(previous.count, PlatformDataStore.defaultPlatforms().count)
        XCTAssertTrue(previous.contains { $0.id == a.id })
        let after = CloudSettingsSyncEngine.snapshot(.standard)
        XCTAssertTrue(try CloudSettingsSyncEngine.recordEdits(from: before, to: after, in: &local, date: Date(timeIntervalSince1970: 2)))
        let merged = try CloudSettingsSyncEngine.merged([peer, local], onto: after)
        let synced = try JSONDecoder().decode([SearchPlatform].self, from: XCTUnwrap(merged["platform_config"] as? Data))
        XCTAssertEqual(Set(synced.map(\.id)), Set(store.platforms.map(\.id)), "An older peer cannot resurrect deliberately replaced links")
    }

    func testPlatformReplacementRejectsPartialInvalidEmptyAndUnbackedImports() throws {
        let store = PlatformDataStore.shared
        let original = (store.platforms, store.customGroups, store.regionNameOverrides)
        defer {
            store.platforms = original.0; store.customGroups = original.1; store.regionNameOverrides = original.2
            store.savePlatforms(); store.saveGroups(); store.saveRegionNames()
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(store.platforms)
        for source in [
            #"{"groups":[{"name":"Bad","platforms":[{"name":"Good","url":"https://example.com/?q=%@"},{"name":"Broken","url":"javascript:alert(1)"}]}]}"#,
            #"{"groups":[{"name":"Empty","platforms":[]}]}"#,
            #"[{"name":"Unnamed","url":"https://example.com/?q=%@"}]"#
        ] {
            let document = try PlatformImportDocument.parse(source)
            XCTAssertThrowsError(try store.replacementPlan(document))
            XCTAssertEqual(try encoder.encode(store.platforms), before)
        }
        let valid = try PlatformImportDocument.parse(#"{"groups":[{"name":"Valid","platforms":[{"name":"Valid","url":"https://example.com/?q=%@"}]}]}"#)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try store.replacePlatforms(valid, backupStore: CloudSettingsBackupStore(directory: file)))
        XCTAssertEqual(try encoder.encode(store.platforms), before)
        XCTAssertEqual(store.customGroups, original.1)
    }

    func testCrossGroupDropsMoveMembershipAndPersistOrderWithoutDuplicatingPlatforms() throws {
        let store = PlatformDataStore.shared, originalPlatforms = store.platforms, originalGroups = store.customGroups
        defer { store.platforms = originalPlatforms; store.customGroups = originalGroups; store.savePlatforms(); store.saveGroups() }
        let examples = Array(PlatformDataStore.defaultPlatforms().prefix(3))
        XCTAssertEqual(examples.count, 3)
        let a = examples[0].id, b = examples[1].id, c = examples[2].id
        var first = CustomGroup(name: "Drag A"), second = CustomGroup(name: "Drag B"), empty = CustomGroup(name: "Empty")
        first.platformIDs = [a,b]; second.platformIDs = [c]
        store.platforms = examples; store.customGroups = [first,second,empty]
        XCTAssertTrue(store.movePlatform(a, from: .custom(first.id), to: .custom(second.id), relativeTo: c))
        XCTAssertEqual(store.customGroups[0].platformIDs,[b]); XCTAssertEqual(store.customGroups[1].platformIDs,[a,c])
        XCTAssertTrue(store.movePlatform(c, from: .custom(second.id), to: .custom(second.id), relativeTo: a))
        XCTAssertEqual(store.customGroups[1].platformIDs,[c,a])
        XCTAssertTrue(store.movePlatform(c, from: .custom(second.id), to: .custom(empty.id)))
        XCTAssertEqual(store.customGroups[2].platformIDs,[c])
        XCTAssertTrue(store.movePlatform(a, from: .custom(second.id), to: .region(.japan)))
        XCTAssertTrue(store.customGroups[1].platformIDs.isEmpty)
        XCTAssertEqual(store.platforms.first { $0.id == a }?.region,.japan)
        XCTAssertTrue(store.movePlatform(a, from: .region(.japan), to: .custom(empty.id), relativeTo: c))
        XCTAssertEqual(store.customGroups[2].platformIDs,[a,c])
        XCTAssertEqual(store.platforms.first { $0.id == a }?.region,.japan,"Custom groups reference the shared regional catalog")
        XCTAssertEqual(Set(store.platforms.map(\.id)).count,3)
        let before = store.customGroups
        XCTAssertFalse(store.movePlatform(b, from: .custom(first.id), to: .custom(UUID())))
        XCTAssertEqual(store.customGroups,before,"Reject disappeared destinations without removing source membership")
        let persisted = try JSONDecoder().decode([CustomGroup].self, from: XCTUnwrap(UserDefaults.standard.data(forKey:"custom_groups")))
        XCTAssertEqual(persisted,store.customGroups)
    }

    func testSavedShenmaDefaultsBecomeQuarkWithoutReplacingCustomTemplates() throws {
        let suite = "QuarkDefaults." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let quark = try XCTUnwrap(GroupDefaultSearchEngine.presets.first { $0.name == "platform_quark" })
        var legacy = quark
        legacy.name = "神马搜索"; legacy.icon = "icon_shenma"
        legacy.template = "https://m.sm.cn/s?q=%@&from=smor&safe=1"; legacy.homeURL = "https://m.sm.cn/"
        var custom = legacy
        custom.name = "My search"; custom.template = "https://search.example/?q=%@"
        let customScope = SearchGroupScope.custom(UUID())
        defaults.set(try JSONEncoder().encode([SearchGroupScope.region(.china).id: legacy, customScope.id: custom]), forKey: GroupDefaultSearchService.storageKey)
        let service = GroupDefaultSearchService(defaults: defaults)
        XCTAssertEqual(service.engine(for: .region(.china)), quark)
        XCTAssertEqual(service.engine(for: customScope), custom)
        let saved = defaults.data(forKey: GroupDefaultSearchService.storageKey)
        service.reloadFromDefaults()
        XCTAssertEqual(defaults.data(forKey: GroupDefaultSearchService.storageKey), saved)
        XCTAssertEqual(GroupDefaultSearchService(defaults: defaults).engine(for: .region(.china)), quark)
    }

    func testRegionDefaultsAndLanguageDependentCustomDefaults() {
        let regions: [(PlatformRegion, String)] = [(.china,"www.baidu.com"),(.international,"www.google.com"),
            (.japan,"www.google.co.jp"),(.korea,"www.google.co.kr"),(.russia,"yandex.ru")]
        for (region, host) in regions {
            let engine = GroupDefaultSearchEngine.initial(scope: .region(region), language: "en-US")
            XCTAssertEqual(engine.platform(region: region).searchURL(for: "a & 中文")?.host, host)
        }
        let scope = SearchGroupScope.custom(UUID())
        XCTAssertEqual(GroupDefaultSearchEngine.initial(scope: scope, language: "zh-Hant").name, "platform_baidu")
        XCTAssertEqual(GroupDefaultSearchEngine.initial(scope: scope, language: "en-US").name, "platform_google")
    }
    func testIndependentOverridesPersistAndValidateURLs() throws {
        let name = "GroupSearchTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = GroupDefaultSearchService(defaults: defaults)
        let scope = SearchGroupScope.custom(UUID())
        var engine = GroupDefaultSearchEngine.presets[0]
        engine.name = "Local search"; engine.template = "https://search.example/find?q=%@"
        try service.save(engine, for: scope)
        XCTAssertEqual(GroupDefaultSearchService(defaults: defaults).engine(for: scope), engine)
        XCTAssertEqual(service.engine(for: .region(.russia)).name, "platform_yandex")
        let baidu = try XCTUnwrap(GroupDefaultSearchEngine.presets.first { $0.name == "platform_baidu" })
        try service.save(baidu, for: .region(.china))
        XCTAssertEqual(GroupDefaultSearchService(defaults: defaults).engine(for: .region(.china)), baidu)
        engine.template = "javascript:alert('%@')"
        XCTAssertThrowsError(try service.save(engine, for: scope))
        engine.template = "https://example.com/search"
        XCTAssertThrowsError(try service.save(engine, for: scope))
        XCTAssertEqual(service.engine(for: scope).name, "Local search")
    }
    func testAllDisabledPlatformsKeepBookmarkAndHomeSearchTargetsAvailable() {
        let store = PlatformDataStore.shared
        let original = store.platforms
        let oldPrivate = UserDefaults.standard.object(forKey: "is_incognito")
        defer {
            store.platforms = original; store.savePlatforms()
            if let oldPrivate { UserDefaults.standard.set(oldPrivate, forKey: "is_incognito") }
            else { UserDefaults.standard.removeObject(forKey: "is_incognito") }
        }
        store.platforms = original.map { var platform = $0; platform.isVisible = false; return platform }
        let model = SearchViewModel(suggestionProvider: { _,_ in [] })
        model.isIncognito = true
        for region in PlatformRegion.allCases {
            model.selectRegion(region)
            model.searchText = "Soulo fallback"
            model.performSearch()
            XCTAssertNotNil(model.selectedPlatform?.searchURL(for: model.currentKeyword))
            XCTAssertTrue(model.isSearching)
            let bookmark = URL(string: "https://example.com/a?x=1")!
            XCTAssertEqual(BrowserNavigationResolver.resolve(bookmark.absoluteString, preferredSearchPlatform: model.selectedPlatform), bookmark)
        }
        XCTAssertFalse(store.platforms.contains(where: \.isVisible))
    }
    func testEmptyCustomGroupGetsItsOwnDefaultInsteadOfAnotherRegion() throws {
        let store = PlatformDataStore.shared
        let groups = store.customGroups
        let language = UserDefaults.standard.object(forKey: "app_language")
        let engineData = UserDefaults.standard.data(forKey: GroupDefaultSearchService.storageKey)
        defer {
            store.customGroups = groups
            if let language { UserDefaults.standard.set(language, forKey: "app_language") }
            else { UserDefaults.standard.removeObject(forKey: "app_language") }
            UserDefaults.standard.set(engineData, forKey: GroupDefaultSearchService.storageKey)
            GroupDefaultSearchService.shared.reloadFromDefaults()
        }
        let group = CustomGroup(name: "Empty group")
        store.customGroups.append(group)
        UserDefaults.standard.set("zh-Hans", forKey: "app_language")
        let model = SearchViewModel(suggestionProvider: { _,_ in [] })
        model.selectCustomGroup(group)
        XCTAssertEqual(model.selectedPlatform?.name, "platform_baidu")
        try GroupDefaultSearchService.shared.save(try XCTUnwrap(GroupDefaultSearchEngine.presets.first { $0.name == "platform_yandex" }), for: .custom(group.id))
        model.selectCustomGroup(group)
        XCTAssertEqual(model.selectedPlatform?.name, "platform_yandex")
        XCTAssertEqual(model.selectedGroupID, group.id)
    }
}
