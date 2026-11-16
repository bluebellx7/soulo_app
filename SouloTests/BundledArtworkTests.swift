import XCTest
import UIKit
@testable import Soulo

@MainActor
final class BundledArtworkTests: XCTestCase {
    func testEveryIllustrationDecodesAndRendersAtMaximumDisplayScale() throws {
        // ToolIllustration is capped at 280 pt. Keep enough real pixels for
        // its largest 3x presentation and exercise the shipped catalog decoder.
        let scenes: [ToolIllustration.Scene] = [.files, .books, .transfer, .pageQR,
            .downloads, .bookmarks, .history, .about, .review, .quickActions, .playback]
        for scene in scenes {
            try autoreleasepool {
                let started = CFAbsoluteTimeGetCurrent()
                let image = try XCTUnwrap(UIImage(named: scene.rawValue), scene.rawValue)
                let decoded = try XCTUnwrap(image.cgImage, scene.rawValue)
                let expected = scene == .pageQR ? CGSize(width: 600, height: 334) : CGSize(width: 840, height: 560)
                XCTAssertEqual(decoded.width, Int(expected.width), scene.rawValue)
                XCTAssertEqual(decoded.height, Int(expected.height), scene.rawValue)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                format.opaque = false
                let size = CGSize(width: 280, height: 280 * image.size.height / image.size.width)
                let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                let output = try XCTUnwrap(rendered.cgImage)
                XCTAssertEqual(output.width, 840, scene.rawValue)
                let data = try XCTUnwrap(output.dataProvider?.data)
                let bytes = CFDataGetBytePtr(data)!
                XCTAssertTrue((0..<CFDataGetLength(data)).contains { bytes[$0] != 0 }, scene.rawValue)
                print("BUNDLED_ARTWORK \(scene.rawValue) decode_and_draw_ms=\((CFAbsoluteTimeGetCurrent() - started) * 1000)")
                if [.about, .quickActions].contains(scene) {
                    let attachment = XCTAttachment(image: rendered)
                    attachment.name = scene.rawValue + "-3x"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }
}
