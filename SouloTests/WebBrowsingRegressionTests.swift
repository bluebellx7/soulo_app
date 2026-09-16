import XCTest
import SwiftUI
import WebKit
import Network
@testable import Soulo

/// Real HTTP navigation through the production representable and its delegates.
@MainActor final class WebBrowsingRegressionTests: XCTestCase {
    private var saved: [String: Any] = [:]
    private let keys = ["privacy_gpc_enabled", "privacy_gpc_header_enabled_sites",
                        "privacy_https_upgrade_enabled", "privacy_strip_tracking_parameters", "is_incognito", "ad_block_enabled"]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in keys { saved[key] = defaults.object(forKey: key) }
        defaults.set(true, forKey: "privacy_gpc_enabled")
        defaults.set(["127.0.0.1"], forKey: "privacy_gpc_header_enabled_sites")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        defaults.set(false, forKey: "privacy_strip_tracking_parameters")
        defaults.set(true, forKey: "is_incognito")
        defaults.set(true, forKey: "ad_block_enabled")
    }

    override func tearDown() {
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
        saved.removeAll()
        super.tearDown()
    }

    private func host(_ model: WebViewModel) throws -> (UIWindow, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.makeKeyAndVisible()
        return (window, previous)
    }

    private func close(_ model: WebViewModel, _ window: UIWindow, _ previous: UIWindow?) {
        window.isHidden = true
        window.rootViewController = nil
        model.releaseWebViewRuntime()
        previous?.makeKeyAndVisible()
    }

    private func wait(_ model: WebViewModel, for script: String) async throws {
        for _ in 0..<160 {
            if let web = model.webView,
               (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Page condition timed out: \(script), URL: \(String(describing: model.currentURL)), error: \(String(describing: model.errorMessage))")
        throw ReadingToolError.invalid
    }

    func testGPCDoesNotReplaceTopPageWithIframe() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("iframe"))
        try await wait(model, for: "document.getElementById('frame')?.contentDocument?.getElementById('child')?.textContent === 'Embedded content'")
        XCTAssertEqual(model.webView?.url?.path, "/iframe")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(server.requests.filter { $0.path == "/iframe" }.count, 1)
        XCTAssertEqual(server.requests.first { $0.path == "/iframe" }?.gpc, "1")
    }

    func testPOSTRedirectHistoryAndNewWindowLinks() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.getElementById('form').submit()")
        try await wait(model, for: "!!document.getElementById('receipt')")
        let submissions = server.requests.filter { $0.path == "/submit" }
        XCTAssertEqual(submissions.count, 1, "POST must not be replayed while applying privacy headers")
        XCTAssertEqual(submissions.first?.method, "POST")
        XCTAssertEqual(submissions.first?.body, "query=a%2Bb+%26+c")
        XCTAssertEqual(web.url?.path, "/receipt")
        XCTAssertTrue(web.canGoBack)
        web.goBack()
        try await wait(model, for: "!!document.getElementById('form')")
        XCTAssertTrue(web.canGoForward)
        web.goForward()
        try await wait(model, for: "!!document.getElementById('receipt')")
        _ = try await web.evaluateJavaScript("document.getElementById('next').click()")
        try await wait(model, for: "!!document.getElementById('destination')")
        XCTAssertEqual(web.url?.path, "/destination")
        XCTAssertNil(model.errorMessage)
    }

    func testAdRuleChangesKeepOtherScriptsAndFollowSPARoutes() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        let url = root.appendingPathComponent("dynamic")
        model.loadURL(url)
        try await wait(model, for: "!!document.getElementById('user-chosen-panel')")
        let web = try XCTUnwrap(model.webView)
        web.configuration.userContentController.addUserScript(WKUserScript(
            source: "window.__regressionScript = (window.__regressionScript || 0) + 1;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let rule = try XCTUnwrap(ManualAdBlockService.shared.save(url: url, selector: "#user-chosen-panel", wholeSite: false))
        defer { ManualAdBlockService.shared.remove(rule.id) }
        try await wait(model, for: "getComputedStyle(document.getElementById('user-chosen-panel')).display === 'none'")
        _ = try await web.evaluateJavaScript("history.pushState({}, '', '/dynamic-next')")
        try await wait(model, for: "getComputedStyle(document.getElementById('user-chosen-panel')).display !== 'none'")
        web.reload()
        try await wait(model, for: "window.__regressionScript === 1 && !!document.getElementById('user-chosen-panel')")
        XCTAssertEqual(web.url?.path, "/dynamic-next")
        XCTAssertNil(model.errorMessage)
    }

    func testNewWindowPOSTKeepsSubmittedBody() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form-popup"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.getElementById('form').submit()")
        for _ in 0..<100 {
            if server.requests.contains(where: { $0.path == "/receipt" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let submissions = server.requests.filter { $0.path == "/submit" }
        XCTAssertEqual(submissions.count, 1)
        XCTAssertEqual(submissions.first?.method, "POST")
        XCTAssertEqual(submissions.first?.body, "query=a%2Bb+%26+c", "New-window submissions must keep the original form body")
    }

    func testAuthenticationPopupSharesSessionAndReturnsToOpener() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("auth-parent"))
        try await wait(model, for: "!!document.getElementById('open-login')")
        let web = try XCTUnwrap(model.webView)
        // Use window.open rather than target=_blank (which has implicit noopener).
        _ = try await web.evaluateJavaScript("document.cookie='fixture_session=parent; path=/'; document.getElementById('open-login').click()")
        try await wait(model, for: "window.authResult === 'session-shared'")
        XCTAssertEqual(web.url?.path, "/auth-parent", "Popup login must leave the original page intact")
        let cookies = try await web.evaluateJavaScript("document.cookie") as? String
        XCTAssertTrue(cookies?.contains("fixture_login=complete") == true)
        for _ in 0..<100 {
            if !web.subviews.contains(where: { $0.subviews.contains(where: { $0 is WKWebView }) }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(web.subviews.contains(where: { $0.subviews.contains(where: { $0 is WKWebView }) }), "window.close must dismiss the authentication popup")
        XCTAssertNil(model.errorMessage)
    }

    func testRemountKeepsFormHistoryAndDoesNotDuplicateScripts() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("destination"))
        try await wait(model, for: "!!document.getElementById('destination')")
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        let web = try XCTUnwrap(model.webView)
        _ = try await web.evaluateJavaScript("document.querySelector('input').value='Unsaved draft'; window.tabMarker=42")
        let scriptCount = web.configuration.userContentController.userScripts.count
        let requestCount = server.requests.count
        for _ in 0..<3 {
            window.rootViewController = UIHostingController(rootView: Color.clear)
            for _ in 0..<100 {
                if !model.isWebViewRuntimeInstalled { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.isWebViewRuntimeInstalled)
            window.rootViewController = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
            for _ in 0..<100 {
                if model.isWebViewRuntimeInstalled { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(model.isWebViewRuntimeInstalled)
            XCTAssertTrue(model.webView === web)
            try await wait(model, for: "window.tabMarker === 42 && document.querySelector('input')?.value === 'Unsaved draft'")
            XCTAssertEqual(web.configuration.userContentController.userScripts.count, scriptCount)
            XCTAssertTrue(web.canGoBack)
        }
        XCTAssertEqual(server.requests.count, requestCount, "Returning to an existing tab must not reload its page")
        web.goBack()
        try await wait(model, for: "!!document.getElementById('destination')")
    }

    func testLateCompiledRulesRespectDisabledFilterAndChallengePage() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let model = WebViewModel()
        model.webView = web
        defer { model.releaseWebViewRuntime() }
        web.load(URLRequest(url: root.appendingPathComponent("destination")))
        try await wait(model, for: "!!document.getElementById('destination')")
        let compiled = await AdBlockService.compileRules()
        let rules = try XCTUnwrap(compiled)
        func canFetch() async throws -> Bool {
            let result = try await web.callAsyncJavaScript(
                "try { return (await fetch('/ads/probe', {cache:'no-store'})).ok; } catch (_) { return false; }",
                arguments: [:], in: nil, contentWorld: .page)
            return result as? Bool == true
        }
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let blocked = try await canFetch()
        XCTAssertFalse(blocked, "Control: the native rule must actually block this resource")
        UserDefaults.standard.set(false, forKey: "ad_block_enabled")
        // Deliver the compiled result after the preference changed.
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let disabled = try await canFetch()
        XCTAssertTrue(disabled, "Late compilation must not re-enable a disabled filter")
        UserDefaults.standard.set(true, forKey: "ad_block_enabled")
        web.load(URLRequest(url: root.appendingPathComponent("login")))
        try await wait(model, for: "location.pathname === '/login' && !!document.getElementById('destination')")
        WebViewRepresentable.applyContentRules(rules, on: web, allowlist: [])
        let challenge = try await canFetch()
        XCTAssertTrue(challenge, "Late compilation must respect the current challenge page bypass")
    }

    func testRapidNavigationRefreshAndRecoveryAfterNetworkFailure() async throws {
        let server = try BrowsingHTTPFixture()
        let root = try await server.start()
        defer { server.stop() }
        let model = WebViewModel()
        let (window, previous) = try host(model)
        defer { close(model, window, previous) }
        model.loadURL(root.appendingPathComponent("form"))
        model.loadURL(root.appendingPathComponent("destination"))
        try await wait(model, for: "!!document.getElementById('destination')")
        let web = try XCTUnwrap(model.webView)
        web.scrollView.refreshControl?.beginRefreshing()
        web.scrollView.refreshControl?.sendActions(for: .valueChanged)
        for _ in 0..<100 {
            if server.requests.filter({ $0.path == "/destination" }).count >= 2,
               web.scrollView.refreshControl?.isRefreshing == false { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(server.requests.filter { $0.path == "/destination" }.count, 2)
        XCTAssertEqual(web.scrollView.refreshControl?.isRefreshing, false)
        model.loadURL(root.appendingPathComponent("disconnect"))
        for _ in 0..<100 {
            if model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(model.errorMessage)
        model.loadURL(root.appendingPathComponent("form"))
        try await wait(model, for: "!!document.getElementById('form')")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(web.url?.path, "/form")
    }
}

private final class BrowsingHTTPFixture: @unchecked Sendable {
    struct Request {
        let method: String
        let path: String
        let body: String
        let gpc: String?
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.browsing.fixture")
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    private var startupCompleted = false
    var requests: [Request] { queue.sync { recorded } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.startupCompleted else { return }
                switch state {
                case .ready:
                    self.startupCompleted = true
                    continuation.resume(returning: URL(string: "http://127.0.0.1:\(self.listener.port!.rawValue)")!)
                case .failed(let error):
                    self.startupCompleted = true
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, buffered: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { connection.cancel(); return }
            var bytes = buffered
            if let data { bytes.append(data) }
            guard bytes.count < 1024 * 1024 else { connection.cancel(); return }
            if let split = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: bytes[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") {
                        headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if first.count >= 2, bytes.count - split.upperBound >= length {
                    let request = Request(method: String(first[0]), path: String(first[1]),
                        body: String(decoding: bytes[split.upperBound..<split.upperBound + length], as: UTF8.self), gpc: headers["sec-gpc"])
                    self.recorded.append(request)
                    self.respond(connection, to: request)
                    return
                }
            }
            if done || error != nil { connection.cancel() }
            else { self.receive(connection, buffered: bytes) }
        }
    }

    private func respond(_ connection: NWConnection, to request: Request) {
        let body: String
        var status = "200 OK"
        var extra = ""
        switch request.path {
        case "/auth-parent": body = "<button id='open-login' onclick=\"window.open('/login-popup','fixture-auth')\">Sign in</button><script>addEventListener('message', e => { if (e.origin === location.origin) window.authResult = e.data; });</script>"
        case "/login-popup": body = "<script>const shared = document.cookie.includes('fixture_session=parent'); document.cookie='fixture_login=complete; path=/'; window.opener.postMessage(shared ? 'session-shared' : 'missing-session', location.origin); window.close();</script>"
        case "/disconnect": connection.cancel(); return
        case "/dynamic", "/dynamic-next": body = "<main>Article content</main><aside id='user-chosen-panel'>Selected panel</aside>"
        case "/iframe": body = "<h1 id='parent'>Parent page</h1><iframe id='frame' src='/child'></iframe>"
        case "/child": body = "<p id='child'>Embedded content</p>"
        case "/form": body = "<form id='form' method='post' action='/submit'><input name='query' value='a+b &amp; c'><button>Submit</button></form>"
        case "/form-popup": body = "<form id='form' method='post' action='/submit' target='_blank'><input name='query' value='a+b &amp; c'><button>Submit</button></form>"
        case "/submit": body = "Redirecting"; status = "303 See Other"; extra = "Location: /receipt\r\n"
        case "/receipt": body = "<p id='receipt'>Submitted</p><a id='next' href='/destination' target='_blank'>Next page</a>"
        default: body = "<p id='destination'>Destination</p>"
        }
        let html = "<!doctype html><html><head><meta name='viewport' content='width=device-width'><title>Browsing fixture</title></head><body>\(body)</body></html>"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\n\(extra)Connection: close\r\n\r\n\(html)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}
