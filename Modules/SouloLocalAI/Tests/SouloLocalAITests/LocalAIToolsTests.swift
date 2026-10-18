import XCTest
@testable import SouloLocalAI

@MainActor final class LocalAIToolsTests: XCTestCase {
    func testPlansOnlyAllowRegisteredToolsAndBoundArguments() throws {
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"tab_switch","value":"2"},{"tool":"page_images"}]}"#, allowed: ["tab_switch", "page_images"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"page_reload"},{"tool":"set:page_zoom","value":"1.5"}]}"#, allowed: ["page_reload", "set:page_zoom"]))
        XCTAssertEqual(try LocalAITools.calls(from: #"{"actions":[{"tool":"open_url","value":"https://example.com"}]}"#, allowed: ["open_url"]), [.init(tool: "open_url", value: "https://example.com")])
        for value in [#"{"actions":[{"tool":"delete_all_files"}]}"#, #"{"actions":[{"tool":"javascript","value":"alert(1)"}]}"#, "window.open('x')", #"{"actions":[]} trailing"#] {
            XCTAssertThrowsError(try LocalAITools.calls(from: value, allowed: ["open_url"]))
        }
        let oversized = try JSONEncoder().encode(["actions": [["tool": "open_url", "value": String(repeating: "x", count: 2001)]]])
        XCTAssertThrowsError(try LocalAITools.calls(from: String(decoding: oversized, as: UTF8.self), allowed: ["open_url"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"feature:settings"},{"tool":"feature:files"}]}"#, allowed: ["feature:settings", "feature:files"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"feature:settings"},{"tool":"open_url","value":"https://example.com"}]}"#, allowed: ["feature:settings", "open_url"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"open_website","value":"Baidu"},{"tool":"page_count_text","value":"test"}]}"#, allowed: ["open_website", "page_count_text"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"page_images"},{"tool":"page_summarize"}]}"#, allowed: ["page_images", "page_summarize"]))
    }
    func testModelSelectedGroupsExposeOnlyTheirRegisteredCapabilities() {
        let tools = LocalAITools(catalog: [.init("page_links", title: "Links", category: .page), .init("files_list", title: "Files", category: .files)], context: { "" }, preview: { _ in "" }, perform: { _ in "" }, undo: { "" }, finish: { _ in })
        XCTAssertEqual(Set(tools.categories), [.answer, .page, .files])
        XCTAssertEqual(tools.offered(in: .page).map(\.id), ["page_links"])
        XCTAssertTrue(tools.offered(in: .privacy).isEmpty)
    }
    func testFunctionSelectionRejectsUnknownToolsAndMixedAnswerActions() throws {
        XCTAssertEqual(try LocalAIPlanner.selection(from: #"{"tools":["page_links"]}"#, allowed: ["page_links"]), ["page_links"])
        XCTAssertTrue(try LocalAIPlanner.selection(from: #"{"tools":["answer"]}"#, allowed: ["page_links"]).isEmpty)
        for output in [#"{"tools":["shell"]}"#, #"{"tools":["answer","page_links"]}"#, "alert(1)", #"{"tools":["page_links"]} trailing"#] {
            XCTAssertThrowsError(try LocalAIPlanner.selection(from: output, allowed: ["page_links"]))
        }
    }
    func testToolArgumentsPreserveLiteralUnicodeAndURLs() throws {
        let calls = try LocalAITools.calls(from: #"{"actions":[{"tool":"page_count_text","value":"雞蛋"}]}"#, allowed: ["page_count_text"])
        XCTAssertEqual(calls.first?.value, "雞蛋")
        XCTAssertEqual(try LocalAITools.calls(from: #"{"actions":[{"tool":"page_count_text","text":"雞蛋"}]}"#, allowed: ["page_count_text"]).first?.value, "雞蛋")
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"page_count_text","text":"a","value":"b"}]}"#, allowed: ["page_count_text"]))
        XCTAssertThrowsError(try LocalAITools.calls(from: #"{"actions":[{"tool":"page_images"},{"tool":"open_url","value":"https://example.com"}]}"#, allowed: ["page_images", "open_url"]))
    }
    func testHalfDockingKeepsFullTouchTargetInsideBothEdgesAndDragWithinScreen() {
        for size in [CGSize(width: 402, height: 800), CGSize(width: 874, height: 350)] {
            for right in [false, true] {
                let center = LocalAICompanionLayout.center(in: size, right: right, fraction: 0.5, drag: .zero)
                XCTAssertEqual(center.x, right ? size.width : 0)
                let hit = LocalAICompanionLayout.hitCenter(center, in: size)
                XCTAssertGreaterThanOrEqual(hit.x - 22, 0); XCTAssertLessThanOrEqual(hit.x + 22, size.width)
                let dragging = LocalAICompanionLayout.center(in: size, right: right, fraction: .infinity, drag: CGSize(width: 5000, height: -5000))
                XCTAssertGreaterThanOrEqual(dragging.x - 24, 0); XCTAssertLessThanOrEqual(dragging.x + 24, size.width)
                XCTAssertGreaterThanOrEqual(dragging.y - 32, 0)
            }
        }
    }
    func testOlderHistoryWithoutLinkResultsStillLoadsAndNewResultsRoundTrip() throws {
        let old = Data(#"{"id":"FE0D5810-6D01-48EC-8C61-77A63D11DB49","role":"assistant","content":"Previous answer"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(LocalAIMessage.self, from: old).linkResult)
        var message = LocalAIMessage(role: "assistant", content: "Found 1 link")
        let source = URL(string: "https://example.org/article")!
        message.linkResult = .init(links: [.init(title: "Source", url: source)], sourceURL: source, filter: "example.org", limited: false)
        let restored = try JSONDecoder().decode(LocalAIMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(restored.linkResult?.links.first?.url, source)
        XCTAssertEqual(restored.linkResult?.filter, "example.org")
    }
}
