import XCTest
import WebKit
import JavaScriptCore
import CryptoKit
@testable import Soulo

@MainActor
final class UserScriptRequirementsTests: XCTestCase {
    private let firstURL = "https://scripts.example/first.js"
    private let secondURL = "https://scripts.example/second.js"

    private func session(offline: Bool = false) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = offline ? [OfflineRequirementProtocol.self] : [RequirementFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func source(requirements: [String], body: String = "window.__requireAnswer = RequirementLibrary.value;") -> String {
        """
        // ==UserScript==
        // @name Require fixture
        // @namespace soulo.tests.require
        // @match https://example.com/*
        // @grant none
        \(requirements.map { "// @require \($0)" }.joined(separator: "\n"))
        // ==/UserScript==
        \(body)
        """
    }

    private func service(root: URL, session: URLSession) -> BrowserExtensionService {
        BrowserExtensionService(extensionRoot: root, requirementSession: session)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("require-\(UUID().uuidString)")
    }

    func testMetadataKeepsDependencyOrderAndCaseSensitivePathsAndHashes() {
        let urls = [firstURL, "https://scripts.example/First.js", firstURL + "#sha256=AbCd", firstURL + "#sha256=abcd", firstURL]
        let metadata = BrowserExtensionService.parseMetadata(from: source(requirements: urls))
        XCTAssertEqual(metadata.requiredURLs, Array(urls.dropLast()))
    }

    func testRelativeDependencyBOMAndCachedOfflineResolution() async throws {
        let online = session()
        let offline = session(offline: true)
        defer { online.invalidateAndCancel(); offline.invalidateAndCancel() }
        let sources = try await UserScriptRequirementLoader.resolve(
            ["../first.js"], baseURL: URL(string: "https://scripts.example/scripts/test.user.js"), session: online
        )
        XCTAssertTrue(try XCTUnwrap(sources["../first.js"]).hasPrefix("let RequirementLibrary"))
        let cached = try await UserScriptRequirementLoader.resolve(
            ["../first.js"], baseURL: URL(string: "https://scripts.example/scripts/test.user.js"), cachedSources: sources, session: offline
        )
        XCTAssertEqual(cached, sources)
        XCTAssertEqual(try UserScriptRequirementLoader.resolvedURL("http://scripts.example:80/first.js", baseURL: nil).absoluteString, firstURL)
    }

    func testInvalidResponsesAndUnsupportedURLsFailWithTheDependencyAddress() async {
        let network = session()
        defer { network.invalidateAndCancel() }
        for url in ["https://scripts.example/missing.js", "https://scripts.example/html.js", "https://scripts.example/invalid-utf8.js", "file:///tmp/test.js", "data:text/javascript,alert(1)", "relative.js"] {
            do {
                _ = try await UserScriptRequirementLoader.resolve([url], baseURL: nil, session: network)
                XCTFail("Expected failure for \(url)")
            } catch {
                XCTAssertEqual((error as? UserScriptRequirementLoader.Failure)?.declaration, url)
                XCTAssertTrue(error.localizedDescription.contains(url))
            }
        }
    }

    func testDependencyCountFileAndCombinedLimitsIncludeCachedSources() async {
        let network = session()
        defer { network.invalidateAndCancel() }
        for (urls, cache, fileLimit, totalLimit) in [
            ((0...UserScriptRequirementLoader.maximumCount).map { "https://scripts.example/\($0).js" }, [:], 1000, 2000),
            ([firstURL], [:], 4, 1000),
            ([firstURL, secondURL], [:], 1000, 100),
            ([firstURL], [firstURL: "12345"], 4, 1000),
            ([firstURL, secondURL], [firstURL: "1234", secondURL: "5678"], 10, 7)
        ] {
            do {
                _ = try await UserScriptRequirementLoader.resolve(urls, baseURL: nil, cachedSources: cache, session: network, maximumFileSize: fileLimit, maximumTotalSize: totalLimit)
                XCTFail("Expected dependency limit failure")
            } catch {
                XCTAssertEqual(((error as? UserScriptRequirementLoader.Failure)?.underlying as? URLError)?.code, .dataLengthExceedsMaximum)
            }
        }
    }

    func testIntegrityAcceptsHexBase64AndLastSupportedHashAndRejectsMismatch() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let data = Data(RequirementFixtureProtocol.firstSource.utf8)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base64 = Data(SHA256.hash(data: data)).base64EncodedString()
        for fragment in ["sha256=\(hex)", "sha256-\(base64)", "md5=wrong;sha256=\(hex)", "sha512=" + Data(SHA512.hash(data: data)).base64EncodedString()] {
            let url = firstURL + "#" + fragment
            let resolved = try await UserScriptRequirementLoader.resolve([url], baseURL: nil, session: network)
            XCTAssertNotNil(resolved[url])
        }
        for fragment in ["sha256=incorrect", "sha999=incorrect", "sha256"] {
            do {
                _ = try await UserScriptRequirementLoader.resolve([firstURL + "#" + fragment], baseURL: nil, session: network)
                XCTFail("Integrity failure must prevent installation")
            } catch { XCTAssertTrue(error is UserScriptRequirementLoader.Failure) }
        }
    }

