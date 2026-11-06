import XCTest
@testable import Soulo

@MainActor
final class AdBlockSettingsServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AdBlockSettingsServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAllowlistMatchesExactAndSubdomainHosts() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        service.addAllowlistedHost("www.example.com")

        XCTAssertTrue(service.isAllowlisted("example.com"))
        XCTAssertTrue(service.isAllowlisted("news.example.com"))
        XCTAssertFalse(service.isAllowlisted("other.com"))
    }

    func testTemporaryExceptionsAffectQueriesWithoutEnteringPreferencesOrSettingsSnapshots() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        service.temporarilyDisableFiltering(for: "www.example.com")
        XCTAssertEqual(service.allowlistedHosts, ["example.com"])
        XCTAssertTrue(service.permanentAllowlistedHosts.isEmpty)
        XCTAssertTrue(service.isTemporarilyAllowlisted("video.example.com"))
        XCTAssertTrue(AdBlockSettingsService.isHostAllowlisted("video.example.com", userDefaults: defaults))
        XCTAssertFalse(AdBlockSettingsService.isHostAllowlisted("notexample.com", userDefaults: defaults))
        XCTAssertNil(defaults.object(forKey: "soulo_ad_block_allowlisted_hosts"))
        XCTAssertNil(CloudSettingsSyncEngine.snapshot(defaults)["soulo_ad_block_allowlisted_hosts"])
        service.reloadFromDefaults() // Reloading settings is not a new app session.
        XCTAssertTrue(service.isAllowlisted("example.com"))
        service.clearTemporaryException(for: "video.example.com")
        XCTAssertFalse(service.isAllowlisted("video.example.com"))
        XCTAssertFalse(AdBlockSettingsService.isHostAllowlisted("video.example.com", userDefaults: defaults))
    }

    func testTemporaryExceptionsEndWithTheirSessionAndDoNotAffectOtherDefaults() {
        var service: AdBlockSettingsService? = AdBlockSettingsService(userDefaults: defaults)
        weak var retired = service
        service?.addAllowlistedHost("permanent.example")
        service?.temporarilyDisableFiltering(for: "temporary.example")
        let anotherSuite = "TemporaryFilteringOther-\(UUID())"
        let anotherDefaults = UserDefaults(suiteName: anotherSuite)!
        defer { anotherDefaults.removePersistentDomain(forName: anotherSuite) }
        XCTAssertFalse(AdBlockSettingsService.isHostAllowlisted("temporary.example", userDefaults: anotherDefaults))
        service = nil
        XCTAssertNil(retired)
        XCTAssertFalse(AdBlockSettingsService.isHostAllowlisted("temporary.example", userDefaults: defaults))
        let nextSession = AdBlockSettingsService(userDefaults: defaults)
        XCTAssertFalse(nextSession.isAllowlisted("temporary.example"))
        XCTAssertTrue(nextSession.isAllowlisted("permanent.example"))
        nextSession.temporarilyDisableFiltering(for: "another.example")
        nextSession.clearTemporaryExceptions()
        XCTAssertEqual(nextSession.allowlistedHosts, ["permanent.example"])
    }

    func testReenablingClearsInheritedTemporaryExceptionAndPermanentChoicePromotesIt() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        service.addAllowlistedHost("other.example")
        service.temporarilyDisableFiltering(for: "example.com")
        service.setFilteringEnabled(true, for: "login.example.com")
        XCTAssertFalse(service.isAllowlisted("login.example.com"))
        XCTAssertTrue(service.isAllowlisted("other.example"))
        service.temporarilyDisableFiltering(for: "new.example")
        service.setFilteringEnabled(false, for: "new.example")
        XCTAssertFalse(service.isTemporarilyAllowlisted("new.example"))
        XCTAssertTrue(service.temporaryAllowlistedHosts.isEmpty)
        XCTAssertEqual(AdBlockSettingsService(userDefaults: defaults).permanentAllowlistedHosts, ["new.example", "other.example"])
    }

    func testSiteFilteringSwitchCanRestoreAnInheritedExceptionAndPersists() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        service.addAllowlistedHost("example.com")
        service.addAllowlistedHost("other.com")
        service.setFilteringEnabled(true, for: "login.example.com")
        XCTAssertFalse(service.isAllowlisted("login.example.com"))
        XCTAssertTrue(service.isAllowlisted("other.com"))
        service.setFilteringEnabled(false, for: "login.example.com")
        XCTAssertTrue(AdBlockSettingsService(userDefaults: defaults).isAllowlisted("login.example.com"))
        service.toggleAllowlist(for: "login.example.com")
        XCTAssertFalse(AdBlockSettingsService(userDefaults: defaults).isAllowlisted("login.example.com"))
    }

    func testHiddenElementStatsPersist() {
        let first = AdBlockSettingsService(userDefaults: defaults)
        first.recordHiddenElementCount(3, for: "example.com")
        first.recordHiddenElementCount(2, for: "www.example.com")
        first.flushPendingStatistics()

        let second = AdBlockSettingsService(userDefaults: defaults)
        XCTAssertEqual(second.hiddenElementCount(for: "example.com"), 5)
    }

    func testInvalidPageCountsDoNotChangeOrPersistStatistics() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        for count in [Int.max, Int.max / 2 + 1, SafeNumericValue.maximumEventCount + 1, -1, 0] {
            service.recordHiddenElementCount(count, for: "example.com")
        }
        XCTAssertTrue(service.hiddenElementCountByHost.isEmpty)
        service.recordHiddenElementCount(3, for: "example.com")
        service.recordHiddenElementCount(2, for: "example.com")
        service.flushPendingStatistics()
        XCTAssertEqual(AdBlockSettingsService(userDefaults: defaults).hiddenElementCount(for: "example.com"), 5)
    }

    func testPreviouslyPersistedLargeCountsDoNotOverflowOnUpdateOrTotal() throws {
        defaults.set(try JSONEncoder().encode(["example.com": Int.max - 1, "other.example": Int.max]), forKey: "counts")
        let service = AdBlockSettingsService(statsKey: "counts", userDefaults: defaults)
        service.recordHiddenElementCount(2, for: "example.com")
        XCTAssertEqual(service.hiddenElementCount(for: "example.com"), .max)
        XCTAssertEqual(SafeNumericValue.totalCount(service.hiddenElementCountByHost.values), .max)
        service.flushPendingStatistics()
        XCTAssertEqual(AdBlockSettingsService(statsKey: "counts", userDefaults: defaults).hiddenElementCount(for: "example.com"), .max)
    }

    func testPrivateFilteringDoesNotRecordVisitedDomains() {
        let service = AdBlockSettingsService(userDefaults: defaults)
        service.recordHiddenElementCount(2, for: "public.example")
        defaults.set(true, forKey: "is_incognito")
        service.recordHiddenElementCount(3, for: "private.example")
        service.recordHiddenElementCount(1, for: "public.example")
        service.flushPendingStatistics()
        let restored = AdBlockSettingsService(userDefaults: defaults)
        XCTAssertEqual(restored.hiddenElementCount(for: "private.example"), 0)
        XCTAssertEqual(restored.hiddenElementCount(for: "public.example"), 2)
        defaults.set(false, forKey: "is_incognito")
        service.recordHiddenElementCount(1, for: "resumed.example")
        XCTAssertEqual(service.hiddenElementCount(for: "resumed.example"), 1)
    }
}
