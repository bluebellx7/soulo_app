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
    @MainActor
    static func inspect(webView: WKWebView?) async throws -> WebResourceSnapshot {
        guard let webView, webView.url != nil else {
            throw WebResourceInspectionError.pageUnavailable
        }
        // YouTube changes videos with same-document navigation. Give its live
        // player a short opportunity to publish the response for the new URL;
        // otherwise the document-level globals can still describe the prior video.
        for attempt in 0..<12 {
            let state = try await webView.evaluateJavaScript(#"""
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
        let value = try await webView.evaluateJavaScript(extractionScript)
        guard let dictionary = value as? [String: Any] else {
            throw WebResourceInspectionError.invalidResult
        }
        return WebResourceSnapshot(dictionary: dictionary)
    }

    static let extractionScript = #"""
    (function() {
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
        var audioMap = new Map();

        function deliveryForURL(value) {
            var decoded = String(value || '').toLowerCase();
            try { decoded = decodeURIComponent(decoded); } catch (_) {}
            if (/\.m3u8(?:$|[?#])/i.test(decoded)) return 'hls';
            if (/\.mpd(?:$|[?#])/i.test(decoded)) return 'dash';
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
            Array.from(document.querySelectorAll(selector)).forEach(function(element) {
                var values = [element.currentSrc, element.src];
                Array.from(element.querySelectorAll('source')).forEach(function(source) {
                    values.push(source.src || source.getAttribute('src'));
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
            var decoded = raw;
            try { decoded = decodeURIComponent(raw); } catch (_) {}
            decoded = decoded.toLowerCase();
            if (/[?&]sabr=1(?:&|$)/i.test(decoded)
                && !/[?&]itag=\d+(?:&|$)/i.test(decoded)) {
                return '';
            }
            if (/[?&](?:mime|type|content[-_]?type)=audio(?:%2f|\/)/i.test(raw)
                || /[?&](?:mime|type|content[-_]?type)=audio\//i.test(decoded)
                || /[?&](?:mime|mime_type|type|content[-_]?type)=audio[_-](?:mp4|mpeg|aac|ogg|webm)(?:&|$)/i.test(decoded)
                || /\.(?:mp3|m4a|aac|wav|ogg|oga|opus|flac)(?:$|[?#])/i.test(decoded)) {
                return 'audio';
            }
            if (/[?&](?:mime|type|content[-_]?type)=video(?:%2f|\/)/i.test(raw)
                || /[?&](?:mime|type|content[-_]?type)=video\//i.test(decoded)
                || /[?&](?:mime|mime_type|type|content[-_]?type)=video[_-](?:mp4|webm|quicktime)(?:&|$)/i.test(decoded)
                || /\.(?:mp4|m4v|mov|webm|ogv|m3u8|mpd)(?:$|[?#])/i.test(decoded)
                || /\/videoplayback(?:$|[?#])/i.test(decoded)
                || /\/video\/tos\//i.test(decoded)
                || /\/aweme\/v1\/(?:web\/)?play/i.test(decoded)
                || /[?&]is_play_url=1(?:&|$)/i.test(decoded)) {
                return 'video';
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

            Array.from(document.querySelectorAll('[data-src],[data-url],[data-play-url]')).slice(0, 1200)
                .forEach(function(element) {
                    ['data-src', 'data-url', 'data-play-url'].forEach(function(attribute) {
                        var value = element.getAttribute(attribute);
                        var kind = mediaKindForURL(value);
                        if (kind) addMedia(kind, value, titleFor(element, ''), element.getAttribute('poster'));
                    });
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
                var nextHint = objectHint;
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
            var candidates = [];
            var currentVideoID = currentYouTubeVideoID();
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
        webView: WKWebView?
    ) async -> AVURLAsset {
        if let downloaded = DownloadManagerService.shared.finishedDownload(for: resource.url) {
            return AVURLAsset(url: downloaded.localURL)
        }
        var options: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: AppConstants.mobileWebViewUserAgent,
            AVURLAssetOverrideMIMETypeKey: resource.kind == .video ? "video/mp4" : "audio/mp4"
        ]
        guard let webView else {
            return AVURLAsset(url: resource.url, options: options)
        }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
        let matchingCookies = WebResourceDownloadService.matchingCookies(
            from: cookies,
            for: resource.url
        )
        if !matchingCookies.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = matchingCookies
        }
        return AVURLAsset(url: resource.url, options: options)
    }

    static func isYouTubePageURL(_ url: URL) -> Bool {
        youtubeVideoID(for: url) != nil
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

        guard let rectValue = try? await webView.evaluateJavaScript(
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
