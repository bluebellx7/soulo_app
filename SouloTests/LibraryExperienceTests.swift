import XCTest
import SwiftUI
import WebKit
import CoreImage
@testable import Soulo

final class LibraryExperienceTests: XCTestCase {
    func testScannedURLsAndLocalTextStaySeparate() {
        for value in ["https://example.com/a?b=1", "http://localhost:8080", "example.com/path", "example.com?a=1", "192.168.1.1:8080", "https://example.com/image.jpg", "https://example.com/book.pdf"] {
            XCTAssertNotNil(ScannedContent(text: value).webURL, value)
        }
        for value in ["hello world", "WIFI:T:WPA;S:my wifi;P:secret;;", "javascript:alert(1)", "file:///tmp/a", "soulo://action", "data:text/html,test"] {
            XCTAssertNil(ScannedContent(text: value).webURL, value)
        }
        let html = ScannedContent(text: "<script>fetch('https://example.com')</script>\nhello & goodbye").html
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertFalse(html.contains("<script>fetch"))
        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("hello &amp; goodbye"))
    }

    func testQRDecoderReadsImagePayload() throws {
        let payload = "https://example.com/scan?value=1"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(payload.utf8), forKey: "inputMessage")
        let output = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let image = try XCTUnwrap(CIContext().createCGImage(output, from: output.extent))
        let data = try XCTUnwrap(UIImage(cgImage: image).pngData())
        XCTAssertEqual(try ScannedContent.decodeImage(data), payload)
    }

    func testPhotoTextFallbackAndEmptyImage() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 400))
        let photo = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400))
            ("Read this original image text." as NSString).draw(at: CGPoint(x: 45, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.black,
            ])
        }
        let text = try ScannedContent.decodeImage(try XCTUnwrap(photo.pngData()))
        XCTAssertTrue(text.localizedCaseInsensitiveContains("original image text"), text)
        let empty = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1000, height: 400)) }
        XCTAssertThrowsError(try ScannedContent.decodeImage(try XCTUnwrap(empty.pngData())))
    }

    func testBarcodeImageReturnsItsContent() throws {
        let filter = try XCTUnwrap(CIFilter(name: "CICode128BarcodeGenerator"))
        filter.setValue(Data("SOULO-12345".utf8), forKey: "inputMessage")
        let code = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 4, y: 4))
        let bounds = code.extent.insetBy(dx: -60, dy: -60)
        let white = CIImage(color: .white).cropped(to: bounds)
        let image = try XCTUnwrap(CIContext().createCGImage(code.composited(over: white), from: bounds))
        XCTAssertEqual(try ScannedContent.decodeImage(try XCTUnwrap(UIImage(cgImage: image).pngData())), "SOULO-12345")
    }

    func testExternalDocumentIsCopiedWithoutChangingOriginal() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("External-\(UUID().uuidString).txt")
        let bytes = Data("An original imported document.".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let imported = try ExternalDocumentImporter.copyToLibrary(source)
        defer { try? FileManager.default.removeItem(at: imported) }
        XCTAssertNotEqual(imported, source)
        XCTAssertEqual(imported.deletingLastPathComponent(), BookLibrary.directory)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        XCTAssertEqual(try ExternalDocumentImporter.copyToLibrary(imported), imported)
        XCTAssertThrowsError(try ExternalDocumentImporter.copyToLibrary(URL(string: "https://example.com/file.txt")!))
    }

    @MainActor func testContinuousReaderCrossesChaptersAndBoundsLoadedDocuments() async throws {
        let chunks = (0..<12).map { "Chapter \($0)\n" + String(repeating: "Paragraph of original test prose, with a steady rhythm for continuous scrolling.\n", count: 50) }
        let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "Continuous", fileName: "continuous.txt"))
        let window = try host(BookWebSurface(data: Data(), textData: JSONEncoder().encode(chunks), format: .text, controller: controller))
        defer { window.isHidden = true; window.rootViewController = nil }
        try await wait { controller.ready || controller.error != nil }
        XCTAssertNil(controller.error)
        let web = try XCTUnwrap(controller.webView)
        controller.go("5")
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 5")
        try await Task.sleep(for: .milliseconds(450))
        let count = try await web.evaluateJavaScript("document.querySelector('foliate-view').renderer.getContents().length") as? Int
        XCTAssertLessThanOrEqual(try XCTUnwrap(count), 5)
        XCTAssertGreaterThan(try XCTUnwrap(count), 1, "Neighboring chapters should already be ready")
        _ = try await web.evaluateJavaScript("""
        (() => {const r = document.querySelector('foliate-view').renderer;
        const frame = r.getContents()[0].doc.defaultView.frameElement;
        r.scrollBy(0, frame.parentElement.parentElement.offsetHeight + 100); return true;})()
        """)
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 6")
        try await waitJS(web, "document.querySelector('foliate-view').lastLocation?.tocItem?.href === '6'")
        let rawLocation = try await web.evaluateJavaScript("document.querySelector('foliate-view').lastLocation?.cfi") as? String
        let location = try XCTUnwrap(rawLocation)
        XCTAssertTrue(location.hasPrefix("epubcfi("))
        controller.go("1")
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 1")
        controller.go(location)
        try await waitJS(web, "document.querySelector('foliate-view').renderer.getContents()[0]?.index === 6")
        // Publisher styles on descendants must not prevent reader preferences from applying.
        _ = try await web.evaluateJavaScript("""
        (() => { const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
        const p = doc.querySelector('p') || doc.body.appendChild(doc.createElement('p'));
        p.id = 'publisher-font-test'; p.textContent = 'Publisher text 字体测试';
        p.style.cssText = 'font-family: Times; font-size: 12px; line-height: 1'; return true; })()
        """)
        controller.font = "sans"; controller.line = 2
        controller.theme = "dark"; controller.size = 22; controller.style()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertNil(controller.error)
        let font = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('foliate-view').renderer.getContents()[0].doc.body).fontSize") as? String
        XCTAssertEqual(font, "22px")
        let paragraph = try await web.evaluateJavaScript("""
        (() => {const doc = document.querySelector('foliate-view').renderer.getContents()[0].doc;
        const style = doc.defaultView.getComputedStyle(doc.getElementById('publisher-font-test'));
        return {font: style.fontFamily, size: style.fontSize, line: style.lineHeight};})()
        """) as? [String: String]
        XCTAssertTrue(paragraph?["font"]?.contains("PingFang SC") == true)
        XCTAssertEqual(paragraph?["size"], "22px")
        XCTAssertEqual(paragraph?["line"], "44px")
        let attachment = XCTAttachment(image: try await web.takeSnapshot(configuration: nil))
        attachment.name = "continuous-reader-dark"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func host<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        return window
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for the reader")
    }
    @MainActor private func waitJS(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<150 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        let state = try? await web.evaluateJavaScript("""
        (()=>{const v=document.querySelector('foliate-view'), c=v.renderer.getContents(), s=c[0]?.doc.defaultView.frameElement.parentElement.parentElement.parentElement;
        return JSON.stringify({last:v.lastLocation?.cfi,scroll:s?.scrollTop,contents:c.map(x=>({index:x.index,top:x.doc.defaultView.frameElement.parentElement.parentElement.offsetTop,height:x.doc.defaultView.frameElement.parentElement.parentElement.offsetHeight}))})})()
        """)
        XCTFail("Reader condition did not become true: \(script), state: \(state ?? "none")")
    }
}
