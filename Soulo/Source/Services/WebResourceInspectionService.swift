import AVFoundation
import Foundation
import UIKit
import WebKit

enum WebResourceInspectionError: LocalizedError {
    case pageUnavailable
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .pageUnavailable:
            return AppLocalization.string("resource_inspector_page_unavailable")
        case .invalidResult:
            return AppLocalization.string("resource_inspector_invalid_result")
        }
    }
}

enum WebResourceInspectionService {
    struct VideoFallbackInspection {
        let target: (resource: WebMediaResource, token: String)?
        let hasInlineVideo: Bool
    }

    @MainActor private final class CCTVLookup {
        let page: URL
        let started = ContinuousClock.now
        let task: Task<WebMediaResource?, Never>

        init(page: URL, task: Task<WebMediaResource?, Never>) {
            self.page = page
            self.task = task
        }
    }
    @MainActor private static let cctvLookups = NSMapTable<WKWebView, CCTVLookup>.weakToStrongObjects()

    static func delivery(for url: URL) -> WebMediaResource.Delivery {
        let fileExtension = url.pathExtension.lowercased()
        let format = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { ["type", "format"].contains($0.name.lowercased()) })?
            .value?.lowercased() ?? ""
        let nestedFormats = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .filter { ["url", "src", "file"].contains($0.name.lowercased()) }
            .compactMap { $0.value.flatMap { URL(string: $0)?.pathExtension.lowercased() } } ?? []
        if fileExtension == "m3u8" || nestedFormats.contains("m3u8") || ["m3u8", "hls"].contains(format)
            || format.contains("mpegurl") { return .hls }
        if fileExtension == "mpd" || ["mpd", "dash"].contains(format) { return .dash }
        return .direct
    }

    /// Resolve the video whose own control was tapped. The media element can
    /// expose a blob URL even though its player configuration or recent network
    /// requests still contain the downloadable stream URL.
    @MainActor
    static func currentVideoResource(webView: WKWebView, frame: WKFrameInfo?, token: String) async -> WebMediaResource? {
        (await videoTarget(webView: webView, frame: frame, token: token))?.resource
    }

    /// A native entry is available when a page has a known player configuration
    /// or exactly one media element whose own toolbar cannot be displayed.
    @MainActor
    static func fallbackVideoTarget(webView: WKWebView, frame: WKFrameInfo?) async -> (resource: WebMediaResource, token: String)? {
        (await inspectVideoFallback(webView: webView, frame: frame)).target
    }

    @MainActor
    static func inspectVideoFallback(webView: WKWebView, frame: WKFrameInfo?) async -> VideoFallbackInspection {
        let inspection = await inspectVideoTarget(webView: webView, frame: frame, token: "__soulo_fallback")
        if frame == nil, inspection.target == nil, !inspection.hasInlineVideo,
           let program = await cctvProgram(in: webView) {
            return .init(target: (program, "__soulo_fallback"), hasInlineVideo: false)
        }
        return inspection
    }

    @MainActor
    private static func cctvProgram(in webView: WKWebView) async -> WebMediaResource? {
        guard let page = webView.url, CCTVDownloadSource.isProgramPage(page) else { return nil }
        if let lookup = cctvLookups.object(forKey: webView), lookup.page == page,
           lookup.started.duration(to: .now) < .seconds(30) {
            return await lookup.task.value
        }
        let task = Task { @MainActor [weak webView] in
            guard let webView else { return nil as WebMediaResource? }
            return await readCCTVProgram(page: page, in: webView)
        }
        cctvLookups.setObject(CCTVLookup(page: page, task: task), forKey: webView)
        let result = await task.value
        if result == nil, cctvLookups.object(forKey: webView)?.page == page, webView.isLoading {
            cctvLookups.removeObject(forKey: webView)
        }
        return result
    }

    @MainActor
    private static func readCCTVProgram(page: URL, in webView: WKWebView) async -> WebMediaResource? {
        guard let id = try? await webView.evaluateCompatibleJavaScript(#"""
                  (() => {
                      if (typeof guid === 'string' && /^[a-f0-9]{32}$/i.test(guid)) return guid;
                      for (const script of Array.from(document.scripts).slice(0, 256)) {
                          if (script.src) continue;
                          const match = script.textContent.slice(0, 65536).match(/(?:^|[\n;])\s*var\s+guid\s*=\s*["']([a-f0-9]{32})["']/i);
                          if (match) return match[1];
                      }
                      return '';
                  })()
                  """#) as? String,
              let url = CCTVDownloadSource.programRequest(id: id) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        request.httpShouldHandleCookies = false
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, http.url?.host == url.host
        else { return nil }
        defer { bytes.task.cancel() }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < 256 * 1024 else { return nil }
                data.append(byte)
            }
        } catch { return nil }
        guard webView.url == page, let stream = try? CCTVDownloadSource.publicStream(in: data, programID: id) else { return nil }
        return WebMediaResource(kind: .video, url: stream, title: webView.title ?? "", posterURL: nil,
                                delivery: .hls, sourcePageURL: page)
    }

    @MainActor
    private static func videoTarget(webView: WKWebView, frame: WKFrameInfo?, token: String) async -> (resource: WebMediaResource, token: String)? {
        (await inspectVideoTarget(webView: webView, frame: frame, token: token)).target
    }

    @MainActor
    private static func inspectVideoTarget(webView: WKWebView, frame: WKFrameInfo?, token: String) async -> VideoFallbackInspection {
        guard let result = try? await webView.callAsyncJavaScript(
            currentVideoScript, arguments: ["token": token], in: frame, contentWorld: .page
        ) as? [String: String] else { return .init(target: nil, hasInlineVideo: false) }
        if let data = result["manifests"]?.data(using: .utf8), let values = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            WebMediaManifestCache.remember(values, webView: webView)
        }
        if result["inlineVideo"] == "true" { return .init(target: nil, hasInlineVideo: true) }
        guard let raw = result["url"],
              let url = URL(string: raw),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return .init(target: nil, hasInlineVideo: false) }
        WebMediaManifestCache.rememberPolicy(result["referrerPolicy"], urls: [url], webView: webView)
        let delivery = WebMediaResource.Delivery(rawValue: result["delivery"] ?? "") ?? .direct
        let declaredReferrer = result["referrer"].flatMap(URL.init(string:))
        let frameURL = ["http", "https"].contains(declaredReferrer?.scheme?.lowercased() ?? "") ? declaredReferrer : frame?.requestURL
        let sourcePageURL = ["http", "https"].contains(frameURL?.scheme?.lowercased() ?? "")
            ? frameURL : webView.url
        return .init(target: (WebMediaResource(
            kind: .video, url: url, title: webView.title ?? "", posterURL: nil,
            delivery: delivery, sourcePageURL: sourcePageURL
        ), result["token"] ?? token), hasInlineVideo: false)
    }

    private static let mediaDOMQuery = #"""
        var mediaRootsCache = null;
        function mediaElements(selector) {
            if (!mediaRootsCache) {
                mediaRootsCache = [document];
                for (var index = 0; index < mediaRootsCache.length && index < 64; index++) {
                    Array.from(mediaRootsCache[index].querySelectorAll('*')).forEach(function(node) {
                        if (node.shadowRoot && mediaRootsCache.indexOf(node.shadowRoot) < 0) mediaRootsCache.push(node.shadowRoot);
                    });
                }
            }
            return mediaRootsCache.flatMap(function(root) { return Array.from(root.querySelectorAll(selector)); });
        }
    """#

    private static let currentVideoScript = #"""
    return (() => {
        \#(mediaDOMQuery)
        const webURL = value => {
            if (typeof value !== 'string' || !value.trim()) return '';
            try {
                const url = new URL(String(value || ''), document.baseURI);
                return /^https?:$/.test(url.protocol) ? url.href : '';
            } catch (_) { return ''; }
        };
        let resolvedToken = token;
        const result = (value, mime) => {
            const url = webURL(value);
            if (!url) return null;
            const parsed = new URL(url);
            const format = String(parsed.searchParams.get('type') || parsed.searchParams.get('format') || '').toLowerCase();
            const nested = ['url','src','file'].map(key => {
                try { return new URL(parsed.searchParams.get(key) || '', parsed).pathname; } catch (_) { return ''; }
            }).join(' ');
            const delivery = /\.m3u8(?:$|\s)/i.test(parsed.pathname + ' ' + nested) || /(?:m3u8|hls|mpegurl)/i.test(format + ' ' + String(mime || ''))
                ? 'hls' : /\.mpd$/i.test(parsed.pathname) || /(?:mpd|dash)/i.test(format + ' ' + String(mime || ''))
                ? 'dash' : 'direct';
            return { url, delivery, token: resolvedToken, referrerPolicy: document.referrerPolicy || document.querySelector('meta[name=referrer]')?.content || '', manifests: JSON.stringify(window.__souloObservedHLSManifests || {}) };
        };
        const mediaURL = (value, encoding) => {
            let raw = String(value || '').trim();
            if (!raw || raw.length > 8192) return '';
            if (Number(encoding) === 2) {
                try { raw = atob(raw); } catch (_) { return ''; }
            }
            for (let step = 0; step < 3; step++) {
                if (/^https?%3a/i.test(raw)) {
                    try { raw = decodeURIComponent(raw); } catch (_) { return ''; }
                }
                const direct = webURL(raw);
                if (direct && (/\.(?:m3u8|mp4|m4v|mov|webm|mpd)(?:$|[?#])/i.test(direct)
                    || /[?&](?:type|format)=(?:m3u8|hls|mpd|dash)(?:&|$)/i.test(direct))) return direct;
                try {
                    const parsed = new URL(raw, document.baseURI);
                    for (const key of ['url', 'src', 'video', 'play', 'playurl', 'file']) {
                        const nested = parsed.searchParams.get(key);
                        const candidate = webURL(nested);
                        if (candidate && (/\.(?:m3u8|mp4|m4v|mov|webm|mpd)(?:$|[?#])/i.test(candidate)
                            || /[?&](?:type|format)=(?:m3u8|hls|mpd|dash)(?:&|$)/i.test(candidate)
                            || /[?&](?:mime|type|format)=video(?:%2f|\/)/i.test(candidate))) return candidate;
                    }
                } catch (_) {}
                try {
                    const decoded = decodeURIComponent(raw);
                    if (decoded === raw) break;
                    raw = decoded;
                } catch (_) { break; }
            }
            return '';
        };
        const configuredVideo = () => {
            for (const config of [window.player_aaaa, window.player_bbbb,
                                  window.player_config, window.__PLAYER_CONFIG__, window.videoInfo]) {
                if (!config || typeof config !== 'object') continue;
                const url = mediaURL(config.url || config.playUrl || config.play_url || config.src, config.encrypt);
                if (url) return result(url);
            }
            return null;
        };
        // This explicit native action only uses the page's current player config.
        // Network observations alone must not turn an unrelated ad into a fallback.
        if (token === '__soulo_configured') return configuredVideo();
        const allVideos = mediaElements('video');
        if (token === '__soulo_episode') {
            let area = -1;
            for (const video of allVideos) {
                const id = video.getAttribute('data-soulo-media-id');
                if (!id || !video.isConnected) continue;
                const bounds = video.getBoundingClientRect();
                const size = bounds.width * bounds.height;
                if (size > area) { area = size; resolvedToken = id; }
            }
            if (area < 0) return configuredVideo();
        }
        if (token === '__soulo_fallback') {
            // A rendered player keeps its own tools, even while paused or below
            // the fold. It must never promote an unrelated hidden frame's URL
            // into a page-corner play button.
            const hasBox = element => {
                const rect = element.getBoundingClientRect();
                if (rect.width <= 1 || rect.height <= 1) return false;
                for (let node = element; node; node = node.parentElement || node.getRootNode()?.host) {
                    const style = node.ownerDocument.defaultView.getComputedStyle(node);
                    if (style.display === 'none' || style.visibility === 'hidden'
                        || style.visibility === 'collapse' || Number(style.opacity) === 0) return false;
                }
                return true;
            };
            const frameVisible = () => {
                let context = window;
                while (context !== context.top) {
                    let frame;
                    try { frame = context.frameElement; } catch (_) { return false; }
                    // Cross-origin frame visibility is reported by its isolated
                    // IntersectionObserver; do not guess from its inner size.
                    if (!frame) return false;
                    if (!hasBox(frame)) return false;
                    context = context.parent;
                }
                return true;
            };
            if (frameVisible() && allVideos.some(video => video.isConnected && hasBox(video)))
                return {inlineVideo: 'true'};
            resolvedToken = '__soulo_configured';
            const configured = configuredVideo();
            if (configured) return configured;
            if (allVideos.length !== 1 || allVideos[0].mediaKeys) return null;
            resolvedToken = allVideos[0].getAttribute('data-soulo-media-id');
            if (!resolvedToken) return null;
        }
        const video = allVideos
            .find(element => element.getAttribute('data-soulo-media-id') === resolvedToken);
        if (!video || !video.isConnected) return null;
        const rawSource = video.getAttribute('src');
        const declaredSource = !!rawSource?.trim() || Array.from(video.querySelectorAll('source[src]')).some(source => !!source.getAttribute('src')?.trim());
        const documentPlaceholder = !declaredSource && video.currentSrc === document.URL;
        const currentURL = (documentPlaceholder ? '' : webURL(video.currentSrc)) || (rawSource?.trim() ? webURL(video.src) : '');
        // Extension media adapters expose only the selected element's source;
        // the common inspector never guesses from unrelated background traffic.
        try {
            const descriptor = window.__souloNativeMediaSource?.(video);
            const selected = descriptor && result(descriptor.url, descriptor.mime);
            if (selected) {
                const referrer = webURL(descriptor.referrer);
                return referrer ? {...selected, referrer} : selected;
            }
        } catch (_) {}
        if (currentURL) {
            const response = Array.from(window.__souloObservedMediaResponses || []).reverse()
                .find(item => webURL(item?.url) === currentURL);
            return result(currentURL, response?.mime);
        }
        // Hls.js keeps a blob in currentSrc while the element's source and
        // attached controller still identify the actual playlist. Resolve that
        // exact element before considering unrelated network responses or ads.
        const hls = [window.hls, ...(Array.isArray(window.Artplayer?.instances) ? window.Artplayer.instances.map(p => p?.hls) : [])]
            .find(controller => controller?.media === video);
        if (hls) {
            const level = hls.levels?.[hls.currentLevel];
            const selected = result(level?.details?.url || hls.url, 'application/vnd.apple.mpegurl');
            if (selected) return selected;
        }
        for (const source of video.querySelectorAll('source[src]')) {
            if (!source.getAttribute('src')?.trim()) continue;
            const selected = result(source.src, source.type);
            if (selected) return selected;
        }
        if (allVideos.length > 1) return null;
        const configured = configuredVideo();
        if (configured) return configured;
        const responses = Array.from(window.__souloObservedMediaResponses || []).reverse();
        for (const response of responses) {
            const mime = String(response?.mime || '').toLowerCase();
            const url = webURL(response?.url);
            if (url && (/mpegurl|video\/(?:mp4|webm|quicktime)/.test(mime)
                || /\.(?:m3u8|mp4|m4v|mov|webm)(?:$|[?#])/i.test(url))) return result(url, mime);
        }
        // Some players clear Resource Timing or receive a generic response
        // MIME type. The request observer still retains their manifest URL.
        const entries = [...(window.__souloObservedResourceURLs || []),
                         ...performance.getEntriesByType('resource').map(entry => entry.name)].reverse();
        for (const entry of entries) {
            const url = webURL(entry);
            if (url && /\.(?:m3u8|mp4|m4v|mov|webm|mpd)(?:$|[?#])/i.test(url)) return result(url);
        }
        return null;
    })();
    """#

    @MainActor
    static func inspect(webView: WKWebView?, frames: [WKFrameInfo] = []) async throws -> WebResourceSnapshot {
        guard let webView, webView.url != nil else {
            throw WebResourceInspectionError.pageUnavailable
        }
        // YouTube changes videos with same-document navigation. Give its live
        // player a short opportunity to publish the response for the new URL;
        // otherwise the document-level globals can still describe the prior video.
        for attempt in 0..<12 {
            let state = try await webView.evaluateCompatibleJavaScript(#"""
            (() => {
                if (typeof window.__souloResolveCurrentYouTubePlayerResponse !== 'function') return -1;
                if (typeof window.__souloCurrentYouTubeVideoID === 'function'
                    && !window.__souloCurrentYouTubeVideoID()) return -1;
                return window.__souloResolveCurrentYouTubePlayerResponse() ? 1 : 0;
            })();
            """#) as? NSNumber
            if state?.intValue != 0 { break }
            if attempt < 11 { try await Task.sleep(for: .milliseconds(100)) }
        }
        let value = try await webView.evaluateCompatibleJavaScript(extractionScript)
        guard let dictionary = value as? [String: Any] else {
            throw WebResourceInspectionError.invalidResult
        }
        WebMediaManifestCache.remember(dictionary["hlsManifests"] as? [String: String] ?? [:], webView: webView)
        var snapshot = WebResourceSnapshot(dictionary: dictionary)
        WebMediaManifestCache.rememberPolicy(dictionary["referrerPolicy"] as? String, urls: snapshot.videos.map(\.url), webView: webView)
        for frame in frames.prefix(16) {
            guard let value = try? await webView.evaluateCompatibleJavaScript(
                extractionScript,
                in: frame,
                contentWorld: .page
            ), let dictionary = value as? [String: Any] else { continue }
            WebMediaManifestCache.remember(dictionary["hlsManifests"] as? [String: String] ?? [:], webView: webView)
            let frameSnapshot = WebResourceSnapshot(dictionary: dictionary)
            WebMediaManifestCache.rememberPolicy(dictionary["referrerPolicy"] as? String, urls: frameSnapshot.videos.map(\.url), webView: webView)
            snapshot = snapshot.mergingMedia(from: frameSnapshot)
        }
        if snapshot.videos.isEmpty, let program = await cctvProgram(in: webView) {
            let video = WebResourceSnapshot(pageTitle: snapshot.pageTitle, pageURL: snapshot.pageURL, images: [],
                videos: [program], audio: [], links: [], textFragments: [], colors: [], documents: [])
            snapshot = snapshot.mergingMedia(from: video)
        }
        return snapshot
    }

    static let extractionScript = #"""
    (function() {
        \#(mediaDOMQuery)
        function absoluteWebURL(value) {
            if (!value) return '';
            try {
                var url = new URL(String(value), document.baseURI).href;
                return /^https?:\/\//i.test(url) ? url : '';
            } catch (_) {
                return '';
            }
        }

        function cleanText(value) {
            return String(value || '').replace(/\s+/g, ' ').trim();
        }

        function currentYouTubeVideoID() {
            try {
                var pageURL = new URL(location.href);
                var host = String(pageURL.hostname || '').toLowerCase();
                if (host.indexOf('www.') === 0) host = host.slice(4);
                var candidate = '';
                if (host === 'youtu.be') {
                    candidate = pageURL.pathname.split('/').filter(Boolean)[0] || '';
                } else if (host === 'youtube.com' || host === 'm.youtube.com') {
                    if (pageURL.pathname === '/watch') {
                        candidate = pageURL.searchParams.get('v') || '';
                    } else {
                        var parts = pageURL.pathname.split('/').filter(Boolean);
                        if (parts.length >= 2 && ['shorts', 'embed', 'live'].indexOf(parts[0]) >= 0) {
                            candidate = parts[1];
                        }
                    }
                }
                return /^[A-Za-z0-9_-]+$/.test(candidate) ? candidate : '';
            } catch (_) {
                return '';
            }
        }

        function isGoogleVideoURL(value) {
            try {
                var host = new URL(String(value || ''), document.baseURI).hostname.toLowerCase();
                return host === 'googlevideo.com' || host.endsWith('.googlevideo.com');
            } catch (_) {
                return false;
            }
        }

        function titleFor(element, fallback) {
            return cleanText(
                (element && (element.getAttribute('aria-label') || element.getAttribute('title') || element.getAttribute('alt')))
                || fallback
                || ''
            ).slice(0, 240);
        }

        function filenameForURL(value) {
            try {
                var name = new URL(value).pathname.split('/').pop() || '';
                return decodeURIComponent(name);
            } catch (_) {
                return '';
            }
        }

        var imageMap = new Map();
        function addImage(value, width, height, title) {
            var url = absoluteWebURL(value);
            if (!url || imageMap.has(url) || imageMap.size >= 400) return;
            imageMap.set(url, {
                url: url,
                width: Math.max(0, Math.round(Number(width) || 0)),
                height: Math.max(0, Math.round(Number(height) || 0)),
                title: cleanText(title || filenameForURL(url)).slice(0, 240)
            });
        }

        Array.from(document.images || []).forEach(function(image) {
            if (!image.complete || image.naturalWidth <= 0 || image.naturalHeight <= 0) return;
            addImage(
                image.currentSrc || image.src,
                image.naturalWidth,
                image.naturalHeight,
                titleFor(image, '')
            );
        });

        Array.from(document.querySelectorAll('body *')).slice(0, 1800).forEach(function(element) {
            try {
                var background = getComputedStyle(element).backgroundImage || '';
                var matches = background.matchAll(/url\(["']?([^"')]+)["']?\)/g);
                for (var match of matches) {
                    var rect = element.getBoundingClientRect();
                    addImage(match[1], rect.width, rect.height, titleFor(element, ''));
                }
            } catch (_) {}
        });

        var videoMap = new Map();
        var configuredVideoURLs = new Set();
        var audioMap = new Map();

        function deliveryForURL(value) {
            var decoded = String(value || '').toLowerCase();
            try { decoded = decodeURIComponent(decoded); } catch (_) {}
            if (/\.m3u8(?:$|[?#])/i.test(decoded)) return 'hls';
            if (/\.mpd(?:$|[?#])/i.test(decoded)) return 'dash';
            try {
                var url = new URL(decoded, document.baseURI);
                var type = String(url.searchParams.get('type') || url.searchParams.get('format') || '').toLowerCase();
                if (type === 'm3u8' || type === 'hls' || type.indexOf('mpegurl') >= 0) return 'hls';
                if (type === 'mpd' || type === 'dash') return 'dash';
            } catch (_) {}
            return 'direct';
        }

        function addMedia(kind, value, title, poster, delivery, audioURL) {
            var url = absoluteWebURL(value);
            if (!url) return;
            var map = kind === 'audio' ? audioMap : videoMap;
            if (map.has(url)) {
                if (delivery && delivery !== 'direct') {
                    var existing = map.get(url);
                    existing.delivery = delivery;
                    if (!existing.title && title) existing.title = cleanText(title).slice(0, 240);
                    if (!existing.poster && poster) existing.poster = absoluteWebURL(poster);
                    if (!existing.audioURL && audioURL) existing.audioURL = absoluteWebURL(audioURL);
                }
                return;
            }
            if (map.size >= 150) return;
            map.set(url, {
                url: url,
                title: cleanText(title || filenameForURL(url)).slice(0, 240),
                poster: kind === 'video' ? absoluteWebURL(poster) : '',
                delivery: delivery || deliveryForURL(url),
                audioURL: kind === 'video' ? absoluteWebURL(audioURL) : ''
            });
        }

        function collectMedia(selector) {
            mediaElements(selector).forEach(function(element) {
                var raw = element.getAttribute('src');
                var emptySource = raw !== null && !raw.trim();
                var values = [emptySource ? '' : element.currentSrc, raw && raw.trim() ? element.src : ''];
                Array.from(element.querySelectorAll('source')).forEach(function(source) {
                    var rawSource = source.getAttribute('src');
                    if (rawSource && rawSource.trim()) values.push(source.src);
                });
                values.forEach(function(value) {
                    addMedia(
                        selector === 'audio' ? 'audio' : 'video',
                        value,
                        titleFor(element, ''),
                        selector === 'video' ? element.poster : ''
                    );
                });
            });
        }

        function mediaKindForURL(value) {
            var raw = String(value || '');
            if (!raw || /^(blob|data):/i.test(raw)) return '';
            var url;
            try { url = new URL(raw, document.baseURI); } catch (_) { return ''; }
            if (!/^https?:$/.test(url.protocol)) return '';
            var path = url.pathname.toLowerCase();
            try { path = decodeURIComponent(path); } catch (_) {}
            var mime = String(
                url.searchParams.get('mime') || url.searchParams.get('mime_type')
                || url.searchParams.get('type') || url.searchParams.get('content-type')
                || url.searchParams.get('content_type') || ''
            ).toLowerCase().replace(/^((?:audio|video))[_-]/, '$1/');
            if (url.searchParams.get('sabr') === '1'
                && !url.searchParams.has('itag')) {
                return '';
            }
            if (mime.indexOf('audio/') === 0
                || /\.(?:mp3|m4a|aac|wav|ogg|oga|opus|flac)$/.test(path)) {
                return 'audio';
            }
            if (mime.indexOf('video/') === 0
                || ['m3u8', 'hls', 'mpd', 'dash'].indexOf(mime) >= 0
                || /\.(?:mp4|m4v|mov|webm|ogv|m3u8|mpd)$/.test(path)
                || /\/videoplayback$/.test(path)
                || /\/video\/tos\//.test(path)
                || /\/aweme\/v1\/(?:web\/)?play/.test(path)
                || url.searchParams.get('is_play_url') === '1') {
                return 'video';
            }
            return '';
        }

        function embeddedMediaURL(value, encoding) {
            var raw = String(value || '').trim();
            if (!raw || raw.length > 8192) return '';
            if (Number(encoding) === 2) {
                try { raw = atob(raw); } catch (_) { return ''; }
            }
            for (var depth = 0; depth < 3; depth++) {
                if (/^https?%3a/i.test(raw)) {
                    try { raw = decodeURIComponent(raw); } catch (_) { return ''; }
                }
                if (mediaKindForURL(raw)) return absoluteWebURL(raw);
                try {
                    var parsed = new URL(raw, document.baseURI);
                    for (var key of ['url', 'src', 'video', 'play', 'playurl', 'file', 'vid']) {
                        var nested = parsed.searchParams.get(key);
                        if (/^https?%3a/i.test(String(nested || ''))) {
                            try { nested = decodeURIComponent(nested); } catch (_) { nested = ''; }
                        }
                        if (nested && mediaKindForURL(nested)) return absoluteWebURL(nested);
                    }
                } catch (_) {}
                try {
                    var decoded = decodeURIComponent(raw);
                    if (decoded === raw) break;
                    raw = decoded;
                } catch (_) { break; }
            }
            return '';
        }

        function collectRuntimeMedia() {
            var youtubeVideoID = currentYouTubeVideoID();
            try {
                Array.from(performance.getEntriesByType('resource') || []).forEach(function(entry) {
                    if (youtubeVideoID && isGoogleVideoURL(entry && entry.name)) return;
                    var kind = mediaKindForURL(entry && entry.name);
                    if (kind) addMedia(kind, entry.name, filenameForURL(entry.name), '');
                });
            } catch (_) {}
            try {
                Array.from(window.__souloObservedResourceURLs || []).forEach(function(value) {
                    if (youtubeVideoID && isGoogleVideoURL(value)) return;
                    var kind = mediaKindForURL(value);
                    if (kind) addMedia(kind, value, filenameForURL(value), '');
                });
            } catch (_) {}
            try {
                Array.from(window.__souloObservedMediaResponses || []).forEach(function(response) {
                    if (!response || youtubeVideoID && isGoogleVideoURL(response.url)) return;
                    var mime = String(response.mime || '').toLowerCase();
                    var kind = mime.indexOf('audio/') === 0 ? 'audio' : 'video';
                    var delivery = mime.indexOf('mpegurl') >= 0 ? 'hls'
                        : mime === 'application/dash+xml' ? 'dash' : 'direct';
                    addMedia(kind, response.url, filenameForURL(response.url), '', delivery);
                });
            } catch (_) {}

            Array.from(document.querySelectorAll('[data-src],[data-url],[data-play-url]')).slice(0, 1200)
                .forEach(function(element) {
                    ['data-src', 'data-url', 'data-play-url'].forEach(function(attribute) {
                        var value = element.getAttribute(attribute);
                        var kind = mediaKindForURL(value);
                        if (kind) addMedia(kind, value, titleFor(element, ''), element.getAttribute('poster'));
                    });
                });
            Array.from(document.querySelectorAll('iframe[src]')).slice(0, 40)
                .forEach(function(frame) {
                    var mediaURL = embeddedMediaURL(frame.getAttribute('src'), 0);
                    if (mediaURL) addMedia('video', mediaURL, titleFor(frame, document.title), '');
                });
        }

        function collectPlayerData(value, hintKind, depth, state) {
            if (depth > 8 || !value || state.visited >= 12000) return;
            state.visited += 1;
            if (typeof value === 'string') {
                var kind = mediaKindForURL(value);
                var isKnownNonMedia = /\.(?:jpe?g|png|gif|webp|avif|svg|css|js|json|html?)(?:$|[?#])/i.test(value);
                if (!kind && hintKind && !isKnownNonMedia) kind = hintKind;
                if (kind && /^https?:\/\//i.test(value)) addMedia(kind, value, '', '');
                return;
            }
            if (typeof value !== 'object') return;
            if (state.objects.has(value)) return;
            state.objects.add(value);
            if (Array.isArray(value)) {
                var items = value.slice(0, 400);
                if (hintKind && items.length > 1 && items.every(function(item) { return typeof item === 'string'; })) {
                    var firstWebURL = items.find(function(item) { return /^https?:\/\//i.test(item); });
                    items = firstWebURL ? [firstWebURL] : items;
                }
                items.forEach(function(item) {
                    collectPlayerData(item, hintKind, depth + 1, state);
                });
                return;
            }
            var objectHint = hintKind;
            var mimeType = cleanText(value.mimeType || value.mime_type || value.type).toLowerCase();
            if (mimeType.indexOf('audio/') === 0) objectHint = 'audio';
            if (mimeType.indexOf('video/') === 0) objectHint = 'video';
            Object.keys(value).slice(0, 300).forEach(function(key) {
                var lowerKey = key.toLowerCase();
                // A media parent can also contain telemetry, profile and app
                // links. Only carry its hint through fields that hold media URLs.
                var nextHint = [
                    'url', 'urls', 'url_list', 'src', 'baseurl', 'base_url',
                    'play_url', 'playurl', 'backup_url', 'backupurl'
                ].indexOf(lowerKey) >= 0 ? objectHint : '';
                if (lowerKey === 'audio') nextHint = 'audio';
                if (lowerKey === 'video'
                    || lowerKey === 'play_addr'
                    || lowerKey === 'playaddr'
                    || lowerKey === 'download_addr'
                    || lowerKey === 'downloadaddr'
                    || lowerKey === 'durl') {
                    nextHint = 'video';
                }
                collectPlayerData(value[key], nextHint, depth + 1, state);
            });
        }

        function collectYouTubeStreamingData(response) {
            if (!response) return false;
            if (typeof response === 'string') {
                try { response = JSON.parse(response); } catch (_) { return false; }
            }
            if (typeof response !== 'object') return false;
            var currentVideoID = currentYouTubeVideoID();
            var responseVideoID = cleanText(response.videoDetails && response.videoDetails.videoId);
            if (currentVideoID && responseVideoID !== currentVideoID) return false;
            var streamingData = response.streamingData;
            if (!streamingData || typeof streamingData !== 'object') return false;

            // Keep the exact response used by the inspector available to the
            // page-bound downloader. On mobile YouTube the public globals can
            // be cleared after the player starts, while the <video> element
            // and the captured SABR request remain visible.
            if (streamingData.serverAbrStreamingUrl
                && Array.isArray(streamingData.adaptiveFormats)
                && streamingData.adaptiveFormats.length) {
                try {
                    window.__souloYouTubePlayerResponses = window.__souloYouTubePlayerResponses || Object.create(null);
                    if (responseVideoID) window.__souloYouTubePlayerResponses[responseVideoID] = response;
                    window.__souloYouTubePlayerResponse = response;
                } catch (_) {}
            }

            var title = cleanText(response.videoDetails && response.videoDetails.title);
            var youtubeDelivery = streamingData.serverAbrStreamingUrl ? 'youtubeSABR' : 'direct';
            var thumbnails = response.videoDetails
                && response.videoDetails.thumbnail
                && response.videoDetails.thumbnail.thumbnails;
            var poster = Array.isArray(thumbnails) && thumbnails.length
                ? thumbnails[thumbnails.length - 1].url
                : '';

            function resolvedURL(format) {
                var mediaURL = format && format.url || '';
                if (mediaURL || !format || !(format.signatureCipher || format.cipher)) return mediaURL;
                try {
                    var cipher = new URLSearchParams(format.signatureCipher || format.cipher);
                    mediaURL = cipher.get('url') || '';
                    var signature = cipher.get('sig') || cipher.get('signature') || '';
                    var encryptedSignature = cipher.get('s') || '';
                    if (mediaURL && signature) {
                        var signedURL = new URL(mediaURL);
                        signedURL.searchParams.set(cipher.get('sp') || 'signature', signature);
                        return signedURL.href;
                    }
                    if (encryptedSignature) return '';
                    return mediaURL;
                } catch (_) {
                    return '';
                }
            }

            var combinedFormats = Array.from(streamingData.formats || []);
            var adaptiveFormats = Array.from(streamingData.adaptiveFormats || []);
            // A result preview can play without changing the document URL.
            // Keep its watch page identity instead of offering its CDN track as the video.
            if (!currentVideoID && youtubeDelivery === 'youtubeSABR'
                && /^https:\/\/(?:www\.|m\.)?youtube\.com$/.test(location.origin)
                && ['/', '/results'].includes(location.pathname)
                && /^[A-Za-z0-9_-]+$/.test(responseVideoID)) {
                var watchURL = new URL('/watch', location.origin);
                watchURL.searchParams.set('v', responseVideoID);
                combinedFormats.concat(adaptiveFormats).forEach(function(format) {
                    var mediaURL = resolvedURL(format);
                    if (isGoogleVideoURL(mediaURL)) videoMap.delete(mediaURL);
                });
                addMedia('video', watchURL.href, title, poster, 'youtubeSABR');
                return true;
            }
            var selectedVideos = combinedFormats;
            if (!selectedVideos.length) {
                var compatibleVideo = adaptiveFormats
                    .filter(function(format) {
                        var mimeType = cleanText(format && format.mimeType).toLowerCase();
                        return mimeType.indexOf('video/mp4') === 0 && mimeType.indexOf('avc1') >= 0;
                    })
                    .sort(function(lhs, rhs) {
                        return (Number(rhs.height) || 0) - (Number(lhs.height) || 0);
                    })[0];
                if (compatibleVideo) selectedVideos = [compatibleVideo];
            }

            var addedVideo = false;
            selectedVideos.forEach(function(format) {
                var mediaURL = resolvedURL(format);
                if (!mediaURL) return;
                var formatTitle = title;
                if (format.qualityLabel) formatTitle += (formatTitle ? ' · ' : '') + format.qualityLabel;
                addMedia('video', mediaURL, formatTitle, poster, youtubeDelivery);
                addedVideo = true;
            });

            // Modern YouTube playback commonly exposes only a SABR endpoint and
            // format metadata. There is no per-format URL to add in that case,
            // but the page-bound SABR downloader can still retrieve both tracks.
            if (!addedVideo && youtubeDelivery === 'youtubeSABR') {
                var pageMediaURL = absoluteWebURL(location.href)
                    || absoluteWebURL(streamingData.serverAbrStreamingUrl);
                if (pageMediaURL) {
                    addMedia('video', pageMediaURL, title, poster, 'youtubeSABR');
                    addedVideo = true;
                }
            }

            var compatibleAudio = adaptiveFormats
                .filter(function(format) {
                    return cleanText(format && format.mimeType).toLowerCase().indexOf('audio/mp4') === 0;
                })
                .sort(function(lhs, rhs) {
                    return (Number(rhs.bitrate) || 0) - (Number(lhs.bitrate) || 0);
                })[0];
            if (compatibleAudio && youtubeDelivery !== 'youtubeSABR') {
                var audioURL = resolvedURL(compatibleAudio);
                if (audioURL) addMedia('audio', audioURL, title, '', youtubeDelivery);
            }
            return addedVideo || !!compatibleAudio;
        }

        function collectYouTubePageFallback() {
            var host = String(location.hostname || '').toLowerCase();
            var isYouTube = host === 'youtube.com'
                || host.endsWith('.youtube.com')
                || host === 'youtu.be';
            if (!isYouTube) return false;

            var path = String(location.pathname || '');
            var isVideoPage = path === '/watch'
                || path.indexOf('/shorts/') === 0
                || host === 'youtu.be';
            if (!isVideoPage) return false;

            var alreadyHasYouTubeVideo = Array.from(videoMap.values()).some(function(resource) {
                if (resource.delivery === 'youtubeSABR') return true;
                try {
                    var resourceHost = new URL(resource.url).hostname.toLowerCase();
                    return resourceHost === 'googlevideo.com'
                        || resourceHost.endsWith('.googlevideo.com');
                } catch (_) {
                    return false;
                }
            });
            if (alreadyHasYouTubeVideo) return true;

            var sabrURL = '';
            var currentVideoID = currentYouTubeVideoID();
            function consider(value) {
                if (sabrURL || !/[?&]sabr=1(?:&|$)/i.test(String(value || ''))) return;
                sabrURL = absoluteWebURL(value);
            }
            try {
                var latestPageSABR = window.__souloLatestPageSABR;
                if (latestPageSABR && latestPageSABR.videoID === currentVideoID) {
                    consider(latestPageSABR.url);
                }
            } catch (_) {}
            // Resource Timing is document-wide and survives YouTube SPA
            // navigation, so it is only safe when no concrete video ID exists.
            if (!currentVideoID) {
                try {
                    Array.from(performance.getEntriesByType('resource') || [])
                        .slice().reverse().forEach(function(entry) { consider(entry && entry.name); });
                } catch (_) {}
                try {
                    Array.from(window.__souloObservedResourceURLs || [])
                        .slice().reverse().forEach(consider);
                } catch (_) {}
            }

            var videoElement = document.querySelector('video');
            if (!sabrURL && !videoElement) return false;
            if (!sabrURL && videoElement.readyState === 0) {
                // An unavailable watch page still renders an empty video element.
                // Keep fallback discovery for playable pages and unknown player states.
                try {
                    var response = window.ytInitialPlayerResponse;
                    if (typeof response === 'string') response = JSON.parse(response);
                    var responseID = response?.videoDetails?.videoId;
                    var status = response?.playabilityStatus?.status;
                    if ((!responseID || responseID === currentVideoID)
                        && ['ERROR', 'UNPLAYABLE', 'LOGIN_REQUIRED', 'AGE_CHECK_REQUIRED', 'LIVE_STREAM_OFFLINE'].includes(status)) return false;
                } catch (_) {}
            }

            var title = cleanText(
                document.querySelector('h1 yt-formatted-string, h1, meta[name="title"]')?.content
                || document.querySelector('h1 yt-formatted-string, h1')?.textContent
                || document.title
            ).replace(/\s*-\s*YouTube\s*$/i, '');
            var poster = videoElement && videoElement.poster || '';
            var pageMediaURL = absoluteWebURL(location.href) || sabrURL;
            if (!pageMediaURL) return false;
            addMedia('video', pageMediaURL, title, poster, 'youtubeSABR');
            return true;
        }

        function collectSeparatedTrackData(response) {
            if (!response) return false;
            if (typeof response === 'string') {
                try { response = JSON.parse(response); } catch (_) { return false; }
            }
            if (typeof response !== 'object') return false;
            var roots = [response, response.data, response.result].filter(Boolean);
            var dash = null;
            for (var root of roots) {
                if (root && root.dash && typeof root.dash === 'object') {
                    dash = root.dash;
                    break;
                }
            }
            if (!dash || !Array.isArray(dash.video) || !Array.isArray(dash.audio)) return false;

            function mediaURL(format) {
                return format && (format.baseUrl || format.base_url || format.url || format.playUrl || '');
            }
            var audio = dash.audio.filter(function(format) { return !!mediaURL(format); })
                .sort(function(lhs, rhs) {
                    return (Number(rhs.bandwidth || rhs.bitrate || rhs.id) || 0)
                        - (Number(lhs.bandwidth || lhs.bitrate || lhs.id) || 0);
                })[0];
            if (!audio) return false;
            var videos = dash.video.filter(function(format) {
                if (!mediaURL(format)) return false;
                var codec = cleanText(format.codecs || format.codec || '').toLowerCase();
                var codecID = Number(format.codecid || format.codec_id || 0);
                if (codec) return codec.indexOf('avc') >= 0 || codec.indexOf('h264') >= 0;
                if (codecID) return codecID === 7;
                return true;
            }).sort(function(lhs, rhs) {
                var left = (Number(lhs.height) || 0) * 100000000 + (Number(lhs.bandwidth || lhs.bitrate) || 0);
                var right = (Number(rhs.height) || 0) * 100000000 + (Number(rhs.bandwidth || rhs.bitrate) || 0);
                return right - left;
            });
            if (!videos.length) return false;
            var video = videos[0];
            var pageTitle = cleanText(document.title);
            var quality = cleanText(video.width && video.height ? video.width + '×' + video.height : '');
            addMedia(
                'video', mediaURL(video),
                pageTitle + (quality ? ' · ' + quality : ''), '',
                'separateTracks', mediaURL(audio)
            );
            return true;
        }

        function collectKnownPlayerData() {
            // An MSE element exposes blob:, while its controller still owns the
            // actual playlist. Prefer that current source over preloaded URLs.
            var controllers = [window.hls];
            try { if (Array.isArray(window.Artplayer?.instances)) window.Artplayer.instances.forEach(function(player) { controllers.push(player.hls); }); } catch (_) {}
            controllers.forEach(function(controller) {
                try {
                    var video = controller?.media;
                    var raw = controller?.url;
                    if (!video?.isConnected || !/^https?:/.test(String(raw || ''))) return;
                    var current = absoluteWebURL(raw);
                    if (!current) return;
                    configuredVideoURLs.add(current);
                    addMedia('video', current, titleFor(video, ''), video.poster, 'hls');
                } catch (_) {}
            });
            // Completed playlist responses provide a MIME-checked fallback for
            // opaque MSE players. Do not infer a stream from an HTML wrapper.
            Object.keys(window.__souloObservedHLSManifests || {}).forEach(function(url) {
                addMedia('video', url, filenameForURL(url), '', 'hls');
            });
            var candidates = [];
            var currentVideoID = currentYouTubeVideoID();
            [window.player_aaaa, window.player_bbbb, window.player_config,
                window.__PLAYER_CONFIG__, window.videoInfo].forEach(function(config) {
                if (!config || typeof config !== 'object') return;
                var mediaURL = embeddedMediaURL(
                    config.url || config.playUrl || config.play_url || config.src,
                    config.encrypt
                );
                if (mediaURL) {
                    configuredVideoURLs.add(mediaURL);
                    addMedia('video', mediaURL, cleanText(config.title || document.title),
                        config.pic || config.poster || '');
                }
                candidates.push(config);
            });
            try {
                if (typeof window.__souloResolveCurrentYouTubePlayerResponse === 'function') {
                    candidates.push(window.__souloResolveCurrentYouTubePlayerResponse());
                }
            } catch (_) {}
            try {
                if (currentVideoID && window.__souloYouTubePlayerResponses) {
                    candidates.push(window.__souloYouTubePlayerResponses[currentVideoID]);
                }
            } catch (_) {}
            try { if (window.__souloYouTubePlayerResponse) candidates.push(window.__souloYouTubePlayerResponse); } catch (_) {}
            try { if (window.ytInitialPlayerResponse) candidates.push(window.ytInitialPlayerResponse); } catch (_) {}
            try { if (window.ytplayer && window.ytplayer.bootstrapPlayerResponse) candidates.push(window.ytplayer.bootstrapPlayerResponse); } catch (_) {}
            try { if (window.ytplayer && window.ytplayer.config && window.ytplayer.config.args) candidates.push(window.ytplayer.config.args.raw_player_response); } catch (_) {}
            try {
                if (typeof window.getInitialData === 'function') {
                    var initialData = window.getInitialData();
                    if (initialData && initialData.playerResponse) candidates.push(initialData.playerResponse);
                }
            } catch (_) {}
            try { if (window.__playinfo__) candidates.push(window.__playinfo__); } catch (_) {}
            try { if (window.__INITIAL_STATE__) candidates.push(window.__INITIAL_STATE__); } catch (_) {}
            try { if (window.__NUXT__) candidates.push(window.__NUXT__); } catch (_) {}
            try { if (window.__APOLLO_STATE__) candidates.push(window.__APOLLO_STATE__); } catch (_) {}
            try { if (window.__PRELOADED_STATE__) candidates.push(window.__PRELOADED_STATE__); } catch (_) {}
            Array.from(document.querySelectorAll('script[type="application/ld+json"], script#__NEXT_DATA__, script#RENDER_DATA'))
                .slice(0, 30)
                .forEach(function(script) {
                    var text = script.textContent || '';
                    if (!text || text.length > 8000000) return;
                    try {
                        if (script.id === 'RENDER_DATA') text = decodeURIComponent(text);
                        candidates.push(JSON.parse(text));
                    } catch (_) {}
                });
            candidates.forEach(function(candidate) {
                var parsedCandidate = candidate;
                if (typeof parsedCandidate === 'string') {
                    try { parsedCandidate = JSON.parse(parsedCandidate); } catch (_) {}
                }
                var candidateVideoID = cleanText(
                    parsedCandidate && parsedCandidate.videoDetails && parsedCandidate.videoDetails.videoId
                );
                if (currentVideoID && candidateVideoID && candidateVideoID !== currentVideoID) return;
                if (!collectYouTubeStreamingData(candidate)) {
                    if (!collectSeparatedTrackData(candidate)) {
                        collectPlayerData(candidate, '', 0, { visited: 0, objects: new WeakSet() });
                    }
                }
            });
        }

        collectMedia('video');
        collectMedia('audio');
        collectRuntimeMedia();
        collectKnownPlayerData();
        collectYouTubePageFallback();

        var linkMap = new Map();
        var documentMap = new Map();
        var documentPattern = /\.(pdf|docx?|xlsx?|pptx?|zip|rar|7z|tar|gz|csv|epub)(?:$|[?#])/i;
        Array.from(document.links || []).forEach(function(anchor) {
            var url = absoluteWebURL(anchor.href);
            if (!url) return;
            var title = cleanText(anchor.innerText || anchor.textContent || anchor.getAttribute('aria-label') || filenameForURL(url)).slice(0, 300);
            if (!linkMap.has(url) && linkMap.size < 800) {
                linkMap.set(url, { url: url, title: title });
            }
            if ((anchor.hasAttribute('download') || documentPattern.test(url)) && !documentMap.has(url) && documentMap.size < 250) {
                documentMap.set(url, { url: url, title: title || filenameForURL(url) });
            }
        });

        var textSet = new Set();
        var texts = [];
        Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,figcaption,td,th,pre,code'))
            .forEach(function(element) {
                if (texts.length >= 700) return;
                var text = cleanText(element.innerText || element.textContent);
                if (text.length < 2 || text.length > 2400 || textSet.has(text)) return;
                textSet.add(text);
                texts.push(text);
            });

        function colorToHex(value) {
            value = String(value || '').trim().toLowerCase();
            if (!value || value === 'transparent') return '';
            var match = value.match(/^rgba?\(\s*(\d+(?:\.\d+)?)\s*[, ]\s*(\d+(?:\.\d+)?)\s*[, ]\s*(\d+(?:\.\d+)?)(?:\s*[,\/]\s*(\d?(?:\.\d+)?))?\s*\)$/i);
            if (!match) return /^#[0-9a-f]{3,8}$/i.test(value) ? value.toUpperCase() : '';
            if (match[4] !== undefined && Number(match[4]) <= 0.02) return '';
            function component(number) {
                return Math.max(0, Math.min(255, Math.round(Number(number)))).toString(16).padStart(2, '0');
            }
            return ('#' + component(match[1]) + component(match[2]) + component(match[3])).toUpperCase();
        }

        var colorCounts = new Map();
        Array.from(document.querySelectorAll('body, body *')).slice(0, 1800).forEach(function(element) {
            try {
                var style = getComputedStyle(element);
                [style.color, style.backgroundColor, style.borderTopColor, style.borderRightColor, style.borderBottomColor, style.borderLeftColor]
                    .forEach(function(value) {
                        var color = colorToHex(value);
                        if (color) colorCounts.set(color, (colorCounts.get(color) || 0) + 1);
                    });
            } catch (_) {}
        });
        var colors = Array.from(colorCounts.entries())
            .map(function(entry) { return { value: entry[0], count: entry[1] }; })
            .sort(function(lhs, rhs) { return rhs.count - lhs.count; })
            .slice(0, 120);

        return {
            pageTitle: cleanText(document.title),
            pageURL: location.href,
            images: Array.from(imageMap.values()),
            videos: Array.from(videoMap.values()),
            configuredVideoURLs: Array.from(configuredVideoURLs),
            hlsManifests: window.__souloObservedHLSManifests || {},
            referrerPolicy: document.referrerPolicy || document.querySelector('meta[name=referrer]')?.content || '',
            audio: Array.from(audioMap.values()),
            links: Array.from(linkMap.values()),
            texts: texts,
            colors: colors,
            documents: Array.from(documentMap.values())
        };
    })();
    """#
}

enum WebResourceMediaService {
    @MainActor private static let thumbnailCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 80
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    @MainActor
    static func asset(
        for resource: WebMediaResource,
        webView: WKWebView?,
        preferDownloadedCopy: Bool = true,
        cacheForPlayback: Bool = false
    ) async -> AVURLAsset {
        if preferDownloadedCopy,
           let downloaded = DownloadManagerService.shared.finishedDownload(for: resource.url) {
            if downloaded.localURL.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
                if let asset = try? OfflineHLSReference.playableAsset(for: downloaded.localURL) {
                    return asset
                }
            } else if downloaded.localURL.pathExtension.lowercased() == "movpkg" {
                if let asset = try? OfflineHLSReference.playablePackage(at: downloaded.localURL) {
                    return asset
                }
            } else {
                return AVURLAsset(url: downloaded.localURL)
            }
        }
        let usePlaybackCache = cacheForPlayback && resource.kind == .video && VideoLoadingStatus.isOnline(resource.url)
            && !(webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? UserDefaults.standard.bool(forKey: "is_incognito"))
        if let normalized = await HLSPlaybackBridge.assetIfNeeded(resource: resource, webView: webView, cacheForPlayback: usePlaybackCache) { return normalized }
        if usePlaybackCache, resource.delivery == .direct {
            let context = await VideoPlaybackRequestContext.load(url: resource.url,
                pageURL: resource.sourcePageURL ?? webView?.url, webView: webView)
            if let asset = await ProgressiveVideoPlaybackBridge.asset(for: resource, context: context) { return asset }
        }
        let options = await networkAssetOptions(for: resource, webView: webView)
        return AVURLAsset(url: resource.url, options: options)
    }

    /// Snapshot credentials once so independent download/player assets use the
    /// same request context without persisting cookies in download history.
    @MainActor
    static func networkAssetOptions(for resource: WebMediaResource, webView: WKWebView?) async -> [String: Any] {
        await networkAssetOptions(for: resource,
                                  cookieStore: webView?.configuration.websiteDataStore.httpCookieStore,
                                  userAgent: webView?.customUserAgent)
    }

    @MainActor
    static func networkAssetOptions(for resource: WebMediaResource, cookieStore: WKHTTPCookieStore?,
                                    userAgent: String? = nil) async -> [String: Any] {
        var options = assetOptions(for: resource)
        if let userAgent, !userAgent.isEmpty {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if let cookieStore {
            let cookies = await WebKitCookieAccess.cookies(for: resource.url, in: cookieStore)
            let matching = WebResourceDownloadService.matchingCookies(from: cookies, for: resource.url)
            if !matching.isEmpty { options[AVURLAssetHTTPCookiesKey] = matching }
        }
        return options
    }

    static func assetOptions(for resource: WebMediaResource) -> [String: Any] {
        var options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: AppConstants.mobileWebViewUserAgent
        ]
        switch resource.delivery {
        case .hls:
            // An MP4 override makes AVFoundation ignore the playlist format.
            if #available(iOS 17.0, *) {
                options[AVURLAssetOverrideMIMETypeKey] = "application/vnd.apple.mpegurl"
            }
        case .direct:
            // Use the server's actual MIME type for MP4, WebM, MOV and
            // extensionless streams. Forcing MP4 can produce audio without video.
            break
        case .dash, .youtubeSABR, .separateTracks:
            break
        }
        return options
    }

    static func isYouTubePageURL(_ url: URL) -> Bool {
        youtubeVideoID(for: url) != nil
    }

    static func isYouTubeCollectionPage(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) else { return false }
        return url.path.isEmpty || url.path == "/" || url.path == "/results"
    }

    static func youtubeEmbedURL(for url: URL) -> URL? {
        guard let videoID = youtubeVideoID(for: url) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(videoID)"
        components.queryItems = [
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "rel", value: "0")
        ]
        return components.url
    }

    static func downloadIdentityURL(
        for resource: WebMediaResource,
        pageURL: URL?
    ) -> URL {
        guard resource.delivery == .youtubeSABR else { return resource.url }
        return [pageURL, resource.url]
            .compactMap { $0 }
            .compactMap { youtubeCanonicalURL(for: $0) }
            .first ?? resource.url
    }

    static func youtubeCanonicalURL(for url: URL) -> URL? {
        guard let videoID = youtubeVideoID(for: url) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/watch"
        components.queryItems = [URLQueryItem(name: "v", value: videoID)]
        return components.url
    }

    static func youtubeVideoID(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let candidate: String?
        if normalizedHost == "youtu.be" {
            candidate = url.pathComponents.dropFirst().first
        } else if normalizedHost == "youtube.com" || normalizedHost == "m.youtube.com" {
            if url.path == "/watch" {
                candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else {
                let components = url.pathComponents.filter { $0 != "/" }
                candidate = components.count >= 2 && ["shorts", "embed", "live"].contains(components[0])
                    ? components[1]
                    : nil
            }
        } else {
            return nil
        }
        guard let candidate,
              !candidate.isEmpty,
              candidate.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0)
                      || CharacterSet(charactersIn: "_-").contains($0)
              }) else { return nil }
        return candidate
    }

    @MainActor
    static func cachedThumbnail(for url: URL) -> UIImage? {
        thumbnailCache.object(forKey: url as NSURL)
    }

    @MainActor
    static func cacheThumbnail(_ image: UIImage, for url: URL) {
        thumbnailCache.setObject(image, forKey: url as NSURL, cost: image.cgImage.map {
            $0.bytesPerRow * $0.height
        } ?? 0)
    }

    @MainActor
    static func pageVideoFrame(in webView: WKWebView?) async -> UIImage? {
        guard let webView else { return nil }
        let script = #"""
        const video = document.querySelector('video');
        if (!video) return null;
        if (video.readyState < 2 || video.videoWidth < 1 || video.videoHeight < 1) {
            await Promise.race([
                new Promise(resolve => video.addEventListener('loadeddata', resolve, { once: true })),
                new Promise(resolve => setTimeout(resolve, 1200))
            ]);
        }
        if (video.readyState < 2 || video.videoWidth < 1 || video.videoHeight < 1) return null;
        await new Promise(resolve => {
            if (typeof video.requestVideoFrameCallback === 'function') {
                let finished = false;
                const timeout = setTimeout(() => {
                    if (!finished) { finished = true; resolve(); }
                }, 500);
                video.requestVideoFrameCallback(() => {
                    if (!finished) { finished = true; clearTimeout(timeout); resolve(); }
                });
            } else {
                requestAnimationFrame(resolve);
            }
        });
        try {
            const maximumWidth = 960;
            const scale = Math.min(1, maximumWidth / video.videoWidth);
            const canvas = document.createElement('canvas');
            canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
            canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
            const context = canvas.getContext('2d', { alpha: false });
            if (!context) return null;
            context.drawImage(video, 0, 0, canvas.width, canvas.height);
            return canvas.toDataURL('image/jpeg', 0.84);
        } catch (_) {
            return null;
        }
        """#

        if let value = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
            in: nil,
            contentWorld: .page
        ), let dataURL = value as? String,
           let image = image(fromDataURL: dataURL) {
            return image
        }

        guard let rectValue = try? await webView.evaluateCompatibleJavaScript(
            """
            (() => {
                const video = document.querySelector('video');
                if (!video) return null;
                const rect = video.getBoundingClientRect();
                return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
            })();
            """
        ), let dictionary = rectValue as? [String: Any],
           let x = (dictionary["x"] as? NSNumber)?.doubleValue,
           let y = (dictionary["y"] as? NSNumber)?.doubleValue,
           let width = (dictionary["width"] as? NSNumber)?.doubleValue,
           let height = (dictionary["height"] as? NSNumber)?.doubleValue,
           width > 1, height > 1 else { return nil }

        let proposedRect = CGRect(x: x, y: y, width: width, height: height)
        let snapshotRect = proposedRect.intersection(webView.bounds)
        guard !snapshotRect.isNull, snapshotRect.width > 1, snapshotRect.height > 1 else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = snapshotRect
        configuration.snapshotWidth = min(snapshotRect.width, 720) as NSNumber
        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func image(fromDataURL value: String) -> UIImage? {
        guard let comma = value.firstIndex(of: ","),
              value[..<comma].lowercased().contains(";base64"),
              let data = Data(base64Encoded: String(value[value.index(after: comma)...])) else {
            return nil
        }
        return UIImage(data: data)
    }
}
