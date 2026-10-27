import XCTest
import WebKit
@testable import Soulo

@MainActor final class WebFrameRequestTests: XCTestCase {
    func testMissingObjectiveCRequestReturnsNil() {
        let frame = RequestFrameInfo.make(request: nil)
        XCTAssertNil(frame.value(forKey: #keyPath(WKFrameInfo.request)))
        XCTAssertNil(frame.requestURL)
        XCTAssertEqual(frame.requestReads, 2)
    }

    func testExistingFrameURLPreservesQueryAndFragment() {
        let url = URL(string: "https://example.com/path?q=a%2Bb#section")!
        let frame = RequestFrameInfo.make(request: NSURLRequest(url: url))
        XCTAssertEqual(frame.requestURL, url)
        XCTAssertEqual(frame.requestReads, 1)
    }

    func testFrameRequestWithoutURLReturnsNil() {
        let request = NSMutableURLRequest(url: URL(string: "https://example.com/")!)
        request.url = nil
        let frame = RequestFrameInfo.make(request: request)
        XCTAssertNil(frame.requestURL)
    }

    func testMissingFrameURLDoesNotUseTheDestinationAsItsSource() {
        let frame = RequestFrameInfo.make(request: nil)
        let destination = URL(string: "https://example.com/article")!
        XCTAssertNil(frame.requestURL)
        XCTAssertFalse(BrowserWebLinkPolicy.shouldLoadInBrowser(url: destination,
            sourceURL: frame.requestURL, navigationType: .other,
            targetsMainFrame: true, method: "GET", nativeRequest: false))
        XCTAssertTrue(BrowserAdNavigationPolicy.shouldBlock(url: destination,
            sourceURL: frame.requestURL, navigationType: .other,
            isNewWindow: true, sourceIsMainFrame: true, hasRecentGesture: false,
            gestureDestination: nil, gestureIsControl: false))
    }

    func testTypedNavigationWithMissingSourceRequestStillCompletesPolicy() {
        let model = WebViewModel()
        let web = AccessibleWebView(frame: .zero, configuration: WKWebViewConfiguration())
        model.webView = web
        defer { model.releaseWebViewRuntime() }
        let destination = URL(string: "https://example.com/")!
        let action = FrameNavigationAction(url: destination, sourceRequest: nil)
        web.loadHTMLString("<p>Native navigation fixture</p>", baseURL: destination)
        web.stopLoading()
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        let preferences = WKWebpagePreferences()
        var decisions: [WKNavigationActionPolicy] = []
        coordinator.webView(web, decidePolicyFor: action.webKitAction, preferences: preferences) { policy, result in
            decisions.append(policy)
            XCTAssertTrue(result === preferences)
        }
        XCTAssertEqual(decisions, [.allow])
        XCTAssertNil(model.domainNavigationConfirmation)
    }

    func testPageNavigationWithMissingSourceRequestStillCompletesPolicy() {
        let model = WebViewModel()
        let web = WKWebView()
        model.webView = web
        defer { model.releaseWebViewRuntime() }
        let action = FrameNavigationAction(url: URL(string: "https://example.com/")!, sourceRequest: nil)
        let coordinator = WebViewRepresentable.Coordinator(viewModel: model)
        var decisions: [WKNavigationActionPolicy] = []
        coordinator.webView(web, decidePolicyFor: action.webKitAction, preferences: WKWebpagePreferences()) { policy, _ in
            decisions.append(policy)
        }
        XCTAssertEqual(decisions, [.allow])
        XCTAssertNil(model.domainNavigationConfirmation)
    }
}

// Objective-C stand-ins return nil from the actual request getter, not from
// value(forKey:). Do not instantiate WKFrameInfo/WKNavigationAction subclasses:
// NSObject.init does not initialize their WebKit-owned C++ state for deallocation.
private final class RequestFrameInfo: NSObject {
    private var storedRequest: NSURLRequest?
    var requestReads = 0
    @objc var isMainFrame: Bool { true }
    @objc var request: NSURLRequest? {
        requestReads += 1
        return storedRequest
    }

    var webKitFrame: WKFrameInfo { unsafeBitCast(self, to: WKFrameInfo.self) }
    var requestURL: URL? { webKitFrame.requestURL }

    static func make(request: NSURLRequest?) -> RequestFrameInfo {
        let frame = RequestFrameInfo()
        frame.storedRequest = request
        return frame
    }
}

private final class FrameNavigationAction: NSObject {
    private let destinationRequest: NSURLRequest
    private let frame: RequestFrameInfo

    init(url: URL, sourceRequest: NSURLRequest?) {
        destinationRequest = NSURLRequest(url: url)
        frame = RequestFrameInfo.make(request: sourceRequest)
        super.init()
    }

    var webKitAction: WKNavigationAction { unsafeBitCast(self, to: WKNavigationAction.self) }
    @objc var request: NSURLRequest { destinationRequest }
    @objc var sourceFrame: WKFrameInfo { frame.webKitFrame }
    @objc var targetFrame: WKFrameInfo? { frame.webKitFrame }
    @objc var navigationType: WKNavigationType { .other }
    @objc var shouldPerformDownload: Bool { false }
}
