import WebKit

struct WebEpisodeDownloadJob: Identifiable {
    enum Status { case waiting, resolving, downloading, finished, failed, cancelled }
    let id = UUID()
    let episode: WebEpisode
    var status: Status = .waiting
    var errorMessage = ""
    var isActive: Bool { [.waiting, .resolving, .downloading].contains(status) }
}

@MainActor final class WebEpisodeDownloadService: ObservableObject {
    static let shared = WebEpisodeDownloadService()
    @Published private(set) var jobs: [WebEpisodeDownloadJob] = []
    private struct Work {
        let id: UUID
        let episode: WebEpisode
        let pageTitle: String
        let sourceView: WKWebView
        weak var model: WebViewModel?
    }
    private var pending: [Work] = []
    private var workers = 0
    private let resolutionTimeout: TimeInterval

    init(resolutionTimeout: TimeInterval = 20) { self.resolutionTimeout = resolutionTimeout }

    @discardableResult
    func enqueue(_ episodes: [WebEpisode], pageTitle: String, viewModel: WebViewModel) -> Int {
        guard let webView = viewModel.webView else { return 0 }
        var activeURLs = Set(jobs.filter(\.isActive).map { $0.episode.url })
        // Retain active work and the most recent results when starting another batch.
        if jobs.count > 500 { jobs = Self.prunedHistory(jobs) }
        var addedJobs: [WebEpisodeDownloadJob] = []
        var addedWork: [Work] = []
        for episode in episodes where activeURLs.insert(episode.url).inserted {
            guard ["http", "https"].contains(episode.url.scheme?.lowercased() ?? "") else { continue }
            let job = WebEpisodeDownloadJob(episode: episode)
            addedJobs.append(job)
            addedWork.append(Work(id: job.id, episode: episode, pageTitle: pageTitle, sourceView: webView, model: viewModel))
        }
        // Publish a complete batch once rather than refreshing the picker for
        // every episode in a large selection.
        if addedJobs.isEmpty { return 0 }
        jobs.append(contentsOf: addedJobs)
        pending.append(contentsOf: addedWork)
        startNext()
        return addedJobs.count
    }

    static func prunedHistory(_ jobs: [WebEpisodeDownloadJob]) -> [WebEpisodeDownloadJob] {
        let recentIDs = Set(jobs.filter { !$0.isActive }.suffix(100).map(\.id))
        // Preserve chronological order so an older result cannot replace a
        // newer active retry when the picker builds its latest-status index.
        return jobs.filter { $0.isActive || recentIDs.contains($0.id) }
    }

    func cancelQueued(episodeURLs: Set<URL>) {
        let ids = Set(pending.filter { episodeURLs.contains($0.episode.url) }.map(\.id))
        guard !ids.isEmpty else { return }
        pending.removeAll { ids.contains($0.id) }
        var updated = jobs
        for index in updated.indices where ids.contains(updated[index].id) { updated[index].status = .cancelled }
        jobs = updated
    }

    private func startNext() {
        while workers < 2, !pending.isEmpty {
            let work = pending.removeFirst()
            workers += 1
            Task {
                await run(work)
                workers -= 1
                startNext()
            }
        }
    }

    private func update(_ id: UUID, status: WebEpisodeDownloadJob.Status, error: String = "") {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].errorMessage = error
    }

    private func run(_ work: Work) async {
        update(work.id, status: .resolving)
        let tracked = work.model?.beginMediaDownload(url: work.episode.url, name: work.episode.title) == true
        let resolver = WebEpisodeMediaResolver(episode: work.episode, sourceView: work.sourceView)
        defer {
            resolver.invalidate()
            if tracked { work.model?.finishMediaDownload(url: work.episode.url) }
        }
        do {
            let resource = try await resolver.resolve(timeout: resolutionTimeout)
            update(work.id, status: .downloading)
            let resolvedTitle = resolver.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let pageTitle = resolvedTitle.isEmpty ? work.pageTitle : resolvedTitle
            let title = pageTitle.localizedCaseInsensitiveContains(work.episode.title)
                ? pageTitle : [pageTitle, work.episode.title].filter { !$0.isEmpty }.joined(separator: " · ")
            let filename = WebDownloadFilename.media(resource, requested: nil, pageTitle: title)
            _ = try await WebResourceDownloadService.shared.download(resource, preferredFilename: filename,
                pageURL: resource.sourcePageURL ?? work.episode.url, webView: resolver.webView)
            update(work.id, status: .finished)
        } catch {
            let native = error as NSError
            let cancelled = error is CancellationError || (native.domain == NSURLErrorDomain && native.code == NSURLErrorCancelled)
            update(work.id, status: cancelled ? .cancelled : .failed, error: cancelled ? "" : error.localizedDescription)
        }
    }
}

