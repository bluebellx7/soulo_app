import XCTest
import UIKit

@MainActor
final class DeviceIntegrationUITests: XCTestCase {
    func testPageBackgroundExtensionDoesNotRecolorAppPanels() async throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven automation requires iOS 16.4") }
        continueAfterFailure = false
        func html(_ dark: Bool) -> Data {
            let background = dark ? "#101010" : "#ffffff"
            let foreground = dark ? "white" : "black"
            return Data("<html style='background:\(background);color:\(foreground)'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='theme-color' content='\(background)'><title>Panel appearance fixture</title><body style='margin:0;min-height:200vh;background:\(background)'><h1>Panel appearance fixture</h1></body></html>".utf8)
        }
        let server = try DownloadPlaybackHTTPFixture(files: ["/dark": html(true), "/light": html(false)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        defer { app.terminate() }

        let linearSRGB = (0...255).map { channel in
            let value = Double(channel) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        func luminances(in rect: CGRect, screenshot: XCUIScreenshot) throws -> [Double] {
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let scale = CGFloat(image.width) / app.frame.width
            let area = CGRect(x: (rect.minX - app.frame.minX) * scale, y: (rect.minY - app.frame.minY) * scale,
                width: rect.width * scale, height: rect.height * scale).integral
            let crop = try XCTUnwrap(image.cropping(to: area))
            let count = crop.width * crop.height
            var rgba = [UInt8](repeating: 0, count: count * 4)
            try rgba.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                    bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            return stride(from: 0, to: rgba.count, by: 4).map { index in
                0.2126 * linearSRGB[Int(rgba[index])]
                    + 0.7152 * linearSRGB[Int(rgba[index + 1])]
                    + 0.0722 * linearSRGB[Int(rgba[index + 2])]
            }
        }
        func checkText(_ label: XCUIElement, expectedDark: Bool, name: String) throws {
            guard label.waitForExistence(timeout: 5) else {
                XCTFail("Missing label for \(name)")
                return
            }
            let shot = XCUIScreen.main.screenshot()
            let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            let values = try luminances(in: label.frame, screenshot: shot).sorted()
            // Most of the label rect is its background. Sample solid glyphs
            // from the corresponding tail and allow translucent system chrome.
            let background = values[values.count / 2]
            let ink = values[Int(Double(values.count - 1) * (expectedDark ? 0.96 : 0.04))]
            let contrast = expectedDark ? (ink + 0.05) / (background + 0.05) : (background + 0.05) / (ink + 0.05)
            print("PANEL_CONTRAST \(name) ratio=\(contrast)")
            XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name) must use legible text in the app appearance")
        }

        let systemIsDark = ProcessInfo.processInfo.environment["SOULO_APPEARANCE_EXPECT_DARK"] == "1"
        for mode in ["light", "dark", "system"] {
            let dark = mode == "dark" || (mode == "system" && systemIsDark)
            app.launchArguments = ["-app_language", "en-US", "-appearance", mode, "-wallpaper_source", "gradient",
                "-is_incognito", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
                "-restore_last_page_on_launch", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
                "-ad_block_enabled", "NO", "-privacy_https_upgrade_enabled", "NO", "-extend_page_background", "YES",
                "-web_force_dark_pages", "NO", "-browser_toolbar_leading_action", "siteInformation",
                "-browser_more_menu_actions", "(home,extensions,platforms)"]
            app.launch()
            app.open(root.appendingPathComponent(dark ? "light" : "dark"))
            XCTAssertTrue(app.webViews.staticTexts["Panel appearance fixture"].firstMatch.waitForExistence(timeout: 15))
            try await Task.sleep(for: .seconds(1))
            app.buttons["browser.more"].firstMatch.tap()
            let tools = app.buttons["browser.moreMenu.pageTools"].firstMatch
            XCTAssertTrue(tools.waitForExistence(timeout: 5))
            try checkText(tools.staticTexts.firstMatch, expectedDark: dark, name: "panels-\(mode)-more")
            let extensions = app.buttons["browser.moreMenu.extensions"].firstMatch
            extensions.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.segmentedControls["extensions.section"].waitForExistence(timeout: 5))
            try checkText(app.staticTexts["UserScript compatibility"].firstMatch, expectedDark: dark, name: "panels-\(mode)-extensions")
            app.navigationBars.buttons["Done"].firstMatch.tap()
            app.buttons["browser.siteInformation"].firstMatch.tap()
            let identity = app.buttons["site.user-agent"].firstMatch
            XCTAssertTrue(identity.waitForExistence(timeout: 5))
            try checkText(identity.staticTexts.firstMatch, expectedDark: dark, name: "panels-\(mode)-site-information")
            app.terminate()
        }
    }

