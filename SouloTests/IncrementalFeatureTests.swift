import XCTest
import AVFoundation
import SwiftUI
import WebKit
import UniformTypeIdentifiers
@testable import Soulo

final class IncrementalFeatureTests: XCTestCase {
    func testHandoffDoesNotPublishPrivateOrLocalContent() {
        for address in ["file:///tmp/a", "http://127.0.0.1/", "http://192.168.1.2/", "http://[::1]/", "https://host.local/a", "https://user:pass@example.com/", "data:text/plain,secret", "https://localhost/"] {
            XCTAssertNil(BrowserHandoff.eligibleURL(URL(string: address), isPrivate: false), address)
        }
        let url = URL(string: "https://example.com/page?q=hello#section")!
        XCTAssertNil(BrowserHandoff.eligibleURL(url, isPrivate: true))
        XCTAssertEqual(BrowserHandoff.eligibleURL(url, isPrivate: false), url)
    }
    func testExplicitEncodingAndBOMDetection() throws {
        let value = "书籍 繁體 café 😀"
        for encoding: String.Encoding in [.utf8, .utf16, .utf32] {
            XCTAssertEqual(try TextBookDecoder.decode(XCTUnwrap(value.data(using: encoding))), value)
        }
        let log = "\u{1b}[32mgreen\u{1b}[0m"
        XCTAssertEqual(try TextBookDecoder.decode(Data(log.utf8)), log, "ANSI text logs remain readable")
        let western = Data([0x63, 0x61, 0x66, 0xe9])
        XCTAssertEqual(try TextBookDecoder.decode(western, encoding: "Windows-1252"), "café")
        XCTAssertThrowsError(try TextBookDecoder.decode(western, encoding: "UTF-8"))
        XCTAssertThrowsError(try TextBookDecoder.decode(Data([0, 1, 2, 3]), encoding: "ISO-8859-1"))
        XCTAssertThrowsError(try TextBookDecoder.decode(Data("text".utf8), encoding: "invalid"))
    }
    func testChineseDisplayPreservesOriginalAndNonChinese() {
        XCTAssertEqual(ChineseTextDisplay.convert("汉语阅读", mode: "traditional"), "漢語閱讀")
        XCTAssertEqual(ChineseTextDisplay.convert("漢語閱讀", mode: "simplified"), "汉语阅读")
        XCTAssertEqual(ChineseTextDisplay.convert("Hello 😀 123", mode: "traditional"), "Hello 😀 123")
        XCTAssertEqual(ChineseTextDisplay.convert("頭髮", mode: "original"), "頭髮")
    }
    func testStagingOwnsTemporaryFileAndAvoidsOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("中文.txt")
        try Data("original".utf8).write(to: source)
        let staged = try LibraryFileImport.stage(source)
        let copy = try LibraryFileImport.commit(staged, to: root)
        XCTAssertNotEqual(copy, source)
        XCTAssertEqual(try Data(contentsOf: copy), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try LibraryFileImport.stage(link))
        XCTAssertThrowsError(try LibraryFileImport.stage(root))
    }
    func testProviderFileSurvivesCompletion() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("provider data".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: source))
        provider.suggestedName = "Imported.txt"
        let staged = try await LibraryFileImport.receive(provider)
        defer { LibraryFileImport.discard(staged) }
        XCTAssertEqual(try Data(contentsOf: staged), Data("provider data".utf8))
        XCTAssertEqual(staged.lastPathComponent, "Imported.txt")
    }
    func testFileURLProviderWithUnrelatedMetadata() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("URL file".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        provider.registerDataRepresentation(forTypeIdentifier: "com.example.metadata", visibility: .all) { reply in
            reply(Data(), nil); return nil
        }
        let staged = try await LibraryFileImport.receive(provider)
        defer { LibraryFileImport.discard(staged) }
        XCTAssertEqual(try Data(contentsOf: staged), Data("URL file".utf8))
    }
    @MainActor func testMiniPlayerCannotStealAndDetachPrimaryVideoSurface() throws {
        let pip = MediaPictureInPicture()
        let mini = UUID(), primary = UUID()
        let thumbnail = try XCTUnwrap(pip.attach(id: mini, primary: false))
        let full = try XCTUnwrap(pip.attach(id: primary))
        XCTAssertTrue(full === thumbnail)
        XCTAssertNil(pip.attach(id: mini, primary: false))
        pip.detach(id: mini)
        XCTAssertTrue(pip.surface === full)
        XCTAssertNotNil(full.playerLayer.player)
        pip.detach(id: primary)
        XCTAssertNil(pip.surface)
        XCTAssertNotNil(pip.attach(id: mini, primary: false))
        pip.detach(id: mini)
    }
    @MainActor func testVideoBoostInterruptionAndCapture() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let session = MediaSession.shared
        let oldRate = session.rate
        defer { session.setRate(oldRate); session.stop() }
        session.open(url: fixture)
        session.setRate(1.5)
        try await wait { session.hasVideo && session.player.rate > 0 && session.player.currentTime().seconds > 0.1 }
        let savedRate = UserDefaults.standard.float(forKey: "media.rate")
        session.beginTemporaryRate()
        XCTAssertTrue(session.temporaryRate)
        XCTAssertEqual(session.player.rate, 2)
        XCTAssertEqual(UserDefaults.standard.float(forKey: "media.rate"), savedRate)
        session.endTemporaryRate()
        XCTAssertEqual(session.player.rate, 1.5)
        session.beginTemporaryRate()
        await Task.detached {
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        }.value
        try await wait { !session.temporaryRate }
        XCTAssertEqual(session.player.rate, 1.5)
        let image = try await session.captureFrame()
        XCTAssertGreaterThan(image.size.width, 0)
        session.beginTemporaryRate()
        session.handleInterruption(began: true, shouldResume: false)
        XCTAssertFalse(session.temporaryRate)
        XCTAssertEqual(session.player.rate, 0)
        session.handleInterruption(began: false, shouldResume: true)
        try await wait { session.player.rate == 1.5 }
        session.handleInterruption(began: true, shouldResume: false)
        session.pause() // A user pause must override a later system resume.
        session.handleInterruption(began: false, shouldResume: true)
        XCTAssertEqual(session.player.rate, 0)
        session.beginTemporaryRate()
        XCTAssertFalse(session.temporaryRate)
    }
    @MainActor func testReaderChineseConversionIsReversibleInWebKit() async throws {
        let original = "汉语阅读 頭髮 😀 Original"
        let controller = BookReaderController(book: LibraryBook(id: UUID().uuidString, name: "Conversion", fileName: "conversion.txt"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(rootView: BookWebSurface(
            data: Data(original.utf8), textData: try JSONEncoder().encode([original, "第二章 汉语阅读"]), format: .text, controller: controller))
        window.makeKeyAndVisible(); window.layoutIfNeeded()
        defer { window.isHidden = true }
        try await wait { controller.ready || controller.error != nil }
        XCTAssertNil(controller.error)
        let web = try XCTUnwrap(controller.webView)
        let script = "document.querySelector('foliate-view').renderer.getContents().map(x => x.doc.body.textContent).join(' ')"
        for (mode, expected) in [("traditional", "漢語閱讀 頭髮"), ("simplified", "汉语阅读 头发"), ("original", "汉语阅读 頭髮")] {
            controller.chineseDisplay = mode; controller.style()
            var text = ""
            for _ in 0..<50 {
                text = (try await web.evaluateJavaScript(script) as? String) ?? ""
                if text.contains(expected) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(text.contains(expected), "\(mode): \(text)")
            XCTAssertTrue(text.contains("😀 Original"))
        }
    }
    @MainActor private func wait(_ predicate: () -> Bool) async throws {
        let end = Date().addingTimeInterval(15)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate())
    }
}
