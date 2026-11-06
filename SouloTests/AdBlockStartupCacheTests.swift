import WebKit
import XCTest
import SwiftUI
@testable import Soulo

final class AdBlockStartupCacheTests: XCTestCase {
    @MainActor
    func testPreparedFirstDocumentHasProtectionAndFilteringChangesKeepItsWebView() async throws {
        let defaults = UserDefaults.standard
        let keys = ["ad_block_enabled", "is_incognito", "privacy_https_upgrade_enabled",
                    "soulo_ad_block_subscription_rules", "soulo_ad_block_allowlisted_hosts"]
        let saved = keys.map { defaults.object(forKey: $0) }
        let settings = AdBlockSettingsService.shared
        let selector = ".qa-startup-ad-" + UUID().uuidString.prefix(8).lowercased()
        let parsed = ParsedAdBlockRules(cosmeticRules: [AdBlockCosmeticRule(selector: selector)])
        defaults.set(true, forKey: "ad_block_enabled")
        defaults.set(true, forKey: "is_incognito")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set([], forKey: "soulo_ad_block_allowlisted_hosts")
        defaults.set(try JSONEncoder().encode(parsed), forKey: "soulo_ad_block_subscription_rules")
        settings.reloadFromDefaults()
        defer {
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            settings.reloadFromDefaults()
        }
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <script>window.filterWasInstalledBeforePageScript=window.__souloAdBlockInstalled===true;</script>
            <h1>Prepared filtered document</h1><div id="advert" class="\(selector.dropFirst())">Advertisement</div>
            <input id="note" aria-label="Saved note"><button id="button" onclick="window.buttonCount=(window.buttonCount||0)+1">Useful action</button>
            """.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let model = WebViewModel()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AdBlockPreparedWebView(viewModel: model))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil; model.releaseWebViewRuntime()
            previous?.makeKeyAndVisible()
        }
        func eventually(_ predicate: () async -> Bool) async throws {
            for _ in 0..<300 {
                if await predicate() { return }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("Prepared filtered document did not reach its expected state")
            throw URLError(.timedOut)
        }
        model.loadURL(root.appendingPathComponent("page.html"))
        try await eventually {
            (try? await model.webView?.evaluateJavaScript("window.filterWasInstalledBeforePageScript===true && document.getElementById('advert') && getComputedStyle(document.getElementById('advert')).display==='none'")) as? Bool == true
        }
        let web = try XCTUnwrap(model.webView)
        XCTAssertEqual(server.receivedRequests.filter { $0.path == "/page.html" }.count, 1)
        XCTAssertEqual(web.configuration.userContentController.userScripts.filter { $0.source.hasPrefix(AdBlockService.hidingScriptPrefix) }.count, 1)
        _ = try await web.evaluateJavaScript("document.getElementById('note').value='User typed note';window.fixtureMutableState=37;document.getElementById('button').click();null")
        defaults.set(false, forKey: "ad_block_enabled")
        try await eventually {
            (try? await web.evaluateJavaScript("window.__souloAdBlockConfig?.cosmeticEnabled===false && getComputedStyle(document.getElementById('advert')).display!=='none'")) as? Bool == true
        }
        XCTAssertTrue(model.webView === web, "Disabling filtering must retain the existing document")
        defaults.set(true, forKey: "ad_block_enabled")
        try await eventually {
            (try? await web.evaluateJavaScript("window.__souloAdBlockConfig?.cosmeticEnabled===true && getComputedStyle(document.getElementById('advert')).display==='none'")) as? Bool == true
        }
        XCTAssertTrue(model.webView === web, "Re-enabling filtering must not replace the WebView")
        let retainedState = try await web.evaluateJavaScript("document.getElementById('note').value==='User typed note' && window.fixtureMutableState===37 && window.buttonCount===1") as? Bool
        XCTAssertEqual(retainedState, true)
        XCTAssertEqual(server.receivedRequests.filter { $0.path == "/page.html" }.count, 1, "Changing protection must not reload the document")
        // Let this fixture's async native preparation finish before restoring
        // its temporary preferences, rather than racing a different rule set.
        try await eventually {
            WebViewRepresentable.adScriptConfiguration(allowlist: settings.allowlistedHosts).nativeCosmeticFiltering
        }
    }

    @MainActor
    func testTemporaryAllowanceLetsTheFirstImmediateReloadBypassPreviouslyInstalledNativeRules() async throws {
        let defaults = UserDefaults.standard, settings = AdBlockSettingsService.shared
        let keys = ["ad_block_enabled", "is_incognito", "privacy_https_upgrade_enabled",
                    "soulo_ad_block_subscription_rules", "soulo_ad_block_allowlisted_hosts",
                    BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        let savedTemporaryHosts = settings.temporaryAllowlistedHosts
        let nonce = UUID().uuidString.lowercased()
        let resourcePath = "/qa-native-\(nonce).js"
        let parsed = ParsedAdBlockRules(networkRules: [AdBlockNetworkRule(urlFilter: nonce, resourceTypes: ["script"])])
        defaults.set(true, forKey: "ad_block_enabled")
        defaults.set(true, forKey: "is_incognito")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set([], forKey: "soulo_ad_block_allowlisted_hosts")
        defaults.set(try JSONEncoder().encode(parsed), forKey: "soulo_ad_block_subscription_rules")
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
        settings.clearTemporaryExceptions()
        settings.reloadFromDefaults()
        defer {
            settings.clearTemporaryExceptions()
            for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) }
            settings.reloadFromDefaults()
            savedTemporaryHosts.forEach { settings.temporarilyDisableFiltering(for: $0) }
        }
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/page.html": Data("""
            <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
            <script>addEventListener('load',()=>webkit.messageHandlers.qaTemporaryAllowance.postMessage({loaded:window.fixtureNativeResourceLoaded===true}));</script>
            <script src="\(resourcePath)"></script><h1>Immediate native-rule refresh</h1>
            """.utf8),
            resourcePath: Data("window.fixtureNativeResourceLoaded=true;".utf8)
        ], responseHeaders: [resourcePath: ["Content-Type": "application/javascript"]])
        let root = try await server.start(); defer { server.stop() }
        let identifier = "SouloTemporaryAllowanceFixture-" + nonce
        let blockingJSON = """
        [{"trigger":{"url-filter":"\(nonce)","resource-type":["script"]},"action":{"type":"block"}}]
        """
        let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: blockingJSON)
        let blockingRules = try XCTUnwrap(compiled)
        defer { WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier) { _ in } }
        let probe = TemporaryAllowanceResourceProbe(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(probe, name: "qaTemporaryAllowance")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let model = WebViewModel()
        model.webView = web
        WebViewRepresentable.applyContentRules([blockingRules], on: web, allowlist: [])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(web)
        window.makeKeyAndVisible()
        defer {
            probe.onReport = nil
            configuration.userContentController.removeScriptMessageHandler(forName: "qaTemporaryAllowance")
            model.releaseWebViewRuntime()
            window.isHidden = true; window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        let blocked = expectation(description: "The installed native rule blocks the first resource load")
        probe.onReport = { blocked.fulfill() }
        model.loadURL(root.appendingPathComponent("page.html"))
        await fulfillment(of: [blocked], timeout: 10)
        guard probe.loadedResults.count == 1 else { throw URLError(.timedOut) }
        XCTAssertEqual(probe.loadedResults, [false])
        XCTAssertFalse(server.receivedRequests.contains { $0.path == resourcePath })
        model.updateLoading(false) // This raw fixture intentionally has no production navigation delegate.

        let reloaded = expectation(description: "The first immediate reload reaches the previously blocked resource")
        probe.onReport = { reloaded.fulfill() }
        settings.temporarilyDisableFiltering(for: try XCTUnwrap(root.host))
        // A bare WebKit fixture has no production script runtime. Asynchronous
        // replacements cannot attach to it, so only synchronous removal of the
        // old blocking rules can let this first reload succeed.
        WebViewRepresentable.synchronizeAdProtection(on: web, model: model, enabled: true, allowlist: settings.allowlistedHosts)
        model.reload() // No yield or wait for replacement compilation between allowing and reloading.
        await fulfillment(of: [reloaded], timeout: 10)
        guard probe.loadedResults.count == 2 else { throw URLError(.timedOut) }
        probe.onReport = nil
        XCTAssertEqual(probe.loadedResults, [false, true])
        XCTAssertEqual(server.receivedRequests.filter { $0.path == resourcePath }.count, 1)
        XCTAssertEqual(server.receivedRequests.filter { $0.path == "/page.html" }.count, 2,
                       "The first reload must work without a second reload or a fresh WebView")
        XCTAssertTrue(model.webView === web)
        XCTAssertTrue(settings.isTemporarilyAllowlisted(root.host))
        XCTAssertTrue(defaults.stringArray(forKey: "soulo_ad_block_allowlisted_hosts")?.isEmpty == true)

        // Finish the small replacement preparation before restoring real
        // subscription preferences, without awaiting potentially stuck page JS.
        for _ in 0..<400 {
            if WebViewRepresentable.adScriptConfiguration(allowlist: settings.allowlistedHosts).nativeCosmeticFiltering { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The fixture's native replacement preparation did not finish")
    }

    func testAutomaticUpdateFastPathRequiresValidatedCurrentNonemptyArchive() throws {
        let suite = "AutomaticUpdateState-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let archive = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: archive) }
        try Data("validated rules".utf8).write(to: archive)
        let now = Date(timeIntervalSince1970: 1_000_000)
        defaults.set(now.timeIntervalSince1970 - 100, forKey: "soulo_ad_block_subscription_auto_update_check")
        defaults.set(1, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        XCTAssertTrue(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now.addingTimeInterval(86400)))
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now.addingTimeInterval(-200)))
        defaults.set(2, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        defaults.set(1, forKey: "soulo_ad_block_subscription_rules_version")
        try Data("replaced archive with different content".utf8).write(to: archive, options: .atomic)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: false)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        let state = try XCTUnwrap(AdBlockAutomaticUpdateState.snapshot(archive: archive, defaults: defaults, hasRules: true))
        let staleParser = AdBlockAutomaticUpdateState(parserVersion: state.parserVersion - 1,
            revision: state.revision, modifiedAt: state.modifiedAt, size: state.size, hasRules: true)
        defaults.set(try JSONEncoder().encode(staleParser), forKey: AdBlockAutomaticUpdateState.storageKey)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        AdBlockAutomaticUpdateState.record(archive: archive, defaults: defaults, hasRules: true)
        defaults.set(Data("{}".utf8), forKey: "soulo_ad_block_subscription_rules")
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules")
        try FileManager.default.removeItem(at: archive)
        XCTAssertFalse(AdBlockAutomaticUpdateState.canSkipCheck(archive: archive, defaults: defaults, now: now))
    }

    func testDiskEntriesRequireExactInputsAndSurviveNewCacheInstance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AdBlockStartupCache(directory: directory)
        cache.write("document.querySelector('.ad')", slot: .cosmeticScript, key: "revision-a")
        cache.write(["native-a", "native-b"], slot: .contentRuleIdentifiers, key: "revision-a")
        let reopened = AdBlockStartupCache(directory: directory)
        XCTAssertEqual(reopened.read(String.self, slot: .cosmeticScript, key: "revision-a"), "document.querySelector('.ad')")
        XCTAssertEqual(reopened.read([String].self, slot: .contentRuleIdentifiers, key: "revision-a"), ["native-a", "native-b"])
        XCTAssertNil(reopened.read(String.self, slot: .cosmeticScript, key: "revision-b"))
        cache.write("updated", slot: .cosmeticScript, key: "revision-b")
        XCTAssertNil(reopened.read(String.self, slot: .cosmeticScript, key: "revision-a"))
        XCTAssertEqual(reopened.read(String.self, slot: .cosmeticScript, key: "revision-b"), "updated")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testMissingCorruptAndWrongTypedEntriesAreCacheMisses() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AdBlockStartupCache(directory: directory)
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        cache.write(["not a script"], slot: .cosmeticScript, key: "key")
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        try Data("{truncated".utf8).write(to: directory.appendingPathComponent("cosmeticScript.json"))
        XCTAssertNil(cache.read(String.self, slot: .cosmeticScript, key: "key"))
        cache.write("recovered", slot: .cosmeticScript, key: "key")
        XCTAssertEqual(cache.read(String.self, slot: .cosmeticScript, key: "key"), "recovered")
        AdBlockStartupCache(directory: nil).write("ignored", slot: .cosmeticScript, key: "key")
    }

    func testFallbackAndNativeScriptsSurviveAlternatingStartupRequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AdBlockStartupCache(directory: directory)
        cache.write("full fallback", slot: .cosmeticScript, key: "fallback-v1")
        cache.write("native supplement", slot: .nativeCosmeticScript, key: "native-v1")
        let reopened = AdBlockStartupCache(directory: directory)
        XCTAssertEqual(reopened.read(String.self, slot: .cosmeticScript, key: "fallback-v1"), "full fallback")
        XCTAssertEqual(reopened.read(String.self, slot: .nativeCosmeticScript, key: "native-v1"), "native supplement")
        // An update must invalidate that mode without accepting the other mode's output.
        XCTAssertNil(reopened.read(String.self, slot: .nativeCosmeticScript, key: "fallback-v1"))
        cache.write("new fallback", slot: .cosmeticScript, key: "fallback-v2")
        XCTAssertNil(reopened.read(String.self, slot: .cosmeticScript, key: "fallback-v1"))
        XCTAssertEqual(reopened.read(String.self, slot: .nativeCosmeticScript, key: "native-v1"), "native supplement")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testCacheIdentityTracksAllowlistRulesAndDirectOverrides() throws {
        let defaults = UserDefaults.standard
        let keys = ["soulo_ad_block_subscription_rules", "soulo_ad_block_subscription_rules_version",
                    BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let original = try XCTUnwrap(AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        XCTAssertEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com", "example.com"], cosmetic: true))
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: [], cosmetic: true))
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: false))
        defaults.set(42, forKey: "soulo_ad_block_subscription_rules_version")
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules_version")
        // Include override bytes too: tests and migrations can change them
        // without bumping the UI store's revision.
        defaults.set(Data("{}".utf8), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertNotEqual(original, AdBlockService.startupCacheKey(allowlistedHosts: ["example.com"], cosmetic: true))
        defaults.set(try JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: "soulo_ad_block_subscription_rules")
        XCTAssertNil(AdBlockService.startupCacheKey(allowlistedHosts: [], cosmetic: true))
        XCTAssertNil(AdBlockService.startupCacheKey(allowlistedHosts: []))
    }

    @MainActor
    func testMissingNativeCompiledArtifactRegeneratesCompleteRuleList() async throws {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "soulo_ad_block_subscription_rules")
        defaults.removeObject(forKey: "soulo_ad_block_subscription_rules")
        defer { defaults.set(saved, forKey: "soulo_ad_block_subscription_rules") }
        let cache = AdBlockStartupCache.shared
        let file = try XCTUnwrap(cache.directory?.appendingPathComponent("contentRuleIdentifiers.json"))
        let previousData = try? Data(contentsOf: file)
        defer {
            if let previousData { try? previousData.write(to: file, options: .atomic) }
            else { try? FileManager.default.removeItem(at: file) }
        }
        let allowlist = ["startup-cache-fixture.example"]
        let key = try XCTUnwrap(AdBlockService.startupCacheKey(allowlistedHosts: allowlist))
        let missingIdentifier = "SouloMissingFixture-" + UUID().uuidString
        cache.write([missingIdentifier], slot: .contentRuleIdentifiers, key: key)
        let generated = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
        let rules = try XCTUnwrap(generated)
        XCTAssertFalse(rules.isEmpty)
        XCTAssertFalse(rules.contains { $0.identifier == missingIdentifier })
        XCTAssertEqual(cache.read([String].self, slot: .contentRuleIdentifiers, key: key), rules.map(\.identifier))
        let reloaded = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist)
        XCTAssertEqual(reloaded?.map(\.identifier), rules.map(\.identifier))
    }
}

@MainActor
private final class TemporaryAllowanceResourceProbe: NSObject, WKScriptMessageHandler {
    var loadedResults: [Bool] = []
    var onReport: (() -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let loaded = body["loaded"] as? Bool, loadedResults.count < 4 else { return }
        loadedResults.append(loaded)
        onReport?()
    }
}
