import XCTest
@testable import Soulo

@MainActor
final class GroupDefaultSearchTests: XCTestCase {
    func testRegionDefaultsAndLanguageDependentCustomDefaults() {
        let regions: [(PlatformRegion, String)] = [(.china,"m.sm.cn"),(.international,"www.google.com"),
            (.japan,"www.google.co.jp"),(.korea,"www.google.co.kr"),(.russia,"yandex.ru")]
        for (region, host) in regions {
            let engine = GroupDefaultSearchEngine.initial(scope: .region(region), language: "en-US")
            XCTAssertEqual(engine.platform(region: region).searchURL(for: "a & 中文")?.host, host)
        }
        let scope = SearchGroupScope.custom(UUID())
        XCTAssertEqual(GroupDefaultSearchEngine.initial(scope: scope, language: "zh-Hant").name, "platform_shenma")
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
        XCTAssertEqual(model.selectedPlatform?.name, "platform_shenma")
        try GroupDefaultSearchService.shared.save(try XCTUnwrap(GroupDefaultSearchEngine.presets.first { $0.name == "platform_yandex" }), for: .custom(group.id))
        model.selectCustomGroup(group)
        XCTAssertEqual(model.selectedPlatform?.name, "platform_yandex")
        XCTAssertEqual(model.selectedGroupID, group.id)
    }
}
