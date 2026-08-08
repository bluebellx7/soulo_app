import XCTest
@testable import Soulo

@MainActor
final class WebViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
        super.tearDown()
    }

    func testLoadURLImmediatelyMarksPageAsLoadingBeforeWebViewExists() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com")!

        model.loadURL(url)

        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0.0)
        XCTAssertNil(model.errorMessage)
    }

    func testCompletedEstimatedProgressClearsLoadingState() {
        let model = WebViewModel()
        model.loadURL(URL(string: "https://example.com")!)

        model.updateProgress(1.0)

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 1.0)
    }

    func testRetryCurrentPageStartsFreshNavigationAndClearsError() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com/article")!
        model.loadURL(url)
        model.setError("Offline")

        model.retryCurrentPage()

        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testBrowserNavigationResolverAcceptsWebURLsAndBareHosts() {
        XCTAssertEqual(
            BrowserNavigationResolver.resolve("https://example.com/path"),
            URL(string: "https://example.com/path")
        )
        XCTAssertEqual(
            BrowserNavigationResolver.resolve("example.com/docs"),
            URL(string: "https://example.com/docs")
        )
    }

    func testBrowserNavigationResolverSearchesUnsafeSchemesInsteadOfExecutingThem() {
        let result = BrowserNavigationResolver.resolve("javascript://example.com/alert(1)")

        XCTAssertEqual(result?.scheme, "https")
        XCTAssertEqual(result?.host, "www.google.com")
        XCTAssertTrue(result?.query?.contains("javascript") == true)
    }

    func testDownloadStateStaysActiveUntilEveryDownloadFinishes() {
        let model = WebViewModel()

        model.updateDownloadState(activeCount: 2, fileName: "First.pdf")
        XCTAssertTrue(model.isDownloading)
        XCTAssertEqual(model.activeDownloadCount, 2)

        model.updateDownloadState(activeCount: 1, fileName: "Second.pdf")
        XCTAssertTrue(model.isDownloading)
        XCTAssertEqual(model.downloadFileName, "Second.pdf")

        model.updateDownloadState(activeCount: 0)
        XCTAssertFalse(model.isDownloading)
        XCTAssertEqual(model.downloadFileName, "")
    }
}
