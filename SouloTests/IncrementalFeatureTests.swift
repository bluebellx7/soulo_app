import XCTest
import AVFoundation
import AVKit
import SwiftUI
import WebKit
import UniformTypeIdentifiers
@testable import Soulo

final class IncrementalFeatureTests: XCTestCase {
    func testHoldSpeedDefaultsAndRejectsInvalidSavedValues() throws {
        let suite = "HoldSpeed-\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VideoPlaybackPreferences.holdSpeed(in: defaults), 2)
        for rate in VideoPlaybackPreferences.holdSpeeds {
            defaults.set(rate, forKey: VideoPlaybackPreferences.holdSpeedKey)
            XCTAssertEqual(VideoPlaybackPreferences.holdSpeed(in: defaults), rate)
        }
        for rate in [-1.0, 0, 0.5, 1, 8, Double.nan, Double.infinity] {
            defaults.set(rate, forKey: VideoPlaybackPreferences.holdSpeedKey)
            XCTAssertEqual(VideoPlaybackPreferences.holdSpeed(in: defaults), 2)
        }
    }

    func testSeekKeepsTargetWhileBufferingAndReleasesOnArrivalOrTimeout() {
        let start = ContinuousClock.now, seek = VideoPlaybackSeek(target: 120, started: start)
        XCTAssertTrue(seek.isPending(actual: 8, now: start.advanced(by: .seconds(3))))
        XCTAssertTrue(seek.isPending(actual: 35, now: start.advanced(by: .seconds(8))))
        XCTAssertFalse(seek.isPending(actual: 120.3, now: start.advanced(by: .seconds(9))))
        XCTAssertFalse(seek.isPending(actual: 8, now: start.advanced(by: .seconds(21))))
    }
    @MainActor func testDecoderSwitchKeepsOneFullscreenWindowAndSourceMounted() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let firstOwner = UUID(), nextOwner = UUID()
        var closed: [String] = []
        defer {
            SharedVideoFullscreenHost.current(in: window)?.dismiss(owner: nextOwner)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        let first = try XCTUnwrap(SharedVideoFullscreenHost.present(owner: firstOwner, in: window,
            content: AnyView(Color.black), identifier: "media.fullscreen.player", landscape: false,
            onClose: { closed.append("old") }))
        try await wait { first.screen?.view.window === window }
        let controller = try XCTUnwrap(first.screen)
        XCTAssertTrue(root.view.window === window, "The destination decoder must be able to mount before the old player closes")
        first.setLandscape(true)
        try await wait { scene.interfaceOrientation.isLandscape }
        XCTAssertEqual(controller.supportedInterfaceOrientations, .landscape)
        first.beginHandoff(owner: firstOwner)
        first.release(owner: firstOwner)
        XCTAssertTrue(root.presentedViewController === controller, "Retiring the old adapter must not dismiss the shared window")
        let next = try XCTUnwrap(SharedVideoFullscreenHost.present(owner: nextOwner, in: window,
            content: AnyView(Text("Soulo")), identifier: "media.mkv.fullscreen.player", landscape: false,
            onClose: { closed.append("new") }))
        XCTAssertTrue(next === first)
        XCTAssertTrue(next.screen === controller)
        XCTAssertEqual(controller.supportedInterfaceOrientations, .landscape, "A decoder change must keep the selected fullscreen direction")
        first.release(owner: firstOwner)
        XCTAssertTrue(root.presentedViewController === controller)
        next.setLandscape(false)
        try await wait { scene.interfaceOrientation == .portrait }
        XCTAssertTrue(root.presentedViewController === controller, "Changing direction must not exit fullscreen")
        XCTAssertEqual(controller.supportedInterfaceOrientations, .portrait)
        next.dismiss(owner: nextOwner)
        try await wait { root.presentedViewController == nil }
        await VideoOrientation.waitForRestoration(in: scene)
        XCTAssertEqual(closed, ["new"], "Only the active playback mode owns the close callback")
    }

    @MainActor func testForegroundRestoresLandscapeWithoutDeviceRotationAndRespectsManualPortrait() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, original = scene.interfaceOrientation
        let window = UIWindow(windowScene: scene), root = OrientationTestController()
        window.rootViewController = root; window.makeKeyAndVisible()
        let rotation = WebVideoFullscreenOrientation(deviceOrientation: { .portrait })
        let fullscreen = OrientationTestController()
        fullscreen.modalPresentationStyle = .fullScreen
        defer {
            rotation.end(); root.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            VideoOrientation.request(VideoOrientation.mask(for: original), in: scene) { _ in }
        }
        rotation.prepare(token: "foreground-qa", scene: scene, prefersLandscape: true)
        root.present(fullscreen, animated: false)
        rotation.begin(token: "foreground-qa") { XCTFail($0.localizedDescription) }
        try await wait { scene.interfaceOrientation.isLandscape }

