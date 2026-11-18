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

    func testExplicitTabActivationHidesUnmatchedDirectPageAndRestoresMatchingDomain() {
        let model = WebViewModel()
        model.resetPlatformSearchTracking()
        model.updateCurrentURL(URL(string: "https://bpzhe5.com/"))
        model.requestPlatformBarTabActivation()
        model.setPlatformBarMatchingHosts(["baidu.com", "bilibili.com"])
        XCTAssertTrue(model.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        XCTAssertTrue(model.platformBarHiddenByPageTap, "An explicitly selected direct-address tab must also be checked")
        XCTAssertFalse(model.applyPendingPlatformBarTabActivation(autoHideEnabled: true), "Activation is consumed once")
        model.updateCurrentURL(URL(string: "https://m.bilibili.com/"))
        XCTAssertFalse(model.platformBarHiddenByPageTap)
        model.updateCurrentURL(URL(string: "https://automatic.test/"))
        XCTAssertFalse(model.platformBarHiddenByPageTap, "Restoration must disarm later automatic navigation")
        model.requestPlatformBarTabActivation()
        model.applyPendingPlatformBarTabActivation(autoHideEnabled: true)
        XCTAssertTrue(model.platformBarHiddenByPageTap)
        model.resetPlatformBarAutoHide()
        XCTAssertFalse(model.platformBarHiddenByPageTap)
    }

    func testEmptyExtensionAndDisabledTabActivationDoNotArmFutureHiding() {
        for url in [nil, URL(string: "webkit-extension://test/downloader.html")] {
            let model = WebViewModel()
            model.setPlatformBarMatchingHosts(["baidu.com"])
            model.updateCurrentURL(url)
            model.requestPlatformBarTabActivation()
            model.applyPendingPlatformBarTabActivation(autoHideEnabled: true)
            model.updateCurrentURL(URL(string: "https://outside.test/"))
            XCTAssertFalse(model.platformBarHiddenByPageTap)
            model.requestPlatformBarTabActivation()
            model.applyPendingPlatformBarTabActivation(autoHideEnabled: false)
            XCTAssertFalse(model.platformBarHiddenByPageTap)
        }
    }

    func testSameTabAndDifferentTabSelectionQueueActivationButCreationDoesNot() throws {
        let key = "platform-activation-" + UUID().uuidString
        UserDefaults.standard.set(Data(#"{"tabs":[],"activeIndex":0}"#.utf8), forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let manager = TabManager(storageKey: key)
        let first = try XCTUnwrap(manager.activeWebViewModel)
        first.updateCurrentURL(URL(string: "https://outside.test/"))
        first.setPlatformBarMatchingHosts(["bilibili.com"])
        XCTAssertFalse(first.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        let revision = manager.platformBarTabActivationRevision
        manager.switchToTab(at: manager.activeTabIndex)
        XCTAssertEqual(manager.platformBarTabActivationRevision, revision + 1)
        XCTAssertTrue(first.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        XCTAssertTrue(first.platformBarHiddenByPageTap)
        let second = manager.createTab(switchTo: false)
        second.webViewModel.updateCurrentURL(URL(string: "https://m.bilibili.com/"))
        XCTAssertFalse(second.webViewModel.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        manager.switchToTab(id: second.id)
        second.webViewModel.setPlatformBarMatchingHosts(["bilibili.com"])
        XCTAssertTrue(second.webViewModel.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        XCTAssertFalse(second.webViewModel.platformBarHiddenByPageTap)
        XCTAssertEqual(manager.platformBarTabActivationRevision, revision + 2)
        first.resetPlatformBarAutoHide()
        manager.switchToTab(at: 0, userInitiated: false)
        XCTAssertEqual(manager.platformBarTabActivationRevision, revision + 2, "Extension-driven focus is not a user activation")
        XCTAssertFalse(first.applyPendingPlatformBarTabActivation(autoHideEnabled: true))
        XCTAssertFalse(first.platformBarHiddenByPageTap)
    }

    func testMatchingPlatformPageStaysVisibleThenRestoresOnAnotherListedPlatformWhileLoading() {
        let model = WebViewModel()
        model.setPlatformBarMatchingHosts(PlatformBarDomainPolicy.hosts(for: [
            platform("https://www.baidu.com/"), platform("https://www.bilibili.com/")
        ]))
        model.beginPlatformSearchTracking()
        model.updateCurrentURL(URL(string: "https://m.baidu.com/s?wd=test"))
        model.pageDidFinishLoading()
        model.recordPlatformPageTap(autoHideEnabled: true)
        XCTAssertFalse(model.platformBarHiddenByPageTap, "A click on any listed platform must keep the bar visible")
        model.isLoading = true
        model.updateCurrentURL(URL(string: "https://outside.test/article"))
        XCTAssertTrue(model.platformBarHiddenByPageTap, "Following that user click off all platform domains hides the bar")
        model.updateCurrentURL(URL(string: "https://m.bilibili.com/video/1"))
        XCTAssertFalse(model.platformBarHiddenByPageTap, "Another listed platform restores the bar without waiting for load completion")
        model.updateCurrentURL(URL(string: "https://automatic-redirect.test/"))
        XCTAssertFalse(model.platformBarHiddenByPageTap, "After restoration an unrelated automatic redirect needs a fresh click")
        model.recordPlatformPageTap(autoHideEnabled: true)
        XCTAssertTrue(model.platformBarHiddenByPageTap)
        model.updateCurrentURL(URL(string: "https://www.baidu.com/another-page"))
        XCTAssertFalse(model.platformBarHiddenByPageTap, "A different document under a matching domain also restores the bar")
    }

    func testPlatformAutoHideStillRequiresAnEnabledTrustedTapAndUsesTheCurrentGroup() {
        let model = WebViewModel()
        model.setPlatformBarMatchingHosts(["current-group.test"])
        model.beginPlatformSearchTracking()
        model.updateCurrentURL(URL(string: "https://different-group.test/search"))
        model.pageDidFinishLoading()
        XCTAssertFalse(model.platformBarHiddenByPageTap, "Automatic navigation alone must not hide the bar")
        model.recordPlatformPageTap(autoHideEnabled: false)
        XCTAssertFalse(model.platformBarHiddenByPageTap)
        model.recordPlatformPageTap(autoHideEnabled: true)
        XCTAssertTrue(model.platformBarHiddenByPageTap, "A platform belonging only to another group is not a match")
        model.setPlatformBarMatchingHosts(["different-group.test"])
        XCTAssertFalse(model.platformBarHiddenByPageTap, "Updating the visible platform group can restore the bar")
        model.updateCurrentURL(URL(string: "https://outside.test/"))
        XCTAssertFalse(model.platformBarHiddenByPageTap)
        model.recordPlatformPageTap(autoHideEnabled: true)
        XCTAssertTrue(model.platformBarHiddenByPageTap)
        model.beginPlatformSearchTracking()
        XCTAssertFalse(model.platformBarHiddenByPageTap)
        model.resetPlatformSearchTracking()
        model.recordPlatformPageTap(autoHideEnabled: true)
        XCTAssertFalse(model.platformBarHiddenByPageTap)
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
