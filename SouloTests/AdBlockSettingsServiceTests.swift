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
