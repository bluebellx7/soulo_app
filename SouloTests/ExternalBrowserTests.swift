import XCTest
@testable import Soulo

@MainActor final class ExternalBrowserTests: XCTestCase {
    func testOtherDefaultBrowserReceivesOriginalURLAndOnlyMatchingReturnUsesSafari() async throws {
        var opened: [URL] = []
        var fallback = false
        let service = ExternalBrowserService(openURL: { opened.append($0); return true })
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=a%2Bb&value=100%25#part"))
        service.open(url, safariFallback: { fallback = true }, onFailure: { XCTFail("Unexpected failure") })
        await settle { opened.count == 1 }
        XCTAssertEqual(opened, [url])
        XCTAssertFalse(service.consumeReturnedURL(URL(string: "https://other.example/path")!))
        XCTAssertTrue(service.consumeReturnedURL(url))
        XCTAssertFalse(service.consumeReturnedURL(url), "A handoff must be consumed only once")
        await settle { opened.count == 2 }
        XCTAssertEqual(opened[1].absoluteString, "x-safari-https://example.com/path?q=a%2Bb&value=100%25#part")
        XCTAssertFalse(fallback)
    }

    func testExpiredAndSupersededRequestsDoNotCaptureOrdinaryIncomingLinks() async throws {
        var now = Date()
        var opened: [URL] = []
        let service = ExternalBrowserService(openURL: { opened.append($0); return true }, now: { now })
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!
        service.open(first, safariFallback: { XCTFail("Unexpected fallback") }, onFailure: {})
        await settle { opened.count == 1 }
        service.open(second, safariFallback: { XCTFail("Unexpected fallback") }, onFailure: {})
        await settle { opened.count == 2 }
        XCTAssertFalse(service.consumeReturnedURL(first))
        now = now.addingTimeInterval(6)
        XCTAssertFalse(service.consumeReturnedURL(second))
    }

    func testHTTPReturnUsesSystemSafariViewWithoutChangingTheAddressToHTTPS() async throws {
        let url = URL(string: "http://example.com:8080/path?q=a%2Bb#part")!
        var opened: [URL] = []
        var fallback = false
        let service = ExternalBrowserService(openURL: { opened.append($0); return true })
        service.open(url, safariFallback: { fallback = true }, onFailure: {})
        await settle { opened.count == 1 }
        XCTAssertTrue(service.consumeReturnedURL(url))
        await settle { fallback }
        XCTAssertEqual(opened, [url])
        XCTAssertNil(ExternalBrowserService.safariURL(for: url))
    }

    func testFailedDefaultHandoffTriesSafariAndUnavailableSafariUsesSystemView() async throws {
        var opened: [URL] = []
        var fallback = false
        let service = ExternalBrowserService(openURL: { opened.append($0); return false })
        let url = URL(string: "https://example.com/path")!
        service.open(url, safariFallback: { fallback = true }, onFailure: { XCTFail("Valid web URL") })
        await settle { fallback }
        XCTAssertEqual(opened.map(\.scheme), ["https", "x-safari-https"])
        XCTAssertFalse(service.consumeReturnedURL(url))
    }

    func testCustomSchemesNeverEnterBrowserHandoff() {
        let service = ExternalBrowserService(openURL: { _ in XCTFail("Unexpected external open"); return true })
        var failed = false
        service.open(URL(string: "some-app://item")!, safariFallback: { XCTFail("Unexpected fallback") }, onFailure: { failed = true })
        XCTAssertTrue(failed)
    }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("External browser handoff did not settle")
    }
}
