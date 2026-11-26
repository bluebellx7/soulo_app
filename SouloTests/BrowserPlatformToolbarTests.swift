import XCTest
@testable import Soulo

@MainActor
final class BrowserPlatformToolbarTests: XCTestCase {
    private func platform(_ home: String, search: String? = nil) -> SearchPlatform {
        SearchPlatform(id: UUID(), name: home, iconName: "globe", searchURLTemplate: search ?? home,
            homeURL: home, region: .china, isBuiltIn: false, isVisible: true,
            sortOrder: 0, usageCount: 0, isCustom: true)
    }

    func testPlatformDomainsIncludeEveryListedPlatformAndItsSearchHost() {
        let hosts = PlatformBarDomainPolicy.hosts(for: [
            platform("https://www.baidu.com/", search: "https://m.baidu.com/s?wd=%@"),
            platform("https://www.bilibili.com/", search: "https://search.bilibili.com/all?keyword=%@"),
            platform("https://portal.example/start", search: "https://query.example/find?q=%@")
        ])
        for raw in ["https://m.baidu.com/s", "https://www.bilibili.com/video/1",
                    "https://live.bilibili.com/42", "https://query.example/find"] {
            XCTAssertTrue(PlatformBarDomainPolicy.matches(URL(string: raw), hosts: hosts), raw)
        }
        for raw in ["https://baidu.com.evil.test/", "https://notbaidu.com/", "https://other-group.test/"] {
            XCTAssertFalse(PlatformBarDomainPolicy.matches(URL(string: raw), hosts: hosts), raw)
        }
    }

    func testPlatformDomainMatchingKeepsPublicSuffixTenantsAndIPAddressesSeparate() {
        let hosts = PlatformBarDomainPolicy.hosts(for: [
            platform("https://www.google.co.kr/"), platform("https://alice.github.io/"),
            platform("http://127.0.0.1:8080/"), platform("http://[::1]:8080/")
        ])
        for raw in ["https://mobile.google.co.kr/", "https://sub.alice.github.io/", "http://127.0.0.1:9090/", "http://[::1]:9090/"] {
            XCTAssertTrue(PlatformBarDomainPolicy.matches(URL(string: raw), hosts: hosts), raw)
        }
        for raw in ["https://other.co.kr/", "https://bob.github.io/", "http://127.0.0.2/", "http://foo.127.0.0.1/"] {
            XCTAssertFalse(PlatformBarDomainPolicy.matches(URL(string: raw), hosts: hosts), raw)
        }
        XCTAssertFalse(PlatformBarDomainPolicy.matches(URL(string: "webkit-extension://test/page.html"), hosts: hosts))
    }

    func testDomainHighlightUsesCurrentPageAndKeepsSearchSelectionIndependent() {
        let baidu = platform("https://www.baidu.com/"), bilibili = platform("https://www.bilibili.com/")
        let entries = PlatformBarDomainPolicy.entries(for: [baidu, bilibili].map(PlatformBarDomainPolicy.Source.init))
        XCTAssertEqual(PlatformBarDomainPolicy.highlightedPlatformID(for: URL(string: "https://m.bilibili.com/video/1"),
            entries: entries, preferredID: baidu.id), bilibili.id)
        for raw in ["https://bpzhe5.com/", "https://bilibili.com.evil.test/", "webkit-extension://test/downloader.html"] {
            XCTAssertNil(PlatformBarDomainPolicy.highlightedPlatformID(for: URL(string: raw), entries: entries, preferredID: baidu.id))
        }
        XCTAssertNil(PlatformBarDomainPolicy.highlightedPlatformID(for: nil, entries: entries, preferredID: baidu.id))
    }

