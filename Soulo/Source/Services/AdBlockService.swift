import WebKit

struct AdBlockService {

    // MARK: - Content Rule List (blocks network requests to ad domains)

    static func compileRules() async -> WKContentRuleList? {
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
        ]

        var rulesArray: [[String: Any]] = adDomains.map { domain in
            [
                "trigger": ["url-filter": domain],
                "action": ["type": "block"]
            ]
        }

        // Block common ad resource patterns
        let adPatterns = [
            "/ads/", "/adserver", "/adclick", "/adview",
            "adsense", "adsbygoogle", "/pagead/",
            "doubleclick\\.net", "/ad\\.js", "/ads\\.js",
        ]
        for pattern in adPatterns {
            rulesArray.append([
                "trigger": ["url-filter": pattern, "resource-type": ["script", "image", "raw"]],
                "action": ["type": "block"]
            ])
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: rulesArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "SouloAdBlock",
                    encodedContentRuleList: jsonString
                ) { ruleList, error in
                    continuation.resume(returning: ruleList)
                }
            }
        }
    }

    // MARK: - CSS + JS injection to hide ad elements

    static var adHidingScript: String {
        """
        (function() {
            var style = document.createElement('style');
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
                [class*="floating-ad"], [class*="sticky-ad"] {
                    display: none !important;
                    height: 0 !important;
                    max-height: 0 !important;
                    overflow: hidden !important;
                    visibility: hidden !important;
                    pointer-events: none !important;
                }
            `;
            (document.head || document.documentElement).appendChild(style);

            function removeAds() {
                var selectors = [
                    'ins.adsbygoogle', 'div[id^="div-gpt-ad"]',
                    'iframe[src*="doubleclick"]', 'iframe[src*="googlesyndication"]',
                    'iframe[src*="ads."]', '[data-ad-slot]',
                    '.adsbygoogle', '[id*="google_ads"]',
                    'div[class*="ad-container"]', 'div[class*="ad-wrapper"]',
                    '[class*="outbrain-widget"]', '[class*="taboola"]',
                    'div[id*="ad-"]', 'div[data-ad]',
                    // Baidu search ads
                    '#content_right .result-op[data-click]',
                    '.ec_tuiguang_pplink',
                    // Generic large fixed overlays (likely ad popups)
                ];
                selectors.forEach(function(sel) {
                    try {
                        document.querySelectorAll(sel).forEach(function(el) {
                            el.remove();
                        });
                    } catch(e) {}
                });

                // Remove fixed-position overlays with high z-index (popup ads)
                try {
                    document.querySelectorAll('div, section, aside').forEach(function(el) {
                        var s = window.getComputedStyle(el);
                        if (s.position === 'fixed' && parseInt(s.zIndex) > 9000 &&
                            el.offsetHeight > 100 && el.offsetWidth > 200) {
                            var text = (el.textContent || '').toLowerCase();
                            if (text.includes('ad') || text.includes('广告') ||
                                text.includes('推广') || text.includes('sponsor') ||
                                el.querySelector('iframe') || el.querySelector('img[src*="ad"]')) {
                                el.remove();
                            }
                        }
                    });
                } catch(e) {}

                // Restore scroll if ads locked it
                try {
                    document.body.style.overflow = '';
                    document.documentElement.style.overflow = '';
                } catch(e) {}
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
