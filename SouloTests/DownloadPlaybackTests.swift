import XCTest
import AVFoundation
import WebKit
import UIKit
import CryptoKit
import CommonCrypto
@testable import Soulo

@MainActor
final class DownloadPlaybackTests: XCTestCase {
    func testLiveMtyySampleDownloadsIntoPlayableMP4() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_MTY_QA"] == "1", "Opt-in user-reported live download")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 20
        let network = URLSession(configuration: configuration); defer { network.invalidateAndCancel() }
        func get(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue(AppConstants.mobileWebViewUserAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await network.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            return data
        }
        let page = URL(string: "https://www.mtyy5.com/vodplay/155698-4-1.html")!
        let html = String(decoding: try await get(page), as: UTF8.self)
        let start = try XCTUnwrap(html.range(of: "player_data="))
        let end = try XCTUnwrap(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        let raw = String(html[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let player = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let token = try XCTUnwrap(player["url"] as? String)
        let endpoint = URL(string: "https://www.mtyy5.com/static/player/art.php")!
        var signed = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        signed.queryItems = [.init(name: "get_signed_url", value: "1"), .init(name: "url", value: token)]
        let signedData = try await get(signed.url!)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: signedData) as? [String: Any])
        let signedURL = try XCTUnwrap(URL(string: try XCTUnwrap(first["signed_url"] as? String), relativeTo: endpoint)?.absoluteURL)
        let metadataData = try await get(signedURL)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        let stream = try XCTUnwrap(URL(string: try XCTUnwrap(metadata["jmurl"] as? String)))
        let text = String(decoding: try await get(stream), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("#EXTM3U"))
        // Fetch two real segments only; do not download the whole episode in QA.
        var sample = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:30", "#EXT-X-PLAYLIST-TYPE:VOD"]
        var duration = "", count = 0
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#EXTINF:") { duration = line }
            else if !line.isEmpty && !line.hasPrefix("#"), !duration.isEmpty {
                sample += [duration, try XCTUnwrap(URL(string: line, relativeTo: stream)?.absoluteURL.absoluteString)]
                count += 1; duration = ""
                if count == 2 { break }
            }
        }
        XCTAssertEqual(count, 2); sample.append("#EXT-X-ENDLIST")
        let web = WKWebView()
        WebMediaManifestCache.remember([stream.absoluteString: sample.joined(separator: "\n")], webView: web)
        WebMediaManifestCache.rememberPolicy("no-referrer", urls: [stream], webView: web)
        let resource = WebMediaResource(kind: .video, url: stream, title: "MTYY real sample", posterURL: nil, delivery: .hls, sourcePageURL: endpoint)
        let manager = DownloadManagerService.shared
        defer { if let item = manager.downloads.first(where: { $0.sourceURLString == stream.absoluteString }) { removeGeneratedDownload(item, manager: manager) } }
        let file = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "MTYY real sample.mp4", pageURL: endpoint, webView: web)
        let asset = AVURLAsset(url: file)
        let length = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(file.pathExtension, "mp4"); XCTAssertGreaterThan(length.seconds, 3); XCTAssertFalse(tracks.isEmpty)
        let attachment = XCTAttachment(string: "Downloaded two real remote segments into MP4: duration=\(length.seconds), bytes=\((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)")
        attachment.name = "mtyy-real-sample-download"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testDecoratedHLSSegmentsPlayAndDownloadAsRealVideo() async throws {
        let segment = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment0", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
        let bytes = try Data(contentsOf: segment)
        let prefix = Data([137,80,78,71,13,10,26,10]) + Data(repeating: 0, count: 61)
        let payload = prefix + bytes
        XCTAssertEqual(HLSTransportPrefix.offset(in: payload), prefix.count)
        XCTAssertNil(HLSTransportPrefix.offset(in: bytes))
        XCTAssertNil(HLSTransportPrefix.offset(in: Data("<html>failure</html>".utf8)))
        let playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.022,\nsegment.ts\n#EXT-X-ENDLIST\n"
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": Data(playlist.utf8), "/segment.ts": payload],
            responseHeaders: ["/segment.ts": ["Content-Type": "image/png"]])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Decorated TS", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: web)
        XCTAssertNotEqual(asset.url, resource.url, "Only verified decorated segments need a playback bridge")
        let item = AVPlayerItem(asset: asset), output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item); player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitFor("Decorated HLS must decode a real frame through the scoped bridge") {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            return player.currentTime().seconds > 0.2 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
        }
        XCTAssertNil(item.error)
        let manager = DownloadManagerService.shared
        defer { if let saved = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) { removeGeneratedDownload(saved, manager: manager) } }
        let file = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource,
            preferredFilename: "Decorated TS QA.mp4", pageURL: nil, webView: web)
        XCTAssertEqual(file.pathExtension, "mp4")
        let downloaded = AVURLAsset(url: file)
        let duration = try await downloaded.load(.duration)
        let tracks = try await downloaded.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(duration.seconds, 1)
        XCTAssertFalse(tracks.isEmpty)
    }

    func testScopedHLSDownloadSessionPreservesConfiguredRequestContext() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_HLS_SYSTEM_CONTEXT_PROOF"] != "1",
                      "Opt-in reproduction of the OS AVAssetDownload cookie/UA issue; production scoped fallback is covered separately")
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: file)
            playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files, requiredCookie: "scopedHLS=allowed")
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "scopedHLS", .value: "allowed"]))
        let jar = try XCTUnwrap(URLSessionConfiguration.ephemeral.httpCookieStorage)
        jar.setCookies([cookie], for: root, mainDocumentURL: root)
        let config = URLSessionConfiguration.background(withIdentifier: "Soulo.HLS.ContextProof." + UUID().uuidString)
        config.httpCookieStorage = jar; config.httpShouldSetCookies = true
        config.httpAdditionalHeaders = ["User-Agent": "Soulo-ScopedHLS-Proof"]
        config.isDiscretionary = false
        let delegate = HLSScopedContextProof()
        let session = AVAssetDownloadURLSession(configuration: config, assetDownloadDelegate: delegate, delegateQueue: .main)
        defer { session.invalidateAndCancel(); if let url = delegate.location { try? FileManager.default.removeItem(at: url) } }
        let asset = AVURLAsset(url: root.appendingPathComponent("video.m3u8"), options: [AVURLAssetHTTPCookiesKey: [cookie], AVURLAssetHTTPUserAgentKey: "Soulo-ScopedHLS-Proof"])
        let task = try XCTUnwrap(session.makeAssetDownloadTask(asset: asset, assetTitle: "Scoped HLS", assetArtworkData: nil, options: nil))
        task.resume()
        try await waitFor("Scoped HLS did not finish") { delegate.finished }
        let requests = server.receivedRequests
        XCTAssertNil(delegate.error, String(describing: requests))
        XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"]?.contains("scopedHLS=allowed") == true }, String(describing: requests))
        XCTAssertTrue(requests.allSatisfy { $0.headers["user-agent"] == "Soulo-ScopedHLS-Proof" }, String(describing: requests))
    }
    func testPrepareCompletedHLSForExportUI() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_MP4_UI_FIXTURE"] != "1", "Prepare a completed download for the separate UI runner")
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files)
        let root = try await server.start(); defer { server.stop() }
        let manager = DownloadManagerService.shared
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("master.m3u8"), title: "Export UI fixture", posterURL: nil, delivery: .hls)
        let reference = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource,
            preferredFilename: "MP4ExportUIQA-\(UUID().uuidString.prefix(6)).mp4", pageURL: nil, webView: WKWebView())
        XCTAssertEqual(reference.pathExtension, OfflineHLSReference.fileExtension)
        XCTAssertEqual(manager.downloads.first { $0.localURL == reference }?.status, .finished)
    }
    func testEncryptedHLSExportsOfflineMP4WithEveryVideoFrameAndOriginalPreserved() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reference = try writeConversionReference(fixture, at: fixture.root.appendingPathComponent("电影.soulohls"))
        let referenceBytes = try Data(contentsOf: reference)
        let snapshot = try packageSnapshot(fixture.package)
        let progress = FileOperationProgress()
        let output = try await OfflineVideoConversionService.exportMP4(from: reference, into: fixture.root, operation: progress)
        XCTAssertEqual(output.lastPathComponent, "电影.mp4")
        XCTAssertEqual(try Data(contentsOf: reference), referenceBytes)
        XCTAssertEqual(try packageSnapshot(fixture.package), snapshot)
        XCTAssertEqual(progress.progress.fractionCompleted, 1, accuracy: 0.001)
        let asset = AVURLAsset(url: output)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(audios.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 7.5)
        XCTAssertLessThan(duration, 9)
        let video = try XCTUnwrap(videos.first)
        let formats = try await video.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first)), kCMVideoCodecType_H264)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
        reader.add(samples); XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = samples.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(frames, 120, "All 8 seconds at 15 fps must survive without re-encoding or dropped frames")
        let outputBytes = try Data(contentsOf: output)
        var counts: [Int] = [], cursor = outputBytes.startIndex
        while let range = outputBytes.range(of: Data("stsz".utf8), in: cursor..<outputBytes.endIndex) {
            counts.append(outputBytes[(range.lowerBound + 12)..<(range.lowerBound + 16)].reduce(0) { $0 << 8 | Int($1) })
            cursor = range.upperBound
        }
        XCTAssertEqual(counts.sorted(), [120, 376], "The MP4 must retain every compressed video and audio sample, including AAC priming samples")
        let generator = AVAssetImageGenerator(asset: asset)
        let first = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600))
        let last = try await generator.image(at: CMTime(seconds: 7.4, preferredTimescale: 600))
        XCTAssertGreaterThan(first.image.width, 0); XCTAssertGreaterThan(last.image.width, 0)
        let attachment = XCTAttachment(contentsOfFile: output)
        attachment.name = "Generated encrypted HLS converted to MP4"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testImplicitAESIVAndHLSDiscontinuityExportWithoutLosingFrames() async throws {
        let fixture = try encryptedPackage(implicitSequence: 42)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let playlist = fixture.package.appendingPathComponent("private/0-128000-sample/media.m3u8")
        let original = try String(contentsOf: playlist, encoding: .utf8)
        try original.replacingOccurrences(of: "#EXTINF:2.000000,\nsegment2.ts", with: "#EXT-X-DISCONTINUITY\n#EXTINF:2.000000,\nsegment2.ts")
            .write(to: playlist, atomically: true, encoding: .utf8)
        let reference = try writeConversionReference(fixture, at: fixture.root.appendingPathComponent("sequence.soulohls"))
        let output = try await OfflineVideoConversionService.exportMP4(from: reference, into: fixture.root)
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(samples); XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = samples.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(sample) }
        XCTAssertEqual(frames, 120)
    }

    func testExistingDeviceHLSExportsMP4AndKeepsOriginalDownload() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SOULO_DEVICE_MP4_QA"] != "1", "Opt-in conversion of an existing device HLS download")
        let item = try XCTUnwrap(DownloadManagerService.shared.downloads.first { $0.status == .finished && $0.localURL.pathExtension == OfflineHLSReference.fileExtension })
        let package = try OfflineHLSReference.packageURL(for: item.localURL)
        let snapshot = try packageSnapshot(package), referenceBytes = try Data(contentsOf: item.localURL)
        let position = UserDefaults.standard.double(forKey: MediaSession.positionKey(item.localURL))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceMP4QA-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await OfflineVideoConversionService.exportMP4(from: item.localURL, into: directory)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 60)
        let image = try await AVAssetImageGenerator(asset: asset).image(at: CMTime(seconds: duration * 0.9, preferredTimescale: 600))
        XCTAssertGreaterThan(image.image.width, 0)
        XCTAssertEqual(try packageSnapshot(package), snapshot)
        XCTAssertEqual(try Data(contentsOf: item.localURL), referenceBytes)
        XCTAssertEqual(UserDefaults.standard.double(forKey: MediaSession.positionKey(item.localURL)), position)
        XCTAssertEqual(DownloadManagerService.shared.downloads.first { $0.id == item.id }, item)
        let summary = XCTAttachment(string: "MP4 duration: \(duration) seconds; bytes: \(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0); original files verified: \(snapshot.count)")
        summary.name = "Existing device HLS conversion"; summary.lifetime = .keepAlways; add(summary)
    }

    func testUnencryptedHLSPackageExportsMP4AndAvoidsExistingFilename() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rendition = fixture.package.appendingPathComponent("private/0-128000-sample")
        let playlist = rendition.appendingPathComponent("media.m3u8")
        let lines = try String(contentsOf: playlist, encoding: .utf8).components(separatedBy: .newlines)
        try lines.filter { !$0.hasPrefix("#EXT-X-KEY:") }.joined(separator: "\n").write(to: playlist, atomically: true, encoding: .utf8)
        for index in 0..<4 {
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            try Data(contentsOf: source).write(to: rendition.appendingPathComponent("(\(index * 2))_(0)_(2.00001).frag"))
        }
        let existing = fixture.root.appendingPathComponent("encrypted.mp4")
        let sentinel = Data("Keep this existing export".utf8); try sentinel.write(to: existing)
        let output = try await OfflineVideoConversionService.exportMP4(from: fixture.package, into: fixture.root)
        XCTAssertEqual(output.lastPathComponent, "encrypted (2).mp4")
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        let video = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(video.count, 1)
    }

    func testCancelingHLSConversionRemovesStagingAndKeepsOriginal() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reference = try writeConversionReference(fixture, at: fixture.root.appendingPathComponent("cancel.soulohls"))
        let snapshot = try packageSnapshot(fixture.package)
        let progress = FileOperationProgress()
        let task = Task { try await OfflineVideoConversionService.exportMP4(from: reference, into: fixture.root, operation: progress) }
        await Task.yield()
        progress.progress.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must not publish an MP4") }
        catch is CancellationError { }
        catch ReadingToolError.canceled { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancel.mp4").path))
        XCTAssertEqual(try packageSnapshot(fixture.package), snapshot)
    }

    func testIncompleteConversionIsNotPublishedAsACompleteMP4() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let rendition = fixture.package.appendingPathComponent("private/0-128000-sample")
        try FileManager.default.moveItem(at: rendition.appendingPathComponent("(6)_(0)_(2.00001).frag"),
            to: rendition.appendingPathComponent("(6)_(0)_(4.00001).frag"))
        let reference = try writeConversionReference(fixture, at: fixture.root.appendingPathComponent("incomplete.soulohls"))
        do {
            _ = try await OfflineVideoConversionService.exportMP4(from: reference, into: fixture.root)
            XCTFail("An export shorter than the downloaded timeline must not be published")
        } catch OfflineVideoConversionError.failed { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("incomplete.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reference.path))
    }

    func testConvertedDownloadIsSeparateAndDoesNotCollideWithAnActiveDownload() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let suite = "ConversionQA-\(UUID())", storage = fixture.root.appendingPathComponent("Downloads")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: storage)
        let (pending, reference) = manager.beginDownload(suggestedFilename: "Movie.soulohls", sourceURL: URL(string: "http://127.0.0.1:1/expired.m3u8"), transport: .hls)
        _ = try writeConversionReference(fixture, at: reference)
        manager.markFinished(id: pending.id)
        let original = try XCTUnwrap(manager.downloads.first)
        let bytes = try Data(contentsOf: reference)
        _ = manager.beginDownload(suggestedFilename: "Movie.mp4", sourceURL: nil)
        let output = try await OfflineVideoConversionService.exportMP4(from: reference, into: fixture.root)
        let converted = try manager.addConvertedVideo(from: output, original: original)
        XCTAssertNotEqual(converted.id, original.id)
        XCTAssertEqual(converted.status, .finished)
        XCTAssertEqual(converted.localURL.pathExtension, "mp4")
        XCTAssertNotEqual(converted.fileName, "Movie.mp4", "An active download has reserved this filename")
        XCTAssertEqual(converted.sourceURLString, original.sourceURLString)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == original.id }), original)
        XCTAssertEqual(try Data(contentsOf: reference), bytes)
        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: storage)
        XCTAssertEqual(restored.downloads.first(where: { $0.id == converted.id }), converted)
    }

    private func writeConversionReference(_ fixture: (root: URL, package: URL, files: [String: Data]), at url: URL) throws -> URL {
        let playlist = try String(contentsOf: fixture.package.appendingPathComponent("private/0-128000-sample/media.m3u8"), encoding: .utf8)
        let material = PortableHLSBundle.EncryptionMaterial(playlistDigest: Data(SHA256.hash(data: Data(playlist.utf8))),
            key: try XCTUnwrap(fixture.files["/enc.key"]), iv: playlist.contains("IV=") ? "0x00000000000000000000000000000000" : nil)
        try OfflineHLSReference.write(packageURL: fixture.package, sourceURL: URL(string: "http://127.0.0.1:1/expired.m3u8"), encryption: material, to: url)
        return url
    }

    private func packageSnapshot(_ package: URL) throws -> [String: Data] {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        var result: [String: Data] = [:]
        for case let url as URL in files where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[url.path] = Data(SHA256.hash(data: try Data(contentsOf: url)))
        }
        return result
    }
    func testSouloPlayerRetainsWebCookiesWhenSwitchingFromTheSystemPlayer() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let server = try DownloadPlaybackHTTPFixture(files: ["/clip.mp4": try Data(contentsOf: fixture)], requiredCookie: "soulo_transfer=allowed")
        let base = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }
        let url = base.appendingPathComponent("clip.mp4")
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "soulo_transfer", .value: "allowed"]))
        let context = VideoPlaybackRequestContext(url: url, referrer: base.appendingPathComponent("page.html"), userAgent: "SouloTransferQA", cookies: [cookie])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(url, requestContext: context)
        try await waitFor("Authenticated video must decode through the Soulo player") {
            playback.elapsed > 0.3 && (playback.player?.media?.statistics.displayedPictures ?? 0) > 0
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
    }
    private func waitFor(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail(message)
        throw URLError(.timedOut)
    }

    private func videoFixture() throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures")))
    }

    private func encryptedPackage(mirroredMaster: Bool = false, implicitSequence: UInt64? = nil) throws -> (root: URL, package: URL, files: [String: Data]) {
        let manager = FileManager.default
        let root = try XCTUnwrap(manager.urls(for: .libraryDirectory, in: .userDomainMask).first)
            .appendingPathComponent("OfflineHLSQA-\(UUID())")
        let package = root.appendingPathComponent("encrypted.movpkg")
        let rendition = package.appendingPathComponent("private/0-128000-sample")
        try manager.createDirectory(at: rendition, withIntermediateDirectories: true)
        var files: [String: Data] = [:]
        let key = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "key", withExtension: "bin", subdirectory: "ReadingFixtures/HLSEncryptedFragments")))
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:\(implicitSequence ?? 0)\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            + "#EXT-X-KEY:METHOD=AES-128,URI=\"enc.key\"" + (implicitSequence == nil ? ",IV=0x00000000000000000000000000000000\n" : "\n")
        for index in 0..<4 {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "frag",
                subdirectory: "ReadingFixtures/HLSEncryptedFragments"))
            var bytes = try Data(contentsOf: fixture)
            if let implicitSequence {
                let source = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments")))
                let iv = Data(repeating: 0, count: 8) + withUnsafeBytes(of: (implicitSequence + UInt64(index)).bigEndian) { Data($0) }
                let capacity = source.count + 16
                var buffer = [UInt8](repeating: 0, count: capacity), count = 0
                let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in source.withUnsafeBytes { s in buffer.withUnsafeMutableBytes { b in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, key.count,
                        v.baseAddress, s.baseAddress, source.count, b.baseAddress, capacity, &count)
                } } } }
                XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
                bytes = Data(buffer.prefix(count))
            }
            try bytes.write(to: rendition.appendingPathComponent("(\(index * 2))_(0)_(2.00001).frag"))
            files["/segment\(index).ts"] = bytes
            playlist += "#EXTINF:2.000000,\nsegment\(index).ts\n"
        }
        playlist += "#EXT-X-ENDLIST\n"
        try playlist.write(to: rendition.appendingPathComponent("media.m3u8"), atomically: true, encoding: .utf8)
        if mirroredMaster {
            let dataDirectory = package.appendingPathComponent("Data")
            try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try playlist.write(to: dataDirectory.appendingPathComponent("Playlist-original-master.m3u8"), atomically: true, encoding: .utf8)
        }
        files["/media.m3u8"] = Data(playlist.utf8)
        files["/master.m3u8"] = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS=\"avc1.42E01E,mp4a.40.2\",RESOLUTION=320x180\nmedia.m3u8\n".utf8)
        files["/enc.key"] = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "key", withExtension: "bin",
            subdirectory: "ReadingFixtures/HLSEncryptedFragments")))
        return (root, package, files)
    }

    func testEncryptedHLSFirstOpenReopenAndSeekWorkAfterOriginStops() async throws {
        let defaults = UserDefaults.standard, savedRate = defaults.object(forKey: "media.rate")
        defaults.set(1, forKey: "media.rate")
        defer { defaults.set(savedRate, forKey: "media.rate") }
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files)
        let origin = try await server.start()
        defer { server.stop() }
        let sourceURL = origin.appendingPathComponent("master.m3u8")
        let fetched = try await PortableHLSBundle.encryptionMaterial(packageURL: fixture.package, sourceURL: sourceURL)
        let material = try XCTUnwrap(fetched)
        let reference = fixture.root.appendingPathComponent("movie.soulohls")
        try OfflineHLSReference.write(packageURL: fixture.package, sourceURL: sourceURL, encryption: material, to: reference)
        XCTAssertEqual(try OfflineHLSReference.encryptionMaterial(for: reference)?.key, fixture.files["/enc.key"])
        server.stop() // No Soulo player has ever opened this download while online.

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for attempt in 0..<2 {
            let source = DownloadPlaybackSource(asset: AVURLAsset(url: fixture.package), pageURL: nil, webView: nil)
            let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
            let playlist = try String(contentsOf: prepared.url, encoding: .utf8)
            XCTAssertTrue(playlist.contains("URI=\"key.bin\""))
            XCTAssertFalse(playlist.contains("http:"))
            XCTAssertEqual(try Data(contentsOf: prepared.url.deletingLastPathComponent().appendingPathComponent("key.bin")), material.key)
            let playback = MatroskaPlayback(); playback.attach(controller.view)
            defer { playback.stop() }
            playback.open(prepared.url, resourceLease: prepared)
            print("OFFLINE_HLS_DIAGNOSTIC attempt=\(attempt) rate=\(playback.rate)")
            try await waitFor("Offline encrypted playback did not produce frames (open \(attempt))") {
                playback.elapsed > 0.5 && (playback.player?.media?.statistics.displayedPictures ?? 0) > 2
            }
            let frames = playback.player?.media?.statistics.displayedPictures ?? 0
            playback.seek(4.5)
            try await waitFor("Seeking offline encrypted media did not decode new frames") {
                playback.elapsed > 4.8 && (playback.player?.media?.statistics.displayedPictures ?? 0) > frames
            }
            XCTAssertNil(playback.error)
            playback.stop()
        }
    }

    func testStoredHLSKeyCannotBeUsedForAChangedPlaylist() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = PortableHLSBundle.EncryptionMaterial(playlistDigest: Data(repeating: 0, count: 32),
            key: try XCTUnwrap(fixture.files["/enc.key"]), iv: "0x00000000000000000000000000000000")
        do {
            _ = try await PortableHLSBundle.export(packageURL: fixture.package, name: "Wrong key", into: fixture.root,
                encryption: invalid)
            XCTFail("Stored material must match this exact local media playlist")
        } catch StreamingMediaDownloadError.unsupportedManifest { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Wrong key.hls").path))
    }

    func testOfflineHLSServerServesOnlyItsBundleAndSupportsByteRanges() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("OfflineServerQA-\(UUID())")
        let bundle = root.appendingPathComponent("video.hls")
        try manager.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let playlist = Data("#EXTM3U\n#EXTINF:2,\n000000.ts\n#EXT-X-ENDLIST\n".utf8)
        let bytes = Data(0..<16)
        try playlist.write(to: bundle.appendingPathComponent("index.m3u8"))
        try bytes.write(to: bundle.appendingPathComponent("000000.ts"))
        try bytes.write(to: bundle.appendingPathComponent("key.bin"))
        try bytes.write(to: bundle.appendingPathComponent("private.txt"))
        let outside = root.appendingPathComponent("outside.ts"); try bytes.write(to: outside)
        try manager.createSymbolicLink(at: bundle.appendingPathComponent("linked.ts"), withDestinationURL: outside)
        let server = try await TorrentStreamServer.startHLS(directory: bundle, playlist: "index.m3u8")
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        let (body, response) = try await session.data(from: server.url)
        XCTAssertEqual(body, playlist)
        XCTAssertEqual(response.mimeType, "application/vnd.apple.mpegurl")
        let base = try XCTUnwrap(server.url).deletingLastPathComponent()
        let (key, _) = try await session.data(from: base.appendingPathComponent("key.bin"))
        XCTAssertEqual(key, bytes)
        var range = URLRequest(url: base.appendingPathComponent("000000.ts"))
        range.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (part, ranged) = try await session.data(for: range)
        XCTAssertEqual((ranged as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(part, bytes.subdata(in: 2..<6))
        range.httpMethod = "HEAD"
        let (empty, head) = try await session.data(for: range)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(head.expectedContentLength, 4)
        for path in ["private.txt", "linked.ts", "../outside.ts"] {
            let url = try XCTUnwrap(URL(string: path, relativeTo: base.appendingPathComponent("", isDirectory: true)))
            let (_, rejected) = try await session.data(from: url)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 404, path)
        }
    }

    func testLegacyEncryptedHLSReferenceRetainsMaterialAfterOneOnlineOpen() async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files)
        let origin = try await server.start(); defer { server.stop() }
        let reference = fixture.root.appendingPathComponent("old.soulohls")
        try OfflineHLSReference.write(packageURL: fixture.package, sourceURL: origin.appendingPathComponent("master.m3u8"), to: reference)
        XCTAssertNil(try OfflineHLSReference.encryptionMaterial(for: reference))
        let source = DownloadPlaybackSource(asset: AVURLAsset(url: fixture.package), pageURL: nil, webView: nil)
        let first = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertEqual(try OfflineHLSReference.encryptionMaterial(for: reference)?.key, fixture.files["/enc.key"])
        server.stop()
        let reopened = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.url.path))
    }

    func testLegacyDirectHLSWithMirroredMasterCanMigrateAndReopenOffline() async throws {
        let fixture = try encryptedPackage(mirroredMaster: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files)
        let origin = try await server.start(); defer { server.stop() }
        let reference = fixture.root.appendingPathComponent("legacy-mirrored.soulohls")
        try OfflineHLSReference.write(packageURL: fixture.package, sourceURL: origin.appendingPathComponent("media.m3u8"), to: reference)
        let original = try Data(contentsOf: fixture.package.appendingPathComponent("Data/Playlist-original-master.m3u8"))
        let source = DownloadPlaybackSource(asset: AVURLAsset(url: fixture.package), pageURL: nil, webView: nil)
        _ = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
        XCTAssertEqual(try OfflineHLSReference.encryptionMaterial(for: reference)?.key, fixture.files["/enc.key"])
        server.stop()
        let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.package.appendingPathComponent("Data/Playlist-original-master.m3u8")), original,
            "Migration must not rewrite the system's existing package")
    }

    func testExistingDeviceLegacyHLSCanPlayInBothPlayers() async throws {
        guard let filename = ProcessInfo.processInfo.environment["SOULO_DEVICE_LEGACY_HLS_QA"] else {
            throw XCTSkip("Opt-in verification of a device's existing HLS download")
        }
        let manager = FileManager.default
        let reference = DownloadManagerService.downloadsDirectory.appendingPathComponent(filename)
        let package = try OfflineHLSReference.packageURL(for: reference)
        let asset = try OfflineHLSReference.playableAsset(for: reference)
        let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: false)
        _ = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
        XCTAssertNotNil(try OfflineHLSReference.encryptionMaterial(for: reference))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: reference)) as? [String: Any])
        record["sourceURLString"] = "http://127.0.0.1:9/unreachable.m3u8"
        let copy = manager.temporaryDirectory.appendingPathComponent("LegacyHLSQA-\(UUID()).soulohls")
        try JSONSerialization.data(withJSONObject: record).write(to: copy)
        defer { try? manager.removeItem(at: copy) }
        let coldSource = DownloadPlaybackSource(asset: AVURLAsset(url: package), pageURL: nil, webView: nil, persistPosition: false)
        let prepared = try await SouloMediaPlaybackSource.prepare(native: coldSource, originalURL: copy)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback(); playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(prepared.url, resourceLease: prepared, persistPosition: false)
        try await waitFor("The existing device download must decode video in Soulo") {
            playback.elapsed > 0.5 && (playback.player?.media?.statistics.displayedPictures ?? 0) > 2
        }
        XCTAssertNil(playback.error)
        let shot = XCTAttachment(image: UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        })
        shot.name = "Existing download restored in Soulo"; shot.lifetime = .keepAlways; add(shot)
        playback.stop()
        let systemAsset = try await prepared.systemAsset()
        let item = AVPlayerItem(asset: systemAsset), output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item); player.play(); defer { player.pause() }
        try await waitFor("The existing device download must decode in the system player using only local resources") {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            return player.currentTime().seconds > 0.5 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
        }
        XCTAssertNil(item.error)
        withExtendedLifetime(prepared) { player.pause() }
    }

    func testEncryptedHLSDownloadStoresOfflineMaterialBeforeReportingFinished() async throws {
        try await checkEncryptedHLSDownload(authenticated: false)
    }

    func testPrivateAuthenticatedEncryptedHLSDownloadFinishesAndPlaysOffline() async throws {
        try await checkEncryptedHLSDownload(authenticated: true)
    }

    func testAuthenticatedFMP4ByteRangesAndSeparateAudioPlayOffline() async throws {
        func media(_ name: String) throws -> Data {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "m4s", subdirectory: "ReadingFixtures/ExtensionMedia/DASH"))
            return try Data(contentsOf: url)
        }
        let videoInit = try media("init-stream0"), video = try media("chunk-stream0-00001")
        let audioInit = try media("init-stream1")
        let audio = try (1...4).map { try media(String(format: "chunk-stream1-%05d", $0)) }
        let header = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:8\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        let videoList = header + "#EXT-X-MAP:URI=\"video.mp4\",BYTERANGE=\"\(videoInit.count)@0\"\n#EXTINF:8.0,\n#EXT-X-BYTERANGE:\(video.count)@\(videoInit.count)\nvideo.mp4\n#EXT-X-ENDLIST\n"
        var audioList = header + "#EXT-X-MAP:URI=\"audio.m4a\",BYTERANGE=\"\(audioInit.count)@0\"\n"
        for index in audio.indices {
            audioList += "#EXTINF:\(index == 0 ? "1.984" : "2.005333"),\n#EXT-X-BYTERANGE:\(audio[index].count)\(index == 0 ? "@\(audioInit.count)" : "")\naudio.m4a\n"
        }
        audioList += "#EXT-X-ENDLIST\n"
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"Original\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=100000,CODECS=\"avc1.64000a,mp4a.40.2\",AUDIO=\"sound\"\nvideo.m3u8\n"
        let files = ["/master.m3u8": Data(master.utf8), "/video.m3u8": Data(videoList.utf8),
                     "/audio.m3u8": Data(audioList.utf8), "/video.mp4": videoInit + video,
                     "/audio.m4a": audio.reduce(audioInit, +)]
        let server = try DownloadPlaybackHTTPFixture(files: files, requiredCookie: "fmp4Download=allowed",
            responseHeaders: ["/audio.m4a": ["Content-Type": "audio/mp4"]])
        let origin = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config); web.customUserAgent = "Soulo-FMP4-Download/1.0"
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "fmp4Download", .value: "allowed"]))
        await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("master.m3u8"), title: "Private fMP4", posterURL: nil, delivery: .hls)
        let manager = DownloadManagerService.shared
        defer { if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) { removeGeneratedDownload(item, manager: manager) } }
        let file = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "Private fMP4.mp4", pageURL: nil, webView: web)
        XCTAssertEqual(file.pathExtension, "hls")
        let saved = try XCTUnwrap(manager.finishedDownload(for: resource.url))
        XCTAssertEqual(saved.localURL.standardizedFileURL.path, file.standardizedFileURL.path)
        let requests = server.receivedRequests
        XCTAssertEqual(requests.filter { $0.headers["range"] != nil }.count, 7)
        XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"]?.contains("fmp4Download=allowed") == true && $0.headers["user-agent"] == web.customUserAgent })
        server.stop()
        let localSource = DownloadPlaybackSource(asset: AVURLAsset(url: try LocalHLSMedia.playlistURL(for: file)), pageURL: nil, webView: nil)
        let prepared = try await SouloMediaPlaybackSource.prepare(native: localSource, originalURL: file)
        let asset = try await prepared.systemAsset()
        let item = AVPlayerItem(asset: asset), output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(output)
        let player = AVPlayer(playerItem: item); player.play()
        defer { withExtendedLifetime(prepared) { player.pause(); player.replaceCurrentItem(with: nil) } }
        try await waitFor("Saved fMP4 ranges and alternate audio must decode after the authenticated origin stops") {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            return player.currentTime().seconds > 0.5 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
        }
        XCTAssertNil(item.error)
        XCTAssertEqual(item.tracks.filter { $0.assetTrack?.mediaType == .audio }.count, 1, "Alternate audio must be retained in the saved master")
        let duration = try await asset.load(.duration)
        XCTAssertGreaterThan(duration.seconds, 7.9)
    }

    func testAuthenticatedHLSCancelRemovesPartialFilesAndRejectsErrorPages() async throws {
        let segmentURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment0", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
        let bytes = try Data(contentsOf: segmentURL)
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXTINF:2.022,\nfirst.ts\n#EXTINF:2.022,\nlast.ts\n#EXT-X-ENDLIST\n"
        let manager = DownloadManagerService.shared
        for failing in [false, true] {
            let server = try DownloadPlaybackHTTPFixture(files: ["/index.m3u8": Data(playlist.utf8), "/first.ts": bytes,
                "/last.ts": failing ? Data("<html>Denied</html>".utf8) : bytes], heldPaths: failing ? [] : ["/last.ts"],
                requiredCookie: "cancelHLS=allowed", responseHeaders: failing ? ["/last.ts": ["Content-Type": "text/html"]] : [:])
            let origin = try await server.start(); defer { server.stop() }
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: .zero, configuration: config); web.customUserAgent = "Soulo-HLS-Cancel/1.0"
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "cancelHLS", .value: "allowed"]))
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
            let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("index.m3u8"), title: "HLS cancellation", posterURL: nil, delivery: .hls)
            let task = Task { try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "Canceled HLS.mp4", pageURL: nil, webView: web) }
            try await waitFor("The first HLS fragment must publish actual received bytes") { (manager.activeDownload(for: resource.url)?.receivedBytes ?? 0) >= Int64(bytes.count) }
            let id = try XCTUnwrap(manager.activeDownload(for: resource.url)?.id)
            defer { if let item = manager.downloads.first(where: { $0.id == id }) { removeGeneratedDownload(item, manager: manager) } }
            if !failing { StreamingMediaDownloadService.shared.cancel(itemID: id) }
            do { _ = try await task.value; XCTFail("A canceled or HTML fragment download cannot finish") } catch { }
            XCTAssertEqual(manager.downloads.first(where: { $0.id == id })?.status, failing ? .failed : .canceled)
            XCTAssertFalse(AuthenticatedHLSDownloadService.shared.owns(id))
            XCTAssertNil(manager.playbackSource(for: id))
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("SouloAuthenticatedHLS/\(id).hls")
            try await waitFor("Failed HLS staging must be removed") { !FileManager.default.fileExists(atPath: staging.path) }
            if failing { XCTAssertEqual(server.receivedRequests.filter { $0.path == "/last.ts" }.count, 3, "Error pages must be retried within the fixed bound") }
            server.stop()
        }
    }

    private func checkEncryptedHLSDownload(authenticated: Bool) async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files, requiredCookie: authenticated ? "encryptedDownload=allowed" : nil)
        let origin = try await server.start(); defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("media.m3u8"),
            title: "Encrypted offline download", posterURL: nil, delivery: .hls)
        let manager = DownloadManagerService.shared
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Soulo-Encrypted-Download/1.0"
        if authenticated {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                                                             .name: "encryptedDownload", .value: "allowed"]))
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let download = Task { try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource,
            preferredFilename: "Encrypted offline download.mp4", pageURL: nil, webView: web) }
        defer {
            download.cancel()
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
        }
        let file = try await download.value
        XCTAssertEqual(manager.downloads.first(where: { $0.localURL == file })?.status, .finished)
        if file.pathExtension == OfflineHLSReference.fileExtension {
            XCTAssertNotNil(try OfflineHLSReference.encryptionMaterial(for: file), "Finished AES downloads need local playback material")
            let legacy = fixture.root.appendingPathComponent("legacy.soulohls")
            try OfflineHLSReference.write(packageURL: OfflineHLSReference.packageURL(for: file),
                sourceURL: resource.url, to: legacy)
            let asset = try OfflineHLSReference.playableAsset(for: file)
            let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil)
            // Older downloads acquire and persist missing material on their
            // first online open, without downloading the video again.
            if !authenticated {
                _ = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: legacy)
                XCTAssertNotNil(try OfflineHLSReference.encryptionMaterial(for: legacy))
            }
            server.stop()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            let controller = UIViewController(); window.rootViewController = controller; window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            for reference in authenticated ? [file] : [file, legacy] {
                let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: reference)
                let playback = MatroskaPlayback(); playback.attach(controller.view)
                defer { playback.stop() }
                playback.open(prepared.url, resourceLease: prepared)
                try await waitFor("A finished or migrated encrypted HLS must decode without its origin") {
                    playback.elapsed > 0.5 && (playback.player?.media?.statistics.displayedPictures ?? 0) > 2
                }
                XCTAssertNil(playback.error)
                playback.stop()
                let systemAsset = try await prepared.systemAsset()
                XCTAssertEqual(systemAsset.url.host, "127.0.0.1")
                let item = AVPlayerItem(asset: systemAsset)
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); item.add(output)
                let player = AVPlayer(playerItem: item); player.play()
                defer { player.pause() }
                try await waitFor("The system player must also decode the saved AES key and fragments without its origin") {
                    let time = output.itemTime(forHostTime: CACurrentMediaTime())
                    return player.currentTime().seconds > 0.5 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
                }
                XCTAssertNil(item.error)
                player.pause()
            }
        } else {
            server.stop()
            let playable = try await AVURLAsset(url: file).load(.isPlayable)
            XCTAssertTrue(playable)
        }
    }

    func testHLSFinalizationWaitsForOfflineMaterialBeforeCompletingBackgroundEvents() async throws {
        try await checkHLSFinalization(cancel: false)
    }

    func testCancelDuringHLSFinalizationRemovesFilesAndCompletesBackgroundEvents() async throws {
        try await checkHLSFinalization(cancel: true)
    }

    private func checkHLSFinalization(cancel: Bool) async throws {
        let fixture = try encryptedPackage()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Segment-normalization probing adds a manifest read before the native
        // download. Hold the later offline verification, not its initial load.
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files, holdAfterRequestCount: ["/media.m3u8": 4])
        let origin = try await server.start(); defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("media.m3u8"),
                                       title: "Encrypted offline download", posterURL: nil, delivery: .hls)
        let service = StreamingMediaDownloadService.shared, manager = DownloadManagerService.shared
        let oldCompletion = service.backgroundEventsCompletionHandler
        defer { service.backgroundEventsCompletionHandler = oldCompletion }
        let download = Task { try await service.downloadHLS(resource: resource,
            preferredFilename: "Encrypted offline download.mp4", pageURL: nil, webView: WKWebView()) }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(40)) } catch { return }
            if let item = manager.activeDownload(for: resource.url) { service.cancel(itemID: item.id) }
        }
        defer {
            watchdog.cancel(); download.cancel()
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
        }
        try await waitFor("HLS did not reach its offline material preparation") {
            service.hasPendingHLSFinalization && server.receivedRequests.filter { $0.path == "/media.m3u8" }.count >= 4
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let package = try OfflineHLSReference.packageURL(for: item.localURL)
        var completions = 0
        service.backgroundEventsCompletionHandler = { completions += 1 }
        service.urlSessionDidFinishEvents(forBackgroundURLSession: URLSession.shared)
        XCTAssertEqual(completions, 0, "System completion must wait until saved video is ready")
        service.pause(itemID: item.id)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress,
                       "A completed native task cannot be suspended while saving its offline material")
        if cancel {
            service.cancel(itemID: item.id)
            do { _ = try await download.value; XCTFail("Canceled HLS finalization returned a finished file") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .canceled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.localURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        } else {
            server.releaseDownloads()
            let file = try await download.value
            XCTAssertNotNil(try OfflineHLSReference.encryptionMaterial(for: file))
            XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        }
        try await waitFor("HLS finalization did not release its background completion") { completions == 1 }
        XCTAssertFalse(service.hasPendingHLSFinalization)
    }

    func testOfflineKeyRequestsRecheckCookiesOnRedirects() async throws {
        let bytes = Data(repeating: 7, count: 16)
        let server = try DownloadPlaybackHTTPFixture(files: ["/key": bytes, "/public/key": bytes],
            redirects: ["/start": (host: "localhost", path: "/key"),
                        "/private/start": (host: "127.0.0.1", path: "/public/key")])
        let root = try await server.start(); defer { server.stop() }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "login", .value: "allowed"]))
        let scoped = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/private", .name: "scoped", .value: "allowed"]))
        let context = VideoPlaybackRequestContext(url: root, referrer: nil, userAgent: "Soulo-Key-Redirect/1.0", cookies: [cookie, scoped])
        let session = URLSession(configuration: .ephemeral); defer { session.invalidateAndCancel() }
        for path in ["start", "private/start"] {
            let (data, _) = try await context.data(for: root.appendingPathComponent(path), referrer: root, session: session)
            XCTAssertEqual(data, bytes)
        }
        let requests = server.receivedRequests
        XCTAssertTrue(requests.first(where: { $0.path == "/start" })?.headers["cookie"]?.contains("login=allowed") == true)
        XCTAssertNil(requests.first(where: { $0.path == "/key" })?.headers["cookie"], "Do not leak credentials across hosts")
        XCTAssertTrue(requests.first(where: { $0.path == "/private/start" })?.headers["cookie"]?.contains("scoped=allowed") == true)
        let publicCookie = requests.first(where: { $0.path == "/public/key" })?.headers["cookie"]
        XCTAssertTrue(publicCookie?.contains("login=allowed") == true)
        XCTAssertFalse(publicCookie?.contains("scoped=allowed") == true, "Recheck cookie paths after a redirect")
    }

    func testPlaybackSourcesRespectPauseTerminalStatesAndAreNotPersisted() throws {
        let suite = "download-playback-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let manager = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        let asset = AVURLAsset(url: URL(string: "https://example.com/video.m3u8")!)
        let item = manager.beginDownload(suggestedFilename: "clip.mp4", sourceURL: asset.url, transport: .hls,
                                         hlsUsesPersistentCookies: true).0
        XCTAssertNil(manager.playbackSource(for: item.id), "A filename alone must not advertise playback")
        manager.registerPlaybackSource(id: item.id, asset: asset)
        XCTAssertTrue(manager.playbackSource(for: item.id)?.asset === asset)
        manager.markPaused(id: item.id)
        XCTAssertNil(manager.playbackSource(for: item.id))
        manager.markResumed(id: item.id)
        XCTAssertTrue(manager.playbackSource(for: item.id)?.asset === asset)
        let restored = DownloadManagerService(userDefaults: defaults, storageDirectory: directory)
        XCTAssertNil(restored.playbackSource(for: item.id), "Cookies and live assets must not enter persisted history")
        XCTAssertEqual(restored.downloads.first(where: { $0.id == item.id })?.hlsUsesPersistentCookies, true)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        legacy.removeValue(forKey: "hlsUsesPersistentCookies")
        XCTAssertNil(try JSONDecoder().decode(BrowserDownloadItem.self, from: JSONSerialization.data(withJSONObject: legacy)).hlsUsesPersistentCookies)
        manager.markCanceled(id: item.id)
        manager.registerPlaybackSource(id: item.id, asset: asset)
        XCTAssertNil(manager.playbackSource(for: item.id), "Late preparation cannot revive a canceled item")
    }

    func testPrivatePlaybackContextSurvivesWebViewRelease() throws {
        let asset = AVURLAsset(url: URL(string: "https://example.com/private.mp4")!)
        var web: WKWebView? = {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            return WKWebView(frame: .zero, configuration: config)
        }()
        let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: web)
        XCTAssertFalse(source.persistsPosition)
        web = nil
        // WebKit can retain a newly initialized view until a later run-loop
        // turn. Model an unavailable weak reference without depending on that.
        source.webView = nil
        XCTAssertNil(source.webView)
        XCTAssertFalse(source.persistsPosition)
    }

    func testCompletedHLSCacheRemainsUntilPlayerReleasesSource() async throws {
        let session = MediaSession.shared
        defer { session.stop() }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let asset = AVURLAsset(url: file)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".movpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let downloadAsset = AVURLAsset(url: file)
        var source: DownloadPlaybackSource? = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, downloadAsset: downloadAsset)
        weak var weakSource = source
        session.open(url: asset.url, asset: asset, persistPosition: false, downloadSource: source)
        XCTAssertFalse(session.deferDownloadPackageRemoval(for: AVURLAsset(url: file), at: package), "Only the actual player asset may lease its cache")
        XCTAssertTrue(session.deferDownloadPackageRemoval(for: downloadAsset, at: package))
        source = nil
        XCTAssertNotNil(weakSource)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        session.stop()
        XCTAssertNil(weakSource)
        try await waitFor("Released HLS cache was not removed") { !FileManager.default.fileExists(atPath: package.path) }
    }

    func testAuthenticatedMP4PlaysAndDownloadContinuesToComplete() async throws {
        let bytes = try videoFixture()
        let server = try DownloadPlaybackHTTPFixture(files: ["/clip.mp4": bytes], requiredCookie: "downloadPlayback=allowed")
        let root = try await server.start()
        defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "downloadPlayback", .value: "allowed"]))
        await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("clip.mp4"), title: "Concurrent download", posterURL: nil)
        let manager = DownloadManagerService.shared, session = MediaSession.shared
        let oldRate = session.rate; session.setRate(1)
        let download = Task { try await WebResourceDownloadService.shared.download(resource, webView: web) }
        defer {
            session.stop(); session.setRate(oldRate)
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                manager.delete(item); try? FileManager.default.removeItem(at: item.localURL)
            }
            download.cancel()
        }
        try await waitFor("Video download did not publish its playback source") {
            guard let item = manager.activeDownload(for: resource.url) else { return false }
            return manager.playbackSource(for: item.id) != nil && item.receivedBytes > 0
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        let received = server.downloadedBytes
        session.open(url: source.asset.url, asset: source.asset, webView: source.webView,
            persistPosition: source.persistsPosition, downloadSource: source)
        try await waitFor("Native player did not advance during the download: \(session.error ?? "no player error")") {
            session.player.currentTime().seconds > 0.6
        }
        XCTAssertNil(session.error)
        XCTAssertTrue(session.hasVideo)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertGreaterThan(server.rangeRequests, 0)
        try await waitFor("Opening the player stopped the file transfer") { server.downloadedBytes > received }
        let before = session.player.currentTime().seconds
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        XCTAssertNil(manager.playbackSource(for: item.id))
        try await waitFor("Finishing the download stopped playback") { session.player.currentTime().seconds > before + 0.3 }
        XCTAssertNil(session.error)
    }

    func testHLSPlaybackCompletesWithIndependentDownloadAsset() async throws {
        try await checkConcurrentHLS(authenticated: false)
    }

    func testPrivateAuthenticatedHLSPlaysAcrossPauseResumeAndCompletes() async throws {
        try await checkConcurrentHLS(authenticated: true)
    }

    private func removeGeneratedDownload(_ item: BrowserDownloadItem, manager: DownloadManagerService) {
        let package = item.localURL.pathExtension == OfflineHLSReference.fileExtension
            ? try? OfflineHLSReference.packageURL(for: item.localURL) : nil
        manager.delete(item)
        try? FileManager.default.removeItem(at: item.localURL)
        if let package { OfflineHLSReference.removeDownloadedPackage(at: package) }
    }

    private func checkConcurrentHLS(authenticated: Bool) async throws {
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: file)
            playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/segment3.ts"],
                                                    requiredCookie: authenticated ? "hlsPlayback=allowed" : nil)
        let root = try await server.start()
        defer { server.stop() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = authenticated ? .nonPersistent() : .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = "Soulo-HLS-Regression/1.0"
        if authenticated {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                                                             .name: "hlsPlayback", .value: "allowed"]))
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Concurrent HLS", posterURL: nil, delivery: .hls)
        let assetOptions = await WebResourceMediaService.networkAssetOptions(for: resource, webView: web)
        XCTAssertEqual(assetOptions[AVURLAssetHTTPUserAgentKey] as? String, web.customUserAgent,
                       "Verify the browser context before handing it to the system download task")
        if authenticated {
            let capturedCookies = assetOptions[AVURLAssetHTTPCookiesKey] as? [HTTPCookie] ?? []
            XCTAssertTrue(capturedCookies.contains { $0.name == "hlsPlayback" && $0.value == "allowed" },
                          "The private WebKit cookie must already be present in the asset options")
        }
        let manager = DownloadManagerService.shared, session = MediaSession.shared
        let oldRate = session.rate; session.setRate(1)
        let download = Task { try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "concurrent-hls.mp4", pageURL: nil, webView: web) }
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            if let item = manager.activeDownload(for: resource.url) {
                XCTFail("Concurrent HLS stalled at \(item.progress), player \(session.player.currentTime().seconds)")
                StreamingMediaDownloadService.shared.cancel(itemID: item.id)
            }
        }
        defer {
            watchdog.cancel()
            let details = server.receivedRequests.map { ["path": $0.path, "headers": $0.headers] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]) {
                let evidence = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                evidence.name = "hls-local-request-context-\(authenticated)"; evidence.lifetime = .keepAlways; add(evidence)
            }
            session.stop(); session.setRate(oldRate)
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
            download.cancel()
        }
        try await waitFor("HLS task did not publish its asset") {
            guard let item = manager.activeDownload(for: resource.url) else { return false }
            return manager.playbackSource(for: item.id) != nil
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        XCTAssertNotNil(source.downloadAsset)
        XCTAssertFalse(source.asset === source.downloadAsset, "AVPlayer must not share the native download resource")
        XCTAssertEqual(item.hlsUsesPersistentCookies, !authenticated)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("allowed"))
        if authenticated {
            StreamingMediaDownloadService.shared.pause(itemID: item.id)
            XCTAssertNil(manager.playbackSource(for: item.id))
            StreamingMediaDownloadService.shared.resume(itemID: item.id)
            try await waitFor("HLS did not resume") { manager.playbackSource(for: item.id) != nil }
        }
        session.open(url: source.asset.url, asset: source.asset, persistPosition: false, downloadSource: source)
        try await waitFor("HLS player did not advance before the last segment arrived") { session.player.currentTime().seconds > 0.5 }
        XCTAssertTrue(session.player.currentItem?.asset === source.asset)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertNil(session.error)
        let before = session.player.currentTime().seconds
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        try await waitFor("HLS completion interrupted the active player") { session.player.currentTime().seconds > before + 0.3 }
        XCTAssertNil(session.error)
        let requests = server.receivedRequests
        XCTAssertGreaterThanOrEqual(requests.filter { $0.path == "/video.m3u8" }.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.headers["user-agent"] == web.customUserAgent }, String(describing: requests))
        if authenticated { XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"]?.contains("hlsPlayback=allowed") == true }) }
        session.stop()
        server.stop()
        let offlineAsset = result.pathExtension == OfflineHLSReference.fileExtension
            ? try OfflineHLSReference.playableAsset(for: result) : AVURLAsset(url: result)
        let offlineItem = AVPlayerItem(asset: offlineAsset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil); offlineItem.add(output)
        let player = AVPlayer(playerItem: offlineItem); player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitFor("Completed HLS must decode after the origin stops") {
            let time = output.itemTime(forHostTime: CACurrentMediaTime())
            return player.currentTime().seconds > 0.3 && output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil
        }
        XCTAssertNil(offlineItem.error)
    }
}

@MainActor
private final class HLSScopedContextProof: NSObject, @preconcurrency AVAssetDownloadDelegate {
    var finished = false
    var error: Error?
    var location: URL?
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error; finished = true
    }
    func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) { self.location = location }
}
