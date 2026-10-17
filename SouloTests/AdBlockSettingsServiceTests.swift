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

    func testHiddenElementStatsPersist() {
        let first = AdBlockSettingsService(userDefaults: defaults)
        first.recordHiddenElementCount(3, for: "example.com")
        first.recordHiddenElementCount(2, for: "www.example.com")
        first.flushPendingStatistics()

        let second = AdBlockSettingsService(userDefaults: defaults)
        XCTAssertEqual(second.hiddenElementCount(for: "example.com"), 5)
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
