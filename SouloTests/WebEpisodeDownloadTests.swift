import XCTest
import WebKit
import Combine
import AVFoundation
import UIKit
@testable import Soulo

@MainActor final class WebEpisodeDownloadTests: XCTestCase {
    func testLiveNavigationSiteResolvesDistinctEpisodesAndStartsPlayback() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_EPISODE_QA"] == "1", "Opt-in real site from website/movies.html")
        try await verifyLiveEpisodes(mtyy: false)
    }

    func testLiveMtyySelectedEpisodesStartBothDecoders() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_MTY_QA"] == "1", "Opt-in user-reported MTYY video")
        try await verifyLiveEpisodes(mtyy: true)
    }

    private func verifyLiveEpisodes(mtyy: Bool) async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let source = WKWebView(frame: .zero, configuration: config)
        var resolved: [URL] = []
        for number in mtyy ? [1,2] : [2,3] {
            let page = URL(string: mtyy ? "https://www.mtyy5.com/vodplay/155698-4-\(number).html" : "https://www.pbkan.com/yun/1009-4-\(number).html")!
            let resolver = WebEpisodeMediaResolver(episode: .init(title: "Episode \(number)",url:page), sourceView:source)
            defer { resolver.invalidate() }
            let resource = try await resolver.resolve(timeout: mtyy ? 45 : 25)
            let configured = try await resolver.webView.evaluateJavaScript("window.player_data?.url") as? String
            if !mtyy {
                XCTAssertEqual(resource.url.absoluteString,configured,"Do not resolve the preloaded next episode")
                XCTAssertEqual(resource.sourcePageURL?.host,page.host,"Retain the actual selected player frame as the media Referer")
            }
            print("LIVE EPISODE QA page=\(page.absoluteString) resource=\(resource.url.absoluteString) referer=\(resource.sourcePageURL?.absoluteString ?? "")")
            XCTAssertFalse(resolved.contains(resource.url));resolved.append(resource.url)
            let asset = await WebResourceMediaService.asset(for:resource,webView:source)
            let session=MediaSession.shared
            session.open(url:resource.url,title:resource.title,pageURL:resource.sourcePageURL,asset:asset,webView:source,persistPosition:false,startAt:0)
            let player=session.player,item=try XCTUnwrap(player.currentItem)
            item.preferredForwardBufferDuration=1
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:nil);item.add(output)
            let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
            let oldWindow=scene.keyWindow,window=UIWindow(windowScene:scene),host=UIViewController()
            window.rootViewController=host;window.makeKeyAndVisible()
            let layer=AVPlayerLayer(player:player);layer.frame=CGRect(x:0,y:0,width:390,height:220);host.view.layer.addSublayer(layer)
            defer { session.stop();window.isHidden=true;window.rootViewController=nil;oldWindow?.makeKeyAndVisible() }
            var decoded = false
            for _ in 0..<400 {
                let time=output.itemTime(forHostTime:CACurrentMediaTime())
                decoded = player.currentTime().seconds > 0.3 && output.copyPixelBuffer(forItemTime:time,itemTimeForDisplay:nil) != nil
                if item.status == .failed || decoded { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            let report: [String:Any] = ["page":page.absoluteString,"resource":resource.url.absoluteString,
                "referer":resource.sourcePageURL?.absoluteString ?? "", "status":item.status.rawValue,
                "time":player.currentTime().seconds, "rate":player.rate,"requested":session.isPlaybackRequested,
                "waiting":player.reasonForWaitingToPlay?.rawValue ?? "",
                "errors":item.errorLog()?.events.map { $0.errorComment ?? "" } ?? []]
            let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:report),uniformTypeIdentifier:"public.json")
            attachment.name="live-selected-episode-\(number)";attachment.lifetime = .keepAlways;add(attachment)
            XCTAssertNotEqual(item.status,.failed,item.error?.localizedDescription ?? "")
            XCTAssertTrue(decoded,"Real selected episode must decode a video frame: \(report)")
            session.stop()
            layer.removeFromSuperlayer()
            let playback=MatroskaPlayback();playback.attach(host.view)
            let context=await VideoPlaybackRequestContext.load(url:resource.url,pageURL:resource.sourcePageURL,webView:source)
            playback.open(asset.url,requestContext:context,title:resource.title)
            defer{playback.stop()}
            for _ in 0..<400 {
                if playback.error != nil || playback.elapsed > 0.3 {break}
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertNil(playback.error)
            XCTAssertGreaterThan(playback.elapsed,0.3,"The default Soulo decoder must play the selected episode")
            playback.stop()
        }
    }

    func testDirectCatalogStreamsResolveWithoutLoadingAnHTMLPage() async throws {
        let pageURL = try XCTUnwrap(URL(string: "https://catalog.example/detail/1"))
        let streamURL = try XCTUnwrap(URL(string: "https://cdn.example/play/first/index.m3u8?token=abc"))
        let episode = WebEpisode(title: "第01集", url: streamURL, resourcePageURL: pageURL)
        let resolver = WebEpisodeMediaResolver(episode: episode, sourceView: WKWebView())
        defer { resolver.invalidate() }
        let resource = try await resolver.resolve(timeout: 1)
        XCTAssertEqual(resource.url, streamURL)
        XCTAssertEqual(resource.title, "第01集")
        XCTAssertEqual(resource.delivery, .hls)
        XCTAssertEqual(resource.sourcePageURL, pageURL)
        XCTAssertNil(resolver.webView.url)
    }

    func testDirectCatalogEpisodesDownloadRealMediaWithSharedCookies() async throws {
        try await verifyDirectCatalogDownloads()
    }

    func testHidingVideoDownloadControlsDoesNotStopExistingOrQueuedDownloads() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        defaults.set(true, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
        defer { defaults.set(original, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey) }
        try await verifyDirectCatalogDownloads(hideControlsAfterEnqueue: true)
    }

    private func verifyDirectCatalogDownloads(hideControlsAfterEnqueue: Bool = false) async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: fixture)
        let names = hideControlsAfterEnqueue ? ["first", "second", "third"] : ["first", "second"]
        let files = Dictionary(uniqueKeysWithValues: names.map { ("/\($0).mp4", bytes) })
        let server = try DownloadPlaybackHTTPFixture(files: files, requiredCookie: "catalogAuth=allowed")
        let root = try await server.start(); defer { server.stop() }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let model = WebViewModel(); model.webView = WKWebView(frame: .zero, configuration: configuration)
        defer { model.releaseWebViewRuntime() }
        let previousIDs = Set(DownloadManagerService.shared.downloads.map(\.id))
        defer {
            for item in DownloadManagerService.shared.downloads where !previousIDs.contains(item.id) {
                DownloadManagerService.shared.delete(item)
                try? FileManager.default.removeItem(at: item.localURL)
            }
        }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "catalogAuth", .value: "allowed"]))
        await configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        let episodes = names.enumerated().map { index, name in
            WebEpisode(title: "Episode \(index + 1)", url: root.appendingPathComponent("\(name).mp4"), resourcePageURL: root.appendingPathComponent("detail.html"))
        }
        let service = WebEpisodeDownloadService(resolutionTimeout: 2)
        XCTAssertEqual(service.enqueue(episodes, pageTitle: "Catalog", viewModel: model), episodes.count)
        if hideControlsAfterEnqueue {
            for _ in 0..<80 where !service.jobs.contains(where: { $0.status == .downloading }) {
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(service.jobs.contains { $0.status == .downloading })
            XCTAssertTrue(service.jobs.contains { $0.status == .waiting }, "Exceed the two-worker limit to verify a queued download starts after controls are hidden")
            UserDefaults.standard.set(false, forKey: VideoPlaybackPreferences.showsWebDownloadControlsKey)
            XCTAssertFalse(VideoPlaybackPreferences.showsWebDownloadControls())
        }
        server.releaseDownloads()
        for _ in 0..<240 where service.jobs.contains(where: \.isActive) { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(service.jobs.map(\.status), Array(repeating: .finished, count: episodes.count), service.jobs.map(\.errorMessage).joined(separator: "; "))
        for episode in episodes {
            let item = try XCTUnwrap(DownloadManagerService.shared.finishedDownload(for: episode.url))
            XCTAssertEqual(try Data(contentsOf: item.localURL), bytes)
        }
    }

    func testEpisodeResolverChoosesCurrentStreamWhenNextEpisodeIsPreloaded() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/episode.html": Data("""
            <script>window.player_aaaa={url:location.origin+'/current.mp4',url_next:location.origin+'/next.mp4',encrypt:0}</script>
            """.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let source = WKWebView(frame: .zero, configuration: configuration)
        let resolver = WebEpisodeMediaResolver(episode: WebEpisode(title: "Episode 10", url: root.appendingPathComponent("episode.html")), sourceView: source)
        defer { resolver.invalidate() }
        let resource = try await resolver.resolve(timeout: 8)
        XCTAssertEqual(resource.url, root.appendingPathComponent("current.mp4"))
        XCTAssertEqual(resource.sourcePageURL, root.appendingPathComponent("episode.html"))
        let snapshot = try await WebResourceInspectionService.inspect(webView: resolver.webView)
        XCTAssertEqual(Set(snapshot.videos.map(\.url)), Set(["current.mp4", "next.mp4"].map(root.appendingPathComponent)))
        XCTAssertEqual(snapshot.configuredVideos.map(\.url), [resource.url])
    }

    func testBatchDownloadsEpisodes10Through14WithoutSelectingTheirPreloads() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: fixture)
        var files: [String: Data] = [:]
        for index in 10...15 { files["/clip\(index).mp4"] = bytes }
        for index in 10...14 {
            files["/ep\(index).html"] = Data("""
                <title>Episode \(index)</title><body><script>window.player_aaaa={
                url:location.origin+'/clip\(index).mp4',
                url_next:location.origin+'/clip\(index + 1).mp4',encrypt:0}</script></body>
                """.utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); defer { server.stop() }
        server.releaseDownloads()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        let model = WebViewModel(); model.webView = web
        let service = WebEpisodeDownloadService(resolutionTimeout: 8)
        let oldIDs = Set(DownloadManagerService.shared.downloads.map(\.id))
        defer {
            for item in DownloadManagerService.shared.downloads where !oldIDs.contains(item.id) {
                DownloadManagerService.shared.delete(item)
                try? FileManager.default.removeItem(at: item.localURL)
            }
            model.webView = nil
        }
        let episodes = (10...14).map { WebEpisode(title: "第\($0)集", url: root.appendingPathComponent("ep\($0).html")) }
        XCTAssertEqual(service.enqueue(episodes, pageTitle: "Episode 9", viewModel: model), 5)
        for _ in 0..<500 {
            if service.jobs.allSatisfy({ !$0.isActive }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(service.jobs.map(\.status), Array(repeating: .finished, count: 5), service.jobs.map(\.errorMessage).joined(separator: "\n"))
        let saved = DownloadManagerService.shared.downloads.filter { !oldIDs.contains($0.id) }
        XCTAssertEqual(Set(saved.map(\.sourceURLString)), Set((10...14).map { root.appendingPathComponent("clip\($0).mp4").absoluteString }))
        XCTAssertEqual(saved.count, 5)
        for item in saved {
            XCTAssertEqual(try Data(contentsOf: item.localURL), bytes)
            let index = URL(string: item.sourceURLString)!.deletingPathExtension().lastPathComponent.dropFirst(4)
            XCTAssertTrue(item.fileName.contains("Episode \(index)"), item.fileName)
            XCTAssertFalse(item.fileName.contains("Episode 9"), item.fileName)
        }
        XCTAssertEqual(model.activeDownloadCount, 0)
    }

    func testEmbeddedPlayerRetainsCurrentStreamAndItsReferer() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/episode.html": Data("<body><iframe src='/embedded.html'></iframe></body>".utf8),
            "/embedded.html": Data("<script>window.player_aaaa={url:'/current.mp4',url_next:'/next.mp4',encrypt:0}</script>".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let source = WKWebView()
        let resolver = WebEpisodeMediaResolver(episode: WebEpisode(title: "Episode", url: root.appendingPathComponent("episode.html")), sourceView: source)
        defer { resolver.invalidate() }
        let resource = try await resolver.resolve(timeout: 8)
        XCTAssertEqual(resource.url, root.appendingPathComponent("current.mp4"))
        XCTAssertEqual(resource.sourcePageURL, root.appendingPathComponent("embedded.html"))
    }

    func testMultipleConfiguredPlayersRemainAmbiguous() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/episode.html": Data("""
            <script>window.player_aaaa={url:'/first.mp4'};window.player_bbbb={url:'/second.mp4'}</script>
            """.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let source = WKWebView()
        let resolver = WebEpisodeMediaResolver(episode: WebEpisode(title: "Episode", url: root.appendingPathComponent("episode.html")), sourceView: source)
        defer { resolver.invalidate() }
        do { _ = try await resolver.resolve(timeout: 4); XCTFail("Must not choose an arbitrary configured player") }
        catch { XCTAssertEqual(error as? WebEpisodeDownloadError, .ambiguous) }
    }

    func testHistoryPruningKeepsActiveRetriesNewerThanOldResults() {
        var jobs=(1...501).map { index in
            var job=WebEpisodeDownloadJob(episode:WebEpisode(title:"EP\(index)",url:URL(string:"https://video.example/ep/\(index)")!))
            job.status = .finished
            return job
        }
        let retry=WebEpisodeDownloadJob(episode:jobs[450].episode,status:.resolving)
        jobs.append(retry)
        let retained=WebEpisodeDownloadService.prunedHistory(jobs)
        XCTAssertEqual(retained.count,101)
        XCTAssertEqual(retained.last?.id,retry.id)
        XCTAssertEqual(retained.last { $0.episode.url == retry.episode.url }?.status,.resolving)
        XCTAssertEqual(retained.filter { !$0.isActive }.map(\.id),Array(jobs.dropLast().suffix(100)).map(\.id))
    }

    func testBatchDownloadsRealMediaWithCookiesAndContinuesAfterAnUnresolvableEpisode() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let bytes = try Data(contentsOf: fixture)
        let first = Data("<body><script>window.player_aaaa={url:'/clip1.mp4',encrypt:0}</script></body>".utf8)
        let third = Data("<body><iframe src='/embedded.html'></iframe></body>".utf8)
        let server = try DownloadPlaybackHTTPFixture(files: ["/ep1.html":first,
            "/ep2.html":Data("<body>No video</body>".utf8), "/ep3.html":third,
            "/embedded.html":Data("<video src='/clip3.mp4'></video>".utf8), "/clip1.mp4":bytes, "/clip3.mp4":bytes],
            requiredCookie: "episodeAuth=allowed")
        let root = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        await config.websiteDataStore.httpCookieStore.setCookie(try XCTUnwrap(HTTPCookie(properties: [
            .domain:"127.0.0.1", .path:"/", .name:"episodeAuth", .value:"allowed"])))
        let model = WebViewModel(); model.webView = web
        let episodes = (1...3).map { WebEpisode(title:"Episode \($0)",url:root.appendingPathComponent("ep\($0).html")) }
        let service = WebEpisodeDownloadService(resolutionTimeout: 6)
        let oldIDs = Set(DownloadManagerService.shared.downloads.map(\.id))
        defer {
            for item in DownloadManagerService.shared.downloads where !oldIDs.contains(item.id) {
                DownloadManagerService.shared.delete(item)
                try? FileManager.default.removeItem(at: item.localURL)
            }
            model.webView = nil
        }
        XCTAssertEqual(service.enqueue(episodes + [episodes[0]], pageTitle: "Batch fixture", viewModel: model), 3)
        XCTAssertEqual(service.enqueue(episodes, pageTitle: "Batch fixture", viewModel: model), 0)
        for _ in 0..<400 {
            if service.jobs.allSatisfy({ !$0.isActive }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(service.jobs.map(\.status), [.finished,.failed,.finished], service.jobs.map(\.errorMessage).joined(separator:"\n"))
        XCTAssertEqual(model.activeDownloadCount, 0)
        let saved = DownloadManagerService.shared.downloads.filter { !oldIDs.contains($0.id) }
        XCTAssertEqual(Set(saved.map { $0.sourceURLString }), Set([root.appendingPathComponent("clip1.mp4").absoluteString,root.appendingPathComponent("clip3.mp4").absoluteString]))
        for item in saved {
            XCTAssertEqual(item.status, .finished)
            XCTAssertEqual(try Data(contentsOf:item.localURL), bytes)
            XCTAssertFalse(item.fileName.hasSuffix(".html"))
        }
    }

    func testAmbiguousVideosAreNotDownloadedAndHTMLIsNeverAResource() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html":Data("<video src='/a.mp4'></video><video src='/b.mp4'></video>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let resolver = WebEpisodeMediaResolver(episode:WebEpisode(title:"Ambiguous",url:root.appendingPathComponent("page.html")),sourceView:WKWebView())
        defer { resolver.invalidate() }
        do { _ = try await resolver.resolve(timeout: 3); XCTFail("Must not choose an arbitrary video") }
        catch { XCTAssertEqual(error as? WebEpisodeDownloadError, .ambiguous) }
    }

    func testStoppingQueueAndRetryingFailuresDoesNotDuplicateActiveWork() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/empty.html":Data("<body>No media</body>".utf8)])
        let root = try await server.start();defer{server.stop()}
        let model = WebViewModel();model.webView = WKWebView()
        defer { model.releaseWebViewRuntime() }
        let episodes=(1...4).map { WebEpisode(title:"EP\($0)",url:root.appendingPathComponent("empty.html").appending(queryItems:[URLQueryItem(name:"ep",value:String($0))])) }
        let service = WebEpisodeDownloadService(resolutionTimeout:1)
        var publishedBatchSizes: [Int] = []
        let subscription = service.$jobs.dropFirst().sink { publishedBatchSizes.append($0.count) }
        defer { subscription.cancel() }
        XCTAssertEqual(service.enqueue(episodes,pageTitle:"Queue fixture",viewModel:model),4)
        XCTAssertEqual(publishedBatchSizes,[4],"Observers should receive the complete batch without intermediate queue totals")
        service.cancelQueued(episodeURLs:Set(episodes.suffix(2).map(\.url)))
        XCTAssertEqual(service.jobs.suffix(2).map(\.status),[.cancelled,.cancelled])
        XCTAssertEqual(service.enqueue([episodes[0],episodes[2]],pageTitle:"Queue fixture",viewModel:model),1)
        func finishQueue() async throws {
            for _ in 0..<120 {
                if service.jobs.allSatisfy({ !$0.isActive }) { return }
                try await Task.sleep(for:.milliseconds(100))
            }
            XCTFail("Queue did not finish")
        }
        try await finishQueue()
        XCTAssertEqual(service.jobs.map(\.status),[.failed,.failed,.cancelled,.cancelled,.failed])
        XCTAssertEqual(service.enqueue([episodes[0]],pageTitle:"Retry fixture",viewModel:model),1)
        try await finishQueue()
        XCTAssertEqual(service.jobs.count,6)
        XCTAssertEqual(service.jobs.last?.status,.failed)
        XCTAssertEqual(model.activeDownloadCount,0)
    }
}