    func testDomainHighlightPrefersSpecificHostThenSelectedPlatformThenBarOrder() {
        let general = platform("https://example.com/"), docs = platform("https://docs.example.com/"),
            sameDocs = platform("https://docs.example.com/start")
        let entries = PlatformBarDomainPolicy.entries(for: [general, docs, sameDocs].map(PlatformBarDomainPolicy.Source.init))
        let url = URL(string: "https://docs.example.com/article")
        XCTAssertEqual(PlatformBarDomainPolicy.highlightedPlatformID(for: url, entries: entries, preferredID: general.id), docs.id)
        XCTAssertEqual(PlatformBarDomainPolicy.highlightedPlatformID(for: url, entries: entries, preferredID: sameDocs.id), sameDocs.id)
        XCTAssertEqual(PlatformBarDomainPolicy.highlightedPlatformID(for: url, entries: entries, preferredID: nil), docs.id)
    }

    func testPlatformBarFollowsCommittedDomainsWithoutAPageTap() throws {
        let model = WebViewModel()
        let results = try XCTUnwrap(URL(string: "https://www.baidu.com/s?wd=%E4%BA%BA"))
        let relay = try XCTUnwrap(URL(string: "https://m.baidu.com/tc"))
        let definition = try XCTUnwrap(URL(string: "https://zd.souf.com.cn/zi/4eba/"))
        let otherPlatform = try XCTUnwrap(URL(string: "https://m.bilibili.com/video/1"))
        let hosts: Set<String> = ["baidu.com", "bilibili.com"]
        func hidden() -> Bool {
            PlatformBarDomainPolicy.shouldAutoHide(for: model.committedPageURL, hosts: hosts)
        }

        model.updateCurrentURL(results)
        XCTAssertFalse(hidden())
        model.isLoading = true
        model.recordNavigationRequest(definition)
        model.updateCurrentURL(definition, fromObservation: true)
        XCTAssertEqual(model.currentURL, definition)
        XCTAssertFalse(hidden(), "A provisional address must not change the bar")
        model.updateCurrentURL(relay)
        XCTAssertFalse(hidden())
        model.updateCurrentURL(definition)
        XCTAssertTrue(hidden(), "An off-platform document hides the bar regardless of how it opened")
        model.updateCurrentURL(otherPlatform)
        XCTAssertFalse(hidden())
        model.updateCurrentURL(definition)
        XCTAssertTrue(hidden())
        XCTAssertFalse(PlatformBarDomainPolicy.shouldAutoHide(for: model.committedPageURL, hosts: ["zd.souf.com.cn"]))
    }

    func testInitialAndNonWebDocumentsKeepPlatformBar() throws {
        for url in [nil, URL(string: "about:blank"), URL(string: "webkit-extension://test/downloader.html")] {
            XCTAssertFalse(PlatformBarDomainPolicy.shouldAutoHide(for: url, hosts: ["baidu.com"]))
        }
        let model = WebViewModel()
        let saved = try XCTUnwrap(URL(string: "https://outside.test/"))
        model.loadCachedURL(saved)
        XCTAssertTrue(PlatformBarDomainPolicy.shouldAutoHide(for: model.committedPageURL, hosts: ["baidu.com"]))
    }

