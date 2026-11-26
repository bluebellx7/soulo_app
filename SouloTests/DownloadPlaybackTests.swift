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
    private struct MovieDownloadSample: Decodable {
        let id: String
        let page: URL
        let inspectOnly: Bool?
        let expectedDuration: Double?
        let useSegmentDownloader: Bool?
        let search: MovieSearch?
        let hlsURL: URL?
    }

    private struct MovieSearch: Decodable {
        let entry: URL
        let query: String
        let field: String
        let submit: String?
        let result: String?
        let resultText: String?
        let play: String?
    }

    func testPreviouslySavedMoviePlaysOffline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SOULO_QA_SAVED_MOVIE"], name.hasPrefix("Movie QA "), !name.contains("/") else {
            throw XCTSkip("Supply a retained movie from a simulator acceptance run")
        }
        let manager = DownloadManagerService.shared
        let item = manager.downloads.first { $0.fileName == name && $0.status == .finished }
        let file = try XCTUnwrap(item?.localURL ?? environment["SOULO_QA_RETAINED_COPY"].map { URL(fileURLWithPath: $0) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKeyAndVisible()
        }
        let duration = environment["SOULO_QA_SAVED_MOVIE_DURATION"].flatMap(Double.init)
        let details = try await verifyOfflinePlayback(file, expected: duration, in: host.view)
        print("MOVIE_QA|retained-download|played-offline|\(details)")
        if let item { removeGeneratedDownload(item, manager: manager) }
    }

    func testLocalHLSBundlePlaysThroughSouloPlayer() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_QA_OFFLINE_PLAYBACK"] == "1",
                          "Opt-in decoder playback on the simulator")
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("Offline-\(UUID()).hls", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        var manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let name = "segment\(index)"
            let segment = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            let filename = segment.lastPathComponent
            try FileManager.default.copyItem(at: segment, to: bundle.appendingPathComponent(filename))
            manifest += "#EXTINF:2.0,\n\(filename)\n"
        }
        try (manifest + "#EXT-X-ENDLIST\n").write(to: bundle.appendingPathComponent("index.m3u8"),
                                                    atomically: true, encoding: .utf8)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let details = try await verifyOfflinePlayback(bundle, expected: 8, in: host.view)
        print("MOVIE_QA|local-hls-fixture|played-offline|\(details)")
    }

    func testClosingWebViewResolvesPageConfirm() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let model = WebViewModel()
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: WebViewRepresentable(viewModel: model))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitFor("The web view did not attach") { model.webView?.window === window }
        let web = try XCTUnwrap(model.webView)
        let coordinator = try XCTUnwrap(web.uiDelegate as? WebViewRepresentable.Coordinator)
        web.loadHTMLString("<body>Confirm test</body>", baseURL: nil)
        try await waitFor("The local page did not finish loading") { web.url != nil && !web.isLoading }
        let result = Task {
            try await web.callAsyncJavaScript("return confirm('Leave this page?');",
                                              arguments: [:], in: nil, contentWorld: .page) as? Bool
        }
        try await waitFor("WebKit did not show the confirm dialog") { host.presentedViewController is UIAlertController }
        WebViewRepresentable.dismantleUIView(web, coordinator: coordinator)
        let confirmed = try await result.value
        XCTAssertEqual(confirmed, false)
    }

    /// Runs an opt-in cohort through the normal browser and video downloader.
    /// Entries are public page URLs, never cached media URLs or session tokens.
    func testLiveMovieDirectoryDownloadCohort() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["SOULO_MOVIE_DOWNLOAD_COHORT"],
              let data = Data(base64Encoded: manifest) else { throw XCTSkip("Opt-in live movie QA") }
        let samples = try JSONDecoder().decode([MovieDownloadSample].self, from: data)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), previous = scene.keyWindow
        let models = samples.map { _ in WebViewModel() }
        let manager = DownloadManagerService.shared
        let prefix = "Movie QA \(UUID().uuidString)"
        window.rootViewController = UIHostingController(rootView: ZStack {
            ForEach(models.indices, id: \.self) { index in
                WebViewRepresentable(viewModel: models[index])
            }
        })
        window.makeKeyAndVisible()
        defer {
            window.rootViewController = nil; window.isHidden = true; previous?.makeKeyAndVisible()
            for item in manager.downloads where item.fileName.hasPrefix(prefix) {
                removeGeneratedDownload(item, manager: manager)
            }
        }
        let scanOnly = environment["SOULO_MOVIE_SCAN_ONLY"] == "1"
        let replayOffline = environment["SOULO_QA_OFFLINE_PLAYBACK"] == "1"
        let timeout = Double(environment["SOULO_MOVIE_DOWNLOAD_TIMEOUT"] ?? "") ?? 240
        let deadline = ContinuousClock.now + .seconds(timeout)
        var jobs: [Task<Void, Never>] = []
        var pending = Set(samples.indices)
        var saved: [Int: (file: URL, expected: Double?)] = [:]
        var activePeak = 0
        var pausedOne = false
        let exercisePause = environment["SOULO_MOVIE_PAUSE_RESUME"] == "1"
        for (index, sample) in samples.enumerated() {
            let model = models[index]
            model.loadURL(sample.search?.entry ?? sample.page)
            jobs.append(Task { @MainActor in
                defer { pending.remove(index) }
                do {
                    if let search = sample.search {
                        try await runMovieSearch(search, sample: sample, model: model)
                    }
                    let source: (WKWebView, WebMediaResource, Double?)?
                    if let hlsURL = sample.hlsURL {
                        try await waitFor("The requesting page did not open") { model.webView?.url?.host == sample.page.host }
                        let web = try XCTUnwrap(model.webView)
                        let resource = WebMediaResource(kind: .video, url: hlsURL, title: "Previously observed HLS",
                            posterURL: nil, delivery: .hls, sourcePageURL: sample.page)
                        source = (web, resource, nil)
                    } else {
                        source = try await movieDownloadSource(model, inspectOnly: sample.inspectOnly == true)
                    }
                    guard let (web, resource, duration) = source else {
                        print("MOVIE_QA|\(sample.id)|no-source|httpHost=\(model.webView?.url?.host ?? "")|title=\(model.webView?.title ?? "")|error=\(model.errorMessage ?? "")")
                        if !scanOnly, sample.inspectOnly != true { XCTFail("\(sample.id) produced no downloadable video") }
                        return
                    }
                    print("MOVIE_QA|\(sample.id)|source|delivery=\(resource.delivery.rawValue)|host=\(resource.url.host ?? "")|duration=\(duration ?? 0)")
                    guard !scanOnly, sample.inspectOnly != true else { return }
                    let expected: Double?
                    if let seconds = sample.expectedDuration ?? duration {
                        expected = seconds
                    } else if resource.delivery == .hls || resource.delivery == .direct {
                        let options = await WebResourceMediaService.networkAssetOptions(for: resource, webView: web)
                        let source = AVURLAsset(url: resource.url, options: options)
                        let seconds = try? await source.load(.duration).seconds
                        expected = seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                    } else { expected = nil }
                    let name = "\(prefix) \(index).mp4"
                    let file: URL
                    if sample.useSegmentDownloader == true, resource.delivery == .hls {
                        file = try await AuthenticatedHLSDownloadService.shared.download(resource: resource,
                            preferredName: name, pageURL: model.currentURL, webView: web)
                    } else {
                        file = try await WebResourceDownloadService.shared.download(resource,
                            preferredFilename: name, pageURL: model.currentURL, webView: web)
                    }
                    let item = try XCTUnwrap(manager.downloads.first {
                        $0.localURL.standardizedFileURL.path == file.standardizedFileURL.path
                    })
                    XCTAssertEqual(item.status, .finished)
                    print("MOVIE_QA|\(sample.id)|finished-transfer|format=\(file.pathExtension)|bytes=\(item.receivedBytes)")
                    if replayOffline {
                        saved[index] = (file, expected)
                    } else {
                        let media = try await verifyDownloadedMovie(file, expected: expected)
                        print("MOVIE_QA|\(sample.id)|saved|\(media)|bytes=\(item.receivedBytes)")
                    }
                } catch {
                    let issue = error as NSError
                    print("MOVIE_QA|\(sample.id)|failed|domain=\(issue.domain)|code=\(issue.code)|message=\(issue.localizedDescription)")
                    if !scanOnly, sample.inspectOnly != true { XCTFail("\(sample.id) download or verification failed") }
                }
            })
        }
        defer { jobs.forEach { $0.cancel() } }
        while !pending.isEmpty, .now < deadline {
            let active = manager.downloads.filter { $0.fileName.hasPrefix(prefix) && $0.status == .inProgress }
            activePeak = max(activePeak, active.count)
            if exercisePause, !pausedOne, active.count >= 2,
               let item = active.first(where: { [.background, .hls].contains($0.transport) && $0.receivedBytes > 0 }) {
                pausedOne = true
                if item.transport == .background { BackgroundDownloadService.shared.pause(id: item.id) }
                else { StreamingMediaDownloadService.shared.pause(itemID: item.id) }
                try await waitFor("A live download should pause independently") {
                    manager.downloads.first { $0.id == item.id }?.status == .paused
                }
                try await Task.sleep(for: .milliseconds(750))
                if item.transport == .background { BackgroundDownloadService.shared.resume(id: item.id) }
                else { StreamingMediaDownloadService.shared.resume(itemID: item.id) }
                print("MOVIE_QA|cohort|pause-resume=\(item.transport.rawValue)")
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        for index in pending.sorted() {
            print("MOVIE_QA|\(samples[index].id)|timeout")
        }
        print("MOVIE_QA|cohort|peak=\(activePeak)")
        XCTAssertTrue(pending.isEmpty, "The cohort did not finish before the deadline")
        if environment["SOULO_MOVIE_REQUIRE_CONCURRENCY"] == "1" { XCTAssertGreaterThanOrEqual(activePeak, 2) }
        if exercisePause { XCTAssertTrue(pausedOne) }
        if replayOffline, !scanOnly, pending.isEmpty {
            let host = UIViewController()
            window.rootViewController = host
            for (index, item) in saved.sorted(by: { $0.key < $1.key }) {
                do {
                    let media = try await verifyOfflinePlayback(item.file, expected: item.expected, in: host.view)
                    print("MOVIE_QA|\(samples[index].id)|played-offline|\(media)")
                } catch {
                    XCTFail("\(samples[index].id) offline playback failed: \(error)")
                }
            }
        }
    }

    private func runMovieSearch(_ search: MovieSearch, sample: MovieDownloadSample, model: WebViewModel) async throws {
        try await waitFor("Search entry did not load") { model.webView?.url?.host == search.entry.host }
        let web = try XCTUnwrap(model.webView)
        let submit = """
            const input = document.querySelector(field);
            if (!input || (submit ? !document.querySelector(submit) : !input.form)) return false;
            const prototype = input instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
            Object.getOwnPropertyDescriptor(prototype, 'value').set.call(input, query);
            input.dispatchEvent(new Event('input', {bubbles: true}));
            input.dispatchEvent(new Event('change', {bubbles: true}));
            setTimeout(() => submit ? document.querySelector(submit)?.click() : input.form?.requestSubmit(), 100);
            return true;
            """
        let click = """
            const result = [...document.querySelectorAll('a, button, [role="button"]')].find(link =>
                link.href === target || (link.textContent.trim() === target && link.getBoundingClientRect().width > 0));
            if (!result) return false;
            result.removeAttribute('target');
            setTimeout(() => result.click(), 50);
            return true;
            """
        func perform(_ script: String, arguments: [String: Any]) async throws {
            for _ in 0..<100 {
                let result = try? await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
                if result as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw URLError(.timedOut)
        }
        try await perform(submit, arguments: ["field": search.field, "query": search.query, "submit": search.submit ?? ""])
        if let resultText = search.resultText {
            try await perform("return document.body?.innerText.includes(text) && location.pathname !== initialPath;",
                              arguments: ["text": resultText, "initialPath": search.entry.path.isEmpty ? "/" : search.entry.path])
        }
        if let result = search.result {
            try await perform(click, arguments: ["target": result])
        }
        if let play = search.play { try await perform(click, arguments: ["target": play]) }
        if search.resultText == nil {
            try await waitFor("The result did not open the expected video page") { web.url == sample.page }
        }
        print("MOVIE_QA|\(sample.id)|search-result|query=\(search.query)|host=\(web.url?.host ?? "")")
    }

    private func verifyOfflinePlayback(_ file: URL, expected: Double?, in view: UIView) async throws -> String {
        let ext = file.pathExtension.lowercased()
        let asset: AVURLAsset?
        switch ext {
        case "movpkg":
            asset = try OfflineHLSReference.playablePackage(at: file)
        case OfflineHLSReference.fileExtension, "hls", "m3u8":
            if ext == OfflineHLSReference.fileExtension, try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                asset = try OfflineHLSReference.playableAsset(for: file)
            } else {
                asset = AVURLAsset(url: try LocalHLSMedia.playlistURL(for: file))
            }
        default:
            asset = nil
        }
        let prepared: SouloMediaPlaybackSource?
        if let asset {
            let native = DownloadPlaybackSource(asset: asset, pageURL: nil, webView: nil)
            prepared = try await SouloMediaPlaybackSource.prepare(native: native, originalURL: file)
        } else {
            prepared = nil
        }
        let player = MatroskaPlayback()
        player.attach(view)
        player.open(prepared?.url ?? file, resourceLease: prepared, originalURL: file, initialRate: 1)
        defer { player.stop() }
        try await waitFor("The file did not play: \(file.pathExtension)") {
            guard let decoder = player.player else { return false }
            return decoder.currentTime > 0.30 && decoder.decodedFrameCount > 1 && decoder.duration > 0
        }
        let decoder = try XCTUnwrap(player.player)
        let duration = decoder.duration
        if let expected {
            XCTAssertEqual(duration, expected, accuracy: max(2, expected * 0.01), "Saved length must match the full source")
        }
        XCTAssertTrue(decoder.isSeekable)
        let tail = duration < 15 ? 0.75 : 0.93
        for target in [duration * 0.5, duration * tail] where target > 0.85 {
            let frames = decoder.decodedFrameCount
            player.seek(target)
            do {
                try await waitFor("The downloaded file did not render after seeking to \(target)") {
                    decoder.currentTime >= target - 0.1 && decoder.decodedFrameCount > frames
                }
            } catch {
                print("PLAYBACK_QA seek=\(target) actual=\(decoder.currentTime) duration=\(decoder.duration) frames=\(decoder.decodedFrameCount) before=\(frames) state=\(decoder.state)")
                throw error
            }
        }
        return "duration=\(duration)|expected=\(expected ?? 0)|decodedFrames=\(decoder.decodedFrameCount)|format=\(file.pathExtension)|decoder=\(type(of: decoder))"
    }

    private func movieDownloadSource(_ model: WebViewModel, inspectOnly: Bool) async throws -> (WKWebView, WebMediaResource, Double?)? {
        let deadline = ContinuousClock.now + .seconds(inspectOnly ? 8 : 28)
        while .now < deadline {
            try Task.checkCancellation()
            if let web = model.webView, web.url != nil,
               let snapshot = try? await WebResourceInspectionService.inspect(webView: web, frames: model.mediaFrameInfos) {
                let frames: [WKFrameInfo?] = [nil] + model.mediaFrameInfos.map(Optional.some)
                let candidates = snapshot.videos + snapshot.configuredVideos
                var detected = candidates.first(where: { $0.delivery != .dash }) ?? candidates.first
                if detected == nil, !inspectOnly {
                    for frame in frames {
                        if let target = await WebResourceInspectionService.fallbackVideoTarget(webView: web, frame: frame) {
                            detected = target.resource
                            break
                        }
                    }
                }
                guard let detected else {
                    try await Task.sleep(for: .milliseconds(350))
                    continue
                }
                var observedDuration: Double?
                var activeResource: WebMediaResource?
                for frame in frames {
                    let query = """
                        const v = [...document.querySelectorAll('video')].find(v => v.videoWidth > 1 && Number.isFinite(v.duration));
                        if (!v || v.mediaKeys) return null;
                        return {d:v.duration, token:v.getAttribute('data-soulo-media-id')};
                        """
                    guard let video = try? await web.callAsyncJavaScript(query, arguments: [:], in: frame, contentWorld: .page) as? [String: Any],
                          let seconds = video["d"] as? Double, seconds > 0 else { continue }
                    if let token = video["token"] as? String,
                       let current = await WebResourceInspectionService.currentVideoResource(webView: web, frame: frame, token: token),
                       current.delivery != .direct || detected.delivery == .direct {
                        activeResource = current
                        observedDuration = seconds
                        break
                    }
                    observedDuration = max(observedDuration ?? 0, seconds)
                }
                let resource = activeResource ?? detected
                let observedManifest = WebMediaManifestCache.snapshot(webView: web)[resource.url]
                if let observedManifest, observedManifest.contains("#EXT-X-ENDLIST") {
                    let duration = observedManifest.split(separator: "\n").compactMap { line -> Double? in
                        guard line.hasPrefix("#EXTINF:") else { return nil }
                        return Double(line.dropFirst(8).split(separator: ",").first ?? "")
                    }.reduce(0, +)
                    if duration > 0 { observedDuration = duration }
                }
                return (web, resource, observedDuration)
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        return nil
    }

    private func verifyDownloadedMovie(_ file: URL, expected: Double?) async throws -> String {
        var mp4 = file
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if file.pathExtension == OfflineHLSReference.fileExtension || file.pathExtension == "hls" {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            mp4 = try await OfflineVideoConversionService.exportMP4(from: file, into: temporary, preferredFilename: "Verify.mp4")
        }
        let asset = AVURLAsset(url: mp4)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(video.isEmpty)
        if let expected {
            XCTAssertEqual(duration, expected, accuracy: max(2, expected * 0.01), "Saved length must match the full source")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        for fraction in [0.05, 0.5, 0.95] {
            let frame = try await generator.image(at: CMTime(seconds: fraction * duration, preferredTimescale: 600))
            XCTAssertGreaterThan(frame.image.width, 0)
        }
        return "duration=\(duration)|expected=\(expected ?? 0)|video=\(video.count)|audio=\(audio.count)|format=\(file.pathExtension)"
    }

    func testPreviouslySavedHLSBundleExportsAndDecodes() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let name = environment["SOULO_QA_HLS_BUNDLE"], !name.contains("/"),
              let expected = environment["SOULO_QA_HLS_BUNDLE_DURATION"].flatMap(Double.init)
        else { throw XCTSkip("Supply a saved simulator HLS bundle") }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { if FileManager.default.fileExists(atPath: directory.path) { try? FileManager.default.removeItem(at: directory) } }
        let exported = try await OfflineVideoConversionService.exportMP4(from: bundle, into: directory)
        let details = try await verifyDownloadedMovie(exported, expected: expected)
        if let sample = environment["SOULO_QA_HLS_BUNDLE_SAMPLE"] {
            print("MOVIE_QA|\(sample)|saved|\(details)")
        }
    }

    func testCCTVDownloadUsesOnlyAnAdvertisedPublicRenditionForTheSameProgram() throws {
        let id = "0ecab3b5755e4d8f8499ce2cf793eed4"
        let page = try XCTUnwrap(URL(string: "https://tv.cctv.com/program.shtml"))
        let source = try XCTUnwrap(URL(string: "https://dh5wx.cntv.kfcbest.com/asp/h5e/hls/main/default/\(id)/main.m3u8"))
        let plain = "https://hls.cntv.lxdns.com/asp/hls/main/default/\(id)/main.m3u8"
        let request = try XCTUnwrap(CCTVDownloadSource.manifestRequest(for: source, page: page))
        XCTAssertEqual(request.absoluteString, "https://vdn.apps.cntv.cn/api/getHttpVideoInfo.do?pid=\(id)")
        XCTAssertNil(CCTVDownloadSource.manifestRequest(for: source, page: URL(string: "https://example.com")))
        XCTAssertNil(CCTVDownloadSource.manifestRequest(for: try XCTUnwrap(URL(string: plain)), page: page))

        func metadata(_ url: String, protected: String = "0", invalid: String = "0") throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "hls_url": url, "is_protected": protected, "is_invalid_copyright": invalid, "play": "1"
            ])
        }
        XCTAssertEqual(try CCTVDownloadSource.publicStream(in: metadata(plain), replacing: source).absoluteString, plain)
        let cdn = plain.replacingOccurrences(of: "hls.cntv.lxdns.com", with: "newcntv.qcloudcdn.com")
        XCTAssertEqual(try CCTVDownloadSource.publicStream(in: metadata(cdn), replacing: source).absoluteString, cdn)
        XCTAssertTrue(CCTVDownloadSource.isProgramPage(URL(string: "https://tv.cctv.com/2018/02/15/VIDE3Al7NaY4n6lp33BlmUT4180215.shtml")))
        XCTAssertFalse(CCTVDownloadSource.isProgramPage(URL(string: "https://cctv.com.example.org/2018/02/15/VIDE3Al7NaY4n6lp33BlmUT4180215.shtml")))
        XCTAssertThrowsError(try CCTVDownloadSource.publicStream(in: metadata(plain, protected: "1"), replacing: source))
        XCTAssertThrowsError(try CCTVDownloadSource.publicStream(in: metadata(plain, invalid: "1"), replacing: source))
        XCTAssertThrowsError(try CCTVDownloadSource.publicStream(
            in: metadata(plain.replacingOccurrences(of: id, with: String(repeating: "a", count: 32))), replacing: source))
        XCTAssertThrowsError(try CCTVDownloadSource.publicStream(
            in: metadata(plain.replacingOccurrences(of: "hls.cntv.lxdns.com", with: "example.com")), replacing: source))
    }

    func testLiveCCTVDownloadProducesDecodableFramesThroughoutTheProgram() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_CCTV_QA"] == "1", "Opt-in reported CCTV program")
        let documentary = ProcessInfo.processInfo.environment["SOULO_CCTV_DOCUMENTARY_QA"] == "1"
        let page = try XCTUnwrap(URL(string: documentary
            ? "https://tv.cctv.com/2018/02/15/VIDE3Al7NaY4n6lp33BlmUT4180215.shtml"
            : "https://tv.cctv.com/2025/02/23/VIDEf455H2PPYdxvc3Iy8tPC250223.shtml?spm=C31267.Ps4TvsHCiPx5.EFhA5EKLlcYD.35"))
        let source: URL
        if documentary {
            let id = "ed5103b5cfc941458eeff5657583c1d8"
            let request = try XCTUnwrap(CCTVDownloadSource.programRequest(id: id))
            let (metadata, response) = try await URLSession.shared.data(from: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            source = try CCTVDownloadSource.publicStream(in: metadata, programID: id)
        } else {
            source = try XCTUnwrap(URL(string: "https://dh5wx.cntv.kfcbest.com/asp/h5e/hls/main/0303000a/3/default/0ecab3b5755e4d8f8499ce2cf793eed4/main.m3u8"))
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        let video = WebMediaResource(kind: .video, url: source, title: "CCTV download QA", posterURL: nil, delivery: .hls)
        let file = try await WebResourceDownloadService.shared.download(video, preferredFilename: "CCTV download QA.mp4",
                                                                       pageURL: page, webView: web)
        let manager = DownloadManagerService.shared
        defer {
            if let item = manager.downloads.first(where: { $0.localURL == file }) { removeGeneratedDownload(item, manager: manager) }
        }
        XCTAssertEqual(file.pathExtension, "mp4")
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        if documentary { XCTAssertGreaterThan(duration, 260) }
        else { XCTAssertEqual(duration, 1619.16, accuracy: 1) }
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        for time in [5.0, duration / 2, duration - 5] {
            let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
            XCTAssertGreaterThan(frame.image.width, 0)
        }
        if documentary {
            print("MOVIE_QA|18.2|saved|duration=\(duration)|video=1|audio=\(audio.count)|format=\(file.pathExtension)")
        }
        let attachment = XCTAttachment(contentsOfFile: file)
        attachment.name = "CCTV download from the official public rendition"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCachedHLSFallbackSavesMP4FromLocalSegments() async throws {
        let library = try XCTUnwrap(FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
        let root = library.appendingPathComponent("CachedHLS-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Sample.movpkg")
        let rendition = package.appendingPathComponent("Data/rendition")
        try FileManager.default.createDirectory(at: rendition, withIntermediateDirectories: true)
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for index in 0..<4 {
            let input = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts",
                subdirectory: "ReadingFixtures/HLSFragments"))
            try FileManager.default.copyItem(at: input, to: rendition.appendingPathComponent("(\(index * 2))_(0)_(2.00001).frag"))
            playlist += "#EXTINF:2.000000,\n\(index).ts\n"
        }
        try (playlist + "#EXT-X-ENDLIST\n").write(to: rendition.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
        let reference = root.appendingPathComponent("Cached.soulohls")
        try OfflineHLSReference.write(packageURL: package, to: reference)
        let destination = root.appendingPathComponent("Video.mp4")
        try Data("system export failed".utf8).write(to: destination)
        try await StreamingMediaDownloadService.convertCachedHLS(reference: reference, to: destination)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertGreaterThan(duration.seconds, 7)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rendition.appendingPathComponent("(0)_(0)_(2.00001).frag").path))
    }

    func testHLSOfflineExportPreservesSectionsAcrossVideoFormatChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let first = environment["SOULO_QA_HLS_MIXED_FIRST"].flatMap({ Data(base64Encoded: $0) }),
              let second = environment["SOULO_QA_HLS_MIXED_SECOND"].flatMap({ Data(base64Encoded: $0) })
        else { throw XCTSkip("Supply the two H.264/AAC transport-stream fixtures") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("mixed.hls", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try first.write(to: bundle.appendingPathComponent("000000.ts"))
        try second.write(to: bundle.appendingPathComponent("000001.ts"))
        try """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:2
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXTINF:1.5,
        000000.ts
        #EXT-X-DISCONTINUITY
        #EXTINF:1.5,
        000001.ts
        #EXT-X-ENDLIST
        """.write(to: bundle.appendingPathComponent("index.m3u8"), atomically: true, encoding: .utf8)
        do {
            _ = try await OfflineVideoConversionService.exportMP4(from: bundle, into: root, allowTranscoding: false)
            XCTFail("Automatic download finalization must keep this format-changing HLS bundle")
        } catch {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["mixed.hls"])
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("000000.ts")), first)
            XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("000001.ts")), second)
        }
        let output = try await OfflineVideoConversionService.exportMP4(from: bundle, into: root)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(duration, 3, accuracy: 0.5)
        XCTAssertEqual(audio.count, 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        let lead = try await generator.image(at: CMTime(seconds: 0.3, preferredTimescale: 600)).image
        let tail = try await generator.image(at: CMTime(seconds: 2.6, preferredTimescale: 600)).image
        XCTAssertEqual(lead.height, 120)
        XCTAssertEqual(tail.height, 120)
        XCTAssertNotEqual(lead.dataProvider?.data as Data?, tail.dataProvider?.data as Data?)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("000000.ts")), first)
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent("000001.ts")), second)
    }

    func testYouTubeDownloadSavesBothTracksAndReportsAnInterruptedPausedTransfer() async throws {
        let controller = WKUserContentController()
        controller.addScriptMessageHandler(StreamingMediaDownloadService.shared, contentWorld: .page,
                                           name: StreamingMediaDownloadService.messageHandlerName)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let web = AccessibleWebView(frame: .zero, configuration: configuration)
        let model = WebViewModel()
        model.webView = web
        let page = try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=\(UUID().uuidString)"))
        let resultsPage = try XCTUnwrap(URL(string: "https://m.youtube.com/results?search_query=nature"))
        let mediaURL = try XCTUnwrap(URL(string: "https://fixture.googlevideo.com/videoplayback?itag=18"))
        let resource = WebMediaResource(kind: .video, url: mediaURL, title: "SABR QA", posterURL: nil, delivery: .youtubeSABR)
        let identity = WebResourceMediaService.downloadIdentityURL(for: resource, pageURL: page)
        try await installYouTubeDownloadFixture(in: web, page: page)
        let manager = DownloadManagerService.shared
        let disconnected = "Fixture transport disconnected"
        let verificationRequired = "Cannot proceed with stream: attestation required"
        let cases: [(failure: String?, inlineSearchPreview: Bool)] = [
            (nil, false), (nil, true), (disconnected, false), (verificationRequired, false)
        ]
        for (failure, inlineSearchPreview) in cases {
            _ = try await web.callAsyncJavaScript("history.replaceState(null, '', path);",
                arguments: ["path": inlineSearchPreview ? resultsPage.absoluteString : page.absoluteString],
                in: nil, contentWorld: .page)
            let selectedResource: WebMediaResource
            if inlineSearchPreview {
                let snapshot = try await WebResourceInspectionService.inspect(webView: web)
                selectedResource = try XCTUnwrap(snapshot.videos.first(where: { $0.delivery == .youtubeSABR }))
                XCTAssertEqual(selectedResource.url, page)
            } else {
                selectedResource = resource
            }
            _ = try await web.callAsyncJavaScript("""
                window.finishFixture = null;
                window.fixtureFailure = failure;
                window.verificationRequired = verificationRequired;
                """, arguments: ["failure": (failure as Any?) ?? NSNull(),
                                  "verificationRequired": failure == verificationRequired],
                in: nil, contentWorld: .page)
            let task = Task {
                // The frame's request can still contain the search URL after selecting a result.
                try await WebResourceDownloadService.shared.download(selectedResource, pageURL: resultsPage, webView: web)
            }
            defer { task.cancel() }
            try await waitFor("The transfer did not receive media") { (manager.activeDownload(for: identity)?.receivedBytes ?? 0) > 0 }
            let item = try XCTUnwrap(manager.activeDownload(for: identity))
            defer { if let current = manager.downloads.first(where: { $0.id == item.id }) { removeGeneratedDownload(current, manager: manager) } }
            XCTAssertTrue(model.hasActivePageDownload)
            model.currentURL = page
            model.invalidateExtensionRuntime()
            model.refreshExtensionRuntimeIfNeeded()
            XCTAssertTrue(model.webView === web, "A settings refresh must retain an active playback transfer")
            for _ in 0..<80 {
                if (try? await web.evaluateJavaScript("typeof window.finishFixture === 'function'")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            if failure == disconnected { StreamingMediaDownloadService.shared.pause(itemID: item.id) }
            _ = try await web.evaluateJavaScript("window.finishFixture(); true")
            if let failure {
                do {
                    _ = try await task.value
                    XCTFail("An interrupted transfer must not publish a file")
                } catch {
                    let failed = try XCTUnwrap(manager.downloads.first(where: { $0.id == item.id }))
                    XCTAssertEqual(failed.status, .failed)
                    if failure == verificationRequired {
                        guard let downloadError = error as? StreamingMediaDownloadError,
                              case .youtubeVerificationRequired = downloadError else {
                            XCTFail("Expected YouTube verification error, got \(error)")
                            continue
                        }
                        XCTAssertEqual(failed.errorMessage, error.localizedDescription)
                        XCTAssertLessThan(failed.receivedBytes, failed.expectedBytes)
                        XCTAssertLessThan(failed.progress, 1)
                    } else {
                        XCTAssertTrue(failed.errorMessage.contains(failure))
                    }
                    XCTAssertFalse(FileManager.default.fileExists(atPath: failed.localPath))
                }
            } else {
                let output = try await task.value
                let asset = AVURLAsset(url: output)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                let video = try await asset.loadTracks(withMediaType: .video)
                XCTAssertEqual(audio.count, 1)
                XCTAssertEqual(video.count, 1)
                XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
            }
            XCTAssertFalse(model.hasActivePageDownload)
        }
    }

    private func installYouTubeDownloadFixture(in web: WKWebView, page: URL) async throws {
        web.loadHTMLString("<title>Streaming fixture</title>", baseURL: page)
        try await waitFor("Fixture page did not load") { web.url == page && !web.isLoading }
        func encodedFixture(_ name: String, _ ext: String) throws -> String {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                subdirectory: "ReadingFixtures/ExtensionMedia"))
            return try Data(contentsOf: url).base64EncodedString()
        }
        _ = try await web.callAsyncJavaScript(#"""
            window.ytInitialPlayerResponse = {
                videoDetails: {videoId: new URL(location.href).searchParams.get('v')},
                streamingData: {serverAbrStreamingUrl: 'https://fixture.googlevideo.com/?sabr=1', adaptiveFormats: [{}]}
            };
            window.__souloSABREngineVersion = 2;
            window.__souloSABRDownload = async ({downloadID}) => {
                const post = (type, payload) => window.webkit.messageHandlers.souloSABRDownload.postMessage({type, downloadID, ...payload});
                await post('started', {videoExpectedBytes: atob(video).length, audioExpectedBytes: atob(audio).length});
                const receivedVideo = window.verificationRequired ? btoa(atob(video).slice(0, -1024)) : video;
                await post('chunk', {track: 'video', index: 0, base64: receivedVideo});
                await post('chunk', {track: 'audio', index: 0, base64: audio});
                await new Promise(resolve => { window.finishFixture = resolve; });
                if (window.fixtureFailure) throw new Error(window.fixtureFailure);
                return {durationSeconds: window.fixtureDuration ?? 2};
            };
            """#, arguments: ["video": try encodedFixture("video", "mp4"), "audio": try encodedFixture("audio", "m4a")],
            in: nil, contentWorld: .page)
    }

    func testConcurrentYouTubeTransfersKeepPauseFilesAndPlaybackSourcesIndependent() async throws {
        struct Source {
            let web: AccessibleWebView
            let page: URL
            let resource: WebMediaResource
            let identity: URL
        }
        let manager = DownloadManagerService.shared
        let service = StreamingMediaDownloadService.shared
        let title = "Concurrent fixture \(UUID().uuidString)"
        var sources: [Source] = []
        for _ in 0..<2 {
            let page = try XCTUnwrap(URL(string: "https://m.youtube.com/watch?v=\(UUID().uuidString)"))
            let resource = WebMediaResource(kind: .video, url: page, title: title, posterURL: nil, delivery: .youtubeSABR)
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addScriptMessageHandler(service, contentWorld: .page,
                name: StreamingMediaDownloadService.messageHandlerName)
            let web = AccessibleWebView(frame: .zero, configuration: configuration)
            let identity = WebResourceMediaService.downloadIdentityURL(for: resource, pageURL: page)
            try await installYouTubeDownloadFixture(in: web, page: page)
            sources.append(Source(web: web, page: page, resource: resource, identity: identity))
        }

        let tasks = sources.map { source in Task {
            try await WebResourceDownloadService.shared.download(source.resource,
                preferredFilename: title + ".mp4", pageURL: source.page, webView: source.web)
        } }
        defer {
            tasks.forEach { $0.cancel() }
            for item in manager.downloads where sources.contains(where: { $0.identity.absoluteString == item.sourceURLString }) {
                if [.inProgress, .paused].contains(item.status) { service.cancel(itemID: item.id) }
                removeGeneratedDownload(item, manager: manager)
            }
        }
        try await waitFor("Both tabs must receive media") {
            sources.allSatisfy { (manager.activeDownload(for: $0.identity)?.receivedBytes ?? 0) > 0 }
        }
        let items = try sources.map { try XCTUnwrap(manager.activeDownload(for: $0.identity)) }
        XCTAssertNotEqual(items[0].localURL, items[1].localURL)
        service.pause(itemID: items[0].id)
        for _ in 0..<80 {
            if (try? await sources[1].web.evaluateJavaScript("typeof window.finishFixture === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await sources[1].web.evaluateJavaScript("window.fixtureDuration = 1; window.finishFixture(); true")
        let second = try await tasks[1].value
        XCTAssertTrue(sources[0].web.activePageDownloadIDs.contains(items[0].id))
        XCTAssertTrue(sources[1].web.activePageDownloadIDs.isEmpty)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == items[0].id })?.status, .paused)
        service.resume(itemID: items[0].id)
        for _ in 0..<80 {
            if (try? await sources[0].web.evaluateJavaScript("typeof window.finishFixture === 'function'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = try await sources[0].web.evaluateJavaScript("window.finishFixture(); true")
        let first = try await tasks[0].value
        for (file, duration) in [(first, 2.0), (second, 1.0)] {
            let asset = AVURLAsset(url: file)
            let actual = try await asset.load(.duration).seconds
            XCTAssertEqual(actual, duration, accuracy: 0.15)
            let audio = try await asset.loadTracks(withMediaType: .audio)
            let video = try await asset.loadTracks(withMediaType: .video)
            XCTAssertEqual(audio.count, 1)
            XCTAssertEqual(video.count, 1)
        }
    }

    func testLiveConcurrentYouTubeDownloads() async throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["SOULO_CONCURRENT_YOUTUBE_QA"] == "1",
                          "Opt-in YouTube downloads using the simulator's browser session")
        let searchTerm = environment["SOULO_QA_YOUTUBE_SEARCH_TERM"]
        let startsAtHome = environment["SOULO_QA_YOUTUBE_HOME"] == "1"
        let requestedIDs = environment["SOULO_QA_YOUTUBE_IDS"]?.split(separator: ",").map(String.init)
        var videoIDs = requestedIDs ?? (startsAtHome ? ["", ""]
            : searchTerm == nil ? ["jNQXAC9IVRw", "BaW_jenozKc", "dQw4w9WgXcQ"] : [""])
        var pages = videoIDs.compactMap { URL(string: "https://m.youtube.com/watch?v=\($0)") }
        let entryPage: URL?
        if startsAtHome {
            entryPage = URL(string: "https://m.youtube.com/")
        } else if let searchTerm {
            var address = URLComponents(string: "https://m.youtube.com/results")!
            address.queryItems = [.init(name: "search_query", value: searchTerm), .init(name: "ra", value: "m")]
            entryPage = address.url
        } else { entryPage = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        let manager = DownloadManagerService.shared
        let preexisting = Set(manager.downloads.map(\.id))
        let webViews = pages.map { page in
            let config = WKWebViewConfiguration()
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            config.userContentController.addUserScript(WKUserScript(source: WebViewScripts.mediaResourceTracking,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
            config.userContentController.addScriptMessageHandler(StreamingMediaDownloadService.shared, contentWorld: .page,
                name: StreamingMediaDownloadService.messageHandlerName)
            let web = AccessibleWebView(frame: host.view.bounds, configuration: config)
            web.customUserAgent = AppConstants.mobileWebViewUserAgent
            host.view.addSubview(web)
            web.load(URLRequest(url: entryPage ?? page))
            return web
        }
        if let entryPage {
            let followVideoLink = #"""
                const candidates = [...document.querySelectorAll('a[href*="/watch?"]')].filter(link => {
                    const linkID = new URL(link.href).searchParams.get('v');
                    const title = (link.closest('ytm-compact-video-renderer, ytm-video-with-context-renderer, ytm-lockup-view-model')
                        ?.innerText || link.innerText || link.getAttribute('aria-label') || '').trim();
                    return linkID && (!videoID || linkID === videoID) && (!titleContains || title.includes(titleContains))
                        && !seenIDs.includes(linkID)
                        && link.getBoundingClientRect().width > 0;
                });
                function duration(link) {
                    const card = link.closest('ytm-compact-video-renderer, ytm-video-with-context-renderer, ytm-lockup-view-model');
                    const time = card?.querySelector('ytm-thumbnail-overlay-time-status-renderer, .badge-shape-wiz__text')?.textContent?.trim() || '';
                    return /^\d{1,2}(:\d{2}){1,2}$/.test(time)
                        ? time.split(':').reduce((seconds, field) => seconds * 60 + Number(field), 0)
                        : Number.MAX_SAFE_INTEGER;
                }
                if (preferShort && !videoID) candidates.sort((lhs, rhs) => duration(lhs) - duration(rhs));
                const match = candidates[0];
                if (!match) return null;
                setTimeout(() => match.click(), 50);
                return match.href;
                """#
            for index in webViews.indices {
                let web = webViews[index]
                let deadline = ContinuousClock.now + .seconds(35)
                var resultURL: URL?
                while resultURL == nil, .now < deadline {
                    if web.url?.path == entryPage.path {
                        let result = try? await web.callAsyncJavaScript(followVideoLink, arguments: [
                            "videoID": videoIDs[index], "titleContains": environment["SOULO_QA_YOUTUBE_TITLE_CONTAINS"] ?? "",
                            "seenIDs": Array(videoIDs.prefix(index)), "preferShort": startsAtHome
                        ],
                            in: nil, contentWorld: .page)
                        if let result = result as? String { resultURL = URL(string: result) }
                    }
                    if resultURL == nil { try await Task.sleep(for: .milliseconds(300)) }
                }
                let selected = try XCTUnwrap(resultURL, "The entry page did not offer the requested video")
                videoIDs[index] = try XCTUnwrap(WebResourceMediaService.youtubeVideoID(for: selected))
                pages[index] = selected
                print("YOUTUBE_QA|\(videoIDs[index])|\(startsAtHome ? "home" : "search-result")")
            }
        }

        var resources: [Int: WebMediaResource] = [:]
        for _ in 0..<75 {
            for index in webViews.indices where resources[index] == nil
                && webViews[index].url.flatMap(WebResourceMediaService.youtubeVideoID(for:)) == videoIDs[index] {
                guard let snapshot = try? await WebResourceInspectionService.inspect(webView: webViews[index]),
                      let resource = snapshot.videos.first(where: { $0.delivery == .youtubeSABR })
                        ?? snapshot.videos.first(where: { $0.delivery != .dash }) else { continue }
                resources[index] = resource
            }
            if resources.count == pages.count { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        var unavailableCount = 0
        var expectedDurations: [Int: Double] = [:]
        for index in webViews.indices {
            let details = try? await webViews[index].callAsyncJavaScript(#"""
                const player = document.getElementById('movie_player')?.getPlayerResponse?.() || window.ytInitialPlayerResponse;
                return JSON.stringify({status:player?.playabilityStatus?.status || 'unknown',
                    ready:document.querySelector('video')?.readyState ?? -1,
                    duration:Number(player?.videoDetails?.lengthSeconds)
                        || document.querySelector('video')?.duration || 0,
                    direct:player?.streamingData?.formats?.length ?? 0,
                    adaptive:player?.streamingData?.adaptiveFormats?.length ?? 0,
                    sabr:!!player?.streamingData?.serverAbrStreamingUrl,
                    hls:!!player?.streamingData?.hlsManifestUrl})
                """#, arguments: [:], in: nil, contentWorld: .page)
            let description = details as? String ?? ""
            let player = (try? JSONSerialization.jsonObject(with: Data(description.utf8))) as? [String: Any]
            let status = player?["status"] as? String ?? "unknown"
            if let duration = player?["duration"] as? Double, duration.isFinite, duration > 0 {
                expectedDurations[index] = duration
            }
            if ["ERROR", "UNPLAYABLE", "LOGIN_REQUIRED", "AGE_CHECK_REQUIRED", "LIVE_STREAM_OFFLINE"].contains(status),
               (player?["ready"] as? Int ?? 0) == 0, player?["sabr"] as? Bool == false {
                XCTAssertNil(resources[index], "A rejected player must not appear as a download")
                resources[index] = nil
                unavailableCount += 1
            }
            print("CONCURRENT_YT_PAGE \(videoIDs[index]) delivery=\(resources[index]?.delivery.rawValue ?? "none") \(description)")
        }
        XCTAssertEqual(resources.count + unavailableCount, pages.count, "Expected a resource for each playable video")

        var pending = Set(resources.keys)
        var jobs: Set<UUID> = []
        var saved: [Int: URL] = [:]
        let tasks = resources.keys.sorted().compactMap { index -> Task<Void, Never>? in
            guard let resource = resources[index] else { return nil }
            return Task { @MainActor in
                defer { pending.remove(index) }
                do {
                    let file = try await WebResourceDownloadService.shared.download(resource,
                        preferredFilename: "YouTube concurrent QA \(videoIDs[index]).mp4",
                        pageURL: entryPage ?? pages[index], webView: webViews[index])
                    let item = try XCTUnwrap(manager.downloads.first { $0.localURL == file })
                    XCTAssertEqual(item.status, .finished)
                    let asset = AVURLAsset(url: file)
                    let duration = try await asset.load(.duration).seconds
                    let video = try await asset.loadTracks(withMediaType: .video)
                    let audio = try await asset.loadTracks(withMediaType: .audio)
                    XCTAssertEqual(video.count, 1)
                    XCTAssertEqual(audio.count, 1)
                    XCTAssertGreaterThan(duration, 0)
                    let generator = AVAssetImageGenerator(asset: asset)
                    for fraction in [0.05, 0.5, 0.95] {
                        let frame = try await generator.image(at: CMTime(seconds: fraction * duration, preferredTimescale: 600))
                        XCTAssertGreaterThan(frame.image.width, 0)
                    }
                    print("CONCURRENT_YT_SAVED \(videoIDs[index]) duration=\(duration) video=\(video.count) audio=\(audio.count)")
                    saved[index] = file
                } catch {
                    print("CONCURRENT_YT_FAILED \(videoIDs[index]) \(error.localizedDescription)")
                    XCTFail("\(videoIDs[index]) failed: \(error)")
                }
            }
        }
        defer {
            for task in tasks { task.cancel() }
            for item in manager.downloads where !preexisting.contains(item.id) && item.fileName.hasPrefix("YouTube concurrent QA") {
                if [.inProgress, .paused].contains(item.status) { StreamingMediaDownloadService.shared.cancel(itemID: item.id) }
                removeGeneratedDownload(item, manager: manager)
            }
        }
        var maximumActive = 0
        var checkedPause = false
        let deadline = ContinuousClock.now + .seconds(235)
        while !pending.isEmpty, .now < deadline {
            let active = manager.downloads.filter {
                !preexisting.contains($0.id) && $0.fileName.hasPrefix("YouTube concurrent QA") && $0.status == .inProgress
            }
            jobs.formUnion(active.map(\.id))
            maximumActive = max(maximumActive, active.count)
            if !checkedPause, active.count >= 2, let first = active.first {
                checkedPause = true
                StreamingMediaDownloadService.shared.pause(itemID: first.id)
                XCTAssertEqual(manager.downloads.first(where: { $0.id == first.id })?.status, .paused)
                webViews.forEach { $0.removeFromSuperview() }
                try await Task.sleep(for: .seconds(1))
                StreamingMediaDownloadService.shared.resume(itemID: first.id)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        print("CONCURRENT_YT_ACTIVE peak=\(maximumActive) started=\(jobs.count) paused=\(checkedPause)")
        if videoIDs.count > 1 {
            XCTAssertGreaterThanOrEqual(maximumActive, 2)
            XCTAssertTrue(checkedPause)
        }
        XCTAssertFalse(saved.isEmpty)
        XCTAssertTrue(pending.isEmpty, "Concurrent downloads did not finish within the test window")
        if pending.isEmpty { for task in tasks { await task.value } }
        if environment["SOULO_QA_OFFLINE_PLAYBACK"] == "1" {
            webViews.forEach { $0.stopLoading(); $0.removeFromSuperview() }
            for (index, file) in saved.sorted(by: { $0.key < $1.key }) {
                let playback = try await verifyOfflinePlayback(file, expected: expectedDurations[index], in: host.view)
                print("YOUTUBE_QA|\(videoIDs[index])|played-offline|\(playback)")
            }
        }
    }

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
        let manager = DownloadManagerService.shared
        let filename = "MP4ExportLegacyUIQA-\(UUID().uuidString.prefix(6)).\(OfflineHLSReference.fileExtension)"
        let (item, reference) = manager.beginDownload(suggestedFilename: filename, sourceURL: nil, transport: .hls)
        do {
            // New downloads may already be MP4. Exercise the export menu with a legacy offline package.
            try writeConversionReference(fixture, at: reference)
            manager.markFinished(id: item.id)
        } catch {
            manager.delete(item)
            try? FileManager.default.removeItem(at: fixture.root)
            throw error
        }
        XCTAssertEqual(manager.downloads.first { $0.localURL == reference }?.status, .finished)
        // The UI runner launches a separate app process immediately after this test exits.
        XCTAssertTrue(UserDefaults.standard.synchronize())
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
        XCTAssertEqual(restored.downloads.first(where: { $0.id == original.id }), original)
        XCTAssertEqual(try Data(contentsOf: reference), bytes)
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
        try await checkAuthenticatedFragmentedHLS(export: false)
    }

    func testAuthenticatedFMP4ByteRangesAndSeparateAudioExportOffline() async throws {
        try await checkAuthenticatedFragmentedHLS(export: true)
    }

    private func checkAuthenticatedFragmentedHLS(export: Bool) async throws {
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
        var completion: BrowserDownloadItem?
        let finished = manager.didFinishDownload.sink { item in
            if item.sourceURLString == resource.url.absoluteString { completion = item }
        }
        defer { finished.cancel() }
        defer { if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) { removeGeneratedDownload(item, manager: manager) } }
        let file = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource, preferredFilename: "Private fMP4.mp4", pageURL: nil, webView: web)
        XCTAssertEqual(file.pathExtension, "hls")
        let saved = try XCTUnwrap(manager.finishedDownload(for: resource.url))
        XCTAssertEqual(saved.localURL.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertEqual(completion?.localURL.standardizedFileURL.path, file.standardizedFileURL.path)
        XCTAssertEqual(completion?.progress, 1)
        XCTAssertFalse(manager.finalizingHLSDownloadIDs.contains(saved.id))
        let requests = server.receivedRequests
        XCTAssertEqual(requests.filter { $0.headers["range"] != nil }.count, 7)
        XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"]?.contains("fmp4Download=allowed") == true && $0.headers["user-agent"] == web.customUserAgent })
        server.stop()
        if export {
            let original = try packageSnapshot(file)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FMP4-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let exported = try await OfflineVideoConversionService.exportMP4(from: file, into: directory)
            let converted = AVURLAsset(url: exported)
            let convertedVideo = try await converted.loadTracks(withMediaType: .video)
            let convertedAudio = try await converted.loadTracks(withMediaType: .audio)
            XCTAssertEqual(convertedVideo.count, 1)
            XCTAssertEqual(convertedAudio.count, 1)
            let convertedDuration = try await converted.load(.duration)
            XCTAssertEqual(convertedDuration.seconds, 8.0, accuracy: 0.2)
            let last = try await AVAssetImageGenerator(asset: converted).image(at: CMTime(seconds: 7.5, preferredTimescale: 600))
            XCTAssertGreaterThan(last.image.width, 0)
            XCTAssertEqual(try packageSnapshot(file), original)
            return
        }
        let localSource = DownloadPlaybackSource(asset: AVURLAsset(url: try LocalHLSMedia.playlistURL(for: file)), pageURL: nil, webView: nil)
        let prepared = try await SouloMediaPlaybackSource.prepare(native: localSource, originalURL: file)
        async let concurrentAsset = prepared.systemAsset()
        let asset = try await prepared.systemAsset()
        let otherAsset = try await concurrentAsset
        XCTAssertEqual(asset.url, otherAsset.url, "Concurrent consumers must keep the same offline HLS listener")
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

    func testAuthenticatedHLSHonorsOriginRetryAfterForManifestAndSegments() async throws {
        var manifest = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        var files: [String: Data] = [:]
        for index in 0..<4 {
            let name = "segment\(index)"
            let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name,
                withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/\(name).ts"] = try Data(contentsOf: source)
            manifest += "#EXTINF:2,\n\(name).ts\n"
        }
        files["/index.m3u8"] = Data((manifest + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files,
            initialRateLimits: ["/index.m3u8": 2, "/segment0.ts": 2])
        let origin = try await server.start()
        defer { server.stop() }
        let resource = WebMediaResource(kind: .video, url: origin.appendingPathComponent("index.m3u8"),
            title: "HLS Retry-After", posterURL: nil, delivery: .hls)
        let manager = DownloadManagerService.shared
        defer {
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
        }
        let web = WKWebView(frame: .zero)
        let file = try await AuthenticatedHLSDownloadService.shared.download(resource: resource,
            preferredName: "HLS Retry-After.mp4", pageURL: nil, webView: web)
        XCTAssertEqual(manager.downloads.first(where: { $0.localURL == file })?.status, .finished)
        for path in ["/index.m3u8", "/segment0.ts"] {
            let attempts = server.receivedRequests.filter { $0.path == path }
            XCTAssertEqual(attempts.count, 2)
            let first = try XCTUnwrap(attempts.first)
            let last = try XCTUnwrap(attempts.last)
            XCTAssertGreaterThanOrEqual(first.receivedAt.duration(to: last.receivedAt), .seconds(2))
        }
        let segments = server.receivedRequests.filter { $0.path.hasSuffix(".ts") }
        for (first, second) in zip(segments, segments.dropFirst()) {
            XCTAssertGreaterThanOrEqual(first.receivedAt.duration(to: second.receivedAt), .milliseconds(850))
        }
    }

    func testHLSDownloadChoosesBestVariantWithMatchingProgramLength() async throws {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=200000
        default.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        matching.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=8000000
        unrelated.m3u8
        """
        var files = ["/master.m3u8": Data(master.utf8)]
        for (variant, count) in [("default", 4), ("matching", 4), ("unrelated", 1)] {
            var media = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            for index in 0..<count {
                let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)",
                    withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
                let filename = "\(variant)-\(index).ts"
                files["/\(filename)"] = try Data(contentsOf: source)
                media += "#EXTINF:2,\n\(filename)\n"
            }
            files["/\(variant).m3u8"] = Data((media + "#EXT-X-ENDLIST\n").utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let origin = try await server.start()
        defer { server.stop() }
        let url = origin.appendingPathComponent("master.m3u8")
        let resource = WebMediaResource(kind: .video, url: url, title: "HLS variant length", posterURL: nil, delivery: .hls)
        let manager = DownloadManagerService.shared
        defer {
            if let item = manager.downloads.first(where: { $0.sourceURLString == url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
        }
        let web = WKWebView(frame: .zero)
        WebMediaManifestCache.remember([url.absoluteString: master], webView: web)
        let file = try await StreamingMediaDownloadService.shared.downloadHLS(resource: resource,
            preferredFilename: "HLS variant length.mp4", pageURL: nil, webView: web)
        XCTAssertEqual(manager.downloads.first(where: { $0.localURL == file })?.status, .finished)
        let segments = server.receivedRequests.map(\.path).filter { $0.hasSuffix(".ts") }
        XCTAssertEqual(Set(segments), Set((0..<4).map { "/matching-\($0).ts" }))
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
        XCTAssertTrue(manager.finalizingHLSDownloadIDs.contains(item.id))
        XCTAssertEqual(item.localURL.pathExtension, "mp4", "Publish the offline reference after its key is available")
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
            let unpublishedReference = item.localURL.deletingPathExtension().appendingPathExtension(OfflineHLSReference.fileExtension)
            XCTAssertFalse(FileManager.default.fileExists(atPath: unpublishedReference.path))
        } else {
            server.releaseDownloads()
            let file = try await download.value
            if file.pathExtension == OfflineHLSReference.fileExtension {
                XCTAssertNotNil(try OfflineHLSReference.encryptionMaterial(for: file))
            } else {
                XCTAssertEqual(file.pathExtension, "mp4")
                let asset = AVURLAsset(url: file)
                let audio = try await asset.loadTracks(withMediaType: .audio)
                XCTAssertFalse(audio.isEmpty)
                let frame = try await AVAssetImageGenerator(asset: asset).image(at: .zero)
                XCTAssertGreaterThan(frame.image.width, 0)
            }
            XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        }
        try await waitFor("HLS finalization did not release its background completion") { completions == 1 }
        XCTAssertFalse(service.hasPendingHLSFinalization)
        XCTAssertFalse(manager.finalizingHLSDownloadIDs.contains(item.id))
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

    func testMP4WithInconsistentRangeValidatorsRetriesAsOneBackgroundDownload() async throws {
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "torrent-stream-h264-aac",
            withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: clip)
        let path = "/inconsistent-ranges.mp4"
        let lastModified = "Wed, 25 Nov 2026 04:33:34 GMT"
        let server = try DownloadPlaybackHTTPFixture(files: [path: bytes],
            responseHeaders: [path: ["Last-Modified": lastModified]],
            rangeResponseHeaders: { offset in offset == 0 ? [:] : ["Last-Modified": "Wed, 25 Nov 2026 10:20:33 GMT"] })
        let url = try await server.start().appendingPathComponent("inconsistent-ranges.mp4")
        server.releaseDownloads()
        let manager = DownloadManagerService.shared
        defer {
            server.stop()
            if let item = manager.downloads.first(where: { $0.sourceURLString == url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
        }

        let resource = WebMediaResource(kind: .video, url: url, title: "Inconsistent ranges", posterURL: nil)
        let file = try await WebResourceDownloadService.shared.download(resource, webView: nil)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let items = manager.downloads.filter { $0.sourceURLString == url.absoluteString }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.status, .finished)
        let requests = server.receivedRequests.filter { $0.path == path && $0.method == "GET" }
        XCTAssertTrue(requests.contains { $0.headers["range"]?.hasPrefix("bytes=0-") == true })
        XCTAssertTrue(requests.contains { $0.headers["range"] != nil && $0.headers["range"]?.hasPrefix("bytes=0-") == false })
        let whole = requests.filter { $0.headers["range"] == nil }
        XCTAssertEqual(whole.count, 1)
        XCTAssertNil(whole.first?.headers["if-range"])
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
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        await VideoOrientation.waitForRestoration(in: scene)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let oldRate = session.rate; session.setRate(1)
        let download = Task { try await WebResourceDownloadService.shared.download(resource, webView: web) }
        defer {
            session.stop(); session.setRate(oldRate)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            if let item = manager.downloads.first(where: { $0.sourceURLString == resource.url.absoluteString }) {
                removeGeneratedDownload(item, manager: manager)
            }
            download.cancel()
        }
        try await waitFor("Video download did not publish its playback source") {
            guard let item = manager.activeDownload(for: resource.url) else { return false }
            return manager.playbackSource(for: item.id) != nil && item.receivedBytes > 0
        }
        let item = try XCTUnwrap(manager.activeDownload(for: resource.url))
        let pendingSource = try XCTUnwrap(manager.playbackSource(for: item.id))
        let source = await pendingSource.preparedForPlayback()
        XCTAssertNotEqual(source.asset.url, resource.url, "Playback must use scoped range requests")
        let received = server.downloadedBytes
        session.open(url: source.asset.url, asset: source.asset, webView: source.webView,
            persistPosition: source.persistsPosition, downloadSource: source)
        // Use the same automatic decoder as the download list's fullscreen preview.
        window.rootViewController = UIHostingController(rootView: FullscreenMediaPlaybackContent())
        window.makeKeyAndVisible()
        try await waitFor("The fullscreen player did not decode video during the download") {
            guard let decoder = session.soulo?.player else { return false }
            return decoder.currentTime > 0.6 && decoder.decodedFrameCount > 1
        }
        let playback = try XCTUnwrap(session.soulo)
        XCTAssertNil(playback.error)
        XCTAssertTrue(playback.hasVideo)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertGreaterThan(server.rangeRequests, 0)
        try await waitFor("Opening the player stopped the file transfer") { server.downloadedBytes > received }
        let before = playback.elapsed
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertEqual(try Data(contentsOf: result), bytes)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        XCTAssertNil(manager.playbackSource(for: item.id))
        try await waitFor("Finishing the download stopped playback") { playback.elapsed > before + 0.3 }
        XCTAssertNil(playback.error)
    }

    func testHLSPlaybackCompletesWithIndependentDownloadAsset() async throws {
        try await checkConcurrentHLS(authenticated: false)
    }

    func testNativeBackgroundHLSPlaysFromDownloadedSegmentsAndCompletes() async throws {
        try await checkConcurrentHLS(authenticated: false, userAgent: AppConstants.mobileWebViewUserAgent)
    }

    func testLivePBKanStartsPlaybackDuringDownload() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_PBKAN_PLAYBACK_QA"] == "1", "Opt-in reported HLS stream")
        let page = try XCTUnwrap(URL(string: "https://www.pbkan.com/yun/241110-3-14.html"))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.customUserAgent = AppConstants.mobileWebViewUserAgent
        web.load(URLRequest(url: page))
        var stream: URL?
        for _ in 0..<100 {
            if let raw = try? await web.evaluateJavaScript("window.player_data?.url ?? ''") as? String,
               raw.hasPrefix("https://"), let url = URL(string: raw), url.pathExtension == "m3u8" {
                stream = url
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let origin = try XCTUnwrap(stream)
        var address = try XCTUnwrap(URLComponents(url: origin, resolvingAgainstBaseURL: false))
        let isolatedID = UUID().uuidString
        // The example's public master accepts a query without changing its
        // relative media playlist. Keep this job apart from restored real tasks.
        if address.host == "play.dyttzyv.com", address.query == nil {
            address.queryItems = [.init(name: "soulo_qa", value: isolatedID)]
        }
        let url = try XCTUnwrap(address.url)
        let name = "PBKan HLS QA \(isolatedID)"
        let resource = WebMediaResource(kind: .video, url: url, title: name, posterURL: nil,
                                        delivery: .hls, sourcePageURL: page)
        let manager = DownloadManagerService.shared
        let session = MediaSession.shared
        let download = Task {
            do { return try await WebResourceDownloadService.shared.download(resource,
                preferredFilename: name + ".mp4", pageURL: page, webView: web) }
            catch {
                let failure = error as NSError
                print("PBKAN_QA_DOWNLOAD_ERROR \(failure.domain) \(failure.code)")
                throw error
            }
        }
        defer {
            session.stop()
            download.cancel()
            if let item = manager.downloads.first(where: { $0.sourceURLString == url.absoluteString && $0.fileName.hasPrefix(name) }) {
                if [.inProgress, .paused].contains(item.status) { StreamingMediaDownloadService.shared.cancel(itemID: item.id) }
                removeGeneratedDownload(item, manager: manager)
            }
        }
        for _ in 0..<280 {
            if let item = manager.downloads.first(where: { $0.sourceURLString == url.absoluteString && $0.fileName.hasPrefix(name) }) {
                if item.status == .failed { throw URLError(.cannotLoadFromNetwork) }
                if item.receivedBytes > 512 * 1024, item.progress > 0, manager.playbackSource(for: item.id) != nil { break }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        let item = try XCTUnwrap(manager.activeDownload(for: url))
        XCTAssertTrue(item.fileName.hasPrefix(name))
        let source = try XCTUnwrap(manager.playbackSource(for: item.id))
        XCTAssertGreaterThan(item.receivedBytes, 512 * 1024)
        XCTAssertGreaterThan(item.progress, 0)
        let shared = source.asset === source.downloadAsset
        print("PBKAN_QA_OPEN progress=\(item.progress) bytes=\(item.receivedBytes) shared=\(shared)")
        XCTAssertTrue(shared, "The playback should use the in-progress native download asset")
        let started = ContinuousClock.now
        let prepared = await source.preparedForPlayback()
        session.open(url: prepared.asset.url, asset: prepared.asset, persistPosition: false, downloadSource: prepared)
        try await waitFor("The reported stream did not play from its downloaded beginning") {
            session.player.currentTime().seconds > 0.6
        }
        print("PBKAN_QA_PLAY elapsed=\(started.duration(to: .now)) playhead=\(session.player.currentTime().seconds)")
        XCTAssertNil(session.error)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
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
        do {
            try await waitFor("Video must play before the origin holds its last segment") {
                host.presentedViewController != nil && position() > 3
            }
        } catch {
            let item = session.player.currentItem
            let buffered = item?.loadedTimeRanges.map { $0.timeRangeValue.duration.seconds } ?? []
            print("HLS fullscreen startup: system=\(usesSystem) presented=\(host.presentedViewController != nil) position=\(position()) rate=\(session.player.rate) waiting=\(String(describing: session.player.reasonForWaitingToPlay)) buffered=\(buffered) requests=\(server.receivedRequests.map(\.path))")
            throw error
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
        if FileManager.default.fileExists(atPath: item.localPath) {
            try? FileManager.default.removeItem(at: item.localURL)
        }
        if let package { OfflineHLSReference.removeDownloadedPackage(at: package) }
    }

    private func checkConcurrentHLS(authenticated: Bool, userAgent: String = "Soulo-HLS-Regression/1.0") async throws {
        let expectsNativeTask = !authenticated && userAgent == AppConstants.mobileWebViewUserAgent
        var files: [String: Data] = [:]
        var playlist = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:VOD\n"
        for index in 0..<4 {
            let key = "SOULO_QA_VIDEO_ONLY_TS_\(index)"
            if let raw = ProcessInfo.processInfo.environment[key], let data = Data(base64Encoded: raw) {
                files["/segment\(index).ts"] = data
                playlist += "#EXTINF:2,\nsegment\(index).ts\n"
            } else {
                let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(index)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
                files["/segment\(index).ts"] = try Data(contentsOf: file)
                playlist += "#EXTINF:2.022,\nsegment\(index).ts\n"
            }
        }
        files["/video.m3u8"] = Data((playlist + "#EXT-X-ENDLIST\n").utf8)
        let server = try DownloadPlaybackHTTPFixture(files: files, heldPaths: ["/segment3.ts"],
                                                    requiredCookie: authenticated ? "hlsPlayback=allowed" : nil)
        let root = try await server.start()
        defer { server.stop() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = authenticated ? .nonPersistent() : .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = userAgent
        if authenticated {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                                                             .name: "hlsPlayback", .value: "allowed"]))
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let playerFrame = root.appendingPathComponent("embedded/player")
        let resource = WebMediaResource(kind: .video, url: root.appendingPathComponent("video.m3u8"),
            title: "Concurrent HLS", posterURL: nil, delivery: .hls, sourcePageURL: authenticated ? playerFrame : nil)
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
        XCTAssertEqual(source.asset === source.downloadAsset, expectsNativeTask)
        if expectsNativeTask {
            XCTAssertFalse(AuthenticatedHLSDownloadService.shared.owns(item.id),
                           "This fixture must exercise AVAssetDownloadURLSession")
            try await waitFor("The download must cache the opening segments before playback starts") {
                let completed = server.completedResponsePaths
                return completed.contains("/segment0.ts") && completed.contains("/segment1.ts")
                    && (manager.activeDownload(for: resource.url)?.progress ?? 0) > 0
            }
        }
        XCTAssertEqual(item.hlsUsesPersistentCookies, !authenticated)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(item), as: UTF8.self).contains("allowed"))
        if authenticated {
            StreamingMediaDownloadService.shared.pause(itemID: item.id)
            XCTAssertNil(manager.playbackSource(for: item.id))
            StreamingMediaDownloadService.shared.resume(itemID: item.id)
            try await waitFor("HLS did not resume") { manager.playbackSource(for: item.id) != nil }
        }
        let openingRequests = server.receivedRequests.filter { $0.path == "/segment0.ts" }.count
        let prepared = await source.preparedForPlayback()
        if expectsNativeTask { XCTAssertTrue(HLSPlaybackBridge.usesLocalBridge(prepared.asset)) }
        session.open(url: prepared.asset.url, asset: prepared.asset, persistPosition: false, downloadSource: prepared)
        try await waitFor("HLS player did not advance before the last segment arrived") { session.player.currentTime().seconds > 0.5 }
        if expectsNativeTask {
            XCTAssertEqual(server.receivedRequests.filter { $0.path == "/segment0.ts" }.count, openingRequests,
                           "Playback must reuse the already downloaded first segment")
        }
        XCTAssertTrue(session.player.currentItem?.asset === prepared.asset)
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .inProgress)
        XCTAssertNil(session.error)
        let before = session.player.currentTime().seconds
        var reachedEnd = false
        let playbackItem = try XCTUnwrap(session.player.currentItem)
        let ended = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: playbackItem, queue: .main) { _ in MainActor.assumeIsolated { reachedEnd = true } }
        defer { NotificationCenter.default.removeObserver(ended) }
        server.releaseDownloads()
        let result = try await download.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(manager.downloads.first(where: { $0.id == item.id })?.status, .finished)
        print("HLS_QA_FINISHED native=\(expectsNativeTask) before=\(before) after=\(session.player.currentTime().seconds) reachedEnd=\(reachedEnd)")
        try await waitFor("HLS completion interrupted the active player") { reachedEnd || session.player.currentTime().seconds > before + 0.3 }
        XCTAssertNil(session.error)
        let requests = server.receivedRequests
        XCTAssertGreaterThanOrEqual(requests.filter { $0.path == "/video.m3u8" }.count, 2)
        if expectsNativeTask {
            XCTAssertTrue(requests.contains { $0.headers["user-agent"] == userAgent })
        } else {
            XCTAssertTrue(requests.allSatisfy { $0.headers["user-agent"] == userAgent }, String(describing: requests))
        }
        if authenticated {
            XCTAssertTrue(requests.allSatisfy { $0.headers["cookie"]?.contains("hlsPlayback=allowed") == true })
            XCTAssertTrue(requests.contains { $0.path == "/segment0.ts" && $0.headers["referer"] == playerFrame.absoluteString },
                "The downloader must keep the embedded player's referrer")
        }
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