    func testDownloadedDependenciesRunInOrderAndShareScopeAtBothInjectionTimes() async throws {
        let network = session()
        defer { network.invalidateAndCancel() }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = service(root: root, session: network)
        let record = try await manager.saveUserScriptResolvingRequirements(id: nil, fallbackName: "Fixture", source: source(requirements: [firstURL, secondURL]), explicitPatterns: nil, injectionTime: nil)
        for injection in [UserScriptInjectionTime.documentStart, .documentEnd] {
            var script = record
            script.injectionTime = injection
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(WKUserScript(
                source: UserScriptRuntime.wrappedSource(for: script),
                injectionTime: injection == .documentStart ? .atDocumentStart : .atDocumentEnd,
                forMainFrameOnly: true
            ))
            let web = WKWebView(frame: .zero, configuration: configuration)
            web.loadHTMLString("<html><body>Require fixture</body></html>", baseURL: URL(string: "https://example.com/probe"))
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("window.__requireAnswer || 0")) as? Int == 42 { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let answer = try await web.evaluateJavaScript("window.__requireAnswer || 0") as? Int
            XCTAssertEqual(answer, 42, "Dependency execution failed at \(injection)")
        }
    }

    func testMissingDependencyNeverRunsTheMainScript() {
        let script = UserScriptRecord(name: "Missing", source: "globalThis.__ran = true;", requiredURLs: [firstURL])
        let context = JSContext()!
        context.evaluateScript("var console = {error: function() {}};")
        context.evaluateScript(UserScriptRuntime.wrappedSource(for: script))
        XCTAssertNil(context.exception)
        XCTAssertTrue(context.objectForKeyedSubscript("__ran")!.isUndefined)
    }

