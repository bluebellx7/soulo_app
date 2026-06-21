import Foundation

enum WebViewScripts {
    static func privacyProtection(gpcEnabled: Bool, cookieBannerHandling: Bool, disabledHosts: [String] = []) -> String {
        let disabledHostsJSON = (try? JSONSerialization.data(withJSONObject: disabledHosts))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
            var souloGPCEnabled = \(gpcEnabled ? "true" : "false");
            var souloCookieBannerHandling = \(cookieBannerHandling ? "true" : "false");
            var souloDisabledHosts = \(disabledHostsJSON);

            function normalizedHost(value) {
                return String(value || '').toLowerCase().replace(/^www\\./, '');
            }

            function domainMatches(pattern, host) {
                pattern = normalizedHost(String(pattern || '').replace(/^\\*/, ''));
                host = normalizedHost(host);
                if (!pattern) return false;
                return host === pattern || host.endsWith('.' + pattern);
            }

            function siteProtectionDisabled() {
                var host = normalizedHost(location.hostname);
                return souloDisabledHosts.some(function(domain) { return domainMatches(domain, host); });
            }

            if (siteProtectionDisabled()) return;

            if (souloGPCEnabled) {
                try {
                    Object.defineProperty(navigator, 'globalPrivacyControl', {
                        value: true,
                        configurable: true
                    });
                } catch (_) {}
            }

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

            function looksLikeTrackerHost(host) {
                host = normalizedHost(host);
                if (!host || domainMatches(host, location.hostname)) return false;
                return /doubleclick|googlesyndication|googleadservices|google-analytics|googletagmanager|facebook|connect\\.facebook|tiktok|bytedance|oceanengine|hm\\.baidu|cnzz|umeng|clarity\\.ms|hotjar|mouseflow|taboola|outbrain|criteo|adnxs|rubiconproject|pubmatic|openx|scorecardresearch|quantserve|amazon-adsystem|ads-twitter|linkedin|adservice|ads?\\./i.test(host);
            }

            function scanTrackers() {
                var hosts = [];
                var selector = 'script[src], iframe[src], img[src], link[href], source[src], a[href]';
                try {
                    document.querySelectorAll(selector).forEach(function(el) {
                        var value = el.src || el.href || '';
                        var host = hostFromURL(value);
                        if (looksLikeTrackerHost(host)) hosts.push(normalizedHost(host));
                    });
                } catch (_) {}
                hosts = Array.from(new Set(hosts)).slice(0, 80);
                if (hosts.length > 0) {
                    postPrivacyMessage({ type: 'trackerScan', trackerHosts: hosts });
                }
            }

            function textOf(el) {
                return String((el && el.textContent) || '').toLowerCase().replace(/\\s+/g, ' ').trim();
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
                    if (!el || el === document.body || el === document.documentElement) return false;
                    var text = textOf(el);
                    if (!/cookie|cookies|consent|privacy|gdpr|ccpa|隐私|同意|cookie|隱私/i.test(text)) return false;
                    var style = window.getComputedStyle(el);
                    var position = style.position;
                    var rect = el.getBoundingClientRect();
                    var largeEnough = rect.width > 160 && rect.height > 40;
                    return largeEnough && (position === 'fixed' || position === 'sticky' || position === 'absolute' || rect.bottom > window.innerHeight * 0.65);
                } catch (_) {
                    return false;
                }
            }

            function handleCookieBanners() {
                if (!souloCookieBannerHandling) return;
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
                                el.remove();
                                handled++;
                            }
                        });
                    } catch (_) {}
                });

                try {
                    document.querySelectorAll('div, section, aside, dialog, footer').forEach(function(el) {
                        if (isCookieBanner(el)) {
                            if (!clickRejectButton(el)) el.remove();
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

            scanTrackers();
            handleCookieBanners();

            var observer = new MutationObserver(function(mutations) {
                var needsScan = false;
                mutations.forEach(function(m) { if (m.addedNodes.length > 0) needsScan = true; });
                if (needsScan) {
                    clearTimeout(observer._timer);
                    observer._timer = setTimeout(function() {
                        scanTrackers();
                        handleCookieBanners();
                    }, 250);
                }
            });
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true });
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
