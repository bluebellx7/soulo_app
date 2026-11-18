import XCTest
import SwiftUI
@testable import Soulo

@MainActor final class UserScriptUpdateTests: XCTestCase {
    private func script(_ version: String, extra: String = "", body: String = "") -> String {
        """
        // ==UserScript==
        // @name Update fixture
        // @namespace soulo.tests.updates
        // @version \(version)
        // @match https://example.com/*
        // @grant GM_getValue
        // @grant GM_setValue
        \(extra)
        // ==/UserScript==
        \(body)
        """
    }
    private func manager() throws -> (BrowserExtensionService, URL, URLSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updates-" + UUID().uuidString)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: config)
        UpdateFixtureProtocol.set([:])
        return (BrowserExtensionService(extensionRoot: root, requirementSession: session), root, session)
    }
    private func installed(_ service: BrowserExtensionService, extra: String = "") throws -> UserScriptRecord {
        try service.saveUserScript(id: nil, fallbackName: "Fixture", source: script("1.9", extra: extra),
            explicitPatterns: nil, injectionTime: nil, sourceURL: URL(string: "https://scripts.example/test.user.js"))
    }
    func testAutomaticMetadataChecksAreThrottledPersistTheirBadgeAndNeverInstallCode() async throws {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { throw XCTSkip("Automatic probes pause in Low Power Mode") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-updates-" + UUID().uuidString)
        let suite = "AutomaticScriptUpdates." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { defaults.removePersistentDomain(forName:suite); session.invalidateAndCancel(); try? FileManager.default.removeItem(at:root) }
        let service = BrowserExtensionService(extensionRoot:root,requirementSession:session,updateDefaults:defaults)
        let old = try installed(service,extra:"// @updateURL https://scripts.example/test.meta.js")
        UpdateFixtureProtocol.set(["/test.meta.js":script("2.0",extra:"// @downloadURL https://scripts.example/never-auto-download.user.js")])
        let now = Date(timeIntervalSince1970:1_000_000)
        await service.checkAutomaticUserScriptUpdates(now:now)
        XCTAssertEqual(service.availableUserScriptUpdateVersions[old.id],"2.0")
        XCTAssertEqual(service.userScript(id:old.id)?.source,old.source)
        XCTAssertEqual(UpdateFixtureProtocol.requestedPaths(),["/test.meta.js"])
        await service.checkAutomaticUserScriptUpdates(now:now.addingTimeInterval(3600))
        let restarted = BrowserExtensionService(extensionRoot:root,requirementSession:session,updateDefaults:defaults)
        XCTAssertEqual(restarted.availableUserScriptUpdateVersions[old.id],"2.0")
        await restarted.checkAutomaticUserScriptUpdates(now:now.addingTimeInterval(3600))
        XCTAssertEqual(UpdateFixtureProtocol.requestedPaths().count,1)
        await restarted.checkAutomaticUserScriptUpdates(now:now.addingTimeInterval(86401))
        XCTAssertEqual(UpdateFixtureProtocol.requestedPaths(),["/test.meta.js","/test.meta.js"])
        XCTAssertEqual(restarted.userScript(id:old.id)?.source,old.source)
    }

    func testAutomaticChecksHaveABoundedBatchAndSkipPrivateBrowsing() async throws {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled else { throw XCTSkip("Automatic probes pause in Low Power Mode") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("auto-batch-" + UUID().uuidString)
        let suite = "AutomaticScriptBatch." + UUID().uuidString
        let defaults = UserDefaults(suiteName:suite)!
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateFixtureProtocol.self]
        let session = URLSession(configuration:configuration)
        defer { defaults.removePersistentDomain(forName:suite); session.invalidateAndCancel(); try? FileManager.default.removeItem(at:root) }
        let service = BrowserExtensionService(extensionRoot:root,requirementSession:session,updateDefaults:defaults)
        var sources:[String:String]=[:]
        for index in 0..<6 {
            let path="/batch-\(index).user.js"
            let old=script("1.0").replacingOccurrences(of:"soulo.tests.updates",with:"soulo.tests.batch.\(index)")
            _ = try service.saveUserScript(id:nil,fallbackName:"Batch",source:old,explicitPatterns:nil,injectionTime:nil,sourceURL:URL(string:"https://scripts.example"+path))
            sources[path]=old.replacingOccurrences(of:"@version 1.0",with:"@version 2.0")
        }
        UpdateFixtureProtocol.set(sources)
        let now=Date(timeIntervalSince1970:1_000_000)
        defaults.set(true,forKey:"is_incognito")
        await service.checkAutomaticUserScriptUpdates(now:now,limit:99)
        XCTAssertTrue(UpdateFixtureProtocol.requestedPaths().isEmpty)
        defaults.set(false,forKey:"is_incognito")
        await service.checkAutomaticUserScriptUpdates(now:now,limit:99)
        XCTAssertEqual(UpdateFixtureProtocol.requestedPaths().count,4)
        await service.checkAutomaticUserScriptUpdates(now:now.addingTimeInterval(1),limit:99)
        XCTAssertEqual(UpdateFixtureProtocol.requestedPaths().count,6)
        XCTAssertEqual(Set(UpdateFixtureProtocol.requestedPaths()).count,6)
        XCTAssertEqual(service.availableUserScriptUpdateVersions.count,6)
    }

    func testVersionsCompareNumericallyAndTreatPrereleasesAndBuildMetadataCorrectly() {
        for (a,b,newer) in [("1.10","1.9",true),("2.0","1.999",true),("1.0.0","1",false),
                            ("1.0-beta.2","1.0-beta.1",true),("1.0","1.0-beta",true),
                            ("1.0-beta","1.0",false),("1.0+build2","1.0+build1",false),
                            ("v2.0","1.0",true),("2026.11.3","2026.11.2",true),("1.1","2.0",false),
                            ("", "",false)] {
            XCTAssertEqual(UserScriptUpdateLoader.isNewer(a, than: b), newer, a + " / " + b)
        }
    }
    func testLocalAndOptedOutScriptsNeverAcquireAnUpdateURL() {
        XCTAssertNil(UserScriptUpdateLoader.checkURL(for: UserScriptRecord(name: "Local", source: "")))
        XCTAssertNil(UserScriptUpdateLoader.checkURL(for: UserScriptRecord(name: "Off", source: "", updateURL: "none", downloadURL: "https://scripts.example/test.user.js")))
        XCTAssertNil(UserScriptUpdateLoader.checkURL(for: UserScriptRecord(name: "Built in", source: "", sourceURL: "https://scripts.example/test.user.js", isBuiltIn: true)))
    }
    func testMetadataUpdateRequiresReviewThenKeepsIDStorageAndOffState() async throws {
        let (service, root, session) = try manager()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let old = try installed(service, extra: "// @updateURL https://scripts.example/test.meta.js")
        try service.setStoredValue(#"{"value":"keep"}"#, forKey: "setting", scriptID: old.id)
        service.setUserScriptEnabled(old.id, enabled: false)
        let next = script("1.10", extra: "// @downloadURL ./test.user.js", body: "window.__updated = true;")
        UpdateFixtureProtocol.set(["/test.meta.js": script("1.10", extra: "// @downloadURL ./test.user.js"), "/test.user.js": next])
        let checked = try await service.previewUserScriptUpdate(old.id)
        let preview = try XCTUnwrap(checked)
        XCTAssertEqual(service.userScript(id: old.id)?.source, old.source, "Checking must never install code")
        let updated = try await service.applyUserScriptUpdate(preview)
        XCTAssertEqual(updated.id, old.id); XCTAssertEqual(updated.installedAt, old.installedAt)
        XCTAssertFalse(updated.isEnabled); XCTAssertEqual(updated.storedValues?["setting"], #"{"value":"keep"}"#)
        XCTAssertEqual(updated.source, next); XCTAssertEqual(updated.version, "1.10")
    }
    func testEqualOrOlderVersionDoesNotDownloadAnUpdate() async throws {
        let (service, root, session) = try manager()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let old = try installed(service)
        for version in ["1.9", "1.8"] {
            UpdateFixtureProtocol.set(["/test.user.js": script(version)])
            let result = try await service.previewUserScriptUpdate(old.id)
            XCTAssertNil(result); XCTAssertEqual(service.userScript(id: old.id)?.source, old.source)
        }
    }
    func testUpdateReviewLayout() async throws {
        let (service, root, session) = try manager()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let old = try installed(service)
        UpdateFixtureProtocol.set(["/test.user.js": script("2.0", body: "window.__updated = true;")])
        let checked = try await service.previewUserScriptUpdate(old.id)
        let preview = try XCTUnwrap(checked)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: UserScriptUpdateReviewView(preview: preview) { _ in })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(250))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "UserScript update version and access review"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testInvalidIdentityHTMLAndStaleDownloadsLeaveInstalledCodeUntouched() async throws {
        let (service, root, session) = try manager()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let old = try installed(service)
        for body in ["<html>Login required</html>", script("2.0").replacingOccurrences(of: "soulo.tests.updates", with: "another.script"), "console.log('not a userscript')"] {
            UpdateFixtureProtocol.set(["/test.user.js": body])
            do { _ = try await service.previewUserScriptUpdate(old.id); XCTFail("Invalid update accepted") } catch { }
            XCTAssertEqual(service.userScript(id: old.id)?.source, old.source)
        }
    }
    func testDependencyFailureAndConcurrentEditCannotReplaceInstalledCode() async throws {
        let (service, root, session) = try manager()
        defer { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
        let old = try installed(service)
        UpdateFixtureProtocol.set(["/test.user.js": script("2.0", extra: "// @require https://scripts.example/missing.js")])
        let checked = try await service.previewUserScriptUpdate(old.id)
        let pending = try XCTUnwrap(checked)
        do { _ = try await service.applyUserScriptUpdate(pending); XCTFail("A failed dependency must not replace code") } catch { }
        XCTAssertEqual(service.userScript(id: old.id)?.source, old.source)
        let edited = try service.saveUserScript(id: old.id, fallbackName: old.name, source: script("1.9", body: "window.localEdit=true;"), explicitPatterns: nil, injectionTime: nil)
        do { _ = try await service.applyUserScriptUpdate(pending); XCTFail("Stale review overwrote a local edit") } catch is CancellationError { }
        XCTAssertEqual(service.userScript(id: old.id)?.source, edited.source)
        service.deleteUserScript(old.id)
        do { _ = try await service.applyUserScriptUpdate(pending); XCTFail("Update restored a deleted script") } catch is CancellationError { }
        XCTAssertNil(service.userScript(id: old.id))
    }
}

private final class UpdateFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var sources: [String: String] = [:]
    private static var paths: [String] = []
    static func requestedPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return paths }
    static func set(_ value: [String: String]) { lock.lock(); sources = value; paths = []; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "scripts.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let text = Self.sources[request.url!.path]; Self.paths.append(request.url!.path); Self.lock.unlock()
        let data = Data((text ?? "Missing").utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: text == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/javascript", "Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