    func testCachePersistsAndEditingOfflineKeepsValuesAndDisabledState() async throws {
        let root = temporaryRoot()
        let online = session()
        let offline = session(offline: true)
        defer { online.invalidateAndCancel(); offline.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let manager = service(root: root, session: online)
        let original = try await manager.saveUserScriptResolvingRequirements(id: nil, fallbackName: "Fixture", source: source(requirements: [firstURL, secondURL]), explicitPatterns: nil, injectionTime: nil)
        manager.setUserScriptEnabled(original.id, enabled: false)
        try manager.setStoredValue(#"{"value":42}"#, forKey: "answer", scriptID: original.id)
        let restored = service(root: root, session: offline)
        let edited = try await restored.saveUserScriptResolvingRequirements(id: original.id, fallbackName: "Fixture", source: original.source + "\n// offline edit", explicitPatterns: nil, injectionTime: nil)
        XCTAssertFalse(edited.isEnabled)
        XCTAssertEqual(edited.storedValues?["answer"], #"{"value":42}"#)
        XCTAssertEqual(edited.requiredSources, original.requiredSources)
        let pruned = try await restored.saveUserScriptResolvingRequirements(id: edited.id, fallbackName: "Fixture", source: source(requirements: [], body: "window.__requireAnswer = 1;"), explicitPatterns: nil, injectionTime: nil)
        XCTAssertEqual(pruned.requiredSources, [:])
    }

    func testFailedReinstallLeavesExistingCodeCacheAndDataIntact() async throws {
        let root = temporaryRoot()
        let network = session()
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let manager = service(root: root, session: network)
        let original = try await manager.saveUserScriptResolvingRequirements(id: nil, fallbackName: "Fixture", source: source(requirements: [firstURL]), explicitPatterns: nil, injectionTime: nil)
        try manager.setStoredValue(#"{"value":"keep"}"#, forKey: "value", scriptID: original.id)
        let before = manager.userScripts
        do {
            _ = try await manager.saveUserScriptResolvingRequirements(id: nil, fallbackName: "Fixture", source: source(requirements: [firstURL, "https://scripts.example/missing.js"]), explicitPatterns: nil, injectionTime: nil)
            XCTFail("Failed reinstall must not replace the original")
        } catch { XCTAssertEqual(manager.userScripts, before) }
    }

    func testFailedNewInstallAndInvalidScopeNeverPersistPartialScripts() async throws {
        let root = temporaryRoot()
        let network = session()
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let manager = service(root: root, session: network)
        let before = manager.userScripts
        for patterns: [String]? in [nil, []] {
            do {
                _ = try await manager.saveUserScriptResolvingRequirements(id: nil, fallbackName: "Fixture", source: source(requirements: ["https://scripts.example/missing.js"]), explicitPatterns: patterns, injectionTime: nil)
                XCTFail("Expected install failure")
            } catch { XCTAssertEqual(manager.userScripts, before) }
        }
    }

    func testFileImportResolvesRelativeRequirementsAgainstTheDownloadURL() async throws {
        let root = temporaryRoot()
        let network = session()
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("fixture.user.js")
        try source(requirements: ["../first.js"]).write(to: file, atomically: true, encoding: .utf8)
        let manager = service(root: root, session: network)
        let imported = try await manager.importUserScript(from: file, sourceURL: URL(string: "https://scripts.example/scripts/fixture.user.js"))
        XCTAssertNotNil(imported.requiredSources?["../first.js"])
        XCTAssertEqual(imported.sourceURL, "https://scripts.example/scripts/fixture.user.js")
        manager.deleteUserScript(imported.id)
        do {
            _ = try await manager.saveUserScriptResolvingRequirements(id: imported.id, fallbackName: imported.name, source: source(requirements: []), explicitPatterns: nil, injectionTime: nil)
            XCTFail("Saving a deleted script must not recreate it")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    private func writeLegacyScript(_ script: UserScriptRecord, root: URL) throws {
        struct Store: Encodable { let userScripts: [UserScriptRecord]; let webExtensions: [WebExtensionRecord] = [] }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Store(userScripts: [script])).write(to: root.appendingPathComponent("extensions.json"))
    }

    private func waitForRequirements(_ manager: BrowserExtensionService, id: UUID) async throws {
        for _ in 0..<100 where manager.loadingUserScripts.contains(id) { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(manager.loadingUserScripts.contains(id))
    }

    func testExistingInstalledScriptsAutomaticallyResolveAndPersistDependencies() async throws {
        let root = temporaryRoot()
        let network = session()
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        var legacy = UserScriptRecord(name: "Legacy", source: source(requirements: [firstURL]), requiredURLs: [firstURL])
        legacy.requiredURLs = nil
        legacy.requiredSources = nil
        try writeLegacyScript(legacy, root: root)
        let manager = service(root: root, session: network)
        try await waitForRequirements(manager, id: legacy.id)
        XCTAssertTrue(try XCTUnwrap(manager.userScript(id: legacy.id)).hasResolvedRequirements)
        XCTAssertNil(manager.userScriptErrors[legacy.id])
        let offline = session(offline: true)
        defer { offline.invalidateAndCancel() }
        let restored = service(root: root, session: offline)
        XCTAssertTrue(try XCTUnwrap(restored.userScript(id: legacy.id)).hasResolvedRequirements)
        XCTAssertTrue(restored.loadingUserScripts.isEmpty)
    }

    func testMigrationFailureDisablesScriptAndExposesRetryableError() async throws {
        let root = temporaryRoot()
        let network = session(offline: true)
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let legacy = UserScriptRecord(name: "Legacy", source: source(requirements: [firstURL]), requiredURLs: [firstURL])
        try writeLegacyScript(legacy, root: root)
        let manager = service(root: root, session: network)
        try await waitForRequirements(manager, id: legacy.id)
        XCTAssertFalse(try XCTUnwrap(manager.userScript(id: legacy.id)).isEnabled)
        XCTAssertNotNil(manager.userScriptErrors[legacy.id])
        manager.setUserScriptEnabled(legacy.id, enabled: true)
        XCTAssertTrue(manager.loadingUserScripts.contains(legacy.id))
        XCTAssertNil(manager.userScriptErrors[legacy.id])
        manager.deleteUserScript(legacy.id)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(manager.userScript(id: legacy.id))
        XCTAssertNil(manager.userScriptErrors[legacy.id])
        XCTAssertFalse(manager.loadingUserScripts.contains(legacy.id))
    }

    func testDisabledLegacyScriptResolvesWhenEnabledWithoutLosingStoredValues() async throws {
        let root = temporaryRoot()
        let network = session()
        defer { network.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let legacy = UserScriptRecord(name: "Disabled legacy", source: source(requirements: [firstURL]), requiredURLs: [firstURL], storedValues: ["answer": #"{"value":42}"#], isEnabled: false)
        try writeLegacyScript(legacy, root: root)
        let manager = service(root: root, session: network)
        XCTAssertTrue(manager.loadingUserScripts.isEmpty)
        manager.setUserScriptEnabled(legacy.id, enabled: true)
        try await waitForRequirements(manager, id: legacy.id)
        let resolved = try XCTUnwrap(manager.userScript(id: legacy.id))
        XCTAssertTrue(resolved.isEnabled)
        XCTAssertTrue(resolved.hasResolvedRequirements)
        XCTAssertEqual(resolved.storedValues, legacy.storedValues)
    }
}

private final class RequirementFixtureProtocol: URLProtocol {
    static let firstSource = "\u{FEFF}let RequirementLibrary = { value: 40 }; // trailing comment"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let data: Data
        switch path {
        case "/first.js": data = Data(Self.firstSource.utf8)
        case "/second.js": data = Data("RequirementLibrary.value += 2; // trailing comment".utf8)
        case "/invalid-utf8.js": data = Data([0xff, 0xff])
        default: data = Data("<html>Not a script</html>".utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "/missing.js" ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": path == "/html.js" ? "text/html" : "application/javascript"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class OfflineRequirementProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
