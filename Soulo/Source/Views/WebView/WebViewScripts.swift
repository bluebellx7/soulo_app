import Foundation

enum WebViewScripts {
    /// WKWebView.pageZoom scales the document relative to the web view bounds,
    /// which can make the root document wider than the visible viewport. Keep
    /// the rendered page pinned to the device width while allowing all page
    /// content (text, images, controls, and spacing) to scale together.
    static func compensatePageZoomWidth(scale: CGFloat) -> String {
        let normalizedScale = min(max(scale, 0.5), 2)
        let scaleLiteral = String(format: "%.5f", Double(normalizedScale))
        return """
        (function() {
            var root = document.documentElement;
            if (!root) return;

            var scale = \(scaleLiteral);
            var stateKey = '__souloPageZoomWidthState';
            var state = window[stateKey];
            if (!state || state.element !== root) {
                state = {
                    element: root,
                    width: root.style.getPropertyValue('width'),
                    widthPriority: root.style.getPropertyPriority('width'),
                    minWidth: root.style.getPropertyValue('min-width'),
                    minWidthPriority: root.style.getPropertyPriority('min-width'),
                    maxWidth: root.style.getPropertyValue('max-width'),
                    maxWidthPriority: root.style.getPropertyPriority('max-width')
                };
                window[stateKey] = state;
            }

            function restore(property, value, priority) {
                if (value) root.style.setProperty(property, value, priority || '');
                else root.style.removeProperty(property);
            }

            if (Math.abs(scale - 1) < 0.001) {
                restore('width', state.width, state.widthPriority);
                restore('min-width', state.minWidth, state.minWidthPriority);
                restore('max-width', state.maxWidth, state.maxWidthPriority);
                delete window[stateKey];
                return;
            }

            root.style.setProperty('width', (100 / scale).toFixed(5) + '%', 'important');
            root.style.setProperty('min-width', '0', 'important');
            root.style.setProperty('max-width', 'none', 'important');
        })();
        """
    }

    static let synchronizeViewport = """
    (function() {
        var height = window.visualViewport ? window.visualViewport.height : window.innerHeight;
        var width = window.visualViewport ? window.visualViewport.width : window.innerWidth;
        if (document.documentElement) {
            document.documentElement.style.setProperty('--soulo-viewport-height', Math.round(height) + 'px');
            document.documentElement.style.setProperty('--soulo-viewport-width', Math.round(width) + 'px');
        }
        try { window.dispatchEvent(new Event('resize')); } catch (_) {}
        try { window.dispatchEvent(new Event('orientationchange')); } catch (_) {}
        try {
            if (window.visualViewport) window.visualViewport.dispatchEvent(new Event('resize'));
        } catch (_) {}
    })();
    """

