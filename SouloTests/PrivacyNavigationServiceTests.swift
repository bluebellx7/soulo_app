import XCTest
@testable import Soulo

final class PrivacyNavigationServiceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PrivacyNavigationServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testUpgradesHTTPAndStripsTrackingParametersByDefault() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        let url = URL(string: "http://example.com/path?utm_source=newsletter&id=42&fbclid=abc#section")!

        let transformed = service.transformedURL(for: url)

        XCTAssertEqual(transformed?.absoluteString, "https://example.com/path?id=42#section")
    }

    func testDoesNotUpgradeLocalOrPrivateHosts() {
        let service = PrivacyNavigationService(userDefaults: defaults)

        XCTAssertNil(service.transformedURL(for: URL(string: "http://localhost:8080")!))
        XCTAssertNil(service.transformedURL(for: URL(string: "http://192.168.1.1")!))
        XCTAssertNil(service.transformedURL(for: URL(string: "http://10.0.0.2")!))
        XCTAssertNil(service.transformedURL(for: URL(string: "http://172.16.0.5")!))
    }

    func testTrackingParameterStrippingPreservesBusinessQueryParameters() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        let url = URL(string: "https://shop.example/product?sku=abc&utm_campaign=sale&quantity=2&gclid=click")!

        let transformed = service.transformedURL(for: url)

        XCTAssertEqual(transformed?.absoluteString, "https://shop.example/product?sku=abc&quantity=2")
    }

    func testRespectsDisabledSettings() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set(false, forKey: "privacy_strip_tracking_parameters")
        let url = URL(string: "http://example.com/?utm_source=x&id=1")!

        XCTAssertNil(service.transformedURL(for: url))
    }

    func testIgnoresSubframeNavigations() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        let url = URL(string: "http://example.com/?utm_source=x")!

        XCTAssertEqual(service.decision(for: url, isMainFrame: false), .allow)
    }

    func testSiteProtectionDisableBypassesPrivacyNavigation() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        defaults.set(["example.com"], forKey: "soulo_privacy_disabled_hosts")
        let url = URL(string: "http://news.example.com/?utm_source=x&id=1")!

        XCTAssertNil(service.transformedURL(for: url))
    }

    func testCompatibilityBypassSkipsPrivacyNavigation() {
        let service = PrivacyNavigationService(userDefaults: defaults)
        let url = URL(string: "https://mp.weixin.qq.com/mp/wappoc_appmsgcaptcha?poc_token=abc&utm_source=x")!

        XCTAssertNil(service.transformedURL(for: url))
    }

    func testHTTPSUpgradeFailureExcludesHostAndSubdomains() {
        let service = PrivacyNavigationService(userDefaults: defaults)

        service.recordHTTPSUpgradeFailure(for: "example.com")

        XCTAssertNil(service.transformedURL(for: URL(string: "http://example.com/path")!))
        XCTAssertNil(service.transformedURL(for: URL(string: "http://news.example.com/path")!))
        XCTAssertEqual(
            service.transformedURL(for: URL(string: "http://other.com/path")!)?.absoluteString,
            "https://other.com/path"
        )
    }
}
