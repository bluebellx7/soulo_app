import XCTest
@testable import Soulo

final class GPCRequestFactoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "GPCRequestFactoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testAddsHeaderOnlyForDDGConfiguredGPCSites() {
        let factory = GPCRequestFactory(userDefaults: defaults)
        let supported = URLRequest(url: URL(string: "https://www.washingtonpost.com/news")!)
        let unsupported = URLRequest(url: URL(string: "https://example.com")!)

        XCTAssertEqual(
            factory.requestForGPC(basedOn: supported, gpcEnabled: true)?
                .allHTTPHeaderFields?[GPCRequestFactory.secGPCHeader],
            "1"
        )
        XCTAssertNil(factory.requestForGPC(basedOn: unsupported, gpcEnabled: true))
    }

    func testRemovesStaleGPCHeaderForUnsupportedSitesOrDisabledSetting() throws {
        let factory = GPCRequestFactory(userDefaults: defaults)
        var unsupported = URLRequest(url: URL(string: "https://example.com")!)
        unsupported.addValue("1", forHTTPHeaderField: GPCRequestFactory.secGPCHeader)

        let strippedUnsupported = try XCTUnwrap(factory.requestForGPC(basedOn: unsupported, gpcEnabled: true))
        XCTAssertNil(strippedUnsupported.allHTTPHeaderFields?[GPCRequestFactory.secGPCHeader])

        var supported = URLRequest(url: URL(string: "https://nytimes.com")!)
        supported.addValue("1", forHTTPHeaderField: GPCRequestFactory.secGPCHeader)

        let strippedDisabled = try XCTUnwrap(factory.requestForGPC(basedOn: supported, gpcEnabled: false))
        XCTAssertNil(strippedDisabled.allHTTPHeaderFields?[GPCRequestFactory.secGPCHeader])
    }

    func testCustomHeaderEnabledSitesMatchSubdomains() {
        defaults.set(["privacy.example"], forKey: "privacy_gpc_header_enabled_sites")
        let factory = GPCRequestFactory(userDefaults: defaults)

        XCTAssertTrue(factory.isGPCHeaderEligible(url: URL(string: "https://news.privacy.example/article")!))
        XCTAssertFalse(factory.isGPCHeaderEligible(url: URL(string: "https://example")!))
    }
}
