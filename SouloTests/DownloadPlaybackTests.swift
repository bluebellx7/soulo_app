import XCTest
import AVFoundation
import WebKit
import UIKit
import SwiftUI
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

    private func decoratedHLSFixture() async throws -> (DownloadPlaybackHTTPFixture, WebMediaResource) {
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
        let root = try await server.start(); server.releaseDownloads()
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Decorated TS", posterURL: nil, delivery: .hls)
        return (server, resource)
    }

    func testHLSPlaybackMeasuresOriginTransfer() async throws {
        let (server, resource) = try await decoratedHLSFixture()
        defer { server.stop() }
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil)
        XCTAssertNotEqual(asset.url, resource.url)
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await waitFor("The bridge must report traffic from its origin connection") {
            if case .rate(let bytes) = HLSPlaybackBridge.loadingStatus(asset) { return bytes > 0 }
            return false
        }
        try await waitFor("The measured rate must clear once transfers stop") { HLSPlaybackBridge.loadingStatus(asset) == nil }
    }

    func testHLSBridgePrefetchesAndRetriesNextSegment() async throws {
        let folder = "ReadingFixtures/HLSFragments"
        let first = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment0", withExtension: "ts", subdirectory: folder)))
        let second = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment1", withExtension: "ts", subdirectory: folder)))
        let prefix = Data([137,80,78,71,13,10,26,10]) + Data(repeating: 0, count: 61)
        let playlist = "#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2.022,\nfirst.ts\n#EXTINF:2.022,\nnext.ts\n#EXT-X-ENDLIST\n"
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": Data(playlist.utf8), "/first.ts": prefix + first, "/next.ts": second],
            initialServiceFailures: ["/next.ts": 1])
        let root = try await server.start()
        defer { server.stop() }
        let url = root.appendingPathComponent("video.m3u8")
        let resource = WebMediaResource(kind: .video, url: url, title: "HLS lookahead", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil)
        XCTAssertTrue(HLSPlaybackBridge.usesLocalBridge(asset))
        let (manifest, _) = try await URLSession.shared.data(from: asset.url)
        let names = String(decoding: manifest, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(names.count, 2)
        let directory = asset.url.deletingLastPathComponent()
        let firstName = try XCTUnwrap(names.first)
        let nextName = try XCTUnwrap(names.last)
        let (opening, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(String(firstName)))
        XCTAssertEqual(opening, first)
        func nextRequests() -> Int { server.receivedRequests.filter { $0.path == "/next.ts" }.count }
        try await waitFor("The bridge should fetch and retry the next segment before the decoder asks") { nextRequests() == 2 }
        let (warmed, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(String(nextName)))
        XCTAssertEqual(warmed, second)
        XCTAssertEqual(nextRequests(), 2, "The decoder should reuse the prefetched segment")
    }

    func testProgressiveCacheAdmissionUsesAvailableSpaceInsteadOfFixedSize() async throws {
        let largeLength: Int64 = 1_280 * 1024 * 1024
        let server = try DownloadPlaybackHTTPFixture(files: ["/large.mp4": Data([0]), "/oversized.mp4": Data([0])],
            responseHeaders: ["/large.mp4": ["Content-Range": "bytes 0-0/\(largeLength)"],
                              "/oversized.mp4": ["Content-Range": "bytes 0-0/\(Int64.max)"]])
        let root = try await server.start()
        defer { server.stop() }

        func asset(_ path: String) async -> AVURLAsset? {
            let url = root.appendingPathComponent(path)
            let resource = WebMediaResource(kind: .video, url: url, title: path, posterURL: nil)
            let context = VideoPlaybackRequestContext(url: url, referrer: nil, userAgent: "Soulo Cache QA", cookies: [])
            return await ProgressiveVideoPlaybackBridge.asset(for: resource, context: context)
        }

        // Advertise the file size with a one-byte probe so the test needs no large fixture or allocation.
        let available = try StorageUsageLocations.current.caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        try XCTSkipUnless((available.volumeAvailableCapacityForImportantUsage ?? 0) > 2 * largeLength, "Requires space to reserve a large playback cache")
        let large = await asset("large.mp4")
        let cache = try XCTUnwrap(large, "Available disk space must admit a video above the old per-video and total caps")
        var request = URLRequest(url: cache.url); request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(response.expectedContentLength, largeLength)
        let oversized = await asset("oversized.mp4")
        XCTAssertNil(oversized, "An object larger than the volume must use ordinary streaming without a disk reservation")
    }

    func testClosingVideoRangeLoaderCancelsPendingAndRejectsLateRequests() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/clip.mp4": Data(repeating: 1, count: 1024)],
            heldPaths: ["/clip.mp4"])
        let url = try await server.start().appendingPathComponent("clip.mp4")
        defer { server.stop() }
        let loader = VideoRangeLoader(context: VideoPlaybackRequestContext(url: url, referrer: nil,
            userAgent: "Soulo Cache QA", cookies: []))
        defer { loader.stop() }
        let pending = Task { try await loader.read(0..<128) }
        defer { pending.cancel() }
        try await waitFor("The initial range must still be in flight when the cache closes") {
            server.receivedRequests.contains { $0.headers["range"] == "bytes=0-127" }
        }
        loader.stop()
        do {
            _ = try await pending.value
            XCTFail("Stopping the cache must cancel its active request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        do {
            _ = try await loader.read(128..<256)
            XCTFail("Late prefetch work must be rejected after the cache closes")
        } catch is CancellationError {
            XCTAssertFalse(server.receivedRequests.contains { $0.headers["range"] == "bytes=128-255" })
        }
    }

    func testProgressivePlaybackCompletesCacheAndProtectsItDuringCleanup() async throws {
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "torrent-stream-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: clip)
        let firstChunk = 512 * 1024
        XCTAssertGreaterThan(bytes.count, firstChunk)
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.mp4": bytes], maximumRangeLength: 192 * 1024,
            holdRequest: { request in request.headers["range"]?.hasPrefix("bytes=\(firstChunk)-") == true })
        let root = try await server.start()
        defer { server.stop() }
        let url = root.appendingPathComponent("video.mp4")
        let resource = WebMediaResource(kind: .video, url: url, title: "Cached video", posterURL: nil)
        var asset: AVURLAsset? = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        let cacheURL = try XCTUnwrap(asset?.url)
        let transfer = try XCTUnwrap(asset.flatMap { ProgressiveVideoPlaybackBridge.transfer(for: $0) })
        XCTAssertNil(transfer.coverage.fileFraction, "The one-byte admission probe is not written to the playback cache")
        XCTAssertNotEqual(cacheURL, url)
        var request = URLRequest(url: cacheURL)
        request.setValue("bytes=0-127", forHTTPHeaderField: "Range")
        let (opening, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(opening, Data(bytes.prefix(128)))
        XCTAssertEqual(try XCTUnwrap(transfer.coverage.fileFraction), Double(firstChunk) / Double(bytes.count), accuracy: 0.000001)
        XCTAssertFalse(transfer.coverage.isComplete)
        XCTAssertTrue(transfer.coverage.ranges.isEmpty, "File offsets provide no position on a compressed video's timeline")
        server.releaseDownloads()
        try await waitFor("The remaining video must cache without decoder requests") { transfer.status == .complete }
        XCTAssertEqual(transfer.coverage.fileFraction, 1)
        let report = try await StorageUsageService.clear(.videoPlaybackCache)
        XCTAssertTrue(report.retainedCategories.contains(.videoPlaybackCache))
        let inventory = await StorageUsageService.inventory(forceRefresh: true)
        XCTAssertGreaterThan(inventory.records.first { $0.category == .videoPlaybackCache }?.bytes ?? 0, 0)
        server.stop()
        let (offline, _) = try await URLSession.shared.data(from: cacheURL)
        XCTAssertEqual(offline, bytes)
        let requests = server.receivedRequests.filter { $0.path == "/video.mp4" }.compactMap { $0.headers["range"] }
        XCTAssertEqual(requests.count, Set(requests).count, "Playback and prefetch share origin ranges")
        asset = nil
        try await waitFor("Closing the playback asset must remove its cache") {
            let root = StorageUsageLocations.current.caches.appendingPathComponent(VideoPlaybackCacheDirectory.name)
            return (try? FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty) == true
        }
    }

    func testFiniteHLSPlaybackPrefetchesTheFullRendition() async throws {
        var files: [String: Data] = [:]
        var manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: url)
            manifest += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((manifest + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/segment1.ts"])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Finite HLS", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        XCTAssertTrue(HLSPlaybackBridge.usesLocalBridge(asset))
        XCTAssertTrue(HLSPlaybackBridge.canCacheEntireVideo(asset))
        let transfer = try XCTUnwrap(HLSPlaybackBridge.transfer(for: asset))
        XCTAssertTrue(transfer.coverage.ranges.isEmpty)
        let (playlist, _) = try await URLSession.shared.data(from: asset.url)
        let segmentNames = String(decoding: playlist, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(segmentNames.count, 4)
        let directory = asset.url.deletingLastPathComponent()
        let first = try XCTUnwrap(segmentNames.first)
        _ = try await URLSession.shared.data(from: directory.appendingPathComponent(String(first)))
        XCTAssertEqual(transfer.coverage.ranges, [0..<2.022])
        XCTAssertFalse(transfer.coverage.isComplete, "A held segment must remain out of the available timeline")
        server.releaseDownloads()
        try await waitFor("Every finite segment must cache after the first playback request") { HLSPlaybackBridge.loadingStatus(asset) == .complete }
        XCTAssertTrue(transfer.coverage.isComplete)
        server.stop()
        for (index, segment) in segmentNames.enumerated() {
            let (bytes, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(String(segment)))
            XCTAssertEqual(bytes, files["/segment\(index).ts"])
        }
        try await checkSeekingCachedHLS(asset, resource: resource)
    }

    func testFiniteHLSDoesNotCacheAPartialSegment() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:3
        #EXTINF:2.022,
        full.ts
        #EXTINF:2.022,
        partial.ts
        #EXT-X-ENDLIST
        """
        let folder = "ReadingFixtures/HLSFragments"
        let fullURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment0", withExtension: "ts", subdirectory: folder))
        let secondURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment1", withExtension: "ts", subdirectory: folder))
        let full = try Data(contentsOf: fullURL)
        let second = try Data(contentsOf: secondURL)
        let partial = Data(second.prefix(second.count / 2))
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": Data(manifest.utf8), "/full.ts": full, "/partial.ts": partial],
            responseHeaders: ["/full.ts": ["Content-Range": "bytes 0-\(full.count - 1)/\(full.count)"],
                              "/partial.ts": ["Content-Range": "bytes 0-\(partial.count - 1)/\(second.count)"]])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Partial HLS", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        let transfer = try XCTUnwrap(HLSPlaybackBridge.transfer(for: asset))
        let (playlist, _) = try await URLSession.shared.data(from: asset.url)
        let names = String(decoding: playlist, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(names.count, 2)
        let directory = asset.url.deletingLastPathComponent()
        let first = directory.appendingPathComponent(String(try XCTUnwrap(names.first)))
        let last = directory.appendingPathComponent(String(try XCTUnwrap(names.last)))
        let (cached, _) = try await URLSession.shared.data(from: first)
        XCTAssertEqual(cached, full, "A 206 response that contains the whole segment can be cached")
        if let (_, response) = try? await URLSession.shared.data(from: last) {
            let status = try XCTUnwrap((response as? HTTPURLResponse)?.statusCode)
            XCTAssertFalse((200...299).contains(status), "An incomplete segment must not be served as playable data")
        }
        XCTAssertEqual(transfer.coverage.ranges, [0..<2.022])
        XCTAssertFalse(transfer.coverage.isComplete)
    }

    func testFiniteHLSDoesNotBridgeAPartialPlaylist() async throws {
        let manifest = Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": manifest],
            responseHeaders: ["/video.m3u8": ["Content-Range": "bytes 0-\(manifest.count - 1)/\(manifest.count + 1)"]])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Partial playlist", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        XCTAssertEqual(asset.url, resource.url)
        XCTAssertFalse(HLSPlaybackBridge.usesLocalBridge(asset))
    }

    func testFiniteHLSCanCacheALargeSegment() async throws {
        let manifest = Data("#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXTINF:2,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment0", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
        let packets = try Data(contentsOf: url)
        var segment = Data()
        while segment.count <= 32 * 1024 * 1024 { segment.append(packets) }
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": manifest, "/segment.ts": segment])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Large segment", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        let transfer = try XCTUnwrap(HLSPlaybackBridge.transfer(for: asset))
        let (playlist, _) = try await URLSession.shared.data(from: asset.url)
        let name = try XCTUnwrap(String(decoding: playlist, as: UTF8.self).split(separator: "\n").first { !$0.hasPrefix("#") })
        var request = URLRequest(url: asset.url.deletingLastPathComponent().appendingPathComponent(String(name)))
        request.setValue("bytes=0-127", forHTTPHeaderField: "Range")
        let (cached, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-127/\(segment.count)")
        XCTAssertEqual(cached, packets.prefix(128))
        XCTAssertEqual(transfer.coverage.ranges, [0..<2])
        XCTAssertTrue(transfer.coverage.isComplete)
    }

    private func checkSeekingCachedHLS(_ asset: AVURLAsset, resource: WebMediaResource) async throws {
        let session = MediaSession.shared
        let oldRate = session.rate
        defer { session.stop(); session.setRate(oldRate) }
        let source = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil, persistPosition: false)
        source.webMediaContext = WebMediaPlaybackContext(resource: resource, pageURL: nil, sourceWebView: nil, episodeList: nil)
        session.open(url: resource.url, asset: asset, persistPosition: false, downloadSource: source, initialRate: 1)
        try await waitFor("System playback did not start from the local HLS cache") { session.player.currentTime().seconds > 0.2 }
        let item = try XCTUnwrap(session.player.currentItem)
        session.seek(4.2)
        try await waitFor("System playback must advance after seeking with the origin offline") {
            session.player.currentTime().seconds > 4.5 && session.player.timeControlStatus == .playing
        }
        XCTAssertTrue(session.player.currentItem === item)
        XCTAssertNil(session.error)
        session.stop()

        let prepared = try await SouloMediaPlaybackSource.prepare(native: source, originalURL: resource.url)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        window.rootViewController = controller; window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        playback.open(prepared.url, resourceLease: prepared, originalURL: resource.url, initialRate: 1)
        try await waitFor("Soulo playback did not start from the local HLS cache") {
            (playback.player?.currentTime ?? 0) > 0.2 && (playback.player?.decodedFrameCount ?? 0) > 0
        }
        let decoder = try XCTUnwrap(playback.player)
        playback.seek(4.2)
        try await waitFor("Soulo playback must advance after seeking with the origin offline") {
            (playback.player?.currentTime ?? 0) > 4.5 && playback.playing
        }
        XCTAssertTrue(playback.player === decoder)
        XCTAssertNil(playback.error)
    }

    func testAdaptiveHLSCachesTheRequestedRenditionFromASeek() async throws {
        let master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=300000\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=900000\nhigh.m3u8\n"
        var files = ["/master.m3u8": Data(master.utf8)]
        for quality in ["low", "high"] {
            var manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:3\n"
            for index in 0..<4 {
                let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
                let name = quality + String(index) + ".ts"
                files["/" + name] = try Data(contentsOf: url)
                manifest += "#EXTINF:2.022,\n" + name + "\n"
            }
            files["/" + quality + ".m3u8"] = Data((manifest + "#EXT-X-ENDLIST\n").utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/high3.ts"])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("master.m3u8"),
            title: "Adaptive HLS", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        let transfer = try XCTUnwrap(HLSPlaybackBridge.transfer(for: asset))
        let directory = asset.url.deletingLastPathComponent()
        func entries(_ url: URL) async throws -> [String] {
            let (body, _) = try await URLSession.shared.data(from: url)
            return String(decoding: body, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
        }
        let variants = try await entries(asset.url)
        XCTAssertEqual(variants.count, 2)
        let high = try await entries(directory.appendingPathComponent(try XCTUnwrap(variants.last)))
        guard high.count == 4 else { return XCTFail("Expected four media segments") }
        _ = try await URLSession.shared.data(from: directory.appendingPathComponent(high[2]))
        XCTAssertEqual(transfer.coverage.ranges, [(2.022 * 2)..<(2.022 * 3)])
        XCTAssertFalse(transfer.coverage.isComplete)
        server.releaseDownloads()
        try await waitFor("Only the selected rendition must reach completion") { transfer.coverage.isComplete }
        server.stop()
        for (index, name) in high.enumerated() {
            let (body, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(name))
            XCTAssertEqual(body, files["/high\(index).ts"])
        }
    }

    func testFragmentedHLSWaitsForInitializationBeforeReportingCacheCoverage() async throws {
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:3
        #EXT-X-MAP:URI="init.m4s"
        #EXTINF:2.000,
        first.m4s
        #EXT-X-ENDLIST
        """
        let folder = "ReadingFixtures/ExtensionMedia/DASH"
        let initialization = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "init-stream0", withExtension: "m4s", subdirectory: folder)))
        let fragment = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "chunk-stream0-00001", withExtension: "m4s", subdirectory: folder)))
        let server = try DownloadPlaybackHTTPFixture(files: ["/video.m3u8": Data(manifest.utf8),
            "/init.m4s": initialization, "/first.m4s": fragment], heldPaths: ["/init.m4s"],
            responseHeaders: ["/init.m4s": ["Content-Type": "video/mp4"], "/first.m4s": ["Content-Type": "video/mp4"]])
        let root = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"), title: "Fragmented", posterURL: nil, delivery: .hls)
        let asset = await WebResourceMediaService.asset(for: resource, webView: nil, cacheForPlayback: true)
        let transfer = try XCTUnwrap(HLSPlaybackBridge.transfer(for: asset))
        let (body, _) = try await URLSession.shared.data(from: asset.url)
        let lines = String(decoding: body, as: UTF8.self).split(separator: "\n")
        let directory = asset.url.deletingLastPathComponent()
        let first = try XCTUnwrap(lines.first { !$0.hasPrefix("#") })
        let map = try XCTUnwrap(lines.first { $0.hasPrefix("#EXT-X-MAP:") }?.split(separator: "\"").dropFirst().first)
        let (cachedFragment, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(String(first)))
        XCTAssertEqual(cachedFragment, fragment)
        XCTAssertTrue(transfer.coverage.ranges.isEmpty)
        XCTAssertFalse(transfer.coverage.isComplete)
        server.releaseDownloads()
        try await waitFor("Initialization and media must both be cached") { transfer.coverage.isComplete }
        server.stop()
        let (cachedInitialization, _) = try await URLSession.shared.data(from: directory.appendingPathComponent(String(map)))
        XCTAssertEqual(cachedInitialization, initialization)
        XCTAssertEqual(transfer.coverage.ranges, [0..<2])
    }

    func testDecoratedHLSSegmentsPlayAndDownloadAsRealVideo() async throws {
        let (server, resource) = try await decoratedHLSFixture()
        defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
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
        let audio = try await downloaded.loadTracks(withMediaType: .audio)
        XCTAssertGreaterThan(duration.seconds, 1)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(audio.count, 1)
        let lateFrame = try await AVAssetImageGenerator(asset: downloaded).image(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.75))
        XCTAssertGreaterThan(lateFrame.image.width, 0)
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
            playback.elapsed > 0.3 && (playback.player?.decodedFrameCount ?? 0) > 0
        }
        XCTAssertNil(playback.error)
        XCTAssertGreaterThan(playback.player?.videoSize.width ?? 0, 0)
    }
    func testExtendedPlaybackKeepsWebCookiesScopedAcrossRedirects() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-vp9-opus", withExtension: "webm",
                                                         subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: file)
        let cases = [
            (entry: "/private/host.webm", host: "localhost", target: "/private/clip.webm"),
            (entry: "/private/path.webm", host: "127.0.0.1", target: "/public/clip.webm"),
        ]
        let server = try DownloadPlaybackHTTPFixture(
            files: Dictionary(uniqueKeysWithValues: cases.map { ($0.target, bytes) }),
            redirects: Dictionary(uniqueKeysWithValues: cases.map { ($0.entry, (host: $0.host, path: $0.target)) }))
        let base = try await server.start()
        defer { server.stop() }
        server.releaseDownloads()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let playback = MatroskaPlayback()
        playback.attach(controller.view)
        defer { playback.stop(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }

        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/private", .name: "soulo_session",
                                                           .value: "local-fixture"]))
        for sample in cases {
            let url = try XCTUnwrap(URL(string: sample.entry, relativeTo: base)?.absoluteURL)
            let context = VideoPlaybackRequestContext(url: url, referrer: nil, userAgent: "SouloTransferQA", cookies: [cookie])
            playback.open(url, requestContext: context)
            try await waitFor("Redirected WebM must continue decoding") {
                playback.elapsed > 0.3 && (playback.player?.decodedFrameCount ?? 0) > 0
            }
            XCTAssertTrue(playback.player is ExtendedPlaybackDecoder)
            let initial = try XCTUnwrap(server.receivedRequests.first(where: { $0.path == sample.entry }))
            XCTAssertEqual(initial.headers["cookie"], "soulo_session=local-fixture")
            let redirected = server.receivedRequests.filter { $0.path == sample.target }
            XCTAssertFalse(redirected.isEmpty)
            XCTAssertTrue(redirected.allSatisfy { $0.headers["cookie"] == nil })
        }
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
                playback.elapsed > 0.5 && (playback.player?.decodedFrameCount ?? 0) > 2
            }
            let frames = playback.player?.decodedFrameCount ?? 0
            playback.seek(4.5)
            try await waitFor("Seeking offline encrypted media did not decode new frames") {
                playback.elapsed > 4.8 && (playback.player?.decodedFrameCount ?? 0) > frames
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
            playback.elapsed > 0.5 && (playback.player?.decodedFrameCount ?? 0) > 2
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
                    playback.elapsed > 0.5 && (playback.player?.decodedFrameCount ?? 0) > 2
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
        // Offline verification uses the source playlist as its referrer. The
        // preflight uses the containing page and AVFoundation can read the
        // playlist a different number of times depending on the OS.
        let isOfflineRead: @Sendable (DownloadPlaybackHTTPFixture.ReceivedRequest) -> Bool = { request in
            guard request.path == "/media.m3u8", let host = request.headers["host"] else { return false }
            return request.headers["referer"] == "http://\(host)/media.m3u8"
        }
        let server = try DownloadPlaybackHTTPFixture(files: fixture.files, holdRequest: isOfflineRead)
        let origin = try await server.start(); defer { server.stop() }
        let pageURL = origin.appendingPathComponent("page.html")
        let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("media.m3u8"),
                                       title: "Encrypted offline download", posterURL: nil, delivery: .hls, sourcePageURL: pageURL)
        let service = StreamingMediaDownloadService.shared, manager = DownloadManagerService.shared
        let oldCompletion = service.backgroundEventsCompletionHandler
        defer { service.backgroundEventsCompletionHandler = oldCompletion }
        let download = Task { try await service.downloadHLS(resource: resource,
            preferredFilename: "Encrypted offline download.mp4", pageURL: pageURL, webView: WKWebView()) }
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
            service.hasPendingHLSFinalization && server.receivedRequests.contains(where: isOfflineRead)
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

    func testHLSDownloadCacheRemainsLeasedAfterAutomaticPlayerTakesOver() async throws {
        let session = MediaSession.shared
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac",
            withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let asset = AVURLAsset(url: video)
        let downloadAsset = AVURLAsset(url: video)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".movpkg")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { session.stop(); try? FileManager.default.removeItem(at: package) }

        var source: DownloadPlaybackSource? = DownloadPlaybackSource(asset: asset, pageURL: nil,
            webView: nil, persistPosition: false, downloadAsset: downloadAsset)
        weak var retained = source
        session.open(url: video, asset: asset, persistPosition: false, downloadSource: source, autoplay: false)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        do {
            let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: MediaPlaybackContent())
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
            try await waitFor("Soulo did not take over the download's prepared asset") {
                session.soulo?.preparedPlaybackSource?.native === retained
            }
            XCTAssertNotNil(retained)
            XCTAssertNil(session.player.currentItem)
            XCTAssertTrue(session.deferDownloadPackageRemoval(for: downloadAsset, at: package))
            source = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        }
        session.stop()
        try await waitFor("The automatic player did not release its download cache") {
            retained == nil && !FileManager.default.fileExists(atPath: package.path)
        }
    }

    func testPlayingAnActiveMP4DownloadReadsVerifiedRangesWithoutContactingTheOrigin() async throws {
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "torrent-stream-h264-aac",
            withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: clip)
        let path = "/shared-video.mp4"
        let server = try DownloadPlaybackHTTPFixture(files: [path: bytes],
            responseHeaders: [path: ["ETag": "\"soulo-shared-video\""]], holdRequest: { request in
                guard let range = request.headers["range"], let offset = Int(range.dropFirst(6).split(separator: "-").first ?? "") else { return false }
                return offset > bytes.count / 2
            })
        let url = try await server.start().appendingPathComponent("shared-video.mp4")
        defer { server.stop() }
        let manager = DownloadManagerService.shared
        let download = Task { try await WebResourceDownloadService.shared.download(url) }
        defer {
            download.cancel()
            if let item = manager.downloads.first(where: { $0.sourceURLString == url.absoluteString }) {
                manager.delete(item); try? FileManager.default.removeItem(at: item.localURL)
            }
        }
        try await waitFor("Verified segments must be usable before the download finishes") {
            guard let item = manager.activeDownload(for: url) else { return false }
            return item.receivedBytes >= 256 * 1024 && item.progress < 1
        }
        let item = try XCTUnwrap(manager.activeDownload(for: url))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        XCTAssertNotEqual(source.asset.url, url)
        let range = 4_096..<16_384
        var request = URLRequest(url: source.asset.url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        let prefixReads = server.receivedRequests.filter { $0.headers["range"]?.hasPrefix("bytes=0-") == true }.count
        for _ in 0..<2 {
            let (portion, _) = try await URLSession.shared.data(for: request)
            XCTAssertEqual(portion, bytes.subdata(in: range))
        }
        XCTAssertEqual(server.receivedRequests.filter { $0.headers["range"]?.hasPrefix("bytes=0-") == true }.count, prefixReads)
        XCTAssertFalse(server.receivedRequests.contains { $0.headers["range"] == request.value(forHTTPHeaderField: "Range") })

        BackgroundDownloadService.shared.pause(id: item.id)
        try await waitFor("A segmented download must pause") { manager.downloads.first(where: { $0.id == item.id })?.status == .paused }
        let (paused, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(paused, bytes.subdata(in: range))
        BackgroundDownloadService.shared.resume(id: item.id)
        server.releaseDownloads()
        let finished = try await download.value
        XCTAssertEqual(try Data(contentsOf: finished), bytes)
        server.stop()
        let (offline, _) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(offline, bytes.subdata(in: range))
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

    func testOnlineFullscreenKeepsPlayingThroughShortHLSDelay() async throws {
        try await checkFullscreenWithHeldSegment(expectsReconnect: false)
    }

    func testOnlineFullscreenReconnectsAtTheStallPosition() async throws {
        try await checkFullscreenWithHeldSegment(expectsReconnect: true)
    }

    private func checkFullscreenWithHeldSegment(expectsReconnect: Bool) async throws {
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts",
                subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(index).ts"] = try Data(contentsOf: fixture)
            playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        for usesSystem in [true, false] {
            try await checkFullscreenWithHeldSegment(files: files, usesSystem: usesSystem, expectsReconnect: expectsReconnect)
        }
    }

    private func checkFullscreenWithHeldSegment(files: [String: Data], usesSystem: Bool, expectsReconnect: Bool) async throws {
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/segment3.ts"])
        let root = try await server.start()
        defer { server.stop() }
        let url = root.appendingPathComponent("video.m3u8")
        let session = MediaSession.shared
        let oldRate = session.rate, oldLoop = session.loop
        let playbackRate: Float = expectsReconnect ? 1.25 : 1
        session.loop = false
        session.setRate(1)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        defer {
            window.rootViewController?.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            session.stop(); session.setRate(oldRate); session.loop = oldLoop
        }

        let host: UIHostingController<AnyView>
        if usesSystem {
            let source = DownloadPlaybackSource(asset: AVURLAsset(url: url), pageURL: root, webView: nil, persistPosition: false)
            let resource = WebMediaResource(kind: .video, url: url, title: "Stalled HLS", posterURL: nil, delivery: .hls)
            source.webMediaContext = WebMediaPlaybackContext(resource: resource, pageURL: root, sourceWebView: nil, episodeList: nil)
            session.open(url: url, asset: source.asset, persistPosition: false, downloadSource: source, initialRate: playbackRate)
            host = UIHostingController(rootView: AnyView(MediaPlaybackContent(initialFullscreen: true, fullscreenOnly: true, initialSystemPlayer: true)))
        } else {
            host = UIHostingController(rootView: AnyView(MatroskaPlayerView(url: url, persistPosition: false,
                initialRate: playbackRate, startsFullscreen: true)))
        }
        func decoder() -> AnyObject? {
            if usesSystem { return session.player.currentItem }
            return session.soulo?.player
        }
        func position() -> Double {
            if usesSystem { return session.player.currentTime().seconds }
            return (session.soulo?.player?.currentTime ?? 0)
        }
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await waitFor("Video must play before the origin holds its last segment") {
            host.presentedViewController != nil && position() > 3
        }
        let originalDecoder = try XCTUnwrap(decoder())
        XCTAssertNotEqual(usesSystem ? session.videoLoading : session.soulo?.videoLoading, .complete)
        if usesSystem { XCTAssertEqual(session.player.currentItem?.preferredForwardBufferDuration, 30) }
        if !expectsReconnect {
            try await waitFor("The player must request the origin's held segment before the outage is released") {
                server.receivedRequests.contains { $0.path == "/segment3.ts" }
            }
            let start = ContinuousClock.now, startPosition = position()
            try await Task.sleep(for: .seconds(1))
            XCTAssertGreaterThan(position(), startPosition + 0.4, "Buffered video must keep playing while the next segment is held")
            server.releaseDownloads()
            try await waitFor("Playback must cross the delayed segment without reconnecting") { position() > 6.2 }
            XCTAssertLessThan(start.duration(to: .now), .seconds(4.5))
            XCTAssertTrue(decoder() === originalDecoder)
            XCTAssertNil(session.error)
            return
        }
        try await waitFor("A mid-video stall must reconnect in the same fullscreen player") {
            guard let current = decoder() else { return false }
            return current !== originalDecoder
        }
        XCTAssertNotNil(host.presentedViewController)
        server.releaseDownloads()
        try await waitFor("Reconnection must seek back to the stalled position") {
            position() > 0.2
        }
        XCTAssertGreaterThan(position(), 3, "Reconnection must not start the video again")
        try await waitFor("Playback must reach the recovered segment") {
            position() > 6.2
        }
        XCTAssertNil(session.error)
        XCTAssertEqual(session.rate, playbackRate)
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