        // Model UIKit restoring portrait while the physical phone stays upright.
        // No UIDevice orientation notification is generated on return.
        VideoOrientation.request(.portrait, in: scene) { XCTFail($0.localizedDescription) }
        try await wait { scene.interfaceOrientation == .portrait }
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await wait { scene.interfaceOrientation.isLandscape }

        rotation.setFullscreenOrientation(false, in: scene, sourceView: nil) { XCTFail($0.localizedDescription) }
        try await wait { scene.interfaceOrientation == .portrait }
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scene.interfaceOrientation, .portrait, "Returning must retain an explicit portrait selection")
        rotation.end(); fullscreen.dismiss(animated: false)
        await VideoOrientation.waitForRestoration(in: scene)
        let restored = scene.interfaceOrientation
        NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scene.interfaceOrientation, restored, "After exit, foreground events must not rotate the page")
    }

    @MainActor func testBackgroundPausesNativeVideoAndRetainsPositionUntilManualResume() async throws {
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let session = MediaSession.shared, oldRate = session.rate
        session.stop(); session.setBackgrounded(false); session.setRate(1)
        defer { session.setBackgrounded(false); session.stop(); session.setRate(oldRate) }
        session.open(url: video, persistPosition: false)
        try await wait { session.hasVideo && session.player.currentTime().seconds > 0.2 }
        session.setBackgrounded(true)
        XCTAssertFalse(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, 0)
        session.play()
        XCTAssertEqual(session.player.rate, 0, "A delayed play callback must not restart video in the background")
        let paused = session.player.currentTime().seconds
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(session.player.currentTime().seconds, paused, accuracy: 0.1)
        session.setBackgrounded(false)
        session.handleInterruption(began: false, shouldResume: true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.player.rate, 0, "Foreground and a late interruption-end event must not restart video")
        session.play()
        try await wait { session.player.currentTime().seconds > paused + 0.2 }
    }

    @MainActor func testNativeVideoBecomingReadyInBackgroundDoesNotAutoplay() async throws {
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let session = MediaSession.shared
        session.stop(); session.setBackgrounded(true)
        defer { session.setBackgrounded(false); session.stop() }
        session.open(url: video, persistPosition: false)
        try await wait { session.hasVideo && session.player.currentItem?.status == .readyToPlay }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, 0)
        session.setBackgrounded(false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.player.rate, 0)
    }

    @MainActor func testBackgroundPausesSouloVideoBeforeMountAndDuringPlayback() async throws {
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let session = MediaSession.shared, oldRate = session.rate
        session.stop(); session.setBackgrounded(false); session.setRate(1)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), root = UIViewController()
        window.rootViewController = root; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        defer {
            session.setBackgrounded(false); session.stop(); session.setRate(oldRate)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        playback.open(video)
        session.setBackgrounded(true)
        playback.attach(root.view)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(playback.isPlaybackRequested)
        XCTAssertFalse(playback.player?.isPlaying ?? true, "A late video surface must not restart the paused decoder")
        session.setBackgrounded(false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(playback.isPlaybackRequested)
        playback.play()
        try await wait { playback.elapsed > 0.2 && playback.playing }
        session.setBackgrounded(true)
        XCTAssertFalse(playback.isPlaybackRequested)
        XCTAssertFalse(session.playing)
        playback.play()
        XCTAssertFalse(playback.isPlaybackRequested)
        let paused = playback.elapsed
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(playback.elapsed, paused, accuracy: 0.3)
    }

    @MainActor func testLocalAudioContinuesInBackgroundInBothPlayerModes() async throws {
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("background-audio-\(UUID()).m4a")
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: video), presetName: AVAssetExportPresetAppleM4A))
        try await export.export(to: audio, as: .m4a)
        let session = MediaSession.shared, oldRate = session.rate
        session.stop(); session.setBackgrounded(false); session.setRate(1)
        defer {
            session.setBackgrounded(false); session.stop(); session.setRate(oldRate)
            try? FileManager.default.removeItem(at: audio)
        }
        for soulo in [false, true] {
            session.setBackgrounded(false); session.stop()
            if soulo { MatroskaPlayback().open(audio) } else { session.open(url: audio, persistPosition: false) }
            try await wait { session.elapsed > 0.1 && session.playing && !session.hasVideo }
            session.setBackgrounded(true)
            let start = session.elapsed
            try await wait { session.elapsed > start + 0.3 }
            XCTAssertTrue(session.isPlaybackRequested, "Background music must continue in both decoder modes")
            XCTAssertTrue(session.playing)
        }
    }

    @MainActor func testExplicitPictureInPictureContinuesUntilStoppedInBackground() async throws {
        try XCTSkipUnless(AVPictureInPictureController.isPictureInPictureSupported(), "System PiP is unavailable on this test device; real PiP requires a supported device")
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let session = MediaSession.shared, oldRate = session.rate
        session.stop(); session.setBackgrounded(false); session.setRate(1)
        defer { session.setBackgrounded(false); session.stop(); session.setRate(oldRate) }
        session.open(url: video, persistPosition: false)
        try await wait { session.hasVideo && session.player.currentTime().seconds > 0.2 }
        let layer = AVPlayerLayer(player: session.player)
        let controller = try XCTUnwrap(AVPictureInPictureController(playerLayer: layer))
        let pip = session.pictureInPicture
        pip.pictureInPictureControllerWillStartPictureInPicture(controller)
        session.setBackgrounded(true)
        XCTAssertTrue(session.isPlaybackRequested, "PiP startup must not be interrupted by backgrounding")
        pip.pictureInPictureControllerDidStartPictureInPicture(controller)
        let start = session.player.currentTime().seconds
        try await wait { session.player.currentTime().seconds > start + 0.2 }
        pip.pictureInPictureControllerDidStopPictureInPicture(controller)
        XCTAssertFalse(session.isPlaybackRequested)
        XCTAssertEqual(session.player.rate, 0, "Closing PiP in the background must not leave video audio playing")
    }

    @MainActor func testTimelineResumesProgressAfterCancelledScrubbing() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let controls = VideoControlsVisibility()
        var seeks: [Double] = []
        controls.update(enabled: true, playing: true, buffering: false, voiceOver: false)
        let root = UIHostingController(rootView: VideoPlaybackTimeline(elapsed: 1, duration: 20,
            identifier: "timeline.qa", seek: { seeks.append($0) }, interactionChanged: controls.interaction))
        window.rootViewController = root; window.makeKeyAndVisible()
        defer { controls.cancel(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func find(_ view: UIView) -> UISlider? {
            if let slider = view as? UISlider { return slider }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        try await Task.sleep(for: .milliseconds(100))
        let slider = try XCTUnwrap(find(root.view))
        let scale = (slider.maximumValue - slider.minimumValue) / 20
        XCTAssertEqual(slider.value, slider.minimumValue + scale, accuracy: 0.01)
        slider.sendActions(for: .touchDown)
        slider.value = slider.minimumValue + 9 * scale; slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchCancel)
        XCTAssertTrue(seeks.isEmpty, "A cancelled drag must not seek")
        root.rootView = VideoPlaybackTimeline(elapsed: 3.2, duration: 20,
            identifier: "timeline.qa", seek: { seeks.append($0) }, interactionChanged: controls.interaction)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(slider.value, slider.minimumValue + 3.2 * scale, accuracy: 0.01, "A cancelled drag must release the thumb back to the playback clock")
        slider.sendActions(for: .touchDown)
        slider.value = slider.minimumValue + 7 * scale; slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
        slider.sendActions(for: .valueChanged)
        XCTAssertEqual(seeks, [7], "A slider release must commit one seek, including UIKit's final valueChanged")
        root.rootView = VideoPlaybackTimeline(elapsed: 7.5, duration: 20,
            identifier: "timeline.qa", seek: { seeks.append($0) }, interactionChanged: controls.interaction)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(slider.value, slider.minimumValue + 7.5 * scale, accuracy: 0.01, "A completed drag must resume following the playback clock")
    }

    @MainActor func testControlsAutoHideByDefaultAndWaitForInteraction() async throws {
        let controls = VideoControlsVisibility(); defer { controls.cancel() }
        controls.update(enabled: true, playing: true, buffering: false, voiceOver: false)
        try await Task.sleep(for: .milliseconds(3150))
        XCTAssertFalse(controls.visible)
        controls.interaction(true)
        try await Task.sleep(for: .milliseconds(3150))
        XCTAssertTrue(controls.visible)
        controls.interaction(false)
        try await Task.sleep(for: .milliseconds(3150))
        XCTAssertFalse(controls.visible)
    }

    @MainActor func testFullscreenFollowsBothDeviceSidesAndStopsFollowingAfterExit() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, original = scene.interfaceOrientation
        let window = UIWindow(windowScene: scene), root = OrientationTestController()
        window.rootViewController = root; window.makeKeyAndVisible()
        var physical = UIDeviceOrientation.landscapeLeft
        var errors: [String] = []
        let rotation = WebVideoFullscreenOrientation(deviceOrientation: { physical })
        defer {
            rotation.end()
            root.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            VideoOrientation.request(VideoOrientation.mask(for: original), in: scene) { _ in }
        }
        let pageOrientation = scene.interfaceOrientation
        rotation.prepare(token: "sides-qa", scene: scene, prefersLandscape: true)
        let fullscreen = OrientationTestController()
        fullscreen.modalPresentationStyle = .fullScreen
        root.present(fullscreen, animated: false)
        rotation.begin(token: "sides-qa") { errors.append($0.localizedDescription) }
        try await wait { scene.interfaceOrientation == .landscapeRight }
        for direction in [UIDeviceOrientation.landscapeRight, .landscapeLeft, .landscapeRight] {
            physical = direction
            NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
            let expected: UIInterfaceOrientation = direction == .landscapeLeft ? .landscapeRight : .landscapeLeft
            try await wait { scene.interfaceOrientation == expected }
        }
        physical = .faceUp
        NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scene.interfaceOrientation, .landscapeLeft, "Laying the phone flat must keep the current side")
        rotation.end()
        fullscreen.dismiss(animated: false)
        try await wait { scene.interfaceOrientation == pageOrientation }
        physical = .landscapeLeft
        NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scene.interfaceOrientation, pageOrientation, "Late orientation events must not rotate the underlying page")
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }
    @MainActor func testAlreadyFullscreenRestoresBrowserInsteadOfNativeKeyWindow() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, original = scene.interfaceOrientation
        let browser = UIWindow(windowScene: scene), page = OrientationTestController()
        let native = UIWindow(windowScene: scene), fullscreen = OrientationTestController()
        browser.rootViewController = page; browser.makeKeyAndVisible()
        let rotation = WebVideoFullscreenOrientation(deviceOrientation: { .landscapeLeft })
        defer {
            rotation.end()
            native.isHidden = true; native.rootViewController = nil
            browser.isHidden = true; browser.rootViewController = nil; previous?.makeKeyAndVisible()
            VideoOrientation.request(VideoOrientation.mask(for: original), in: scene) { _ in }
        }
        VideoOrientation.request(.portrait, in: scene) { _ in }
        try await wait { scene.interfaceOrientation == .portrait }
        // Direct media documents can already have made AVKit's window key
        // when the user chooses Play in landscape.
        native.rootViewController = fullscreen; native.makeKeyAndVisible()
        rotation.prepare(token: "late-native", scene: scene, prefersLandscape: true,
                         nativeWebKit: true, sourceView: page.view)
        var errors: [String] = []
        rotation.begin(token: "late-native") { errors.append($0.localizedDescription) }
        try await wait { scene.interfaceOrientation == .landscapeRight }
        rotation.nativeFullscreenEnded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(scene.interfaceOrientation, .landscapeRight, "Do not rotate the dismissing native window")
        native.isHidden = true; browser.makeKeyAndVisible()
        await VideoOrientation.waitForRestoration(in: scene)
        XCTAssertEqual(scene.interfaceOrientation, .portrait, "The browser must recover its original orientation")
        NotificationCenter.default.post(name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(scene.interfaceOrientation, .portrait)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
    }

    @MainActor func testFullscreenLandscapeRespectsDeviceSideAndKeepsFlatOrientation() {
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .landscapeLeft, interface: .portrait), .landscapeRight)
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .landscapeRight, interface: .portrait), .landscapeLeft)
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .faceUp, interface: .landscapeRight), .landscapeRight)
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .faceDown, interface: .landscapeLeft), .landscapeLeft)
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .unknown, interface: .portrait), .landscape)
        XCTAssertEqual(VideoOrientation.landscapeMask(device: .portrait, interface: .landscapeLeft), .landscapeLeft)
    }
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
    @MainActor func testNativeHoldSpeedAboveTwoAdvancesAtTheSelectedRateForMP4AndHLS() async throws {
        let defaults = UserDefaults.standard, session = MediaSession.shared
        let savedHold = defaults.object(forKey: VideoPlaybackPreferences.holdSpeedKey)
        let savedRate = defaults.object(forKey: "media.rate"), oldRate = session.rate
        defer {
            session.stop(); session.setRate(oldRate)
            defaults.set(savedHold, forKey: VideoPlaybackPreferences.holdSpeedKey)
            defaults.set(savedRate, forKey: "media.rate")
        }
        let mp4 = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<12 {
            let part = index % 4
            let segment = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(part)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(part).ts"] = try Data(contentsOf: segment)
            if index > 0, part == 0 { playlist += "#EXT-X-DISCONTINUITY\n" }
            playlist += "#EXTINF:2.022,\nsegment\(part).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        defaults.set(2.5, forKey: VideoPlaybackPreferences.holdSpeedKey)
        for url in [mp4, root.appendingPathComponent("video.m3u8")] {
            session.stop(); session.setRate(1)
            session.open(url: url, persistPosition: false, startAt: 0)
            try await wait { session.hasVideo && session.player.currentTime().seconds > 1.5 && session.player.rate > 0 }
            let capability = session.player.currentItem?.canPlayFastForward == true
            session.beginTemporaryRate()
            XCTAssertEqual(session.player.rate, 2.5, url.pathExtension)
            XCTAssertEqual(session.temporaryRateFeedback, 2.5, url.pathExtension)
            // Exclude the audio time-pitch pipeline's rate-change startup.
            try await Task.sleep(for: .milliseconds(250))
            let start = session.player.currentTime().seconds
            let measuredAt = ContinuousClock.now
            try await Task.sleep(for: .milliseconds(url.pathExtension == "m3u8" ? 2500 : 1200))
            let advanced = session.player.currentTime().seconds - start
            let wallTime = measuredAt.duration(to: .now).components
            let seconds = Double(wallTime.seconds) + Double(wallTime.attoseconds) / 1e18
            let observedRate = advanced / seconds
            print("NATIVE_HOLD_RATE|type=\(url.pathExtension)|fastForward=\(capability)|rate=\(session.player.rate)|observed=\(observedRate)")
            XCTAssertEqual(observedRate, 2.5, accuracy: 0.35, "The playback clock must follow the selected rate: \(url.pathExtension)")
            session.endTemporaryRate()
            XCTAssertEqual(session.player.rate, 1)
            XCTAssertEqual(session.temporaryRateFeedback, 1)
            XCTAssertEqual(defaults.float(forKey: "media.rate"), 1)
            XCTAssertNil(session.error)
        }
    }

    @MainActor func testVideoBoostInterruptionAndCapture() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        // Keep the native rate/interruption unit independent of the app's
        // floating-player surface and the preceding shared decoder sessions.
        let session = MediaSession()
        let oldRate = session.rate, savedHold = UserDefaults.standard.object(forKey: VideoPlaybackPreferences.holdSpeedKey)
        UserDefaults.standard.removeObject(forKey: VideoPlaybackPreferences.holdSpeedKey)
        defer {
            session.setRate(oldRate); session.stop()
            UserDefaults.standard.set(savedHold, forKey: VideoPlaybackPreferences.holdSpeedKey)
        }
        session.open(url: fixture)
        session.setRate(1.5)
        try await wait { session.hasVideo && session.player.rate > 0 && session.player.currentTime().seconds > 0.1 }
        let savedRate = UserDefaults.standard.float(forKey: "media.rate")
        session.beginTemporaryRate()
        XCTAssertTrue(session.temporaryRate)
        XCTAssertEqual(session.player.rate, 2)
        XCTAssertEqual(session.temporaryRateFeedback, 2)
        XCTAssertEqual(UserDefaults.standard.float(forKey: "media.rate"), savedRate)
        session.endTemporaryRate()
        XCTAssertEqual(session.player.rate, 1.5)
        XCTAssertEqual(session.temporaryRateFeedback, 1.5)
        UserDefaults.standard.set(1.75, forKey: VideoPlaybackPreferences.holdSpeedKey)
        session.beginTemporaryRate()
        XCTAssertEqual(session.player.rate, 1.75)
        session.endTemporaryRate()
        XCTAssertEqual(session.player.rate, 1.5)
        UserDefaults.standard.removeObject(forKey: VideoPlaybackPreferences.holdSpeedKey)
        // AVKit's own controls can change the current rate independently of
        // the browser's saved preference; restore that actual prior rate.
        session.player.rate = 0.75
        session.beginTemporaryRate()
        XCTAssertEqual(session.player.rate, 2)
        session.endTemporaryRate()
        XCTAssertEqual(session.player.rate, 0.75)
        session.setRate(1.5)
        XCTAssertEqual(session.player.rate, 1.5)
        session.beginTemporaryRate()
        // UIKit also observes this system notification and requires delivery
        // on the main thread, just as during an actual app interruption.
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
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
        session.stop()
        XCTAssertNil(session.temporaryRateFeedback)
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

private final class OrientationTestController: UIViewController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
}