    static let webAppearanceBootstrap = """
    (function() {
        if (window.__souloApplyWebAppearance) return;
        var originalStyles = new Map();
        var observer = null;
        var scanTimer = null;

        function luminance(color) {
            var match = String(color || '').match(/rgba?\\((\\d+)[, ]+(\\d+)[, ]+(\\d+)/i);
            if (!match) return null;
            return (Number(match[1]) * 0.2126 + Number(match[2]) * 0.7152 + Number(match[3]) * 0.0722) / 255;
        }

        function remember(element) {
            if (originalStyles.has(element)) return;
            originalStyles.set(element, {
                background: element.style.getPropertyValue('background-color'),
                backgroundPriority: element.style.getPropertyPriority('background-color'),
                color: element.style.getPropertyValue('color'),
                colorPriority: element.style.getPropertyPriority('color'),
                border: element.style.getPropertyValue('border-color'),
                borderPriority: element.style.getPropertyPriority('border-color')
            });
        }

        function darken(root) {
            if (!root || !root.querySelectorAll) return;
            var elements = [root].concat(Array.prototype.slice.call(root.querySelectorAll('*'), 0, 2800));
            elements.forEach(function(element) {
                if (!element || /^(IMG|VIDEO|CANVAS|SVG|PICTURE|IFRAME|SOURCE)$/.test(element.tagName || '')) return;
                var style;
                try { style = getComputedStyle(element); } catch (_) { return; }
                var background = luminance(style.backgroundColor);
                var foreground = luminance(style.color);
                var border = luminance(style.borderColor);
                if ((background !== null && background > 0.78) || (foreground !== null && foreground < 0.25) || (border !== null && border > 0.72)) {
                    remember(element);
                    if (background !== null && background > 0.78) {
                        element.style.setProperty('background-color', background > 0.94 ? '#111113' : '#1c1c1f', 'important');
                    }
                    if (foreground !== null && foreground < 0.25) {
                        element.style.setProperty('color', '#e7e7eb', 'important');
                    }
                    if (border !== null && border > 0.72) {
                        element.style.setProperty('border-color', '#3a3a3f', 'important');
                    }
                }
            });
        }

        function restore() {
            originalStyles.forEach(function(value, element) {
                if (!element || !element.style) return;
                if (value.background) element.style.setProperty('background-color', value.background, value.backgroundPriority);
                else element.style.removeProperty('background-color');
                if (value.color) element.style.setProperty('color', value.color, value.colorPriority);
                else element.style.removeProperty('color');
                if (value.border) element.style.setProperty('border-color', value.border, value.borderPriority);
                else element.style.removeProperty('border-color');
            });
            originalStyles.clear();
        }

        function setWarmOverlay(enabled) {
            var overlay = document.getElementById('soulo-warm-color-overlay');
            if (!enabled) {
                if (overlay) overlay.remove();
                return;
            }
            if (!document.documentElement || overlay) return;
            overlay = document.createElement('div');
            overlay.id = 'soulo-warm-color-overlay';
            overlay.setAttribute('aria-hidden', 'true');
            overlay.style.cssText = 'position:fixed;inset:0;pointer-events:none;background:rgba(255,154,61,.055);mix-blend-mode:multiply;z-index:2147483646;';
            document.documentElement.appendChild(overlay);
        }

        function observeDarkContent(enabled) {
            if (observer) { observer.disconnect(); observer = null; }
            if (!enabled || !document.documentElement) return;
            observer = new MutationObserver(function(mutations) {
                clearTimeout(scanTimer);
                scanTimer = setTimeout(function() {
                    mutations.forEach(function(mutation) {
                        Array.prototype.forEach.call(mutation.addedNodes || [], function(node) {
                            if (node.nodeType === 1) darken(node);
                        });
                    });
                }, 120);
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });
        }

        window.__souloApplyWebAppearance = function(config) {
            config = config || {};
            var forceDark = !!config.forceDark;
            if (document.documentElement) {
                document.documentElement.classList.toggle('soulo-force-dark', forceDark);
                document.documentElement.style.setProperty('color-scheme', forceDark ? 'dark' : '', forceDark ? 'important' : '');
                if (forceDark) {
                    document.documentElement.style.setProperty('background-color', '#0b0b0d', 'important');
                    darken(document.documentElement);
                } else {
                    document.documentElement.style.removeProperty('background-color');
                    restore();
                }
            }
            setWarmOverlay(!!config.warmColorShift);
            observeDarkContent(forceDark);
        };
    })();
    """

    static func applyWebAppearance(warmColorShift: Bool, forceDark: Bool) -> String {
        """
        \(webAppearanceBootstrap)
        window.__souloApplyWebAppearance && window.__souloApplyWebAppearance({
            warmColorShift: \(warmColorShift ? "true" : "false"),
            forceDark: \(forceDark ? "true" : "false")
        });
        """
    }