    func testSettingsAppearanceRemainsIndependentOfDarkPageBackgroundExtension() async throws {
        continueAfterFailure = false
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven automation requires iOS 16.4") }
        let html = "<html style='background:#101010;color:white;color-scheme:dark'><meta name='viewport' content='width=device-width,initial-scale=1'><meta name='theme-color' content='#101010'><title>Dark appearance fixture</title><body style='margin:0;min-height:200vh;background:#101010;color:white'><h1>Dark appearance fixture</h1></body></html>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/appearance-dark": Data(html.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-is_incognito", "YES",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-ad_block_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-restore_last_page_on_launch", "NO", "-extend_page_background", "YES", "-web_force_dark_pages", "NO"]
        app.launch(); defer { app.terminate() }
        func select(_ mode: String) {
            let choice = app.buttons["settings.appearance." + mode.lowercased()].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
            XCTAssertTrue(choice.isSelected)
        }
        func closeSettings() {
            let done = app.navigationBars.buttons["Done"].firstMatch
            if !done.exists || !done.isHittable { app.navigationBars.buttons.firstMatch.tap() }
            XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        }
        func brightness() -> Double {
            guard let image = XCUIScreen.main.screenshot().image.cgImage,
                  let crop = image.cropping(to: CGRect(x: CGFloat(image.width) * 0.025,
                    y: CGFloat(image.height) * 0.55, width: 6, height: 6)) else { return -1 }
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                context?.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return (Double(rgba[0]) + Double(rgba[1]) + Double(rgba[2])) / (3 * 255)
        }
        func record(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name; shot.lifetime = .keepAlways; add(shot)
            print("APPEARANCE_BACKGROUND \(name) brightness=\(brightness())")
        }
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        select("Light"); record("appearance-home-light-control")
        XCTAssertGreaterThan(brightness(), 0.6, "The Home entry must honor Light")
        closeSettings()
        app.open(root.appendingPathComponent("appearance-dark"))
        XCTAssertTrue(app.webViews.staticTexts["Dark appearance fixture"].firstMatch.waitForExistence(timeout: 15))
        try await Task.sleep(for: .seconds(1))
        record("appearance-dark-page-chrome")
        app.buttons["browser.more"].tap(); app.buttons["Settings"].firstMatch.tap()
        for mode in ["Light", "Dark", "System"] {
            select(mode); record("appearance-from-dark-page-" + mode.lowercased())
            let expectsDark = mode == "Dark" || (mode == "System"
                && ProcessInfo.processInfo.environment["SOULO_APPEARANCE_EXPECT_DARK"] == "1")
            if expectsDark { XCTAssertLessThan(brightness(), 0.4, "\(mode) must use the dark app/system theme") }
            else { XCTAssertGreaterThan(brightness(), 0.6, "\(mode) must honor the light app/system appearance, independent of the webpage") }
        }
        let toolbar = app.buttons["settings.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5)); toolbar.tap()
        let sections = app.segmentedControls["browser-toolbar.section"]
        XCTAssertTrue(sections.waitForExistence(timeout: 5))
        XCTAssertTrue(sections.buttons.element(boundBy: 1).isSelected, "Browser settings must start on the Browsing toolbar")
        closeSettings()
        XCTAssertTrue(app.webViews.staticTexts["Dark appearance fixture"].firstMatch.waitForExistence(timeout: 5))
        record("appearance-dark-page-after-settings")
        app.buttons["Home Screen"].firstMatch.tap()
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        record("appearance-home-after-browser")
        if ProcessInfo.processInfo.environment["SOULO_APPEARANCE_EXPECT_DARK"] == "1" { XCTAssertLessThan(brightness(), 0.4) }
        else { XCTAssertGreaterThan(brightness(), 0.6) }
    }

    func testRestartOptionRestoresOnlyWhenBrowserWasVisible() async throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven automation requires iOS 16.4") }
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/restart-start": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Restart start</title><a href='/restart-article'>Read saved article</a>".utf8),
            "/restart-article": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Saved restart article</title><h1>Saved restart article</h1>".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        let arguments = ["-app_language", "en-US", "-is_incognito", "NO", "-icloud_sync_enabled", "NO",
            "-review.requestedOnce", "YES", "-wallpaper_source", "gradient", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-ad_block_enabled", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launchArguments = arguments + ["-restore_last_page_on_launch", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("restart-start"))
        let next = app.webViews.links["Read saved article"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10)); next.tap()
        let article = app.webViews.staticTexts["Saved restart article"].firstMatch
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        let count = app.buttons["browser.tabs"].label
        XCUIDevice.shared.press(.home); app.terminate()
        app.launchArguments = arguments + ["-restore_last_page_on_launch", "YES"]
        app.launch()
        XCTAssertTrue(article.waitForExistence(timeout: 15), "Restart must keep the saved article rather than load the original start URL")
        XCTAssertEqual(app.buttons["browser.tabs"].label, count, "Restart must reuse the saved tab")

        let home = app.buttons["home.menu"]
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); app.terminate(); app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "Returning to Home must prevent restoring a tab behind it")
        XCTAssertFalse(article.waitForExistence(timeout: 2))

        app.open(root.appendingPathComponent("restart-article"))
        XCTAssertTrue(article.waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home); app.terminate()
        app.launchArguments = arguments + ["-restore_last_page_on_launch", "NO"]
        app.launch()
        XCTAssertTrue(home.waitForExistence(timeout: 10), "The disabled option must open Home")
        XCTAssertFalse(article.exists)
    }

    func testHomeRecentSearchSupportsTapAndLongPressDelete() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let query = "recent-tap-qa-\(UUID().uuidString.prefix(6))"
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-show_recent_searches_on_home", "YES",
            "-show_bookmarks_on_home", "NO", "-show_group_picker_on_home", "NO", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let home = app.buttons["Home Screen"].firstMatch
        if home.waitForExistence(timeout: 2) { home.tap() }
        let field = app.textFields["search.query"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap(); field.typeText(query + "\n")
        XCTAssertTrue(home.waitForExistence(timeout: 10))
        home.tap()
        let recent = app.buttons["Recent search, \(query)"].firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        print("Recent search touch target: \(recent.frame)")
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "recent-search-before-physical-tap"; before.lifetime = .keepAlways; add(before)
        recent.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        after.name = "recent-search-after-physical-tap"; after.lifetime = .keepAlways; add(after)
        XCTAssertTrue(home.waitForExistence(timeout: 5), "A physical short tap on a recent search must open results")
        home.tap()
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.press(forDuration: 1)
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "Long press must reveal deletion")
        XCTAssertFalse(home.exists, "Long press must not submit the recent search")
        delete.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5), "The context menu must remove the recent search")
    }

    func testTopTabCloseButtonsKeepTheSurvivingPageResponsive() async throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven UI automation requires iOS 16.4") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let pages = Dictionary(uniqueKeysWithValues: (0..<7).map { index in
            ("/close-\(index)", Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Close page \(index)</title><h1>Close page \(index)</h1><a target='_blank' href='/close-\(index + 1)'>Open next tab</a><button onclick='this.textContent=\"Still responsive\"'>Check page</button>".utf8))
        })
        let server = try DownloadPlaybackHTTPFixture(files: pages)
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-is_incognito", "YES",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-show_top_tab_bar", "YES",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-wallpaper_source", "gradient",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let tabs = app.buttons["browser.tabs"]
        app.open(root.appendingPathComponent("close-0"))
        for index in 0..<7 {
            XCTAssertTrue(app.webViews.staticTexts["Close page \(index)"].firstMatch.waitForExistence(timeout: 10))
            if index < 6 { app.webViews.links["Open next tab"].firstMatch.tap() }
        }
        XCTAssertEqual(tabs.label, "7 Tabs", "The fixture must create separate tabs before testing their close buttons")
        for remaining in stride(from: 7, through: 2, by: -1) {
            let chip = app.buttons["Close page \(remaining - 1), tab \(remaining) of \(remaining)"].firstMatch
            XCTAssertTrue(chip.waitForExistence(timeout: 5), app.debugDescription)
            chip.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -14, dy: 0)).tap()
            let count = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "\(remaining - 1) Tabs"), object: tabs)
            await fulfillment(of: [count], timeout: 6)
            XCTAssertEqual(app.state, .runningForeground)
        }
        XCTAssertTrue(app.webViews.staticTexts["Close page 0"].firstMatch.waitForExistence(timeout: 10))
        app.webViews.buttons["Check page"].firstMatch.tap()
        XCTAssertTrue(app.webViews.buttons["Still responsive"].firstMatch.waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "top-tab-close-surviving-page"; shot.lifetime = .keepAlways; add(shot)
    }

    func testMorePopoverStaysNextToItsButtonAfterKeyboardDismissal() async throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven UI automation requires iOS 16.4") }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let server = try DownloadPlaybackHTTPFixture(files: ["/menu": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>Menu anchor</title><h1>Menu anchor</h1><div style='height:2000px'>Scrollable page</div>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-is_incognito", "YES",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-browser_toolbar_hidden", "NO",
            "-keep_fullscreen_browsing", "NO", "-wallpaper_source", "gradient", "-privacy_https_upgrade_enabled", "NO",
            "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("menu"))
        XCTAssertTrue(app.webViews.staticTexts["Menu anchor"].firstMatch.waitForExistence(timeout: 10))
        for iteration in 0..<3 {
            if iteration > 0 {
                app.buttons["Edit Address or Search"].firstMatch.tap()
                let field = app.textFields["addressEditor.query"].firstMatch
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
                XCTAssertTrue(field.waitForNonExistence(timeout: 5))
                XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
            }
            let more = app.buttons["browser.more"].firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            let gridHome = app.buttons["browser.moreMenu.home"].firstMatch
            XCTAssertTrue(gridHome.waitForExistence(timeout: 5), app.debugDescription)
            let panel = app.popovers.firstMatch
            XCTAssertTrue(panel.exists, app.debugDescription)
            XCTAssertLessThanOrEqual(abs(panel.frame.maxY - more.frame.minY), 36,
                "The More popover must stay anchored to the bottom toolbar: \(panel.frame), \(more.frame)")
            XCTAssertGreaterThanOrEqual(panel.frame.minY, app.frame.minY)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "more-anchor-\(iteration)"; shot.lifetime = .keepAlways; add(shot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
            XCTAssertTrue(gridHome.waitForNonExistence(timeout: 5))
        }
    }

    func testMoreShortcutTogglesBrowserToolbarInBothDirections() async throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("URL-driven UI automation requires iOS 16.4") }
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/toolbar": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Toolbar toggle fixture</h1>".utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient", "-is_incognito", "YES",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-keep_fullscreen_browsing", "NO",
            "-ad_block_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_actions", "(home,back,tabs,more)", "-browser_more_menu_actions", "(hideToolbar)"]
        app.launch(); defer { app.terminate() }
        app.open(root.appendingPathComponent("toolbar"))
        let page = app.webViews.staticTexts["Toolbar toggle fixture"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 10))

        let home = app.buttons["browser.action.home"].firstMatch
        func openMore() {
            let more = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", "browser.more", "More")).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        }
        if !home.exists {
            openMore()
            app.buttons["Restore Toolbar"].firstMatch.tap()
        }
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        openMore()
        let shortcut = app.buttons["browser.moreMenu.hideToolbar"].firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5)); XCTAssertEqual(shortcut.label, "Hide Toolbar")
        shortcut.tap()
        XCTAssertTrue(home.waitForNonExistence(timeout: 5))

        openMore()
        XCTAssertTrue(shortcut.waitForExistence(timeout: 5)); XCTAssertEqual(shortcut.label, "Restore Toolbar")
        shortcut.tap()
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(page.exists)
    }

    func testLiveTencentPlaybackAndFullscreenDoNotShowSpuriousFailure() async throws {
        guard #available(iOS 16.4, *), ProcessInfo.processInfo.environment["SOULO_LIVE_TENCENT_QA"] == "1",
              SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else {
            throw XCTSkip("Opt-in live Tencent playback in the isolated acceptance app")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language","zh-Hans","-appearance","light","-wallpaper_source","gradient",
            "-is_incognito","YES","-icloud_sync_enabled","NO","-review.requestedOnce","YES",
            "-browser_toolbar_hidden","NO","-keep_fullscreen_browsing","NO","-ad_block_confirm_cross_domain","NO",
            "-video.takeOverWebPlayers","NO","-video.showsWebTools","YES"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_LIVE_VIDEO"] = "1"
        app.launchEnvironment["SOULO_VIDEO_VOLUME_TRACE"] = "1"
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        var route = URLComponents(string: "soulo://open")!
        route.queryItems = [URLQueryItem(name: "url", value: ProcessInfo.processInfo.environment["SOULO_TENCENT_URL"]
            ?? "https://v.qq.com/x/cover/mzc002001bk7moh/o41028027ng.html")]
        app.open(try XCTUnwrap(route.url))
        let probe = app.staticTexts["qa.acceptance"]
        XCTAssertTrue(probe.waitForExistence(timeout: 15))
        func state() -> [String: Any] {
            guard let text = probe.value as? String, let range = text.range(of: ";extension="),
                  let data = String(text[range.upperBound...]).data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return result
        }
        func record(_ name: String) {
            let report = XCTAttachment(string: String(describing: state()))
            report.name = "tencent-" + name; report.lifetime = .keepAlways; add(report)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "tencent-" + name; shot.lifetime = .keepAlways; add(shot)
        }
        func video() -> [String: Any]? { (state()["videos"] as? [[String: Any]])?.first { ($0["width"] as? Int ?? 0)>0 } }
        func tap(_ rect: [String: Double]) {
            let facts = state()
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
                dx:(facts["originX"] as? Double ?? 0)+(rect["x"] ?? 0)+(rect["width"] ?? 0)/2,
                dy:(facts["originY"] as? Double ?? 0)+(rect["y"] ?? 0)+(rect["height"] ?? 0)/2)).tap()
        }
        for _ in 0..<60 {
            if !(state()["videos"] as? [[String: Any]] ?? []).isEmpty { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        record("loaded")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        // Let the publisher's preroll finish naturally. Touching the video
        // during an ad opens its advertiser, which does not test fullscreen.
        // A decoded advertisement alone is not evidence of program playback.
        for _ in 0..<160 {
            let text=state()["text"] as? String ?? ""
            if let v=video(), (v["ready"] as? Int ?? 0)>=2, v["paused"] as? Bool == false,
               (v["duration"] as? Double ?? 0) > 60, (v["time"] as? Double ?? 0) > 0.5,
               !text.contains("关闭该广告"), !text.contains("点击画面，查看详情") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        record("playing")
        guard let before=video(), (before["ready"] as? Int ?? 0)>=2, before["paused"] as? Bool == false,
              (before["duration"] as? Double ?? 0) > 60 else {
            XCTFail("Tencent did not produce a playing decoded video: \(state())"); return
        }
        XCTAssertEqual(state()["handoffError"] as? String, "")
        XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
        let priorTime=before["time"] as? Double ?? 0
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThan(video()?["time"] as? Double ?? 0, priorTime + 0.5)
        if ProcessInfo.processInfo.environment["SOULO_TENCENT_FULLSCREEN_MODE"] == "tools" {
            for iteration in 0..<2 {
                let toggle=app.webViews.buttons["视频工具"].firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription); toggle.tap()
                let controls=state()["controls"] as? [[String: Any]] ?? []
                guard let full=controls.first(where: { ($0["label"] as? String)=="全屏" && ($0["classes"] as? String)=="" }),
                      let rect=full["rect"] as? [String: Double] else {
                    record("missing-soulo-tool"); XCTFail("The expanded Soulo fullscreen tool must be visible: \(state())"); return
                }
                tap(rect)
                let player=app.otherElements["media.mkv.fullscreen.player"].firstMatch
                guard player.waitForExistence(timeout: 20) else {
                    record("soulo-tool-failed"); XCTFail(app.debugDescription); return
                }
                let diagnostic=app.staticTexts["media.volume.diagnostics"].firstMatch
                let decoded=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@","frameReady=true"),object:diagnostic)
                guard XCTWaiter.wait(for:[decoded],timeout:25) == .completed else {
                    record("soulo-no-frame"); XCTFail(diagnostic.exists ? diagnostic.label : app.debugDescription); return
                }
                let report=XCTAttachment(string:diagnostic.label)
                report.name="tencent-soulo-decoded-\(iteration)"; report.lifetime = .keepAlways; add(report)
                record("soulo-fullscreen-\(iteration)")
                let close=app.buttons["media.mkv.fullscreen.close"]
                for _ in 0..<3 where !close.exists {
                    player.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.4)).tap()
                    try await Task.sleep(for:.milliseconds(150))
                }
                XCTAssertTrue(close.exists, app.debugDescription); close.tap()
                try await Task.sleep(for:.seconds(3))
                record("soulo-returned-\(iteration)")
                XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
                XCTAssertEqual(state()["handoffError"] as? String, "")
                XCTAssertTrue(app.webViews.firstMatch.exists)
            }
            return
        }
        for iteration in 0..<2 {
            // Reveal the publisher's controls, then use its own fullscreen entry.
            if let rect=video()?["rect"] as? [String: Double] { tap(rect) }
            try await Task.sleep(for: .milliseconds(500))
            let controls=state()["controls"] as? [[String: Any]] ?? []
            let full=controls.first { c in
                let label=c["label"] as? String ?? "", classes=c["classes"] as? String ?? ""
                return !classes.contains("soulo") && (label=="全屏" || classes.contains("fullscreen"))
            }
            guard let rect=full?["rect"] as? [String: Double] else {
                record("missing-fullscreen"); XCTFail("Publisher fullscreen control not found: \(state())"); return
            }
            tap(rect)
            let close=app.buttons.matching(NSPredicate(format:"label IN %@",["Done","完成","Close","关闭"])).firstMatch
            guard close.waitForExistence(timeout: 10) else {
                // Some Tencent mobile programs intentionally route their
                // fullscreen button to the publisher's App-download page.
                // Verify that outcome separately, never call it fullscreen.
                if (state()["url"] as? String ?? "").contains("/activity/downapp_activity.html") {
                    record("publisher-app-handoff")
                    XCTAssertTrue(app.buttons["browser.external-app-confirmation.cancel"].exists, app.debugDescription)
                    XCTAssertEqual(state()["handoffError"] as? String, "")
                    XCTAssertFalse(app.alerts.firstMatch.exists)
                    app.buttons["browser.external-app-confirmation.cancel"].tap()
                    return
                }
                record("fullscreen-not-entered"); XCTFail(app.debugDescription); return
            }
            record("fullscreen-\(iteration)")
            close.tap()
            try await Task.sleep(for: .seconds(3))
            record("returned-\(iteration)")
            XCTAssertFalse(app.alerts.firstMatch.exists, app.debugDescription)
            XCTAssertEqual(state()["handoffError"] as? String, "")
        }
    }

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

    func testVideoToolsLongPressDragIsTemporaryAndResetsOnPageReload() async throws {
        guard #available(iOS 16.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance") else {
            throw XCTSkip("Requires URL opening in the isolated acceptance app")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let html = """
        <!doctype html><html lang="en"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Video tools drag fixture</title>
        <style>
        *{box-sizing:border-box}body{margin:0;padding:24px 16px;min-height:calc(100vh + 1200px);font:16px -apple-system,sans-serif;background:#f2f3f7;color:#20232a}
        h1{font-size:18px;margin:0 0 24px}video{display:block;width:320px;max-width:100%;height:200px;background:#252936}
        button{display:block;margin-top:24px;min-height:44px;padding:8px 20px;font:inherit}
        .scroll-fixture{position:fixed;top:8px;right:8px;margin:0;padding:8px 12px;font-size:12px;z-index:2}
        </style></head><body><h1>Video tools drag fixture</h1>
        <video width="320" height="200" playsinline preload="none"></video>
        <button type="button" onclick="location.reload()">Reload fixture page</button>
        <button type="button" class="scroll-fixture" onclick="const away=window.scrollY&lt;100;window.scrollTo(0,away?600:0);window.requestAnimationFrame(()=&gt;window.requestAnimationFrame(()=&gt;this.textContent=window.scrollY&gt;400?'Restore fixture scroll':'Scroll fixture away'))">Scroll fixture away</button>
        </body></html>
        """
        let path = "/video-tools-drag.html"
        let server = try DownloadPlaybackHTTPFixture(files: [path: Data(html.utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-is_incognito", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-auto_hide_platform_bar", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-ad_block_enabled", "NO",
            "-video.showsWebTools", "YES", "-video.takeOverWebPlayers", "NO"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        var route = URLComponents(string: "soulo://open")!
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("video-tools-drag.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let web = app.webViews.firstMatch
        let tools = web.buttons["Video tools"].firstMatch
        let close = web.buttons["Close"].firstMatch
        let reload = web.buttons["Reload fixture page"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(tools.isHittable)
        XCTAssertTrue(reload.exists)

        // Use real taps before and after the drag: moving must not replace the
        // normal expand/collapse gesture or trigger expansion on pointer-up.
        tools.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
        close.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        let initial = tools.frame
        let destination = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: max(web.frame.minX + 220, initial.midX - 55) - app.frame.minX,
            dy: min(web.frame.maxY - 30, initial.midY + 235) - app.frame.minY))
        tools.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.65, thenDragTo: destination)
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            tools.exists && hypot(tools.frame.midX - initial.midX, tools.frame.midY - initial.midY) > 55
        }, object: nil)
        await fulfillment(of: [moved], timeout: 4)
        XCTAssertFalse(close.exists, "Finishing a long-press drag must not expand the video tools")
        let dragged = tools.frame
        // The fixture video is exactly 200pt high. Its initial toggle starts
        // inside the top edge, so this puts the entire handle below the box.
        XCTAssertGreaterThan(dragged.minY, initial.minY + 200, "Video tools must be draggable outside the source video frame")
        XCTAssertGreaterThanOrEqual(dragged.minX, web.frame.minX - 2)
        XCTAssertLessThanOrEqual(dragged.maxX, web.frame.maxX + 2)
        XCTAssertGreaterThanOrEqual(dragged.minY, web.frame.minY - 2)
        XCTAssertLessThanOrEqual(dragged.maxY, web.frame.maxY + 2)
        let movedShot = XCTAttachment(screenshot: app.screenshot())
        movedShot.name = "video-tools-real-long-press-drag"; movedShot.lifetime = .keepAlways; add(movedShot)
        tools.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertEqual(close.frame.midX, dragged.midX, accuracy: 3, "Expanding must preserve the detached handle position")
        XCTAssertEqual(close.frame.midY, dragged.midY, accuracy: 3)
        close.tap()
        XCTAssertTrue(tools.waitForExistence(timeout: 3))
        XCTAssertEqual(tools.frame.midX, dragged.midX, accuracy: 3)
        XCTAssertEqual(tools.frame.midY, dragged.midY, accuracy: 3)

        let scrollAway = web.buttons["Scroll fixture away"].firstMatch
        XCTAssertTrue(scrollAway.isHittable)
        XCTAssertFalse(scrollAway.frame.intersects(dragged), "The scroll fixture button must not be covered by the detached video tools")
        scrollAway.tap()
        XCTAssertTrue(web.buttons["Restore fixture scroll"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(tools.exists, "A manually detached control must stay visible when its source scrolls off screen")
        XCTAssertEqual(tools.frame.midX, dragged.midX, accuracy: 3)
        XCTAssertEqual(tools.frame.midY, dragged.midY, accuracy: 3)
        web.buttons["Restore fixture scroll"].firstMatch.tap()
        XCTAssertTrue(web.buttons["Scroll fixture away"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(tools.frame.midX, dragged.midX, accuracy: 3)
        XCTAssertEqual(tools.frame.midY, dragged.midY, accuracy: 3)

        let requestsBeforeReload = server.receivedRequests.filter { $0.path == path && $0.method == "GET" }.count
        reload.tap()
        let reset = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let requestedAgain = server.receivedRequests.filter { $0.path == path && $0.method == "GET" }.count > requestsBeforeReload
            return requestedAgain && tools.exists
                && abs(tools.frame.midX - initial.midX) <= 3 && abs(tools.frame.midY - initial.midY) <= 3
        }, object: nil)
        await fulfillment(of: [reset], timeout: 10)
        XCTAssertFalse(close.exists)
        XCTAssertEqual(tools.frame.midX, initial.midX, accuracy: 3, "A new document must discard the temporary drag offset")
        XCTAssertEqual(tools.frame.midY, initial.midY, accuracy: 3)
        tools.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), "The reloaded control must still respond to a short tap")
        close.tap()
        let resetShot = XCTAttachment(screenshot: app.screenshot())
        resetShot.name = "video-tools-reload-restores-position"; resetShot.lifetime = .keepAlways; add(resetShot)
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