enum WebEpisodeDownloadError: LocalizedError, Equatable {
    case unavailable, ambiguous
    var errorDescription: String? {
        ToolText.text(self == .ambiguous ? "episodes_download_ambiguous" : "episodes_download_unavailable")
    }
}

/// Load each selected episode in its own cookie-sharing context. Never click a
/// site's controls or download an episode's HTML as if it were a video.
@MainActor final class WebEpisodeMediaResolver: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    private let episode: WebEpisode
    private var frames: [WKFrameInfo] = []
    private var committed = false
    private var navigationError: Error?

    init(episode: WebEpisode, sourceView: WKWebView) {
        self.episode = episode
        let config = WKWebViewConfiguration()
        config.websiteDataStore = sourceView.configuration.websiteDataStore
        config.defaultWebpagePreferences.preferredContentMode = sourceView.configuration.defaultWebpagePreferences.preferredContentMode
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 720), configuration: config)
        super.init()
        webView.customUserAgent = sourceView.customUserAgent
        webView.navigationDelegate = self
        let controller = config.userContentController
        controller.add(self, name: "souloEpisodeFrame")
        controller.addUserScript(WKUserScript(source: WebViewScripts.mediaResourceTracking,
            injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: """
        document.addEventListener('play',event=>{if(event.target instanceof HTMLMediaElement){event.target.muted=true;event.target.pause()}},true);
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.souloEpisodeFrame.postMessage({});",
            injectionTime: .atDocumentEnd, forMainFrameOnly: false))
    }

    func resolve(timeout: TimeInterval = 20) async throws -> WebMediaResource {
        if UserDefaults.standard.object(forKey: "ad_block_enabled") as? Bool ?? true {
            for rule in await AdBlockService.compileRuleLists(allowlistedHosts: AdBlockSettingsService.shared.allowlistedHosts) ?? [] {
                webView.configuration.userContentController.add(rule)
            }
        }
        var request = URLRequest(url: episode.url)
        request.timeoutInterval = timeout
        webView.load(request)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var previous: WebMediaResource?
        var ambiguous = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if let navigationError { throw navigationError }
            if committed, let snapshot = try? await WebResourceInspectionService.inspect(webView: webView, frames: frames) {
                let configured = snapshot.configuredVideos.filter { $0.delivery != .dash }
                let mainPlayer = configured.filter { resource in
                    guard let source = resource.sourcePageURL, let page = snapshot.pageURL else { return false }
                    return WebEpisodeList.matches(source, page)
                }
                // An explicit current URL in the page's player configuration
                // identifies this episode. Keep next-episode preloads available
                // in Resources without treating them as competing downloads.
                let candidates = !mainPlayer.isEmpty ? mainPlayer
                    : !configured.isEmpty ? configured : snapshot.videos.filter { $0.delivery != .dash }
                ambiguous = candidates.count > 1
                if candidates.count == 1, let candidate = candidates.first {
                    // Require two observations so a transient preload does not
                    // win before the player publishes its actual source.
                    if candidate.url == previous?.url {
                        return WebMediaResource(kind: .video, url: candidate.url, title: episode.title,
                            posterURL: candidate.posterURL, delivery: candidate.delivery,
                            companionAudioURL: candidate.companionAudioURL,
                            sourcePageURL: candidate.sourcePageURL ?? snapshot.pageURL ?? episode.url)
                    }
                    previous = candidate
                } else { previous = nil }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ambiguous ? WebEpisodeDownloadError.ambiguous : WebEpisodeDownloadError.unavailable
    }

    func invalidate() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "souloEpisodeFrame")
        frames.removeAll()
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, !message.frameInfo.isMainFrame, frames.count < 16,
              let url = message.frameInfo.requestURL, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        frames.removeAll { $0.requestURL == url }
        frames.append(message.frameInfo)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if !WebNavigationErrorClassifier.isExpectedInterruption(error) { navigationError = error }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              action.targetFrame != nil else { decisionHandler(.cancel); return }
        // Loading an iframe is necessary for embedded players. A committed
        // document cannot replace this resolver with an advertising landing page.
        if action.targetFrame?.isMainFrame == true, committed { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
}
