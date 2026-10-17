import UIKit
import XCTest

@MainActor
private final class URLOpeningResponder: UIResponder {
    var receivedURL: URL?
    var receivedOptions: [String: Any]?
    var calls = 0

    @objc(openURL:options:completionHandler:)
    func open(_ url: URL, options: [String: Any]?, completion: ((Bool) -> Void)?) {
        receivedURL = url
        receivedOptions = options
        calls += 1
        completion?(true)
    }
}

@MainActor
private final class ChainedResponder: UIResponder {
    var destination: UIResponder?
    override var next: UIResponder? { destination }
}

@MainActor
private final class WrongSignatureResponder: UIResponder {
    var calls = 0
    @objc(openURL:options:completionHandler:)
    func wrong(_ value: Int, options: Int, completion: Int) { calls += 1 }
}

@MainActor
final class ExtensionURLOpenerTests: XCTestCase {
    func testModernURLRequestTraversesRespondersAndPreservesTheExactLink() throws {
        let root = ChainedResponder(), intermediate = ChainedResponder(), opener = URLOpeningResponder()
        root.destination = intermediate; intermediate.destination = opener
        let url = try XCTUnwrap(URL(string: "soulo://action?id=EDE6575C-E27A-4387-8626-453611017856"))
        XCTAssertTrue(SouloExtensionURLOpener.requestOpen(url, from: root))
        XCTAssertEqual(opener.receivedURL, url)
        XCTAssertEqual(opener.calls, 1)
        XCTAssertNil(opener.receivedOptions)
    }

    func testMissingHostOpenerReturnsFalseForTheExistingFallback() throws {
        XCTAssertFalse(SouloExtensionURLOpener.requestOpen(try XCTUnwrap(URL(string: "soulo://action?id=123")), from: UIResponder()))
    }

    func testUnexpectedMethodSignatureIsNotInvoked() throws {
        let root = ChainedResponder(), wrong = WrongSignatureResponder()
        root.destination = wrong
        XCTAssertFalse(SouloExtensionURLOpener.requestOpen(try XCTUnwrap(URL(string: "soulo://action?id=123")), from: root))
        XCTAssertEqual(wrong.calls, 0)
    }

    func testOnlyContainingAppActionLinksCanUseTheOpener() throws {
        let root = ChainedResponder(), opener = URLOpeningResponder()
        root.destination = opener
        for target in ["https://example.com", "soulo://downloads", "otherapp://action"] {
            XCTAssertFalse(SouloExtensionURLOpener.requestOpen(try XCTUnwrap(URL(string: target)), from: root))
        }
        XCTAssertEqual(opener.calls, 0)
    }
}
