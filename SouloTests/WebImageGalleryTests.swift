import WebKit
import XCTest
@testable import Soulo

@MainActor
final class WebImageGalleryTests: XCTestCase {
    func testGalleryKeepsDOMOrderDeduplicatesAndSelectsLinkedOriginal() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        web.loadHTMLString("""
        <img src='/one.jpg' width='320' height='240'>
        <img src='/icon.png' width='20' height='20'>
        <a href='/full-two.jpg'><img src='/thumb-two.jpg' width='320' height='240'></a>
        <img src='/one.jpg' width='320' height='240'>
        <img data-src='/lazy.jpg' width='320' height='240'>
        <img width='320' height='240'>
        <img src='javascript:alert(1)' width='320' height='240'>
        """, baseURL: URL(string: "https://gallery.example/page"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.images.length === 7")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let request = WebImagePreviewRequest(url: URL(string: "https://gallery.example/thumb-two.jpg")!, webView: web, frame: nil)
        let gallery = await WebImageGalleryService.collect(for: request)
        XCTAssertEqual(gallery.items.map(\.url.lastPathComponent), ["one.jpg", "full-two.jpg", "lazy.jpg"])
        XCTAssertEqual(gallery.selectedID, "https://gallery.example/full-two.jpg")
        XCTAssertTrue(gallery.items.allSatisfy { $0.pageURL == request.pageURL })
    }
    func testUnavailableSourceStillKeepsPressedImage() async {
        let web = WKWebView()
        let url = URL(string: "https://gallery.example/selected.png")!
        let request = WebImagePreviewRequest(url: url, webView: web, frame: nil)
        let gallery = await WebImageGalleryService.collect(for: request)
        XCTAssertEqual(gallery.items.map(\.url), [url])
        XCTAssertEqual(gallery.selectedID, url.absoluteString)
    }
}
