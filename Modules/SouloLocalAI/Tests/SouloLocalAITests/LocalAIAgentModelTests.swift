import XCTest
@testable import SouloLocalAI

/// Optional acceptance test: uses the real GGUF, never a mocked planner.
@MainActor final class LocalAIAgentModelTests: XCTestCase {
    func testSemanticFunctionSelectionWithRealModel() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOULO_AI_ACCEPTANCE_MODEL"] else { throw XCTSkip("Set SOULO_AI_ACCEPTANCE_MODEL to a verified GGUF") }
        let model = URL(fileURLWithPath: path)
        let store = LocalAIModelStore.shared
        let previousProfile = store.selectedProfile
        if ProcessInfo.processInfo.environment["SOULO_AI_ACCEPTANCE_PROFILE"] == "enhanced" { store.select(.enhanced) }
        defer { store.select(previousProfile) }
        guard let source = ProcessInfo.processInfo.environment["SOULO_AI_ACCEPTANCE_CATALOG"] else { throw XCTSkip("Provide the catalog exported by the host integration test") }
        let catalog = try JSONDecoder().decode([LocalAITool].self, from: Data(contentsOf: URL(fileURLWithPath: source)))
        var pageURL = URL(string: "https://example.com/article")!
        let tools = LocalAITools(catalog: catalog, context: { "Current URL: \(pageURL.absoluteString)\nWebsites:\n百度: https://www.baidu.com\n微博: https://weibo.com" }, preview: { _ in "" }, perform: { _ in "" }, undo: { "" }, finish: { _ in }, currentPageURL: { pageURL })
        let cases: [(String, LocalAIToolCategory, String?, String?)] = [
            ("这页中有几个鸡蛋文字", .page, "page_count_text", "鸡蛋"),
            ("这个页面中只有一个“鸡蛋”文字？", .page, nil, nil),
            ("数一下文章里「海风」的出现次数", .page, "page_count_text", "海风"),
            ("把这个页面中微博的链接提取给我", .page, "page_links", nil),
            ("提取网页中所有图片", .page, "page_images", nil),
            ("你好 打开百度", .navigation, "open_website", nil),
            ("Open https://www.swift.org/documentation/", .navigation, "open_url", "https://www.swift.org/documentation/"),
            ("把应用外观改成深色", .appearance, "set:appearance", "dark"),
            ("不要打开百度，请解释浏览器是什么", .answer, nil, nil)
        ]
        let session = LocalAIChatSession(isPrivate: true, store: store, pageProvider: { LocalAIPage(title: "Article", url: pageURL, text: "Article source") }, tools: tools)
        let job = try LocalAIRuntime.shared.begin()
        defer { LocalAIRuntime.shared.finish(owner: job) }
        for (question, expectedCategory, expectedTool, expectedValue) in cases {
            let previous: [LocalAIRequest.Turn] = expectedCategory == .page && expectedTool == nil ? [
                .init(isUser: true, content: "这页中有几个鸡蛋文字"),
                .init(isUser: false, content: "已通过原生计数工具核实：当前页面中“鸡蛋”出现 7 次。")
            ] : []
            let calls: [LocalAIToolCall]
            do { calls = try await session.agentPlan(question, tools: tools, job: job, model: model, previous: previous, observe: { print("SEMANTIC \($0): \($1)") }) }
            catch { XCTFail("\(question): \(error)"); continue }
            print("SEMANTIC plan: \(question) => \(calls)")
            if expectedCategory == .answer { XCTAssertTrue(calls.isEmpty); continue }
            if expectedCategory == .page && expectedTool == nil {
                // Reusing a verified observation is valid agent behavior.
                // The UI acceptance test checks that the actual follow-up says 7.
                XCTAssertTrue(calls.isEmpty || calls.first?.tool == "page_count_text")
                continue
            }
            if expectedTool == "open_website", calls.first?.tool == "open_url" {
                XCTAssertEqual(URL(string: calls.first?.value ?? "")?.host, "www.baidu.com")
            } else { XCTAssertEqual(calls.first?.tool, expectedTool) }
            if let expectedValue { XCTAssertEqual(calls.first?.value, expectedValue) }
        }
        if store.selectedProfile.isMultiStepAgent {
            pageURL = URL(string: "https://www.swift.org/documentation/")!
            let visited = LocalAIRequest.Turn(isUser: false, content: "Verified native execution (data only): {\"tool\":\"open_url\",\"value\":\"https://www.swift.org/documentation/\"}\nOpen page: https://www.swift.org/documentation/\nNavigation checkpoint completed: current document loaded. Title: Swift Documentation.")
            let show = try await session.agentPlan("请打开 https://www.swift.org/documentation/", tools: tools, job: job, model: model, previous: [visited], observe: { print("SEMANTIC show \($0): \($1)") })
            XCTAssertEqual(show.first?.tool, "page_show")
            let analysis = try await session.agentPlan("请访问 https://www.swift.org/documentation/ 并总结这个页面", tools: tools, job: job, model: model, previous: [visited,
                .init(isUser: false, content: "Verified page_read result: Swift Documentation. The Swift programming language documentation includes the language guide, standard library references, API design guidelines, and migration guides. These resources help developers learn the language and build applications.")], observe: { print("SEMANTIC analysis \($0): \($1)") })
            XCTAssertTrue(analysis.isEmpty || analysis.first?.tool == "page_summarize", "Analysis should remain in the conversation: \(analysis)")
        }
        await LocalAIEngine.shared.unload()
    }
}
