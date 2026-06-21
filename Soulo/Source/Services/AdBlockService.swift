import WebKit

struct AdBlockService {

    // MARK: - Content Rule List (blocks network requests to ad domains)

    static func compileRules(allowlistedHosts: [String] = []) async -> WKContentRuleList? {
        guard let jsonString = encodedContentRuleList(allowlistedHosts: allowlistedHosts) else {
            return nil
        }

        let signature = [
            normalizedAllowlist(allowlistedHosts).joined(separator: ","),
            AdBlockSubscriptionService.rulesSignature()
        ].joined(separator: "|")
        let identifier = "SouloAdBlockV3-\(stableIdentifierHash(signature))"
        return try? await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: jsonString
        )
    }

    static func encodedContentRuleList(allowlistedHosts: [String] = []) -> String? {
        let excludedDomains = normalizedAllowlist(allowlistedHosts)
            .flatMap { ["*\($0)", $0] }

        func trigger(_ urlFilter: String, resourceTypes: [String]? = nil) -> [String: Any] {
            var value: [String: Any] = ["url-filter": urlFilter]
            if let resourceTypes {
                value["resource-type"] = resourceTypes
            }
            if !excludedDomains.isEmpty {
                value["unless-domain"] = excludedDomains
            }
            return value
        }

        func trigger(for rule: AdBlockNetworkRule) -> [String: Any] {
            var value = trigger(rule.urlFilter, resourceTypes: rule.resourceTypes.isEmpty ? nil : rule.resourceTypes)
            if !rule.loadTypes.isEmpty {
                value["load-type"] = rule.loadTypes
            }
            if !rule.ifDomains.isEmpty {
                value["if-domain"] = rule.ifDomains
            }
            if !rule.unlessDomains.isEmpty {
                let domains = Set((value["unless-domain"] as? [String]) ?? []).union(rule.unlessDomains)
                value["unless-domain"] = Array(domains).sorted()
            }
            return value
        }

        // Each rule blocks requests whose URL matches the pattern
        let adDomains = [
            // Google Ads
            "googlesyndication\\.com", "googleadservices\\.com", "googleads\\.g\\.doubleclick\\.net",
            "pagead2\\.googlesyndication\\.com", "adservice\\.google\\.com",
            "doubleclick\\.net", "tpc\\.googlesyndication\\.com",
            // Facebook / Meta
            "facebook\\.com/tr", "connect\\.facebook\\.net.*fbevents",
            // Baidu Ads
            "cpro\\.baidustatic\\.com", "pos\\.baidu\\.com", "hm\\.baidu\\.com",
            "cpro\\.baidu\\.com", "eclick\\.baidu\\.com", "baidustatic\\.com/cpro",
            // Alibaba Ads
            "tanx\\.com", "mmstat\\.com", "atanx\\.alicdn\\.com",
            // Sina / Weibo
            "ad\\.sina\\.com\\.cn", "beacon\\.sina\\.com\\.cn",
            // Amazon
            "mads\\.amazon\\.com", "aax-.*\\.amazon\\.com",
            // Yahoo
            "ads\\.yahoo\\.com", "adtech\\.de",
            // Major ad networks
            "adnxs\\.com", "adsrvr\\.org", "serving-sys\\.com",
            "moatads\\.com", "outbrain\\.com", "taboola\\.com",
            "criteo\\.com", "pubmatic\\.com", "rubiconproject\\.com",
            "openx\\.net", "carbonads\\.com", "buysellads\\.com",
            "adroll\\.com", "googletag\\.cmd", "securepubads",
            // Analytics / Tracking
            "analytics\\.tiktok\\.com", "ads-api\\.tiktok\\.com",
            "hotjar\\.com", "clarity\\.ms", "mouseflow\\.com",
            // Chinese ad networks
            "union\\.bytedance\\.com", "ad\\.oceanengine\\.com",
            "e\\.qq\\.com", "gdt\\.qq\\.com", "mi\\.gdt\\.qq\\.com",
            "c\\.cnzz\\.com", "s\\.cnzz\\.com",
            // Popup / overlay ads
            "popads\\.net", "popcash\\.net", "propellerads\\.com",
            "adform\\.net", "adzerk\\.net", "adition\\.com", "yieldmo\\.com",
            "media\\.net", "lijit\\.com", "sovrn\\.com", "sharethrough\\.com",
            "smartadserver\\.com", "adsafeprotected\\.com", "zedo\\.com",
            "scorecardresearch\\.com", "quantserve\\.com", "amazon-adsystem\\.com",
            "ads-twitter\\.com", "ads\\.linkedin\\.com", "bat\\.bing\\.com",
            "ad\\.doubleclick\\.net", "partner\\.googleadservices\\.com",
            "imasdk\\.googleapis\\.com", "google-analytics\\.com", "googletagmanager\\.com/gtag/js",
            "static\\.doubleclick\\.net", "fls\\.doubleclick\\.net", "adservice\\.google\\.",
            "ads\\.pubmatic\\.com", "pixel\\.rubiconproject\\.com", "fastlane\\.rubiconproject\\.com",
            "ib\\.adnxs\\.com", "secure\\.adnxs\\.com", "sync\\.outbrain\\.com",
            "trc\\.taboola\\.com", "cdn\\.taboola\\.com", "analytics\\.google\\.com",
        ]

        var rulesArray: [[String: Any]] = adDomains.map { domain in
            [
                "trigger": trigger(domain),
                "action": ["type": "block"]
            ]
        }

        // Block common ad resource patterns
        let adPatterns = [
            "/ads/", "/adserver", "/adclick", "/adview",
            "adsense", "adsbygoogle", "/pagead/",
            "doubleclick\\.net", "/ad\\.js", "/ads\\.js",
            "/advert/", "/advertising/", "/sponsor/", "/sponsored/",
            "\\?ad=", "&ad=", "\\?ads=", "&ads=",
            "\\?adid=", "&adid=", "\\?adunit=", "&adunit=",
            "\\?adslot=", "&adslot=",
            "/prebid", "prebid\\.js", "gpt\\.js", "pubads_impl",
            "/cpcad", "cpcad", "gudingwei", "jioeidd", "cqlkxq1wc",
            "/union/", "/tuiguang/", "/gg/", "/gg\\.js", "/adver",
            "/adpic", "adpic", "adimg", "/adimg/", "/adsimg/", "/adv/",
            "/adfile/", "/ad_code/", "/adcode/", "/adstatic/", "/adverts/",
            "/adsystem/", "adbanner", "ad_banner", "floatad", "float_ad",
            "popupad", "popup_ad", "rightad", "leftad", "topad", "bottomad",
        ]
        for pattern in adPatterns {
            rulesArray.append([
                "trigger": trigger(pattern, resourceTypes: ["script", "image", "raw"]),
                "action": ["type": "block"]
            ])
        }

        let cachedRules = AdBlockSubscriptionService.cachedRules()
        let structuredNetworkRules = cachedRules.networkRules.isEmpty
            ? cachedRules.networkURLFilters.map {
                AdBlockNetworkRule(urlFilter: $0, resourceTypes: ["script", "image", "raw", "document", "popup"])
            }
            : cachedRules.networkRules

        for networkRule in structuredNetworkRules {
            rulesArray.append([
                "trigger": trigger(for: networkRule),
                "action": ["type": "block"]
            ])
        }

        var hideSelectors = [
            ".adsbygoogle", "ins.adsbygoogle", "[id^='div-gpt-ad']",
            "[class*='ad-container']", "[class*='ad-wrapper']", "[class*='ad-banner']",
            "[id*='google_ads']", "[data-ad-slot]", "[data-ad-position]",
            "[class*='sponsor']", "[class*='promoted']", "[class*='taboola']",
            "[class*='outbrain']", "iframe[src*='doubleclick']",
            "iframe[src*='googlesyndication']", "[aria-label*='advertisement' i]",
            "[aria-label*='广告']", "[class*='advertisement']", "[id*='advertisement']",
            "[class*='banner-ad']", "[class*='sticky-ad']", "[class*='popup-ad']",
            ".cpcad", ".pcad", ".adpic", ".adpicbox", ".gg", "[class*=' cpcad']",
            "[class*='-ad-']", "[class^='ad-']", "[id^='ad-']", "[id^='gg']",
            "[class^='gg-']", "[class*='-gg']", "[class*='广告']", "[id*='广告']",
            "[class*='gudingwei']", "[id*='gudingwei']", "[class*='jioeidd']",
            "[id*='jioeidd']", "[class*='cqlkxq1wc']", "[id*='cqlkxq1wc']",
            "[class*='tuiguang']", "[id*='tuiguang']", "[class*='floatad']",
            "[id*='floatad']", "[class*='popupad']", "[id*='popupad']"
        ]

        hideSelectors.append(contentsOf: cachedRules.cosmeticRules.filter { $0.ifDomains.isEmpty && $0.unlessDomains.isEmpty }.map(\.selector))
        for selectorGroup in chunkedSelectors(hideSelectors) {
            rulesArray.append([
                "trigger": trigger(".*"),
                "action": ["type": "css-display-none", "selector": selectorGroup.joined(separator: ",")]
            ])
        }

        for cosmeticRule in cachedRules.cosmeticRules where !cosmeticRule.ifDomains.isEmpty || !cosmeticRule.unlessDomains.isEmpty {
            var cosmeticTrigger = trigger(".*")
            if !cosmeticRule.ifDomains.isEmpty {
                cosmeticTrigger["if-domain"] = cosmeticRule.ifDomains
            }
            if !cosmeticRule.unlessDomains.isEmpty {
                let domains = Set((cosmeticTrigger["unless-domain"] as? [String]) ?? []).union(cosmeticRule.unlessDomains)
                cosmeticTrigger["unless-domain"] = Array(domains).sorted()
            }
            rulesArray.append([
                "trigger": cosmeticTrigger,
                "action": ["type": "css-display-none", "selector": cosmeticRule.selector]
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rulesArray) else { return nil }
        return String(data: jsonData, encoding: .utf8)
    }

    private static func normalizedAllowlist(_ hosts: [String]) -> [String] {
        Array(Set(hosts.map { AdBlockSettingsService.normalizedHost($0) }.filter { !$0.isEmpty })).sorted()
    }

    private static func stableIdentifierHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func chunkedSelectors(_ selectors: [String], chunkSize: Int = 80) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []

        for selector in selectors where !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            current.append(selector)
            if current.count >= chunkSize {
                chunks.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    // MARK: - CSS + JS injection to hide ad elements

    static func adHidingScript(cosmetic: Bool = true, popups: Bool = true, allowlistedHosts: [String] = []) -> String {
        let cachedRules = AdBlockSubscriptionService.cachedRules()
        let cosmeticRules = cachedRules.cosmeticRules.isEmpty
            ? cachedRules.cosmeticSelectors.map { AdBlockCosmeticRule(selector: $0) }
            : cachedRules.cosmeticRules
        let cosmeticPayload = cosmeticRules.map { rule in
            [
                "selector": rule.selector,
                "ifDomains": rule.ifDomains,
                "unlessDomains": rule.unlessDomains
            ] as [String: Any]
        }
        let subscriptionCosmeticRulesJSON = (try? JSONSerialization.data(withJSONObject: cosmeticPayload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let allowlistJSON = (try? JSONSerialization.data(withJSONObject: normalizedAllowlist(allowlistedHosts)))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
            var souloCosmeticEnabled = \(cosmetic ? "true" : "false");
            var souloPopupEnabled = \(popups ? "true" : "false");
            var souloAllowlistedHosts = \(allowlistJSON);
            var souloSubscriptionCosmeticRules = \(subscriptionCosmeticRulesJSON);

            function normalizedHost(value) {
                return String(value || '').toLowerCase().replace(/^www\\./, '');
            }

            function domainMatches(pattern, host) {
                pattern = normalizedHost(String(pattern || '').replace(/^\\*/, ''));
                host = normalizedHost(host);
                if (!pattern) return false;
                return host === pattern || host.endsWith('.' + pattern);
            }

            function isSouloAllowlisted() {
                var host = normalizedHost(location.hostname);
                return souloAllowlistedHosts.some(function(domain) { return domainMatches(domain, host); });
            }

            if (isSouloAllowlisted()) return;

            function matchingSubscriptionSelectors() {
                var host = normalizedHost(location.hostname);
                var selectors = [];
                souloSubscriptionCosmeticRules.forEach(function(rule) {
                    var selector = rule.selector || '';
                    if (!selector) return;
                    var ifDomains = rule.ifDomains || [];
                    var unlessDomains = rule.unlessDomains || [];
                    var included = ifDomains.length === 0 || ifDomains.some(function(domain) { return domainMatches(domain, host); });
                    var excluded = unlessDomains.some(function(domain) { return domainMatches(domain, host); });
                    if (included && !excluded) selectors.push(selector);
                });
                return selectors;
            }

            var souloSubscriptionSelectors = matchingSubscriptionSelectors();

            if (souloCosmeticEnabled) {
                var style = document.getElementById('soulo-ad-hiding-style');
                if (!style) {
                    style = document.createElement('style');
                    style.id = 'soulo-ad-hiding-style';
                    (document.head || document.documentElement).appendChild(style);
                }
                style.textContent = `
                /* Common ad containers */
                [class*="ad-container"], [class*="ad-wrapper"], [class*="ad-banner"],
                [class*="ad-slot"], [class*="ad_"], [class*="adsbygoogle"],
                [id*="ad-container"], [id*="ad-wrapper"], [id*="ad-banner"],
                [id*="google_ads"], [id*="div-gpt-ad"],
                ins.adsbygoogle, div[data-ad], div[data-ad-slot],
                [class*="sponsor"], [class*="promoted"],
                .ad, .ads, .advert, .advertisement,
                #ad, #ads, #advert, #advertisement,

                /* iframes */
                iframe[src*="doubleclick"], iframe[src*="googlesyndication"],
                iframe[src*="advertising"], iframe[src*="ads."],
                iframe[src*="ad."], iframe[src*="adserver"],

                /* Baidu specific */
                #content_right .result-op[data-click],
                .ec_tuiguang_pplink, .ec_tuiguang_pptitle,
                [class*="s_side_ad"], [class*="ec_wise_ad"],
                #ec_im_container, .ec-result-container,

                /* Sogou specific */
                [class*="promote"], .vrwrap[data-promote],

                /* Common patterns */
                [class*="adArea"], [class*="ad-area"],
                [class*="adsBox"], [class*="ads-box"],
                [class*="adBlock"], [class*="ad-block"],
                [class*="banner-ad"], [class*="bannerAd"],
                [data-testid*="ad"], [data-ad-position],
                [class*="commercial"], [class*="promo-"],
                [class*="outbrain"], [class*="taboola"],
                [aria-label*="advertisement" i], [aria-label*="广告"],

                /* Fixed / sticky overlays that are likely ads */
                [class*="popup-ad"], [class*="interstitial"],
                [class*="overlay-ad"], [id*="popup-ad"],
                [class*="floating-ad"], [class*="sticky-ad"],

                /* Chinese video/resource site ad templates */
                .cpcad, .pcad, .adpic, .adpicbox, .gg,
                [class*=" cpcad"], [class*="-ad-"], [class^="ad-"],
                [id^="ad-"], [id^="gg"], [class^="gg-"], [class*="-gg"],
                [class*="广告"], [id*="广告"],
                [class*="tuiguang"], [id*="tuiguang"],
                [class*="promotion"], [class*="promote"],
                [class*="gudingwei"], [id*="gudingwei"],
                [class*="jioeidd"], [id*="jioeidd"],
                [class*="cqlkxq1wc"], [id*="cqlkxq1wc"],
                [class*="floatad"], [id*="floatad"],
                [class*="popupad"], [id*="popupad"],
                [class*="adpic"], [id*="adpic"],
                [class*="adimg"], [id*="adimg"] {
                    display: none !important;
                    height: 0 !important;
                    max-height: 0 !important;
                    overflow: hidden !important;
                    visibility: hidden !important;
                    pointer-events: none !important;
                }
            `;
                if (souloSubscriptionSelectors.length) {
                    style.textContent += '\\n' + souloSubscriptionSelectors.join(',\\n') + '{display:none!important;height:0!important;max-height:0!important;overflow:hidden!important;visibility:hidden!important;pointer-events:none!important;}';
                }
            }

            function normalizedTrackerHost(value) {
                return String(value || '').toLowerCase().replace(/^www\\./, '');
            }

            function hostFromElement(el) {
                try {
                    var value = el.src || el.href || '';
                    if (!value && el.querySelector) {
                        var child = el.querySelector('[src], [href]');
                        value = (child && (child.src || child.href)) || '';
                    }
                    if (!value) {
                        var html = String(el.outerHTML || '');
                        var match = html.match(/https?:\\/\\/([^\\/"'\\s>]+)/i);
                        value = match ? match[0] : '';
                    }
                    return normalizedTrackerHost(new URL(value, location.href).hostname);
                } catch(e) {
                    return '';
                }
            }

            function looksLikeTrackerHost(host) {
                host = normalizedTrackerHost(host);
                if (!host || domainMatches(host, location.hostname)) return false;
                return /doubleclick|googlesyndication|googleadservices|google-analytics|googletagmanager|facebook|connect\\.facebook|tiktok|bytedance|oceanengine|hm\\.baidu|cnzz|umeng|clarity\\.ms|hotjar|mouseflow|taboola|outbrain|criteo|adnxs|rubiconproject|pubmatic|openx|scorecardresearch|quantserve|amazon-adsystem|ads-twitter|linkedin|adservice|ads?\\./i.test(host);
            }

            function removeAds() {
                var hiddenCount = 0;
                var trackerHosts = [];
                if (souloCosmeticEnabled) {
                    var selectors = [
                        'ins.adsbygoogle', 'div[id^="div-gpt-ad"]',
                        'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
                        'iframe[src*="ads."]', '[data-ad-slot]',
                        '.adsbygoogle', '[id*="google_ads"]',
                        'div[class*="ad-container"]', 'div[class*="ad-wrapper"]',
                        '[class*="outbrain-widget"]', '[class*="taboola"]',
                        'div[id*="ad-"]', 'div[data-ad]',
                        '#content_right .result-op[data-click]',
                        '.ec_tuiguang_pplink',
                        '.cpcad', '.pcad', '.adpic', '.adpicbox', '.gg',
                        '[class*=" cpcad"]', '[class^="gg-"]', '[class*="-gg"]',
                        '[id^="gg"]', '[class*="广告"]', '[id*="广告"]',
                        '[class*="gudingwei"]', '[id*="gudingwei"]',
                        '[class*="jioeidd"]', '[id*="jioeidd"]',
                        '[class*="cqlkxq1wc"]', '[id*="cqlkxq1wc"]',
                        '[class*="tuiguang"]', '[id*="tuiguang"]',
                        '[class*="floatad"]', '[id*="floatad"]',
                        '[class*="popupad"]', '[id*="popupad"]',
                        '[class*="adpic"]', '[id*="adpic"]',
                        '[class*="adimg"]', '[id*="adimg"]',
                    ];
                    souloSubscriptionSelectors.forEach(function(sel) {
                        if (sel) selectors.push(sel);
                    });
                    selectors.forEach(function(sel) {
                        try {
                            document.querySelectorAll(sel).forEach(function(el) {
                                hiddenCount++;
                                var host = hostFromElement(el);
                                if (looksLikeTrackerHost(host)) trackerHosts.push(host);
                                el.remove();
                            });
                        } catch(e) {}
                    });
                }

                function hasAdLikeResource(el) {
                    try {
                        var html = (el.outerHTML || '').toLowerCase();
                        var bg = window.getComputedStyle(el).backgroundImage || '';
                        return /cpcad|gudingwei|jioeidd|cqlkxq1wc|adpic|adimg|floatad|popupad|\\/ads?\\/|adserver|doubleclick|googlesyndication|tuiguang|广告|推广|sponsor|data:image\\/(jpg|jpeg|png|gif);base64/.test(html + ' ' + bg);
                    } catch(e) {
                        return false;
                    }
                }

                function isLikelyFloatingAd(el) {
                    try {
                        if (!el || el === document.body || el === document.documentElement) return false;
                        var s = window.getComputedStyle(el);
                        var position = s.position;
                        var z = parseInt(s.zIndex, 10) || 0;
                        if (position !== 'fixed' && position !== 'absolute') return false;
                        if (z < 999) return false;

                        var r = el.getBoundingClientRect();
                        var coversMostScreen = r.width > window.innerWidth * 0.92 && r.height > window.innerHeight * 0.72;
                        var smallFloating = r.width >= 20 && r.height >= 20 && r.width <= 900 && r.height <= 420;
                        if (!coversMostScreen && !smallFloating) return false;

                        var text = (el.textContent || '').toLowerCase();
                        var adText = text.includes('ad') || text.includes('广告') || text.includes('推广') || text.includes('sponsor');
                        return adText || hasAdLikeResource(el) || !!el.querySelector('iframe[src*="ad"], iframe[src*="doubleclick"], img[src*="ad"], a[href*="ad"]');
                    } catch(e) {
                        return false;
                    }
                }

                // Remove fixed/absolute overlays with high z-index (popup and floating ads)
                if (souloPopupEnabled) try {
                    document.querySelectorAll('div, section, aside, iframe, a, img').forEach(function(el) {
                        if (isLikelyFloatingAd(el)) {
                            hiddenCount++;
                            var host = hostFromElement(el);
                            if (looksLikeTrackerHost(host)) trackerHosts.push(host);
                            el.remove();
                        }
                    });
                } catch(e) {}

                // Restore scroll if ads locked it
                if (souloPopupEnabled) try {
                    document.body.style.overflow = '';
                    document.documentElement.style.overflow = '';
                } catch(e) {}

                if (hiddenCount > 0 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.souloAdBlocker) {
                    try {
                        window.webkit.messageHandlers.souloAdBlocker.postMessage({
                            host: location.hostname,
                            hiddenCount: hiddenCount,
                            trackerHosts: Array.from(new Set(trackerHosts)).slice(0, 80)
                        });
                    } catch(e) {}
                }
            }

            removeAds();

            var observer = new MutationObserver(function(mutations) {
                var needsClean = false;
                mutations.forEach(function(m) { if (m.addedNodes.length > 0) needsClean = true; });
                if (needsClean) {
                    clearTimeout(observer._timer);
                    observer._timer = setTimeout(removeAds, 100);
                }
            });
            if (document.body) {
                observer.observe(document.body, { childList: true, subtree: true });
            }
        })();
        """
    }
}
