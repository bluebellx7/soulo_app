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

        function setPreferenceStyle(identifier, css, enabled) {
            var style = document.getElementById(identifier);
            if (!enabled) {
                if (style) style.remove();
                return;
            }
            if (!document.documentElement) return;
            if (!style) {
                style = document.createElement('style');
                style.id = identifier;
                document.documentElement.appendChild(style);
            }
            if (style.textContent !== css) style.textContent = css;
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
            setPreferenceStyle(
                'soulo-reduce-motion-style',
                '*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;transition-duration:.01ms!important;scroll-behavior:auto!important}',
                !!config.reduceMotion
            );
            setPreferenceStyle(
                'soulo-underline-links-style',
                'a[href]{text-decoration-line:underline!important;text-decoration-thickness:max(1px,.08em)!important;text-underline-offset:.14em!important}',
                !!config.underlineLinks
            );
        };
    })();
    """

    static func applyWebAppearance(
        warmColorShift: Bool,
        forceDark: Bool,
        reduceMotion: Bool,
        underlineLinks: Bool
    ) -> String {
        """
        \(webAppearanceBootstrap)
        window.__souloApplyWebAppearance && window.__souloApplyWebAppearance({
            warmColorShift: \(warmColorShift ? "true" : "false"),
            forceDark: \(forceDark ? "true" : "false"),
            reduceMotion: \(reduceMotion ? "true" : "false"),
            underlineLinks: \(underlineLinks ? "true" : "false")
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
    static func extensionInstallBridge(
        title: String,
        message: String,
        installButton: String,
        installingButton: String,
        logoDataURL: String
    ) -> String {
        let escapedTitle = title.escapedForJavaScriptString
        let escapedMessage = message.escapedForJavaScriptString
        let escapedInstallButton = installButton.escapedForJavaScriptString
        let escapedInstallingButton = installingButton.escapedForJavaScriptString
        let escapedLogoDataURL = logoDataURL.escapedForJavaScriptString
        return """
    (function() {
        if (window.__souloExtensionInstallBridgeInstalled) return;
        window.__souloExtensionInstallBridgeInstalled = true;

        function supportedExtensionPage() {
            var host = String(location.hostname || '').toLowerCase();
            var path = String(location.pathname || '');
            if (host === 'chromewebstore.google.com' || host === 'chrome.google.com') {
                return /\\/detail\\/[^/]+\\/[a-p]{32}(?:\\/|$)/i.test(path);
            }
            if (host === 'microsoftedge.microsoft.com') {
                return /\\/addons\\/detail\\/[^/]+\\/[a-z]{32}(?:\\/|$)/i.test(path);
            }
            if (host === 'addons.mozilla.org' || host === 'www.addons.mozilla.org') {
                return /\\/firefox\\/addon\\/[A-Za-z0-9._-]+(?:\\/|$)/i.test(path);
            }
            return false;
        }

        function supportedStoreHost() {
            var host = String(location.hostname || '').toLowerCase();
            return host === 'chromewebstore.google.com'
                || host === 'chrome.google.com'
                || host === 'microsoftedge.microsoft.com'
                || host === 'addons.mozilla.org'
                || host === 'www.addons.mozilla.org';
        }

        function requestInstall(button) {
            var handler = window.webkit && window.webkit.messageHandlers
                && window.webkit.messageHandlers.souloExtensionInstaller;
            if (!handler || !supportedExtensionPage()) return;
            if (button) {
                var originalLabel = String(button.textContent || '');
                button.disabled = true;
                button.textContent = '\(escapedInstallingButton)';
                window.setTimeout(function() {
                    button.disabled = false;
                    button.textContent = originalLabel || '\(escapedInstallButton)';
                }, 1200);
            }
            handler.postMessage({ pageURL: String(location.href || '') });
        }

        function addInstallBar() {
            if (!supportedExtensionPage() || document.getElementById('__soulo-extension-install-host')) return;
            var host = document.createElement('div');
            host.id = '__soulo-extension-install-host';
            host.style.cssText = 'all:initial;position:fixed;z-index:2147483647;left:12px;right:12px;top:max(10px,env(safe-area-inset-top));pointer-events:auto;';
            var shadow = host.attachShadow ? host.attachShadow({mode:'closed'}) : host;
            var bar = document.createElement('div');
            bar.setAttribute('role', 'banner');
            bar.style.cssText = 'box-sizing:border-box;display:flex;align-items:center;gap:12px;width:100%;max-width:760px;margin:0 auto;padding:10px 11px 10px 14px;border:1px solid rgba(128,128,128,.24);border-radius:16px;color:#111;background:rgba(250,250,252,.94);box-shadow:0 8px 28px rgba(0,0,0,.16);backdrop-filter:blur(22px);-webkit-backdrop-filter:blur(22px);font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;';
            if (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) {
                bar.style.color = '#f5f5f7';
                bar.style.background = 'rgba(35,35,38,.94)';
                bar.style.borderColor = 'rgba(255,255,255,.13)';
            }
            var icon = document.createElement('img');
            icon.src = '\(escapedLogoDataURL)';
            icon.alt = '';
            icon.draggable = false;
            icon.setAttribute('aria-hidden', 'true');
            icon.style.cssText = 'box-sizing:border-box;display:block;flex:0 0 34px;width:34px;height:34px;border:1px solid rgba(128,128,128,.18);border-radius:10px;object-fit:cover;background:#fff;box-shadow:0 2px 7px rgba(0,0,0,.12);';
            var copy = document.createElement('div');
            copy.style.cssText = 'min-width:0;flex:1;';
            var title = document.createElement('div');
            title.textContent = '\(escapedTitle)';
            title.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:14px;font-weight:700;line-height:18px;';
            var message = document.createElement('div');
            message.textContent = '\(escapedMessage)';
            message.style.cssText = 'overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-top:1px;opacity:.66;font-size:11px;font-weight:450;line-height:15px;';
            var button = document.createElement('button');
            button.type = 'button';
            button.textContent = '\(escapedInstallButton)';
            button.style.cssText = 'all:unset;box-sizing:border-box;flex:0 0 auto;min-height:34px;padding:0 14px;border-radius:10px;color:white;background:#5b55e7;cursor:pointer;font-size:13px;font-weight:700;text-align:center;-webkit-tap-highlight-color:transparent;';
            button.addEventListener('click', function(event) {
                event.preventDefault();
                event.stopPropagation();
                requestInstall(button);
            });
            copy.appendChild(title);
            copy.appendChild(message);
            bar.appendChild(icon);
            bar.appendChild(copy);
            bar.appendChild(button);
            shadow.appendChild(bar);
            (document.documentElement || document.body).appendChild(host);
        }

        function syncInstallBar() {
            var host = document.getElementById('__soulo-extension-install-host');
            if (!supportedExtensionPage()) {
                if (host) host.remove();
                return;
            }
            if (!host) addInstallBar();
        }

        document.addEventListener('click', function(event) {
            var target = event.target;
            if (target && target.nodeType !== 1) target = target.parentElement;
            var control = target && target.closest ? target.closest('button, a, [role="button"]') : null;
            if (!control) return;

            if (!supportedExtensionPage()) return;
            var label = String(
                control.innerText || control.textContent || control.getAttribute('aria-label') || ''
            ).replace(/\\s+/g, ' ').trim().toLowerCase();
            var installLabel = /add to chrome|add to edge|add to firefox|add extension|install|安装|添加至?\\s*(chrome|edge|firefox)|添加扩展|获取/.test(label);
            if (!installLabel) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            requestInstall(control);
        }, true);

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', syncInstallBar, {once:true});
        } else {
            syncInstallBar();
        }

        if (supportedStoreHost()) {
            var routeTimer = 0;
            var scheduleSync = function() {
                window.clearTimeout(routeTimer);
                routeTimer = window.setTimeout(syncInstallBar, 80);
            };
            window.addEventListener('popstate', scheduleSync);
            window.addEventListener('hashchange', scheduleSync);
            var root = document.body || document.documentElement;
            if (root) {
                new MutationObserver(scheduleSync).observe(root, {childList:true, subtree:true});
            }
        }
    })();
    """
    }

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

        window.__souloCancelDownload = function(identifier) {
            if (Object.prototype.hasOwnProperty.call(activeDownloads, identifier)) {
                activeDownloads[identifier] = false;
            }
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

    static let contextMenuResourceTracking = #"""
    (function() {
        if (window.__souloContextResourceTrackingInstalled) return;
        window.__souloContextResourceTrackingInstalled = true;
        var lastResource = null;

        function absoluteWebURL(value) {
            if (!value) return '';
            try {
                var url = new URL(String(value), document.baseURI).href;
                return /^https?:\/\//i.test(url) ? url : '';
            } catch (_) {
                return '';
            }
        }

        function filenameFor(value) {
            try {
                var name = new URL(value).pathname.split('/').pop() || '';
                return decodeURIComponent(name) || 'Download';
            } catch (_) {
                return 'Download';
            }
        }

        function resource(kind, value) {
            var url = absoluteWebURL(value);
            return url ? { kind: kind, url: url, filename: filenameFor(url) } : null;
        }

        function resourceForElement(target) {
            if (!target || target.nodeType !== 1) return null;

            var image = target.closest && target.closest('img');
            if (!image && target.querySelector) image = target.querySelector('img');
            if (image) {
                var imageResource = resource('image', image.currentSrc || image.src);
                if (imageResource) return imageResource;
            }

            var video = target.closest && target.closest('video');
            if (!video && target.querySelector) video = target.querySelector('video');
            if (video) {
                var videoSource = video.currentSrc || video.src;
                if (!videoSource && video.querySelector('source')) videoSource = video.querySelector('source').src;
                var videoResource = resource('video', videoSource);
                if (videoResource) return videoResource;
            }

            var audio = target.closest && target.closest('audio');
            if (!audio && target.querySelector) audio = target.querySelector('audio');
            if (audio) {
                var audioSource = audio.currentSrc || audio.src;
                if (!audioSource && audio.querySelector('source')) audioSource = audio.querySelector('source').src;
                var audioResource = resource('audio', audioSource);
                if (audioResource) return audioResource;
            }

            var current = target;
            for (var depth = 0; current && depth < 4; depth++, current = current.parentElement) {
                try {
                    var background = getComputedStyle(current).backgroundImage || '';
                    var match = background.match(/url\(["']?([^"')]+)["']?\)/);
                    if (match) {
                        var backgroundResource = resource('image', match[1]);
                        if (backgroundResource) return backgroundResource;
                    }
                } catch (_) {}
            }

            var link = target.closest && target.closest('a[href]');
            if (link && /\.(pdf|docx?|xlsx?|pptx?|zip|rar|7z|tar|gz|csv|epub)(?:$|[?#])/i.test(link.href)) {
                return resource('file', link.href);
            }
            return null;
        }

        function remember(target) {
            lastResource = resourceForElement(target);
        }

        document.addEventListener('touchstart', function(event) {
            remember(event.touches && event.touches[0]
                ? document.elementFromPoint(event.touches[0].clientX, event.touches[0].clientY)
                : event.target);
        }, true);
        document.addEventListener('pointerdown', function(event) {
            remember(document.elementFromPoint(event.clientX, event.clientY) || event.target);
        }, true);
        document.addEventListener('contextmenu', function(event) {
            remember(event.target);
        }, true);

        window.__souloContextResourceInfo = function() { return lastResource; };
    })();
    """#

    static let mediaResourceTracking = #"""
    (function() {
        if (window.__souloMediaResourceTrackingInstalled) return;
        window.__souloMediaResourceTrackingInstalled = true;

        var observedURLs = [];
        var observedSet = new Set();
        window.__souloObservedResourceURLs = observedURLs;

        function currentYouTubeVideoID() {
            try {
                var pageURL = new URL(location.href);
                var host = String(pageURL.hostname || '').toLowerCase();
                if (host.indexOf('www.') === 0) host = host.slice(4);
                if (host === 'youtu.be') {
                    return pageURL.pathname.split('/').filter(Boolean)[0] || '';
                }
                if (host !== 'youtube.com' && host !== 'm.youtube.com') return '';
                if (pageURL.pathname === '/watch') return pageURL.searchParams.get('v') || '';
                var parts = pageURL.pathname.split('/').filter(Boolean);
                return parts.length >= 2 && ['shorts', 'embed', 'live'].indexOf(parts[0]) >= 0
                    ? parts[1]
                    : '';
            } catch (_) {
                return '';
            }
        }
        window.__souloCurrentYouTubeVideoID = currentYouTubeVideoID;

        function isYouTubeSite() {
            try {
                var host = String(location.hostname || '').toLowerCase();
                return host === 'youtube.com'
                    || host.endsWith('.youtube.com')
                    || host === 'youtu.be';
            } catch (_) {
                return false;
            }
        }

        function cacheYouTubePlayerResponse(value) {
            try {
                if (typeof value === 'string') value = JSON.parse(value);
                var streamingData = value && value.streamingData;
                if (!streamingData || typeof streamingData !== 'object') return null;
                if (!streamingData.serverAbrStreamingUrl
                    || !Array.isArray(streamingData.adaptiveFormats)
                    || !streamingData.adaptiveFormats.length) return null;
                var responseVideoID = String(value.videoDetails && value.videoDetails.videoId || '');
                var snapshot = JSON.parse(JSON.stringify(value));
                window.__souloYouTubePlayerResponses = window.__souloYouTubePlayerResponses || Object.create(null);
                if (responseVideoID) {
                    window.__souloYouTubePlayerResponses[responseVideoID] = snapshot;
                    var cachedIDs = Object.keys(window.__souloYouTubePlayerResponses);
                    while (cachedIDs.length > 8) {
                        delete window.__souloYouTubePlayerResponses[cachedIDs.shift()];
                    }
                }
                if (!currentYouTubeVideoID() || currentYouTubeVideoID() === responseVideoID) {
                    window.__souloYouTubePlayerResponse = snapshot;
                }
                return snapshot;
            } catch (_) {
                return null;
            }
        }
        window.__souloCacheYouTubePlayerResponse = cacheYouTubePlayerResponse;

        var trackedYouTubeVideoID = currentYouTubeVideoID();

        function syncYouTubeVideoState() {
            var videoID = currentYouTubeVideoID();
            if (videoID === trackedYouTubeVideoID) return;
            trackedYouTubeVideoID = videoID;

            var preparedID = String(
                window.__souloPreparedYouTubePlayerResponse?.videoDetails?.videoId || ''
            );
            if (!videoID || preparedID !== videoID) {
                window.__souloPreparedYouTubePlayerResponse = null;
            }
            var currentID = String(window.__souloYouTubePlayerResponse?.videoDetails?.videoId || '');
            if (!videoID || currentID !== videoID) {
                window.__souloYouTubePlayerResponse = null;
            }
            if (!window.__souloLatestPageSABR
                || window.__souloLatestPageSABR.videoID !== videoID) {
                window.__souloLatestPageSABR = null;
            }
        }

        function liveYouTubePlayerResponses() {
            var responses = [];
            var players = [];
            var seen = new Set();
            function addPlayer(value) {
                if (!value || seen.has(value)) return;
                seen.add(value);
                players.push(value);
                try { addPlayer(value.player_); } catch (_) {}
                try { addPlayer(value.player); } catch (_) {}
                try { addPlayer(value.getPlayer && value.getPlayer()); } catch (_) {}
                try { addPlayer(value.querySelector && value.querySelector('#movie_player, #shorts-player')); } catch (_) {}
            }

            try { addPlayer(window.movie_player); } catch (_) {}
            try {
                document.querySelectorAll('#movie_player, #shorts-player, yt-player, ytm-player, #player')
                    .forEach(addPlayer);
            } catch (_) {}

            players.forEach(function(player) {
                try {
                    if (typeof player.getPlayerResponse === 'function') {
                        responses.push(player.getPlayerResponse.call(player));
                    }
                } catch (_) {}
            });
            return responses;
        }

        function resolveCurrentYouTubePlayerResponse() {
            syncYouTubeVideoState();
            var expectedVideoID = currentYouTubeVideoID();
            if (!expectedVideoID) return null;
            var candidates = liveYouTubePlayerResponses();
            try { candidates.push(window.__souloYouTubePlayerResponses?.[expectedVideoID]); } catch (_) {}
            try { candidates.push(window.__souloYouTubePlayerResponse); } catch (_) {}
            try { candidates.push(window.ytInitialPlayerResponse); } catch (_) {}
            try { candidates.push(window.ytplayer?.bootstrapPlayerResponse); } catch (_) {}
            try { candidates.push(window.ytplayer?.config?.args?.raw_player_response); } catch (_) {}
            try { candidates.push(window.ytplayer?.config?.args?.player_response); } catch (_) {}
            try { candidates.push(window.ytcfg?.get?.('PLAYER_RESPONSE')); } catch (_) {}
            try { candidates.push(window.getInitialData?.()?.playerResponse); } catch (_) {}

            for (var candidate of candidates) {
                try {
                    if (typeof candidate === 'string') candidate = JSON.parse(candidate);
                    var candidateVideoID = String(candidate?.videoDetails?.videoId || '');
                    if (candidateVideoID !== expectedVideoID) continue;
                    var cached = cacheYouTubePlayerResponse(candidate);
                    if (cached) return cached;
                } catch (_) {}
            }
            return null;
        }
        window.__souloResolveCurrentYouTubePlayerResponse = resolveCurrentYouTubePlayerResponse;

        function refreshCurrentYouTubePlayerResponse() {
            syncYouTubeVideoState();
            var videoID = currentYouTubeVideoID();
            if (videoID && !window.__souloYouTubePlayerResponses?.[videoID]) {
                resolveCurrentYouTubePlayerResponse();
            }
        }

        if (isYouTubeSite()) {
            ['yt-navigate-start', 'yt-navigate-finish', 'yt-page-data-updated', 'popstate']
                .forEach(function(eventName) {
                    window.addEventListener(eventName, function() {
                        [0, 100, 300, 800, 1500].forEach(function(delay) {
                            setTimeout(refreshCurrentYouTubePlayerResponse, delay);
                        });
                    }, true);
                });
            window.__souloYouTubeContextTimer = setInterval(refreshCurrentYouTubePlayerResponse, 500);
        }

        function cacheYouTubePlayerResponsesDeep(root) {
            var visited = new Set();
            var visitedCount = 0;
            function visit(value, depth, keyHint) {
                if (visitedCount >= 2000 || depth > 10 || value == null) return;
                if (typeof value === 'string') {
                    if (!/player_?response/i.test(keyHint || '')) return;
                    try { value = JSON.parse(value); } catch (_) { return; }
                }
                if (typeof value !== 'object' || visited.has(value)) return;
                visited.add(value);
                visitedCount += 1;
                if (value.videoDetails && value.streamingData) {
                    cacheYouTubePlayerResponse(value);
                }
                var keys = Object.keys(value).slice(0, 300).sort(function(lhs, rhs) {
                    return (/player_?response/i.test(rhs) ? 1 : 0)
                        - (/player_?response/i.test(lhs) ? 1 : 0);
                });
                keys.forEach(function(key) { visit(value[key], depth + 1, key); });
            }
            visit(root, 0, '');
        }
        window.__souloCacheYouTubePlayerResponsesDeep = cacheYouTubePlayerResponsesDeep;

        function remember(value) {
            value = String(value || '');
            if (!/^https?:\/\//i.test(value) || observedSet.has(value)) return;
            if (observedURLs.length >= 2000) {
                observedSet.delete(observedURLs.shift());
            }
            observedSet.add(value);
            observedURLs.push(value);
        }

        // Resource Timing may omit cross-origin streaming requests. Observe
        // fetch inputs as well so the inspector retains the exact URL after
        // the page has applied any player-specific URL transformation.
        try {
            var pageHost = String(location.hostname || '').toLowerCase();
            var isYouTubePage = pageHost === 'youtube.com'
                || pageHost.endsWith('.youtube.com')
                || pageHost === 'youtu.be';
            var pageFetch = window.fetch;
            if (isYouTubePage && typeof pageFetch === 'function') {
                window.fetch = function(input) {
                    var value = '';
                    try {
                        syncYouTubeVideoState();
                        value = input instanceof Request ? input.url : String(input || '');
                        remember(value);
                        if (/[?&]sabr=1(?:&|$)/i.test(value)) {
                            window.__souloLatestPageSABR = {
                                url: value,
                                videoID: currentYouTubeVideoID()
                            };
                        }
                    } catch (_) {}
                    var result = pageFetch.apply(this, arguments);
                    if (/\/youtubei\/v1\/(?:player|next)(?:[?\/]|$)/i.test(value)) {
                        Promise.resolve(result).then(function(response) {
                            try {
                                return response.clone().json()
                                    .then(cacheYouTubePlayerResponsesDeep)
                                    .catch(function() {});
                            } catch (_) {}
                        }).catch(function() {});
                    }
                    return result;
                };
            }

            if (isYouTubePage && typeof XMLHttpRequest === 'function') {
                var originalOpen = XMLHttpRequest.prototype.open;
                XMLHttpRequest.prototype.open = function(method, url) {
                    try {
                        var value = String(url || '');
                        remember(value);
                        if (/\/youtubei\/v1\/(?:player|next)(?:[?\/]|$)/i.test(value)) {
                            this.addEventListener('load', function() {
                                try {
                                    cacheYouTubePlayerResponsesDeep(
                                        this.responseType === 'json' ? this.response : this.responseText
                                    );
                                } catch (_) {}
                            }, { once: true });
                        }
                    } catch (_) {}
                    return originalOpen.apply(this, arguments);
                };
            }
        } catch (_) {}

        try {
            performance.setResourceTimingBufferSize(2500);
            Array.from(performance.getEntriesByType('resource') || []).forEach(function(entry) {
                remember(entry && entry.name);
            });
        } catch (_) {}

        try {
            var observer = new PerformanceObserver(function(list) {
                list.getEntries().forEach(function(entry) { remember(entry && entry.name); });
            });
            try {
                observer.observe({ type: 'resource', buffered: true });
            } catch (_) {
                observer.observe({ entryTypes: ['resource'] });
            }
            window.__souloMediaResourceObserver = observer;
        } catch (_) {}
    })();
    """#

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

private extension String {
    var escapedForJavaScriptString: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}
