import Foundation
import UIKit
import WebKit

/// Reuses the site's normal playback in a separate view after a media request
/// cannot be saved directly. The user's tab, playhead, and audio stay intact.
@MainActor
final class YouTubePlaybackDownload: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static let handlerName = "souloYouTubePlaybackDownload"
    private static let maximumSourceRestarts = 2
    private static let maximumRestartPlayhead = 1.5
    nonisolated private static let maximumTailGap = 0.35
    nonisolated private static let maximumTailGapFraction = 0.01
    private let webView: WKWebView
    private let pageURL: URL
    private let videoID: String
    private let advertisedDuration: Double
    private let write: (String, Int, Data) async throws -> Void
    private let restart: () async throws -> Void
    private let progress: (Double) -> Void
    private var result: CheckedContinuation<Double, Error>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var lastCoverage = 0.0
    private var lastPlayhead = 0.0
    private var sourceRestarts = 0
    private var paused = false
    private var appIsActive = true
    private var canceled = false

    init(source: WKWebView, pageURL: URL, duration: Double,
         write: @escaping (String, Int, Data) async throws -> Void,
         restart: @escaping () async throws -> Void,
         progress: @escaping (Double) -> Void) throws {
        guard let videoID = WebResourceMediaService.youtubeVideoID(for: pageURL),
              var url = WebResourceMediaService.youtubeCanonicalURL(for: pageURL)
                .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }),
              duration.isFinite, duration > 0 else { throw StreamingMediaDownloadError.unavailable }
        url.host = "m.youtube.com"
        guard let watchURL = url.url else { throw StreamingMediaDownloadError.unavailable }
        self.pageURL = watchURL
        self.videoID = videoID
        self.advertisedDuration = duration
        self.write = write
        self.restart = restart
        self.progress = progress

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = source.configuration.websiteDataStore
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = source.customUserAgent
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: Self.handlerName)
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.captureScript(duration: duration), injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
    }

    static func captureScript(duration: Double) -> String {
        captureScript + "(\(duration), \(maximumTailGap), \(maximumTailGapFraction), \(maximumSourceRestarts), \(maximumRestartPlayhead));"
    }

    func collect(in window: UIWindow) async throws -> Double {
        defer { cleanUp() }
        guard window.windowScene != nil else { throw StreamingMediaDownloadError.unavailable }
        if AdBlockSettingsService.filteringEnabled() {
            let allowlist = AdBlockSettingsService.shared.allowlistedHosts
            let rules: [WKContentRuleList]?
            if let cached = WebViewRepresentable.cachedContentRules(for: allowlist) { rules = cached }
            else { rules = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist) }
            for rule in rules ?? [] { webView.configuration.userContentController.add(rule) }
        }
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        let notifications = NotificationCenter.default
        notifications.addObserver(self, selector: #selector(appWillResignActive),
                                  name: UIApplication.willResignActiveNotification, object: nil)
        notifications.addObserver(self, selector: #selector(appDidBecomeActive),
                                  name: UIApplication.didBecomeActiveNotification, object: nil)
        appIsActive = UIApplication.shared.applicationState == .active
        webView.frame = window.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // The browser's own view can detach while a download is still active.
        webView.alpha = 0.02
        window.insertSubview(webView, at: 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result = continuation
                lastActivity = .now
                BrowserStartupTrace.mark("youtube_playback_download_started", detail: "duration=\(advertisedDuration)")
                webView.load(URLRequest(url: pageURL))
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, !Task.isCancelled, result != nil else { return }
                        if paused || !appIsActive { lastActivity = .now }
                        if lastActivity.duration(to: .now) > .seconds(45) {
                            failCapture("watchdog")
                            return
                        }
                        pumpPlayback()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        lastActivity = .now
        pumpPlayback()
    }

    @objc private func appWillResignActive() {
        appIsActive = false
        pumpPlayback()
    }

    @objc private func appDidBecomeActive() {
        appIsActive = true
        lastActivity = .now
        pumpPlayback()
    }

    private func pumpPlayback() {
        let shouldPause = paused || !appIsActive
        webView.evaluateJavaScript("window.__souloPlaybackDownloadPump?.(\(shouldPause));", completionHandler: nil)
    }

    func cancel() {
        canceled = true
        finish(.failure(CancellationError()))
    }

    nonisolated static func hasCompleteCoverage(duration: Double, covered: Double) -> Bool {
        guard duration.isFinite, duration > 0, covered.isFinite, covered > 0 else { return false }
        // Audio and video can end on different sample boundaries.
        return covered >= duration - min(maximumTailGap, duration * maximumTailGapFraction)
    }

    private func finish(_ outcome: Result<Double, Error>) {
        guard let result else { return }
        self.result = nil
        result.resume(with: outcome)
    }

    private func failCapture(_ reason: String) {
        guard result != nil else { return }
        BrowserStartupTrace.mark("youtube_playback_download_failed",
            detail: "\(reason) covered=\(lastCoverage) playhead=\(lastPlayhead) duration=\(advertisedDuration)")
        finish(.failure(StreamingMediaDownloadError.unavailable))
    }

    private func cleanUp() {
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        watchdog?.cancel()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        webView.removeFromSuperview()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let frame = action.targetFrame else {
            decisionHandler(.cancel)
            return
        }
        guard frame.isMainFrame else { decisionHandler(.allow); return }
        guard let url = action.request.url, url.scheme == "https",
              ["m.youtube.com", "www.youtube.com"].contains(url.host ?? ""),
              WebResourceMediaService.youtubeVideoID(for: url) == videoID else {
            decisionHandler(.cancel)
            failCapture("navigation")
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failCapture("web_process_terminated")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard result != nil, message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "https",
              ["m.youtube.com", "www.youtube.com"].contains(message.frameInfo.securityOrigin.host),
              webView.url.flatMap(WebResourceMediaService.youtubeVideoID(for:)) == videoID,
              let body = message.body as? [String: Any], let kind = body["type"] as? String else {
            replyHandler(nil, "Playback download is unavailable")
            return
        }
        switch kind {
        case "restart":
            guard sourceRestarts < Self.maximumSourceRestarts, lastPlayhead <= Self.maximumRestartPlayhead else {
                replyHandler(nil, "Cannot restart this playback download")
                failCapture("source_changed")
                return
            }
            sourceRestarts += 1
            Task {
                do {
                    try await restart()
                    lastCoverage = 0
                    lastPlayhead = 0
                    lastActivity = .now
                    BrowserStartupTrace.mark("youtube_playback_download_restarted")
                    replyHandler(true, nil)
                } catch {
                    replyHandler(nil, "Could not restart playback download")
                    finish(.failure(error))
                }
            }
        case "progress", "complete":
            guard let duration = (body["duration"] as? NSNumber)?.doubleValue, duration.isFinite, duration > 0,
                  abs(duration - advertisedDuration) <= 1.05,
                  let covered = (body["covered"] as? NSNumber)?.doubleValue, covered.isFinite, covered >= 0 else {
                replyHandler(nil, "Invalid playback duration")
                return
            }
            if covered > lastCoverage {
                lastCoverage = covered
                lastActivity = .now
                progress(min(covered / duration, 1))
            }
            // A full buffer can feed playback for longer than the fragment
            // timeout before the player requests anything from the server.
            if !paused, let playhead = (body["playhead"] as? NSNumber)?.doubleValue,
               playhead.isFinite, playhead > lastPlayhead + 0.1, playhead <= min(duration, covered + 0.15) {
                lastPlayhead = playhead
                lastActivity = .now
            }
            replyHandler(true, nil)
            if kind == "complete", Self.hasCompleteCoverage(duration: duration, covered: covered) {
                finish(.success(duration))
            }
        case "chunk":
            guard let track = body["track"] as? String, track == "video" || track == "audio",
                  let index = SafeNumericValue.nonnegativeInt(body["index"]),
                  let encoded = body["base64"] as? String, encoded.utf8.count <= 175_000,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
                replyHandler(nil, "Invalid playback segment")
                return
            }
            Task {
                do {
                    try await write(track, index, bytes)
                    lastActivity = .now
                    replyHandler(true, nil)
                } catch {
                    replyHandler(nil, "Could not write playback segment")
                    finish(.failure(error))
                }
            }
        case "failed":
            replyHandler(true, nil)
            let reasons = ["encrypted", "buffer_error", "queue_limit", "source_changed", "track_changed", "format_changed", "write_rejected"]
            let reason = body["reason"] as? String ?? ""
            failCapture(reasons.contains(reason) ? reason : "capture_failure")
        default:
            replyHandler(nil, "Unknown playback download event")
        }
    }

    // Installed only in the replay view. Its format profile describes what the
    // native MP4 exporter can save, while the site's player fetches the data.
    private static let captureScript = #"""
    ((advertisedDuration, maximumTailGap, maximumTailGapFraction, maximumSourceRestarts, maximumRestartPlayhead) => {
        const mediaSourceType = window.ManagedMediaSource || window.MediaSource;
        if (!mediaSourceType) return;
        const send = (type, payload = {}) => window.webkit.messageHandlers.souloYouTubePlaybackDownload.postMessage({ type, ...payload });
        const compatible = mime => /^(?:video\/mp4|audio\/mp4)\b/i.test(String(mime));
        const accepts = mediaSourceType.isTypeSupported;
        const canPlay = HTMLMediaElement.prototype.canPlayType;
        mediaSourceType.isTypeSupported = function (mime) {
            return compatible(mime) && Reflect.apply(accepts, this, arguments);
        };
        HTMLMediaElement.prototype.canPlayType = function (mime) {
            return compatible(mime) ? Reflect.apply(canPlay, this, arguments) : '';
        };

        const mainVideo = () => document.querySelector('#movie_player video.html5-main-video');
        const isAd = () => document.querySelector('#movie_player')?.classList.contains('ad-showing');
        const mediaSources = new Map();
        const createObjectURL = URL.createObjectURL;
        URL.createObjectURL = function (object) {
            const url = Reflect.apply(createObjectURL, this, arguments);
            if (object instanceof mediaSourceType) {
                mediaSources.set(url, object);
                object.addEventListener('sourceclose', () => mediaSources.delete(url), { once: true });
            }
            return url;
        };
        const attachedSource = video => video.srcObject instanceof mediaSourceType
            ? video.srcObject : mediaSources.get(video.currentSrc || video.src);
        const play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () {
            this.muted = true;
            this.playsInline = true;
            return Reflect.apply(play, this, arguments);
        };
        let source, stopped = false, paused = false, queuedBytes = 0;
        let sourceRestarts = 0, restartPending = false, playhead = 0, lastAdvance = 0;
        let queue = Promise.resolve();
        const tracks = new Map();
        const fail = reason => {
            if (stopped) return;
            stopped = true;
            void send('failed', { reason }).catch(() => {});
        };
        document.addEventListener('encrypted', event => {
            if (event.target === mainVideo()) fail('encrypted');
        }, true);

        function report() {
            if (stopped || restartPending || isAd() || tracks.size !== 2) return;
            const video = mainVideo();
            const duration = video?.duration;
            if (!Number.isFinite(duration) || Math.abs(duration - advertisedDuration) > 1.05 || video.mediaKeys) return;
            const attached = attachedSource(video);
            if (attached && attached !== source) return;
            playhead = Math.max(playhead, video.currentTime);
            // WebKit can extend buffered ranges when the media source ends,
            // without dispatching another SourceBuffer updateend.
            for (const track of tracks.values()) {
                let ranges;
                try { ranges = track.buffer.buffered; } catch { return; }
                for (let i = 0; i < ranges.length; i += 1) {
                    if (ranges.start(i) <= track.covered + 0.06) {
                        track.covered = Math.max(track.covered, ranges.end(i));
                    }
                }
            }
            const covered = Math.min(...Array.from(tracks.values(), track => track.covered));
            if (covered <= 0) return;
            if (covered >= duration - Math.min(maximumTailGap, duration * maximumTailGapFraction)) {
                stopped = true;
                video.pause();
                void queue.then(() => send('complete', { duration, covered })).catch(() => {});
            } else {
                void send('progress', { duration, covered, playhead: video.currentTime }).catch(() => fail('write_rejected'));
                // The replay can advance inside the data it has already saved.
                // Keep three seconds before the edge and require contiguous audio and video from zero.
                const target = covered - 3;
                if (!paused && !video.paused && !video.seeking && video.currentTime > maximumRestartPlayhead
                    && target - video.currentTime >= 8 && target - lastAdvance >= 5) {
                    lastAdvance = target;
                    const advancingSource = source;
                    void queue.then(() => {
                        if (!stopped && !paused && !video.paused && !video.seeking
                            && source === advancingSource && target > video.currentTime) video.currentTime = target;
                    }).catch(() => fail('write_rejected'));
                }
            }
        }

        window.__souloPlaybackDownloadPump = function (shouldPause) {
            paused = shouldPause;
            const video = mainVideo();
            if (stopped || !video) return;
            if (paused) {
                if (!video.paused) video.pause();
            } else if (video.paused && !video.ended) {
                video.play().catch(() => {});
            }
            report();
        };

        function enqueue(bytes, track) {
            queuedBytes += bytes.byteLength;
            queue = queue.then(async () => {
                for (let offset = 0; offset < bytes.byteLength; offset += 128 * 1024) {
                    const end = Math.min(offset + 128 * 1024, bytes.byteLength);
                    let raw = '';
                    for (let start = offset; start < end; start += 32768) {
                        raw += String.fromCharCode(...bytes.subarray(start, Math.min(end, start + 32768)));
                    }
                    await send('chunk', { track: track.kind, index: track.index++, base64: btoa(raw) });
                }
                queuedBytes -= bytes.byteLength;
            });
            // A closed or canceled view rejects pending writes.
            void queue.catch(() => fail('write_rejected'));
        }

        const addBuffer = mediaSourceType.prototype.addSourceBuffer;
        mediaSourceType.prototype.addSourceBuffer = function (mime) {
            const buffer = Reflect.apply(addBuffer, this, arguments);
            if (!compatible(mime)) return buffer;
            const owner = this;
            const kind = /^video\//i.test(mime) ? 'video' : 'audio';
            const track = { kind, buffer, index: 0, covered: 0 };
            const append = buffer.appendBuffer;
            buffer.addEventListener('error', () => { if (source === owner) fail('buffer_error'); });
            buffer.appendBuffer = function (data) {
                const result = Reflect.apply(append, this, arguments);
                const video = mainVideo();
                if (stopped || !video || isAd() || video.mediaKeys) return result;
                const attached = attachedSource(video);
                if (attached && attached !== owner) return result;
                if (source && source !== owner) {
                    if (attached !== owner) return result;
                    if (restartPending || sourceRestarts >= maximumSourceRestarts
                        || Math.max(playhead, video.currentTime) > maximumRestartPlayhead) {
                        fail('source_changed');
                        return result;
                    }
                    // YouTube can replace its startup source before playback settles.
                    // Drain the old writes, then truncate both tracks before index zero of the new source.
                    sourceRestarts++;
                    restartPending = true;
                    playhead = 0;
                    lastAdvance = 0;
                    tracks.clear();
                    queue = queue.then(async () => {
                        await send('restart');
                        restartPending = false;
                    });
                }
                const reason = queuedBytes + data.byteLength > 16 * 1024 * 1024 ? 'queue_limit'
                    : (tracks.has(kind) && tracks.get(kind) !== track) ? 'track_changed' : '';
                if (reason) {
                    fail(reason);
                    return result;
                }
                source = owner;
                tracks.set(kind, track);
                const bytes = new Uint8Array(data.buffer || data, data.byteOffset || 0, data.byteLength).slice();
                enqueue(bytes, track);
                this.addEventListener('updateend', report, { once: true });
                return result;
            };
            const changeType = buffer.changeType;
            if (typeof changeType === 'function') {
                buffer.changeType = function () {
                    const result = Reflect.apply(changeType, this, arguments);
                    if (tracks.get(kind) === track) fail('format_changed');
                    return result;
                };
            }
            return buffer;
        };
    })
    """#
}
