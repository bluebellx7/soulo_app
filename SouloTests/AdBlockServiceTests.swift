import XCTest
import WebKit
@testable import Soulo

final class AdBlockServiceTests: XCTestCase {
    private var savedBuiltInOverrides: Data?
    private var savedBuiltInRevision: String?
    private var savedSubscriptionCache: Data?
    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSubscriptionCache = defaults.data(forKey: "soulo_ad_block_subscription_rules")
        defaults.set(try? JSONEncoder().encode(ParsedAdBlockRules.empty), forKey: "soulo_ad_block_subscription_rules")
        savedBuiltInOverrides = defaults.data(forKey: BuiltInAdRuleStore.storageKey)
        savedBuiltInRevision = defaults.string(forKey: BuiltInAdRuleStore.versionKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        defaults.removeObject(forKey: BuiltInAdRuleStore.versionKey)
    }
    override func tearDown() {
        let defaults = UserDefaults.standard
        defaults.set(savedSubscriptionCache, forKey: "soulo_ad_block_subscription_rules")
        defaults.set(savedBuiltInOverrides, forKey: BuiltInAdRuleStore.storageKey)
        defaults.set(savedBuiltInRevision, forKey: BuiltInAdRuleStore.versionKey)
        super.tearDown()
    }

    func testEveryNativeBatchKeepsCloudflareVerificationExceptions() throws {
        for json in AdBlockService.encodedContentRuleLists(batchSize: 2) {
            let data = try XCTUnwrap(json.data(using: .utf8))
            let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            for filter in WebCompatibilityService.verificationResourceURLFilters {
                XCTAssertTrue(rules.contains { rule in
                    (rule["trigger"] as? [String: Any])?["url-filter"] as? String == filter
                        && (rule["action"] as? [String: Any])?["type"] as? String == "ignore-previous-rules"
                })
            }
        }
    }

