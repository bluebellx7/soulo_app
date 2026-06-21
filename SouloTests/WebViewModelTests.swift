import XCTest
@testable import Soulo

@MainActor
final class WebViewModelTests: XCTestCase {
    func testLoadURLImmediatelyMarksPageAsLoadingBeforeWebViewExists() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com")!

        model.loadURL(url)

        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0.0)
        XCTAssertNil(model.errorMessage)
    }
}
