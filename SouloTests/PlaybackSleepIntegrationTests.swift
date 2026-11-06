import AVFoundation
import MobileVLCKit
import SwiftUI
import XCTest
@testable import Soulo

@MainActor
final class PlaybackSleepIntegrationTests: XCTestCase {
    func testAfterCurrentItemStopsTheActualQueueInBothModesAndSystemCanReplay() async throws {
        let fixture = try makeAudioQueue(firstSeconds: 3, nextSeconds: 10)
        let saved = PlaybackPreferencesSnapshot()
        defer { saved.restore(using: fixture.urls[0]); remove(fixture) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = MediaSession.shared

        for engine in ["soulo", "system"] {
            prepare(engine: engine, urls: fixture.urls)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: AnyView(NavigationStack { LocalDocumentContent(url: fixture.urls[0]) }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                session.stop(); previous?.makeKeyAndVisible()
            }
            try await wait("The first audio item must actually play in \(engine)") {
                session.url == fixture.urls[0] && session.playing && !session.hasVideo
                    && session.duration > 1 && self.actualClock(session) > 0.15
            }
            XCTAssertEqual(session.soulo != nil, engine == "soulo")
            session.sleepTimer.stopAfterCurrentItem()
            XCTAssertTrue(session.sleepTimer.stopsAfterCurrentItem)
            // Use the existing mini-player host path: leaving the original
            // file page must preserve the queue and its one shared timer.
            host.rootView = AnyView(ZStack { Text("File list"); MediaMiniPlayer() })
            try await wait("Natural end must consume the timer and pause instead of advancing: \(engine)") {
                !session.sleepTimer.isActive && !session.isPlaybackRequested && !session.playing
            }
            XCTAssertEqual(session.url, fixture.urls[0], "After-current must prevent automatic next in \(engine)")
            XCTAssertNil(session.sleepTimer.deadline)
            XCTAssertFalse(session.sleepTimer.stopsAfterCurrentItem)
            XCTAssertNil(session.error)
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(session.url, fixture.urls[0])
            XCTAssertFalse(session.playing)

            if engine == "system" {
                try await wait("The native ended handler must rewind the actual AVPlayer clock") {
                    let time = session.player.currentTime().seconds
                    return time.isFinite && time < 0.15
                }
                session.play()
                try await wait("A manual play after the timer consumed native end must replay from zero") {
                    let time = session.player.currentTime().seconds
                    return session.playing && time > 0.15 && time < 1.5
                }
                XCTAssertEqual(session.url, fixture.urls[0])
                session.pause()
            }

            XCTAssertTrue(session.advanceLocalAudio(by: 1), "Stopping at end must retain the sibling queue")
            try await wait("The retained next item must remain playable: \(engine)") {
                session.url == fixture.urls[1] && session.playing && self.actualClock(session) > 0.15
            }
            XCTAssertEqual(session.soulo != nil, engine == "soulo")
            XCTAssertFalse(session.sleepTimer.isActive)
        }
    }

    func testShortDeadlinePausesTheActualAudioClockAndRetainsTheQueueInBothModes() async throws {
        let fixture = try makeAudioQueue(firstSeconds: 12, nextSeconds: 12)
        let saved = PlaybackPreferencesSnapshot()
        defer { saved.restore(using: fixture.urls[0]); remove(fixture) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let session = MediaSession.shared

        for engine in ["soulo", "system"] {
            prepare(engine: engine, urls: fixture.urls)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: AnyView(NavigationStack { LocalDocumentContent(url: fixture.urls[0]) }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer {
                window.isHidden = true; window.rootViewController = nil
                session.stop(); previous?.makeKeyAndVisible()
            }
            try await wait("The long audio fixture must actually play in \(engine)") {
                session.url == fixture.urls[0] && session.playing && !session.hasVideo
                    && session.duration > 8 && self.actualClock(session) > 0.15
            }
            XCTAssertEqual(session.soulo != nil, engine == "soulo")
            host.rootView = AnyView(ZStack { Text("File list"); MediaMiniPlayer() })
            let before = actualClock(session)
            XCTAssertTrue(session.sleepTimer.start(after: 0.3))
            try await wait("The actual scheduled deadline must pause \(engine)", timeout: .seconds(4)) {
                !session.sleepTimer.isActive && !session.isPlaybackRequested && !session.playing
            }
            // Allow decoder pause delivery to settle, then compare its real
            // clock rather than a frozen presentation value or fake timer.
            try await Task.sleep(for: .milliseconds(200))
            let stopped = actualClock(session)
            XCTAssertGreaterThanOrEqual(stopped, before - 0.05)
            XCTAssertLessThan(stopped, before + 1.5, "A 300 ms deadline must pause well before natural end")
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(actualClock(session), stopped, accuracy: 0.2, "The real decoder must remain paused: \(engine)")
            XCTAssertEqual(session.url, fixture.urls[0])
            XCTAssertFalse(session.isPlaybackRequested)
            XCTAssertNil(session.error)

            XCTAssertTrue(session.advanceLocalAudio(by: 1), "Deadline expiry must preserve the sibling queue")
            try await wait("The next item must still play after an explicit next command: \(engine)") {
                session.url == fixture.urls[1] && session.playing && self.actualClock(session) > 0.15
            }
            XCTAssertEqual(session.soulo != nil, engine == "soulo")
            XCTAssertFalse(session.sleepTimer.isActive)
        }
    }

    private func actualClock(_ session: MediaSession) -> Double {
        if let playback = session.soulo { return Double(playback.player?.time.intValue ?? 0) / 1000 }
        return session.player.currentTime().seconds
    }

    private func wait(_ message: String, timeout: Duration = .seconds(10),
                      file: StaticString = #filePath, line: UInt = #line,
                      until predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < end {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTFail(message, file: file, line: line)
        throw URLError(.timedOut)
    }

    private func prepare(engine: String, urls: [URL]) {
        let session = MediaSession.shared
        session.stop(); session.setBackgrounded(false); session.loop = false
        UserDefaults.standard.set(engine, forKey: VideoPlaybackPreferences.defaultPlayerKey)
        UserDefaults.standard.set(1.0, forKey: "media.rate")
        _ = session.setRate(1)
        urls.forEach { UserDefaults.standard.removeObject(forKey: MediaSession.positionKey($0)) }
    }

    private func makeAudioQueue(firstSeconds: Int, nextSeconds: Int) throws -> (root: URL, urls: [URL]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackSleep-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
            let urls = [root.appendingPathComponent("2.wav"), root.appendingPathComponent("10.wav")]
            for (file, seconds) in zip(urls, [firstSeconds, nextSeconds]) {
                let frames = AVAudioFrameCount(seconds * 8_000)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
                buffer.frameLength = frames
                if let samples = buffer.floatChannelData?[0] {
                    for index in 0..<Int(frames) { samples[index] = Float(sin(Double(index) * 0.1)) * 0.05 }
                }
                try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
            }
            XCTAssertEqual(FileVideoEpisodes.localURLs(in: root, audio: true).map(\.lastPathComponent), ["2.wav", "10.wav"])
            return (root, urls)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private func remove(_ fixture: (root: URL, urls: [URL])) {
        fixture.urls.forEach { UserDefaults.standard.removeObject(forKey: MediaSession.positionKey($0)) }
        try? FileManager.default.removeItem(at: fixture.root)
    }
}

@MainActor
private struct PlaybackPreferencesSnapshot {
    let mode = UserDefaults.standard.object(forKey: VideoPlaybackPreferences.defaultPlayerKey)
    let storedRate = UserDefaults.standard.object(forKey: "media.rate")
    let rate = MediaSession.shared.rate
    let loop = MediaSession.shared.loop
    let backgrounded = UIApplication.shared.applicationState == .background

    func restore(using file: URL) {
        let session = MediaSession.shared, defaults = UserDefaults.standard
        session.stop()
        if !session.setRate(rate) {
            // The public setter rejects >2x without a loaded fast-forwardable
            // item. Opening paused reloads the exact old preference immediately;
            // stop retires its readiness callbacks before they can change it.
            defaults.set(rate, forKey: "media.rate")
            session.open(url: file, persistPosition: false, autoplay: false)
            session.stop()
        }
        session.loop = loop; session.setBackgrounded(backgrounded)
        defaults.set(mode, forKey: VideoPlaybackPreferences.defaultPlayerKey)
        defaults.set(storedRate, forKey: "media.rate")
    }
}
