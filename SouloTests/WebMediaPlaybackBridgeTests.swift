import XCTest
import WebKit
import UIKit
@testable import Soulo

@MainActor final class WebMediaPlaybackBridgeTests: XCTestCase {
    private func page(_ html: String = "<video id='v' src='data:video/mp4;base64,'></video>") async throws -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        web.loadHTMLString("<html><body>\(html)</body></html>", baseURL: URL(string: "https://media.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('v')")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ReadingToolError.invalid
    }
    private func nativeRate(_ web: WKWebView) async throws -> Double {
        let value = try await web.evaluateJavaScript("Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype,'playbackRate').get.call(document.getElementById('v'))")
        return try XCTUnwrap(value as? Double)
    }

    func testIsolatedSetterBypassesPageWrapperThatPretendsToSetRate() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("Object.defineProperty(document.getElementById('v'), 'playbackRate', {get(){return 8},set(value){}});true")
        let rates = try await WebMediaPlaybackBridge.setRate(2, on: web)
        XCTAssertEqual(rates, [2])
        let actual = try await nativeRate(web)
        XCTAssertEqual(actual, 2)
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.rate, 2)
    }

    func testStartupResetIsRepairedAndReplacementInheritsSelectedRate() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("setTimeout(() => document.getElementById('v').playbackRate=1, 80)")
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        let repaired = try await nativeRate(web)
        XCTAssertEqual(repaired, 2)
        _ = try await web.evaluateJavaScript("const next=document.createElement('video');next.id='v';next.src='data:video/mp4;base64,';document.getElementById('v').replaceWith(next)")
        try await Task.sleep(for: .milliseconds(250))
        let replacement = try await nativeRate(web)
        XCTAssertEqual(replacement, 2)
        _ = try await web.evaluateJavaScript("const v=document.getElementById('v');v.playbackRate=1;v.dispatchEvent(new Event('loadedmetadata'));v.dispatchEvent(new Event('play'))")
        try await Task.sleep(for: .milliseconds(100))
        let restarted = try await nativeRate(web)
        XCTAssertEqual(restarted, 2)
    }

    func testPersistentSiteResetIsBoundedAndDoesNotReportSuccess() async throws {
        let web = try await page()
        _ = try await web.evaluateJavaScript("window.changes=0;const v=document.getElementById('v');v.addEventListener('ratechange',()=>{window.changes++;if(v.playbackRate!==1)v.playbackRate=1;v.dispatchEvent(new Event('play'))})")
        do { _ = try await WebMediaPlaybackBridge.setRate(2, on: web); XCTFail("Must not claim a rejected rate succeeded") }
        catch ReadingToolError.unsupported { }
        try await Task.sleep(for: .milliseconds(300))
        let changeValue = try await web.evaluateJavaScript("window.changes")
        let changes = try XCTUnwrap(changeValue as? Int)
        XCTAssertLessThan(changes, 20)
        try await Task.sleep(for: .milliseconds(200))
        let laterValue = try await web.evaluateJavaScript("window.changes")
        let later = try XCTUnwrap(laterValue as? Int)
        XCTAssertEqual(changes, later)
    }

    func testOneTimesReleasesRestorationAndNativeControlsWorkAfterStartup() async throws {
        let web = try await page()
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        try await Task.sleep(for: .milliseconds(2100))
        _ = try await web.evaluateJavaScript("document.getElementById('v').playbackRate=1.5")
        try await Task.sleep(for: .milliseconds(100))
        let nativeChoice = try await nativeRate(web)
        XCTAssertEqual(nativeChoice, 1.5)
        _ = try await WebMediaPlaybackBridge.setRate(1, on: web)
        _ = try await web.evaluateJavaScript("const v=document.getElementById('v');v.playbackRate=1.5;v.dispatchEvent(new Event('play'))")
        try await Task.sleep(for: .milliseconds(100))
        let released = try await nativeRate(web)
        XCTAssertEqual(released, 1.5)
    }

    func testVisiblePlayerDeterminesDisplayedRateInsteadOfHiddenPreload() async throws {
        let web = try await page("<video id='hidden' src='data:video/mp4;base64,' style='display:none'></video><video id='v' src='data:video/mp4;base64,' style='width:300px;height:200px'></video>")
        _ = try await web.evaluateJavaScript("document.getElementById('v').playbackRate=2")
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.count, 2)
        XCTAssertEqual(state.rate, 2)
    }

    func testNavigationDoesNotCarryRateIntoAnotherDocument() async throws {
        let web = try await page()
        _ = try await WebMediaPlaybackBridge.setRate(2, on: web)
        web.loadHTMLString("<html><body><video id='next' src='data:video/mp4;base64,'></video></body></html>", baseURL: URL(string: "https://other.test/"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('next')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let state = await WebMediaPlaybackBridge.inspect(web)
        XCTAssertEqual(state.rate, 1)
        XCTAssertEqual(state.count, 1)
    }

    func testRealVideoTimelineAdvancesFasterAtTwoTimes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac",
            withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("video.mp4"))
        let html = root.appendingPathComponent("index.html")
        try "<html><body><video id='v' muted playsinline src='video.mp4'></video></body></html>".write(to: html, atomically: true, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 600), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController(); host.view.addSubview(web)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { web.stopLoading(); window.isHidden = true; previous?.makeKey() }
        web.loadFileURL(html, allowingReadAccessTo: root)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.getElementById('v')?.readyState >= 2")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await web.callAsyncJavaScript("await document.getElementById('v').play(); return true", arguments: [:], in: nil, contentWorld: .defaultClient)
        var deltas: [Double] = []
        for rate in [1.0, 2.0] {
            _ = try await WebMediaPlaybackBridge.setRate(rate, on: web)
            // Let WebKit finish switching the media pipeline before measuring steady-state speed.
            try await Task.sleep(for: .seconds(1))
            let before = try await web.evaluateJavaScript("JSON.stringify({time:v.currentTime,rate:v.playbackRate,ready:v.readyState,paused:v.paused,ended:v.ended})")
            print("WEB_MEDIA_BEFORE \(rate): \(String(describing: before))")
            let start = try await web.evaluateJavaScript("document.getElementById('v').currentTime") as! Double
            try await Task.sleep(for: .milliseconds(1000))
            let end = try await web.evaluateJavaScript("document.getElementById('v').currentTime") as! Double
            deltas.append(end - start)
            let after = try await web.evaluateJavaScript("JSON.stringify({time:v.currentTime,rate:v.playbackRate,ready:v.readyState,paused:v.paused,ended:v.ended})")
            print("WEB_MEDIA_AFTER \(rate): \(String(describing: after))")
        }
        XCTAssertGreaterThan(deltas[0], 0.3)
        XCTAssertGreaterThan(deltas[1], deltas[0] * 1.5)
        print("WEB_MEDIA_TIMELINE 1x=\(deltas[0]), 2x=\(deltas[1]) over 1 second")
    }

}
