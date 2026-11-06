import XCTest

final class DownloadPlaybackUITests: XCTestCase {
    @MainActor
    func testExistingPhoneOfflineDownloadPlayerRoundTrip() async throws {
        continueAfterFailure = false
        guard let name = ProcessInfo.processInfo.environment["SOULO_DEVICE_OFFLINE_DOWNLOAD_QA"] else {
            throw XCTSkip("Requires an existing offline download on the connected phone")
        }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-video.defaultPlayer", "soulo", "-video.showsWebTools", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        app.open(URL(string: "soulo://downloads")!)
        let download = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "downloads.open.", name)).firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 10), app.debugDescription)
        download.tap()
        let fullscreen = app.buttons["media.mkv.fullscreen"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "Soulo")
        app.sliders["media.mkv.timeline"].adjust(toNormalizedSliderPosition: 0.075)
        let elapsed = app.staticTexts["media.mkv.timeline.elapsed"]
        let before = elapsed.label
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            elapsed.label != before
        }, object: nil)], timeout: 10)
        XCTAssertFalse(app.progressIndicators["media.mkv.buffering"].exists)
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        capture("Phone original offline download in Soulo")
        fullscreen.tap()
        let close = app.buttons["media.mkv.fullscreen.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let play = app.buttons["media.mkv.play"]
        if play.exists { play.tap() }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)], timeout: 5)
        XCTAssertEqual(play.frame.midX, app.frame.midX, accuracy: 3)
        XCTAssertEqual(play.frame.midY, app.frame.midY, accuracy: 3)
        capture("Phone offline Soulo landscape controls")
        app.buttons.matching(identifier: "media.file.player").firstMatch.tap()
        app.descendants(matching: .any)["media.file.engine.system"].firstMatch.tap()
        XCTAssertTrue(app.buttons["media.fullscreen.close"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "System")
        capture("Phone original offline download in system mode")
        let switchPlayer = app.buttons.matching(identifier: "media.file.player").firstMatch
        XCTAssertTrue(switchPlayer.waitForExistence(timeout: 5), app.debugDescription)
        capture("Phone offline system fullscreen switch")
        switchPlayer.tap()
        app.buttons["media.file.engine.soulo"].tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen.close"].waitForExistence(timeout: 10))
        app.buttons["media.mkv.fullscreen.close"].tap()
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "Soulo")
        app.open(URL(string: "soulo://")!)
    }

    @MainActor
    func testLeavingWebFullscreenRestoresPortraitBrowserAndHome() async throws {
        continueAfterFailure = false
        guard let direct = ProcessInfo.processInfo.environment["SOULO_DIRECT_MEDIA_URL"] else {
            throw XCTSkip("Set SOULO_DIRECT_MEDIA_URL to check a live native media document")
        }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO", "-video.showsWebTools", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: direct)]
        app.open(try XCTUnwrap(route.url))
        let tools = app.buttons["media.web.fullscreen.tools"]
        XCTAssertTrue(tools.waitForExistence(timeout: 25))
        tools.tap()
        app.descendants(matching: .any)["Play in landscape"].firstMatch.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)], timeout: 8)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Done", "关闭", "完成"])).firstMatch
        if close.exists && close.isHittable { close.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.09)).tap() }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width < app.frame.height && app.webViews.firstMatch.exists
                && !app.buttons["media.web.fullscreen.player"].exists
        }, object: nil)], timeout: 8)
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertLessThan(app.frame.width, app.frame.height)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Portrait home after leaving native landscape video"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor
    func testDownloadingVideoLinkOpensPlayerAndDownloadFinishes() async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><h2>Concurrent video download</h2><video src='/clip.mp4' controls preload='auto' loop playsinline style='width:100%'></video></body></html>"
        // Keep this small fixture downloading throughout slower UI operations;
        // range reads used by the player remain fast.
        let server = try DownloadPlaybackHTTPFixture(
            files: ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: video)], slowChunkSize: 128)
        let root = try await server.start()
        defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-video.defaultPlayer", "system", "-video.showsWebTools", "YES"]
        app.launch()
        var route = URLComponents()
        route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 20), app.debugDescription)
        tools.tap()
        let download = app.webViews.buttons["Download"].firstMatch
        XCTAssertTrue(download.waitForExistence(timeout: 5), app.debugDescription)
        download.tap()
        let status = app.buttons["browser.downloadStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), app.debugDescription)
        status.tap()
        let link = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "downloads.playWhileDownloading.")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(link.label, "Play while downloading")
        let rowShot = XCTAttachment(screenshot: app.screenshot())
        rowShot.name = "download-row-play-while-downloading"; rowShot.lifetime = .keepAlways; add(rowShot)
        link.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 10), app.debugDescription)
        let position = app.sliders["Playback position"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), app.debugDescription)
        let before = position.value as? String
        let advance = NSPredicate { _, _ in (position.value as? String) != before }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: advance, object: nil)], timeout: 8)
        let playerShot = XCTAttachment(screenshot: app.screenshot())
        playerShot.name = "download-in-progress-native-player"; playerShot.lifetime = .keepAlways; add(playerShot)
        let received = server.downloadedBytes
        let continued = NSPredicate { _, _ in server.downloadedBytes > received }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: continued, object: nil)], timeout: 5)
        let playerChoice = app.buttons.matching(identifier: "media.file.player").firstMatch
        XCTAssertTrue(playerChoice.waitForExistence(timeout: 5), "The generic network player must expose decoder switching")
        playerChoice.tap()
        app.descendants(matching: .any)["media.file.engine.soulo"].firstMatch.tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "Soulo")
        let souloShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        souloShot.name = "Network video in Soulo player"; souloShot.lifetime = .keepAlways; add(souloShot)
        app.buttons.matching(identifier: "media.file.player").firstMatch.tap()
        app.descendants(matching: .any)["media.file.engine.system"].firstMatch.tap()
        XCTAssertTrue(app.otherElements["media.preview"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "System")
        app.buttons["media.fullscreen"].tap()
        let fullscreenSwitch = app.buttons.matching(identifier: "media.file.player").firstMatch
        XCTAssertTrue(fullscreenSwitch.waitForExistence(timeout: 8), "System fullscreen must expose the Soulo switch")
        let nativePlay = app.buttons["media.native.play"], nativeTimeline = app.sliders["media.native.timeline"]
        XCTAssertTrue(nativePlay.waitForExistence(timeout: 5))
        XCTAssertTrue(nativeTimeline.waitForExistence(timeout: 5))
        XCTAssertEqual(nativePlay.frame.midX, app.frame.midX, accuracy: 3)
        XCTAssertEqual(nativePlay.frame.midY, app.frame.midY, accuracy: 3)
        XCTAssertGreaterThan(nativeTimeline.frame.midY, nativePlay.frame.maxY)
        let fullShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        fullShot.name = "System fullscreen Soulo switch"; fullShot.lifetime = .keepAlways; add(fullShot)
        fullscreenSwitch.tap()
        app.buttons["media.file.engine.soulo"].tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen.close"].waitForExistence(timeout: 10))
        app.buttons["media.mkv.fullscreen.close"].tap()
        XCTAssertTrue(app.buttons["media.mkv.fullscreen"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "Soulo")
        server.releaseDownloads()
        XCTAssertTrue(app.buttons["downloads.completion-toast"].waitForExistence(timeout: 15), app.debugDescription)
    }
    @MainActor
    func testWebFullscreenSwitchesModesAndClosesDirectly() async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body><video src='/clip.mp4' controls preload='auto' loop playsinline style='width:100%'></video></body></html>"
        let captured = ProcessInfo.processInfo.environment["SOULO_CAPTURED_PLAYER_DIR"].map { URL(fileURLWithPath: $0) }
        var files = ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: video)]
        if let captured {
            files["/page.html"] = Data("<meta name='viewport' content='width=device-width,initial-scale=1'><iframe src='/static/player/artplayer.html?url=https%3A%2F%2Fhn.bfvvs.com%2Fplay%2FDbD98gqd%2Findex.m3u8' style='border:0;width:100%;height:300px' allowfullscreen></iframe>".utf8)
            for (path, file) in [("/static/player/artplayer.html", "artplayer.html"),
                                 ("/static/player/artplayer/artplayer.min.js", "artplayer.min.js"),
                                 ("/static/player/artplayer/hls.min.js", "hls.min.js")] {
                files[path] = try Data(contentsOf: captured.appendingPathComponent(file))
            }
        }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); defer { server.stop() }
        server.releaseDownloads()
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        let preferSoulo = ProcessInfo.processInfo.environment["SOULO_TEST_SOULO_DEFAULT"] == "1"
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-video.defaultPlayer", preferSoulo ? "soulo" : "system", "-video.showsWebTools", "YES", "-media.file.systemPlayer", "YES"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        let pageURL = ProcessInfo.processInfo.environment["SOULO_DIRECT_MEDIA_URL"]
            ?? ProcessInfo.processInfo.environment["SOULO_LIVE_PAGE_URL"] ?? root.appendingPathComponent("page.html").absoluteString
        route.queryItems = [URLQueryItem(name: "url", value: pageURL)]
        app.open(try XCTUnwrap(route.url))
        let direct = ProcessInfo.processInfo.environment["SOULO_DIRECT_MEDIA_URL"]
        if direct == nil {
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 20), app.debugDescription)
            tools.tap()
            let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
            if !fullscreen.waitForExistence(timeout: 3) { tools.tap() }
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 5), app.debugDescription)
            fullscreen.tap()
        }
        func closeButton(_ soulo: Bool) -> XCUIElement {
            app.buttons[soulo ? "media.mkv.fullscreen.close" : "media.fullscreen.close"]
        }
        func reveal(_ soulo: Bool) {
            if !closeButton(soulo).exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            XCTAssertTrue(closeButton(soulo).waitForExistence(timeout: 5), app.debugDescription)
        }
        func choose(_ soulo: Bool) throws {
            let picker = app.buttons.matching(identifier: "media.file.player").firstMatch
            picker.tap()
            let option = app.descendants(matching: .any)[soulo ? "media.file.engine.soulo" : "media.file.engine.system"].firstMatch
            guard option.waitForExistence(timeout: 3) else { throw NSError(domain: "UnifiedPlayer.ModeMenu", code: 1, userInfo: [NSLocalizedDescriptionKey: app.debugDescription]) }
            option.tap()
            XCTAssertTrue(closeButton(soulo).waitForExistence(timeout: 12), app.debugDescription)
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
        }
        func checkRotationAndForeground(_ soulo: Bool) async {
            reveal(soulo)
            let play = app.buttons[soulo ? "media.mkv.play" : "media.native.play"]
            if play.label == "Pause" { play.tap() }
            let rotate = app.buttons["media.fullscreen.rotate"]
            XCTAssertTrue(rotate.waitForExistence(timeout: 3))
            let clock = app.staticTexts["media.fullscreen.clock"]
            XCTAssertTrue(clock.waitForExistence(timeout: 3))
            XCTAssertFalse(clock.label.isEmpty)
            XCTAssertEqual(clock.frame.midY, closeButton(soulo).frame.midY, accuracy: 2)
            XCTAssertLessThanOrEqual(clock.frame.maxX, app.buttons["media.file.player"].firstMatch.frame.minX)
            rotate.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.height > app.frame.width
            }, object: nil)], timeout: 4)
            XCTAssertTrue(closeButton(soulo).isHittable, "Portrait must remain in the same fullscreen session")
            XCTAssertTrue(rotate.isHittable, "Fullscreen must offer rotation in portrait too")
            rotate.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.width > app.frame.height
            }, object: nil)], timeout: 4)
            // Leave while actually playing, rather than masking a missing
            // background pause by pausing the fixture before switching apps.
            if play.label == "Play" { play.tap() }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                play.label == "Pause"
            }, object: nil)], timeout: 4)
            XCUIDevice.shared.press(.home)
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.launch()
            XCUIDevice.shared.orientation = .portrait
            app.activate()
            XCTAssertGreaterThan(app.frame.width, app.frame.height, "Returning from another app must retain landscape")
            reveal(soulo)
            XCTAssertEqual(play.label, "Play", "Ordinary video must pause in the background and stay paused on return")
            XCTAssertTrue(rotate.isHittable)
            XCTAssertTrue(clock.waitForExistence(timeout: 3))
        }
        XCTAssertTrue(closeButton(preferSoulo).waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertFalse(app.buttons["media.web.fullscreen.player"].exists, "Web fullscreen must use the shared component")
        reveal(preferSoulo)
        let picker = app.buttons.matching(identifier: "media.file.player").firstMatch
        XCTAssertEqual(picker.frame.midY, closeButton(preferSoulo).frame.midY, accuracy: 2)
        picker.tap()
        let souloChoice = app.descendants(matching: .any)["media.file.engine.soulo"].firstMatch
        XCTAssertTrue(souloChoice.waitForExistence(timeout: 3))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(souloChoice.waitForNonExistence(timeout: 3), "A blank tap must dismiss the mode menu")
        if !preferSoulo { try choose(true) }
        reveal(true)
        try choose(false)
        reveal(false)
        await checkRotationAndForeground(false)
        XCTAssertEqual(picker.frame.midY, closeButton(false).frame.midY, accuracy: 2)
        let nativeShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        nativeShot.name = "Shared fullscreen controls in system mode"; nativeShot.lifetime = .keepAlways; add(nativeShot)
        try choose(true)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.sliders["media.mkv.timeline"].isEnabled
        }, object: nil)], timeout: 8)
        XCTAssertTrue(app.progressIndicators["media.mkv.buffering"].waitForNonExistence(timeout: 8))
        reveal(true)
        await checkRotationAndForeground(true)
        // Pause so the three-second auto-hide cannot race the UI test's
        // separate accessibility snapshots while checking an explicit tap.
        let souloPlay = app.buttons["media.mkv.play"]
        if souloPlay.label == "Pause" { souloPlay.tap() }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(closeButton(true).waitForNonExistence(timeout: 2))
        XCTAssertFalse(app.staticTexts["media.fullscreen.clock"].exists, "Time must hide with the controls")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(closeButton(true).waitForExistence(timeout: 3), "A center tap must reveal the shared controls")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Shared fullscreen controls in Soulo mode"; shot.lifetime = .keepAlways; add(shot)
        closeButton(true).tap()
        XCTAssertTrue(app.buttons["media.web.close"].waitForNonExistence(timeout: 5), "Closing fullscreen must return directly to the page")
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
        }, object: nil)], timeout: 5)
    }

    @MainActor
    func testSiteNativeFullscreenJoinsSharedDefaultPlayer() async throws {
        try await verifySiteFullscreenUsesSharedPlayer(document: false)
    }

    @MainActor
    func testSiteContainerFullscreenJoinsSharedDefaultPlayer() async throws {
        try await verifySiteFullscreenUsesSharedPlayer(document: true)
    }

    @MainActor
    private func verifySiteFullscreenUsesSharedPlayer(document: Bool) async throws {
        continueAfterFailure = false
        let video = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>button{display:block;width:100%;height:44px;margin:10px 0}#actions{padding-top:40px}</style>
        <div id='container'><video id='video' src='/clip.mp4' controls preload='auto' loop playsinline style='width:100%;height:220px'></video></div>
        <div id='actions'>
        <button id='play-button'>Play video</button>
        <button id='pause-button'>Pause video</button>
        <button id='native-button' disabled>Site fullscreen</button>
        </div>
        <p id='request-status'>Request ready</p>
        <script>
        const v=document.getElementById('video');
        const status=document.getElementById('request-status');
        document.getElementById('play-button').addEventListener('click',()=>{status.textContent='Play requested';v.play()});
        document.getElementById('pause-button').addEventListener('click',()=>{status.textContent='Pause requested';v.pause()});
        document.getElementById('native-button').addEventListener('click',()=>{
          status.textContent='Request sent';
          \(document ? "document.getElementById('container').requestFullscreen()" : "(v.webkitEnterFullscreen||v.webkitEnterFullScreen||v.requestFullscreen).call(v)");
        });
        v.addEventListener('loadeddata',()=>document.getElementById('native-button').disabled=false,{once:true});
        window.addEventListener('soulo-video-fullscreen-request',event=>setTimeout(()=>{
          document.getElementById('request-status').textContent='Fullscreen hook accepted '+event.defaultPrevented;
        },0),true);
        </script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/site.html": Data(html.utf8), "/clip.mp4": Data(contentsOf: video)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO", "-video.defaultPlayer", "soulo"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("site.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let native = app.webViews.buttons["Site fullscreen"].firstMatch
        XCTAssertTrue(native.waitForExistence(timeout: 10))
        app.webViews.buttons["Play video"].firstMatch.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in native.isEnabled }, object: nil)], timeout: 8)
        app.webViews.buttons["Pause video"].firstMatch.tap()
        let buttonFrame = native.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: buttonFrame.midX, dy: buttonFrame.midY)).tap()
        let close = app.buttons["media.mkv.fullscreen.close"]
        if !close.waitForExistence(timeout: 3) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
        if !close.waitForExistence(timeout: 12) {
            let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); failure.name = "Site fullscreen entry"; failure.lifetime = .keepAlways; add(failure)
            XCTFail(app.debugDescription)
        }
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertEqual(app.buttons.matching(identifier: "media.file.player").firstMatch.value as? String, "Soulo")
        close.tap()
        XCTAssertTrue(app.buttons["media.web.close"].waitForNonExistence(timeout: 5))
    }

}