    /// Adds conservative ARIA metadata to third-party pages without changing
    /// their layout or click behavior. Search engines frequently render result
    /// cards as generic containers, which makes direct-touch navigation vague
    /// or skips the card entirely in VoiceOver.
    static let accessibilityEnhancements = """
    (function() {
        if (window.__souloAccessibilityInstalled) {
            if (typeof window.__souloAccessibilityScan === 'function') {
                window.__souloAccessibilityScan();
            }
            return;
        }
        window.__souloAccessibilityInstalled = true;

        function visible(element) {
            if (!element || !element.getBoundingClientRect) return false;
            var style = window.getComputedStyle(element);
            if (style.display === 'none' || style.visibility === 'hidden') return false;
            var rect = element.getBoundingClientRect();
            return rect.width > 1 && rect.height > 1;
        }

        function cleanText(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
        }

        function accessibleName(element) {
            if (!element) return '';
            var explicit = cleanText(
                element.getAttribute('aria-label') ||
                element.getAttribute('title') ||
                element.getAttribute('alt')
            );
            if (explicit) return explicit;
            var labelledBy = element.getAttribute('aria-labelledby');
            if (labelledBy) {
                var labelledText = labelledBy.split(/\\s+/).map(function(identifier) {
                    var label = document.getElementById(identifier);
                    return label ? cleanText(label.innerText || label.textContent) : '';
                }).filter(Boolean).join(' ');
                if (labelledText) return labelledText;
            }
            var image = element.querySelector && element.querySelector('img[alt]');
            var text = cleanText(element.innerText || element.textContent);
            return text || (image ? cleanText(image.getAttribute('alt')) : '');
        }

        function labelInteractiveElements(root) {
            var elements = root.querySelectorAll(
                'a[href], button, input, select, textarea, [role="button"], [role="link"]'
            );
            Array.prototype.forEach.call(elements, function(element) {
                if (!visible(element) || accessibleName(element)) return;
                var icon = element.querySelector && element.querySelector('img[alt], svg[aria-label]');
                var name = icon && cleanText(
                    icon.getAttribute('alt') || icon.getAttribute('aria-label')
                );
                if (name) element.setAttribute('aria-label', name);
            });
        }

        function markResultCards(root) {
            var selectors = [
                'article', '[role="article"]',
                '.search-result', '[class*="search-result"]',
                '[data-testid*="result"]'
            ];
            var host = String(location.hostname || '').toLowerCase();
            var path = String(location.pathname || '').toLowerCase();
            if (host.indexOf('google.') >= 0) selectors.push('.g', '[data-snhf="0"]');
            if (host.indexOf('bing.com') >= 0) selectors.push('.b_algo');
            if (/search|result|query/.test(path)) selectors.push('.result');
            var cards;
            try { cards = root.querySelectorAll(selectors.join(',')); } catch (_) { return; }
            Array.prototype.forEach.call(cards, function(card) {
                if (!visible(card) || card.hasAttribute('aria-label')) return;
                var primary = card.querySelector('h1, h2, h3, [role="heading"], a[href]');
                var label = accessibleName(primary);
                if (!label) return;
                if (!card.hasAttribute('role') && card.tagName !== 'ARTICLE') {
                    card.setAttribute('role', 'group');
                }
                card.setAttribute('aria-label', label);
                card.setAttribute('data-soulo-accessible-result', 'true');
            });
        }

        function markResultHeadings(root) {
            var selectors = [
                '.g h3', '.b_algo h2', '.result h2', '.result h3',
                '.search-result h2', '.search-result h3',
                '[class*="search-result"] h2', '[class*="search-result"] h3'
            ];
            var headings;
            try { headings = root.querySelectorAll(selectors.join(',')); } catch (_) { return; }
            Array.prototype.forEach.call(headings, function(heading) {
                if (!visible(heading)) return;
                if (!heading.hasAttribute('role')) heading.setAttribute('role', 'heading');
                if (!heading.hasAttribute('aria-level')) heading.setAttribute('aria-level', '2');
            });
        }

        function markClickableContainers(root) {
            var elements = root.querySelectorAll('[onclick]:not(a):not(button):not(input)');
            Array.prototype.forEach.call(elements, function(element) {
                if (!visible(element) || element.hasAttribute('role')) return;
                var name = accessibleName(element);
                if (!name || name.length > 180) return;
                element.setAttribute('role', 'button');
                element.setAttribute('tabindex', '0');
                element.setAttribute('aria-label', name);
            });
        }

        window.__souloAccessibilityScan = function() {
            var root = document;
            labelInteractiveElements(root);
            markResultCards(root);
            markResultHeadings(root);
            markClickableContainers(root);
        };

        window.__souloAccessibilityScan();

        function installObserver() {
            if (!document.body || window.__souloAccessibilityObserver) return;
            window.__souloAccessibilityObserver = new MutationObserver(function(mutations) {
                var hasAddedContent = mutations.some(function(mutation) {
                    return mutation.addedNodes && mutation.addedNodes.length > 0;
                });
                if (!hasAddedContent) return;
                clearTimeout(window.__souloAccessibilityTimer);
                window.__souloAccessibilityTimer = setTimeout(function() {
                    window.__souloAccessibilityScan();
                }, 300);
            });
            window.__souloAccessibilityObserver.observe(document.body, {
                childList: true,
                subtree: true
            });
        }

        installObserver();
        if (!document.body) {
            document.addEventListener('DOMContentLoaded', installObserver, { once: true });
        }
    })();
    """

