import XCTest
@testable import Soulo

final class SafeNumericValueTests: XCTestCase {
    func testAcceptsExactNonnegativeIntegersWithoutLosingInt64Precision() {
        for value in [0, 42, Int64.max, "9223372036854775807", NSNumber(value: Int64.max)] as [Any] {
            XCTAssertNotNil(SafeNumericValue.nonnegativeInt64(value), "\(value)")
        }
        XCTAssertEqual(SafeNumericValue.nonnegativeInt64(NSNumber(value: Int64.max)), .max)
        XCTAssertEqual(SafeNumericValue.nonnegativeInt64("9223372036854775807"), .max)
        XCTAssertEqual(SafeNumericValue.nonnegativeInt(42.0), 42)
        XCTAssertEqual(SafeNumericValue.nonnegativeInt("42"), 42)
    }

    func testRejectsNonfiniteOutOfRangeFractionalNegativeAndBooleanValues() {
        let invalid: [Any] = [Double.nan, Double.infinity, -Double.infinity, 1e100,
            Double(Int64.max), UInt64.max, "9223372036854775808", "1e100", "NaN",
            -1, -1.0, "-1", 1.5, "1.5", true, false, NSNull(), [1, 2]]
        for value in invalid {
            XCTAssertNil(SafeNumericValue.nonnegativeInt64(value), "\(value)")
            XCTAssertNil(SafeNumericValue.nonnegativeInt(value), "\(value)")
        }
        XCTAssertNil(SafeNumericValue.nonnegativeInt(nil))
    }

    func testSinglePageReportsAreBoundedWithoutChangingNormalCounts() {
        XCTAssertEqual(SafeNumericValue.eventCount(1), 1)
        XCTAssertEqual(SafeNumericValue.eventCount(3), 3)
        XCTAssertEqual(SafeNumericValue.eventCount(SafeNumericValue.maximumEventCount), SafeNumericValue.maximumEventCount)
        for value in [0, -1, SafeNumericValue.maximumEventCount + 1, Int.max, true, 3.5] as [Any] {
            XCTAssertNil(SafeNumericValue.eventCount(value))
        }
    }

    func testCounterAndSummaryAdditionNeverWraps() {
        XCTAssertEqual(SafeNumericValue.addingCounts(3, 2), 5)
        XCTAssertEqual(SafeNumericValue.addingCounts(.max, 1), .max)
        XCTAssertEqual(SafeNumericValue.addingCounts(.max - 1, 2), .max)
        XCTAssertEqual(SafeNumericValue.addingCounts(-1, 2), 2)
        XCTAssertEqual(SafeNumericValue.totalCount([Int.max, Int.max, 1]), .max)
        XCTAssertEqual(SafeNumericValue.totalCount([1, 2, 3]), 6)
    }

    func testExpectedBytesAreUnknownWhenMissingInvalidOrOverflowing() {
        XCTAssertEqual(SafeNumericValue.byteCountTotal([10, 20], requirePositive: true), 30)
        XCTAssertEqual(SafeNumericValue.byteCountTotal([Int64.max - 1, 1], requirePositive: true), .max)
        for values in [[0, 10], [-1, 10], [Int64.max, 1], [1 << 62, 1 << 62], []] as [[Int64]] {
            XCTAssertNil(SafeNumericValue.byteCountTotal(values, requirePositive: true))
        }
    }

    func testReceivedBytesAllowZeroButRejectNegativeAndOverflow() {
        XCTAssertEqual(SafeNumericValue.byteCountTotal([0, 12]), 12)
        XCTAssertEqual(SafeNumericValue.byteCountTotal([0, 0]), 0)
        XCTAssertNil(SafeNumericValue.byteCountTotal([-1, 1]))
        XCTAssertNil(SafeNumericValue.byteCountTotal([Int64.max, 1]))
    }

    func testPersistedLargePrivacyCountersCanStillRenderTheirTotal() throws {
        var summary = SitePrivacySummary(host: "example.com")
        summary.hiddenElementCount = .max
        summary.httpsUpgradeCount = .max
        summary.strippedTrackingParameterCount = .max
        summary.cookieBannerActionCount = .max
        let restored = try JSONDecoder().decode(SitePrivacySummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(restored.protectionCount, .max)
        XCTAssertEqual(restored.hiddenElementCount, .max)
    }
}
