import XCTest
import UIKit

@MainActor
final class DeviceIntegrationUITests: XCTestCase {
    func testBookmarkAndNewTabDragShareTheSavedOrder() throws {
        guard SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Isolated library acceptance") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO",
            "-icloud_bookmarks_sync_enabled", "NO", "-review.requestedOnce", "YES", "-home_toolbar_actions", "(bookmarks,newTab)",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"; app.launchEnvironment["SOULO_ACCEPTANCE_BOOKMARKS"] = "1"
        app.launch(); defer { app.terminate() }
        let library = app.buttons["home.toolbar.0"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        func row(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "favorites.bookmark.", "Quicklink QA " + name)).firstMatch
        }
        XCTAssertTrue(row("One").waitForExistence(timeout: 5)); XCTAssertTrue(row("Three").exists)
        row("One").press(forDuration: 0.6, thenDragTo: row("Three"), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertGreaterThan(row("One").frame.midY, row("Two").frame.midY)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["home.toolbar.1"].tap()
        func quick(_ name: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "new-tab.quick-link.", "Quicklink QA " + name)).firstMatch
        }
        XCTAssertTrue(quick("One").waitForExistence(timeout: 5), app.debugDescription); XCTAssertTrue(quick("Two").exists)
        XCTAssertGreaterThan(quick("One").frame.midX, quick("Two").frame.midX)
        quick("One").press(forDuration: 1, thenDragTo: quick("Two"), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertLessThan(quick("One").frame.midX, quick("Two").frame.midX)
        quick("One").press(forDuration: 1)
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["Add to Quick Links"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "new-tab-drag-order-and-context-menu"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBookmarkHeartsRenameFilterAndNewTabQuickLinks() throws {
        guard #available(iOS 18.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Isolated bookmark UI") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","en-US","-appearance","light","-wallpaper_source","gradient","-is_incognito","NO","-icloud_sync_enabled","NO","-review.requestedOnce","YES","-home_toolbar_actions","(bookmarks,newTab)","-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"; app.launchEnvironment["SOULO_ACCEPTANCE_BOOKMARKS"] = "1"
        app.launch(); defer { app.terminate() }
        let library = app.buttons["home.toolbar.0"]
        XCTAssertTrue(library.waitForExistence(timeout: 10)); library.tap()
        let filter = app.buttons["favorites.heart-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); filter.tap()
        XCTAssertTrue(app.otherElements["favorites.heart-empty"].waitForExistence(timeout: 5) || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Press and hold a bookmark")).firstMatch.exists)
        filter.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "favorites.bookmark.", "Quicklink QA One")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.press(forDuration: 1)
        app.buttons["Add to Quick Links"].tap()
        filter.tap(); XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "favorites.bookmark.", "Quicklink QA Two")).firstMatch.exists)
        row.press(forDuration: 1); app.buttons["Rename"].tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Quicklink QA One".count) + "My quick page")
        app.alerts.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "favorites.bookmark.", "My quick page")).firstMatch.waitForExistence(timeout: 5))
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "bookmarks-heart-filter-renamed"; image.lifetime = .keepAlways; add(image)
        app.navigationBars.buttons.firstMatch.tap()
        let newTab = app.buttons["home.toolbar.1"]
        XCTAssertTrue(newTab.waitForExistence(timeout: 5)); newTab.tap()
        let quick = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "new-tab.quick-link.")).allElementsBoundByIndex
        XCTAssertEqual(quick.count, 1); XCTAssertEqual(quick.first?.label, "My quick page")
        let field = app.textFields["search.query"], area = app.scrollViews["new-tab.search.area"]
        XCTAssertTrue(field.exists); XCTAssertTrue(area.exists)
        let box = app.otherElements["new-tab.search.field"]
        XCTAssertTrue(box.exists)
        XCTAssertEqual(field.frame.midY, area.frame.midY - box.frame.height * 0.65, accuracy: 3)
        let page = XCTAttachment(screenshot: app.screenshot()); page.name = "new-tab-centered-heart-quick-link"; page.lifetime = .keepAlways; add(page)
    }

    func testConfiguredNewTabToolbarCreatesAndSelectsANewTab() async throws {
        guard #available(iOS 18.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Isolated toolbar acceptance") }
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: ["/toolbar.html": Data("<html><title>Toolbar source</title><body>Original toolbar page</body></html>".utf8)], responseHeaders: ["/toolbar.html": ["Content-Type":"text/html"]])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","en-US","-appearance","light","-wallpaper_source","gradient","-is_incognito","NO","-icloud_sync_enabled","NO","-review.requestedOnce","YES","-browser_toolbar_actions","(newTab,back,tabs,more)","-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO","-privacy_https_upgrade_enabled","NO"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(string: "soulo://open")!
        route.queryItems = [URLQueryItem(name:"url", value:base.appendingPathComponent("toolbar.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Original toolbar page"].waitForExistence(timeout: 10))
        let badge = app.buttons["browser.tabs"]
        XCTAssertTrue(badge.waitForExistence(timeout: 5))
        let count = try XCTUnwrap(Int(badge.label.split(separator: " ").first.map(String.init) ?? ""))
        let newTab = app.buttons["New Tab"].firstMatch
        XCTAssertTrue(newTab.isEnabled); newTab.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in badge.label.hasPrefix("\(count + 1) ") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertFalse(app.webViews.staticTexts["Original toolbar page"].isHittable, "The new empty tab must be selected")
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "custom-toolbar-new-tab-selected"; image.lifetime = .keepAlways; add(image)
    }

    func testOriginalFastStreamProgressBarAcceptsARealTouchDrag() async throws {
        try await exerciseOriginalFastStream(fullscreen: true)
    }

    func testOriginalFastStreamStandaloneDownloadShowsSavedFile() async throws {
        try await exerciseOriginalFastStream(fullscreen: false)
    }

    private func exerciseOriginalFastStream(fullscreen: Bool) async throws {
        guard #available(iOS 18.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Isolated native extension app") }
        continueAfterFailure = false
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let server = try DownloadPlaybackHTTPFixture(files: ["/touch.mp4": Data(contentsOf: media)])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient", "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-is_incognito", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_PLAYER"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_PLAYER_MEDIA"] = base.appendingPathComponent("touch.mp4").absoluteString
        app.launch(); defer { app.terminate() }
        let probe = app.staticTexts["qa.acceptance"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        func state() -> [String: Any] {
            guard let text = probe.value as? String, let range = text.range(of: ";extension="),
                  let data = String(text[range.upperBound...]).data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return result
        }
        for _ in 0..<200 {
            if (state()["ready"] as? Int ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        var facts = state()
        XCTAssertGreaterThanOrEqual(facts["ready"] as? Int ?? 0, 2, probe.value as? String ?? app.debugDescription)
        let bar = try XCTUnwrap(facts["bar"] as? [String: Double])
        let x = (facts["originX"] as? Double ?? 0) + (bar["x"] ?? 0)
        let y = (facts["originY"] as? Double ?? 0) + (bar["y"] ?? 0) + (bar["height"] ?? 0)/2
        let width = try XCTUnwrap(bar["width"])
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x + width*0.12, dy: y))
        let end = origin.withOffset(CGVector(dx: x + width*0.76, dy: y))
        start.press(forDuration: 0.15, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        try await Task.sleep(for: .milliseconds(350))
        facts = state()
        let time = facts["time"] as? Double ?? 0, duration = facts["duration"] as? Double ?? 0
        XCTAssertGreaterThan(time, duration*0.65, "The original mouse-only control must follow a real finger, not just a click: \(facts)")
        XCTAssertLessThan(time, duration+0.1)
        XCTAssertEqual(facts["error"] as? String, "")
        let report = XCTAttachment(string: String(describing: facts)); report.name = "original-faststream-real-touch-drag"; report.lifetime = .keepAlways; add(report)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "original-faststream-after-touch-drag"; shot.lifetime = .keepAlways; add(shot)
        func tapControl(_ key: String) throws {
            if state()["controlsVisible"] as? Bool == false {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                for _ in 0..<20 {
                    if state()["controlsVisible"] as? Bool == true { break }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
            // WebKit's fullscreen window has its own safe-area transform;
            // accessibility reports the actual onscreen control bounds.
            let labels = key == "full" ? ["Toggle fullscreen", "切换全屏", "切換全螢幕"] : ["Save video", "保存视频", "儲存影片"]
            let native = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", labels[0], labels[1], labels[2])).firstMatch
            if native.exists, native.isHittable { native.tap(); return }
            let current = state(), rect = try XCTUnwrap(current[key] as? [String: Double])
            let dx = (current["originX"] as? Double ?? 0)+(rect["x"] ?? 0)+(rect["width"] ?? 0)/2
            let dy = (current["originY"] as? Double ?? 0)+(rect["y"] ?? 0)+(rect["height"] ?? 0)/2
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: dx, dy: dy)).tap()
        }
        if fullscreen {
        try tapControl("full")
        for _ in 0..<50 {
            if state()["fullscreen"] as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(state()["fullscreen"] as? Bool, true, String(describing: state()))
        try tapControl("full")
        for _ in 0..<50 {
            if state()["fullscreen"] as? Bool == false { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(state()["fullscreen"] as? Bool, false)
        XCTAssertEqual(state()["error"] as? String, "")
        guard !app.alerts.firstMatch.exists else { XCTFail(app.debugDescription); return }
        let fullscreenReport = XCTAttachment(string: String(describing: state())); fullscreenReport.name = "original-faststream-fullscreen-exit"; fullscreenReport.lifetime = .keepAlways; add(fullscreenReport)
        return
        }
        try tapControl("download")
        let filename = app.webViews.textFields.firstMatch
        guard filename.waitForExistence(timeout: 8) else { XCTFail(app.debugDescription); return }
        let name = try XCTUnwrap(filename.value as? String)
        let confirm = app.webViews.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "确定", "確定", "好"])).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        for control in [filename, confirm] {
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.frame.minX, "Extension dialogs must fit a narrow viewport")
            XCTAssertLessThanOrEqual(control.frame.maxX, app.frame.maxX)
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.frame.minY)
            XCTAssertLessThanOrEqual(control.frame.maxY, app.frame.maxY)
        }
        let dialog = XCTAttachment(screenshot: app.screenshot()); dialog.name = "faststream-filename-dialog-fits-viewport"; dialog.lifetime = .keepAlways; add(dialog)
        confirm.tap()
        let downloads = app.buttons["downloads.completion-list"]
        guard downloads.waitForExistence(timeout: 30) else {
            let detail = XCTAttachment(string: String(describing: state())); detail.name = "faststream-download-failure"; detail.lifetime = .keepAlways; add(detail)
            XCTFail("A completed extension save must expose the shared Downloads entry: \(state())"); return
        }
        downloads.tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "downloads.open.", name)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)
        let fileShot = XCTAttachment(screenshot: app.screenshot()); fileShot.name = "faststream-saved-file-in-downloads"; fileShot.lifetime = .keepAlways; add(fileShot)
    }

    func testStandaloneVideoCanExitNativeFullscreenWithoutAPlaybackError() async throws {
        guard #available(iOS 18.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Isolated media document") }
        continueAfterFailure = false
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let server = try DownloadPlaybackHTTPFixture(files: ["/direct.mp4": Data(contentsOf: media)], responseHeaders: ["/direct.mp4": ["Content-Type":"video/mp4"]])
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","en-US","-appearance","light","-wallpaper_source","gradient","-is_incognito","NO","-icloud_sync_enabled","NO","-review.requestedOnce","YES","-privacy_https_upgrade_enabled","NO"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(string: "soulo://open")!
        route.queryItems = [URLQueryItem(name:"url", value:base.appendingPathComponent("direct.mp4").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        let play = app.buttons.matching(NSPredicate(format: "label IN %@", ["Play", "播放"])).firstMatch
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成", "Close", "关闭"])).firstMatch
        if !close.exists, play.waitForExistence(timeout: 5) { play.tap() }
        // WebKit may initially play inline on iPad. Use its actual fullscreen
        // control when present rather than synthesizing fullscreen events.
        let fullscreen = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@", "Enter Full Screen", "进入全屏")).firstMatch
        if !close.exists, fullscreen.exists, fullscreen.isHittable { fullscreen.tap() }
        guard close.waitForExistence(timeout: 8) else {
            let details = XCTAttachment(string: app.debugDescription); details.name = "native-direct-video-controls"; details.lifetime = .keepAlways; add(details)
            XCTFail("The native video fullscreen must be exercised"); return
        }
        close.tap()
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Exiting a healthy WebKit media document must not present a failed Soulo-player handoff")
        XCTAssertTrue(app.webViews.firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "direct-video-native-fullscreen-exited"; image.lifetime = .keepAlways; add(image)
    }

    private func launch(export: Bool = false, speech: Bool = false) throws -> XCUIApplication {
        guard SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else { throw XCTSkip("Requires the isolated acceptance app") }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-is_incognito", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        if speech { app.launchArguments += ["-AppleLanguages", "(zh-Hans)"] }
        if export { app.launchEnvironment["SOULO_ACCEPTANCE_EXPORT"] = "1" }
        app.launch()
        XCTAssertTrue(probe(app).waitForExistence(timeout: 10))
        return app
    }

    private func probe(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "qa.acceptance").firstMatch
    }
    private func value(_ app: XCUIApplication) -> String { probe(app).value as? String ?? "" }
    private func wait(_ app: XCUIApplication, for text: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in value(app).contains(text) }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testNativeContinuedTaskRunsInBackgroundAndFinishes() throws {
        let app = try launch(export: true); defer { app.terminate() }
        XCTAssertTrue(wait(app, for: "native=1", timeout: 10), value(app))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        app.activate()
        XCTAssertTrue(wait(app, for: "export=completed", timeout: 25), value(app))
        XCTAssertTrue(value(app).contains("background=1"), value(app))
        let progress = value(app).split(separator: ";").first { $0.hasPrefix("progress=") }.flatMap { Double($0.dropFirst(9)) } ?? 0
        XCTAssertGreaterThan(progress, 0)
        let attachment = XCTAttachment(string: value(app)); attachment.name = "native-background-task"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRealAnalyzerMicrophoneStartsAndCancels() throws {
        let app = try launch(speech: true); defer { app.terminate() }
        let monitor = addUIInterruptionMonitor(withDescription: "QA speech permissions") { alert in
            let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
            guard text.contains("soulo"), ["speech", "microphone", "语音", "麦克风"].contains(where: text.contains) else { return false }
            for name in ["允许", "Allow", "OK", "好"] where alert.buttons[name].exists { alert.buttons[name].tap(); return true }
            return false
        }
        defer { removeUIInterruptionMonitor(monitor) }
        let voice = app.buttons["Record"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5)); voice.tap()
        let record = app.buttons["voice.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        if !value(app).contains("analyzerStarted=1") { record.tap() }
        for _ in 0..<4 {
            // Permission alerts may be hosted outside SpringBoard's AX tree.
            // A real app interaction lets XCTest invoke the interruption monitor.
            app.tap()
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            if alert.exists {
                let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
                if text.contains("soulo") {
                    let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["允许", "Allow", "OK", "好"])).firstMatch
                    if allow.exists { allow.tap() }
                }
            }
            if value(app).contains("analyzerStarted=1") { break }
            Thread.sleep(forTimeInterval: 1)
        }
        // The production silence timer can stop a silent microphone after
        // 1.2s, before an automation round trip. Latch only an actual start.
        XCTAssertTrue(wait(app, for: "analyzerStarted=1", timeout: 20), value(app))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(wait(app, for: "recording=0;analyzer=0", timeout: 5), value(app))
        let attachment = XCTAttachment(string: value(app)); attachment.name = "physical-microphone-cancelled"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRealSystemAccessibilityPreferencesReachTheApp() throws {
        let app = try launch(); defer { app.terminate() }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let cases: [(String, [String], [String])] = [
            ("transparency", ["显示与文字大小", "Display & Text Size"], ["降低透明度", "Reduce Transparency"]),
            ("contrast", ["显示与文字大小", "Display & Text Size"], ["增强对比度", "Increase Contrast"]),
            ("motion", ["动态效果", "Motion"], ["减弱动态效果", "Reduce Motion"])
        ]
        for (key, section, labels) in cases {
            let initial = value(app).contains("\(key)=1")
            settings.launch()
            let accessibility = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["辅助功能", "Accessibility"])).firstMatch
            XCTAssertTrue(accessibility.waitForExistence(timeout: 10), "Settings Accessibility entry")
            if !accessibility.isHittable { settings.swipeUp() }
            accessibility.tap()
            let detail = settings.staticTexts.matching(NSPredicate(format: "label IN %@", section)).firstMatch
            XCTAssertTrue(detail.waitForExistence(timeout: 5)); detail.tap()
            let toggle = settings.switches.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), settings.debugDescription)
            XCTAssertEqual(toggle.value as? String, initial ? "1" : "0")
            addTeardownBlock {
                settings.activate()
                if toggle.exists, (toggle.value as? String == "1") != initial {
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
                }
            }
            // Settings exposes the full row as the switch's accessibility
            // frame; tap the control at its trailing end, not the label.
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            XCTAssertEqual(toggle.value as? String, initial ? "0" : "1", "System switch must actually change")
            app.activate()
            XCTAssertTrue(wait(app, for: "\(key)=\(initial ? 0 : 1)"), value(app))
            let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "real-system-\(key)-toggled"; screenshot.lifetime = .keepAlways; add(screenshot)
            settings.activate()
            if (toggle.value as? String == "1") != initial {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            app.activate()
            XCTAssertTrue(wait(app, for: "\(key)=\(initial ? 1 : 0)"), "Restore original system preference")
        }
    }
}