    static let blankPageProbe = """
    (function() {
        var body = document.body;
        var text = body ? String(body.innerText || body.textContent || '').replace(/\\s+/g, '') : '';
        var visibleElementCount = 0;
        var ignoredTags = { SCRIPT: true, STYLE: true, LINK: true, META: true, NOSCRIPT: true, TEMPLATE: true };
        if (body) {
            var elements = body.getElementsByTagName('*');
            for (var i = 0; i < elements.length && i < 800; i++) {
                var el = elements[i];
                if (ignoredTags[el.tagName]) continue;
                var style = window.getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden' || parseFloat(style.opacity || '1') === 0) continue;
                var rect = el.getBoundingClientRect();
                if (rect.width > 1 && rect.height > 1) {
                    visibleElementCount++;
                    if (visibleElementCount > 0) break;
                }
            }
        }
        return {
            readyState: document.readyState,
            titleLength: String(document.title || '').trim().length,
            textLength: text.length,
            bodyChildCount: body ? body.children.length : 0,
            bodyHTMLLength: body ? body.innerHTML.length : 0,
            visibleElementCount: visibleElementCount,
            location: location.href
        };
    })();
    """

    /// Captures files created inside the page, which WKDownload cannot reliably
    /// receive because blob: and data: URLs do not have a network response.
    static let extensionInstallBridge = """
    (function() {
        if (window.__souloExtensionInstallBridgeInstalled) return;
        window.__souloExtensionInstallBridgeInstalled = true;

        function chromeExtensionID() {
            if (location.hostname !== 'chromewebstore.google.com') return null;
            var segments = location.pathname.split('/').filter(Boolean);
            for (var index = segments.length - 1; index >= 0; index--) {
                if (/^[a-p]{32}$/i.test(segments[index])) return segments[index].toLowerCase();
            }
            return null;
        }

        document.addEventListener('click', function(event) {
            var target = event.target;
            if (target && target.nodeType !== 1) target = target.parentElement;
            var control = target && target.closest ? target.closest('button, a, [role="button"]') : null;
            if (!control) return;

            var extensionID = chromeExtensionID();
            if (!extensionID) return;
            var label = String(
                control.innerText || control.textContent || control.getAttribute('aria-label') || ''
            ).replace(/\\s+/g, ' ').trim().toLowerCase();
            var installLabel = /add to chrome|add extension|安装|添加至?\\s*chrome|添加扩展|获取/.test(label);
            if (!installLabel) return;

            var handler = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.souloExtensionInstaller;
            if (!handler) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            handler.postMessage({ provider: 'chrome', extensionID: extensionID });
        }, true);
    })();
    """

