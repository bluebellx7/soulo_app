import Foundation
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

        function collectMedia(selector, limit) {
            var map = new Map();
            Array.from(document.querySelectorAll(selector)).forEach(function(element) {
                var values = [element.currentSrc, element.src];
                Array.from(element.querySelectorAll('source')).forEach(function(source) {
                    values.push(source.src || source.getAttribute('src'));
                });
                values.forEach(function(value) {
                    var url = absoluteWebURL(value);
                    if (!url || map.has(url) || map.size >= limit) return;
                    map.set(url, {
                        url: url,
                        title: titleFor(element, filenameForURL(url)),
                        poster: selector === 'video' ? absoluteWebURL(element.poster) : ''
                    });
                });
            });
            return Array.from(map.values());
        }

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
            videos: collectMedia('video', 150),
            audio: collectMedia('audio', 150),
            links: Array.from(linkMap.values()),
            texts: texts,
            colors: colors,
            documents: Array.from(documentMap.values())
        };
    })();
    """#
}
