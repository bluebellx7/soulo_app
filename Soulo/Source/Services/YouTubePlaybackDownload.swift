import Foundation
import UIKit
import WebKit

/// Reuses the site's normal playback in a separate view after a media request
/// cannot be saved directly. The user's tab, playhead, and audio stay intact.
@MainActor
final class YouTubePlaybackDownload: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    private static let handlerName = "souloYouTubePlaybackDownload"
    private let webView: WKWebView
    private let pageURL: URL
    private let videoID: String
    private let advertisedDuration: Double
    private let write: (String, Int, Data) async throws -> Void
    private let progress: (Double) -> Void
    private var result: CheckedContinuation<Double, Error>?
    private var watchdog: Task<Void, Never>?
    private var lastActivity = ContinuousClock.now
    private var lastCoverage = 0.0
    private var paused = false
    private var canceled = false

    init(source: WKWebView, pageURL: URL, duration: Double,
         write: @escaping (String, Int, Data) async throws -> Void,
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
        let script = Self.captureScript + "(\(duration));"
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true
        ))
    }

    func collect(behind source: WKWebView) async throws -> Double {
        defer { cleanUp() }
        let host = source.superview ?? source.window?.rootViewController?.view
            ?? UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController?.view }.first
        guard let host else { throw StreamingMediaDownloadError.unavailable }
        if AdBlockSettingsService.filteringEnabled() {
            let allowlist = AdBlockSettingsService.shared.allowlistedHosts
            let rules: [WKContentRuleList]?
            if let cached = WebViewRepresentable.cachedContentRules(for: allowlist) { rules = cached }
            else { rules = await AdBlockService.compileRuleLists(allowlistedHosts: allowlist) }
            for rule in rules ?? [] { webView.configuration.userContentController.add(rule) }
        }
        try Task.checkCancellation()
        guard !canceled else { throw CancellationError() }
        webView.frame = host.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.insertSubview(webView, at: 0)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                result = continuation
                lastActivity = .now
                webView.load(URLRequest(url: pageURL))
                watchdog = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, !Task.isCancelled, result != nil else { return }
                        if paused { lastActivity = .now }
                        if lastActivity.duration(to: .now) > .seconds(45) {
                            finish(.failure(StreamingMediaDownloadError.unavailable))
                            return
                        }
                        webView.evaluateJavaScript("window.__souloPlaybackDownloadPump?.(\(paused));", completionHandler: nil)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        webView.evaluateJavaScript("window.__souloPlaybackDownloadPump?.(\(value));", completionHandler: nil)
    }

    func cancel() {
        canceled = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ outcome: Result<Double, Error>) {
        guard let result else { return }
        self.result = nil
        result.resume(with: outcome)
    }

    private func cleanUp() {
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
            finish(.failure(StreamingMediaDownloadError.unavailable))
            return
        }
        decisionHandler(.allow)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(StreamingMediaDownloadError.unavailable))
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
            replyHandler(true, nil)
            if kind == "complete", covered >= duration - 0.12 { finish(.success(duration)) }
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
            finish(.failure(StreamingMediaDownloadError.unavailable))
        default:
            replyHandler(nil, "Unknown playback download event")
        }
    }

    // Installed only in the replay view. Its format profile describes what the
    // native MP4 exporter can save, while the site's player fetches the data.
    private static let captureScript = #"""
    (advertisedDuration => {
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
        const play = HTMLMediaElement.prototype.play;
        HTMLMediaElement.prototype.play = function () {
            this.muted = true;
            this.playsInline = true;
            return Reflect.apply(play, this, arguments);
        };
        let source, stopped = false, paused = false, queuedBytes = 0;
        let queue = Promise.resolve();
        const tracks = new Map();
        const fail = () => {
            if (stopped) return;
            stopped = true;
            void send('failed').catch(() => {});
        };
        document.addEventListener('encrypted', fail, true);

        function report() {
            if (stopped || isAd() || tracks.size !== 2) return;
            const video = mainVideo();
            const duration = video?.duration;
            if (!Number.isFinite(duration) || Math.abs(duration - advertisedDuration) > 1.05 || video.mediaKeys) return;
            const covered = Math.min(...Array.from(tracks.values(), track => track.covered));
            if (covered <= 0) return;
            if (covered >= duration - 0.09) {
                stopped = true;
                video.pause();
                void queue.then(() => send('complete', { duration, covered })).catch(() => {});
            } else {
                void send('progress', { duration, covered }).catch(fail);
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
            void queue.catch(fail);
        }

        const addBuffer = mediaSourceType.prototype.addSourceBuffer;
        mediaSourceType.prototype.addSourceBuffer = function (mime) {
            const buffer = Reflect.apply(addBuffer, this, arguments);
            if (!compatible(mime)) return buffer;
            const owner = this;
            const kind = /^video\//i.test(mime) ? 'video' : 'audio';
            const track = { kind, index: 0, covered: 0 };
            const append = buffer.appendBuffer;
            buffer.addEventListener('error', () => { if (source === owner) fail(); });
            buffer.appendBuffer = function (data) {
                const result = Reflect.apply(append, this, arguments);
                if (stopped || isAd() || mainVideo()?.mediaKeys) return result;
                if (queuedBytes + data.byteLength > 16 * 1024 * 1024
                    || (source && source !== owner) || (tracks.has(kind) && tracks.get(kind) !== track)) {
                    fail();
                    return result;
                }
                source = owner;
                tracks.set(kind, track);
                const bytes = new Uint8Array(data.buffer || data, data.byteOffset || 0, data.byteLength).slice();
                enqueue(bytes, track);
                this.addEventListener('updateend', () => {
                    for (let i = 0; i < this.buffered.length; i += 1) {
                        if (this.buffered.start(i) <= track.covered + 0.06) {
                            track.covered = Math.max(track.covered, this.buffered.end(i));
                        }
                    }
                    report();
                }, { once: true });
                return result;
            };
            const changeType = buffer.changeType;
            if (typeof changeType === 'function') {
                buffer.changeType = function () {
                    const result = Reflect.apply(changeType, this, arguments);
                    if (tracks.get(kind) === track) fail();
                    return result;
                };
            }
            return buffer;
        };
    })
    """#
}