    static let downloadBridge = """
    (function() {
        if (window.__souloDownloadBridgeInstalled) return;
        window.__souloDownloadBridgeInstalled = true;

        var activeDownloads = Object.create(null);
        var chunkSize = 256 * 1024;
        var maximumGeneratedFileSize = 256 * 1024 * 1024;

        function post(payload) {
            try {
                var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.souloDownload;
                if (!handler) return Promise.reject(new Error('native download handler unavailable'));
                return Promise.resolve(handler.postMessage(payload));
            } catch (error) {
                return Promise.reject(error);
            }
        }

        function normalizedFilename(value) {
            var name = String(value || '').trim();
            if (!name) return 'Download';
            try { name = decodeURIComponent(name); } catch (_) {}
            return name.split('/').pop() || 'Download';
        }

        function filenameFor(anchor, href) {
            var explicitName = anchor && (anchor.getAttribute('download') || anchor.download);
            if (explicitName) return normalizedFilename(explicitName);
            try {
                var pathname = new URL(href, location.href).pathname;
                var candidate = pathname.split('/').pop();
                if (candidate) return normalizedFilename(candidate);
            } catch (_) {}
            return 'Download';
        }

        function downloadID() {
            if (window.crypto && typeof window.crypto.randomUUID === 'function') {
                return window.crypto.randomUUID();
            }
            return String(Date.now()) + '-' + Math.random().toString(36).slice(2);
        }

        function readSlice(blob) {
            return new Promise(function(resolve, reject) {
                var reader = new FileReader();
                reader.onload = function() { resolve(reader.result); };
                reader.onerror = function() { reject(reader.error || new Error('read failed')); };
                reader.readAsArrayBuffer(blob);
            });
        }

        function base64ForArrayBuffer(buffer) {
            var bytes = new Uint8Array(buffer);
            var binary = '';
            var batchSize = 0x8000;
            for (var offset = 0; offset < bytes.length; offset += batchSize) {
                var batch = bytes.subarray(offset, Math.min(offset + batchSize, bytes.length));
                binary += String.fromCharCode.apply(null, batch);
            }
            return btoa(binary);
        }

        window.__souloCancelDownloads = function() {
            Object.keys(activeDownloads).forEach(function(identifier) {
                activeDownloads[identifier] = false;
            });
        };

        async function exportURL(href, filename) {
            filename = normalizedFilename(filename);
            var identifier = downloadID();
            activeDownloads[identifier] = true;

            try {
                await post({
                    type: 'started',
                    downloadID: identifier,
                    filename: filename,
                    sourceURL: location.href
                });

                var response = await fetch(href);
                var blob = await response.blob();
                if (blob.size > maximumGeneratedFileSize) throw new Error('file too large');

                var chunkIndex = 0;
                for (var offset = 0; offset < blob.size; offset += chunkSize) {
                    if (!activeDownloads[identifier]) throw new Error('download canceled');
                    var buffer = await readSlice(blob.slice(offset, Math.min(offset + chunkSize, blob.size)));
                    if (!activeDownloads[identifier]) throw new Error('download canceled');
                    await post({
                        type: 'chunk',
                        downloadID: identifier,
                        index: chunkIndex,
                        base64: base64ForArrayBuffer(buffer)
                    });
                    chunkIndex += 1;
                }

                if (!activeDownloads[identifier]) throw new Error('download canceled');
                await post({
                    type: 'finished',
                    downloadID: identifier,
                    chunkCount: chunkIndex
                });
            } catch (error) {
                try {
                    await post({
                        type: 'failed',
                        downloadID: identifier,
                        filename: filename,
                        message: String(error || '')
                    });
                } catch (_) {}
            } finally {
                delete activeDownloads[identifier];
            }
        }

        document.addEventListener('click', function(event) {
            var target = event.target;
            if (target && target.nodeType !== 1) target = target.parentElement;
            var anchor = target && target.closest ? target.closest('a[href]') : null;
            if (!anchor) return;

            var href = String(anchor.href || anchor.getAttribute('href') || '');
            var isGeneratedFile = href.indexOf('blob:') === 0 || href.indexOf('data:') === 0;
            if (!isGeneratedFile) return;

            event.preventDefault();
            event.stopImmediatePropagation();
            exportURL(href, filenameFor(anchor, href));
        }, true);
    })();
    """

