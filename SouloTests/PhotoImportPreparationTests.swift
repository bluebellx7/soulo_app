import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import Soulo

final class PhotoImportPreparationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func source(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent("download.tmp")
        try data.write(to: url)
        return url
    }
    private func png() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).pngData { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }
    func testIncorrectSuffixUsesDetectedTypeAndPreservesOriginalBytes() throws {
        let data = png()
        let prepared = try PhotoImportPreparation.prepare(sourceURL: source(data), directory: directory, filename: "cdn-photo.jpg")
        XCTAssertEqual(prepared.url.lastPathComponent, "cdn-photo.png")
        XCTAssertEqual(prepared.typeIdentifier, UTType.png.identifier)
        XCTAssertEqual(try Data(contentsOf: prepared.url), data)
    }
    func testHTMLResponseIsRejectedAsImage() throws {
        XCTAssertThrowsError(try PhotoImportPreparation.prepare(sourceURL: source(Data("<html>Forbidden</html>".utf8)),
            directory: directory, filename: "photo.jpg")) { error in
            guard case WebResourceDownloadError.invalidImage = error else { return XCTFail("\(error)") }
        }
    }
    func testCompatibleStaticImageKeepsDimensionsAndAlpha() throws {
        let prepared = try PhotoImportPreparation.prepare(sourceURL: source(png()), directory: directory, filename: "photo.webp", convert: true)
        XCTAssertEqual(prepared.typeIdentifier, UTType.png.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(prepared.url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(image, 0, nil))
        XCTAssertEqual(decoded.width, 40); XCTAssertEqual(decoded.height, 30)
        XCTAssertNotEqual(decoded.alphaInfo, .none)
    }
    func testAnimatedFallbackKeepsFramesAndTiming() throws {
        let file = directory.appendingPathComponent("source.gif")
        let target = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.gif.identifier as CFString, 2, nil))
        let data = png()
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        CGImageDestinationSetProperties(target, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
        for delay in [0.2, 0.4] {
            CGImageDestinationAddImage(target, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(target))
        let prepared = try PhotoImportPreparation.prepare(sourceURL: file, directory: directory, filename: "animated.webp", convert: true)
        let output = try XCTUnwrap(CGImageSourceCreateWithURL(prepared.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(output), 2)
        let properties = CGImageSourceCopyPropertiesAtIndex(output, 1, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        XCTAssertEqual((gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0, 0.4, accuracy: 0.01)
    }
}
