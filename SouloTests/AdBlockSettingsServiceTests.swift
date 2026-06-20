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

        let second = AdBlockSettingsService(userDefaults: defaults)
        XCTAssertEqual(second.hiddenElementCount(for: "example.com"), 5)
    }
}
