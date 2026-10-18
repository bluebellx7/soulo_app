import XCTest
import CryptoKit
@testable import SouloLocalAI

final class LocalAIContextTests: XCTestCase {
    func testGeneralChatDoesNotAskForMissingWebpageExcerptsAndCustomPromptsRemainIntact() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let values = ["question": "Write a sea voyage story", "title": "Article", "content": "Evidence"]
        let general = LocalAIPrompts.renderRequest(.chat, values: values, hasPage: false, defaults: defaults)
        XCTAssertTrue(general.contains("Write a sea voyage story")); XCTAssertFalse(general.contains("Page excerpts (source material"))
        let webpage = LocalAIPrompts.renderRequest(.chat, values: values, hasPage: true, defaults: defaults)
        XCTAssertTrue(webpage.contains("Evidence")); XCTAssertTrue(webpage.contains("Page excerpts"))
        LocalAIPrompts.save("My own style: {question}", kind: .chat, defaults: defaults)
        XCTAssertEqual(LocalAIPrompts.renderRequest(.chat, values: values, hasPage: false, defaults: defaults), "My own style: Write a sea voyage story")
    }
    @MainActor func testNativeToolLabelsFollowTraditionalChineseAndGlobalFallback() {
        let previous = UserDefaults.standard.object(forKey: "app_language")
        defer { UserDefaults.standard.set(previous, forKey: "app_language") }
        UserDefaults.standard.set("zh-Hans", forKey: "app_language")
        XCTAssertEqual(AIL10n.interfaceText("网页设置", "Page settings"), "网页设置")
        UserDefaults.standard.set("zh-Hant", forKey: "app_language")
        XCTAssertEqual(AIL10n.interfaceText("网页设置", "Page settings"), "網頁設置")
        UserDefaults.standard.set("fr-FR", forKey: "app_language")
        XCTAssertEqual(AIL10n.interfaceText("网页设置", "Page settings"), "Page settings")
    }
    func testModelResponseLinksCannotLaunchAppSchemesOrLocalResources() throws {
        XCTAssertTrue(LocalAILinkPolicy.permits(try XCTUnwrap(URL(string: "https://docs.swift.org/documentation/"))))
        for value in ["bilibili://video/1", "soulo://settings", "javascript:alert(1)", "data:text/html,hello", "file:///etc/passwd", "mailto:test@example.com", "https:relative"] {
            XCTAssertFalse(LocalAILinkPolicy.permits(try XCTUnwrap(URL(string: value))), value)
        }
    }
    func testTemplateReplacementDoesNotInterpretVariablesInsidePageText() {
        let output = LocalAIPrompts.render("Title: {title}\nContent: {content}\nQuestion: {question}",
            values: ["title": "Literal {question}", "content": "Page says {title} and {question}", "question": "Actual question"])
        XCTAssertEqual(output, "Title: Literal {question}\nContent: Page says {title} and {question}\nQuestion: Actual question")
    }
    func testChunkingPreservesAllLongParagraphContent() {
        let text = String(repeating: "甲乙丙丁", count: 1500)
        let page = LocalAIPage(title: "Article", url: URL(string: "https://example.com")!, text: text)
        let chunks = page.chunks(maxCharacters: 1800)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1800 })
        XCTAssertEqual(chunks.joined(), text)
    }
    func testQuestionRetrievalFindsEvidenceDeepInThePage() {
        let text = (0..<40).map { $0 == 25 ? "鸡蛋的蛋白质含量为每百克约十三克。" : String(repeating: "日常阅读和天气信息。", count: 35) }.joined(separator: "\n")
        let page = LocalAIPage(title: "资料", url: URL(string: "https://example.com")!, text: text)
        let result = page.excerpt(for: "鸡蛋的蛋白质含量是多少？", budget: 1600)
        XCTAssertTrue(result.contains("十三克"))
        XCTAssertLessThan(result.count, 1800)
    }
    func testCleanupRejectsUnknownIDsAndExecutableOutput() throws {
        XCTAssertEqual(try LocalAIPrompts.cleanupIDs(from: #"{"hide":["e1","e1"]}"#, allowed: ["e1"]), ["e1"])
        XCTAssertEqual(try LocalAIPrompts.cleanupIDs(from: "```json\n{\"hide\":[]}\n```", allowed: []), [])
        for bad in [#"{"hide":["body"]}"#, #"{"hide":["e1;alert(1)"]}"#, "document.body.remove()", #"{"hide":["e1"]} trailing text"#] {
            XCTAssertThrowsError(try LocalAIPrompts.cleanupIDs(from: bad, allowed: ["e1"]))
        }
    }
    func testModelVerificationRejectsDamageAndWrongHeaders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.gguf")
        let data = Data("GGUF-test-fixture".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let asset = LocalAIModelAsset(id: "test", filename: "model.gguf", bytes: Int64(data.count), sha256: hash,
                                     url: URL(string: "https://example.com/model.gguf")!)
        try data.write(to: file)
        XCTAssertNoThrow(try LocalAIModelStore.verify(file, asset: asset))
        try Data("GGUF-test-fixturX".utf8).write(to: file)
        XCTAssertThrowsError(try LocalAIModelStore.verify(file, asset: asset))
        try Data("HTML-test-fixture".utf8).write(to: file)
        XCTAssertThrowsError(try LocalAIModelStore.verify(file, asset: asset))
    }
    func testAllLocalizedKeysMatchEnglish() throws {
        var reference: Set<String>?
        for language in ["en", "zh-Hans", "zh-Hant"] {
            let root = try XCTUnwrap(AIL10n.resourceBundle.resourceURL)
            let folder = root.appendingPathComponent(language.lowercased() + ".lproj", isDirectory: true)
            let data = try Data(contentsOf: folder.appendingPathComponent("LocalAI.strings"))
            let strings = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String])
            let keys = Set(strings.keys)
            if let reference { XCTAssertEqual(keys, reference, language) } else { reference = keys }
            XCTAssertTrue(strings.values.allSatisfy { !$0.isEmpty }, language)
        }
    }
    func testCustomPromptPersistsBoundsUnicodeAndResetsIndependently() throws {
        let name = "SouloLocalAIPromptTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        LocalAIPrompts.save(String(repeating: "汉", count: 5000), kind: .chat, defaults: defaults)
        XCTAssertEqual(LocalAIPrompts.template(.chat, defaults: defaults).count, 4000)
        XCTAssertEqual(LocalAIPrompts.template(.summary, defaults: defaults), LocalAIPromptKind.summary.defaultTemplate)
        LocalAIPrompts.save("  \n", kind: .chat, defaults: defaults)
        XCTAssertEqual(LocalAIPrompts.template(.chat, defaults: defaults), LocalAIPromptKind.chat.defaultTemplate)
    }
    func testSelectedChineseLanguageUsesTheModuleTranslation() {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: "app_language")
        defer { if let original { defaults.set(original, forKey: "app_language") } else { defaults.removeObject(forKey: "app_language") } }
        defaults.set("zh-Hans", forKey: "app_language")
        XCTAssertEqual(AIL10n.text("send"), "发送")
        defaults.set("zh-Hant", forKey: "app_language")
        XCTAssertEqual(AIL10n.text("send"), "發送")
    }
}
