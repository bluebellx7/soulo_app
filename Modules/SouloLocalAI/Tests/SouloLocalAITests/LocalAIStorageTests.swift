import XCTest
import CryptoKit
@testable import SouloLocalAI

@MainActor final class LocalAIStorageTests: XCTestCase {
    func testCleanupAppliesAllowedElementsImmediatelyAndCanUndo() async throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        var applied: [String] = [], revision = "", restored = false
        let session = LocalAIChatSession(isPrivate: true, store: store, applyCleanup: { ids, token in
            applied = ids; revision = token; return ids.count
        }, undoCleanup: { restored = true })
        let page = LocalAIPage(title: "Page", url: URL(string: "https://example.com")!, text: "Article", revision: "current",
            elements: [.init(id: "e0", text: "Advertisement", hint: "div.ad")])
        let count = try await session.removeAds(response: #"{"hide":["e0","e0"]}"#, from: page)
        XCTAssertEqual(count, 1); XCTAssertEqual(applied, ["e0"]); XCTAssertEqual(revision, "current")
        XCTAssertEqual(session.removedAds, 1); XCTAssertTrue(session.canUndo)
        await session.undo()
        XCTAssertTrue(restored); XCTAssertFalse(session.canUndo)
    }
    func testCleanupRejectsUnknownElementsAndDoesNotApplyEmptyOrCancelledOutput() async throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        var calls = 0
        let session = LocalAIChatSession(isPrivate: true, store: store, applyCleanup: { _, _ in calls += 1; return 1 })
        let page = LocalAIPage(title: "Page", url: URL(string: "https://example.com")!, text: "Article", revision: "current",
            elements: [.init(id: "e0", text: "Advertisement", hint: "div.ad")])
        do { _ = try await session.removeAds(response: #"{"hide":["article"]}"#, from: page); XCTFail("Unknown elements must not be applied") } catch {}
        _ = try await session.removeAds(response: #"{"hide":[]}"#, from: page)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await session.removeAds(response: #"{"hide":["e0"]}"#, from: page); XCTFail("Cancelled actions must not mutate the page") }
            catch is CancellationError {} catch { XCTFail(error.localizedDescription) }
        }
        await task.value
        XCTAssertEqual(calls, 0); XCTAssertFalse(session.canUndo)
    }
    private func fixture() throws -> (URL, URL, LocalAIModelAsset) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.gguf")
        let data = Data("GGUF-local-model-fixture".utf8)
        try data.write(to: source)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (root, source, .init(id: "fixture", filename: "model.gguf", bytes: Int64(data.count), sha256: sha,
                                  url: URL(string: "https://example.com/fixture.gguf")!))
    }
    private func waitForVerification(_ store: LocalAIModelStore, _ asset: LocalAIModelAsset) async throws {
        for _ in 0..<100 {
            if store.statuses[asset.id] != .verifying { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Verification did not complete")
    }
    func testImportRelaunchAndDeleteRetainsOnlyVerifiedModels() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        try await store.importFile(source)
        XCTAssertEqual(store.statuses[asset.id], .installed)
        let relaunched = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        XCTAssertNotNil(relaunched.installedURL(for: asset))
        await relaunched.delete(asset)
        XCTAssertNil(relaunched.installedURL(for: asset))
        XCTAssertFalse(relaunched.hasLocalData(for: asset))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testInterruptedTransferRecoversWithoutDownloadingAgain() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent("staged.download"))
        try Data("staged.download".utf8).write(to: directory.appendingPathComponent(asset.id + ".pending"))
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        XCTAssertEqual(store.statuses[asset.id], .verifying)
        try await waitForVerification(store, asset)
        XCTAssertEqual(store.statuses[asset.id], .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("staged.download").path))
    }
    func testUnmarkedFileIsVerifiedBeforeUseAndCorruptionIsRejected() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try Data(contentsOf: source); data[data.count - 1] = 0
        try data.write(to: directory.appendingPathComponent(asset.filename))
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        XCTAssertNil(store.installedURL(for: asset))
        try await waitForVerification(store, asset)
        XCTAssertNil(store.installedURL(for: asset))
        if case .failed = store.statuses[asset.id] {} else { XCTFail("Corrupt model was accepted") }
    }
    func testTransferWithoutSidecarRecoversAndPartialStagingDoesNotLeakStorage() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let complete = directory.appendingPathComponent(UUID().uuidString + ".download")
        let partial = directory.appendingPathComponent(UUID().uuidString + ".download")
        let unrelated = directory.appendingPathComponent("notes.download")
        try FileManager.default.copyItem(at: source, to: complete)
        try Data("GGUF".utf8).write(to: partial)
        try Data("Preserve this unrelated file".utf8).write(to: unrelated)
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        try await waitForVerification(store, asset)
        XCTAssertEqual(store.statuses[asset.id], .installed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testDeletionDuringRecoveryCannotResurrectTheModel() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: directory.appendingPathComponent(asset.filename))
        let store = LocalAIModelStore(directory: directory, assets: [asset], configuration: .ephemeral)
        await store.delete(asset)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(store.statuses[asset.id], .missing)
        XCTAssertNil(store.installedURL(for: asset))
    }
    func testBadImportPreservesAnAlreadyInstalledModel() async throws {
        let (root, source, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        try await store.importFile(source)
        var damaged = try Data(contentsOf: source); damaged[4] = 0; try damaged.write(to: source)
        do { try await store.importFile(source); XCTFail("Accepted corrupt import") } catch {}
        XCTAssertEqual(store.statuses[asset.id], .installed)
        XCTAssertNoThrow(try LocalAIModelStore.verify(try XCTUnwrap(store.installedURL(for: asset)), asset: asset))
    }
    func testPrivateSessionNeverLoadsOrSavesHistory() throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: LocalAIHistory.directory.path)) ?? [])
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        let session = LocalAIChatSession(isPrivate: true, store: store)
        session.messages = [.init(role: "user", content: "Private test should not be written")]
        session.persist(); session.newConversation(); session.close()
        XCTAssertTrue(session.history.isEmpty)
        let after = Set((try? FileManager.default.contentsOfDirectory(atPath: LocalAIHistory.directory.path)) ?? [])
        XCTAssertEqual(before, after)
    }
    func testAnIdleSessionCannotCancelAnotherOwner() throws {
        let runtime = LocalAIRuntime()
        let owner = try runtime.begin()
        XCTAssertThrowsError(try runtime.begin())
        runtime.stop(owner: UUID())
        runtime.finish(owner: UUID())
        XCTAssertTrue(runtime.isBusy)
        runtime.finish(owner: owner)
        XCTAssertFalse(runtime.isBusy)
    }
    func testSwitchingToPrivateInAnotherWindowKeepsTheConversationEphemeral() throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: LocalAIHistory.directory.path)) ?? [])
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        var privateMode = false
        let session = LocalAIChatSession(isPrivate: false, store: store, privacyCheck: { privateMode })
        privateMode = true
        session.messages = [.init(role: "user", content: "Private after a global mode change")]
        session.persist()
        XCTAssertTrue(session.isPrivate)
        privateMode = false
        session.persist(); session.close()
        XCTAssertTrue(session.isPrivate)
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertEqual(before, Set((try? FileManager.default.contentsOfDirectory(atPath: LocalAIHistory.directory.path)) ?? []))
    }
    func testPrivateModeNotificationUpdatesHistoryBeforeAnotherMessage() async throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        var privateMode = false
        let session = LocalAIChatSession(isPrivate: false, store: store, privacyCheck: { privateMode })
        privateMode = true
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        for _ in 0..<20 where !session.isPrivate { await Task.yield() }
        XCTAssertTrue(session.isPrivate); XCTAssertTrue(session.history.isEmpty)
        privateMode = false
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        await Task.yield()
        XCTAssertTrue(session.isPrivate)
    }
    func testUndoCannotOverlapGenerationOrAnotherUndo() async throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        var restores = 0
        let session = LocalAIChatSession(isPrivate: true, store: store, undoCleanup: {
            restores += 1; try await Task.sleep(for: .milliseconds(30))
        })
        session.canUndo = true; session.isRunning = true
        await session.undo(); XCTAssertEqual(restores, 0)
        session.isRunning = false
        let first = Task { await session.undo() }
        for _ in 0..<30 where !session.isUndoing { await Task.yield() }
        await session.undo(); await first.value
        XCTAssertEqual(restores, 1); XCTAssertFalse(session.isUndoing)
    }
    func testCancellingAReviewedPlanCannotLeaveExecutableActions() throws {
        let (root, _, asset) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        let session = LocalAIChatSession(isPrivate: true, store: store)
        session.messages = [.init(role: "user", content: "Close a tab"), .init(role: "assistant", content: AIL10n.text("confirm_actions"))]
        session.pendingCalls = [.init(tool: "tab_close", value: "1")]; session.pendingDescriptions = ["Tab 1"]
        session.cancelPendingTools(); session.confirmTools()
        XCTAssertTrue(session.pendingCalls.isEmpty); XCTAssertTrue(session.pendingDescriptions.isEmpty)
        XCTAssertEqual(session.messages.last?.content, AIL10n.text("actions_cancelled")); XCTAssertFalse(session.isRunning)
    }
    private func installedToolFixture() async throws -> (URL, LocalAIModelStore) {
        let (root, source, original) = try fixture()
        let asset = LocalAIModelAsset(id: LocalAIModelAsset.language.id, filename: LocalAIModelAsset.language.filename,
            bytes: original.bytes, sha256: original.sha256, url: original.url)
        let store = LocalAIModelStore(directory: root.appendingPathComponent("Models"), assets: [asset], configuration: .ephemeral)
        try await store.importFile(source)
        store.selectedProfile = .light // This fixture installs only the light model.
        return (root, store)
    }
    func testClosingDuringAnAtomicToolFinishesTheChangeWithoutRevealingOldUI() async throws {
        let (root, store) = try await installedToolFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled"); defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.enabled") }
        var started = false, finished = 0
        let tools = LocalAITools(catalog: [.init("files_organize", title: "Organize", confirmation: true)], context: { "" }, preview: { _ in "" }, perform: { _ in
            started = true; try? await Task.sleep(for: .milliseconds(40)); return "Completed atomic change"
        }, undo: { "" }, finish: { _ in finished += 1 })
        let session = LocalAIChatSession(isPrivate: true, store: store, tools: tools)
        session.pendingCalls = [.init(tool: "files_organize")]; session.confirmTools()
        for _ in 0..<50 where !started { await Task.yield() }
        XCTAssertTrue(started); session.close()
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(session.isRunning); XCTAssertEqual(finished, 0)
        XCTAssertEqual(session.messages.last?.content, "Completed atomic change")
    }
    func testRetryKeepsTheDraftAndReusesTheFailedConversationTurn() async throws {
        let (root, store) = try await installedToolFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled"); defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.enabled") }
        var calls = 0
        let tools = LocalAITools(catalog: [.init("open_url", title: "Open", argument: "URL")], context: { "" }, preview: { _ in "Open page" }, perform: { _ in
            calls += 1; if calls == 1 { throw LocalAIError.operationNotApplied }; return "Opened the page"
        }, undo: { "" }, finish: { _ in })
        var pageReads = 0
        let session = LocalAIChatSession(isPrivate: true, store: store, pageProvider: {
            pageReads += 1; return LocalAIPage(title: "Page", url: URL(string: "https://example.com")!, text: "Article")
        }, tools: tools, plan: { _, _ in [.init(tool: "open_url", value: "https://example.com/summarize/screenshot/text")] })
        session.run(.chat, question: "Open https://example.com/summarize/screenshot/text")
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(session.canRetry)
        session.input = "Keep my next question"
        session.retry()
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(calls, 2); XCTAssertFalse(session.canRetry); XCTAssertNil(session.error)
        XCTAssertEqual(session.input, "Keep my next question")
        XCTAssertEqual(session.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertEqual(session.messages.last?.content, "Opened the page")
        XCTAssertEqual(pageReads, 0, "An explicit URL must not be mistaken for summary or image keywords in its path")
    }
    func testImageTextRequestsRequireVisionAndPreserveTheQuestion() async throws {
        let (root, store) = try await installedToolFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let old = UserDefaults.standard.object(forKey: "soulo.localAI.enabled")
        UserDefaults.standard.set(true, forKey: "soulo.localAI.enabled"); defer { UserDefaults.standard.set(old, forKey: "soulo.localAI.enabled") }
        var captured = false
        let tools = LocalAITools(catalog: [.init("page_images", title: "Images", category: .page)], context: { "" }, preview: { _ in "" }, perform: { _ in "" }, undo: { "" }, finish: { _ in })
        let session = LocalAIChatSession(isPrivate: true, store: store, tools: tools, imageProvider: { captured = true; return Data() }, plan: { _, _ in [.init(tool: "page_understand_image")] })
        session.input = "提取图片中的文字"; session.run(.chat)
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(session.error, LocalAIError.visionMissing.localizedDescription)
        XCTAssertEqual(session.input, "提取图片中的文字"); XCTAssertEqual(session.messages.filter { $0.role == "user" }.count, 1)
        XCTAssertFalse(captured); XCTAssertFalse(session.isRunning)
    }
}
