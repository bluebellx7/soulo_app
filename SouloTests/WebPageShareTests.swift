import XCTest
import WebKit
@testable import Soulo

@MainActor final class WebPageShareTests: XCTestCase {
    func testVisibleRectExcludesOnlyObscuredBottomAndHandlesEmptyViews() {
        let bounds = CGRect(x: 18, y: 24, width: 390, height: 720)
        XCTAssertEqual(WebPageShareImageRenderer.visibleRect(in: bounds, obscuredBottom: 64),
                       CGRect(x: 0, y: 0, width: 390, height: 656))
        XCTAssertEqual(WebPageShareImageRenderer.visibleRect(in: bounds, obscuredBottom: -20).height, 720)
        XCTAssertEqual(WebPageShareImageRenderer.visibleRect(in: bounds, obscuredBottom: 900).height, 0)
        XCTAssertEqual(WebPageShareImageRenderer.visibleRect(in: .zero, obscuredBottom: 0), .zero)
        XCTAssertEqual(WebPageShareImageRenderer.visibleRect(in: CGRect(x: 0, y: 0, width: -1, height: 100), obscuredBottom: 0), .zero)
    }

    func testBrandFooterPreservesPagePixelsAndIncludesTheSouloLogo() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let screenshot = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 200), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 200))
        }
        let image = WebPageShareImageRenderer.brandedImage(from: screenshot, brand: "Soulo：多重搜索浏览器")
        XCTAssertEqual(image.size, CGSize(width: 390, height: 264))
        XCTAssertEqual(image.scale, screenshot.scale)
        assertPixel(image, x: 12, y: 12, red: 255, green: 0, blue: 0)
        assertPixel(image, x: 378, y: 198, red: 255, green: 0, blue: 0)
        assertPixel(image, x: 378, y: 250, red: 255, green: 255, blue: 255)
        let footer = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 0, y: 200 * image.scale,
            width: 390 * image.scale, height: 64 * image.scale)))
        let width = footer.width, height = footer.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(footer, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        var goldenPixels = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1]), blue = Int(pixels[index + 2])
            if red > 170 && green > 120 && red - blue > 25 { goldenPixels += 1 }
        }
        XCTAssertGreaterThan(goldenPixels, 30, "Use the existing golden SouloLogo asset in the exported pixels")
        let attachment = XCTAttachment(image: image); attachment.name = "Soulo branded image payload"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testImageAndURLSharePayloadsStayDistinct() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 200)).image { _ in UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 390, height: 200)) }
        let branded = WebPageShareImageRenderer.brandedImage(from: image, brand: "Soulo: Multi-Search Browser")
        let item = WebPageShareImageItem(image: branded, title: "Chosen viewport")
        let controller = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        let sharedImage = try XCTUnwrap(item.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? UIImage)
        XCTAssertTrue(sharedImage === branded, "The image preview and activity must use the same branded bitmap")
        XCTAssertEqual(item.activityViewController(controller, dataTypeIdentifierForActivityType: nil), "public.png")
        XCTAssertNil(item.activityViewControllerLinkMetadata(controller)?.url)

        let url = try XCTUnwrap(URL(string: "https://example.com/page?q=chosen#part"))
        let items = WebPageShareItems.link(url: url, title: "Chosen page")
        XCTAssertEqual(items.count, 1)
        if #available(iOS 17.4, *) {
            let link = try XCTUnwrap(items.first as? WebPageShareActivityItem)
            XCTAssertEqual(link.activityViewController(controller, itemForActivityType: nil) as? URL, url)
        } else { XCTAssertEqual(items.first as? URL, url) }
    }

    func testUnavailablePreviewStillKeepsTheChosenURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/retained?q=1"))
        let model = WebPageSharePreviewModel(url: url, title: "Unavailable page", webView: nil, obscuredBottom: 64)
        model.capture()
        XCTAssertFalse(model.isCapturing)
        XCTAssertNil(model.image)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.url, url)
        XCTAssertEqual(WebPageShareItems.link(url: model.url, title: model.title).count, 1)
    }

    func testSharingCapturesTheScrolledViewportWithoutScrollingOrToolbarArea() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        web.scrollView.contentInsetAdjustmentBehavior = .never
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.addSubview(web); window.layoutIfNeeded()
        defer { web.stopLoading(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let url = try XCTUnwrap(URL(string: "https://share.example/article"))
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;padding:0}#top{height:400px;background:#f00}#visible{height:1600px;background:#0066ff}</style>
        <div id="top">Above the viewport</div><div id="visible">Chosen visible area</div>
        """, baseURL: url)
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript("document.readyState==='complete'&&!!document.getElementById('visible')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("scrollTo(0,420);null")
        let model = WebPageSharePreviewModel(url: url, title: "Chosen visible area", webView: web, obscuredBottom: 64)
        model.capture()
        for _ in 0..<200 {
            if !model.isCapturing { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.error)
        let image = try XCTUnwrap(model.image)
        XCTAssertEqual(image.size, CGSize(width: 390, height: 500))
        assertPixel(image, x: 12, y: 1, red: 0, green: 102, blue: 255)
        assertPixel(image, x: 12, y: 120, red: 0, green: 102, blue: 255)
        assertPixel(image, x: 378, y: 434, red: 0, green: 102, blue: 255)
        assertPixel(image, x: 378, y: 480, red: 255, green: 255, blue: 255)
        let scrollY = try await web.evaluateJavaScript("scrollY") as? Double
        XCTAssertEqual(scrollY ?? 0, 420, accuracy: 1)
        let attachment = XCTAttachment(image: image); attachment.name = "Branded current scrolled viewport"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func assertPixel(_ image: UIImage, x: CGFloat, y: CGFloat, red: UInt8, green: UInt8, blue: UInt8,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let pixel = image.cgImage?.cropping(to: CGRect(x: x * image.scale, y: y * image.scale, width: 1, height: 1)) else {
            XCTFail("Missing pixel", file: file, line: line); return
        }
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        for (actual, expected) in zip(bytes.prefix(3), [red, green, blue]) {
            XCTAssertLessThanOrEqual(abs(Int(actual) - Int(expected)), 5, file: file, line: line)
        }
    }
}
