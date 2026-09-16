import XCTest
import CoreImage
import UIKit
@testable import Soulo

final class WebPageQRCodeTests: XCTestCase {
    func testPlainQRCodeRoundTripsExactAddress() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/中文路径?q=hello%20world&token=a%2Bb#section-2"))
        let result = await WebPageQRCodeService.image(for: url)
        let image = try XCTUnwrap(result)
        XCTAssertEqual(try decode(image), url.absoluteString)
        XCTAssertGreaterThanOrEqual(image.size.width, 900)
        XCTAssertEqual(image.size.width, image.size.height)
    }

    func testLogoQRCodeRoundTripsShortAndLongAddresses() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let logo = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 48), format: format).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            UIColor.white.setFill(); context.fill(CGRect(x: 16, y: 8, width: 32, height: 32))
        }
        for address in ["https://example.com", "https://example.com/article?text=" + String(repeating: "abc123%20", count: 85)] {
            let url = try XCTUnwrap(URL(string: address))
            let result = await WebPageQRCodeService.image(for: url, favicon: logo)
            let image = try XCTUnwrap(result)
            XCTAssertEqual(try decode(image), url.absoluteString)
            let png = try XCTUnwrap(image.pngData())
            XCTAssertEqual(try ScannedContent.decodeImage(png), url.absoluteString, "Saved/shared PNG must be readable by Soulo's scanner")
        }
    }

    func testUnsupportedAndOversizedAddressesFailGracefully() async throws {
        for address in ["file:///private/example.txt", "about:blank", "javascript:alert(1)"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertFalse(WebPageQRCodeService.canEncode(url))
            let image = await WebPageQRCodeService.image(for: url)
            XCTAssertNil(image)
        }
        let long = try XCTUnwrap(URL(string: "https://example.com/?q=" + String(repeating: "a", count: 5000)))
        let image = await WebPageQRCodeService.image(for: long)
        XCTAssertNil(image)
    }

    private func decode(_ image: UIImage) throws -> String {
        let cgImage = try XCTUnwrap(image.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        return try XCTUnwrap(detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first)
    }
}
