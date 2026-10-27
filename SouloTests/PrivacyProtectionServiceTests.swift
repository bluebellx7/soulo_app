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
        first.flushPendingStatistics()

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

    func testInvalidPageCountsCannotCreateOrPollutePrivacySummaries() {
        let service = PrivacyProtectionService(userDefaults: defaults)
        for count in [Int.max, Int.max / 2 + 1, SafeNumericValue.maximumEventCount + 1, -1, 0] {
            service.recordHiddenElementCount(count, for: "example.com")
            service.recordCookieBannerActions(count, for: "example.com")
            service.recordTrackingParametersStripped(count, for: "example.com")
        }
        XCTAssertTrue(service.summariesByHost.isEmpty)
        service.recordHiddenElementCount(3, for: "example.com")
        service.recordCookieBannerActions(1, for: "example.com")
        XCTAssertEqual(service.summary(for: "example.com").protectionCount, 4)
    }

    func testExistingLargeCountersCanIncrementAndPersistWithoutOverflow() throws {
        var summary = SitePrivacySummary(host: "example.com")
        summary.hiddenElementCount = .max
        summary.httpsUpgradeCount = .max
        summary.strippedTrackingParameterCount = .max
        summary.cookieBannerActionCount = .max
        defaults.set(try JSONEncoder().encode([summary.host: summary]), forKey: "summaries")
        let service = PrivacyProtectionService(userDefaults: defaults, summariesKey: "summaries")
        service.recordHiddenElementCount(2, for: summary.host)
        service.recordHTTPSUpgrade(for: summary.host)
        service.recordTrackingParametersStripped(2, for: summary.host)
        service.recordCookieBannerActions(2, for: summary.host)
        XCTAssertEqual(service.summary(for: summary.host).protectionCount, .max)
        service.flushPendingStatistics()
        XCTAssertEqual(PrivacyProtectionService(userDefaults: defaults, summariesKey: "summaries").summary(for: summary.host), summary)
    }

    func testPrivateBrowsingDoesNotRecordDomainsOrResourceURLs() {
        let service = PrivacyProtectionService(userDefaults: defaults)
        service.recordHiddenElementCount(2, for: "public.example")
        defaults.set(true, forKey: "is_incognito")
        service.recordHiddenElementCount(3, for: "private.example")
        service.recordTrackerHosts(["google-analytics.com"], for: "private.example")
        service.recordResourceObservations([ResourceObservation(
            urlString: "https://google-analytics.com/collect?private=1", resourceType: "script",
            pageURLString: "https://private.example/secret", potentiallyBlocked: true
        )], for: URL(string: "https://private.example/secret"))
        service.recordHTTPSUpgrade(for: "private.example")
        service.recordTrackingParametersStripped(1, for: "private.example")
        service.recordCookieBannerActions(1, for: "private.example")
        service.flushPendingStatistics()
        XCTAssertNil(service.summariesByHost["private.example"])
        let restored = PrivacyProtectionService(userDefaults: defaults)
        XCTAssertNil(restored.summariesByHost["private.example"])
        XCTAssertEqual(restored.summary(for: "public.example").hiddenElementCount, 2)
        defaults.set(false, forKey: "is_incognito")
        service.recordHiddenElementCount(1, for: "resumed.example")
        XCTAssertEqual(service.summary(for: "resumed.example").hiddenElementCount, 1)
    }
}