    @MainActor func testNativeFilteringAllowsChallengeResourcesAndFramesButKeepsBlockingAds() async throws {
        let parsed = ParsedAdBlockRules(networkURLFilters: [], cosmeticSelectors: [".qa-ad"],
            networkRules: [AdBlockNetworkRule(urlFilter: ".*", resourceTypes: ["script"])])
        UserDefaults.standard.set(try JSONEncoder().encode(parsed), forKey: "soulo_ad_block_subscription_rules")
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/page": Data("""
            <script src='/cdn-cgi/challenge-platform/h/g/probe.js'></script><script src='/advert.js'></script>
            <div id='advert' class='qa-ad'>Advertisement</div><iframe src='/cdn-cgi/challenge-platform/h/g/widget'></iframe>
            """.utf8),
            "/cdn-cgi/challenge-platform/h/g/probe.js": Data("window.challengeLoaded=true;".utf8),
            "/advert.js": Data("window.advertLoaded=true;".utf8),
            "/cdn-cgi/challenge-platform/h/g/widget": Data("<div id='verification' class='qa-ad'>Verification</div>".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let compiled = await AdBlockService.compileRuleLists()
        let rules = try XCTUnwrap(compiled)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        rules.forEach(config.userContentController.add)
        let web = WKWebView(frame: .zero, configuration: config)
        web.load(URLRequest(url: root.appendingPathComponent("page")))
        for _ in 0..<160 {
            let ready = try? await web.evaluateJavaScript("window.challengeLoaded===true && !!document.querySelector('iframe')?.contentDocument?.getElementById('verification')")
            if ready as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let result = try await web.evaluateJavaScript("""
        ({challenge:window.challengeLoaded===true,advert:window.advertLoaded===true,
        advertDisplay:getComputedStyle(document.getElementById('advert')).display,
        widgetDisplay:getComputedStyle(document.querySelector('iframe').contentDocument.getElementById('verification')).display})
        """) as? [String: Any]
        XCTAssertEqual(result?["challenge"] as? Bool, true)
        XCTAssertEqual(result?["advert"] as? Bool, false)
        XCTAssertEqual(result?["advertDisplay"] as? String, "none")
        XCTAssertNotEqual(result?["widgetDisplay"] as? String, "none")
    }

    @MainActor
    func testSiteAllowlistAlsoBypassesFilteringInsideCrossOriginPlayers() async throws {
        let parsed = ParsedAdBlockRules(networkURLFilters: [], cosmeticSelectors: [".qa-overlay"],
            networkRules: [AdBlockNetworkRule(urlFilter: "ad-probe", resourceTypes: ["script"])])
        UserDefaults.standard.set(try JSONEncoder().encode(parsed), forKey: "soulo_ad_block_subscription_rules")
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/parent.html": Data("""
            <script>addEventListener('message', e => window.childResult=e.data);</script>
            <iframe id='player'></iframe><script>player.src=location.origin.replace('127.0.0.1','localhost')+'/child.html';</script>
            """.utf8),
            "/child.html": Data("""
            <div class='qa-overlay'>Player overlay</div><script src='/ad-probe.js'></script>
            <script>addEventListener('load',()=>setTimeout(()=>parent.postMessage({
              loaded:window.advertLoaded===true,
              visible:getComputedStyle(document.querySelector('.qa-overlay')).display!=='none'
            },'*'),150));</script>
            """.utf8),
            "/ad-probe.js": Data("window.advertLoaded=true;".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        for allowlisted in [false, true] {
            let hosts = allowlisted ? ["127.0.0.1"] : []
            let compiled = await AdBlockService.compileRuleLists(allowlistedHosts: hosts)
            let rules = try XCTUnwrap(compiled)
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            rules.forEach(config.userContentController.add)
            config.userContentController.addUserScript(WKUserScript(
                source: AdBlockService.adHidingScript(allowlistedHosts: hosts),
                injectionTime: .atDocumentStart, forMainFrameOnly: false))
            let web = WKWebView(frame: .zero, configuration: config)
            web.load(URLRequest(url: root.appendingPathComponent("parent.html")))
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("!!window.childResult")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let result = try await web.evaluateJavaScript("window.childResult") as? [String: Any]
            XCTAssertEqual(result?["loaded"] as? Bool, allowlisted, "A site's ad switch must also control its embedded player's resources")
            XCTAssertEqual(result?["visible"] as? Bool, allowlisted, "A site's ad switch must also control its embedded player's overlays")
            web.stopLoading()
        }
    }

    @MainActor
    func testFilteredPlayerAdClosesItsOwnStateAndAllowsPlayback() async throws {
        for midroll in [false, true] {
            let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
            let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 300), configuration: config)
            web.loadHTMLString("""
            <div class="xgct-static-ads xgct-static-ads--blocking" id="ads">
            <section class="xgct-static-ad xgct-static-ad--modal" id="modal">
              <div class="xgct-static-ad__content"><div data-soulo-hidden-ad style="display:none">Filtered ad</div></div>
              <button class="xgct-static-ad__close" id="close" disabled>Close</button>
            </section></div>
            <button id="play">Play video</button>
            <script>
            window.blocking=true; window.plays=0; const closeButton=document.getElementById('close');
            closeButton.addEventListener('click',()=>{
              if (\(midroll ? "true" : "false") && closeButton.disabled) return;
              blocking=false; modal.hidden=true; ads.classList.remove('xgct-static-ads--blocking');
            });
            play.addEventListener('click',()=>{ if(!blocking) plays++; });
            window.fixtureReady=true;
            </script>
            """, baseURL: URL(string: "https://pframe.xgcartoon.com/pframe/player.htm"))
            for _ in 0..<200 {
                if (try? await web.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let script = """
            function adBlockConfig(){ return {cosmeticEnabled:true}; }
            function shouldDisableAdBlock(){ return false; }
            \(WebAdOverlayCleanup.source)
            cleanupAdOverlays(); null
            """
            _ = try await web.evaluateJavaScript(script)
            if midroll {
                let waiting = try await web.evaluateJavaScript("blocking && closeButton.disabled") as? Bool
                XCTAssertEqual(waiting, true, "Keep the player's own mid-roll close condition")
                _ = try await web.evaluateJavaScript("closeButton.disabled=false; null")
            }
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("!blocking")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let result = try await web.evaluateJavaScript("play.click(); ({closed:modal.hidden,plays:plays})") as? [String: Any]
            XCTAssertEqual(result?["closed"] as? Bool, true)
            XCTAssertEqual(result?["plays"] as? Int, 1, "Removing the ad must also release the player's playback lock")
        }
    }

    @MainActor
    func testClosingFilteredPauseAdPreservesPauseAndRestoresPlay() async throws {
        let web = WKWebView()
        web.loadHTMLString("""
        <div class="xgct-static-ad-host"><video id="video"></video>
        <div class="xgct-static-ads--blocking" id="ads"><section class="xgct-static-ad--modal" id="modal" data-slot="pause">
        <button class="xgct-static-ad__close" id="ad-close">Continue</button></section></div></div>
        <script>
        window.playCalls=0;video.play=()=>{playCalls++;return Promise.resolve();};
        window.originalPlay=video.play;
        document.getElementById('ad-close').addEventListener('click',()=>{
          modal.hidden=true;ads.classList.remove('xgct-static-ads--blocking');video.play();
        });window.fixtureReady=true;
        </script>
        """, baseURL: URL(string: "https://pframe.xgcartoon.com/pframe/player.htm"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("""
        function adBlockConfig(){return {cosmeticEnabled:true};}
        function shouldDisableAdBlock(){return false;}
        \(WebAdOverlayCleanup.source)
        cleanupAdOverlays();null
        """)
        let result = try await web.evaluateJavaScript("({closed:modal.hidden,plays:playCalls,restored:video.play===originalPlay})") as? [String: Any]
        XCTAssertEqual(result?["closed"] as? Bool, true)
        XCTAssertEqual(result?["plays"] as? Int, 0, "Ad cleanup must not undo the user's Pause")
        XCTAssertEqual(result?["restored"] as? Bool, true)
        _ = try await web.evaluateJavaScript("video.play();null")
        let plays = try await web.evaluateJavaScript("playCalls") as? Int
        XCTAssertEqual(plays, 1, "Subsequent user playback must use the original implementation")
    }

    @MainActor
    func testDocumentStartFilteringWaitsForTheDocumentElement() async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(ParsedAdBlockRules(cosmeticSelectors: [".qa-late-ad"])), forKey: "soulo_ad_block_subscription_rules")
        let web = WKWebView()
        web.loadHTMLString("<p id='ready'>Document startup fixture</p>", baseURL: URL(string: "https://example.com/"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.evaluateJavaScript("document.documentElement.remove(); null")
        _ = try await web.evaluateJavaScript(AdBlockService.adHidingScript() + "\nnull")
        _ = try await web.evaluateJavaScript("""
        const root=document.createElement('html');root.innerHTML='<body><div class="qa-late-ad">Ad</div></body>';document.append(root);null
        """)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("getComputedStyle(document.querySelector('.qa-late-ad')).display==='none'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let installed = try await web.evaluateJavaScript("!!window.__souloAdBlockObserver && getComputedStyle(document.querySelector('.qa-late-ad')).display==='none'") as? Bool
        XCTAssertEqual(installed, true, "Document-start timing must not abort the runtime before its observer is installed")
    }

    func testNativeCosmeticFilteringOnlyRemovesSafeDuplicateWork() {
        let plain = AdBlockCosmeticRule(selector: ".advert-slot")
        let domain = AdBlockCosmeticRule(selector: ".sponsor", ifDomains: ["*example.com"])
        let mixed = AdBlockCosmeticRule(selector: ".conditional", ifDomains: ["example.com"], unlessDomains: ["sub.example.com"])
        let excepted = AdBlockCosmeticRule(selector: ".excepted")
        let overlay = AdBlockCosmeticRule(selector: ".popup-ad")
        let rules = [plain, domain, mixed, excepted, overlay]
        let remaining = AdBlockService.javaScriptCosmeticRules(rules, exceptions: [excepted],
            hasGenericExceptions: false, nativeFiltering: true)
        XCTAssertEqual(remaining, [mixed, excepted, overlay])
        XCTAssertEqual(AdBlockService.javaScriptCosmeticRules(rules, exceptions: [excepted],
            hasGenericExceptions: false, nativeFiltering: false), rules, "Compilation failure retains the full fallback")
        XCTAssertTrue(AdBlockService.javaScriptCosmeticRules([plain], exceptions: [],
            hasGenericExceptions: true, nativeFiltering: true).contains(plain))
    }

    func testNativeCosmeticFilteringReducesLargeSubscriptionPayload() throws {
        let rules = ParsedAdBlockRules(networkURLFilters: [], cosmeticSelectors: [],
            cosmeticRules: (0..<10_000).map { AdBlockCosmeticRule(selector: ".qa-ad-\($0)") })
        UserDefaults.standard.set(try JSONEncoder().encode(rules), forKey: "soulo_ad_block_subscription_rules")
        let fallback = AdBlockService.adHidingScript()
        let native = AdBlockService.adHidingScript(nativeCosmeticFiltering: true)
        XCTAssertLessThan(native.utf8.count, fallback.utf8.count / 2)
        print("NATIVE_AD_SCRIPT_BYTES fallback=\(fallback.utf8.count), native=\(native.utf8.count)")
    }

    func testLegacyImageBannerOverrideKeepsChoiceButNoLongerRevealsOnPicker() throws {
        let suite = "ImageBannerMigration-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var rule = BuiltInAdRule(id: "paired-image-banner", kind: .cosmetic,
            pattern: ":root:not([data-soulo-ad-picker-active]) [data-soulo-image-banner]")
        rule.isEnabled = false
        rule.domains = ["example.com"]
        defaults.set(try JSONEncoder().encode([rule.id:rule]), forKey: BuiltInAdRuleStore.storageKey)
        let effective = try XCTUnwrap(BuiltInAdRuleStore.effectiveRules(defaults:defaults).first { $0.id == rule.id })
        XCTAssertEqual(effective.pattern, ManualAdBlockRuntime.imageBannerSelector)
        XCTAssertFalse(effective.isEnabled)
        XCTAssertEqual(effective.domains, rule.domains)
        rule.pattern = ".custom-ad"
        defaults.set(try JSONEncoder().encode([rule.id:rule]), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertEqual(BuiltInAdRuleStore.effectiveRules(defaults:defaults).first { $0.id == rule.id }?.pattern, ".custom-ad")
    }

    @MainActor
    func testBuiltInEditsPersistValidateAndReset() async throws {
        let suite = "BuiltInRulesTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BuiltInAdRuleStore(defaults: defaults)
        var rule = try XCTUnwrap(store.rules.first { $0.kind == .network })
        let original = rule
        rule.pattern = "qa-tracker\\.example"
        rule.domains = ["news.example.com"]
        rule.isEnabled = false
        let saved = await store.save(rule)
        XCTAssertTrue(saved)
        XCTAssertEqual(BuiltInAdRuleStore(defaults: defaults).rules.first { $0.id == rule.id }, rule)
        XCTAssertNotEqual(BuiltInAdRuleStore.signature(defaults: defaults), "default")
        var invalid = rule
        invalid.resourceTypes = ["document"]
        let rejected = await store.save(invalid)
        XCTAssertFalse(rejected)
        XCTAssertEqual(store.rules.first { $0.id == rule.id }, rule)
        invalid = rule
        invalid.pattern = "["
        let invalidRegex = await store.save(invalid)
        XCTAssertFalse(invalidRegex)
        store.reset(rule.id)
        XCTAssertEqual(store.rules.first { $0.id == rule.id }, original)
        var cosmetic = try XCTUnwrap(store.rules.first { $0.kind == .cosmetic })
        cosmetic.pattern = ".qa-promotion"
        let cosmeticSaved = await store.save(cosmetic)
        XCTAssertTrue(cosmeticSaved)
        store.reset()
        XCTAssertEqual(store.rules, AdBlockService.defaultBuiltInRules)
        XCTAssertEqual(Set(store.rules.map(\.id)).count, store.rules.count)
        print("BUILT_IN_RULE_COUNT", store.rules.count)
    }

    @MainActor
    func testDisabledBuiltInRulesLeaveNativeAndScriptOutputs() async throws {
        let defaults = UserDefaults.standard
        let keys = [BuiltInAdRuleStore.storageKey, BuiltInAdRuleStore.versionKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        defaults.removeObject(forKey: BuiltInAdRuleStore.storageKey)
        let store = BuiltInAdRuleStore(defaults: defaults)
        var rule = try XCTUnwrap(store.rules.first { $0.kind == .network })
        rule.isEnabled = false
        let disabled = await store.save(rule)
        XCTAssertTrue(disabled)
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        XCTAssertFalse(json.contains(rule.pattern))
        XCTAssertTrue(json.contains("googleadservices"))
        var cosmetic = try XCTUnwrap(store.rules.first { $0.kind == .cosmetic })
        cosmetic.pattern = ".unique-qa-sponsor"
        let edited = await store.save(cosmetic)
        XCTAssertTrue(edited)
        XCTAssertTrue(AdBlockService.encodedContentRuleList()!.contains("unique-qa-sponsor"))
        XCTAssertTrue(AdBlockService.adHidingScript(cosmetic: true).contains("unique-qa-sponsor"))
        cosmetic.isEnabled = false
        let hidden = await store.save(cosmetic)
        XCTAssertTrue(hidden)
        XCTAssertFalse(AdBlockService.encodedContentRuleList()!.contains("unique-qa-sponsor"))
        XCTAssertFalse(AdBlockService.adHidingScript(cosmetic: true).contains("unique-qa-sponsor"))
    }

    func testDomainRulesRequireActualHostAndPreserveEditedLegacyRules() throws {
        let rules = AdBlockService.defaultBuiltInRules
        let domains = rules.filter { $0.isEnabled && $0.id.hasPrefix("domain:") }
        for rule in domains {
            let regex = try NSRegularExpression(pattern: rule.pattern)
            for url in ["https://example.com/help?url=https://doubleclick.net/", "https://doubleclick.net.example.com/image.png", "https://notdoubleclick.net/image.png"] {
                XCTAssertNil(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), rule.id + " matched " + url)
            }
        }
        let rule = try XCTUnwrap(domains.first { $0.id == "domain:doubleclick\\.net" })
        for url in ["https://doubleclick.net/ad.js", "https://ad.doubleclick.net/ad.js"] {
            XCTAssertNotNil(url.range(of: rule.pattern, options: .regularExpression))
        }
        let suite = "ConservativeRuleDefaults-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var edited = try XCTUnwrap(rules.first { $0.id == "pattern:/gg/" })
        XCTAssertFalse(edited.isEnabled)
        edited.isEnabled = true
        edited.domains = ["chosen.example"]
        defaults.set(try JSONEncoder().encode([edited.id: edited]), forKey: BuiltInAdRuleStore.storageKey)
        XCTAssertEqual(BuiltInAdRuleStore.effectiveRules(defaults: defaults).first { $0.id == edited.id }, edited)
        print("CONSERVATIVE_RULE_DEFAULTS", rules.count, rules.filter(\.isEnabled).count)
    }

    func testProductionRuleCompilationFromBackgroundTask() async {
        let rules = await Task.detached {
            await AdBlockService.compileRuleLists(allowlistedHosts: ["soulo-test.example"])
        }.value
        XCTAssertNotNil(rules)
    }

    func testEncodedContentRulesAreValidAndContainBlockActions() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        XCTAssertFalse(rules.isEmpty)
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "block"
        })
        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any] else { return false }
            return action["type"] as? String == "css-display-none"
        })
    }

    func testNetworkBlockRulesDoNotTargetMainDocuments() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])

        let blockRules = rules.filter { rule in
            (rule["action"] as? [String: Any])?["type"] as? String == "block"
        }

        XCTAssertFalse(blockRules.isEmpty)
        for rule in blockRules {
            let trigger = try XCTUnwrap(rule["trigger"] as? [String: Any])
            let resourceTypes = try XCTUnwrap(trigger["resource-type"] as? [String])
            XCTAssertFalse(resourceTypes.contains("document"))
        }
    }

    func testEncodedContentRulesCompileWithWebKit() async throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let identifier = "SouloTests-\(UUID().uuidString)"

        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesSanitizeLegacyUnsupportedURLFilters() async throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let oldData = defaults.data(forKey: key)
        defer {
            if let oldData {
                defaults.set(oldData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let cached = ParsedAdBlockRules(
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: #"/waWQiOjE.*=eyJ\.js([\\/:?&=]|$)"#,
                    resourceTypes: ["script"]
                )
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())

        XCTAssertFalse(json.contains(#"([\\/:?&=]|$)"#))
        _ = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "SouloLegacyFilterTest-\(UUID().uuidString)",
            encodedContentRuleList: json
        )
    }

    func testEncodedContentRulesIncludeAllowlistDomains() throws {
        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList(allowlistedHosts: ["www.example.com"]))
        let data = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let firstTrigger = try XCTUnwrap(rules.first?["trigger"] as? [String: Any])
        let unlessDomain = try XCTUnwrap(firstTrigger["unless-domain"] as? [String])

        XCTAssertTrue(unlessDomain.contains("*example.com"))
        XCTAssertTrue(unlessDomain.contains("example.com"))
        XCTAssertFalse(unlessDomain.contains("*weixin.qq.com"))
        XCTAssertFalse(unlessDomain.contains("weixin.qq.com"))
        XCTAssertFalse(unlessDomain.contains("*xiaohongshu.com"))
    }

    func testEncodedContentRulesPreserveSupportedStructuredConditionsAndSkipUnsupportedMixedDomains() throws {
        let defaults = UserDefaults.standard
        let key = "soulo_ad_block_subscription_rules"
        let oldData = defaults.data(forKey: key)
        defer {
            if let oldData {
                defaults.set(oldData, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let cached = ParsedAdBlockRules(
            networkURLFilters: ["tracker\\.example"],
            cosmeticSelectors: [],
            networkRules: [
                AdBlockNetworkRule(
                    urlFilter: "tracker\\.example",
                    resourceTypes: ["script"],
                    loadTypes: ["third-party"],
                    ifDomains: ["*example.com"],
                    unlessDomains: ["*admin.example.com"]
                ),
                AdBlockNetworkRule(
                    urlFilter: "scoped\\.example",
                    resourceTypes: ["script"],
                    loadTypes: ["third-party"],
                    ifDomains: ["*example.com"]
                )
            ],
            cosmeticRules: [
                AdBlockCosmeticRule(selector: ".site-ad", ifDomains: ["*example.com"])
            ]
        )
        let data = try JSONEncoder().encode(cached)
        defaults.set(data, forKey: key)

        let json = try XCTUnwrap(AdBlockService.encodedContentRuleList())
        let jsonData = try XCTUnwrap(json.data(using: .utf8))
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]])

        XCTAssertFalse(rules.contains { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (trigger["url-filter"] as? String) == "tracker\\.example"
        })

        XCTAssertTrue(rules.contains { rule in
            guard let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (trigger["url-filter"] as? String) == "scoped\\.example"
                && (trigger["resource-type"] as? [String]) == ["script"]
                && (trigger["load-type"] as? [String]) == ["third-party"]
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
                && trigger["unless-domain"] == nil
        })

        XCTAssertTrue(rules.contains { rule in
            guard let action = rule["action"] as? [String: Any],
                  let trigger = rule["trigger"] as? [String: Any] else { return false }
            return (action["type"] as? String) == "css-display-none"
                && (action["selector"] as? String)?.hasPrefix(":root:not([data-soulo-native-ads-disabled]) :is(.site-ad)") == true
                && ((trigger["if-domain"] as? [String])?.contains("*example.com") == true)
                && trigger["unless-domain"] == nil
        })

        for rule in rules {
            guard let trigger = rule["trigger"] as? [String: Any] else { continue }
            let domainConditionCount = ["if-domain", "unless-domain", "if-top-url", "unless-top-url"]
                .filter { trigger[$0] != nil }
                .count
            XCTAssertLessThanOrEqual(domainConditionCount, 1)
        }
    }

    func testBuiltInDefaultsRetainExplicitAdPatternsAndDisableWeakNames() throws {
        let rules = AdBlockService.defaultBuiltInRules
        for id in ["pattern:cpcad", "pattern:floatad", "pattern:popupad", "selector:#float-bottom-ad"] {
            XCTAssertEqual(rules.first { $0.id == id }?.isEnabled, true)
        }
        for id in ["pattern:gudingwei", "pattern:jioeidd", "pattern:adpic", "pattern:cqlkxq1wc", "selector:.gg"] {
            XCTAssertEqual(rules.first { $0.id == id }?.isEnabled, false)
        }
    }

    func testAdHidingScriptUsesExplicitAdSelectorsWithoutGenericPopupScanning() {
        let script = AdBlockService.adHidingScript(cosmetic: true)

        XCTAssertFalse(script.contains("isLikelyFloatingAd"))
        XCTAssertFalse(script.contains("div, section, aside, iframe, a, img"))
        XCTAssertTrue(script.contains("hideAdElement"))
        XCTAssertTrue(script.contains("isProtectedPageElement"))
        XCTAssertFalse(script.contains("el.remove()"))
        XCTAssertTrue(script.contains("adpic"))
        XCTAssertTrue(script.contains("adimg"))
        XCTAssertTrue(script.contains("floatad"))
    }

    func testAdHidingScriptChecksRuntimeAllowlist() {
        let script = AdBlockService.adHidingScript(
            cosmetic: true,
            allowlistedHosts: ["example.com"]
        )

        XCTAssertTrue(script.contains("souloAllowlistedHosts"))
        XCTAssertTrue(script.contains("isSouloAllowlisted"))
        XCTAssertTrue(script.contains("example.com"))
    }

    func testBuiltInRulesPreservePBPBWPlayerScripts() throws {
        let rules = AdBlockService.defaultBuiltInRules
        XCTAssertFalse(rules.contains { $0.id.hasPrefix("pbpbw:") })
        for url in [
            "https://www.pbpbw.com/assets/chunks/site-render.js?v=2",
            "https://www.pbpbw.com/static/js/playerconfig.js?t=20261015",
            "https://www.pbpbw.com/static/js/player.js?t=a20261015",
            "https://www.pbpbw.com/statics/js/stui_default.js"
        ] {
            for rule in rules where rule.isEnabled && rule.kind == .network {
                let hostMatches = rule.domains.isEmpty || rule.domains.contains("pbpbw.com")
                guard hostMatches else { continue }
                let regex = try NSRegularExpression(pattern: rule.pattern)
                XCTAssertNil(regex.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)), "\(rule.id) blocks \(url)")
            }
        }
    }

}
