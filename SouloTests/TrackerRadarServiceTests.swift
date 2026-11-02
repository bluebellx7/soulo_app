import XCTest
import CryptoKit
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

    func testBundledCompressedDatasetPreservesEveryOriginalByteAndTrackerClassification() throws {
        let originalURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "trackerData", withExtension: "json"))
        let original = try Data(contentsOf: originalURL)
        let compressedURL = try XCTUnwrap(Bundle.main.url(forResource: "trackerData", withExtension: "lzfse"))
        let payload = try Data(contentsOf: compressedURL)
        XCTAssertNil(Bundle.main.url(forResource: "trackerData", withExtension: "json"),
            "The app must not ship both compressed and uncompressed resources")
        XCTAssertLessThan(payload.count, original.count / 2)
        XCTAssertEqual(try XCTUnwrap(TrackerRadarResource.decode(payload)), original)
        XCTAssertEqual(try XCTUnwrap(TrackerRadarResource.load(in: .main)), original)

        let raw = TrackerRadarService(data: original)
        let packed = TrackerRadarService(bundle: .main)
        let root = try JSONDecoder().decode(TrackerRadarRoot.self, from: original)
        XCTAssertFalse(root.trackers.isEmpty)
        for host in root.trackers.keys {
            let observation = ResourceObservation(urlString: "https://\(host)/pixel.js", resourceType: "script",
                pageURLString: "https://source.example.invalid/article", potentiallyBlocked: true)
            for protection in [false, true] {
                let expected = try XCTUnwrap(raw.classify(observation: observation, protectionEnabled: protection), host)
                let actual = try XCTUnwrap(packed.classify(observation: observation, protectionEnabled: protection), host)
                XCTAssertEqual(actual.state, expected.state, host)
                XCTAssertEqual(actual.category, expected.category, host)
                XCTAssertEqual(actual.ownerName, expected.ownerName, host)
                XCTAssertEqual(actual.entityName, expected.entityName, host)
                XCTAssertEqual(actual.prevalence, expected.prevalence, host)
                XCTAssertEqual(actual.eTLDplus1, expected.eTLDplus1, host)
            }
        }
        print("TRACKER_RESOURCE_PARITY trackers=\(root.trackers.count) raw=\(original.count) compressed=\(payload.count)")
    }

    func testCompressedDatasetRejectsCorruptionTruncationAndExcessiveAllocation() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "trackerData", withExtension: "lzfse"))
        let payload = try Data(contentsOf: url)
        var badMagic = payload; badMagic[0] ^= 1
        var badChecksum = payload; badChecksum[16] ^= 1
        var tooLarge = payload
        let length = UInt64(TrackerRadarResource.maximumDecodedSize) + 1
        for index in 0..<8 { tooLarge[8 + index] = UInt8(truncatingIfNeeded: length >> (index * 8)) }
        var wrongLength = payload; wrongLength[8] ^= 1
        for invalid in [Data(), Data(payload.prefix(20)), badMagic, badChecksum,
                        tooLarge, wrongLength, Data(payload.prefix(payload.count / 2))] {
            XCTAssertNil(TrackerRadarResource.decode(invalid))
        }
    }

    func testRawFixtureBundlesRetainCompatibility() throws {
        let bundle = Bundle(for: Self.self)
        let original = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "trackerData", withExtension: "json")))
        XCTAssertEqual(TrackerRadarResource.load(in: bundle), original)
    }

    func testCompressedDatasetCanBeReadFromANonzeroBasedDataSlice() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "trackerData", withExtension: "lzfse"))
        let payload = try Data(contentsOf: url)
        var container = Data(repeating: 0, count: 17)
        container.append(payload)
        let slice = container.dropFirst(17)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(TrackerRadarResource.decode(slice), TrackerRadarResource.decode(payload))
    }

    func testBundledDecompressionTimingProbe() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "trackerData", withExtension: "lzfse"))
        let payload = try Data(contentsOf: url)
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = ContinuousClock.now
            let data = try XCTUnwrap(TrackerRadarResource.decode(payload))
            XCTAssertGreaterThan(data.count, payload.count)
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        samples.sort()
        print("TRACKER_DECODE_MEDIAN_MS \(samples[samples.count / 2])")
    }
}
