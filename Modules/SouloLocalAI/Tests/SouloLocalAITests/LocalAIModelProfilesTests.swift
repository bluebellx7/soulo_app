import XCTest
import CryptoKit
@testable import SouloLocalAI

@MainActor final class LocalAIModelProfilesTests: XCTestCase {
    private func installedProfiles() async throws -> (URL, LocalAIModelStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let definitions = [.language] + LocalAIModelProfile.enhanced.languageAssets
        let assets = try definitions.map { original -> LocalAIModelAsset in
            let data = Data((original.kind == .gguf ? "GGUFtest" : "{\"fixture\":true}").utf8)
            let target = root.appendingPathComponent(original.filename)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return .init(id: original.id, filename: original.filename, bytes: Int64(data.count), sha256: hash, url: URL(string: "https://example.invalid/test")!, kind: original.kind)
        }
        let store = LocalAIModelStore(directory: root, assets: assets, configuration: .ephemeral)
        store.select(.light)
        for _ in 0..<300 where assets.contains(where: { store.statuses[$0.id] != .installed }) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(store.modelURL(for: .light)); XCTAssertNotNil(store.modelURL(for: .enhanced))
        return (root, store)
    }

    func testPinnedExpertCatalogAndSeparateVision() throws {
        let profile = LocalAIModelProfile.enhanced
        XCTAssertEqual(LocalAIModelAsset.enhancedAssets.count, 43)
        XCTAssertEqual(profile.languageAssets.count, 42)
        XCTAssertEqual(profile.languageAssets.filter { $0.kind == .expert }.count, 40)
        XCTAssertEqual(profile.languageAssets.filter { $0.kind == .manifest }.count, 1)
        XCTAssertEqual(profile.downloadBytes, 15_504_009_668)
        XCTAssertNotNil(profile.visionAsset)
        XCTAssertFalse(profile.languageAssets.contains { $0.id == profile.visionAsset?.id })
        XCTAssertEqual(Set(LocalAIModelAsset.catalog.map(\.id)).count, LocalAIModelAsset.catalog.count)
        for asset in LocalAIModelAsset.enhancedAssets {
            XCTAssertEqual(asset.sha256.count, 64)
            XCTAssertTrue(asset.filename.hasPrefix("35B-A3B/")); XCTAssertFalse(asset.filename.contains(".."))
            XCTAssertTrue(asset.url.path.contains("8716e5209f308fd53f197ccd7d50c6fdcc2dc37d"))
            XCTAssertTrue(asset.downloadURL(source: .modelScope).path.contains("MiniCPM-V-4.7-35B-A3B/"))
        }
    }
    func testHomeKeepsDynamicPageProviderWithoutReadingAMissingPage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root, assets: [], configuration: .ephemeral)
        var reads = 0
        let tools = LocalAITools(catalog: [], context: { "" }, preview: { _ in "" }, perform: { _ in "" }, undo: { "" }, finish: { _ in }, currentPageURL: { nil })
        let session = LocalAIChatSession(isPrivate: true, store: store, pageProvider: { reads += 1; throw LocalAIError.pageChanged }, tools: tools)
        XCTAssertFalse(session.hasPageProvider)
        await session.preparePage()
        XCTAssertEqual(reads, 0); XCTAssertNil(session.page); XCTAssertNil(session.error)
    }
    func testRecoveryDistinguishesEqualSizeExpertShards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func asset(_ id: String, content: String) -> LocalAIModelAsset {
            let data = Data(content.utf8)
            return .init(id: id, filename: id + ".bin", bytes: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), url: URL(string: "https://example.invalid/" + id)!, kind: .expert)
        }
        let first = asset("shard-one", content: "aaaa"), second = asset("shard-two", content: "bbbb")
        let staged = root.appendingPathComponent(second.id + "." + UUID().uuidString + ".download")
        try Data("bbbb".utf8).write(to: staged)
        let store = LocalAIModelStore(directory: root, assets: [first, second], configuration: .ephemeral)
        for _ in 0..<100 where store.statuses[second.id] != .installed { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(store.statuses[first.id], .missing)
        XCTAssertEqual(store.statuses[second.id], .installed)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.installedURL(for: second))), Data("bbbb".utf8))
    }

    func testAgentDoesNotAttachPageTextWhenAttachmentIsOff() async throws {
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.model")
        let enabled = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.model"); UserDefaults.standard.set(enabled, forKey: "soulo.localAI.enabled") }
        let (root, store) = try await installedProfiles(); defer { try? FileManager.default.removeItem(at: root) }
        store.select(.enhanced); UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled")
        var performed = 0, reads = 0
        let url = URL(string: "https://example.com")!
        let tools = LocalAITools(catalog: [.init("first", title: "First"), .init("second", title: "Second")], context: { "" }, preview: { $0.tool }, perform: { call in performed += 1; return call.tool }, undo: { "" }, finish: { _ in }, checkpoint: { _ in performed < 2 }, currentPageURL: { url })
        let session = LocalAIChatSession(isPrivate: true, store: store, pageProvider: {
            reads += 1; return LocalAIPage(title: "Private source", url: url, text: "Must not be attached automatically")
        }, tools: tools, plan: { _, _ in [.init(tool: performed == 0 ? "first" : "second")] })
        session.attachPage = false
        session.run(.chat, question: "Perform the two requested settings changes")
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(performed, 2); XCTAssertEqual(reads, 0); XCTAssertNil(session.error)
    }

    func testMissingExpertPreventsReadinessWithoutAffectingLightModel() async throws {
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.model")
        defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.model") }
        let (root, store) = try await installedProfiles(); defer { try? FileManager.default.removeItem(at: root) }
        store.select(.enhanced)
        XCTAssertNotNil(store.selectedModelURL)
        let shard = try XCTUnwrap(LocalAIModelProfile.enhanced.languageAssets.first { $0.kind == .expert })
        try FileManager.default.removeItem(at: root.appendingPathComponent(shard.filename))
        XCTAssertNil(store.selectedModelURL)
        XCTAssertNotEqual(store.status(for: .enhanced), .installed)
        XCTAssertNotNil(store.modelURL(for: .light))
        XCTAssertNil(store.selectedVisionURL)
    }

    func testAgentObservesEachStepBeforeChoosingNextFunction() async throws {
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.model")
        let enabled = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.model"); UserDefaults.standard.set(enabled, forKey: "soulo.localAI.enabled") }
        let (root, store) = try await installedProfiles(); defer { try? FileManager.default.removeItem(at: root) }
        store.select(.enhanced); UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled")
        var performed: [String] = [], finished: [LocalAIToolCall] = [], plans = 0, legacyFinishes = 0
        let tools = LocalAITools(catalog: [.init("navigate", title: "Navigate"), .init("inspect", title: "Inspect")], context: { performed.joined() }, preview: { $0.tool }, perform: { call in
            performed.append(call.tool); return "Verified " + call.tool
        }, undo: { "" }, finish: { _ in legacyFinishes += 1 }, checkpoint: { _ in performed.count < 2 }, finishAgent: { finished = $0 })
        let session = LocalAIChatSession(isPrivate: true, store: store, tools: tools, plan: { _, _ in
            plans += 1; XCTAssertEqual(performed.count, plans - 1)
            return [.init(tool: plans == 1 ? "navigate" : "inspect")]
        })
        session.run(.chat, question: "Complete the requested task")
        for _ in 0..<300 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(session.error); XCTAssertEqual(performed, ["navigate", "inspect"])
        XCTAssertEqual(finished.map(\.tool), performed); XCTAssertEqual(legacyFinishes, 0)
        XCTAssertTrue(session.messages.last?.content.contains("Verified navigate") == true)
        XCTAssertTrue(session.messages.last?.content.contains("Verified inspect") == true)
    }

    func testAgentWaitsForReviewBeforeChangingPrivateSettings() async throws {
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.model")
        let enabled = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.model"); UserDefaults.standard.set(enabled, forKey: "soulo.localAI.enabled") }
        let (root, store) = try await installedProfiles(); defer { try? FileManager.default.removeItem(at: root) }
        store.select(.enhanced); UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled")
        var performed: [String] = []
        let tools = LocalAITools(catalog: [.init("observe", title: "Observe"), .init("private_change", title: "Private setting", confirmation: true)], context: { "" }, preview: { $0.tool }, perform: { call in performed.append(call.tool); return call.tool }, undo: { "" }, finish: { _ in }, checkpoint: { _ in true })
        let session = LocalAIChatSession(isPrivate: true, store: store, tools: tools, plan: { _, _ in
            [.init(tool: performed.isEmpty ? "observe" : "private_change")]
        })
        session.run(.chat, question: "Change the requested setting")
        for _ in 0..<300 where session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(performed, ["observe"])
        XCTAssertEqual(session.pendingCalls.map(\.tool), ["private_change"])
        session.cancelPendingTools(); XCTAssertEqual(performed, ["observe"])
    }
}
