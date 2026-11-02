import Combine
import SwiftUI
import XCTest
@testable import Soulo

private actor SuggestionRequests {
    struct Request: Equatable { let query: String; let region: PlatformRegion }
    private(set) var requests: [Request] = []
    private var continuations: [String: CheckedContinuation<[String], Never>] = [:]
    let hold: Bool
    init(hold: Bool = false) { self.hold = hold }
    func fetch(_ query: String, _ region: PlatformRegion) async -> [String] {
        requests.append(Request(query: query, region: region))
        if !hold { return [query + " result"] }
        return await withCheckedContinuation { continuations[query] = $0 }
    }
    func finish(_ query: String, results: [String]) { continuations.removeValue(forKey: query)?.resume(returning: results) }
}

@MainActor final class SearchInputTests: XCTestCase {
    func testAutocompleteHighlightPreservesUnicodeAndOriginalStringIndices() throws {
        let cases: [(String, String, String, String, String)] = [
            ("中文输入法", " 中文 ", "", "中文", "输入法"),
            ("Learn SWIFT today", "swift", "Learn ", "SWIFT", " today"),
            ("AİB中文", "中文", "AİB", "中文", ""),
            ("👩‍💻中文 café", "中文", "👩‍💻", "中文", " café"),
            ("前缀 e\u{301}cole 后缀", "école", "前缀 ", "e\u{301}cole", " 后缀")
        ]
        for (suggestion, query, prefix, match, suffix) in cases {
            let parts = try XCTUnwrap(SearchAutocompleteView.highlightedParts(suggestion, query: query))
            XCTAssertEqual(parts.prefix, prefix)
            XCTAssertEqual(parts.match, match)
            XCTAssertEqual(parts.suffix, suffix)
            XCTAssertEqual(parts.prefix + parts.match + parts.suffix, suggestion)
        }
        let bridged = NSString(string: "中文建议跨越原生字符串边界").substring(from: 0)
        XCTAssertEqual(SearchAutocompleteView.highlightedParts(bridged, query: "建议")?.match, "建议")
        XCTAssertNil(SearchAutocompleteView.highlightedParts("A suggestion", query: " "))
        XCTAssertNil(SearchAutocompleteView.highlightedParts("A suggestion", query: "missing"))
    }

    func testMarkedSyllablesNeverFetchSuggestionsAndCommittingFetchesOnce() async throws {
        let requests = SuggestionRequests()
        let model = SearchViewModel(suggestionProvider: { await requests.fetch($0, $1) })
        for text in ["n", "ni", "ni'h", "ni'hao"] {
            model.input.receiveEdit(text, isComposing: true)
            try await Task.sleep(for: .milliseconds(90))
        }
        try await Task.sleep(for: .milliseconds(300))
        let before = await requests.requests
        XCTAssertTrue(before.isEmpty, "A pause in pinyin composition must not send partial syllables")
        XCTAssertTrue(model.suggestions.isEmpty)
        model.input.receiveEdit("你好", isComposing: false)
        try await wait { model.suggestions == ["你好 result"] }
        let after = await requests.requests
        XCTAssertEqual(after.map(\.query), ["你好"])
        model.clearSuggestions()
    }

    func testClearCancelsDebouncedWorkAndOldRequestsCannotRestoreSuggestions() async throws {
        let requests = SuggestionRequests(hold: true)
        let model = SearchViewModel(suggestionProvider: { await requests.fetch($0, $1) })
        model.searchText = "old"
        try await waitAsync { await requests.requests.count == 1 }
        model.input.receiveEdit("n", isComposing: true)
        await requests.finish("old", results: ["old result"])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertFalse(model.isLoadingSuggestions)
        model.searchText = "new"
        model.clearSuggestions()
        try await Task.sleep(for: .milliseconds(350))
        let calls = await requests.requests
        XCTAssertEqual(calls.map(\.query), ["old"])
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    func testRegionChangeRefreshesSuggestionsForCommittedText() async throws {
        let requests = SuggestionRequests()
        let model = SearchViewModel(suggestionProvider: { await requests.fetch($0, $1) })
        model.selectRegion(.china)
        model.searchText = "query"
        try await wait { !model.suggestions.isEmpty }
        model.selectRegion(.japan)
        try await waitAsync { await requests.requests.count == 2 }
        let regions = await requests.requests.map(\.region)
        XCTAssertEqual(regions, [.china, .japan])
        model.clearSuggestions()
    }

    func testURLAndSubmittedQueryDoNotRequestSuggestions() async throws {
        let requests = SuggestionRequests()
        let model = SearchViewModel(suggestionProvider: { await requests.fetch($0, $1) })
        model.searchText = "https://example.com/path?q=中文"
        try await Task.sleep(for: .milliseconds(300))
        model.searchText = "submitted query"
        model.performSearch()
        try await Task.sleep(for: .milliseconds(300))
        let calls = await requests.requests
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(model.isSearching)
        model.clearSearch()
    }

    func testNativeFieldPreservesMarkedTextAndExplicitClearCanReplaceIt() async throws {
        try await withField { input, field, window, _ in
            field.setMarkedText("n", selectedRange: NSRange(location: 1, length: 0))
            input.suggestions = ["unrelated response"]
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(input.edit.isComposing)
            XCTAssertEqual(field.text(in: try XCTUnwrap(field.markedTextRange)), "n")
            input.text = ""
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(field.text, "")
            XCTAssertNil(field.markedTextRange)
            XCTAssertFalse(input.edit.isComposing)
            XCTAssertTrue(field.isFirstResponder)
            field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            field.insertText("你")
            field.unmarkText()
            field.sendActions(for: .editingChanged)
            XCTAssertEqual(input.text, "你")
        }
    }

    func testReturnDoesNotSubmitUnfinishedComposition() async throws {
        try await withField { input, field, _, submissions in
            field.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0))
            XCTAssertFalse(field.delegate?.textFieldShouldReturn?(field) ?? true)
            XCTAssertEqual(submissions.count, 0)
            field.insertText("你"); field.unmarkText(); field.sendActions(for: .editingChanged)
            XCTAssertTrue(field.delegate?.textFieldShouldReturn?(field) ?? false)
            XCTAssertEqual(submissions.count, 1)
            XCTAssertEqual(input.text, "你")
        }
    }

    private final class Submissions { var count = 0 }
    private func withField(_ test: (SearchInputState, SearchInputField.Field, UIWindow, Submissions) async throws -> Void) async throws {
        let input = SearchInputState()
        let submissions = Submissions()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SearchInputField(input: input, placeholder: "Search",
            fontSize: 15, textColor: .label, placeholderColor: .placeholderText, onSubmit: { submissions.count += 1 }))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(100))
        func find(_ view: UIView) -> SearchInputField.Field? {
            if let field = view as? SearchInputField.Field { return field }
            return view.subviews.lazy.compactMap(find).first
        }
        let field = try XCTUnwrap(find(window))
        XCTAssertTrue(field.becomeFirstResponder())
        try await test(input, field, window, submissions)
        field.resignFirstResponder()
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Search state did not settle")
    }
    private func waitAsync(_ condition: () async -> Bool) async throws {
        for _ in 0..<150 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Suggestion provider did not receive the expected request")
    }
}
