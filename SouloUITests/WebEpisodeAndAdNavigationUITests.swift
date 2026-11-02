import XCTest

final class WebEpisodeAndAdNavigationUITests: XCTestCase {
    @MainActor
    func testUnprocessedBaiduPlaybackBaseline() throws {
        guard ProcessInfo.processInfo.environment["SOULO_RAW_BASELINE_QA"] == "1" else {
            throw XCTSkip("Opt-in isolated WKWebView baseline, requires the separate RawBrowser app")
        }
        let profiles = (ProcessInfo.processInfo.environment["SOULO_BASELINE_PROFILES"] ?? "system,inline,autoplay,ua").split(separator: ",").map(String.init)
        let entries = (ProcessInfo.processInfo.environment["SOULO_BASELINE_ENTRIES"] ?? "title,picture,source").split(separator: ",").map(String.init)
        var observations: [[String: Any]] = []
        func state(_ app: XCUIApplication) -> [String: Any]? {
            let label = app.staticTexts["baseline.state"].firstMatch
            guard label.exists, let value = label.value as? String, let data = value.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        func front(_ value: [String: Any]?) -> [String: Any]? {
            let views = value?["views"] as? [[String: Any]] ?? []
            return views.last(where: { $0["inWindow"] as? Bool == true }) ?? views.last
        }
        func tapRect(_ name: String, app: XCUIApplication) -> Bool {
            guard let view = front(state(app)), let frame = view["frame"] as? [String: Double],
                  let page = view["state"] as? [String: Any], let rect = page[name] as? [String: Double],
                  let width = rect["w"], width > 0, let height = rect["h"], height > 0,
                  let innerWidth = page["innerWidth"] as? Double, innerWidth > 0 else { return false }
            let scale = (frame["w"] ?? innerWidth) / innerWidth
            let x = (frame["x"] ?? 0) + ((rect["x"] ?? 0) + width / 2) * scale
            let y = (frame["y"] ?? 0) + ((rect["y"] ?? 0) + height / 2) * scale
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: x, dy: y)).tap()
            return true
        }
        func revealControls(_ app: XCUIApplication) {
            guard let view=front(state(app)), let frame=view["frame"] as? [String: Double],
                  let page=view["state"] as? [String:Any], let width=page["innerWidth"] as? Double,
                  let media=(page["media"] as? [[String:Any]])?.first,
                  let x=media["x"] as? Double, let y=media["y"] as? Double, let w=media["w"] as? Double, w>0 else { return }
            let scale=(frame["w"] ?? width)/width
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx:(frame["x"] ?? 0)+(x+w/2)*scale,dy:(frame["y"] ?? 0)+(y+20)*scale)).tap()
            Thread.sleep(forTimeInterval: 1.1)
        }
        for profile in profiles {
            for entry in entries {
                let app = XCUIApplication(bundleIdentifier: "com.soulo.qa.RawBrowser.\(profile)")
                app.launchArguments = ["-profile", profile, "-entry", entry]
                let cloneAudit = ProcessInfo.processInfo.environment["SOULO_BASELINE_CLONE_AUDIT"] == "1"
                if cloneAudit { app.launchArguments += ["-cloneAudit", "YES"] }
                app.launch()
                var observation: [String: Any] = ["profile": profile, "entry": entry]
                let title = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "又挖出一部宝藏")).firstMatch
                guard title.waitForExistence(timeout: 35) else {
                    observation["unavailable"] = "Reported card not returned"
                    observations.append(observation)
                    let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "baseline-\(profile)-\(entry)-unavailable"; shot.lifetime = .keepAlways; add(shot)
                    app.terminate(); continue
                }
                for _ in 0..<6 where !title.isHittable { app.webViews.firstMatch.swipeUp() }
                if title.frame.maxY + 160 > app.frame.maxY - 70 { app.webViews.firstMatch.swipeUp() }
                Thread.sleep(forTimeInterval: 6)
                if ProcessInfo.processInfo.environment["SOULO_BASELINE_UNMUTE_SOURCE"] == "1" {
                    let sound = app.webViews.images.matching(NSPredicate(format:"label CONTAINS %@","打开视频声音")).firstMatch
                    if sound.exists && sound.isHittable { sound.tap(); Thread.sleep(forTimeInterval:1.1) }
                }
                observation["before"] = state(app)
                let views = state(app)?["views"] as? [[String: Any]] ?? []
                XCTAssertFalse(views.isEmpty, "The read-only baseline state must be observable")
                let expectedScripts = (profile == "script-all" ? 7 : profile == "script-handoff" ? 2 : profile.hasPrefix("script-") ? 1 : 0) + (cloneAudit ? 1 : 0)
                XCTAssertTrue(views.allSatisfy { $0["scripts"] as? Int == expectedScripts }, "Verify the isolated profile script count")
                if entry == "source" {
                    let source = app.webViews.staticTexts["B站精选"].firstMatch
                    for _ in 0..<3 where !source.isHittable { app.webViews.firstMatch.swipeUp() }
                    if source.exists && source.isHittable { source.tap() }
                    else { observation["unavailable"] = "Source label not hittable" }
                } else if entry == "picture" {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: title.frame.maxY + 100)).tap()
                } else {
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: title.frame.midY)).tap()
                }
                Thread.sleep(forTimeInterval: 5)
                observation["afterEntry"] = state(app)
                let sample = app.buttons["采样"].firstMatch
                if sample.exists && sample.isHittable { sample.tap() }
                let entered = XCTAttachment(screenshot: app.screenshot()); entered.name = "baseline-\(profile)-\(entry)-entered"; entered.lifetime = .keepAlways; add(entered)
                if front(state(app))?["url"] as? String == "m.baidu.com/video/page" {
                    if !tapRect("soundRect", app: app) { revealControls(app);observation["soundControlAvailable"] = tapRect("soundRect", app: app) }
                    else { observation["soundControlAvailable"] = true }
                    Thread.sleep(forTimeInterval: 1.1)
                    observation["soundTap1"] = state(app)
                    if !tapRect("soundRect", app: app) { revealControls(app);_ = tapRect("soundRect", app: app) }
                    Thread.sleep(forTimeInterval: 1.1)
                    observation["soundTap2"] = state(app)
                    if !tapRect("playRect", app: app) { revealControls(app);_ = tapRect("playRect", app: app) }
                    Thread.sleep(forTimeInterval: 1.1)
                    observation["pauseTap"] = state(app)
                    // Baidu auto-hides its controls: the first touch can reveal
                    // them. Observe each retry instead of assuming a tap paused.
                    for retry in 1...2 {
                        let page = front(state(app))?["state"] as? [String: Any]
                        let media = (page?["media"] as? [[String: Any]])?.first
                        if media?["paused"] as? Bool == true { break }
                        revealControls(app)
                        _ = tapRect("playRect", app: app)
                        Thread.sleep(forTimeInterval: 1.1)
                        observation["pauseRetry\(retry)"] = state(app)
                    }
                }
                let end = XCTAttachment(screenshot: app.screenshot()); end.name = "baseline-\(profile)-\(entry)-controls"; end.lifetime = .keepAlways; add(end)
                let tree = XCTAttachment(string: app.debugDescription); tree.name = "baseline-\(profile)-\(entry)-accessibility"; tree.lifetime = .keepAlways; add(tree)
                observations.append(observation)
                if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted,.sortedKeys]), let text = String(data: data, encoding: .utf8) {
                    let report = XCTAttachment(string: text); report.name = "baseline-observations-\(profile)-\(entry)"; report.lifetime = .keepAlways; add(report)
                }
                app.terminate()
            }
        }
    }

    @MainActor
    private func open(_ url: URL, app: XCUIApplication) throws {
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url))
    }

    @MainActor
    private func launch(incognito: Bool = false, confirmCrossDomain: Bool? = nil) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-ad_block_enabled", "YES",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-is_incognito", incognito ? "YES" : "NO"]
        if let confirmCrossDomain {
            app.launchArguments += ["-ad_block_confirm_cross_domain", confirmCrossDomain ? "YES" : "NO"]
        }
        if ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_VIDEO_QA"] == "1" {
            app.launchArguments += ["-privacy_cookie_banner_enabled", "YES"]
            app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        }
        if ProcessInfo.processInfo.environment["SOULO_LIVE_DOMAIN_CONFIRMATION_QA"] == "1" {
            app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    func testPageClickAdsAreBlockedAndExplicitExternalLinkStillOpens() async throws {
        let html = #"""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font:20px system-ui"><h3>Navigation fixture</h3>
        <p id="popup">Popup action</p><p id="replace">Replacement action</p>
        <p id="synthetic">Synthetic link action</p><p id="status">Waiting</p>
        <a id="external">Open chosen page</a>
        <script>
        const other=location.origin.replace('127.0.0.1','localhost');
        document.getElementById('external').href=other+'/chosen.html';
        document.addEventListener('pointerdown', e => {
          if(e.target.id==='popup')window.open(other+'/ad.html','_blank');
          if(e.target.id==='replace')location.href=other+'/ad.html';
          if(e.target.id==='synthetic'){
            const a=document.createElement('a');a.href=other+'/ad.html';a.target='_blank';
            document.body.append(a);a.click();a.remove();
          }
        });
        document.addEventListener('click',e=>{if(['popup','replace','synthetic'].includes(e.target.id))document.getElementById('status').textContent=e.target.id+' remained'});
        </script></body></html>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8),
            "/ad.html": Data("<html><body>Unexpected advertisement</body></html>".utf8),
            "/chosen.html": Data("<html><body>Chosen destination</body></html>".utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("page.html"), app: app)
        XCTAssertTrue(app.webViews.staticTexts["Navigation fixture"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        for (label, status) in [("Popup action", "popup remained"), ("Replacement action", "replace remained"),
                                ("Synthetic link action", "synthetic remained")] {
            app.webViews.staticTexts[label].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts[status].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertFalse(app.webViews.staticTexts["Unexpected advertisement"].exists)
        }
        app.webViews.links["Open chosen page"].tap()
        if app.buttons["browser.domain-confirmation.continue"].waitForExistence(timeout: 2) {
            app.buttons["browser.domain-confirmation.continue"].tap()
        }
        XCTAssertTrue(app.webViews.staticTexts["Chosen destination"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    func testSearchResultCardsPreserveSiteHandlersAndWebViewRedirects() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1"><body style="font:20px system-ui">
        <h3>Search results fixture</h3>
        <p><a id="handled" href="/wrong.html">Site handled result</a></p>
        <article id="card" data-sf-href="/tracking.html" style="padding:15px">Delegated result card</article>
        <article id="logcard" style="padding:15px">Result metadata card</article>
        <article id="richcard" style="padding:15px"><h3>Rich video title</h3></article>
        <article id="landingcard" style="padding:15px"><span>Video landing title</span></article>
        <a id="newtab" target="_blank">Native new window result</a>
        <form id="form" action="/receipt.html"><input name="q" value="movie"><button>Search chosen site</button></form>
        <script>
        const other=location.origin.replace('127.0.0.1','localhost');
        handled.href=other+'/wrong.html';
        handled.onclick=e=>{e.preventDefault();location.href=other+'/chosen.html?handler=original'};
        card.onclick=()=>location.href=other+'/redirect.html';
        logcard.setAttribute('data-log',JSON.stringify({mu:other+'/chosen.html'}));
        logcard.onclick=()=>location.href=other+'/chosen.html';
        richcard.setAttribute('rl-link-href',other+'/chosen.html');
        richcard.setAttribute('data-log',JSON.stringify({mu:other+'/wrong.html'}));
        richcard.innerHTML='<div>'.repeat(18)+'<h3>Rich video title</h3>'+'</div>'.repeat(18);
        richcard.onclick=()=>window.open(richcard.getAttribute('rl-link-href'),'_blank');
        landingcard.setAttribute('rl-link-data-url',other+'/chosen.html');
        landingcard.setAttribute('data-log',JSON.stringify({mu:other+'/wrong.html'}));
        landingcard.onclick=()=>window.open(landingcard.getAttribute('rl-link-data-url'),'_blank');
        newtab.href=other+'/chosen.html';form.action=other+'/receipt.html';
        </script></body>
        """#
        let server=try DownloadPlaybackHTTPFixture(files:["/results.html":Data(html.utf8),
            "/chosen.html":Data("<body>Chosen search result</body>".utf8),
            "/wrong.html":Data("<body>Wrong intercepted href</body>".utf8),
            "/receipt.html":Data("<body>Chosen search submitted</body>".utf8)],
            redirects:["/redirect.html":(host:"127.0.0.1",path:"/chosen.html")])
        let root=try await server.start();defer{server.stop()}
        let app=launch(),origin=root.appendingPathComponent("results.html")
        try open(origin,app:app)
        XCTAssertTrue(app.webViews.staticTexts["Search results fixture"].firstMatch.waitForExistence(timeout:20))
        setConfirmation(true,app:app)
        for label in ["Site handled result","Delegated result card","Result metadata card","Rich video title","Video landing title","Native new window result"] {
            try open(origin,app:app)
            let target=app.webViews.descendants(matching:.any).matching(NSPredicate(format:"label == %@",label)).firstMatch
            XCTAssertTrue(target.waitForExistence(timeout:10),app.debugDescription)
            target.tap()
            XCTAssertTrue(app.webViews.staticTexts["Chosen search result"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
            XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
            XCTAssertFalse(app.webViews.staticTexts["Wrong intercepted href"].exists)
        }
        try open(origin,app:app)
        let submit=app.webViews.buttons["Search chosen site"].firstMatch
        XCTAssertTrue(submit.waitForExistence(timeout:10));submit.tap()
        XCTAssertTrue(app.webViews.staticTexts["Chosen search submitted"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
        setConfirmation(false,app:app)
    }

    @MainActor
    func testLiveBaiduVideoCardTitleOpensItsLandingPage() throws {
        try checkLiveBaiduVideoCard(tapPicture: false)
    }

    @MainActor
    func testHistoryBackRevealsContentBeforePendingResourcesFinish() async throws {
        let origin = "<meta name='viewport' content='width=device-width,initial-scale=1'><body style='font:24px system-ui;padding:20px'><h1>Previous search results</h1><a href='/player.html'>Open video detail</a><iframe src='/hold' style='width:1px;height:1px;border:0'></iframe></body>"
        let player = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Current video detail</h1>"
        let server = try DownloadPlaybackHTTPFixture(files:["/origin.html":Data(origin.utf8),"/player.html":Data(player.utf8),"/hold":Data("<p>Late resource</p>".utf8)],heldPaths:["/hold"])
        let root = try await server.start(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("origin.html"),app:app)
        let previous = app.webViews.staticTexts["Previous search results"].firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout:20))
        Thread.sleep(forTimeInterval:1)
        let loading = XCTAttachment(screenshot:app.screenshot())
        loading.name="Gold loading progress before opening detail";loading.lifetime = .keepAlways;add(loading)
        app.webViews.links["Open video detail"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Current video detail"].firstMatch.waitForExistence(timeout:10))
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(previous.waitForExistence(timeout:10))
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, app.otherElements["browser.history-preview"].exists { Thread.sleep(forTimeInterval:0.05) }
        XCTAssertFalse(app.otherElements["browser.history-preview"].exists,"Usable content must not wait for the hanging iframe")
        XCTAssertTrue(previous.isHittable)
        let screenshot = XCTAttachment(screenshot:app.screenshot())
        screenshot.name="Back reveals search with gold loading progress";screenshot.lifetime = .keepAlways;add(screenshot)
    }

    @MainActor
    func testLiveBaiduVideoCardPictureOpensItsLandingPage() throws {
        try checkLiveBaiduVideoCard(tapPicture: true)
    }

    @MainActor
    private func checkLiveBaiduVideoCard(tapPicture: Bool) throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_SEARCH_VIDEO_QA"] == "1" else {
            throw XCTSkip("Opt-in live Baidu video result check")
        }
        let app = launch(incognito: ProcessInfo.processInfo.environment["SOULO_MEDIA_NORMAL_QA"] != "1")
        var search = URLComponents(string: "https://www.baidu.com/s")!
        search.queryItems = [URLQueryItem(name: "wd", value: "20201年喜剧电影解说")]
        try open(try XCTUnwrap(search.url), app: app)
        let title = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "又挖出一部宝藏")).firstMatch
        guard title.waitForExistence(timeout: 40) else {
            throw XCTSkip("The live search did not return the reported video card: \(app.debugDescription)")
        }
        for _ in 0..<6 where !title.isHittable { app.webViews.firstMatch.swipeUp() }
        if tapPicture, title.frame.maxY + 120 > app.frame.maxY - 80 { app.webViews.firstMatch.swipeUp() }
        Thread.sleep(forTimeInterval: 10)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "baidu-search-card-accessibility"; tree.lifetime = .keepAlways; add(tree)
        let before = XCTAttachment(screenshot: app.screenshot())
        before.name = "baidu-video-card-before-title-tap"; before.lifetime = .keepAlways; add(before)
        if tapPicture {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: title.frame.maxY + 100)).tap()
        } else {
            // The first text span may be covered by Baidu's AI tooltip. Tap
            // the exposed center of the heading instead of that span's center.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: title.frame.midY)).tap()
        }
        let address = app.buttons["Edit Address or Search"].firstMatch
        var reachedVideo = false
        for _ in 0..<80 {
            let value = address.value as? String ?? ""
            // The compact address button exposes only the host. The original
            // page link belongs to the video detail page, not its search card.
            if value.contains("m.baidu.com"), app.webViews.links["原网页"].firstMatch.exists {
                reachedVideo = true; break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTAssertTrue(reachedVideo, app.debugDescription)
        guard reachedVideo else { return }
        // Seeking to the preview position changes the clock once even when
        // playback is stuck. Sample only after startup/seek have settled.
        Thread.sleep(forTimeInterval: 8)
        let clock = app.webViews.otherElements.matching(NSPredicate(format: "label MATCHES %@", "^.+(秒钟|seconds?|minutes?).*[,，].+$")).firstMatch
        var firstTime: String?, progressed = false
        for _ in 0..<160 {
            if clock.exists {
                let time = clock.label.components(separatedBy: CharacterSet(charactersIn: ",，")).first ?? ""
                if let firstTime, time != firstTime { progressed = true; break }
                if firstTime == nil { firstTime = time }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if tapPicture, progressed {
            let player = clock.frame
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: player.midX, dy: player.minY + 20)).tap()
            let sound = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: player.minX + 22, dy: player.maxY - 20))
            sound.tap()
            Thread.sleep(forTimeInterval: 2.5)
            let muted = XCTAttachment(screenshot: app.screenshot())
            muted.name = "baidu-detail-after-native-mute-tap"; muted.lifetime = .keepAlways; add(muted)
            sound.tap()
            Thread.sleep(forTimeInterval: 1)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: player.midX, dy: player.midY)).tap()
            Thread.sleep(forTimeInterval: 0.5)
            let afterFirstTap = clock.label
            Thread.sleep(forTimeInterval: 1.2)
            if clock.label != afterFirstTap {
                // The controls auto-hide. In that state the first tap reveals
                // them and the next tap activates the visible pause control.
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: player.midX, dy: player.midY)).tap()
                Thread.sleep(forTimeInterval: 0.5)
            }
            let pausedTime = clock.label
            Thread.sleep(forTimeInterval: 1.5)
            XCTAssertEqual(clock.label, pausedTime, "The site's pause button must stop the actual detail timeline")
        }
        let after = XCTAttachment(screenshot: app.screenshot())
        after.name = "baidu-video-card-after-title-tap"; after.lifetime = .keepAlways; add(after)
        let detailTree = XCTAttachment(string: app.debugDescription)
        detailTree.name = "baidu-detail-accessibility"; detailTree.lifetime = .keepAlways; add(detailTree)
        XCTAssertTrue(progressed, "The real destination video did not advance: \(app.debugDescription)")
    }

    @MainActor
    func testDomainAllowlistEntryRespondsAcrossWholeRowOnRepeatedPresentation() async throws {
        let server=try DownloadPlaybackHTTPFixture(files:["/origin.html":Data("<body>Settings entry fixture</body>".utf8)])
        let root=try await server.start();defer{server.stop()}
        let app=launch();try open(root.appendingPathComponent("origin.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["Settings entry fixture"].firstMatch.waitForExistence(timeout:20))
        for _ in 0..<2 {
            app.buttons["browser.siteInformation"].tap();app.buttons["site.ad-block-details"].tap()
            let entry=app.buttons["adBlock.domainAllowlist"]
            XCTAssertTrue(entry.waitForExistence(timeout:5))
            entry.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            guard app.textFields["domainAllowlist.input"].waitForExistence(timeout:5) else { XCTFail(app.debugDescription);return }
            app.navigationBars.buttons.element(boundBy:0).tap()
            app.buttons["Done"].firstMatch.tap()
        }
    }

    @MainActor
    func testTrustFromConfirmationPersistsAndSettingsManageDomains() async throws {
        let auto="<meta name='viewport' content='width=device-width,initial-scale=1'><h3>Automatic trust fixture</h3><script>setTimeout(()=>location.href=location.origin.replace('127.0.0.1','localhost')+'/chosen.html',600)</script>"
        let server=try DownloadPlaybackHTTPFixture(files:["/origin.html":Data("<body>Trust origin</body>".utf8),
            "/auto.html":Data(auto.utf8),"/chosen.html":Data("<body>Trusted destination</body>".utf8)])
        let root=try await server.start();defer{server.stop()}
        let app=launch()
        try open(root.appendingPathComponent("origin.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["Trust origin"].firstMatch.waitForExistence(timeout:20))
        app.buttons["browser.siteInformation"].tap();app.buttons["site.ad-block-details"].tap()
        let initialToggle=app.switches["adBlock.confirmCrossDomain"]
        XCTAssertTrue(initialToggle.waitForExistence(timeout:5))
        if initialToggle.value as? String != "1" { initialToggle.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap() }
        app.buttons["adBlock.domainAllowlist"].tap()
        guard app.textFields["domainAllowlist.input"].waitForExistence(timeout:5) else { XCTFail(app.debugDescription);return }
        app.buttons["domainAllowlist.actions"].tap();app.buttons["domainAllowlist.reset"].tap()
        app.navigationBars.buttons.element(boundBy:0).tap()
        app.buttons["Done"].firstMatch.tap()
        try open(root.appendingPathComponent("auto.html"),app:app)
        let trust=app.buttons["browser.domain-confirmation.trust"]
        XCTAssertTrue(trust.waitForExistence(timeout:10),app.debugDescription)
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Domain confirmation with trust action";screenshot.lifetime = .keepAlways;add(screenshot)
        trust.tap()
        XCTAssertTrue(app.webViews.staticTexts["Trusted destination"].firstMatch.waitForExistence(timeout:10))
        try open(root.appendingPathComponent("auto.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["Trusted destination"].firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(trust.exists)
        app.buttons["browser.siteInformation"].tap();app.buttons["site.ad-block-details"].tap()
        let entry=app.buttons["adBlock.domainAllowlist"]
        XCTAssertTrue(entry.waitForExistence(timeout:5),app.debugDescription)
        entry.tap()
        let input=app.textFields["domainAllowlist.input"]
        guard input.waitForExistence(timeout:5) else { XCTFail(app.debugDescription);return }
        input.tap();input.typeText("*.example.test")
        app.buttons["domainAllowlist.add"].tap()
        let added=app.staticTexts["domainAllowlist.rule.*.example.test"]
        XCTAssertTrue(added.waitForExistence(timeout:5),app.debugDescription)
        added.swipeLeft();app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(added.exists)
        app.buttons["domainAllowlist.actions"].tap();app.buttons["domainAllowlist.reset"].tap()
        app.navigationBars.buttons.element(boundBy:0).tap()
        let toggle=app.switches["adBlock.confirmCrossDomain"]
        XCTAssertTrue(toggle.waitForExistence(timeout:5),app.debugDescription)
        if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset:CGVector(dx:0.92,dy:0.5)).tap() }
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func testExplicitFormAndSignInPopupRemainUsable() async throws {
        let html = #"""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font:20px system-ui"><h3>Explicit actions fixture</h3>
        <button onclick="window.open('/login-popup.html','login')">Sign in</button>
        <p id="result">Not signed in</p>
        <form id="form" method="post" action="/submit.html" target="_blank"><input name="query" value="chosen"><button>Submit form</button></form>
        <script>
        document.getElementById('form').action=location.origin.replace('127.0.0.1','localhost')+'/submit.html';
        addEventListener('message',e=>{if(e.origin===location.origin)document.getElementById('result').textContent=e.data});
        </script>
        </body></html>
        """#
        let popup = "<html><body><script>window.opener.postMessage('Sign in completed',location.origin);window.close()</script></body></html>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8),
            "/login-popup.html": Data(popup.utf8), "/submit.html": Data("<body>Form submitted</body>".utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("page.html"), app: app)
        XCTAssertTrue(app.webViews.buttons["Sign in"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.webViews.buttons["Sign in"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Sign in completed"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.webViews.buttons["Submit form"].firstMatch.tap()
        if app.buttons["browser.domain-confirmation.continue"].waitForExistence(timeout: 2) {
            app.buttons["browser.domain-confirmation.continue"].tap()
        }
        XCTAssertTrue(app.webViews.staticTexts["Form submitted"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func openEpisodes(_ app: XCUIApplication, video: Bool = false, timeout: TimeInterval = 10) {
        if video {
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 10), app.debugDescription)
            tools.tap()
        }
        let episodes = app.webViews.buttons["Episodes"].firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout: timeout), app.debugDescription)
        episodes.tap()
        XCTAssertTrue(app.buttons["browser.episodes-order"].waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    private func selectFixtureTab(title: String, app: XCUIApplication) {
        let mode=app.buttons["tabs.view-mode"]
        if mode.exists, mode.value as? String != "Group by Domain" { mode.tap() }
        // The top tab strip exposes the same labels as the overview cards.
        // Scope to the overview so the most recently used source is selected.
        let groups=app.scrollViews["tabs.groups"].firstMatch
        XCTAssertTrue(groups.waitForExistence(timeout:5),app.debugDescription)
        let tab=groups.buttons.matching(NSPredicate(format:"label BEGINSWITH %@",title+",")).firstMatch
        for _ in 0..<12 {
            if tab.exists, tab.isHittable, app.frame.insetBy(dx:20,dy:70).contains(CGPoint(x:tab.frame.midX,y:tab.frame.midY)) { break }
            groups.swipeUp()
        }
        XCTAssertTrue(tab.exists && tab.isHittable,app.debugDescription)
        tab.tap()
    }

    @MainActor
    private func setConfirmation(_ enabled: Bool, app: XCUIApplication, expectDefaultOff: Bool = false) {
        let site = app.buttons["browser.siteInformation"]
        XCTAssertTrue(site.waitForExistence(timeout: 5), app.debugDescription)
        site.tap()
        let details = app.buttons["site.ad-block-details"]
        XCTAssertTrue(details.waitForExistence(timeout: 5), app.debugDescription)
        details.tap()
        let toggle = app.switches["adBlock.confirmCrossDomain"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        if expectDefaultOff { XCTAssertEqual(toggle.value as? String,"0") }
        if (toggle.value as? String == "1") != enabled {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0", app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func testVideoToolsUseIconsAndPickerReversesAndSwitchesWithoutSearch() async throws {
        func page(_ episode: Int) -> Data {
            let links = (1...12).map { "<li><a href='/player/7-1-\($0).html'>EP\($0)</a></li>" }.joined()
            return Data("""
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="font:20px system-ui"><video style="width:100%;height:200px" playsinline controls></video><h3>Playing EP\(episode)</h3>
            <h3>Line A</h3><ul class='stui-content__playlist'>\(links)</ul>
            <script>document.addEventListener('click',()=>{location.href='/ad.html'},true)</script>
            </body></html>
            """.utf8)
        }
        var files: [String: Data] = ["/ad.html": Data("<body>Unexpected advertisement</body>".utf8)]
        for index in 1...12 { files["/player/7-1-\(index).html"] = page(index) }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("player/7-1-2.html"), app: app)
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 20),app.debugDescription)
        tools.tap()
        for title in ["Download","Speed","Fullscreen","Episodes"] {
            XCTAssertTrue(app.webViews.buttons[title].firstMatch.exists, app.debugDescription)
        }
        let menu = XCTAttachment(screenshot:app.screenshot());menu.name="Compact video tools with icons";menu.lifetime = .keepAlways;add(menu)
        app.webViews.buttons["Episodes"].firstMatch.tap()
        let order = app.buttons["browser.episodes-order"]
        XCTAssertTrue(order.waitForExistence(timeout: 5),app.debugDescription)
        XCTAssertFalse(app.textFields["browser.episodes-search"].exists)
        XCTAssertFalse(app.switches["video-helper.cross-domain-toggle"].exists)
        if order.label.contains("Ascending") { order.tap() }
        XCTAssertTrue(order.label.contains("Descending"))
        XCTAssertLessThan(app.buttons["EP12"].firstMatch.frame.minY,app.buttons["EP9"].firstMatch.frame.minY)
        app.buttons["EP12"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Playing EP12"].firstMatch.waitForExistence(timeout: 10),app.debugDescription)
        openEpisodes(app,video:true)
        XCTAssertFalse(app.buttons["browser.episodes-next"].isEnabled)
        app.buttons["browser.episodes-previous"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Playing EP11"].firstMatch.waitForExistence(timeout: 10),app.debugDescription)
        XCTAssertFalse(app.webViews.staticTexts["Unexpected advertisement"].exists)
    }

    @MainActor
    func testVideoToolsHideMissingEpisodesAndReuseIconsWhenExpanded() async throws {
        let html=#"""
        <meta name="viewport" content="width=device-width,initial-scale=1"><body style="font:18px system-ui">
        <video style="width:100%;height:200px" playsinline controls></video><h3>Icon toolbar fixture</h3>
        <button onclick="document.getElementById('playlist').innerHTML='<ul class=episode-list><li><a href=/ep1.html>EP1</a></li><li><a href=/ep2.html>EP2</a></li></ul>'">Add episodes</button>
        <button onclick="document.getElementById('playlist').replaceChildren()">Remove episodes</button>
        <div id="playlist"></div><p id="status">Waiting for tools</p>
        <script>
        let changes=0;
        new MutationObserver(records=>{
          let stateChanged=false;
          for(const r of records){
            if(!r.target.closest?.('[data-soulo-video-rotate]'))continue;
            if(r.type==='childList')changes++;
            if(r.type==='attributes')stateChanged=true;
          }
          if(stateChanged){
            const group=document.querySelector('[data-soulo-video-rotate]');
            document.getElementById('status').textContent=group.textContent.trim()===''?'Icons only; node changes '+changes:'Unexpected toolbar text';
          }
        }).observe(document,{childList:true,subtree:true,attributes:true,attributeFilter:['aria-expanded']});
        </script></body>
        """#
        let server=try DownloadPlaybackHTTPFixture(files:["/icons.html":Data(html.utf8)])
        let root=try await server.start();defer{server.stop()}
        let app=launch();try open(root.appendingPathComponent("icons.html"),app:app)
        let tools=app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout:20))
        for _ in 0..<2 {
            tools.tap()
            for label in ["Download","Speed","Fullscreen"] { XCTAssertTrue(app.webViews.buttons[label].firstMatch.waitForExistence(timeout:5),app.debugDescription) }
            XCTAssertFalse(app.webViews.buttons["Episodes"].firstMatch.exists)
            XCTAssertTrue(app.webViews.staticTexts["Icons only; node changes 0"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
            app.webViews.buttons["Close"].firstMatch.tap()
            XCTAssertTrue(tools.waitForExistence(timeout:5))
        }
        app.webViews.buttons["Add episodes"].firstMatch.tap()
        XCTAssertTrue(app.webViews.links["EP2"].firstMatch.waitForExistence(timeout:5))
        tools.tap()
        let episodes=app.webViews.buttons["Episodes"].firstMatch
        XCTAssertTrue(episodes.waitForExistence(timeout:5),app.debugDescription)
        let image=XCTAttachment(screenshot:app.screenshot());image.name="Compact icons with detected episodes";image.lifetime = .keepAlways;add(image)
        app.webViews.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(tools.waitForExistence(timeout:5))
        app.webViews.buttons["Remove episodes"].firstMatch.tap()
        XCTAssertTrue(app.webViews.links["EP2"].firstMatch.waitForNonExistence(timeout:5))
        tools.tap()
        XCTAssertTrue(app.webViews.buttons["Speed"].firstMatch.waitForExistence(timeout:5))
        let disappears=NSPredicate(format:"exists == false")
        let hidden=expectation(for:disappears,evaluatedWith:episodes)
        await fulfillment(of:[hidden],timeout:5)
    }

    @MainActor
    func testEpisodeDockOpensAfterReturningFromPlayer() async throws {
        let links = (1...3).map { "<li><a href='/player/7-1-\($0).html'>EP\($0)</a></li>" }.joined()
        let detail = "<meta name='viewport' content='width=device-width,initial-scale=1'><h2>Series details</h2><ul class='episode-list'>" + links + "</ul>"
        let player = "<meta name='viewport' content='width=device-width,initial-scale=1'><h2>Episode player</h2><a href='/detail.html'>Series details</a>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(detail.utf8),
            "/player/7-1-1.html": Data(player.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("detail.html"), app: app)
        openEpisodes(app)
        app.buttons["EP1"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Episode player"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Series details"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        openEpisodes(app)
        app.buttons["Done"].firstMatch.tap()
        openEpisodes(app)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "episode-picker-after-return"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testVideoEpisodeButtonOpensAfterBackAndForward() async throws {
        let links = (1...3).map { "<li><a href='/player/7-1-\($0).html'>EP\($0)</a></li>" }.joined()
        let head = "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        let list = "<ul class='episode-list'>" + links + "</ul>"
        let player = head + "<iframe src='/frame.html' style='width:100%;height:220px;border:0'></iframe><h2>Episode player</h2>" + list
        let frame = head + "<video playsinline controls style='width:100%;height:200px'></video>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data((head + "<h2>Series details</h2>" + list).utf8),
            "/player/7-1-1.html": Data(player.utf8), "/frame.html": Data(frame.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("detail.html"), app: app)
        openEpisodes(app)
        app.buttons["EP1"].firstMatch.tap()
        openEpisodes(app, video: true)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Series details"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        openEpisodes(app)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["More"].firstMatch.tap()
        app.buttons["Forward"].firstMatch.tap()
        openEpisodes(app, video: true)
    }

    @MainActor
    func testLoginPageFilteringCanBeSwitchedOffAndBackOn() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/user/login": Data("<h1>Login fixture</h1><form><input placeholder='Email'><input type='password'></form><aside id='float-bottom-ad'>Advertisement</aside>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("user/login"), app: app)
        XCTAssertTrue(app.webViews.staticTexts["Login fixture"].firstMatch.waitForExistence(timeout: 10))
        func toggle() -> XCUIElement {
            let button = app.buttons["site.ad-block-toggle"]
            if !button.exists { app.buttons["browser.siteInformation"].tap() }
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            return button
        }
        let first = toggle()
        XCTAssertTrue(first.isEnabled)
        XCTAssertTrue(first.isSelected)
        first.tap()
        let disabled = toggle()
        XCTAssertFalse(disabled.isSelected)
        disabled.tap()
        let enabled = toggle()
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertTrue(enabled.isSelected)
    }

    @MainActor
    func testTypedAddressFailureShowsTheFailedDestinationAndRetriesIt() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/previous": Data("<h1>Previous document</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let unavailable = try DownloadPlaybackHTTPFixture(files: [:])
        let destination = try await unavailable.start().appendingPathComponent("typed-address")
        unavailable.stop()
        let app = launch()
        try open(root.appendingPathComponent("previous"), app: app)
        XCTAssertTrue(app.webViews.staticTexts["Previous document"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Edit Address or Search"].tap()
        let field = app.textFields["addressEditor.query"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + destination.absoluteString + "\n")
        let failedURL = app.staticTexts["browser.error.url"]
        XCTAssertTrue(failedURL.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(failedURL.label, destination.absoluteString)
        XCTAssertTrue(app.staticTexts["Unable to Access"].exists, app.debugDescription)
        app.buttons["browser.error.retry"].tap()
        XCTAssertTrue(failedURL.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(failedURL.label, destination.absoluteString)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "failed-typed-address"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testGenericCatalogAndVideoButtonsKeepTheirSizeWithoutMobileViewport() async throws {
        let catalog = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <h3>Generic stream line</h3><table><tbody>
        <tr><td>EP1</td><td><a href='/one.mp4'>URL</a></td></tr>
        <tr><td>EP2</td><td><a href='/two.mp4'>URL</a></td></tr></tbody></table>
        """
        let player = """
        <style>html,body{margin:0;width:100%;height:100%}video{position:fixed;inset:0;width:100%;height:100%}button{width:10px!important;height:10px!important}svg{width:4px!important;height:4px!important}</style>
        <video playsinline controls></video><ul class='episode-list' style='display:none'><li><a href='/first'>EP1</a></li><li><a href='/second'>EP2</a></li></ul>
        """
        let server = try DownloadPlaybackHTTPFixture(files:["/catalog":Data(catalog.utf8),"/wide-player":Data(player.utf8),
            "/mobile-player":Data(("<meta name='viewport' content='width=device-width,initial-scale=1'>"+player).utf8)])
        let root = try await server.start();defer{server.stop()}
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        try open(root.appendingPathComponent("catalog"),app:app)
        let dock = app.webViews.buttons["Episodes"].firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertEqual(dock.frame.width,48,accuracy:2)
        dock.tap()
        XCTAssertTrue(app.scrollViews.buttons["EP2"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        for path in ["mobile-player","wide-player"] {
            try open(root.appendingPathComponent(path),app:app)
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout:15),app.debugDescription)
            XCTAssertEqual(tools.frame.width,48,accuracy:2,path)
            XCTAssertEqual(tools.frame.height,48,accuracy:2,path)
            tools.tap()
            for name in ["Download","Speed","Fullscreen","Episodes","Close"] {
                let button = app.webViews.buttons[name].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout:5),app.debugDescription)
                XCTAssertEqual(button.frame.width,48,accuracy:2,name+" "+path)
                XCTAssertEqual(button.frame.height,48,accuracy:2,name+" "+path)
            }
            app.webViews.buttons["Close"].firstMatch.tap()
            if path == "mobile-player" {
                func openZoom() {
                    app.buttons["More"].firstMatch.tap()
                    app.buttons["browser.moreMenu.pageTools"].tap()
                    app.buttons["Page Zoom"].firstMatch.tap()
                    XCTAssertTrue(app.buttons["Zoom In"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
                }
                openZoom()
                for _ in 0..<10 { app.buttons["Zoom In"].firstMatch.tap() }
                app.buttons["Done"].firstMatch.tap()
                tools.tap()
                for name in ["Download","Speed","Fullscreen","Episodes","Close"] {
                    let button = app.webViews.buttons[name].firstMatch
                    XCTAssertTrue(button.waitForExistence(timeout:5),app.debugDescription)
                    XCTAssertTrue(button.isHittable,name+" must remain visible at 200% page zoom")
                    XCTAssertEqual(button.frame.width,48,accuracy:2,name+" at 200% page zoom")
                    XCTAssertEqual(button.frame.height,48,accuracy:2,name+" at 200% page zoom")
                }
                let zoomed=XCTAttachment(screenshot:app.screenshot());zoomed.name="Expanded controls at 200 percent page zoom";zoomed.lifetime = .keepAlways;add(zoomed)
                app.webViews.buttons["Close"].firstMatch.tap()
                openZoom()
                app.buttons["Reset to 100%"].firstMatch.tap()
                app.buttons["Done"].firstMatch.tap()
            }
            if path == "wide-player" {
                app.webViews.firstMatch.pinch(withScale:1.5,velocity:1)
                XCTAssertTrue(tools.waitForExistence(timeout:5),app.debugDescription)
                XCTAssertEqual(tools.frame.width,48,accuracy:2,"After pinch zoom")
                let image=XCTAttachment(screenshot:app.screenshot());image.name="Wide player with 48 point controls";image.lifetime = .keepAlways;add(image)
                XCUIDevice.shared.orientation = .landscapeLeft
                let stable = expectation(for:NSPredicate { _,_ in abs(tools.frame.width-48)<=2.5 && abs(tools.frame.height-48)<=2.5 },evaluatedWith:tools)
                await fulfillment(of:[stable],timeout:10)
                let landscape=XCTAttachment(screenshot:app.screenshot());landscape.name="Player controls after device orientation change";landscape.lifetime = .keepAlways;add(landscape)
            }
        }
    }

    @MainActor
    func testResourceCatalogStreamsKeepThePickerAndAdjacentEpisodes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let data = try Data(contentsOf: fixture)
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Catalog fixture</title>
        <div class="dy-collect-video"><div class="dy-collect-video-name">光速云</div>
        <ul class="dy-collect-list"><li><span class="c-name">第01集</span><a href="/play/first">Player</a></li></ul></div>
        <div class="dy-collect-video"><div class="dy-collect-video-name">光速M3U8</div>
        <ul class="dy-collect-list"><li><span class="c-name">第01集</span><a href="/first.mp4">Stream</a></li>
        <li><span class="c-name">第02集</span><a href="/second.mp4">Stream</a></li></ul></div>
        <script>document.querySelector('.dy-collect-list a').href=location.origin.replace('127.0.0.1','localhost')+'/play/first';</script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(html.utf8), "/first.mp4": data, "/second.mp4": data,
            "/play/first": Data("<h1>Cloud episode</h1>".utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("detail.html"), app: app)
        openEpisodes(app)
        app.buttons["browser.episodes-source"].tap()
        app.buttons["光速M3U8"].firstMatch.tap()
        XCTAssertFalse(app.buttons["browser.episodes-next"].isEnabled)
        app.scrollViews.buttons["第01集"].firstMatch.tap()
        let player = app.navigationBars["Video Player"]
        XCTAssertTrue(player.waitForExistence(timeout: 10), app.debugDescription)
        player.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.episodes-order"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews.buttons["第01集"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["browser.episodes-next"].isEnabled)
        app.buttons["browser.episodes-next"].tap()
        XCTAssertTrue(player.waitForExistence(timeout: 10), app.debugDescription)
        player.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["browser.episodes-previous"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.scrollViews.buttons["第02集"].firstMatch.isSelected)
        XCTAssertTrue(app.buttons["browser.episodes-previous"].isEnabled)
        XCTAssertFalse(app.buttons["browser.episodes-next"].isEnabled)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "resource-catalog-episodes-after-playback"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["browser.episodes-source"].tap()
        app.buttons["光速云"].firstMatch.tap()
        app.scrollViews.buttons["第01集"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Cloud episode"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["Back"].firstMatch.tap()
        openEpisodes(app)
        XCTAssertTrue(app.scrollViews.buttons["第01集"].firstMatch.exists, app.debugDescription)
    }

    @MainActor
    func testLiveEpisodeDockOpensAfterReturningFromPlayback() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_EPISODES_QA"] == "1" else {
            throw XCTSkip("Opt-in live website check")
        }
        let app = launch()
        try open(try XCTUnwrap(URL(string: "https://www.pbpbw.com/html/228208.html")), app: app)
        openEpisodes(app, timeout: 30)
        let order = app.buttons["browser.episodes-order"]
        if order.label.contains("Descending") { order.tap() }
        let first = app.buttons["第01集"].firstMatch
        guard first.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
        first.tap()
        let next = app.webViews.links.matching(NSPredicate(format: "label CONTAINS %@", "下一集")).firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 30), app.debugDescription)
        app.buttons["Back"].firstMatch.tap()
        openEpisodes(app, timeout: 30)
        XCTAssertTrue(app.buttons["第01集"].firstMatch.exists, app.debugDescription)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "live-pbpbw-episodes-after-return"; image.lifetime = .keepAlways; add(image)
    }

    @MainActor
    func testLongPressEpisodeDownloadsWithoutNavigatingAndShowsSizesInFiles() async throws {
        let mediaURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let data = try Data(contentsOf: mediaURL)
        let detail = "<title>Episode download fixture</title><meta name='viewport' content='width=device-width,initial-scale=1'><h2>Series details</h2><ul class='episode-list'><li><a href='/ep1.html'>EP1</a></li><li><a href='/ep2.html'>EP2</a></li></ul>"
        let player = "<script>window.player_aaaa={url:'/clip.mp4',encrypt:0}</script>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(detail.utf8),
            "/ep1.html": Data(player.utf8), "/ep2.html": Data(player.utf8), "/clip.mp4": data])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch()
        try open(root.appendingPathComponent("detail.html"), app: app)
        openEpisodes(app)
        app.buttons["EP1"].firstMatch.press(forDuration: 1)
        let download = app.buttons["browser.episode-download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), app.debugDescription)
        download.tap()
        XCTAssertTrue(app.buttons["browser.episodes-order"].exists, "Downloading must leave the selected webpage and picker in place")
        app.buttons["browser.episodes-downloads"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", "EP1")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), app.debugDescription)
        let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", size).evaluate(with: row), row.label)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "episode-download-with-file-size"; image.lifetime = .keepAlways; add(image)
        app.buttons["downloads.files"].tap()
        let file = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "files.item.", "EP1")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(file.label.contains(size), file.label)
        app.buttons["files.viewMode"].tap()
        XCTAssertTrue(file.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(file.label.contains(size), file.label)
    }

    @MainActor
    func testDetailPageDockDragsAndBatchSelectionDownloadsMedia() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"playback-h264-aac",withExtension:"mp4"))
        let links=(1...3).map { "<li><a href='/ep\($0).html'>EP\($0)</a></li>" }.joined()
        let detail="<meta name='viewport' content='width=device-width,initial-scale=1'><h2>Series details</h2><ul class='episode-list'>"+links+"</ul>"
        let player="<script>window.player_aaaa={url:'/clip.mp4',encrypt:0}</script>"
        let server=try DownloadPlaybackHTTPFixture(files:["/detail.html":Data(detail.utf8),"/ep1.html":Data(player.utf8),"/ep2.html":Data(player.utf8),"/clip.mp4":try Data(contentsOf:fixture)])
        let root=try await server.start();server.releaseDownloads();defer{server.stop()}
        let app=launch();try open(root.appendingPathComponent("detail.html"),app:app)
        let dock=app.webViews.buttons["Episodes"].firstMatch
        XCTAssertTrue(dock.waitForExistence(timeout:20),app.debugDescription)
        let web=app.webViews.firstMatch
        dock.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).press(forDuration:0.15,thenDragTo:web.coordinate(withNormalizedOffset:CGVector(dx:0.03,dy:0.35)))
        XCTAssertLessThan(dock.frame.minX,15)
        XCTAssertFalse(app.buttons["browser.episodes-order"].exists)
        dock.tap()
        XCTAssertTrue(app.buttons["browser.episodes-select"].waitForExistence(timeout:5))
        app.buttons["browser.episodes-select"].tap()
        app.buttons["EP1"].firstMatch.tap();app.buttons["EP2"].firstMatch.tap()
        let download=app.buttons["browser.episodes-download"]
        XCTAssertTrue(download.label.contains("2"),app.debugDescription)
        let selected=XCTAttachment(screenshot:app.screenshot());selected.name="Episode batch selection";selected.lifetime = .keepAlways;add(selected)
        download.tap()
        XCTAssertTrue(app.staticTexts["Processed 2 of 2"].waitForExistence(timeout:30),app.debugDescription)
        XCTAssertFalse(app.buttons["browser.episodes-download-failures"].exists)
        XCTAssertFalse(app.webViews.staticTexts["Unexpected advertisement"].exists)
    }

    @MainActor
    func testLiveBaiduResultClickDoesNotRepeatDomainConfirmation() throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_DOMAIN_CONFIRMATION_QA"] == "1" else {
            throw XCTSkip("Opt-in live Baidu result click")
        }
        let app=launch(confirmCrossDomain:true)
        var search=URLComponents(string:"https://www.baidu.com/s")!
        search.queryItems=[URLQueryItem(name:"wd",value:"MDN JavaScript Array")]
        try open(try XCTUnwrap(search.url),app:app)
        let result=app.webViews.otherElements.matching(NSPredicate(format:"label == %@","Array - JavaScript | MDN")).firstMatch
        guard result.waitForExistence(timeout:35) else { throw XCTSkip("The live search did not return the intended MDN result") }
        for _ in 0..<6 where !result.isHittable { app.webViews.firstMatch.swipeUp() }
        let before=XCTAttachment(screenshot:app.screenshot());before.name="Live Baidu result before click";before.lifetime = .keepAlways;add(before)
        result.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        let confirm=app.buttons["browser.domain-confirmation.continue"]
        let address=app.buttons["Edit Address or Search"].firstMatch
        var arrived=false
        for _ in 0..<80 {
            if confirm.exists { XCTFail("A chosen Baidu result must retain its declared destination: \(app.debugDescription)");return }
            let host=address.value as? String ?? ""
            // Baidu may return the official MDN page or a university mirror.
            if !host.isEmpty && host != "baidu.com" && !host.hasSuffix(".baidu.com") { arrived=true;break }
            Thread.sleep(forTimeInterval:0.25)
        }
        XCTAssertTrue(arrived,"The chosen external result did not open: \(app.debugDescription)")
        let heading=app.webViews.staticTexts["Array"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout:20) && heading.isHittable,"Verify actual destination content, not only its address")
        let after=XCTAttachment(screenshot:app.screenshot());after.name="Live Baidu external destination";after.lifetime = .keepAlways;add(after)
    }

    @MainActor
    func testDeclaredSearchDestinationKeepsClickIntentThroughIntermediateDocument() async throws {
        let origin="<meta name='viewport' content='width=device-width,initial-scale=1'><article id='result'><a href='/bridge.html'>Chosen search result</a></article><script>result.setAttribute('data-log',JSON.stringify({mu:location.origin.replace('127.0.0.1','localhost')+'/chosen.html'}));</script>"
        let bridge="<body>Opening result…<script>setTimeout(()=>location.replace(location.origin.replace('127.0.0.1','localhost')+'/chosen.html'),250)</script></body>"
        let server=try DownloadPlaybackHTTPFixture(files:["/origin.html":Data(origin.utf8),"/bridge.html":Data(bridge.utf8),"/chosen.html":Data("<h1>Chosen result destination</h1>".utf8)])
        let root=try await server.start();defer { server.stop() }
        let app=launch(confirmCrossDomain:true)
        try open(root.appendingPathComponent("origin.html"),app:app)
        let result=app.webViews.links["Chosen search result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout:15));result.tap()
        XCTAssertTrue(app.webViews.staticTexts["Chosen result destination"].firstMatch.waitForExistence(timeout:8),app.debugDescription)
        XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists,"The clicked result already declares this exact destination")
    }

    @MainActor
    func testUndeclaredDestinationAfterIntermediateDocumentStillNeedsConfirmation() async throws {
        let origin="<meta name='viewport' content='width=device-width,initial-scale=1'><a href='/bridge.html'>Open intermediate page</a>"
        let bridge="<body>Intermediate content<script>setTimeout(()=>location.replace(location.origin.replace('127.0.0.1','localhost')+'/unrelated.html'),250)</script></body>"
        let server=try DownloadPlaybackHTTPFixture(files:["/origin.html":Data(origin.utf8),"/bridge.html":Data(bridge.utf8),"/unrelated.html":Data("<h1>Unrelated destination</h1>".utf8)])
        let root=try await server.start();defer { server.stop() }
        let app=launch(confirmCrossDomain:true)
        try open(root.appendingPathComponent("origin.html"),app:app)
        let result=app.webViews.links["Open intermediate page"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout:15));result.tap()
        let confirm=app.buttons["browser.domain-confirmation.continue"]
        XCTAssertTrue(confirm.waitForExistence(timeout:10),"Unrelated automatic destinations must still ask")
        XCTAssertFalse(app.webViews.staticTexts["Unrelated destination"].firstMatch.exists)
        confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Unrelated destination"].firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(confirm.exists)
    }

    @MainActor
    func testCrossDomainSettingOnlyConfirmsAutomaticNavigation() async throws {
        let html = #"""
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font:20px system-ui"><h3>Domain fixture</h3>
        <a id="other">Other website</a><p><a href='/redirect.html'>Chosen redirect</a></p><iframe id="embed" style="height:40px"></iframe>
        <script>const other=location.origin.replace('127.0.0.1','localhost');document.getElementById('other').href=other+'/chosen.html';document.getElementById('embed').src=other+'/embedded.html';</script></body></html>
        """#
        let server=try DownloadPlaybackHTTPFixture(files:["/origin.html":Data(html.utf8),"/chosen.html":Data("<body>Confirmed destination</body>".utf8),"/embedded.html":Data("<body>Embedded content</body>".utf8),"/automatic.html":Data("<head><title>Automatic origin</title></head><body><h3>Automatic origin</h3><script>document.title='Automatic origin '+location.port+location.search;setTimeout(()=>location.href='/redirect.html',600)</script></body>".utf8)],redirects:["/redirect.html":(host:"localhost",path:"/chosen.html")])
        let root=try await server.start();defer{server.stop()}
        let app=launch(),origin=root.appendingPathComponent("origin.html")
        try open(origin,app:app)
        XCTAssertTrue(app.webViews.staticTexts["Domain fixture"].firstMatch.waitForExistence(timeout:20))
        let confirm=app.buttons["browser.domain-confirmation.continue"],cancel=app.buttons["browser.domain-confirmation.cancel"]
        XCTAssertFalse(confirm.exists)
        // This scenario changes the preference itself. Start from a known
        // value even when a previous interrupted UI run left it enabled.
        setConfirmation(false,app:app)
        setConfirmation(true,app:app,expectDefaultOff:true)
        app.webViews.links["Other website"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(confirm.exists,"A chosen link is explicit consent")
        try open(origin,app:app)
        XCTAssertTrue(app.webViews.links["Chosen redirect"].firstMatch.waitForExistence(timeout:10))
        app.webViews.links["Chosen redirect"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(confirm.exists,"A chosen link's HTTP redirects keep its user intent")
        try open(root.appendingPathComponent("redirect.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(confirm.exists,"Native address entry and platform actions must not prompt")
        try open(root.appendingPathComponent("automatic.html"),app:app)
        XCTAssertTrue(confirm.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(app.alerts["Leave this website?"].exists)
        cancel.tap()
        XCTAssertTrue(app.webViews.staticTexts["Automatic origin"].exists)
        try open(root.appendingPathComponent("automatic.html"),app:app)
        XCTAssertTrue(confirm.waitForExistence(timeout:10))
        let screenshot=XCTAttachment(screenshot:app.screenshot());screenshot.name="Automatic navigation confirmation";screenshot.lifetime = .keepAlways;add(screenshot)
        confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10))
        for (iteration,horizontalEdge) in [0.05,0.95].enumerated() {
            let source=root.appendingPathComponent("automatic.html").appending(queryItems:[URLQueryItem(name:"qa",value:String(iteration))])
            try open(source,app:app)
            let newTab=app.buttons["browser.domain-confirmation.new-tab"]
            XCTAssertTrue(newTab.waitForExistence(timeout:10),app.debugDescription)
            XCTAssertTrue(newTab.isEnabled)
            XCTAssertGreaterThanOrEqual(newTab.frame.height,44)
            let image=XCTAttachment(screenshot:app.screenshot());image.name="Domain confirmation buttons and yellow trust";image.lifetime = .keepAlways;add(image)
            newTab.coordinate(withNormalizedOffset:CGVector(dx:horizontalEdge,dy:0.5)).tap()
            XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
            app.buttons["browser.tabs"].tap()
            selectFixtureTab(title:"Automatic origin \(root.port ?? 0)?qa=\(iteration)",app:app)
            XCTAssertTrue(app.webViews.staticTexts["Automatic origin"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
            XCTAssertFalse(confirm.exists)
        }
        setConfirmation(false,app:app)
        try open(root.appendingPathComponent("automatic.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["Confirmed destination"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertFalse(confirm.exists)
    }

    @MainActor
    func testLongEpisodeListKeepsCurrentEpisodeVisibleWhenOrderChanges() async throws {
        let links=(1...180).map { "<li><a href='/player/8-1-\($0).html'>EP\($0)</a></li>" }.joined()
        let html="<meta name='viewport' content='width=device-width,initial-scale=1'><video style='width:100%;height:200px' playsinline></video><ul class='episode-list'>"+links+"</ul>"
        let server=try DownloadPlaybackHTTPFixture(files:["/player/8-1-28.html":Data(html.utf8)])
        let root=try await server.start();defer{server.stop()}
        let app=launch();try open(root.appendingPathComponent("player/8-1-28.html"),app:app)
        openEpisodes(app,video:true)
        let current=app.buttons["EP28"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertTrue(current.isHittable)
        XCTAssertTrue(current.isSelected)
        app.buttons["browser.episodes-order"].tap()
        XCTAssertTrue(current.waitForExistence(timeout:5))
        XCTAssertTrue(current.isHittable,app.debugDescription)
        XCTAssertTrue(current.isSelected)
        app.buttons["browser.episodes-select"].tap()
        current.tap()
        XCTAssertTrue(app.buttons["browser.episodes-download"].label.contains("1"))
    }

    @MainActor
    func testAutomaticPostNavigationKeepsNewTabActionAndRetainsSource() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Automatic POST origin</title><h3>Automatic POST origin</h3>
        <form id="submission" method="post"><input name="query" value="chosen"></form>
        <script>
        document.title='Automatic POST origin '+location.port;
        submission.action=location.origin.replace('127.0.0.1','localhost')+'/post-destination.html';
        setTimeout(()=>submission.submit(),600);
        </script>
        """#
        let server=try DownloadPlaybackHTTPFixture(files:[
            "/origin.html":Data("<body>POST settings fixture</body>".utf8),
            "/automatic-post.html":Data(html.utf8),
            "/post-destination.html":Data("<body>New tab destination</body>".utf8)])
        let root=try await server.start();defer{server.stop()}
        let app=launch();try open(root.appendingPathComponent("origin.html"),app:app)
        XCTAssertTrue(app.webViews.staticTexts["POST settings fixture"].firstMatch.waitForExistence(timeout:20))
        setConfirmation(true,app:app)
        try open(root.appendingPathComponent("automatic-post.html"),app:app)
        let newTab=app.buttons["browser.domain-confirmation.new-tab"]
        XCTAssertTrue(newTab.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(newTab.isEnabled)
        let image=XCTAttachment(screenshot:app.screenshot());image.name="POST confirmation keeps New Tab action";image.lifetime = .keepAlways;add(image)
        newTab.tap()
        XCTAssertTrue(app.webViews.staticTexts["New tab destination"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        app.buttons["browser.tabs"].tap()
        selectFixtureTab(title:"Automatic POST origin \(root.port ?? 0)",app:app)
        XCTAssertTrue(app.webViews.staticTexts["Automatic POST origin"].firstMatch.waitForExistence(timeout:10))
        XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
        setConfirmation(false,app:app)
    }

    @MainActor
    func testHoldingVideoTemporarilyAcceleratesAndRestoresItsPreviousRate() async throws {
        let file=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"playback-h264-aac",withExtension:"mp4"))
        let html=#"""
        <meta name="viewport" content="width=device-width,initial-scale=1"><body style="margin:0;font:18px system-ui"><h3>Hold speed fixture</h3>
        <button onclick="v.playbackRate=1.5;v.play();">Play fixture</button>
        <video id="v" src="/clip.mp4" playsinline loop style="width:100%;height:240px;display:block"></video><p id="status">Waiting</p>
        <button id="other" onclick="document.getElementById('actions').textContent='Other control '+(++clicks)">Other control</button><p id="actions">No actions</p>
        <script>let maximum=0,clicks=0;v.addEventListener('ratechange',()=>{maximum=Math.max(maximum,v.playbackRate);document.getElementById('status').textContent='Maximum '+maximum+'; current '+v.playbackRate});
        document.addEventListener('pointerup',event=>{if(event.target===v)document.getElementById('other').click()});
        </script></body>
        """#
        let embedded = "<meta name='viewport' content='width=device-width,initial-scale=1'><iframe id='player' style='width:100%;height:650px;border:0'></iframe><script>player.src=location.origin.replace('127.0.0.1','localhost')+'/hold.html'</script>"
        let server=try DownloadPlaybackHTTPFixture(files:["/hold.html":Data(html.utf8),"/embedded.html":Data(embedded.utf8),"/clip.mp4":try Data(contentsOf:file)])
        let root=try await server.start();server.releaseDownloads();defer{server.stop()}
        let app=launch()
        for path in ["hold.html", "embedded.html"] {
        try open(root.appendingPathComponent(path),app:app)
        let play=app.webViews.buttons["Play fixture"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout:20));play.tap()
        XCTAssertTrue(app.webViews.staticTexts["Maximum 1.5; current 1.5"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        let point=app.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0)).withOffset(CGVector(dx:app.frame.midX,dy:play.frame.maxY+100))
        point.press(forDuration:0.9)
        let toast = app.descendants(matching: .any).matching(identifier: "browser.video-hold-speed").firstMatch
        XCTAssertTrue(toast.exists, app.debugDescription)
        XCTAssertTrue(toast.label.contains("1.5×"), "After release the toast shows the restored rate")
        XCTAssertLessThan(toast.frame.maxY, app.frame.midY, "The hold speed belongs at the top of the viewport")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "video-hold-speed-" + path; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.webViews.staticTexts["Maximum 2; current 1.5"].firstMatch.waitForExistence(timeout:10),app.debugDescription)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3), "Releasing the video dismisses the temporary speed toast")
        XCTAssertTrue(app.webViews.staticTexts["Other control 1"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        app.webViews.buttons["Other control"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Other control 2"].firstMatch.waitForExistence(timeout:5),app.debugDescription)
        }
    }
}
