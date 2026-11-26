import XCTest
import AVFoundation

final class WebEpisodeAndAdNavigationUITests: XCTestCase {
    @MainActor func testWebsiteElementFullscreenFillsScreenAndHidesSouloVideoTools() async throws {
        try await checkWebsiteElementFullscreen(embedded: false)
    }

    @MainActor func testEmbeddedPlayerFullscreenFillsScreenAndHidesSouloVideoTools() async throws {
        try await checkWebsiteElementFullscreen(embedded: true)
    }

    @MainActor private func checkWebsiteElementFullscreen(embedded: Bool) async throws {
        let clip = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Fullscreen viewport</title>
        <style>
        body { margin: 0; background: white }
        main { height: 320px; background: #e04f20; display: grid; place-content: center }
        video { width: 200px; height: 110px }
        html:fullscreen main { position: fixed; inset: 0; height: auto }
        html:fullscreen #enter, html:not(:fullscreen) #exit { display: none }
        </style>
        <main>
          <video src="/clip.mp4" playsinline muted autoplay loop></video>
          <button id="enter" onclick="document.documentElement.requestFullscreen()">Enter page fullscreen</button>
          <button id="exit" onclick="document.exitFullscreen()">Exit page fullscreen</button>
        </main>
        """
        var files = ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: clip)]
        if embedded {
            files["/frame.html"] = Data(html.utf8)
            files["/page.html"] = Data("""
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <body style="margin:0;background:white">
            <iframe src="/frame.html" allowfullscreen style="display:block;width:100%;height:380px;border:0"></iframe>
            </body>
            """.utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch(filtering: false, tools: true, takeover: false)
        defer { app.terminate() }
        try open(root.appendingPathComponent("page.html"), app: app)
        let enter = app.buttons["Enter page fullscreen"].firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 15), app.debugDescription)
        let tools = app.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), app.debugDescription)
        enter.tap()
        let exit = app.buttons["Exit page fullscreen"].firstMatch
        XCTAssertTrue(exit.waitForExistence(timeout: 10))
        try await Task.sleep(for: .milliseconds(700))

        continueAfterFailure = true
        let screen = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screen)
        attachment.name = "website-element-fullscreen-edges"; attachment.lifetime = .keepAlways; add(attachment)
        let image = try XCTUnwrap(screen.image.cgImage)
        // Sample clear areas between the clock, camera cutout and status icons.
        for x in [0.31, 0.69] {
            for y in [0.035, 0.97] {
                let position = CGRect(x: CGFloat(image.width) * x, y: CGFloat(image.height) * y, width: 1, height: 1)
                let pixel = try XCTUnwrap(image.cropping(to: position))
                var rgba = [UInt8](repeating: 0, count: 4)
                let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
                    guard let canvas = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    canvas.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return true
                }
                XCTAssertTrue(rendered && rgba[0] > 160 && rgba[1] < 130 && rgba[2] < 90, "Expected the player at screen position (\(x), \(y)), got \(rgba)")
            }
        }
        XCTAssertFalse(tools.exists)
        exit.tap()
        XCTAssertTrue(enter.waitForExistence(timeout: 10))
        XCTAssertTrue(tools.waitForExistence(timeout: 5))
    }

    @MainActor func testWebsiteNativeFullscreenStaysWithWebsitePlayer() async throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Website player ownership</title>
        <video id="v" src="/clip.mp4" playsinline controls loop style="width:100%;height:260px"></video>
        <button onclick="v.play();v.webkitEnterFullscreen()">Website fullscreen</button>
        <button onclick="v.play()">Resume website video</button><p id="state">Not entered</p>
        <script>v.addEventListener('webkitbeginfullscreen',()=>state.textContent='Website fullscreen entered');
        v.addEventListener('webkitendfullscreen',()=>state.textContent='Website fullscreen returned');
        setInterval(()=>{if(!v.webkitDisplayingFullscreen&&v.currentTime>0.2&&!v.paused)state.textContent='Website inline playing'},150);</script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": Data(contentsOf: fixture)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch(player: "soulo", tools: false, takeover: false); defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        try open(root.appendingPathComponent("page.html"), app: app)
        let entry = app.webViews.buttons["Website fullscreen"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15)); entry.tap()
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(app.otherElements["media.mkv.fullscreen.player"].exists)
        XCTAssertFalse(app.otherElements["media.fullscreen.player"].exists)
        var close: XCUIElement?
        for _ in 0..<3 {
            close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "Close", "关闭"])).allElementsBoundByIndex.first(where: { $0.isHittable })
            if close != nil { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        }
        guard let close else { XCTFail(app.debugDescription); return }
        let closeFrame = close.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: closeFrame.midX, dy: closeFrame.midY)).tap()
        let resume = app.webViews.buttons["Resume website video"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 8)); resume.tap()
        XCTAssertTrue(app.webViews.staticTexts["Website inline playing"].firstMatch.waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "website-native-player-not-replaced"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testWebToolsKeepPortraitVideoFullscreenInPortrait() async throws {
        try await checkWebToolsFullscreenAndReturn(portrait: true)
    }

    @MainActor func testWebToolsLandscapeVideoReturnsToPortraitBrowser() async throws {
        try await checkWebToolsFullscreenAndReturn(portrait: false)
    }

    @MainActor private func checkWebToolsFullscreenAndReturn(portrait: Bool) async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "Tests iPhone video orientation")
        let media = try await longVideoFixtureData(portrait: portrait)
        let comparison = portrait ? ">" : "<"
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <video src='/clip.mp4' preload='metadata' playsinline muted style='width:100%;height:300px'
          onloadedmetadata="if (this.videoHeight \(comparison) this.videoWidth) document.querySelector('p').textContent = 'Video ready'"></video>
        <p>Loading video</p>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": media])
        let root = try await server.start(); server.releaseDownloads()
        let app = launch(player: "soulo", filtering: false, tools: true)
        defer { app.terminate(); server.stop(); XCUIDevice.shared.orientation = .portrait }

        try open(root.appendingPathComponent("page.html"), app: app)
        let inline = app.webViews.staticTexts["Video ready"].firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 20))
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 8)); tools.tap()
        let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 5)); fullscreen.tap()
        try requireWebFullscreen(app)

        let canvas = app.otherElements["media.fullscreen.canvas"].firstMatch
        XCTAssertEqual(canvas.value as? String, portrait ? "portrait" : "landscape")
        XCTAssertEqual(app.frame.height > app.frame.width, portrait)
        let play = app.buttons["media.mkv.play"]
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in play.exists && play.label == "Pause" }, object: nil)
        await fulfillment(of: [started], timeout: 10)
        if portrait {
            play.tap()
            XCUIDevice.shared.orientation = .landscapeRight
            XCTAssertEqual(canvas.value as? String, "portrait")
            XCTAssertGreaterThan(app.frame.height, app.frame.width)
            XCUIDevice.shared.orientation = .portrait
        }
        let back = app.buttons["media.mkv.fullscreen.close"]
        for _ in 0..<3 where canvas.exists {
            if !back.isHittable { canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.3)).tap() }
            let frame = back.frame
            if !frame.isEmpty {
                let appFrame = app.frame
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX - appFrame.minX, dy: frame.midY - appFrame.minY)).tap()
            }
            if canvas.waitForNonExistence(timeout: 1) { break }
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !canvas.exists && app.frame.height > app.frame.width && inline.isHittable
        }, object: nil)], timeout: 8)
    }

    @MainActor func testWebToolsFullscreenOpensSouloWithThePagePositionAndRate() async throws {
        continueAfterFailure = false
        let asset = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <video id='clip' playsinline loop style='width:100%;height:260px'></video>
        <button id='start'>Start inline playback</button><p id='status'>Waiting</p><p id='native'></p>
        <script>
          const video = document.getElementById('clip'), status = document.getElementById('status');
          let loads = 0, ready = false;
          video.addEventListener('loadstart', () => loads++);
          video.src = '/clip.mp4';
          document.getElementById('start').onclick = () => { video.playbackRate = 0.75; video.play(); };
          video.addEventListener('timeupdate', () => {
            if (!ready && video.currentTime > 0.35) { ready = true; status.textContent = 'Inline video is playing'; }
          });
          video.addEventListener('pause', () => {
            if (ready && loads === 1 && video.currentTime > 0.35 && video.playbackRate === 0.75)
              status.textContent = 'Inline position retained';
          });
          video.addEventListener('webkitbeginfullscreen', () => document.getElementById('native').textContent = 'System fullscreen opened');
        </script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": try Data(contentsOf: asset)],
            holdRequest: { $0.path == "/clip.mp4" && $0.headers["range"] == "bytes=0-0" })
        let root = try await server.start()
        defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        let app = launch(player: "soulo", tools: true, takeover: false)
        defer { app.terminate() }
        try open(root.appendingPathComponent("page.html"), app: app)
        let start = app.webViews.buttons["Start inline playback"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        XCTAssertTrue(app.webViews.staticTexts["Inline video is playing"].firstMatch.waitForExistence(timeout: 8))
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 6)); tools.tap()
        let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 6)); fullscreen.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.receivedRequests.contains { $0.path == "/clip.mp4" && $0.headers["range"] == "bytes=0-0" }
        }, object: nil)], timeout: 8)
        XCTAssertTrue(app.webViews.staticTexts["Inline video is playing"].exists,
            "The webpage must continue playback while the native range probe is pending")
        server.releaseDownloads()
        try requireWebFullscreen(app)
        let canvas = app.otherElements["media.fullscreen.canvas"].firstMatch
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(canvas.value as? String, "landscape")
        }
        let speed = app.buttons["media.file.speed"]
        if !speed.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
        XCTAssertTrue(speed.exists || speed.waitForExistence(timeout: 5))
        XCTAssertEqual(speed.value as? String, "0.75×")
        // Wait for the short fixture to finish so the three-second controls
        // timeout cannot expire while XCTest waits for the app to idle.
        let finished = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "media.mkv.play", "Play")).firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 20), app.debugDescription)
        let close = app.buttons["media.mkv.fullscreen.close"]
        XCTAssertTrue(close.isHittable, app.debugDescription)
        close.tap()
        XCTAssertTrue(app.otherElements["media.mkv.fullscreen.player"].firstMatch.waitForNonExistence(timeout: 8), app.debugDescription)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.frame.height > app.frame.width
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 8), .completed)
        }
        XCTAssertTrue(app.webViews.staticTexts["Inline position retained"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.webViews.staticTexts["System fullscreen opened"].exists)
    }

    @MainActor func testWebVideoTakeoverOptInUsesSelectedPlayer() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Opt-in web video</title>
        <video id="v" src="/clip.mp4" playsinline controls loop style="width:100%;height:260px"></video>
        <button onclick="v.play();v.webkitEnterFullscreen()">Website fullscreen</button>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": Data(contentsOf: file)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        let app = launch(player: "soulo", tools: false, takeover: true); defer { app.terminate() }
        try open(root.appendingPathComponent("page.html"), app: app)
        let button = app.webViews.buttons["Website fullscreen"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 15)); button.tap()
        try requireWebFullscreen(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "web-video-takeover-enabled"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testFullscreenSpeedMenuOpensAboveItsButton() async throws {
        continueAfterFailure = false
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <video id="v" src="/clip.mp4" playsinline controls loop style="width:100%;height:260px"></video>
        <button onclick="v.play();v.webkitEnterFullscreen()">Website fullscreen</button>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/clip.mp4": Data(contentsOf: file)])
        let root = try await server.start()
        server.releaseDownloads()
        defer { server.stop(); XCUIDevice.shared.orientation = .portrait }

        for engine in ["system", "soulo"] {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(player: engine, tools: false, takeover: true)
            defer { app.terminate() }
            try open(root.appendingPathComponent("page.html"), app: app)
            let fullscreen = app.webViews.buttons["Website fullscreen"].firstMatch
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 15), app.debugDescription)
            fullscreen.tap()
            try requireWebFullscreen(app)

            let speed = app.buttons["media.file.speed"]
            if !speed.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            XCTAssertTrue(speed.waitForExistence(timeout: 5), app.debugDescription)
            let play = app.buttons["media.mkv.play"]
            if play.exists && play.label == "Pause" { play.tap() }
            let loading = app.staticTexts["media.video.loading"]
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                loading.exists && ["Fully loaded", "加载完成"].contains(loading.label)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed, app.debugDescription)
            let prefix = "media.mkv"
            XCTAssertFalse(app.staticTexts[prefix + ".timeline.cache"].exists)
            let cacheTrack = XCTAttachment(screenshot: app.screenshot())
            cacheTrack.name = "video-cache-track-" + engine; cacheTrack.lifetime = .keepAlways; add(cacheTrack)
            let speedButtonFrame = speed.frame
            XCTAssertGreaterThanOrEqual(loading.frame.minX, speedButtonFrame.maxX)
            let targetRate = speed.value as? String == "0.75×" ? "1.25" : "0.75"
            speed.tap()

            let option = app.buttons["media.file.rate.\(targetRate)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(option.isHittable, app.debugDescription)
            XCTAssertLessThanOrEqual(option.frame.maxY, speedButtonFrame.minY, "The speed menu must open above its button in \(engine)")
            let speedMenu = XCTAttachment(screenshot: app.screenshot())
            speedMenu.name = "video-speed-menu-" + engine; speedMenu.lifetime = .keepAlways; add(speedMenu)
            option.tap()
            XCTAssertTrue(option.waitForNonExistence(timeout: 5))
            XCTAssertEqual(speed.value as? String, targetRate + "×")

            let timeline = app.sliders[prefix + ".timeline"]
            XCTAssertEqual(timeline.frame.height, 44, accuracy: 1)
            let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            start.tap()
            start.press(forDuration: 0.05,
                thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.72, dy: 0.5)))
            let elapsed = app.staticTexts[prefix + ".timeline.elapsed"]
            let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                elapsed.label.split(separator: ":").last.flatMap { Int($0) }.map { $0 >= 5 } ?? false
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 5), .completed, app.debugDescription)
        }
    }

    @MainActor func testFullscreenMenusAndRotationWorkInWindowedLayouts() async throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Fullscreen canvas</title>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Main</div><ul class="dy-collect-list">
        <li><span class="c-name">01</span><a href="/one.mp4">Stream</a></li><li><span class="c-name">02</span><a href="/two.mp4">Stream</a></li></ul></div>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Backup</div><ul class="dy-collect-list">
        <li><span class="c-name">01</span><a href="/two.mp4">Stream</a></li><li><span class="c-name">02</span><a href="/three.mp4">Stream</a></li></ul></div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8), "/one.mp4": Data(contentsOf: file), "/two.mp4": Data(contentsOf: file), "/three.mp4": Data(contentsOf: file)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        for engine in ["system", "soulo"] {
            let app = launch(player: engine, episodeDock: true); defer { app.terminate() }
            try open(root.appendingPathComponent("page.html"), app: app); openEpisodes(app)
            app.scrollViews.buttons["01"].firstMatch.tap(); try requireWebFullscreen(app)
            func tap(_ id: String) throws {
                let button = app.buttons[id].firstMatch
                for _ in 0..<4 {
                    if button.exists {
                        let rect = button.frame
                        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
                        return
                    }
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                }
                XCTFail(app.debugDescription); throw URLError(.timedOut)
            }
            let play = app.buttons["media.mkv.play"]
            if play.exists && play.label == "Pause" { try tap("media.mkv.play") }
            let canvas = app.descendants(matching: .any).matching(identifier: "media.fullscreen.canvas").firstMatch
            XCTAssertTrue(canvas.waitForExistence(timeout: 5))
            let original = canvas.value as? String ?? "portrait"
            for expected in [original == "portrait" ? "landscape" : "portrait", original] {
                try tap("media.fullscreen.rotate")
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: canvas)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 6), .completed, app.debugDescription)
                XCTAssertFalse(app.alerts.firstMatch.exists, "Windowed rotation must not raise a geometry error")
                try requireWebFullscreen(app)
                if expected == "landscape", engine == "system" {
                    try tap("media.fullscreen.options")
                    let settings = app.buttons["media.fullscreen.settings"]
                    XCTAssertTrue(settings.waitForExistence(timeout: 5))
                    let scroll = app.scrollViews["media.fullscreen.options.scroll"]
                    if scroll.exists { scroll.swipeUp() }
                    XCTAssertTrue(settings.isHittable, app.debugDescription)
                    let shot = XCTAttachment(screenshot: app.screenshot())
                    shot.name = "fullscreen-options-landscape"; shot.lifetime = .keepAlways; add(shot)
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
                    XCTAssertTrue(settings.waitForNonExistence(timeout: 5))
                }
            }
            try tap("media.file.episodes")
            let source = app.buttons["media.file.episodes.source"].firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 5)); source.tap()
            let backup = app.buttons["Backup"].firstMatch
            XCTAssertTrue(backup.waitForExistence(timeout: 5)); XCTAssertTrue(backup.isHittable)
            let menu = XCTAttachment(screenshot: app.screenshot()); menu.name = "fullscreen-source-menu-contrast-" + engine; menu.lifetime = .keepAlways; add(menu)
            backup.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Backup"), object: source)
            XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
            try tap("media.file.episodes.close")
            try tap("media.fullscreen.options")
            XCTAssertTrue(app.buttons["media.fullscreen.settings"].waitForExistence(timeout: 5))
            let menuRows = ["media.sleep-timer", "media.download", "media.fullscreen.share", "media.fullscreen.settings"]
                .map { app.buttons[$0].firstMatch }
            XCTAssertTrue(menuRows.allSatisfy(\.exists), app.debugDescription)
            let frames = menuRows.map(\.frame)
            let first = try XCTUnwrap(frames.first)
            XCTAssertGreaterThanOrEqual(first.height, 43.5)
            let floatingWindow = app.buttons["media.picture-in-picture"].firstMatch
            let alignedRows = floatingWindow.exists ? frames + [floatingWindow.frame] : frames
            for row in alignedRows {
                XCTAssertEqual(row.minX, first.minX, accuracy: 1)
                XCTAssertEqual(row.height, first.height, accuracy: 1)
            }
            let gaps = zip(frames, frames.dropFirst()).map { $1.minY - $0.maxY }
            XCTAssertGreaterThanOrEqual(gaps[0], 0)
            for gap in gaps.dropFirst() { XCTAssertEqual(gap, gaps[0], accuracy: 1) }
            let settings = app.buttons["media.fullscreen.settings"]
            let scroll = app.scrollViews["media.fullscreen.options.scroll"]
            if scroll.exists, !settings.isHittable { scroll.swipeUp() }
            XCTAssertTrue(settings.isHittable, app.debugDescription)
            let options = XCTAttachment(screenshot: app.screenshot()); options.name = "fullscreen-options-contrast-" + engine; options.lifetime = .keepAlways; add(options)
            app.terminate()
        }
    }

    @MainActor func testLiveMtyyExplicitFullscreenDecodesVideo() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_MTY_QA"] == "1", "Opt-in user-reported live video")
        for engine in ["soulo", "system"] {
            let app = launch(player: engine, filtering: false, episodeDock: true, grouped: false, tools: true)
            try open(URL(string: "https://www.mtyy5.com/vodplay/155698-4-1.html")!, app: app)
            let tools = app.webViews.buttons["Video tools"].firstMatch
            guard tools.waitForExistence(timeout: 40) else {
                let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "mtyy-web-page-no-tools-" + engine; shot.lifetime = .keepAlways; add(shot)
                XCTFail(app.debugDescription); app.terminate(); continue
            }
            let before = XCTAttachment(screenshot: app.screenshot()); before.name = "mtyy-before-fullscreen-" + engine; before.lifetime = .keepAlways; add(before)
            tools.tap()
            let full = app.webViews.buttons["Fullscreen"].firstMatch
            XCTAssertTrue(full.waitForExistence(timeout: 8)); full.tap()
            try requireWebFullscreen(app)
            let diagnostic = app.staticTexts["media.volume.diagnostics"]
            XCTAssertTrue(diagnostic.waitForExistence(timeout: 10))
            let decoded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "frameReady=true"), object: diagnostic)
            XCTAssertEqual(XCTWaiter.wait(for: [decoded], timeout: 30), .completed, diagnostic.label)
            let metadata = XCTAttachment(string: diagnostic.label + "\n" + app.debugDescription); metadata.name = "mtyy-playback-state-" + engine; metadata.lifetime = .keepAlways; add(metadata)
            let after = XCTAttachment(screenshot: app.screenshot()); after.name = "mtyy-fullscreen-" + engine; after.lifetime = .keepAlways; add(after)
            let episodes = app.buttons["media.file.episodes"].firstMatch
            for _ in 0..<4 where !episodes.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            XCTAssertTrue(episodes.waitForExistence(timeout: 5)); episodes.tap()
            let second = app.buttons["media.file.episode.https://www.mtyy5.com/vodplay/155698-4-2.html"].firstMatch
            XCTAssertTrue(second.waitForExistence(timeout: 5), app.debugDescription); second.tap()
            let page = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "4-2.html"), object: diagnostic)
            XCTAssertEqual(XCTWaiter.wait(for: [page], timeout: 50), .completed, diagnostic.label)
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "frameReady=true"), object: diagnostic)], timeout: 30), .completed, diagnostic.label)
            let selected = XCTAttachment(screenshot: app.screenshot()); selected.name = "mtyy-second-episode-" + engine; selected.lifetime = .keepAlways; add(selected)
            app.terminate()
        }
    }

    @MainActor private func requireWebFullscreen(_ app: XCUIApplication) throws {
        let host = app.otherElements["media.mkv.fullscreen.player"].firstMatch
        guard host.waitForExistence(timeout: 20) else { XCTFail(app.debugDescription); throw URLError(.timedOut) }
        XCTAssertFalse(app.buttons["media.copy-url"].exists, "Web video has no URL-bearing intermediate page")
        XCTAssertFalse(app.buttons["media.mkv.fullscreen.exit"].exists)
    }

    @MainActor private func openFullscreenEpisodes(_ app: XCUIApplication) {
        let drawer = app.otherElements["media.file.episodes.drawer"].firstMatch
        let button = app.buttons["media.file.episodes"].firstMatch
        for _ in 0..<4 {
            if drawer.exists { return }
            if button.isHittable {
                let rect = button.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
                if drawer.waitForExistence(timeout: 0.7) { return }
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        XCTAssertTrue(drawer.exists, app.debugDescription)
    }

    @MainActor
    func testLiveBaiduFreePrivilegeButton() throws {
        guard ProcessInfo.processInfo.environment["SOULO_LIVE_BAIDU_PRIVILEGE_QA"] == "1" else {
            throw XCTSkip("Opt-in live Baidu privilege page check")
        }
        let url = try XCTUnwrap(URL(string: "https://pan.baidu.com/wap/svip/privilege/freeget?na_immerse_theme=1&task_scene=reward_video_bidding_scene_hybrid_forward_download_speed&from=pc_acceleration"))
        for filtering in [false, true] {
            let app = launch(incognito: true, confirmCrossDomain: false, filtering: filtering)
            try open(url, app: app)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 30))
            Thread.sleep(forTimeInterval: 15)
            let cancel = app.buttons["browser.external-app-confirmation.cancel"]
            if cancel.exists { cancel.tap() }
            func record(_ stage: String) {
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "baidu-privilege-\(filtering)-\(stage)-tree"; tree.lifetime = .keepAlways; add(tree)
                let shot = XCTAttachment(screenshot: app.screenshot())
                shot.name = "baidu-privilege-\(filtering)-\(stage)"; shot.lifetime = .keepAlways; add(shot)
            }
            record("loaded")
            let button = app.webViews.staticTexts["开通SVIP 畅享"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
            button.tap()
            let address = app.buttons["Edit Address or Search"].firstMatch
            let reached = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "snsyun.baidu.com"), object: address)
            XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: 10), .completed,
                "The chosen privilege button must reach Baidu's app handoff page with either filtering setting")
            record("clicked")
            app.terminate()
        }
    }

    @MainActor
    func testScriptButtonsConfirmComputedCrossSiteDestinations() async throws {
        let html = #"""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>.privilege-free-get-privilege-buy-btn{margin:20px;padding:16px;background:#ffd69e;border-radius:24px;text-align:center}</style>
        <div class="privilege-free-get-privilege-buy-btn" id="replace"><span>Open chosen app page</span></div>
        <div class="privilege-free-get-privilege-buy-btn" id="window"><span>Open chosen app window</span></div>
        <button id="native">Open native script button</button>
        <script>
        const next=location.origin.replace('127.0.0.1','localhost')+'/chosen.html';
        document.getElementById('replace').addEventListener('click',()=>location.href=next);
        document.getElementById('window').addEventListener('click',()=>window.open(next));
        document.getElementById('native').addEventListener('click',()=>location.href=next);
        </script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8),
            "/chosen.html": Data("<body>Chosen app page reached</body>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: true); defer { app.terminate() }
        for label in ["Open chosen app page", "Open chosen app window", "Open native script button"] {
            try open(root.appendingPathComponent("entry.html"), app: app)
            let control = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
            let previousRequests = server.receivedRequests.filter { $0.path == "/chosen.html" }.count
            let previousTabLabel = app.buttons["browser.tabs"].label
            control.tap()
            let confirm = app.buttons["browser.domain-confirmation.continue"]
            guard confirm.waitForExistence(timeout: 10) else {
                XCTFail("An undeclared third-party target must be confirmed: " + app.debugDescription)
                return
            }
            XCTAssertEqual(server.receivedRequests.filter { $0.path == "/chosen.html" }.count, previousRequests,
                "The destination request must remain blocked until confirmation")
            XCTAssertFalse(app.webViews.staticTexts["Chosen app page reached"].firstMatch.exists)
            if label == "Open chosen app window" {
                XCTAssertEqual(app.buttons["browser.tabs"].label, previousTabLabel,
                    "A script popup must not switch or create a visible tab before approval")
            }
            let frame = confirm.frame
            if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertLessThan(frame.width, 200) }
            confirm.tap()
            XCTAssertTrue(app.webViews.staticTexts["Chosen app page reached"].firstMatch.waitForExistence(timeout: 10),
                "Confirming must resume the original request")
            XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
        }
    }

    @MainActor
    func testScriptNavigationWorksWithoutButtonClassification() async throws {
        let html = #"""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>.x91,.r42,custom-action{display:block;padding:16px;margin:12px;background:#eee}</style>
        <div class="x91" tabindex="0" id="focus"><span>Open keyboard action</span></div>
        <div class="r42" onclick="openChosen()"><span>Open inline action</span></div>
        <div id="plain">Open ordinary container</div>
        <custom-action id="shadow"></custom-action>
        <div id="card" style="height:200px;cursor:pointer;background:#eee;margin:12px">Open larger card</div>
        <p><a id="scriptLink" href="javascript:void(0);" rel="nofollow noopener"><span>Open result link</span></a></p>
        <script>
        const next=location.origin.replace('127.0.0.1','localhost')+'/chosen.html';
        function openChosen(){location.href=next;}
        document.getElementById('focus').addEventListener('click',openChosen);
        document.getElementById('plain').addEventListener('click',openChosen);
        document.getElementById('card').addEventListener('click',openChosen);
        document.getElementById('scriptLink').addEventListener('click',()=>window.open(next,'_blank'));
        const root=document.getElementById('shadow').attachShadow({mode:'open'});
        root.innerHTML='<div tabindex="0" class="r73" style="padding:16px"><span>Open shadow action</span></div>';
        root.firstElementChild.addEventListener('click',()=>window.open(next));
        </script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8),
            "/chosen.html": Data("<body>Semantic action reached</body>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: false); defer { app.terminate() }
        for label in ["Open ordinary container", "Open keyboard action", "Open inline action", "Open shadow action", "Open larger card", "Open result link"] {
            try open(root.appendingPathComponent("entry.html"), app: app)
            let control = app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
            control.tap()
            XCTAssertTrue(app.webViews.staticTexts["Semantic action reached"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
        }
    }

    @MainActor
    func testSameSiteScriptsAndWindowsWorkWithoutButtonMarkup() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <p id="plain">Open same-site page</p>
        <div id="window">Open same-site window</div>
        <script>
        document.getElementById('plain').addEventListener('click',()=>location.href='/chosen.html');
        document.getElementById('window').addEventListener('click',()=>window.open('/chosen.html'));
        </script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8),
            "/chosen.html": Data("<body>Same-site destination</body>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: true); defer { app.terminate() }
        for label in ["Open same-site page", "Open same-site window"] {
            try open(root.appendingPathComponent("entry.html"), app: app)
            let target = app.webViews.staticTexts[label].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 15))
            target.tap()
            XCTAssertTrue(app.webViews.staticTexts["Same-site destination"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
        }
    }

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
    private func launch(incognito: Bool = false, confirmCrossDomain: Bool? = nil, player: String? = nil, filtering: Bool = true, episodeDock: Bool? = nil, grouped: Bool? = nil, tools: Bool? = nil, downloadControls: Bool? = nil, takeover: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-privacy_https_upgrade_enabled", "NO",
            "-ad_block_enabled", filtering ? "YES" : "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-is_incognito", incognito ? "YES" : "NO"]
        app.launchArguments += ["-video.takeOverWebPlayers", takeover ? "YES" : "NO"]
        if let confirmCrossDomain {
            app.launchArguments += ["-ad_block_confirm_cross_domain", confirmCrossDomain ? "YES" : "NO"]
        }
        if let player { app.launchArguments += ["-video.defaultPlayer", player] }
        if let tools { app.launchArguments += ["-video.showsWebTools", tools ? "YES" : "NO"] }
        if let downloadControls { app.launchArguments += ["-video.showsWebDownloadControls", downloadControls ? "YES" : "NO"] }
        if let grouped {
            app.launchArguments += ["-tab_overview_grouped", grouped ? "YES" : "NO"]
            app.launchEnvironment["SOULO_VIDEO_VOLUME_TRACE"] = "1"
        }
        if let episodeDock {
            app.launchArguments += ["-video.showsEpisodeDock", episodeDock ? "YES" : "NO", "-icloud_sync_enabled", "NO"]
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
    func testCustomScriptButtonWithFilteringDisabled() async throws {
        try await checkCustomScriptButton(filtering: false)
    }

    @MainActor
    func testCustomScriptButtonWithFilteringEnabled() async throws {
        try await checkCustomScriptButton(filtering: true)
    }

    @MainActor
    private func checkCustomScriptButton(filtering: Bool) async throws {
        let html = #"""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
        <body style="font:20px system-ui"><h1>Script entry fixture</h1>
        <input aria-label="Entry note" onkeydown="if(event.key==='Enter'){this.blur();return false}">
        <div id="entry" style="cursor:pointer;padding:24px;background:#eee"><span>Continue to chosen page</span></div>
        <script>document.getElementById('entry').onclick=()=>window.open('/chosen.html','entry');</script>
        </body></html>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8),
            "/chosen.html": Data("""
                <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
                <body style="font:20px system-ui">Script entry reached
                <p id="opener">Checking opener</p><button onclick="window.close()">Close entry window</button>
                <script>document.getElementById('opener').textContent=window.opener?'Opener preserved':'Missing opener';</script>
                </body></html>
                """.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: false, filtering: filtering)
        defer { app.terminate() }
        try open(root.appendingPathComponent("entry.html"), app: app)
        let entry = app.webViews.staticTexts["Continue to chosen page"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 20), app.debugDescription)
        let note = app.webViews.textFields["Entry note"].firstMatch
        let savedNote = "Keep " + UUID().uuidString.prefix(6)
        note.tap(); note.typeText(savedNote + "\n")
        let tabs = app.buttons["browser.tabs"]
        let count = try XCTUnwrap(Int(tabs.label.split(separator: " ").first.map(String.init) ?? ""))
        entry.tap()
        XCTAssertTrue(app.webViews.staticTexts["Script entry reached"].firstMatch.waitForExistence(timeout: 10),
            "A trusted click on a custom script button must remain usable with filtering enabled")
        XCTAssertTrue(app.webViews.staticTexts["Opener preserved"].firstMatch.exists)
        XCTAssertEqual(tabs.label, "\(count + 1) Tabs")
        XCTAssertFalse(app.buttons["Open in Current Tab"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Script window in full browser tab filtering-\(filtering)"
        screenshot.lifetime = .keepAlways; add(screenshot)
        let close = app.webViews.buttons["Close entry window"].firstMatch
        XCTAssertTrue(close.isEnabled)
        XCTAssertTrue(app.frame.contains(CGPoint(x: close.frame.midX, y: close.frame.midY)))
        // iOS 26.2 reports no accessibility hit point for script-created windows
        // even in the isolated raw WKWebView control. Exercise a real touch and
        // verify its effect instead of using a synthetic DOM click.
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "window.close must return to the original tab")
        XCTAssertEqual(tabs.label, "\(count) Tabs")
        XCTAssertEqual(note.value as? String, savedNote, "Opening and closing a script window must preserve the original document")
    }

    @MainActor
    func testScriptControlsCanUseComputedCrossSiteURLs() async throws {
        let html = #"""
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <button id="replace">Continue in this tab</button>
        <div role="button" id="window" style="padding:24px">Continue in a new tab</div>
        <script>
        const next=location.origin.replace('127.0.0.1','localhost')+'/chosen.html';
        document.getElementById('replace').onclick=()=>location.href=next;
        document.getElementById('window').onclick=()=>window.open(next);
        </script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/entry.html": Data(html.utf8),
            "/chosen.html": Data("<body>Computed cross-site destination</body>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: false); defer { app.terminate() }
        for label in ["Continue in this tab", "Continue in a new tab"] {
            try open(root.appendingPathComponent("entry.html"), app: app)
            let control = app.webViews.buttons[label].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 15), app.debugDescription)
            control.tap()
            XCTAssertTrue(app.webViews.staticTexts["Computed cross-site destination"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["browser.domain-confirmation.continue"].exists)
            XCTAssertFalse(app.buttons["Open in Current Tab"].exists)
        }
    }

    @MainActor
    func testLiveScriptEntryUsesNormalTabWithFilteringEnabled() throws {
        guard let address = ProcessInfo.processInfo.environment["SOULO_LIVE_SCRIPT_ENTRY_URL"],
              let url = URL(string: address) else { throw XCTSkip("Opt-in live script-entry check") }
        let app = launch(incognito: true, confirmCrossDomain: false); defer { app.terminate() }
        try open(url, app: app)
        let entry = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "点此进入")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 60), app.debugDescription)
        let tabs = app.buttons["browser.tabs"]
        let count = try XCTUnwrap(Int(tabs.label.split(separator: " ").first.map(String.init) ?? ""))
        entry.tap()
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(count + 1) Tabs"), object: tabs)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 5), .completed)
        XCTAssertEqual(tabs.label, "\(count + 1) Tabs", "The real entry must open a browser tab while filtering stays enabled")
        XCTAssertFalse(app.buttons["Open in Current Tab"].exists)
        app.buttons["Edit Address or Search"].firstMatch.tap()
        let current = app.textFields["addressEditor.pageURL"]
        XCTAssertTrue(current.waitForExistence(timeout: 5), app.debugDescription)
        let destination = try XCTUnwrap(URL(string: try XCTUnwrap(current.value as? String)))
        XCTAssertEqual(destination.host, url.host)
        XCTAssertEqual(destination.path, "/home")
    }

    @MainActor
    func testRawWebKitScriptWindowTouchBaseline() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_RAW_SCRIPT_WINDOW_QA"] == "1" else {
            throw XCTSkip("Opt-in minimal WKWebView window control")
        }
        let viewport = "<meta name=viewport content='width=device-width,initial-scale=1'>"
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/entry.html": Data((viewport + "<button onclick=\"window.open('/child.html')\">Open raw window</button>").utf8),
            "/child.html": Data((viewport + """
                <p id="count">Count 0</p><button onclick="document.getElementById('count').textContent='Count 1'">Count touch</button>
                <button onclick="window.close()">Close raw window</button>
                """).utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.soulo.qa.RawScriptWindow")
        app.launchArguments = ["-url", root.appendingPathComponent("entry.html").absoluteString]
        app.launch(); defer { app.terminate() }
        let entry = app.webViews.buttons["Open raw window"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let count = app.webViews.buttons["Count touch"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10))
        print("RAW_SCRIPT_WINDOW_COUNT_HITTABLE=\(count.isHittable) FRAME=\(count.frame)")
        if count.isHittable { count.tap() } else { count.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.webViews.staticTexts["Count 1"].firstMatch.waitForExistence(timeout: 5))
        let close = app.webViews.buttons["Close raw window"].firstMatch
        print("RAW_SCRIPT_WINDOW_CLOSE_HITTABLE=\(close.isHittable) FRAME=\(close.frame)")
        if close.isHittable { close.tap() } else { close.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    @MainActor
    func testUndeclaredCrossSiteScriptsAskInsteadOfBeingSilentlyBlocked() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <p id="popup">Open script window</p><p id="replace">Open script page</p>
        <p id="synthetic">Open synthetic link</p><p id="blank">Open blank then navigate</p>
        <a id="explicit">Open declared destination</a>
        <script>
        const other=location.origin.replace('127.0.0.1','localhost');
        document.getElementById('explicit').href=other+'/chosen.html';
        document.addEventListener('click',e=>{
          if(e.target.id==='popup')window.open(other+'/script.html');
          if(e.target.id==='replace')location.href=other+'/script.html';
          if(e.target.id==='synthetic'){
            const a=document.createElement('a');a.href=other+'/script.html';a.target='_blank';
            document.body.append(a);a.click();a.remove();
          }
          if(e.target.id==='blank'){
            const child=window.open('about:blank');
            setTimeout(()=>child.location.href=other+'/script.html',200);
          }
        });
        </script>
        """#
        let server = try DownloadPlaybackHTTPFixture(files: ["/page.html": Data(html.utf8),
            "/script.html": Data("<body>Script destination</body>".utf8),
            "/chosen.html": Data("<body>Declared destination</body>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(incognito: true, confirmCrossDomain: true); defer { app.terminate() }
        for label in ["Open script window", "Open script page", "Open synthetic link", "Open blank then navigate"] {
            try open(root.appendingPathComponent("page.html"), app: app)
            let target = app.webViews.staticTexts[label].firstMatch
            XCTAssertTrue(target.waitForExistence(timeout: 15), app.debugDescription)
            target.tap()
            let cancel = app.buttons["browser.domain-confirmation.cancel"]
            guard cancel.waitForExistence(timeout: 10) else {
                XCTFail(app.debugDescription)
                return
            }
            XCTAssertFalse(app.webViews.staticTexts["Script destination"].exists)
            cancel.tap()
            XCTAssertEqual(server.receivedRequests.filter { $0.path == "/script.html" }.count, 0)
        }
        try open(root.appendingPathComponent("page.html"), app: app)
        app.webViews.staticTexts["Open script page"].firstMatch.tap()
        let confirm = app.buttons["browser.domain-confirmation.continue"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10)); confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Script destination"].firstMatch.waitForExistence(timeout: 10))
        try open(root.appendingPathComponent("page.html"), app: app)
        app.webViews.links["Open declared destination"].firstMatch.tap()
        XCTAssertTrue(app.webViews.staticTexts["Declared destination"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(confirm.exists)
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
            if ["Site handled result", "Delegated result card"].contains(label) {
                let confirm = app.buttons["browser.domain-confirmation.continue"]
                XCTAssertTrue(confirm.waitForExistence(timeout: 10), "A replacement destination is confirmed instead of guessed from element type")
                confirm.tap()
            }
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
        let submissions = server.receivedRequests.filter { $0.path == "/submit.html" }
        XCTAssertEqual(submissions.count, 1, "The original form request must not be replayed")
        let submission = try XCTUnwrap(submissions.first)
        XCTAssertEqual(submission.method, "POST")
        XCTAssertEqual(String(decoding: submission.body, as: UTF8.self), "query=chosen")
        XCTAssertEqual(submission.headers["origin"], root.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
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
    func testLandscapeMiniPlayerRestoresWebEpisodesAndClosesInOneStep() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let data = try Data(contentsOf: fixture)
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Episode mini player</title>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Main</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/first.mp4">Stream</a></li>
        <li><span class="c-name">Episode 2</span><a href="/second.mp4">Stream</a></li></ul></div>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Backup</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/backup.mp4">Stream</a></li></ul></div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(html.utf8),
            "/first.mp4": data, "/second.mp4": data, "/backup.mp4": data])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        defer { XCUIDevice.shared.orientation = .portrait }
        for engine in ["system", "soulo"] {
            let app = launch(player: engine, episodeDock: true)
            defer { app.terminate() }
            XCUIDevice.shared.orientation = .landscapeLeft
            try open(root.appendingPathComponent("detail.html"), app: app)
            openEpisodes(app)
            app.scrollViews.buttons["Episode 1"].firstMatch.tap()
            try requireWebFullscreen(app)
            let closeID = "media.mkv.fullscreen.close"
            let exitID = "media.mkv.fullscreen.exit"
            func reveal(_ id: String) throws -> XCUIElement {
                let button = app.buttons[id]
                for _ in 0..<3 {
                    if button.exists && button.isHittable { return button }
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                    if button.waitForExistence(timeout: 0.5) && button.isHittable { return button }
                }
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Missing control " + id
                shot.lifetime = .keepAlways; add(shot)
                throw URLError(.timedOut)
            }
            func pausePlayback() throws {
                let id = "media.mkv.play"
                for _ in 0..<3 {
                    let play = try reveal(id)
                    if play.label != "Pause" { return }
                    let frame = play.frame
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                    let paused = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        play.exists && play.label == "Play"
                    }, object: nil)
                    if XCTWaiter.wait(for: [paused], timeout: 1) == .completed { return }
                }
                throw URLError(.timedOut)
            }
            XCTAssertTrue(app.buttons[closeID].waitForExistence(timeout: 12), app.debugDescription)
            try pausePlayback()
            try reveal("media.file.episodes").tap()
            let secondID = "media.file.episode." + root.appendingPathComponent("second.mp4").absoluteString
            XCTAssertTrue(app.buttons[secondID].waitForExistence(timeout: 5)); app.buttons[secondID].tap()
            XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForNonExistence(timeout: 8))
            try pausePlayback()
            try reveal(closeID).tap()
            XCTAssertTrue(app.buttons["browser.episodes-order"].waitForExistence(timeout: 6), "Close must return straight to the episode picker")
            XCTAssertFalse(app.buttons["media.web.close"].exists, "Do not expose the intermediate preview page")
            app.buttons["Done"].firstMatch.tap()
            let mini = app.descendants(matching: .any)["media.mini-player"].firstMatch
            XCTAssertTrue(mini.waitForExistence(timeout: 8), app.debugDescription)
            app.buttons["Hide at screen edge"].firstMatch.tap()
            let expandCard = app.buttons.matching(NSPredicate(format: "label == %@", "Expand player")).firstMatch
            XCTAssertTrue(expandCard.waitForExistence(timeout: 5)); expandCard.tap()
            XCTAssertTrue(app.buttons["Hide at screen edge"].firstMatch.waitForExistence(timeout: 5))
            app.buttons.matching(NSPredicate(format: "label == %@", "Expand player")).firstMatch.tap()
            try pausePlayback()
            try reveal("media.file.episodes").tap()
            XCTAssertTrue(app.buttons[secondID].waitForExistence(timeout: 5), "The mini-player must retain the same episodes")
            XCTAssertTrue(app.buttons[secondID].isSelected, "The selected episode must survive collapsing")
            let restoredShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            restoredShot.name = "Restored web episodes from mini-player · " + engine
            restoredShot.lifetime = .keepAlways; add(restoredShot)
            let firstID = "media.file.episode." + root.appendingPathComponent("first.mp4").absoluteString
            app.buttons[firstID].tap()
            XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForNonExistence(timeout: 8))
            try pausePlayback()
            XCTAssertFalse(app.buttons[exitID].exists, "The preview-page exit is removed")
            let originalLandscape = app.frame.width > app.frame.height
            for expected in [!originalLandscape, originalLandscape] {
                if UIDevice.current.userInterfaceIdiom == .pad {
                    // iPad windowed scenes can reject programmatic orientation;
                    // physical rotation still exercises both fullscreen layouts.
                    XCUIDevice.shared.orientation = expected ? .landscapeLeft : .portrait
                } else { try reveal("media.fullscreen.rotate").tap() }
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.frame.width > app.frame.height) == expected
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 6), .completed)
                try requireWebFullscreen(app)
                try pausePlayback()
            }
            try reveal(closeID).tap()
            XCTAssertTrue(app.webViews.staticTexts["Main"].firstMatch.waitForExistence(timeout: 6),
                          "The mini-player page must also close in one step")
            XCTAssertFalse(app.buttons["media.web.close"].exists)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Landscape close and episode restoration · " + engine
            shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    @MainActor
    func testPlayerEpisodeGridSwitchesAndReportsUnresolvableEpisode() async throws {
        continueAfterFailure = false
        let fixture = try XCTUnwrap(Bundle(for:Self.self).url(forResource:"playback-h264-aac",withExtension:"mp4"))
        let data = try Data(contentsOf:fixture)
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'><title>Episode grid</title>
        <div class='dy-collect-video'><div class='dy-collect-video-name'>Main</div><ul class='dy-collect-list'>
        <li><span class='c-name'>Episode 1</span><a href='/first.mp4'>Stream</a></li>
        <li><span class='c-name'>Episode 2</span><a href='/second.mp4'>Stream</a></li>
        <li><span class='c-name'>Episode 3</span><a href='/player/3.html'>Stream</a></li>
        <li><span class='c-name'>Episode 4</span><a href='/fourth.mp4'>Stream</a></li></ul></div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(html.utf8), "/first.mp4": data,
            "/second.mp4": data, "/fourth.mp4": data],
            holdRequest: { $0.path == "/second.mp4" && $0.headers["range"] == "bytes=0-0" })
        let root = try await server.start(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        let app = launch(player:"system",episodeDock:true);defer{app.terminate()}
        try open(root.appendingPathComponent("detail.html"),app:app);openEpisodes(app)
        app.scrollViews.buttons["Episode 1"].firstMatch.tap()
        try requireWebFullscreen(app)
        openFullscreenEpisodes(app)
        let first=app.buttons["media.file.episode."+root.appendingPathComponent("first.mp4").absoluteString]
        let second=app.buttons["media.file.episode."+root.appendingPathComponent("second.mp4").absoluteString]
        XCTAssertTrue(second.waitForExistence(timeout:5),app.debugDescription)
        XCTAssertEqual(first.frame.midY,second.frame.midY,accuracy:2,"At least two episodes fit in one row")
        second.tap()
        let drawer = app.otherElements["media.file.episodes.drawer"].firstMatch
        let loadingValue = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != nil AND value != ''"), object: second)
        await fulfillment(of: [loadingValue], timeout: 3)
        XCTAssertTrue(drawer.exists, "The viewer can change the selection while the next episode loads")
        XCTAssertTrue(first.isSelected, "The playing episode stays marked during preparation")
        XCTAssertFalse(second.isSelected)
        let loading = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); loading.name = "Pending episode in fullscreen drawer"; loading.lifetime = .keepAlways; add(loading)

        let fourth = app.buttons["media.file.episode." + root.appendingPathComponent("fourth.mp4").absoluteString]
        fourth.tap()
        XCTAssertTrue(drawer.waitForNonExistence(timeout: 8))
        server.releaseDownloads()
        openFullscreenEpisodes(app)
        XCTAssertTrue(fourth.isSelected, "The latest choice wins when the previous network request finishes")
        XCTAssertFalse(second.isSelected)
        let broken=app.buttons["media.file.episode."+root.appendingPathComponent("player/3.html").absoluteString]
        XCTAssertTrue(broken.waitForExistence(timeout:5),app.debugDescription);broken.tap()
        let failure = app.descendants(matching: .any)["media.file.episodes.failure"].firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 8), "A rejected page must fail without waiting for media discovery. Requests: \(server.receivedRequests.map(\.path))")
        XCTAssertTrue(drawer.exists)
        XCTAssertTrue(fourth.isSelected)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Episode 3 ·")).firstMatch.waitForExistence(timeout: 5))
        let retry = app.buttons["media.file.episodes.retry"]
        XCTAssertTrue(retry.exists); retry.tap()
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            server.receivedRequests.filter { $0.path == "/player/3.html" }.count >= 2
        }, object: nil)], timeout: 5)
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(fourth.isSelected)
        let shot=XCTAttachment(screenshot:XCUIScreen.main.screenshot());shot.name="player-episode-grid-and-failure-retry";shot.lifetime = .keepAlways;add(shot)
    }

    @MainActor
    func testAutomaticPlayerKeepsFullscreenWhileSelectingWebEpisodes() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let data = try Data(contentsOf: fixture)
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Episode player</title>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Main</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/first.mp4">Stream</a></li>
        <li><span class="c-name">Episode 2</span><a href="/second.mp4">Stream</a></li></ul></div>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Backup</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/backup.mp4">Stream</a></li></ul></div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(html.utf8),
            "/first.mp4": data, "/second.mp4": data, "/backup.mp4": data])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch(player: "soulo")
        defer { XCUIDevice.shared.orientation = .portrait }
        try open(root.appendingPathComponent("detail.html"), app: app)
        openEpisodes(app)
        app.scrollViews.buttons["Episode 1"].firstMatch.tap()
        try requireWebFullscreen(app)
        let currentPlay = app.buttons["media.mkv.play"]
        if currentPlay.exists && currentPlay.label == "Pause" { currentPlay.tap() }
        XCUIDevice.shared.orientation = .landscapeLeft
        let close = app.buttons["media.mkv.fullscreen.close"]
        openFullscreenEpisodes(app)
        let second = app.buttons["media.file.episode.\(root.appendingPathComponent("second.mp4").absoluteString)"]
        XCTAssertTrue(second.waitForExistence(timeout: 4), app.debugDescription)
        second.tap()
        XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["media.mkv.fullscreen.player"].firstMatch.exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        XCTAssertFalse(app.buttons["media.file.player"].exists)
        openFullscreenEpisodes(app)
        let first = app.buttons["media.file.episode.\(root.appendingPathComponent("first.mp4").absoluteString)"]
        XCTAssertTrue(first.waitForExistence(timeout: 4), app.debugDescription)
        first.tap()
        XCTAssertTrue(app.otherElements["media.file.episodes.drawer"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.otherElements["media.mkv.fullscreen.player"].firstMatch.exists)
        XCTAssertGreaterThan(app.frame.width, app.frame.height)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Web episodes preserve fullscreen"; shot.lifetime = .keepAlways; add(shot)
        for _ in 0..<3 {
            if !close.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
            if close.isHittable { close.tap(); break }
        }
        XCTAssertTrue(app.otherElements["media.mkv.fullscreen.player"].firstMatch.waitForNonExistence(timeout: 5),
                      "Closing must dismiss the active fullscreen player")
        XCTAssertTrue(app.buttons["media.web.close"].waitForNonExistence(timeout: 5),
                      "Closing fullscreen must dismiss the preview page as well")
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
        let app = launch(downloadControls: true)
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
    func testLiveMovieCardsOpenWithAdFiltering() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_AD_CLICK_QA"] == "1",
                          "Requires live Mtime and Cupfox results")
        let app = launch(incognito: true, confirmCrossDomain: true, filtering: true)
        defer { app.terminate() }

        let cases = [
            ("https://live.mtime.com/home", "乐呵到底"),
            ("https://www.cupfox.lol/movie/1795.html", "厂长资源")
        ]
        for (address, cardLabel) in cases {
            try open(try XCTUnwrap(URL(string: address)), app: app)
            let card = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", cardLabel)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 25), app.debugDescription)
            for _ in 0..<5 where !card.isHittable { app.webViews.firstMatch.swipeUp() }
            card.tap()
            let confirmation = app.buttons["browser.domain-confirmation.cancel"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 8),
                          "The card should reach the standard cross-domain confirmation")
            confirmation.tap()
        }
    }

    @MainActor
    func testLiveYoukuPlaysFromFirstPageWithAdFiltering() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_YOUKU_QA"] == "1", "Requires the live Youku player")
        let url = try XCTUnwrap(URL(string: "https://m.youku.com/alipay_video/id_XNjU1MDAxMDYzMg==.html?spm=a2hww.8166708.drawer3.2"))
        for filtering in [true, false] {
            let app = launch(incognito: true, confirmCrossDomain: false, filtering: filtering)
            defer { app.terminate() }
            try open(url, app: app)
            let web = app.webViews.firstMatch
            XCTAssertTrue(web.waitForExistence(timeout: 12))
            let playerTitle = web.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "第1话 仙人不爱世人")).firstMatch
            XCTAssertTrue(playerTitle.waitForExistence(timeout: 20), app.debugDescription)
            web.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.19)).tap()
            let playingTime = web.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"0?0:[0-5][1-9]"#)).firstMatch
            let continueInBrowser = web.staticTexts["继续使用浏览器"].firstMatch
            var played = false
            for _ in 0..<12 {
                if continueInBrowser.exists && continueInBrowser.isHittable { continueInBrowser.tap() }
                if playingTime.waitForExistence(timeout: 3) { played = true; break }
            }
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "Youku-initial-playback-filtering-\(filtering)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertTrue(played, app.debugDescription)
        }
    }

    @MainActor
    func testLiveBilibiliHomepageStaysInSouloWhenOpenedFromAnotherSite() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_LIVE_BILIBILI_LINK_QA"] == "1",
                          "Requires access to the live Bilibili homepage")
        let page = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <a href='https://www.bilibili.com/'>Bilibili homepage</a>
        <a href='https://www.bilibili.com/' target='_blank'>Bilibili homepage in new tab</a>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/results": Data(page.utf8)])
        let root = try await server.start()
        defer { server.stop() }
        let app = launch(confirmCrossDomain: true)
        defer { app.terminate() }

        for name in ["Bilibili homepage", "Bilibili homepage in new tab"] {
            try open(root.appendingPathComponent("results"), app: app)
            let link = app.webViews.links[name].firstMatch
            XCTAssertTrue(link.waitForExistence(timeout: 12))
            link.tap()
            let address = app.buttons["Edit Address or Search"].firstMatch
            let isBilibili = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let host = address.value as? String ?? ""
                return host == "bilibili.com" || host.hasSuffix(".bilibili.com")
            }, object: nil)
            await fulfillment(of: [isBilibili], timeout: 20)
            XCTAssertEqual(app.state, .runningForeground)
            XCTAssertFalse(app.otherElements["browser.external-app-confirmation"].exists)
        }
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

extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testWebVideoDownloadVisibilityInSystemPlayer() async throws {
        try await verifyWebVideoDownloadVisibility(engine: "system")
    }

    @MainActor func testWebVideoDownloadVisibilityInSouloPlayer() async throws {
        try await verifyWebVideoDownloadVisibility(engine: "soulo")
    }

    @MainActor private func verifyWebVideoDownloadVisibility(engine: String) async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let bytes = try Data(contentsOf: fixture)
        func page(_ number: Int) -> Data {
            Data("""
            <meta name='viewport' content='width=device-width,initial-scale=1'>
            <title>Video download visibility \(number)</title>
            <style>body{margin:0;font:16px system-ui}video{display:block;width:100%;height:210px}h1{font-size:18px}</style>
            <h1>Episode \(number) page</h1>
            <video src='/clip\(number).mp4' controls playsinline preload='metadata' loop></video>
            <audio src='/sound.m4a' preload='none'></audio>
            <ul class='episode-list'><li><a href='/ep1.html'>Episode 1</a></li><li><a href='/ep2.html'>Episode 2</a></li></ul>
            """.utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: ["/ep1.html": page(1), "/ep2.html": page(2),
            "/clip1.mp4": bytes, "/clip2.mp4": bytes, "/sound.m4a": bytes])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        for visible in [false, true] {
            let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
            app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
            app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
                "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-privacy_https_upgrade_enabled", "NO",
                "-ad_block_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
                "-browser_toolbar_actions", "(home,resources,more)", "-video.defaultPlayer", engine,
                "-video.showsWebTools", "YES", "-video.showsEpisodeDock", "YES",
                "-video.showsWebDownloadControls", visible ? "YES" : "NO"]
            app.launch(); defer { app.terminate() }
            try open(root.appendingPathComponent("ep1.html"), app: app)
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 15)); tools.tap()
            XCTAssertTrue(app.webViews.buttons["Fullscreen"].firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.webViews.buttons["Download"].firstMatch.exists, visible)
            let episodes = app.webViews.buttons["Episodes"].firstMatch
            XCTAssertTrue(episodes.waitForExistence(timeout: 5)); episodes.tap()
            XCTAssertTrue(app.buttons["browser.episodes-order"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["browser.episodes-select"].exists, visible)
            XCTAssertEqual(app.buttons["browser.episodes-downloads"].exists, visible)
            if visible {
                app.buttons["Episode 1"].firstMatch.press(forDuration: 1)
                XCTAssertTrue(app.buttons["browser.episode-download"].waitForExistence(timeout: 3))
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
            }
            app.buttons["Episode 2"].firstMatch.tap()
            XCTAssertTrue(app.webViews.staticTexts["Episode 2 page"].firstMatch.waitForExistence(timeout: 10), "Episode links must still navigate normally")
            app.buttons["Web Resources"].firstMatch.tap()
            let videos = app.buttons["resources.tab.videos"]
            XCTAssertTrue(videos.waitForExistence(timeout: 10)); videos.tap()
            XCTAssertEqual(app.buttons["resources.media.download.video"].exists, visible)
            let audio = app.buttons["resources.tab.audio"]
            XCTAssertTrue(audio.exists); audio.tap()
            XCTAssertTrue(app.buttons["resources.media.download.audio"].exists, "Audio downloads are independent of video controls")
            videos.tap()
            let preview = app.buttons["resources.video.play"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5)); preview.tap()
            try requireWebFullscreen(app)
            let options = app.buttons["media.fullscreen.options"]
            let settings = app.buttons["media.fullscreen.settings"]
            for _ in 0..<4 {
                if settings.exists { break }
                if options.exists {
                    let rect = options.frame
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
                    if settings.waitForExistence(timeout: 0.7) { break }
                }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            }
            XCTAssertTrue(settings.exists, app.debugDescription)
            XCTAssertEqual(app.buttons["media.download"].exists, visible)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "video-download-controls-\(engine)-\(visible ? "on" : "off")"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    @MainActor func testBothFullscreenPlayersSupportHorizontalSeekingAndIPadPreview() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Episode mini player</title>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Main</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/first.mp4">Stream</a></li>
        <li><span class="c-name">Episode 2</span><a href="/second.mp4">Stream</a></li></ul></div>
        <div class="dy-collect-video"><div class="dy-collect-video-name">Backup</div><ul class="dy-collect-list">
        <li><span class="c-name">Episode 1</span><a href="/backup.mp4">Stream</a></li></ul></div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/detail.html": Data(html.utf8),
            "/first.mp4": try Data(contentsOf: fixture), "/second.mp4": try Data(contentsOf: fixture)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        let engines = ProcessInfo.processInfo.environment["SOULO_VOLUME_SOULO_ONLY"] == "1" ? ["soulo"] : ["system", "soulo"]
        for engine in engines {
            XCUIDevice.shared.orientation = .portrait
            let app = launch(player: engine, episodeDock: true, grouped: false)
            try open(root.appendingPathComponent("detail.html"), app: app)
            XCTAssertTrue(app.webViews.buttons["Episodes"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertGreaterThan(app.frame.width, app.frame.height)
            openEpisodes(app); app.scrollViews.buttons["Episode 1"].firstMatch.tap()
            let prefix = "media.mkv"
            try requireWebFullscreen(app)
            let play = app.buttons[prefix + ".play"]
            for _ in 0..<4 {
                if !play.exists || !play.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
                if play.waitForExistence(timeout: 1) && play.label == "Pause" {
                    let frame = play.frame
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                }
                if play.exists && play.label == "Play" { break }
            }
            XCTAssertEqual(play.label, "Play", app.debugDescription)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            // Keep the gesture on the video surface above the transport buttons.
            func drag(_ from: CGFloat, _ to: CGFloat, y: CGFloat = 0.34) {
                origin.withOffset(CGVector(dx: app.frame.width * from, dy: app.frame.height * y))
                    .press(forDuration: 0.5, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * to, dy: app.frame.height * y)),
                           withVelocity: .slow, thenHoldForDuration: 0.1)
            }
            drag(0.3, 0.6)
            let feedback = app.descendants(matching: .any).matching(identifier: prefix + ".gesture.feedback").firstMatch
            XCTAssertTrue(feedback.waitForExistence(timeout: 1), app.debugDescription)
            XCTAssertTrue(feedback.label.contains("+"), feedback.label)
            let forwardClock = feedback.label
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = engine + "-horizontal-seek"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
            drag(0.65, 0.35)
            XCTAssertTrue(feedback.waitForExistence(timeout: 1), app.debugDescription)
            XCTAssertTrue(feedback.label.contains("−"), feedback.label)
            XCTAssertNotEqual(feedback.label.components(separatedBy: "  ").first, forwardClock.components(separatedBy: "  ").first,
                "Committing a forward seek and then rewinding must change the actual target")
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
            if !play.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
            XCTAssertTrue(play.waitForExistence(timeout: 2)); XCTAssertEqual(play.label, "Play", "Seeking must keep a paused player paused")
            // Preserve the existing vertical adjustment gestures alongside seeking.
            origin.withOffset(CGVector(dx: app.frame.width * 0.75, dy: app.frame.height * 0.60))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: app.frame.width * 0.75, dy: app.frame.height * 0.40)),
                       withVelocity: .fast, thenHoldForDuration: 0.05)
            XCTAssertTrue(feedback.waitForExistence(timeout: 1)); XCTAssertTrue(feedback.label.contains("%"))
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
            #if !targetEnvironment(simulator)
            func waitForVolumeFeedback() -> Bool {
                let end = Date().addingTimeInterval(2)
                while Date() < end {
                    if feedback.exists { return true }
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return false
            }
            var returnButton: XCUIDevice.Button = .volumeUp
            XCUIDevice.shared.press(.volumeDown)
            if !waitForVolumeFeedback() {
                // Dynamic iPad buttons can reverse with orientation. A key at
                // its limit changes nothing; require feedback after an actual change.
                XCUIDevice.shared.press(.volumeUp)
                returnButton = .volumeDown
                let observed = waitForVolumeFeedback()
                if !observed { print("VOLUME DIAG \(engine): \(app.staticTexts["media.volume.diagnostics"].label)") }
                XCTAssertTrue(observed, "A physical volume change must update the video HUD")
            }
            let firstVolumeLabel = feedback.label
            XCTAssertTrue(firstVolumeLabel.contains("%"))
            let volumeShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            volumeShot.name = engine + "-physical-volume-hud"; volumeShot.lifetime = .keepAlways; add(volumeShot)
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
            XCUIDevice.shared.press(returnButton)
            XCTAssertTrue(waitForVolumeFeedback())
            let returnedVolumeLabel = feedback.label
            XCTAssertTrue(returnedVolumeLabel.contains("%"))
            XCTAssertNotEqual(firstVolumeLabel, returnedVolumeLabel, "Opposite physical keys must change the observed in-app volume")
            print("VOLUME HUD QA \(engine): \(firstVolumeLabel) -> \(returnedVolumeLabel)")
            XCTAssertTrue(feedback.waitForNonExistence(timeout: 3))
            app.activate()
            #endif
            let close = app.buttons["media.mkv.fullscreen.close"]
            if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            for _ in 0..<3 {
                let frame = close.frame
                origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                if close.waitForNonExistence(timeout: 1) { break }
            }
            guard !close.exists else { XCTFail("Fullscreen did not close"); app.terminate(); return }
            XCTAssertTrue(app.buttons["browser.episodes-order"].waitForExistence(timeout: 5))
            app.navigationBars["Episodes"].buttons["Done"].tap()
            let tabsButton = app.buttons["browser.tabs"]
            XCTAssertTrue(tabsButton.waitForExistence(timeout: 5))
            let card = app.descendants(matching: .any).matching(identifier: "tabs.card.preview").firstMatch
            for _ in 0..<3 {
                let frame = tabsButton.frame
                origin.withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
                if card.waitForExistence(timeout: 2) { break }
            }
            guard card.exists else { XCTFail(app.debugDescription); app.terminate(); return }
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertGreaterThan(card.frame.width, 340)
                XCTAssertGreaterThan(card.frame.width / card.frame.height, 0.9, "iPad previews should retain webpage geometry")
            }
            let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); preview.name = engine + "-ipad-preview"; preview.lifetime = .keepAlways; add(preview)
            app.terminate()
        }
    }
}

extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testWebPlayButtonStartsPausedVideoFullscreenWithoutRotatingIPad() async throws {
        let mediaData = try await longVideoFixtureData()
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Web play intent</title>
        <style>body{margin:0}video{width:100%;height:300px}</style>
        <video src="/first.mp4" controls playsinline preload="metadata"></video>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/play.html": Data(html.utf8), "/first.mp4": mediaData])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        for engine in ["system", "soulo"] {
            let app = launch(player: engine)
            try open(root.appendingPathComponent("play.html"), app: app)
            let tools = app.webViews.buttons["Video tools"].firstMatch
            guard tools.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); app.terminate(); return }
            tools.tap()
            let button = app.webViews.buttons["Fullscreen"].firstMatch
            guard button.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); app.terminate(); return }
            button.tap()
            let fullscreen = app.otherElements["media.mkv.fullscreen.player"].firstMatch
            guard fullscreen.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); app.terminate(); return }
            let play = app.buttons["media.mkv.play"]
            var started = false
            for _ in 0..<4 {
                if !play.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
                if play.exists && play.label == "Pause" { started = true; break }
                try await Task.sleep(for: .milliseconds(300))
            }
            XCTAssertTrue(started, "An explicit web play action must start a previously paused video")
            let frame = app.frame
            if UIDevice.current.userInterfaceIdiom == .pad {
                XCTAssertLessThan(frame.width, frame.height, "iPad fullscreen must preserve the current portrait window")
            } else {
                XCTAssertGreaterThan(frame.width, frame.height, "iPhone should enter landscape playback")
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = engine + "-web-play-orientation"; shot.lifetime = .keepAlways; add(shot)
            let back = app.buttons["media.mkv.fullscreen.close"].firstMatch
            for _ in 0..<4 where fullscreen.exists {
                if back.exists {
                    let rect = back.frame
                    app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: rect.midX, dy: rect.midY)).tap()
                    if fullscreen.waitForNonExistence(timeout: 1) { break }
                } else {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
                }
            }
            XCTAssertTrue(fullscreen.waitForNonExistence(timeout: 6))
            XCTAssertTrue(app.webViews.buttons["Video tools"].firstMatch.waitForExistence(timeout: 6))
            let returnedToPortrait = NSPredicate { _, _ in app.frame.height > app.frame.width }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: returnedToPortrait, object: nil)],
                                          timeout: 5), .completed)
            app.terminate()
        }
    }
}

@MainActor func longVideoFixtureData(portrait: Bool = false) async throws -> Data {
    let fixture = try XCTUnwrap(Bundle(for: WebEpisodeAndAdNavigationUITests.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
    let asset = AVURLAsset(url: fixture), composition = AVMutableComposition()
    let clipDuration = try await asset.load(.duration)
    for index in 0..<8 {
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: clipDuration), of: asset,
            at: CMTimeMultiply(clipDuration, multiplier: Int32(index)))
    }
    if portrait {
        let track = try XCTUnwrap(composition.tracks(withMediaType: .video).first)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: track.naturalSize.height, ty: 0)
    }
    let longVideo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    defer { try? FileManager.default.removeItem(at: longVideo) }
    let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
    export.outputURL = longVideo; export.outputFileType = .mp4
    await withCheckedContinuation { continuation in export.exportAsynchronously { continuation.resume() } }
    guard export.status == .completed else { throw export.error ?? URLError(.cannotDecodeContentData) }
    return try Data(contentsOf: longVideo)
}

extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testInlineVideoNeverAddsAPageCornerPlayButtonAfterPlaybackScrollAndRemoval() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Inline video regression</title>
        <h1>Inline video regression</h1>
        <video id="v" controls playsinline muted preload="metadata" style="width:100%;height:200px" src="/first.mp4"></video>
        <button onclick="v.play()">Play inline</button>
        <button onclick="v.src='/second.mp4';v.play()">Switch source</button>
        <button onclick="v.pause();v.remove()">Remove player</button>
        <iframe src="/hidden.html" style="display:none"></iframe>
        <div style="height:1400px"></div><p>Below the player</p>
        """
        let hidden = "<script>var player_aaaa={url:location.origin+'/first.mp4?hidden=1'};</script>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/inline.html": Data(html.utf8), "/hidden.html": Data(hidden.utf8), "/first.mp4": try Data(contentsOf: fixture), "/second.mp4": try Data(contentsOf: fixture)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = launch(player: "system", episodeDock: false, tools: true); defer { app.terminate() }
        try open(root.appendingPathComponent("inline.html"), app: app)
        let entry = app.buttons["browser.configured-video.play"]
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 10))
        XCTAssertFalse(entry.exists)
        app.webViews.buttons["Play inline"].tap()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(entry.exists)
        app.webViews.buttons["Switch source"].tap()
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(entry.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "inline-video-without-stray-page-play-button"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.webViews.firstMatch.swipeUp()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(entry.exists)
        app.webViews.firstMatch.swipeDown()
        let remove = app.webViews.buttons["Remove player"]
        if !remove.isHittable { app.webViews.firstMatch.swipeDown() }
        remove.tap()
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertFalse(entry.exists, "Recycling the real player must not expose an unrelated hidden frame's play button")
    }

    @MainActor func testConfiguredPlayerFallbackOffersNativeFullscreenAndKeepsEpisodes() async throws {
        let media = try await longVideoFixtureData()
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Configured player</title>
        <script>var player_aaaa={encrypt:0,url:location.origin+'/first.mp4'};</script>
        <p>The external webpage player is still loading.</p>
        <ul class="episode-list"><li><a href="/first.mp4">Episode 1</a></li><li><a href="/second.mp4">Episode 2</a></li></ul>
        """
        let hidden = "<meta name='viewport' content='width=device-width,initial-scale=1'><title>Hidden frame player</title><iframe src='/hidden-frame.html' style='width:0;height:0;border:0'></iframe><ul class='episode-list'><li><a href='/first.mp4'>Episode 1</a></li><li><a href='/second.mp4'>Episode 2</a></li></ul>"
        // The real failure occurs after the document's initial probe has ended:
        // a delayed player inserts an invisible video and resolves its stream.
        let hiddenFrame = "<body><script>setTimeout(()=>{document.body.innerHTML=\"<video playsinline preload='auto' style='display:none' src='/first.mp4'></video>\";},2200);</script></body>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/configured.html": Data(html.utf8), "/hidden.html": Data(hidden.utf8), "/hidden-frame.html": Data(hiddenFrame.utf8), "/first.mp4": media, "/second.mp4": media])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        for (engine, path) in [("system", "configured.html"), ("soulo", "configured.html"), ("system", "hidden.html"), ("soulo", "hidden.html")] {
            let app = launch(player: engine, episodeDock: true, tools: true)
            try open(root.appendingPathComponent(path), app: app)
            let entry = app.buttons["browser.configured-video.play"]
            guard entry.waitForExistence(timeout: 10) else { XCTFail(app.debugDescription); app.terminate(); return }
            entry.tap()
            let fullscreen = app.otherElements["media.mkv.fullscreen.player"].firstMatch
            guard fullscreen.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); app.terminate(); return }
            let play = app.buttons["media.mkv.play"]
            for _ in 0..<4 {
                if !play.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap() }
                if play.exists && play.label == "Pause" { break }
                try await Task.sleep(for: .milliseconds(300))
            }
            XCTAssertEqual(play.label, "Pause")
            let episodes = app.buttons["media.file.episodes"].firstMatch
            XCTAssertTrue(episodes.exists, "Configured-source takeover must keep webpage episodes")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = engine + "-configured-player-takeover"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}

extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testNewWebTapCanReconsiderCancelledScriptNavigation() async throws {
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <button onclick="location.href=location.origin.replace('127.0.0.1','localhost')+'/result.html';">Open site</button>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/source.html": Data(html.utf8),
            "/result.html": Data("<h1>Confirmed result</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(confirmCrossDomain: true)
        try open(root.appendingPathComponent("source.html"), app: app)
        let button = app.webViews.buttons["Open site"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        let confirm = app.buttons["browser.domain-confirmation.continue"]
        let cancel = app.buttons["browser.domain-confirmation.cancel"]
        button.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
        XCTAssertFalse(server.receivedRequests.contains { $0.path == "/result.html" })
        button.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Confirmed result"].waitForExistence(timeout: 10))
    }

    @MainActor func testPopupConfirmationWaitsOnSourceAndPreservesWebKitPostAndOpener() async throws {
        let html = #"""
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Window form origin</title>
        <h1>Window form source</h1><p id="status">Waiting</p>
        <form id="submission" method="post" target="_blank" rel="opener"><input name="token" value="keep-body"></form>
        <button type="button" onclick="submission.submit()">Open form window</button>
        <script>
        document.title+=' '+location.port;
        submission.action=location.origin.replace('127.0.0.1','localhost')+'/window-result.html';
        addEventListener('message',event=>{if(event.data==='opener-ok')document.getElementById('status').textContent='Opener connection preserved';});
        </script>
        """#
        let result = "<h1>Window form destination</h1><script>if(opener)opener.postMessage('opener-ok','*');</script>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/window-form.html": Data(html.utf8), "/window-result.html": Data(result.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = launch(confirmCrossDomain: true)
        try open(root.appendingPathComponent("window-form.html"), app: app)
        let openButton = app.webViews.buttons["Open form window"].firstMatch
        XCTAssertTrue(openButton.waitForExistence(timeout: 10))
        let tabLabel = app.buttons["browser.tabs"].label
        openButton.tap()
        let confirm = app.buttons["browser.domain-confirmation.continue"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.buttons["browser.tabs"].label, tabLabel)
        XCTAssertTrue(app.webViews.staticTexts["Window form source"].firstMatch.exists)
        XCTAssertTrue(server.receivedRequests.filter { $0.path == "/window-result.html" }.isEmpty)
        let cancel = app.buttons["browser.domain-confirmation.cancel"]
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["browser.tabs"].label, tabLabel)
        XCTAssertTrue(server.receivedRequests.filter { $0.path == "/window-result.html" }.isEmpty)
        openButton.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(app.webViews.staticTexts["Window form destination"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        let request = try XCTUnwrap(server.receivedRequests.first { $0.path == "/window-result.html" })
        XCTAssertEqual(request.method, "POST")
        XCTAssertTrue(String(decoding: request.body, as: UTF8.self).contains("token=keep-body"))
        app.buttons["browser.tabs"].tap()
        selectFixtureTab(title: "Window form origin \(root.port ?? 0)", app: app)
        XCTAssertTrue(app.webViews.staticTexts["Window form source"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["Opener connection preserved"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)

    }
}


extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testLiveMoviePageOffersTakeoverAndPreservesEpisodes() async throws {
        guard let raw = ProcessInfo.processInfo.environment["SOULO_LIVE_VIDEO_URL"], let url = URL(string: raw) else {
            throw XCTSkip("Opt-in public movie player UI check")
        }
        let app = launch(player: "system", episodeDock: true, grouped: false, tools: true, downloadControls: true)
        defer { app.terminate() }
        try open(url, app: app)
        let native = app.buttons["browser.configured-video.play"].firstMatch
        let tools = app.webViews.buttons["Video tools"].firstMatch
        for _ in 0..<60 {
            if native.exists || tools.exists { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); before.name = "Live movie page takeover entry"; before.lifetime = .keepAlways; add(before)
        guard native.exists || tools.exists else { XCTFail(app.debugDescription); return }
        let start: ContinuousClock.Instant
        if native.exists { start = .now; native.tap() } else {
            tools.tap()
            let play = app.webViews.buttons["Fullscreen"].firstMatch
            if !play.waitForExistence(timeout: 2), tools.exists {
                // A website player can overlap the center of the floating tool.
                tools.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
            }
            guard play.waitForExistence(timeout: 5) else { XCTFail(app.debugDescription); return }
            start = .now
            play.tap()
        }
        let fullscreen = app.otherElements["media.mkv.fullscreen.player"].firstMatch
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["media.file.episodes"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let diagnostic = app.staticTexts["media.volume.diagnostics"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            diagnostic.exists && diagnostic.label.contains("frameReady=true")
        }, object: nil)], timeout: 30)
        print("Live movie takeover time to decoded frame: \(start.duration(to: .now))")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); after.name = "Live movie fullscreen with episodes"; after.lifetime = .keepAlways; add(after)
        if ProcessInfo.processInfo.environment["SOULO_LIVE_SWITCH_EPISODE"] == "1" {
            let picker = app.buttons["media.file.episodes"].firstMatch
            if !picker.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.47, dy: 0.25)).tap() }
            XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription)
            picker.tap()
            let drawer = app.otherElements["media.file.episodes.drawer"].firstMatch
            XCTAssertTrue(drawer.waitForExistence(timeout: 5), app.debugDescription)
            let prefix = "media.file.episode."
            let rows = drawer.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            let next = try XCTUnwrap(rows.allElementsBoundByIndex.first { !$0.isSelected && $0.isHittable })
            let episodeID = String(next.identifier.dropFirst(prefix.count))
            let switching = ContinuousClock.now
            next.tap()
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                diagnostic.exists && diagnostic.label.contains("frameReady=true") && diagnostic.label.hasSuffix("episode=" + episodeID)
            }, object: nil)], timeout: 35)
            XCTAssertTrue(fullscreen.exists)
            XCTAssertTrue(drawer.waitForNonExistence(timeout: 3))
            print("Live movie episode switch time to decoded frame: \(switching.duration(to: .now))")
        }
    }
}

extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testFullscreenPauseButtonStopsTheDecoderWithoutWaitingForHoldSpeedInBothModes() async throws {
        let media = try await longVideoFixtureData()
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1"><title>Pause response</title>
        <video src="/clip.mp4" controls playsinline preload="metadata" style="width:100%;height:300px"></video>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/pause.html": Data(html.utf8), "/clip.mp4": media])
        let root = try await server.start(); server.releaseDownloads()
        defer { server.stop(); XCUIDevice.shared.orientation = .portrait }
        for engine in ["system", "soulo"] {
            let app = launch(player: engine, grouped: false)
            defer { app.terminate() }
            try open(root.appendingPathComponent("pause.html"), app: app)
            let tools = app.webViews.buttons["Video tools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 15)); tools.tap()
            let fullscreen = app.webViews.buttons["Fullscreen"].firstMatch
            XCTAssertTrue(fullscreen.waitForExistence(timeout: 5)); fullscreen.tap()
            let player = app.otherElements["media.mkv.fullscreen.player"].firstMatch
            guard player.waitForExistence(timeout: 15) else { XCTFail(app.debugDescription); return }
            let play = app.buttons["media.mkv.play"]
            let diagnostic = app.staticTexts["media.volume.diagnostics"]
            func clock() throws -> Double {
                let value = diagnostic.label.components(separatedBy: "clock=").last?.components(separatedBy: " ").first
                return try XCTUnwrap(value.flatMap(Double.init), diagnostic.label)
            }
            let screen = app.frame
            let backdrop = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screen.midX, dy: screen.height * 0.25))
            let center = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: screen.midX, dy: screen.midY))
            let doubleTapReady = NSPredicate { _, _ in ((try? clock()) ?? 0) > 0.3 }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: doubleTapReady, object: nil)], timeout: 10)
            backdrop.doubleTap()
            XCTAssertEqual(play.label, "Play", "A double tap pauses exactly once")
            let doubleTapStopped = try clock()
            try await Task.sleep(for: .milliseconds(600))
            XCTAssertEqual(try clock(), doubleTapStopped, accuracy: 0.15)
            backdrop.doubleTap()
            let resumed = NSPredicate { _, _ in ((try? clock()) ?? 0) > doubleTapStopped + 0.3 }
            await fulfillment(of: [XCTNSPredicateExpectation(predicate: resumed, object: nil)], timeout: 5)
            for _ in 0..<3 {
                // Readiness and AX polling can outlast the normal three-second
                // auto-hide interval. Wait first, then reveal and press promptly.
                let ready = NSPredicate { _, _ in ((try? clock()) ?? 0) > 0.3 }
                await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 10)
                guard ((try? clock()) ?? 0) > 0.3 else { XCTFail(diagnostic.label); return }
                if play.exists {
                    backdrop.tap()
                    guard play.waitForNonExistence(timeout: 2) else { XCTFail(app.debugDescription); return }
                }
                backdrop.tap()
                guard play.waitForExistence(timeout: 2) else { XCTFail(app.debugDescription); return }
                center.tap()
                XCTAssertEqual(play.label, "Play", "The central Pause button must receive the first tap")
                let stopped = try clock()
                let delayText = diagnostic.label.components(separatedBy: "pauseDelay=").last?.components(separatedBy: " ").first
                let delay = try XCTUnwrap(delayText.flatMap(Double.init), diagnostic.label)
                XCTAssertGreaterThanOrEqual(delay, 0, "Require a real UIKit control touch timestamp")
                XCTAssertLessThan(delay, 0.4, "Measure actual touch-to-action latency, excluding XCTest event delivery and stale AX snapshots: \(engine)")
                print("PAUSE INPUT QA \(engine): \(delay) seconds")
                try await Task.sleep(for: .milliseconds(650))
                XCTAssertEqual(try clock(), stopped, accuracy: 0.15, "Verify the actual decoder, not the displayed position")
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = engine + "-paused-on-first-tap"; shot.lifetime = .keepAlways; add(shot)
                center.tap()
            }
            XCTAssertFalse(app.buttons["media.mkv.fullscreen.exit"].exists)
            if !app.buttons["media.fullscreen.rotate"].exists { backdrop.tap() }
            app.buttons["media.fullscreen.rotate"].tap()
            try requireWebFullscreen(app)
            let portraitBackdrop = app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4))
            portraitBackdrop.doubleTap()
            if !play.exists { portraitBackdrop.tap() }
            XCTAssertEqual(play.label, "Play", "Portrait fullscreen double-tap must not trigger a second recognizer")
            portraitBackdrop.doubleTap()
            if !play.exists { portraitBackdrop.tap() }
            XCTAssertEqual(play.label, "Pause")
        }
    }
}


extension WebEpisodeAndAdNavigationUITests {
    @MainActor func testAuxiliaryPlayAnchorsToPlayerBoxAndOpensBothPlayers() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <title>Anchored auxiliary Play</title><style>body{margin:0}header{height:110px}#player{margin:0 20px;width:calc(100% - 40px);height:250px;background:#222;color:white}</style>
        <script>var player_aaaa={url:location.origin+'/video.mp4'};</script>
        <header>Page header must remain clear</header><div id='player' role='region' aria-label='Video box'>Video area</div><div style='height:1000px'>Other content</div>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/anchored.html": Data(html.utf8), "/video.mp4": try Data(contentsOf: fixture)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        for engine in ["system", "soulo"] {
            let app = launch(player: engine, tools: true); defer { app.terminate() }
            try open(root.appendingPathComponent("anchored.html"), app: app)
            let entry = app.webViews.buttons["Play"].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 12), app.debugDescription)
            XCTAssertFalse(app.buttons["browser.configured-video.play"].exists, "The page-corner fallback must yield to the video-box control")
            XCTAssertFalse(app.webViews.buttons["Video tools"].exists, "Normal video tools and auxiliary Play must be mutually exclusive")
            let box = app.webViews.otherElements["Video box"].firstMatch
            if box.exists { XCTAssertTrue(box.frame.contains(entry.frame), "Play must stay inside the video box") }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = engine + "-auxiliary-play-on-video-box"; shot.lifetime = .keepAlways; add(shot)
            entry.tap()
            let full = app.otherElements["media.mkv.fullscreen.player"].firstMatch
            XCTAssertTrue(full.waitForExistence(timeout: 15), app.debugDescription)
            app.terminate()
        }
    }

    @MainActor func testStalledPlaybackWarningStaysOutsideTransportAndRecoversInBothPlayers() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><title>Stalled player</title><script>var player_aaaa={url:location.origin+'/held.mp4'};</script><p>Stalled player fixture</p>"
        defer { XCUIDevice.shared.orientation = .portrait }
        for engine in ["system", "soulo"] {
            let server = try DownloadPlaybackHTTPFixture(files: ["/stalled.html": Data(html.utf8), "/held.mp4": try Data(contentsOf: fixture)], heldPaths: ["/held.mp4"])
            let root = try await server.start(); defer { server.stop() }
            let app = launch(player: engine, tools: true); defer { app.terminate() }
            try open(root.appendingPathComponent("stalled.html"), app: app)
            let entry = app.buttons["browser.configured-video.play"]
            XCTAssertTrue(entry.waitForExistence(timeout: 12)); entry.tap()
            let prefix = "media.mkv"
            let status = app.staticTexts[prefix + ".status"]
            XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
            let play = app.buttons[prefix + ".play"]
            XCTAssertTrue(play.exists)
            XCTAssertFalse(status.frame.intersects(play.frame), "The warning must have reserved space outside Play/loading")
            XCTAssertGreaterThan(status.frame.height, 10)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = engine + "-startup-warning-outside-play-and-loading"; screenshot.lifetime = .keepAlways; add(screenshot)
            server.releaseDownloads()
            XCTAssertTrue(status.waitForNonExistence(timeout: 20), "A slow link must recover after the first frame")
            app.terminate()
        }
    }
}
