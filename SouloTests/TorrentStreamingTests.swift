import AVFoundation
import Foundation
import SwiftUI
import XCTest
@testable import Soulo

final class TorrentStreamingTests: XCTestCase {
    @MainActor
    func testUnexpectedDecoderStopPublishesAnErrorAfterItsClockIsReset() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(root.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(fixture)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(playback.elapsed, 0.5)
        // Simulate the decoder stopping without a public playback.stop().
        // Its zeroed clock must not leave the UI silently stalled forever.
        playback.player?.stop()
        for _ in 0..<80 {
            if playback.error != nil, MediaSession.shared.error != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(playback.error)
        XCTAssertFalse(playback.buffering)
        XCTAssertFalse(playback.playing)
        XCTAssertNotNil(MediaSession.shared.error)
    }

    @MainActor
    func testSouloPrivatePlaybackNeverPersistsProgressWhenStoppedOrSwitchedToSystem() async throws {
        let session = MediaSession.shared, defaults = UserDefaults.standard
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let logical = try XCTUnwrap(URL(string: "https://private.example.test/\(UUID()).mp4"))
        let key = MediaSession.positionKey(logical)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(root.view)
        defer {
            playback.stop(); session.stop(); defaults.removeObject(forKey: key)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        for switching in [false, true] {
            session.open(url: fixture, persistPosition: true, autoplay: false)
            playback.open(fixture, persistPosition: false, originalURL: logical)
            for _ in 0..<100 {
                if session.elapsed > 0.3 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertGreaterThan(session.elapsed, 0.3)
            if switching {
                session.restoreSystemFromSoulo()
                for _ in 0..<100 {
                    if session.player.currentTime().seconds > 0.3 { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                XCTAssertNotNil(session.player.currentItem)
            }
            session.stop()
            XCTAssertNil(defaults.object(forKey: key), "Private progress must stay in memory after \(switching ? "switching decoders" : "stopping")")
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor
    func testSouloReplaysAfterEndAndReleasesItsScreenAwakeRequest() async throws {
        let session = MediaSession.shared, defaults = UserDefaults.standard
        session.stop()
        let preference = defaults.object(forKey: VideoScreenAwakeService.preferenceKey), loop = session.loop
        defaults.set(false, forKey: VideoScreenAwakeService.preferenceKey)
        VideoScreenAwakeService.shared.reloadUserPreference(); session.loop = false
        let baseline = UIApplication.shared.isIdleTimerDisabled
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let root = UIViewController(); window.rootViewController = root; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(root.view)
        defer {
            playback.stop(); session.stop(); session.loop = loop
            defaults.set(preference, forKey: VideoScreenAwakeService.preferenceKey)
            VideoScreenAwakeService.shared.reloadUserPreference()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
        }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        playback.open(file)
        for _ in 0..<100 {
            if playback.playing, playback.duration > 2, playback.player?.isSeekable == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(playback.playing)
        playback.seek(playback.duration - 0.4)
        for _ in 0..<100 {
            if !playback.isPlaybackRequested, !playback.playing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(playback.isPlaybackRequested)
        XCTAssertEqual(UIApplication.shared.isIdleTimerDisabled, baseline, "A completed video must release its screen-awake request")
        playback.togglePlayback()
        for _ in 0..<100 {
            if playback.playing, playback.elapsed > 0.3, playback.elapsed < playback.duration - 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(playback.playing)
        XCTAssertGreaterThan(playback.elapsed, 0.3, "Replay must restart the observable playback clock")
        XCTAssertLessThan(playback.elapsed, playback.duration - 1)
    }

    @MainActor
    func testHLSTimelineAdvancesAndSeeksWhileVideoFramesKeepPlaying() async throws {
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: file)
            playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        let live = ProcessInfo.processInfo.environment["SOULO_LIVE_VIDEO_URL"].flatMap(URL.init(string:))
        let referrer = ProcessInfo.processInfo.environment["SOULO_LIVE_VIDEO_REFERRER"].flatMap(URL.init(string:))
        let context = live.map { VideoPlaybackRequestContext(url: $0, referrer: referrer,
            userAgent: AppConstants.mobileWebViewUserAgent, cookies: []) }
        let startAt = ProcessInfo.processInfo.environment["SOULO_LIVE_VIDEO_START"].flatMap(Double.init)
        let prepared: SouloMediaPlaybackSource?
        if let live {
            let asset = AVURLAsset(url: live, options: [AVURLAssetHTTPUserAgentKey: AppConstants.mobileWebViewUserAgent,
                AVURLAssetOverrideMIMETypeKey: "application/vnd.apple.mpegurl"])
            do { print("PROTECTION_PROBE|\(try await asset.load(.hasProtectedContent))") }
            catch { print("PROTECTION_PROBE_ERROR|\((error as NSError).domain)|\((error as NSError).code)") }
            prepared = try await SouloMediaPlaybackSource.prepare(
                native: DownloadPlaybackSource(asset: asset, pageURL: referrer, webView: nil), originalURL: live)
        } else { prepared = nil }
        window.rootViewController = UIHostingController(rootView: MatroskaPlayerView(
            url: prepared?.url ?? root.appendingPathComponent("video.m3u8"), resourceLease: prepared, requestContext: context,
            persistPosition: false, startAt: startAt))
        window.makeKeyAndVisible()
        func findSurface(_ view: UIView) -> MatroskaVideoSurface? {
            if let surface = view as? MatroskaVideoSurface { return surface }
            return view.subviews.lazy.compactMap { findSurface($0) }.first
        }
        func findTimeline(_ view: UIView) -> UISlider? {
            if let slider = view as? UISlider, slider.accessibilityIdentifier == "media.mkv.timeline" { return slider }
            return view.subviews.lazy.compactMap { findTimeline($0) }.first
        }
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for _ in 0..<30 {
            if findSurface(try XCTUnwrap(window.rootViewController?.view))?.playback != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let playback = try XCTUnwrap(findSurface(try XCTUnwrap(window.rootViewController?.view))?.playback)
        defer { playback.stop() }
        for _ in 0..<200 {
            if playback.elapsed > max(1, (startAt ?? 0) + 0.5),
               (playback.player?.media?.statistics.displayedPictures ?? 0) > 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("HLS_CLOCK|elapsed=\(playback.elapsed)|duration=\(playback.duration)|time=\(String(describing: playback.player?.time.value))|remaining=\(String(describing: playback.player?.remainingTime?.value))|position=\(playback.player?.position ?? -1)")
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.duration, 6, "A VOD needs a valid seek range")
        let slider = try XCTUnwrap(findTimeline(try XCTUnwrap(window.rootViewController?.view)))
        let displayedTime = slider.value
        let elapsed = playback.elapsed, frames = playback.player?.media?.statistics.displayedPictures ?? 0
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertGreaterThan(playback.elapsed, elapsed + 0.5, "Progress must advance with video frames")
        XCTAssertGreaterThan(playback.player?.media?.statistics.displayedPictures ?? 0, frames)
        XCTAssertGreaterThan(slider.value, displayedTime + 0.5, "The visible timeline must advance with the decoded video")
        XCTAssertEqual(Double(slider.value), playback.elapsed, accuracy: 0.6)
        let framesBeforeSeek = playback.player?.media?.statistics.displayedPictures ?? 0
        playback.seek(5)
        for _ in 0..<80 {
            if playback.elapsed > 5.3,
               Double(playback.player?.time.intValue ?? 0) / 1000 > 5.3,
               (playback.player?.media?.statistics.displayedPictures ?? 0) > framesBeforeSeek { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(playback.elapsed, 5.3)
        XCTAssertGreaterThan(Double(playback.player?.time.intValue ?? 0) / 1000, 5.3,
                             "Seeking must move the decoder clock as well as the displayed time")
        XCTAssertGreaterThan(playback.player?.media?.statistics.displayedPictures ?? 0, framesBeforeSeek)
        for _ in 0..<30 {
            if abs(Double(slider.value) - playback.elapsed) < 0.6 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(Double(slider.value), playback.elapsed, accuracy: 0.6, "The timeline must resume following the clock after a seek")
    }

    @MainActor
    func testOfflineHLSPlaybackLinksDecimalFragmentsAndPreservesDiscontinuities() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("OfflinePlaybackQA-\(UUID())")
        let package = root.appendingPathComponent("sample.movpkg")
        let rendition = package.appendingPathComponent("rendition")
        try manager.createDirectory(at: rendition, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n"
        var originals: [URL] = []
        for index in 0..<4 {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            let target = rendition.appendingPathComponent("(\(Double(index) * 2.022))_(0)_(2.022).frag")
            try manager.copyItem(at: source, to: target); originals.append(target)
            if index == 2 { manifest += "#EXT-X-DISCONTINUITY\n" }
            manifest += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        try (manifest + "#EXT-X-ENDLIST\n").write(to: rendition.appendingPathComponent("media.m3u8"), atomically: true, encoding: .utf8)
        let source = DownloadPlaybackSource(asset: AVURLAsset(url: package), pageURL: nil, webView: nil)
        let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: package)
        let exported = try String(contentsOf: prepared.url, encoding: .utf8)
        XCTAssertTrue(exported.contains("#EXT-X-DISCONTINUITY\n#EXTINF:2.02200,\n000002.ts"))
        for (index, original) in originals.enumerated() {
            let linked = prepared.url.deletingLastPathComponent().appendingPathComponent(String(format: "%06d.ts", index))
            XCTAssertEqual(try manager.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber,
                           try manager.attributesOfItem(atPath: linked.path)[.systemFileNumber] as? NSNumber,
                           "Playback must share the downloaded bytes without copying the video")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(try XCTUnwrap(window.rootViewController?.view))
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(prepared.url, resourceLease: prepared)
        for _ in 0..<120 {
            if playback.elapsed > 1, (playback.player?.media?.statistics.displayedPictures ?? 0) > 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.player?.media?.statistics.displayedPictures ?? 0, 2)
        XCTAssertGreaterThan(playback.elapsed, 1)
        XCTAssertTrue(originals.allSatisfy { manager.fileExists(atPath: $0.path) })
    }

    @MainActor
    func testPortableHLSFolderOpensAsVideoAndPlaysInSharedFilePlayer() async throws {
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent("HLSFolderQA-\(UUID())")
        let package = root.appendingPathComponent("Episode 2.hls", isDirectory: true)
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard, key = VideoPlaybackPreferences.defaultPlayerKey, saved = defaults.object(forKey: key)
        defaults.set("soulo", forKey: key)
        defer { defaults.set(saved, forKey: key); try? manager.removeItem(at: root) }
        var manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            try manager.copyItem(at: file, to: package.appendingPathComponent("segment\(index).ts"))
            manifest += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        let playlist = package.appendingPathComponent("index.m3u8")
        try (manifest + "#EXT-X-ENDLIST\n").write(to: playlist, atomically: true, encoding: .utf8)
        XCTAssertEqual(FilePresentation.inspect(package).kind, .video)
        XCTAssertEqual(try LocalHLSMedia.playlistURL(for: package).resolvingSymlinksInPath(), playlist.resolvingSymlinksInPath())
        XCTAssertEqual(FileVideoEpisodes.localURLs(in: root).map(\.lastPathComponent), [package.lastPathComponent])
        XCTAssertGreaterThan(FileStorageSize.bytes(at: package) ?? 0, 1000)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: NavigationStack { LocalDocumentContent(url: package) })
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func surface(_ view: UIView) -> MatroskaVideoSurface? {
            if let result = view as? MatroskaVideoSurface { return result }
            return view.subviews.lazy.compactMap { surface($0) }.first
        }
        for _ in 0..<120 {
            if let playback = surface(try XCTUnwrap(window.rootViewController?.view))?.playback,
               playback.elapsed > 0.5, (playback.player?.media?.statistics.displayedPictures ?? 0) > 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let playback = try XCTUnwrap(surface(try XCTUnwrap(window.rootViewController?.view))?.playback)
        defer { playback.stop() }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5)
        XCTAssertGreaterThan(playback.player?.media?.statistics.displayedPictures ?? 0, 2)
        XCTAssertGreaterThan(playback.duration, 6)
    }

    func testPortableHLSPackageNeverSelectsAnExternalSymlink() throws {
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent("HLSLinksQA-\(UUID())")
        let package = root.appendingPathComponent("Video.hls"), external = root.appendingPathComponent("outside.m3u8")
        try manager.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try "#EXTM3U\n#EXT-X-ENDLIST\n".write(to: external, atomically: true, encoding: .utf8)
        try manager.createSymbolicLink(at: package.appendingPathComponent("master.m3u8"), withDestinationURL: external)
        XCTAssertThrowsError(try LocalHLSMedia.playlistURL(for: package))
        let internalPlaylist = package.appendingPathComponent("index.m3u8")
        try "#EXTM3U\n#EXT-X-ENDLIST\n".write(to: internalPlaylist, atomically: true, encoding: .utf8)
        XCTAssertEqual(try LocalHLSMedia.playlistURL(for: package).resolvingSymlinksInPath(), internalPlaylist.resolvingSymlinksInPath())
    }

    @MainActor
    func testMP4UsesSouloByDefaultForFilesAndDownloadPlayback() async throws {
        let defaults = UserDefaults.standard
        let keys = [VideoPlaybackPreferences.defaultPlayerKey, "media.file.systemPlayer"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.removeObject(forKey: keys[0]); defaults.set(true, forKey: keys[1])
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let server = try DownloadPlaybackHTTPFixture(files: ["/clip.mp4": Data(contentsOf: file)])
        let remote = try await server.start().appendingPathComponent("clip.mp4")
        defer { server.stop() }
        for url in [file, remote] {
            MediaSession.shared.stop()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            await VideoOrientation.waitForRestoration(in: scene)
            let previous = scene.windows.first(where: \.isKeyWindow), window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                if url.isFileURL { LocalDocumentContent(url: url) }
                else { MediaPlaybackContent() }
            })
            window.makeKeyAndVisible()
            if !url.isFileURL { MediaSession.shared.open(url: url, persistPosition: false) }
            var playback: MatroskaPlayback?
            func find(_ view: UIView) -> MatroskaPlayback? {
                if let surface = view as? MatroskaVideoSurface { return surface.playback }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            defer {
                playback?.stop(); MediaSession.shared.stop()
                window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            }
            for _ in 0..<120 {
                playback = window.rootViewController.flatMap { find($0.view) }
                if (playback?.player?.media?.statistics.displayedPictures ?? 0) > 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let decoder = try XCTUnwrap(playback, "Both file and download paths must mount Soulo by default")
            XCTAssertGreaterThan(decoder.player?.media?.statistics.displayedPictures ?? 0, 2)
            XCTAssertTrue(decoder.playing, "Switching before AVPlayer's first frame must preserve autoplay")
            XCTAssertNil(MediaSession.shared.player.currentItem)
            func findSlider(_ view: UIView) -> UISlider? {
                if let slider = view as? UISlider, slider.accessibilityIdentifier == "media.mkv.timeline" { return slider }
                return view.subviews.lazy.compactMap { findSlider($0) }.first
            }
            let slider = try XCTUnwrap(findSlider(try XCTUnwrap(window.rootViewController?.view)))
            var hit: UIView?
            for _ in 0..<30 {
                window.layoutIfNeeded()
                let point = slider.convert(CGPoint(x: slider.bounds.midX, y: slider.bounds.midY), to: window)
                hit = window.hitTest(point, with: nil)
                if hit === slider || hit?.isDescendant(of: slider) == true { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(hit === slider || hit?.isDescendant(of: slider) == true, "Timeline hit test: \(String(describing: hit))")
        }
    }

    @MainActor
    func testFileMusicKeepsPlayingAfterNavigationAndAutomaticallyAdvancesInBothModes() async throws {
        let defaults = UserDefaults.standard, modeKey = VideoPlaybackPreferences.defaultPlayerKey
        let mode = defaults.object(forKey: modeKey), oldRate = defaults.object(forKey: "media.rate")
        defaults.set(1.0, forKey: "media.rate")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MusicQueue-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { MediaSession.shared.stop(); defaults.set(mode, forKey: modeKey); defaults.set(oldRate, forKey: "media.rate"); try? FileManager.default.removeItem(at: root) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1))
        let urls = [root.appendingPathComponent("2.wav"), root.appendingPathComponent("10.wav")]
        for (index, file) in urls.enumerated() {
            let frames: AVAudioFrameCount = index == 0 ? 12000 : 64000
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)); buffer.frameLength = frames
            if let samples = buffer.floatChannelData?[0] { for i in 0..<Int(frames) { samples[i] = Float(sin(Double(i) * 0.1)) * 0.05 } }
            try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        }
        XCTAssertEqual(FileVideoEpisodes.localURLs(in: root, audio: true).map(\.lastPathComponent), ["2.wav", "10.wav"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for engine in ["soulo", "system"] {
            MediaSession.shared.stop(); defaults.set(engine, forKey: modeKey)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: AnyView(NavigationStack { LocalDocumentContent(url: urls[0]) }))
            window.rootViewController = host; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            for _ in 0..<80 {
                if MediaSession.shared.url?.lastPathComponent == "2.wav", MediaSession.shared.playing,
                   MediaSession.shared.elapsed > 0.1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(MediaSession.shared.url?.lastPathComponent, "2.wav", engine)
            XCTAssertEqual(MediaSession.shared.soulo != nil, engine == "soulo")
            host.rootView = AnyView(ZStack { Text("File list"); MediaMiniPlayer() })
            for _ in 0..<140 {
                if MediaSession.shared.url?.lastPathComponent == "10.wav", MediaSession.shared.elapsed > 0.1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(MediaSession.shared.url?.lastPathComponent, "10.wav", "The queue must survive its originating page: \(engine)")
            XCTAssertTrue(MediaSession.shared.playing, engine)
            XCTAssertGreaterThan(MediaSession.shared.elapsed, 0.1, engine)
            XCTAssertEqual(MediaSession.shared.soulo != nil, engine == "soulo")
            MediaSession.shared.stop()
        }
    }

    @MainActor
    func testAudioFileUsesSharedSouloModeAndAdvancingTimeline() async throws {
        let defaults = UserDefaults.standard, key = VideoPlaybackPreferences.defaultPlayerKey
        let saved = defaults.object(forKey: key)
        defaults.set("soulo", forKey: key)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = 80_000
        if let samples = buffer.floatChannelData?[0] { for index in 0..<80_000 { samples[index] = 0 } }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: NavigationStack { LocalDocumentContent(url: url) })
        window.rootViewController = host; window.makeKeyAndVisible()
        func find(_ view: UIView) -> MatroskaPlayback? {
            if let surface = view as? MatroskaVideoSurface { return surface.playback }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        var playback: MatroskaPlayback?
        defer {
            playback?.stop(); MediaSession.shared.stop()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            defaults.set(saved, forKey: key); try? FileManager.default.removeItem(at: url)
        }
        for _ in 0..<80 {
            playback = find(host.view)
            if (playback?.elapsed ?? 0) > 0.4 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let decoder = try XCTUnwrap(playback)
        XCTAssertFalse(decoder.hasVideo)
        XCTAssertGreaterThan(decoder.elapsed, 0.4)
        XCTAssertTrue(decoder.playing)
        XCTAssertNil(MediaSession.shared.player.currentItem)
    }

    @MainActor
    func testCompletedHEVCFilePreviewShowsVideoAndEntersFullscreen() async throws {
        let defaults = UserDefaults.standard, key = VideoPlaybackPreferences.defaultPlayerKey
        let savedPlayer = defaults.object(forKey: key)
        defaults.set("soulo", forKey: key)
        defer { defaults.set(savedPlayer, forKey: key) }

        let url: URL
        if let offline = ProcessInfo.processInfo.environment["SOULO_DEVICE_OFFLINE_DOWNLOAD_QA"] {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(offline)
        } else if let relative = ProcessInfo.processInfo.environment["SOULO_DEVICE_VIDEO_QA"] {
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(relative)
        } else {
            url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-hevc-hev1", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // Reproduce a handoff from the former audio-only native path as well
        // as opening the completed download through its actual file preview.
        MediaSession.shared.open(url: url, persistPosition: false)
        try await Task.sleep(for: .milliseconds(400))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let original = scene.interfaceOrientation
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { LocalDocumentContent(url: url) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        var playback: MatroskaPlayback?
        defer {
            playback?.stop()
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            VideoOrientation.request(VideoOrientation.mask(for: original), in: scene) { _ in }
        }
        func find<T: UIView>(_ root: UIView, _ type: T.Type) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews { if let match = find(child, type) { return match } }
            return nil
        }
        for _ in 0..<160 {
            playback = find(controller.view, MatroskaVideoSurface.self)?.playback
            if (playback?.player?.media?.statistics.displayedPictures ?? 0) > 3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let decoder = try XCTUnwrap(playback, "A completed HEVC file must use the extended decoder through the actual file preview")
        func capture(_ name: String) {
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
            let shot = XCTAttachment(image: image); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        capture("Connected phone original file preview")
        XCTAssertNil(decoder.error)
        XCTAssertFalse(decoder.buffering, "Visible playing video must not keep showing a loading indicator")
        XCTAssertGreaterThan(decoder.player?.media?.statistics.displayedPictures ?? 0, 3, "Audio progress alone does not prove that the file preview has video")
        XCTAssertGreaterThan(decoder.player?.videoSize.width ?? 0, 0)
        XCTAssertNil(MediaSession.shared.player.currentItem, "The incompatible MP4 must not be left playing only its audio through AVPlayer")
        func button(_ identifier: String, in root: UIView) -> UIButton? {
            if let match = root as? UIButton, match.accessibilityIdentifier == identifier { return match }
            for child in root.subviews { if let match = button(identifier, in: child) { return match } }
            return nil
        }
        let drawable = try XCTUnwrap(decoder.player?.drawable as? UIView)
        let previewFrames = decoder.player?.media?.statistics.displayedPictures ?? 0
        let expand = try XCTUnwrap(button("media.mkv.fullscreen", in: controller.view))
        expand.sendActions(for: .touchUpInside)
        for _ in 0..<100 {
            if controller.presentedViewController?.view.accessibilityIdentifier == "media.mkv.fullscreen.player" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let fullscreen = try XCTUnwrap(controller.presentedViewController)
        XCTAssertEqual(fullscreen.modalPresentationStyle, .overFullScreen)
        XCTAssertEqual(fullscreen.view.accessibilityIdentifier, "media.mkv.fullscreen.player")
        for _ in 0..<100 {
            if drawable.isDescendant(of: fullscreen.view),
               (decoder.player?.media?.statistics.displayedPictures ?? 0) > previewFrames { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(drawable.isDescendant(of: fullscreen.view), "Fullscreen must display the active video surface")
        for _ in 0..<60 {
            if scene.interfaceOrientation.isLandscape, fullscreen.view.bounds.width > fullscreen.view.bounds.height,
               fullscreen.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let videoFrame = drawable.convert(drawable.bounds, to: fullscreen.view)
        XCTAssertGreaterThan(fullscreen.view.bounds.width, fullscreen.view.bounds.height)
        let videoSize = try XCTUnwrap(decoder.player).videoSize
        XCTAssertEqual(videoFrame.width / videoFrame.height, videoSize.width / videoSize.height, accuracy: 0.01)
        XCTAssertEqual(videoFrame.midX, fullscreen.view.bounds.midX, accuracy: 2)
        XCTAssertEqual(videoFrame.midY, fullscreen.view.bounds.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(videoFrame.width, fullscreen.view.bounds.width + 2)
        XCTAssertLessThanOrEqual(videoFrame.height, fullscreen.view.bounds.height + 2)
        let fullscreenFrames = decoder.player?.media?.statistics.displayedPictures ?? 0
        XCTAssertGreaterThan(fullscreenFrames, previewFrames, "Video frames must continue in fullscreen")
        capture("Connected phone original video fullscreen")
        if ProcessInfo.processInfo.environment["SOULO_DEVICE_VISUAL_HOLD"] == "1" {
            decoder.seek(65)
            try await Task.sleep(for: .milliseconds(1500))
            if decoder.playing { decoder.togglePlayback() }
            try await Task.sleep(for: .milliseconds(500))
            print("PHONE_FULLSCREEN_READY|\(fullscreen.view.bounds)")
            try await Task.sleep(for: .seconds(8))
            if !decoder.playing { decoder.togglePlayback() }
        }
        XCTAssertTrue((decoder.player?.drawable as? UIView) === drawable, "Entering fullscreen must preserve the active video output")
        let close = try XCTUnwrap(button("media.mkv.fullscreen.close", in: fullscreen.view))
        close.sendActions(for: .touchUpInside)
        for _ in 0..<100 {
            if controller.presentedViewController == nil, drawable.isDescendant(of: controller.view),
               (decoder.player?.media?.statistics.displayedPictures ?? 0) > fullscreenFrames { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(controller.presentedViewController)
        XCTAssertTrue((decoder.player?.drawable as? UIView) === drawable)
        XCTAssertTrue(drawable.isDescendant(of: controller.view), "Closing fullscreen must restore the video surface")
        XCTAssertGreaterThan(decoder.player?.media?.statistics.displayedPictures ?? 0, fullscreenFrames, "Video must keep playing after fullscreen")
        capture("Connected phone after exiting fullscreen")
        print("FILE_HEVC_VIDEO_QA|size=\(decoder.player?.videoSize ?? .zero)|displayed=\(decoder.player?.media?.statistics.displayedPictures ?? 0)|fullscreen=entered-and-exited")
    }

    func testByteRangesSupportSeekingAndRejectMalformedRequests() throws {
        XCTAssertEqual(try TorrentHTTPRange.parse(nil, size: 100), 0..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=10-19", size: 100), 10..<20)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=90-", size: 100), 90..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=-20", size: 100), 80..<100)
        XCTAssertEqual(try TorrentHTTPRange.parse("bytes=90-9223372036854775807", size: 100), 90..<100)
        for range in ["bytes=100-", "bytes=20-10", "bytes=-0", "bytes=1-2,4-5", "bytes=a-b", "bytes=9223372036854775808-", "items=0-1"] {
            XCTAssertThrowsError(try TorrentHTTPRange.parse(range, size: 100), range)
        }
    }

    func testEpisodeListSortsNaturallyAndExcludesUnsafeOrUnselectedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["Episode 10.mp4", "Episode 2.mkv", "Episode 1.mp4", "Episode 3.soulohls", ".hidden.mp4", "audio.mp3", "busy.mp4"] {
            try Data().write(to: directory.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Episode 4.movpkg"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.mp4"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link.mp4"),
            withDestinationURL: directory.appendingPathComponent("Episode 1.mp4"))
        let busy = directory.appendingPathComponent("busy.mp4")
        XCTAssertEqual(FileVideoEpisodes.localURLs(in: directory, excluding: [busy]).map(\.lastPathComponent),
                       ["Episode 1.mp4", "Episode 2.mkv", "Episode 3.soulohls", "Episode 4.movpkg", "Episode 10.mp4"])
        let files = ["10.mp4", "2.mkv", "1.mp4", "audio.mp3", "pad.mp4", "empty.mp4"].enumerated().map {
            TorrentFileEntry(index: $0.offset, path: $0.element, size: $0.offset == 5 ? 0 : 100, pad: $0.offset == 4)
        }
        let job = TorrentDownloadJob(id: UUID(), hash: "qa", name: "Episodes", files: files,
            selected: [0, 1, 3, 4, 5], state: .downloading, directory: directory.path)
        XCTAssertEqual(FileVideoEpisodes.torrentFiles(job).map(\.path), ["2.mkv", "10.mp4"])
        XCTAssertTrue(FileVideoEpisodes.torrentFiles(job, directory: "other").isEmpty)
    }

    func testStreamWaitsForVerifiedBytesAndSupportsRangeAndHead() async throws {
        let fixture = ProgressiveTorrentBytes()
        let server = try await TorrentStreamServer.start(size: Int64(fixture.bytes.count), name: "movie.mkv") { offset, count in
            await fixture.read(offset: offset, count: count)
        }
        defer { server.stop() }
        XCTAssertEqual(server.url.host, "127.0.0.1")
        var request = URLRequest(url: server.url)
        request.setValue("bytes=4096-8191", forHTTPHeaderField: "Range")
        let download = Task {
            let result = try await URLSession.shared.data(for: request)
            await fixture.finish()
            return result
        }
        defer { download.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        let finishedEarly = await fixture.finished
        XCTAssertFalse(finishedEarly, "Missing pieces must buffer; preallocated zeroes are not playable data")
        await fixture.makeAvailable()
        let (data, response) = try await download.value
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 4096-8191/16384")
        XCTAssertEqual(data, fixture.bytes.subdata(in: 4096..<8192))
        var head = URLRequest(url: server.url); head.httpMethod = "HEAD"
        let (body, headResponse) = try await URLSession.shared.data(for: head)
        XCTAssertTrue(body.isEmpty)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length"), "16384")
        var invalid = URLRequest(url: server.url); invalid.setValue("bytes=16384-", forHTTPHeaderField: "Range")
        let (_, rejected) = try await URLSession.shared.data(for: invalid)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 416)
        let wrong = server.url.deletingLastPathComponent().appendingPathComponent("other.mkv")
        let (_, wrongResponse) = try await URLSession.shared.data(from: wrong)
        XCTAssertEqual((wrongResponse as? HTTPURLResponse)?.statusCode, 404)
    }

    func testFinishingATorrentPlaybackLeaseWaitsForCleanupAndRunsOnce() async throws {
        let worker = PlaybackCleanupEngine()
        let server = try await TorrentStreamServer.start(size: 16, name: "clip.mp4") { _, count in Data(repeating: 1, count: count) }
        var lease: TorrentPlaybackLease? = TorrentPlaybackLease(server: server, id: UUID(), worker: worker)
        await withTaskGroup(of: Void.self) { group in
            let active = lease!
            group.addTask { await active.finish() }
            group.addTask { await active.finish() }
            await group.waitForAll()
        }
        let count = await worker.cleanups
        XCTAssertEqual(count, 1, "All callers must await the same cleanup before opening another episode")
        lease = nil
        try await Task.sleep(for: .milliseconds(100))
        let finalCount = await worker.cleanups
        XCTAssertEqual(finalCount, 1, "Releasing a finished lease must not reset a newer stream")
    }

    @MainActor
    func testMKVDecodesAndAdvancesWithTheExtendedPlayer() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mkv", subdirectory: "ReadingFixtures"))
        XCTAssertEqual(FilePresentation.inspect(url).kind, .video)
        playback.open(url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5, "An MKV must actually decode and play, not merely open a preview")
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        XCTAssertGreaterThan(playback.duration, 0)
        XCTAssertFalse(playback.buffering, "A playing video must not leave its loading indicator on")
        let oldRate = UserDefaults.standard.object(forKey: "media.rate")
        let oldHoldSpeed = UserDefaults.standard.object(forKey: VideoPlaybackPreferences.holdSpeedKey)
        UserDefaults.standard.set(2, forKey: VideoPlaybackPreferences.holdSpeedKey)
        defer {
            if let oldRate { UserDefaults.standard.set(oldRate, forKey: "media.rate") }
            else { UserDefaults.standard.removeObject(forKey: "media.rate") }
            UserDefaults.standard.set(oldHoldSpeed, forKey: VideoPlaybackPreferences.holdSpeedKey)
        }
        playback.setRate(1.5)
        XCTAssertEqual(playback.rate, 1.5)
        let originalRate = try XCTUnwrap(playback.player).rate
        playback.beginTemporaryRate()
        XCTAssertEqual(playback.player?.rate, 2)
        XCTAssertEqual(playback.gestureFeedback?.kind, .rate)
        playback.endTemporaryRate()
        XCTAssertEqual(playback.player?.rate, originalRate)
        XCTAssertNil(playback.gestureFeedback)
        UserDefaults.standard.set(1.75, forKey: VideoPlaybackPreferences.holdSpeedKey)
        playback.beginTemporaryRate()
        XCTAssertEqual(playback.player?.rate, 1.75)
        playback.endTemporaryRate()
        XCTAssertEqual(playback.player?.rate, originalRate)
        UserDefaults.standard.set(2.5, forKey: VideoPlaybackPreferences.holdSpeedKey)
        playback.beginTemporaryRate()
        XCTAssertEqual(playback.player?.rate, 2.5)
        XCTAssertEqual(playback.gestureFeedback?.value, 2.5)
        playback.endTemporaryRate()
        XCTAssertEqual(playback.player?.rate, originalRate)
        playback.togglePlayback()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(playback.playing)
        playback.seek(1)
        playback.togglePlayback()
        playback.stop()
        playback.open(url, startAt: 1, autoplay: false)
        for _ in 0..<100 {
            if playback.elapsed >= 0.9, playback.duration > 0, !playback.playing,
               !playback.buffering, playback.player?.isPlaying == false { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThanOrEqual(playback.elapsed, 0.9, "A paused player handoff must restore its position")
        XCTAssertFalse(playback.playing)
        XCTAssertFalse(playback.buffering, "Paused VLC media can report .buffering even after its seek has finished")
        let rotatedSurface = UIView(frame: CGRect(x: 0, y: 0, width: 700, height: 350))
        controller.view.addSubview(rotatedSurface)
        playback.attach(rotatedSurface)
        let frame = try XCTUnwrap(playback.player?.drawable as? UIView).frame
        let size = try XCTUnwrap(playback.player).videoSize
        XCTAssertEqual(frame.width / frame.height, size.width / size.height, accuracy: 0.01,
                       "Rotating a paused video must preserve its display ratio without restarting playback")
    }

    @MainActor
    func testMKVPlaysAndSeeksFromTheTorrentHTTPStream() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mkv", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "clip.mkv") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5)
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        playback.seek(4)
        for _ in 0..<100 {
            if playback.elapsed > 4.2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(playback.elapsed, 4.2, "MKV seeking must work through the same HTTP ranges used for torrent playback")
    }

    @MainActor
    func testHEV1MP4UsesExtendedDecoderAndPlaysThroughTheTorrentStream() async throws {
        let fixture = "playback-hevc-hev1"
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "hev1.mp4") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let extended = try await TorrentFileDecoder.prefersExtended(AVURLAsset(url: server.url), path: "hev1.mp4")
        XCTAssertTrue(extended, "A .mp4 suffix must not force an incompatible HEVC sample through AVPlayer")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5, (playback.player?.media?.statistics.displayedPictures ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.elapsed, 0.5, "\(fixture): state=\(String(describing: playback.player?.state.rawValue)), duration=\(playback.duration), position=\(playback.player?.position ?? 0)")
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
        let stats = try XCTUnwrap(playback.player?.media?.statistics)
        XCTAssertGreaterThan(stats.decodedVideo, 0)
        XCTAssertGreaterThan(stats.displayedPictures, 0, "Audio progress alone does not prove HEVC video playback")
        print("HEVC_ACTUAL_FRAMES|decoded=\(stats.decodedVideo)|displayed=\(stats.displayedPictures)")
    }

    @MainActor
    func testSilentDecoderStopIsReportedInsteadOfLeavingABlackScreen() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-hevc-hev1-no-audio", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let server = try await TorrentStreamServer.start(size: Int64(bytes.count), name: "no-audio.mp4") { offset, count in
            bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        defer { server.stop() }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(server.url)
        for _ in 0..<100 {
            if playback.elapsed > 0.5 || playback.error != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        // Capabilities vary by decoder/device. Either actual playback progresses
        // or the UI must present its retry/error state; opening alone isn't success.
        XCTAssertTrue(playback.elapsed > 0.5 || playback.error != nil)
        if playback.error != nil {
            XCTAssertFalse(playback.buffering)
            print("HEVC_VIDEO_ONLY|decoder_stopped_early|explicit_error_presented")
        }
    }
}

private actor ProgressiveTorrentBytes {
    nonisolated let bytes = Data((0..<16384).map { UInt8($0 % 251) })
    private var available = false
    private(set) var finished = false
    func finish() { finished = true }
    func makeAvailable() { available = true }
    func read(offset: Int64, count: Int) -> Data? {
        guard available else { return nil }
        let first = Int(offset)
        return bytes.subdata(in: first..<min(bytes.count, first + count))
    }
}

private actor PlaybackCleanupEngine: TorrentEngine {
    private(set) var cleanups = 0
    func inspect(data: Data) async throws -> TorrentMetadata { throw TorrentTaskError.invalid }
    func inspect(magnet: String) async throws -> TorrentMetadata { throw TorrentTaskError.invalid }
    func add(id: UUID, data: Data?, magnet: String?, directory: URL, resume: Data?, priorities: [Bool], metadataOnly: Bool) async throws {}
    func snapshots() async -> [TorrentSnapshot] { [] }
    func save(id: UUID, pause: Bool) async throws -> Data? { nil }
    func resumeMetadata(id: UUID) async {}
    func resume(id: UUID, priorities: [Bool]) async {}
    func remove(id: UUID, deleteFiles: Bool) async -> Bool { true }
    func endStreaming(id: UUID) async {
        try? await Task.sleep(for: .milliseconds(100))
        cleanups += 1
    }
}
