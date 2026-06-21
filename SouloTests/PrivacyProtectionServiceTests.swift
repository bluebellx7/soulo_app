import XCTest
@testable import Soulo

@MainActor
final class PrivacyProtectionServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PrivacyProtectionServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testTrackerClassificationAndSummaryPersistence() {
        let first = PrivacyProtectionService(userDefaults: defaults)

        first.recordTrackerHosts(
            [
                "www.google-analytics.com",
                "ads.example.net",
                "example.com",
                "static.example.com"
            ],
            for: "www.example.com"
        )
        first.recordHiddenElementCount(3, for: "example.com")
        first.recordHTTPSUpgrade(for: "example.com")
        first.recordTrackingParametersStripped(2, for: "example.com")
        first.recordCookieBannerActions(1, for: "example.com")

        let second = PrivacyProtectionService(userDefaults: defaults)
        let summary = second.summary(for: "example.com")

        XCTAssertEqual(summary.trackerHostCount, 2)
        XCTAssertEqual(summary.hiddenElementCount, 3)
        XCTAssertEqual(summary.httpsUpgradeCount, 1)
        XCTAssertEqual(summary.strippedTrackingParameterCount, 2)
        XCTAssertEqual(summary.cookieBannerActionCount, 1)
        XCTAssertTrue(summary.trackerCompanies.contains("Google Analytics"))
        XCTAssertTrue(summary.trackerCompanies.contains("Advertising Network"))
        XCTAssertNil(summary.trackerHostsByCategory[.analytics]?.first { $0.contains("example.com") })
    }

    func testProtectionDisabledHostsPersistAndMatchSubdomains() {
        let first = PrivacyProtectionService(userDefaults: defaults)

        first.setProtectionEnabled(false, for: "www.example.com")

        XCTAssertTrue(first.isProtectionDisabled(for: "example.com"))
        XCTAssertTrue(first.isProtectionDisabled(for: "news.example.com"))
        XCTAssertFalse(first.isProtectionDisabled(for: "other.com"))
        XCTAssertTrue(PrivacyProtectionService.isProtectionDisabled("cdn.example.com", userDefaults: defaults))

        let second = PrivacyProtectionService(userDefaults: defaults)
        XCTAssertTrue(second.isProtectionDisabled(for: "shop.example.com"))

        second.setProtectionEnabled(true, for: "example.com")
        XCTAssertFalse(second.isProtectionDisabled(for: "example.com"))
    }
}