    private func defaults() throws -> UserDefaults {
        let name = "PlatformToolbar." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testVisibilityDefaultsPreserveExistingAutoHidePreference() throws {
        let d = try defaults()
        XCTAssertTrue(PlatformBarPreferences.isVisible(in: d))
        XCTAssertNil(d.object(forKey: PlatformBarPreferences.visibilityKey))
        d.set(true, forKey: "auto_hide_platform_bar")
        XCTAssertTrue(PlatformBarPreferences.autoHides(in: d))
        d.set(false, forKey: PlatformBarPreferences.visibilityKey)
        XCTAssertFalse(PlatformBarPreferences.autoHides(in: d))
        XCTAssertTrue(d.bool(forKey: "auto_hide_platform_bar"))
        d.set(true, forKey: PlatformBarPreferences.visibilityKey)
        XCTAssertTrue(PlatformBarPreferences.autoHides(in: d))
    }

    func testMoreAndToolbarEditsAndResetsAreIndependent() throws {
        let d = try defaults(), service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(service.moreActions, BrowserToolbarConfigurationService.defaultMoreActions)
        XCTAssertNil(d.object(forKey: BrowserToolbarConfigurationService.moreActionsKey))
        service.save(actions: [.platforms, .newTab, .tabs, .more], addressAction: .reload,
                     moreActions: [.platforms, .none, .downloads])
        let more = service.moreActions
        service.reset()
        XCTAssertEqual(service.moreActions, more)
        service.save(actions: [.platforms, .back, .tabs, .more], addressAction: .platforms)
        service.resetMoreActions()
        XCTAssertEqual(service.actions, [.platforms, .back, .tabs, .more])
        XCTAssertEqual(service.addressAction, .platforms)
        XCTAssertFalse(BrowserToolbarAction.platforms.requiresPage)
        let restored = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(restored.actions, service.actions)
        XCTAssertEqual(restored.moreActions, BrowserToolbarConfigurationService.defaultMoreActions)
    }

    func testCorruptAndHiddenMoreSlotsHaveSafeStableFallbacks() throws {
        let d = try defaults()
        d.set(["more", "future-action", "books"], forKey: BrowserToolbarConfigurationService.moreActionsKey)
        let service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(Array(service.moreActions.prefix(3)), [.none, .reload, .files])
        XCTAssertEqual(service.moreActions.count, 12)
        service.saveMoreActions(Array(repeating: .none, count: 20))
        service.reloadFromDefaults()
        XCTAssertEqual(service.moreActions, Array(repeating: .none, count: 12))
    }

    func testLeadingActionMigrationPersistenceAndIndependentReset() throws {
        let d = try defaults(), service = BrowserToolbarConfigurationService(defaults: d)
        XCTAssertEqual(service.leadingAction, .siteInformation)
        XCTAssertNil(d.object(forKey: BrowserToolbarConfigurationService.leadingActionKey))
        service.save(actions: service.actions, addressAction: .reload, moreActions: [.siteInformation], leadingAction: .platforms)
        XCTAssertEqual(BrowserToolbarConfigurationService(defaults: d).leadingAction, .platforms)
        service.resetMoreActions()
        XCTAssertEqual(service.leadingAction, .platforms)
        service.save(actions: service.actions, addressAction: .reload)
        XCTAssertEqual(service.leadingAction, .platforms, "Older save callers must preserve the chosen leading action")
        service.reset()
        XCTAssertEqual(service.leadingAction, .siteInformation)
        d.set("future-action", forKey: BrowserToolbarConfigurationService.leadingActionKey)
        service.reloadFromDefaults()
        XCTAssertEqual(service.leadingAction, .siteInformation)
        XCTAssertEqual(BrowserToolbarConfigurationService.normalizedLeadingAction(.more), .siteInformation)
        XCTAssertEqual(BrowserToolbarConfigurationService.normalizedLeadingAction(BrowserToolbarAction.none), .none)
    }

    func testNewPreferencesAreIncludedInSyncAndBackups() throws {
        let d = try defaults()
        d.set(false, forKey: PlatformBarPreferences.visibilityKey)
        d.set(["platforms", "none"], forKey: BrowserToolbarConfigurationService.moreActionsKey)
        d.set("platforms", forKey: BrowserToolbarConfigurationService.leadingActionKey)
        let snapshot = CloudSettingsSyncEngine.snapshot(d)
        XCTAssertEqual(snapshot[BrowserToolbarConfigurationService.leadingActionKey] as? String, "platforms")
        XCTAssertEqual(snapshot[PlatformBarPreferences.visibilityKey] as? Bool, false)
        XCTAssertEqual(snapshot[BrowserToolbarConfigurationService.moreActionsKey] as? [String], ["platforms", "none"])
    }
}
