import XCTest
import UniformTypeIdentifiers
@testable import Soulo

@MainActor
final class ShareContentLoaderTests: XCTestCase {
    private let address = "https://a-stock-screener.app.workbuddy.host/?q=a%2Bb&percent=100%25#part"

    private func item(_ providers: NSItemProvider...) -> NSExtensionItem {
        let item = NSExtensionItem()
        item.attachments = providers
        return item
    }

    private func assertURL(_ action: SouloSharedAction?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(action?.kind, .openURL, file: file, line: line)
        XCTAssertEqual(action?.text, address, file: file, line: line)
    }

    func testGenericTextProviderThatDoesNotConformToPlainTextOpensTheLink() async {
        let provider = NSItemProvider(item: address as NSString, typeIdentifier: UTType.text.identifier)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                       "This host representation was skipped by build 31.")
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testURLDataProviderOpensTheOriginalEncodedAddress() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { reply in
            reply(Data(self.address.utf8), nil); return nil
        }
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testGenericTextDataAndTitleAreReadAsALink() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.text.identifier, visibility: .all) { reply in
            reply(Data("A股技术面筛选器\n\(self.address)".utf8), nil); return nil
        }
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testUTF16TextPreservesURLInsteadOfUsingUTF8WithNullBytes() async throws {
        let provider = NSItemProvider(item: try XCTUnwrap(address.data(using: .utf16)) as NSData,
                                      typeIdentifier: UTType.utf16ExternalPlainText.identifier)
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testAttributedTextUsesItsLinkAttribute() async {
        let text = NSAttributedString(string: "A股技术面筛选器", attributes: [.init("NSLink"): URL(string: address)!])
        let provider = NSItemProvider(item: text, typeIdentifier: UTType.text.identifier)
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testBodyTextWithoutAnAttachmentStillOpensTheLink() async {
        let item = NSExtensionItem()
        item.attributedContentText = NSAttributedString(string: address)
        assertURL(await SouloShareContentLoader.action(from: [item]))
    }

    func testURLAttachmentWinsOverTheFirstProviderTitle() async {
        let title = NSItemProvider(item: "A股技术面筛选器" as NSString, typeIdentifier: UTType.text.identifier)
        let link = NSItemProvider(item: URL(string: address)! as NSURL, typeIdentifier: UTType.url.identifier)
        assertURL(await SouloShareContentLoader.action(from: [item(title), item(link)]))
    }

    func testTemporaryTextFileIsReadBeforeItsProviderIsCompleted() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data(address.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = NSItemProvider(item: file as NSURL, typeIdentifier: UTType.text.identifier)
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testJavaScriptWebPageResultsUseURLInsteadOfTitleOrPreview() async {
        let results = ["NSExtensionJavaScriptPreprocessingResultsKey":
            ["url": address, "title": "A股技术面筛选器", "image": "https://example.com/icon.png"]] as NSDictionary
        let provider = NSItemProvider(item: results, typeIdentifier: UTType.propertyList.identifier)
        assertURL(await SouloShareContentLoader.action(from: [item(provider)]))
    }

    func testFileURLAndImageOnlyItemsAreNotTurnedIntoSearches() async {
        let provider = NSItemProvider(item: URL(fileURLWithPath: "/tmp/private.txt") as NSURL,
                                      typeIdentifier: UTType.fileURL.identifier)
        let result = await SouloShareContentLoader.action(from: [item(provider)])
        XCTAssertNil(result)
    }

    func testUnresponsiveProviderHasABoundedDeadlineAndIgnoresLateReplies() async {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.text.identifier, visibility: .all) { reply in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { reply(Data(self.address.utf8), nil) }
            return Progress(totalUnitCount: 1)
        }
        let start = Date()
        let result = await SouloShareContentLoader.action(from: [item(provider)], timeout: 0.03)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try? await Task.sleep(nanoseconds: 300_000_000)
        // A late callback must not crash by resuming the continuation twice.
    }

    func testOversizedOrBinaryContentIsRejectedButPlainSearchTextStillWorks() async {
        XCTAssertNil(SouloShareContentLoader.decodedText(Data(repeating: 1, count: 64_001), identifier: UTType.text.identifier))
        XCTAssertNil(SouloShareContentLoader.decodedText(Data([0, 1, 0, 2]), identifier: UTType.text.identifier))
        let provider = NSItemProvider(item: "search this phrase" as NSString, typeIdentifier: UTType.text.identifier)
        let action = await SouloShareContentLoader.action(from: [item(provider)])
        XCTAssertEqual(action?.kind, .search)
        XCTAssertEqual(action?.text, "search this phrase")
    }
}
