import WebKit
import XCTest
@testable import Soulo

@MainActor
final class KimiInteractionTests: XCTestCase {
    private func fixture(disabled: Bool = false, login: Bool = false) async throws -> (WKWebView, UIWindow) {
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        let window = UIWindow(frame: web.frame); let controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(web); window.makeKeyAndVisible()
        web.loadHTMLString("""
        <html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body>
        \(login ? "<button class='login-button'>Login</button>" : "")
        <div class='chat-input-editor' data-lexical-editor='true' contenteditable='true' role='textbox' style='width:300px;height:90px;border:1px solid gray'></div>
        <button id='plugin' onclick='window.plugins++'>Plugins</button>
        <div class='send-button-container' aria-disabled='\(disabled ? "true" : "false")' style='width:50px;height:50px;background:blue' onclick='window.sends++;this.innerHTML="<span>Stop</span>"'>
        <svg class='send-icon' name='Send' width='20' height='20'></svg></div>
        <script>window.sends=0;window.plugins=0;</script></body></html>
        """, baseURL: URL(string: "https://www.kimi.com/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.querySelector('.chat-input-editor')")) as? Bool == true { return (web, window) }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw URLError(.timedOut)
    }
    func testKimiFillsLexicalEditorAndSendsExactlyOnceWithoutClickingPlugins() async throws {
        let (web, window) = try await fixture(); defer { web.stopLoading(); window.isHidden = true }
        let query = "Soulo 'Kimi' 中文"
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.kimiChatScript(query: query))
        try await Task.sleep(for: .seconds(2))
        let text = try await web.evaluateJavaScript("document.querySelector('.chat-input-editor').innerText")
        let sends = try await web.evaluateJavaScript("window.sends")
        let plugins = try await web.evaluateJavaScript("window.plugins")
        XCTAssertEqual(text as? String, query)
        XCTAssertEqual(sends as? Int, 1)
        XCTAssertEqual(plugins as? Int, 0)
    }
    func testKimiHonorsDisabledSendAndCancelsPendingInteraction() async throws {
        let (web, window) = try await fixture(disabled: true); defer { web.stopLoading(); window.isHidden = true }
        _ = try await web.evaluateJavaScript(AIPlatformInteractionService.kimiChatScript(query: "test"))
        try await Task.sleep(for: .seconds(1.5))
        AIPlatformInteractionService.cancelInteraction(in: web)
        let sends = try await web.evaluateJavaScript("window.sends")
        let disabled = try await web.evaluateJavaScript("document.querySelector('.send-button-container').getAttribute('aria-disabled')")
        XCTAssertEqual(sends as? Int, 0)
        XCTAssertEqual(disabled as? String, "true")
    }
    func testKimiDetectsVisibleLoginEvenWhenGuestEditorExists() async throws {
        let (web, window) = try await fixture(login: true); defer { web.stopLoading(); window.isHidden = true }
        let status = try await web.evaluateJavaScript(AIPlatformInteractionService.loginDetectionScript(for: "Kimi"))
        XCTAssertEqual(status as? String, "needs_login")
    }
    func testKimiIsHiddenInTheDefaultCatalog() throws {
        let kimi = try XCTUnwrap(PlatformDataStore.defaultPlatforms().first { $0.name == "Kimi" })
        XCTAssertFalse(kimi.isVisible)
        XCTAssertTrue(kimi.requiresLogin)
        XCTAssertEqual(kimi.interactionType, .aiChat)
    }
    func testKimiMigrationAddsHiddenEntryAndPreservesManualEnable() throws {
        let defaults = UserDefaults.standard, store = PlatformDataStore.shared
        let data = defaults.data(forKey: "platform_config"), version = defaults.object(forKey: "platform_config_version")
        defer {
            defaults.set(data, forKey: "platform_config"); defaults.set(version, forKey: "platform_config_version"); store.reloadFromDefaults()
        }
        let old = PlatformDataStore.defaultPlatforms().filter { $0.name != "Kimi" }
        defaults.set(try JSONEncoder().encode(old), forKey: "platform_config")
        defaults.set(42, forKey: "platform_config_version"); store.reloadFromDefaults()
        let kimi = try XCTUnwrap(store.platforms.first { $0.name == "Kimi" })
        XCTAssertFalse(kimi.isVisible)
        XCTAssertTrue(store.platforms.contains(where: \.isVisible))
        store.toggleVisibility(for: kimi.id)
        store.reloadFromDefaults()
        XCTAssertTrue(try XCTUnwrap(store.platforms.first { $0.id == kimi.id }).isVisible)
    }
    func testKimiMigrationPreservesAllDisabledSetting() throws {
        let defaults = UserDefaults.standard, store = PlatformDataStore.shared
        let data = defaults.data(forKey: "platform_config"), version = defaults.object(forKey: "platform_config_version")
        defer {
            defaults.set(data, forKey: "platform_config"); defaults.set(version, forKey: "platform_config_version"); store.reloadFromDefaults()
        }
        let disabled = store.platforms.filter { $0.name != "Kimi" && $0.name != "platform_kimi" }.map { var p = $0; p.isVisible = false; return p }
        defaults.set(try JSONEncoder().encode(disabled), forKey: "platform_config")
        defaults.set(42, forKey: "platform_config_version"); store.reloadFromDefaults()
        let kimi = try XCTUnwrap(store.platforms.first { $0.name == "Kimi" })
        XCTAssertEqual(kimi.homeURL, "https://www.kimi.com/")
        XCTAssertEqual(kimi.interactionType, .aiChat)
        XCTAssertTrue(kimi.requiresLogin)
        XCTAssertFalse(store.platforms.contains(where: \.isVisible))
    }
}
