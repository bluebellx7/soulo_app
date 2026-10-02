import XCTest
import Network

/// Actual screen taps catch chrome occlusion that model-only navigation tests miss.
final class BrowserToolbarResponsivenessUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    private var fixture: ToolbarHTTPFixture!
    private var root: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        fixture = try ToolbarHTTPFixture()
        root = try fixture.start()
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
    }

    override func tearDownWithError() throws { fixture?.stop() }

    private func open(_ path: String) throws {
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent(path).absoluteString)]
        app.open(try XCTUnwrap(route.url))
    }

    private func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element.isHittable, app.debugDescription)
        // Coordinate taps exercise hit testing instead of accessibility activation.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func checkMoreAndTabs() {
        let more = app.buttons["More"].firstMatch
        let panel = app.popovers.firstMatch
        for _ in 0..<3 {
            tap(more)
            XCTAssertTrue(panel.waitForExistence(timeout: 5), app.debugDescription)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5), app.debugDescription)
        }
        tap(app.buttons["browser.tabs"])
        let newTab = app.buttons["tabs.tab_new_tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5), app.debugDescription)
        tap(newTab)
        XCTAssertTrue(app.buttons["browser.tabs"].waitForExistence(timeout: 5))
    }

    func testPageLinksAndBottomToolbarRespondDuringSlowLoading() throws {
        try open("slow")
        let link = app.webViews.links["Next page"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(fixture.hasPendingSlowResource)
        checkMoreAndTabs()
        XCTAssertTrue(fixture.hasPendingSlowResource)
        // Return through the real overview to exercise retained WebView remounting.
        tap(app.buttons["browser.tabs"])
        let card = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Toolbar fixture,")).firstMatch
        tap(card)
        tap(link)
        XCTAssertTrue(app.webViews.staticTexts["Second page"].firstMatch.waitForExistence(timeout: 10))
        tap(app.buttons["Back"].firstMatch)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        tap(app.buttons["Home Screen"].firstMatch)
        XCTAssertTrue(app.buttons["Home Screen"].firstMatch.waitForNonExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "toolbar-responsive-returned-home"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBottomToolbarRespondsBeforeBlockedDocumentFinishes() throws {
        try open("blocked")
        XCTAssertTrue(app.buttons["browser.tabs"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.webViews.staticTexts["Interactive page"].firstMatch.exists)
        XCTAssertTrue(fixture.hasPendingSlowResource)
        checkMoreAndTabs()
    }

    func testToolbarRespondsAfterAddressKeyboardDismissal() throws {
        try open("slow")
        XCTAssertTrue(app.webViews.links["Next page"].firstMatch.waitForExistence(timeout: 20))
        for _ in 0..<2 {
            tap(app.buttons["Edit Address or Search"].firstMatch)
            let field = app.textFields["addressEditor.query"].firstMatch
            tap(field)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(field.waitForNonExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        checkMoreAndTabs()
    }
}

private final class ToolbarHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "soulo.toolbar.ui-fixture")
    private var connections: [NWConnection] = []
    private var slowRequests = 0
    private var completedSlowRequests = 0
    var hasPendingSlowResource: Bool { queue.sync { slowRequests > completedSlowRequests } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self, let data else { connection.cancel(); return }
                let path = String(decoding: data, as: UTF8.self).split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body: String
                if path == "/slow.js" { body = "window.slowResourceFinished=true;" }
                else if path == "/second" { body = "<html><body><p>Second page</p></body></html>" }
                else {
                    let script = path == "/blocked" ? "<script src='/slow.js'></script>" : "<script async src='/slow.js'></script>"
                    body = "<html><head><title>Toolbar fixture</title>\(script)</head><body style='font:20px system-ui'><p>Interactive page</p><a href='/second'>Next page</a></body></html>"
                }
                let bytes = Data(body.utf8)
                let type = path == "/slow.js" ? "application/javascript" : "text/html; charset=utf-8"
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(bytes.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(bytes)
                let send = { connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() }) }
                if path == "/slow.js" {
                    self.slowRequests += 1
                    self.queue.asyncAfter(deadline: .now() + 180) { [weak self] in
                        self?.completedSlowRequests += 1
                        send()
                    }
                }
                else { send() }
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
            throw NSError(domain: "ToolbarHTTPFixture", code: 1)
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }

    func stop() {
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() }
    }
}
