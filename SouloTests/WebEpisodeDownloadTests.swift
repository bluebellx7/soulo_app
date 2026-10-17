import XCTest
import WebKit
import Combine
@testable import Soulo

@MainActor final class WebEpisodeDownloadTests: XCTestCase {
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
