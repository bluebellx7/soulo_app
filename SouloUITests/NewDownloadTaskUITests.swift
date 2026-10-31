import XCTest
import CryptoKit

final class NewDownloadTaskUITests: XCTestCase {
    @MainActor
    func testCreateTaskFormValidatesAddressAndCanCancel() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US"]
        app.launch()
        app.open(URL(string: "soulo://downloads")!)
        let create = app.buttons["downloads.new"]
        XCTAssertTrue(create.waitForExistence(timeout: 15), app.debugDescription)
        create.tap()
        let field = app.textFields["downloads.new.address"].exists ? app.textFields["downloads.new.address"] : app.textViews["downloads.new.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap(); field.typeText("not-a-link")
        app.buttons["downloads.new.create"].tap()
        XCTAssertTrue(app.staticTexts["Enter a valid HTTP, HTTPS or magnet link."].waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "new-download-validation"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
    }
}

extension NewDownloadTaskUITests {
    @MainActor
    func testCreateOrdinaryHTTPDownloadFromDownloadsPage() async throws {
        continueAfterFailure = false
        let name = "manual-" + UUID().uuidString + ".txt"
        let server = try DownloadPlaybackHTTPFixture(files: ["/" + name: Data("Manual download fixture".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US"]
        app.launch(); app.open(URL(string: "soulo://downloads")!)
        XCTAssertTrue(app.buttons["downloads.new"].waitForExistence(timeout: 10))
        app.buttons["downloads.new"].tap()
        let field = app.textFields["downloads.new.address"].exists ? app.textFields["downloads.new.address"] : app.textViews["downloads.new.address"]
        field.tap(); field.typeText(root.appendingPathComponent(name).absoluteString)
        app.buttons["downloads.new.create"].tap()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["downloads.new"].waitForExistence(timeout: 10), "The form should close after creating a native task")
        XCTAssertTrue(app.staticTexts["Finished"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
    }
}


extension NewDownloadTaskUITests {
    @MainActor
    func testTorrentURLShowsFilesWithoutStartingPayloadAndCanBeRemoved() async throws {
        continueAfterFailure = false
        func bencode(_ value: Any) -> Data {
            if let data = value as? Data { return Data("\(data.count):".utf8) + data }
            if let text = value as? String { return bencode(Data(text.utf8)) }
            if let number = value as? Int { return Data("i\(number)e".utf8) }
            if let list = value as? [Any] { return Data("l".utf8) + list.reduce(Data()) { $0 + bencode($1) } + Data("e".utf8) }
            let map = value as! [String: Any]
            return Data("d".utf8) + map.keys.sorted().reduce(Data()) { $0 + bencode($1) + bencode(map[$1]!) } + Data("e".utf8)
        }
        let name = "TorrentUI-" + UUID().uuidString.prefix(6)
        let metadata = bencode(["info": ["name": name, "piece length": 16384,
            "pieces": Data(Insecure.SHA1.hash(data: Data("hello".utf8))),
            "files": [["length": 5, "path": ["hello.txt"]]]]])
        let server = try DownloadPlaybackHTTPFixture(files: ["/sample.torrent": metadata])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US"]
        app.launch(); app.open(URL(string: "soulo://downloads")!)
        XCTAssertTrue(app.buttons["downloads.new"].waitForExistence(timeout: 10))
        app.buttons["downloads.new"].tap()
        let field = app.textFields["downloads.new.address"].exists ? app.textFields["downloads.new.address"] : app.textViews["downloads.new.address"]
        field.tap(); field.typeText(root.appendingPathComponent("sample.torrent").absoluteString)
        app.buttons["downloads.new.create"].tap()
        let file = app.buttons["torrent.file.0"]
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Choose files to download"].exists)
        XCTAssertEqual(file.value as? String, "selected")
        file.tap(); XCTAssertFalse(app.buttons["torrent.start"].isEnabled)
        file.tap(); XCTAssertTrue(app.buttons["torrent.start"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "torrent-file-selection"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Cancel"].firstMatch.tap()
        let row = app.cells.containing(.staticText, identifier: String(name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.swipeLeft(); app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts[String(name)].exists)
    }
}
