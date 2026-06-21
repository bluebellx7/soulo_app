import Foundation

enum WebViewScripts {
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

            if (siteProtectionDisabled()) return;

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

    static let loginOverlayRemoval = """
    (function() {
        var skipDomains = ['deepseek.com', 'qianwen.com', 'chatgpt.com', 'claude.ai', 'xiaohongshu.com', 'taobao.com', 'jd.com', 'yuanbao.tencent.com', 'doubao.com', 'metaso.cn'];
        var host = window.location.hostname;
        for (var i = 0; i < skipDomains.length; i++) {
            if (host.includes(skipDomains[i])) return;
        }

        const OVERLAY_SELECTORS = [
            '.login-modal', '.signup-dialog', '.login-popup', '.signup-popup', '.auth-modal',
            '[class*="login-guide"]', '[class*="loginGuide"]', '[class*="login-panel"]',
            '[class*="login-mask"]', '[class*="dy-account"]', '[class*="passport-sdk"]',
            '[class*="loginLayer"]', '[class*="login-layer"]',
            '[class*="mask-login"]', '[class*="guide-login"]'
        ];

        function shouldRemove(el) {
            try {
                const style = window.getComputedStyle(el);
                const zIndex = parseInt(style.zIndex, 10);
                const position = style.position;
                return (position === 'fixed' || position === 'absolute') && zIndex > 999;
            } catch (_) {}
            return false;
        }

        function removeOverlays() {
            OVERLAY_SELECTORS.forEach(function(selector) {
                try {
                    document.querySelectorAll(selector).forEach(function(el) {
                        if (shouldRemove(el)) el.remove();
                    });
                } catch (_) {}
            });

            try {
                document.querySelectorAll('div').forEach(function(el) {
                    var s = window.getComputedStyle(el);
                    if ((s.position === 'fixed' || s.position === 'absolute') &&
                        parseInt(s.zIndex) > 999 &&
                        el.offsetWidth > 100 && el.offsetHeight > 100) {
                        var text = (el.textContent || '').toLowerCase();
                        if (text.includes('登录') || text.includes('login') ||
                            text.includes('注册') || text.includes('sign') ||
                            text.includes('验证码') || text.includes('手机号')) {
                            el.remove();
                        }
                    }
                });
            } catch(_) {}

            try {
                document.body.style.overflow = '';
                document.documentElement.style.overflow = '';
            } catch (_) {}
        }

        removeOverlays();

        const observer = new MutationObserver(function(mutations) {
            let shouldCheck = false;
            mutations.forEach(function(m) {
                if (m.addedNodes.length > 0) shouldCheck = true;
            });
            if (shouldCheck) removeOverlays();
        });

        observer.observe(document.body || document.documentElement, {
            childList: true,
            subtree: true
        });
    })();
    """
}
