import XCTest
@testable import Soulo

final class TrackerRadarServiceTests: XCTestCase {
    private let trackerData = Data("""
    {
      "trackers": {
        "doubleclick.net": {
          "domain": "doubleclick.net",
          "owner": { "name": "Google LLC", "displayName": "Google" },
          "prevalence": 0.42,
          "categories": ["Advertising", "Ad Motivated Tracking"],
          "default": "block"
        },
        "analytics.example": {
          "domain": "analytics.example",
          "owner": { "name": "Example Analytics" },
          "prevalence": 0.1,
          "categories": ["Analytics"],
          "default": "ignore"
        }
      }
    }
    """.utf8)

    func testClassifiesBlockedTrackerFromTrackerRadarData() throws {
        let service = TrackerRadarService(data: trackerData)
        let request = try XCTUnwrap(service.classify(
            observation: ResourceObservation(
                urlString: "https://stats.doubleclick.net/pixel.js",
                resourceType: "script",
                pageURLString: "https://example.com/article",
                potentiallyBlocked: true
            ),
            protectionEnabled: true
        ))

        XCTAssertEqual(request.state, .blocked)
        XCTAssertEqual(request.entityName, "Google")
        XCTAssertEqual(request.category, .advertising)
        XCTAssertEqual(request.eTLDplus1, "doubleclick.net")
    }

    func testAllowsKnownTrackerWhenProtectionDisabled() throws {
        let service = TrackerRadarService(data: trackerData)
        let request = try XCTUnwrap(service.classify(
            observation: ResourceObservation(
                urlString: "https://doubleclick.net/pixel.js",
                resourceType: "script",
                pageURLString: "https://example.com/article",
                potentiallyBlocked: true
            ),
            protectionEnabled: false
        ))

        XCTAssertEqual(request.state, .allowedProtectionDisabled)
    }

    func testSuppressesSameSiteObservationLikeDuckDuckGoMapper() {
        let service = TrackerRadarService(data: trackerData)
        let request = service.classify(
            observation: ResourceObservation(
                urlString: "https://assets.example.com/app.js",
                resourceType: "script",
                pageURLString: "https://www.example.com/article",
                potentiallyBlocked: false
            ),
            protectionEnabled: true
        )

        XCTAssertNil(request)
    }
}