    static func privacyProtection(gpcEnabled: Bool, cookieBannerHandling: Bool, disabledHosts: [String] = []) -> String {
        let disabledHostsJSON = (try? JSONSerialization.data(withJSONObject: disabledHosts))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
            var souloGPCEnabled = \(gpcEnabled ? "true" : "false");
            var souloCookieBannerHandling = \(cookieBannerHandling ? "true" : "false");
            var souloDisabledHosts = \(disabledHostsJSON);
            window.__souloPrivacyConfig = {
                gpcEnabled: souloGPCEnabled,
                cookieBannerHandling: souloCookieBannerHandling,
                disabledHosts: souloDisabledHosts
            };

            function normalizedHost(value) {
                return String(value || '').toLowerCase().replace(/^www\\./, '');
            }

            function domainMatches(pattern, host) {
                pattern = normalizedHost(String(pattern || '').replace(/^\\*/, ''));
                host = normalizedHost(host);
                if (!pattern) return false;
                return host === pattern || host.endsWith('.' + pattern);
            }

            function privacyConfig() {
                return window.__souloPrivacyConfig || {
                    gpcEnabled: souloGPCEnabled,
                    cookieBannerHandling: souloCookieBannerHandling,
                    disabledHosts: souloDisabledHosts
                };
            }

            function siteProtectionDisabled() {
                var host = normalizedHost(location.hostname);
                return (privacyConfig().disabledHosts || []).some(function(domain) { return domainMatches(domain, host); });
            }

            function isSensitiveChallengePage() {
                return /(^|[\\/?&#_=.-])(captcha|wappoc|verify|verification|challenge|security|passport|login|auth)([\\/?&#_=.-]|$)/.test(String(location.href || '').toLowerCase());
            }

            if (siteProtectionDisabled() || isSensitiveChallengePage()) return;

            if (privacyConfig().gpcEnabled) {
                try {
                    Object.defineProperty(navigator, 'globalPrivacyControl', {
                        value: true,
                        configurable: true
                    });
                } catch (_) {}
            }

            if (window.__souloPrivacyProtectionInstalled) {
                if (typeof window.__souloPrivacyScan === 'function') {
                    window.__souloPrivacyScan();
                }
                return;
            }
            window.__souloPrivacyProtectionInstalled = true;

            function postPrivacyMessage(payload) {
                if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.souloPrivacy) return;
                try {
                    payload.host = location.hostname;
                    window.webkit.messageHandlers.souloPrivacy.postMessage(payload);
                } catch (_) {}
            }

            function hostFromURL(value) {
                try {
                    return new URL(value, location.href).hostname;
                } catch (_) {
                    return '';
                }
            }

            function resourceTypeForElement(el) {
                var tag = String(el.tagName || '').toLowerCase();
                if (tag === 'script') return 'script';
                if (tag === 'iframe') return 'document';
                if (tag === 'img') return 'image';
                if (tag === 'link') {
                    var rel = String(el.rel || '').toLowerCase();
                    if (rel.indexOf('stylesheet') >= 0) return 'stylesheet';
                    if (rel.indexOf('icon') >= 0) return 'image';
                    return 'raw';
                }
                if (tag === 'source' || tag === 'video' || tag === 'audio' || tag === 'track') return 'media';
                if (tag === 'embed' || tag === 'object') return 'document';
                return 'raw';
            }

            function resourceURLForElement(el) {
                var tag = String(el.tagName || '').toLowerCase();
                if (tag === 'object') return el.data || '';
                return el.currentSrc || el.src || el.href || el.data || '';
            }

            function scanTrackers() {
                if (siteProtectionDisabled()) return;
                var hosts = [];
                var observations = [];
                var seen = Object.create(null);
                var selector = [
                    'script[src]',
                    'iframe[src]',
                    'img[src]',
                    'link[href][rel~="stylesheet"]',
                    'link[href][rel~="preload"]',
                    'link[href][rel~="preconnect"]',
                    'link[href][rel~="dns-prefetch"]',
                    'source[src]',
                    'video[src]',
                    'audio[src]',
                    'track[src]',
                    'embed[src]',
                    'object[data]'
                ].join(',');
                try {
                    var elements = document.querySelectorAll(selector);
                    for (var i = 0; i < elements.length && observations.length < 120; i++) {
                        var el = elements[i];
                        var value = resourceURLForElement(el);
                        var host = hostFromURL(value);
                        if (!host || domainMatches(host, location.hostname)) continue;
                        var absoluteURL = '';
                        try {
                            absoluteURL = new URL(value, location.href).href;
                        } catch (_) {
                            continue;
                        }
                        var key = absoluteURL + '|' + location.href;
                        if (seen[key]) continue;
                        seen[key] = true;
                        hosts.push(normalizedHost(host));
                        observations.push({
                            url: absoluteURL,
                            resourceType: resourceTypeForElement(el),
                            potentiallyBlocked: true,
                            pageUrl: location.href
                        });
                    }
                } catch (_) {}
                hosts = Array.from(new Set(hosts)).slice(0, 80);
                if (hosts.length > 0 || observations.length > 0) {
                    postPrivacyMessage({
                        type: 'resourceObserved',
                        trackerHosts: hosts,
                        observations: observations
                    });
                }
            }

            function textOf(el) {
                return String((el && el.textContent) || '').toLowerCase().replace(/\\s+/g, ' ').trim();
            }

            function isProtectedPageElement(el) {
                try {
                    if (!el || el === document.body || el === document.documentElement) return true;
                    var tag = String(el.tagName || '').toLowerCase();
                    if (tag === 'main' || tag === 'article') return true;

                    var id = String(el.id || '').toLowerCase();
                    var role = String(el.getAttribute('role') || '').toLowerCase();
                    if (/^(app|root|__next|__nuxt|main|content|page|container|results|lg_wrapper)$/.test(id) || role === 'main') return true;

                    var rect = el.getBoundingClientRect();
                    var textLength = String(el.innerText || el.textContent || '').replace(/\\s+/g, '').length;
                    var linkCount = el.querySelectorAll ? el.querySelectorAll('a').length : 0;
                    var coversViewport = rect.width > window.innerWidth * 0.86 && rect.height > window.innerHeight * 0.6;
                    var topLevelContent = el.parentElement === document.body && rect.width > window.innerWidth * 0.7 && rect.height > window.innerHeight * 0.35;
                    if ((coversViewport || topLevelContent) && (textLength > 120 || linkCount > 6)) return true;
                } catch (_) {}
                return false;
            }

            function hasCookieConsentLanguage(text) {
                text = String(text || '').toLowerCase();
                var hasCookieWord = /cookie|cookies|gdpr|ccpa/.test(text);
                var hasConsentWord = /consent|agree|accept|reject|decline|deny|preferences|necessary|同意|接受|允许|拒绝|不同意|必要|偏好|設定|设置|拒絕/.test(text);
                var hasPrivacyWord = /privacy|隐私|隱私/.test(text);
                return hasCookieWord || (hasPrivacyWord && hasConsentWord);
            }

            function isOverlayLike(el) {
                try {
                    var style = window.getComputedStyle(el);
                    var position = style.position;
                    var zIndex = parseInt(style.zIndex, 10) || 0;
                    var rect = el.getBoundingClientRect();
                    if (rect.width <= 160 || rect.height <= 40) return false;
                    if (position === 'fixed' || position === 'sticky') return true;
                    if (position === 'absolute' && zIndex >= 100) return true;
                    var role = String(el.getAttribute('role') || '').toLowerCase();
                    if (role === 'dialog' || el.tagName === 'DIALOG') return true;
                } catch (_) {}
                return false;
            }

            function clickRejectButton(root) {
                var buttons = Array.prototype.slice.call(root.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"], a'));
                var rejectPatterns = [
                    'reject', 'decline', 'deny', 'necessary only', 'essential only',
                    '拒绝', '不同意', '仅必要', '必要 cookie', '必要cookies',
                    '拒絕', '不同意', '必要'
                ];
                for (var i = 0; i < buttons.length; i++) {
                    var label = textOf(buttons[i]) || String(buttons[i].value || '').toLowerCase();
                    if (rejectPatterns.some(function(pattern) { return label.indexOf(pattern) >= 0; })) {
                        try {
                            buttons[i].click();
                            return true;
                        } catch (_) {}
                    }
                }
                return false;
            }

            function isCookieBanner(el) {
                try {
                    if (!el || isProtectedPageElement(el)) return false;
                    var text = textOf(el);
                    if (text.length > 1400) return false;
                    if (!hasCookieConsentLanguage(text)) return false;
                    return isOverlayLike(el);
                } catch (_) {
                    return false;
                }
            }

            function handleCookieBanners() {
                if (siteProtectionDisabled() || !privacyConfig().cookieBannerHandling) return;
                var handled = 0;
                var selectors = [
                    '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.ot-sdk-container',
                    '#CybotCookiebotDialog', '.cc-window', '.cc-banner', '.cookie-banner',
                    '.cookie-consent', '[class*="cookie-banner"]', '[class*="cookieConsent"]',
                    '[id*="cookie-banner"]', '[id*="cookieConsent"]', '[class*="consent-banner"]',
                    '[id*="consent"]'
                ];
                selectors.forEach(function(selector) {
                    try {
                        document.querySelectorAll(selector).forEach(function(el) {
                            if (clickRejectButton(el)) {
                                handled++;
                            } else if (isCookieBanner(el)) {
                                el.style.setProperty('display', 'none', 'important');
                                handled++;
                            }
                        });
                    } catch (_) {}
                });

                try {
                    document.querySelectorAll('div, section, aside, dialog').forEach(function(el) {
                        if (isCookieBanner(el)) {
                            if (!clickRejectButton(el)) {
                                el.style.setProperty('display', 'none', 'important');
                            }
                            handled++;
                        }
                    });
                } catch (_) {}

                if (handled > 0) {
                    try {
                        document.body.style.overflow = '';
                        document.documentElement.style.overflow = '';
                    } catch (_) {}
                    postPrivacyMessage({ type: 'cookieBanner', actionCount: handled });
                }
            }

            window.__souloPrivacyScan = function() {
                scanTrackers();
                handleCookieBanners();
            };
            window.__souloPrivacyScan();

            function installPrivacyObserver() {
                if (!document.body || window.__souloPrivacyObserver) return;
                window.__souloPrivacyObserver = new MutationObserver(function(mutations) {
                    var needsScan = false;
                    mutations.forEach(function(m) { if (m.addedNodes.length > 0) needsScan = true; });
                    if (needsScan) {
                        clearTimeout(window.__souloPrivacyTimer);
                        window.__souloPrivacyTimer = setTimeout(function() {
                            if (typeof window.__souloPrivacyScan === 'function') {
                                window.__souloPrivacyScan();
                            }
                        }, 250);
                    }
                });
                window.__souloPrivacyObserver.observe(document.body, { childList: true, subtree: true });
            }

            installPrivacyObserver();
            if (!document.body) {
                document.addEventListener('DOMContentLoaded', installPrivacyObserver, { once: true });
            }
        })();
        """
    }

}
