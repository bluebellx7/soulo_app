import XCTest

@MainActor
final class HomeToolbarUITests: XCTestCase {
    func testWebVideoDownloadExtensionTogglePersistsAndSharesItsDetailSetting() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launch(); defer { app.terminate() }
        func openModule() {
            openCompactSettings(app)
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Scripts")
            let entry = app.buttons["settings.extensions"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            XCTAssertTrue(app.switches["extensions.video-download-toggle"].waitForExistence(timeout: 5))
        }
        func set(_ element: XCUIElement, _ enabled: Bool) {
            XCTAssertTrue(element.waitForExistence(timeout: 5))
            if (element.value as? String == "1") != enabled {
                element.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(element.value as? String, enabled ? "1" : "0")
        }
        openModule()
        let toggle = app.switches["extensions.video-download-toggle"]
        let original = toggle.value as? String == "1"
        set(toggle, false)
        compactSettingsCapture(app, name: "web-video-download-extension-disabled")
        app.buttons["extensions.video-download-details"].tap()
        let detail = app.switches["extensions.video-download-details-toggle"]
        XCTAssertTrue(detail.waitForExistence(timeout: 5)); XCTAssertEqual(detail.value as? String, "0")
        set(detail, true)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        set(toggle, false)
        app.terminate(); app.launch(); openModule()
        XCTAssertEqual(toggle.value as? String, "0")
        set(toggle, original)
        compactSettingsCapture(app, name: "web-video-download-extension-restored")
    }

    func testCompactSettingsDisplayPagesKeepPreferencesAndNestedNavigation() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        XCTAssertFalse(app.buttons["settings.homeDisplay.title"].exists)
        XCTAssertFalse(app.switches["settings.homeDisplay.bookmarks"].exists)
        XCTAssertFalse(app.switches["settings.browsingDisplay.topSearchBar"].exists)
        XCTAssertFalse(app.switches["settings.icloud-sync"].exists)
        compactSettingsTap("settings.wallpaper", app: app)
        XCTAssertTrue(app.navigationBars["Wallpaper"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["wallpaper.sources"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["settings.personalization.section"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        compactSettingsTap("settings.browsingDisplay", app: app)
        XCTAssertFalse(app.switches["settings.browsingDisplay.topSearchBar"].exists)
        XCTAssertFalse(app.switches["settings.browsingDisplay.platformBar"].exists)
        for id in ["fullscreen", "pageAboveToolbar"] {
            XCTAssertTrue(app.switches["settings.browsingDisplay." + id].exists)
        }
        compactSettingsCapture(app, name: "compact-settings-browsing-display")
        compactSettingsTap("settings.websiteZoom", app: app)
        XCTAssertTrue(app.switches["settings.zoom.remember"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.switches["settings.browsingDisplay.fullscreen"].waitForExistence(timeout: 5))
        compactSettingsTap("settings.webAppearance", app: app)
        XCTAssertTrue(app.navigationBars["Web Appearance"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.switches["settings.browsingDisplay.fullscreen"].waitForExistence(timeout: 5))


    }

    func testCompactSettingsBackupsAboutAndFooter() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        XCTAssertFalse(app.buttons["settings.rate"].exists)
        XCTAssertFalse(app.buttons["settings.feedback"].exists)
        XCTAssertFalse(app.buttons["settings.url-schemes"].exists)
        compactSettingsTap("settings.backups", app: app)
        XCTAssertTrue(app.switches["settings.icloud-sync"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["settings.icloud-sync"].value as? String, "0")
        XCTAssertTrue(app.switches["settings.icloud-bookmarks"].exists)
        let backupActions = ["save", "import", "export"].map { app.buttons["settings.backups." + $0] }
        for action in backupActions {
            XCTAssertTrue(action.exists)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44)
            XCTAssertLessThanOrEqual(action.frame.height, 56)
            XCTAssertEqual(action.frame.midY, backupActions[0].frame.midY, accuracy: 1)
        }
        compactSettingsCapture(app, name: "compact-settings-backups-with-sync")
        app.navigationBars.buttons.firstMatch.tap()
        let storage = app.buttons["settings.storage"]
        compactSettingsReveal(storage, app: app)
        XCTAssertTrue(storage.isHittable)
        compactSettingsReveal(app.buttons["settings.quickClear"], app: app)
        let footer = app.staticTexts["settings.footer.version"]
        compactSettingsReveal(footer, app: app)
        XCTAssertNotNil(footer.label.range(of: "^Soulo [0-9]+\\.[0-9]+", options: .regularExpression))
        let telegram = app.descendants(matching: .any)["settings.telegram"].firstMatch
        XCTAssertTrue(telegram.exists && telegram.isHittable)
        XCTAssertGreaterThan(telegram.frame.midY, app.buttons["settings.version"].frame.midY)
        XCTAssertLessThan(telegram.frame.midY, footer.frame.midY)
        compactSettingsCapture(app, name: "compact-settings-other-about-footer")
        compactSettingsTap("settings.version", app: app)
        XCTAssertTrue(app.buttons["version.website"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["version.telegram"].firstMatch.exists)
        compactSettingsTap("settings.rate", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["review.write"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        compactSettingsTap("settings.url-schemes", app: app)
        XCTAssertTrue(app.buttons["scheme.copy.scheme_home"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        compactSettingsTap("settings.feedback", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["feedback.telegram"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["settings.rate"].waitForExistence(timeout: 5))
        compactSettingsCapture(app, name: "compact-settings-about-support")
    }

    func testFeedbackRequiresContactBeforeSubmission() {
        continueAfterFailure = false
        let app = compactSettingsApp(); app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        compactSettingsTap("settings.version", app: app)
        compactSettingsTap("settings.feedback", app: app)
        let content = app.textViews["feedback.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 5)); content.tap(); content.typeText("Required contact UI fixture")
        app.buttons["feedback.keyboard.done"].tap()
        let submit = app.buttons["feedback.submit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled)
        let contact = app.textFields["feedback.contact"]
        compactSettingsReveal(contact, app: app)
        contact.tap(); contact.typeText("qa@example.test")
        app.buttons["feedback.keyboard.done"].tap()
        compactSettingsReveal(submit, app: app)
        XCTAssertTrue(submit.isEnabled)
        compactSettingsCapture(app, name: "feedback-contact-required-valid")
        contact.tap()
        contact.press(forDuration: 1.2)
        let selectAll = app.menuItems.matching(NSPredicate(format: "label IN %@", ["Select All", "全选", "全選"])).firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3), app.debugDescription)
        selectAll.tap()
        contact.typeText(XCUIKeyboardKey.delete.rawValue)
        app.buttons["feedback.keyboard.done"].tap()
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "Contact must be empty: \(String(describing: contact.value))")
    }

    func testSettingsSearchFindsWebpageBackgroundExtension() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        for character in "Background" { search.typeText(String(character)) }
        XCTAssertEqual(search.value as? String, "Background")
        compactSettingsTap("settings.browsingDisplay", app: app)
        XCTAssertTrue(app.switches["settings.browsingDisplay.backgroundExtension"].waitForExistence(timeout: 5))
    }

    func testFreezingPageColorsIsConditionalAndPersists() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launch(); defer { app.terminate() }
        func openDisplay() { openCompactSettings(app); compactSettingsTap("settings.browsingDisplay", app: app) }
        func set(_ toggle: XCUIElement, _ enabled: Bool) {
            compactSettingsReveal(toggle, app: app)
            if (toggle.value as? String == "1") != enabled { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        openDisplay()
        let extensionToggle = app.switches["settings.browsingDisplay.backgroundExtension"]
        let freeze = app.switches["settings.browsingDisplay.freezeBackgroundOnScroll"]
        let gradient = app.switches["settings.browsingDisplay.backgroundGradient"]
        set(extensionToggle, false)
        XCTAssertFalse(freeze.exists)
        XCTAssertFalse(gradient.exists)
        set(extensionToggle, true)
        let done = app.buttons["browsing-guide.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(freeze.waitForExistence(timeout: 5))
        XCTAssertTrue(gradient.exists)
        XCTAssertEqual(gradient.value as? String, "0")
        XCTAssertEqual(gradient.frame.minX, freeze.frame.minX, accuracy: 1)
        XCTAssertEqual(gradient.frame.maxX, freeze.frame.maxX, accuracy: 1)
        set(gradient, true)
        set(freeze, true)
        compactSettingsCapture(app, name: "page-background-keep-initial-colors-setting")
        app.terminate(); app.launch(); openDisplay()
        XCTAssertEqual(extensionToggle.value as? String, "1")
        XCTAssertEqual(freeze.value as? String, "1")
        XCTAssertEqual(gradient.value as? String, "1")
        set(gradient, false)
        set(freeze, false); set(extensionToggle, false)
        XCTAssertFalse(freeze.exists)
    }

    func testBrowsingDisplayExamplesAndRenderedPageBackgroundExtension() async throws {
        continueAfterFailure = false
        let html = """
        <meta name='viewport' content='width=device-width,initial-scale=1'>
        <style>html,body{margin:0;background:white}header,footer{position:fixed;left:0;right:0;height:70px}header{top:0;background:#d91c2c}footer{bottom:0;background:#195bcc}main{padding:110px 20px;min-height:1300px}button{font-size:22px}</style>
        <header></header><main><h1>Browser edge fixture</h1><button onclick="document.querySelector('header').style.background='#112233';document.querySelector('footer').style.background='#eebc22'">Change edge colors</button></main><footer></footer>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/edge-colors": Data(html.utf8)])
        let root = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let app = compactSettingsApp()
        if let index = app.launchArguments.firstIndex(of: "-wallpaper_source") { app.launchArguments[index + 1] = "solid" }
        app.launchArguments += ["-wallpaper_solid_color_light", "#E6F0FF", "-wallpaper_solid_color_dark", "#111111", "-freeze_page_background_on_scroll", "NO"]
        app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        compactSettingsTap("settings.browsingDisplay", app: app)
        for (id, name) in [("fullscreen", "fullscreen"), ("backgroundExtension", "background"), ("pageAboveToolbar", "aboveToolbar")] {
            let toggle = app.switches["settings.browsingDisplay." + id].firstMatch
            compactSettingsReveal(toggle, app: app)
            if toggle.value as? String == "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            let done = app.buttons["browsing-guide.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(app.switches["browsing-guide.enabled"].firstMatch.value as? String, "1")
            compactSettingsCapture(app, name: "browsing-example-" + name)
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 3))
            if id == "fullscreen" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        }
        app.navigationBars.buttons.firstMatch.tap()
        let settingsDone = app.navigationBars["Settings"].buttons["Done"]
        XCTAssertTrue(settingsDone.waitForExistence(timeout: 5)); settingsDone.tap()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("edge-colors").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Browser edge fixture"].firstMatch.waitForExistence(timeout: 12))
        func rgb(_ image: UIImage, x: CGFloat, y: CGFloat) -> (Double, Double, Double) {
            let sx = CGFloat(image.cgImage?.width ?? 0) / max(1, app.frame.width)
            let sy = CGFloat(image.cgImage?.height ?? 0) / max(1, app.frame.height)
            guard let source = image.cgImage?.cropping(to: CGRect(x: x * sx, y: y * sy, width: 1, height: 1)) else { return (0,0,0) }
            var pixel = [UInt8](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(source, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return (Double(pixel[0])/255, Double(pixel[1])/255, Double(pixel[2])/255)
        }
        func checkEdges(dark: Bool) async {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let image = XCUIScreen.main.screenshot().image
                let top = rgb(image, x: 8, y: 25), bottom = rgb(image, x: 8, y: app.frame.height - 8)
                return dark ? (top.0 < 0.2 && top.2 < 0.3 && bottom.0 > 0.7 && bottom.1 > 0.5)
                            : (top.0 > 0.6 && top.1 < 0.3 && bottom.2 > 0.5 && bottom.0 < 0.3)
            }, object: nil)
            await fulfillment(of: [ready], timeout: 10)
        }
        await checkEdges(dark: false)
        compactSettingsCapture(app, name: "browser-page-background-red-top-blue-bottom")
        app.webViews.buttons["Change edge colors"].firstMatch.tap()
        await checkEdges(dark: true)
        compactSettingsCapture(app, name: "browser-page-background-dynamic-dark-top-gold-bottom")
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        let homeColor = rgb(XCUIScreen.main.screenshot().image, x: 8, y: app.frame.height * 0.35)
        XCTAssertEqual(homeColor.0, 230.0 / 255, accuracy: 0.04)
        XCTAssertEqual(homeColor.1, 240.0 / 255, accuracy: 0.04)
        XCTAssertEqual(homeColor.2, 1, accuracy: 0.04)
        compactSettingsCapture(app, name: "home-wallpaper-unchanged-after-dark-web-chrome")
        openCompactSettings(app)
        compactSettingsTap("settings.browsingDisplay", app: app)
        let background = app.switches["settings.browsingDisplay.backgroundExtension"].firstMatch
        compactSettingsReveal(background, app: app)
        background.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(background.value as? String, "0")
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons["Done"].tap()
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Browser edge fixture"].firstMatch.waitForExistence(timeout: 12))
        let originalChrome = rgb(XCUIScreen.main.screenshot().image, x: 8, y: 25)
        XCTAssertTrue(originalChrome.1 > 0.3, "Disabling extension must stop using the webpage's red header")
        compactSettingsCapture(app, name: "browser-background-extension-disabled")
    }

    private func compactSettingsApp() -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        return app
    }

    private func openCompactSettings(_ app: XCUIApplication) {
        app.open(URL(string: "soulo://")!)
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    private func compactSettingsReveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func compactSettingsTap(_ id: String, app: XCUIApplication) {
        let element = app.buttons[id]
        compactSettingsReveal(element, app: app); element.tap()
    }

    private func compactSettingsCapture(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testGlobalFeedbackSettingsPersistAndAreSharedWithGestures() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        app.launch(); defer { app.terminate() }
        func openSettings(search query: String, entry: String) {
            app.open(URL(string: "soulo://")!)
            let menu = app.buttons["home.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
            app.buttons["Settings"].firstMatch.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText(query)
            let link = app.buttons[entry]
            XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        }
        func set(_ toggle: XCUIElement, enabled: Bool) {
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            if (toggle.value as? String == "1") != enabled {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
        }
        openSettings(search: "Haptics", entry: "settings.feedbackPreferences")
        let haptics = app.switches["settings.feedback.haptics"]
        let sound = app.switches["settings.feedback.sound"]
        XCTAssertTrue(haptics.waitForExistence(timeout: 5))
        let originalHaptics = haptics.value as? String == "1"
        let originalSound = sound.value as? String == "1"
        let preview = app.buttons["settings.feedback.preview"]
        set(haptics, enabled: false); set(sound, enabled: false)
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        set(haptics, enabled: true)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        set(haptics, enabled: false)
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        set(sound, enabled: true)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        preview.tap()
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "global-sounds-and-haptics"; shot.lifetime = .keepAlways; add(shot)

        app.terminate(); app.launch()
        openSettings(search: "Webpage Gestures", entry: "settings.gestures")
        let feedback = app.buttons["settings.gestures.feedback"]
        for _ in 0..<5 where !feedback.isHittable { app.swipeUp() }
        XCTAssertTrue(feedback.waitForExistence(timeout: 5)); feedback.tap()
        XCTAssertTrue(haptics.waitForExistence(timeout: 5))
        XCTAssertEqual(haptics.value as? String, "0")
        XCTAssertEqual(sound.value as? String, "1")
        set(haptics, enabled: originalHaptics); set(sound, enabled: originalSound)
    }

    func testGesturesAndFeedbackGroupOpensAllThreeSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10)); app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.interaction"]
        for _ in 0..<5 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        for (id, ready) in [("shake", "settings.shake.direction"), ("gestures", "settings.gestures.enabled"), ("feedback", "settings.feedback.haptics")] {
            let row = app.buttons["settings.interaction." + id]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            XCTAssertTrue(app.descendants(matching: .any)[ready].firstMatch.waitForExistence(timeout: 5))
            let done = app.buttons["Done"].firstMatch
            if done.exists { done.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
            XCTAssertTrue(row.waitForExistence(timeout: 5))
        }
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "gestures-feedback-group"; shot.lifetime = .keepAlways; add(shot)
    }

    func testAdFilteringDestinationsRemainResponsiveOnRepeatedNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout:10)); app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5)); search.tap(); search.typeText("Ad Blocking")
        app.buttons["settings.adBlock"].firstMatch.tap()
        let routes = [("domainAllowlist","Trusted domains"),("manualRules","Marked ads"),
            ("builtInRules","Built-in rules"),("subscriptions","Filter lists"),("allowedSites","Allowed Sites")]
        for pass in 0..<2 {
            for (id, title) in routes {
                let entry = app.buttons["adBlock." + id]
                for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
                for _ in 0..<4 where !entry.isHittable { app.swipeDown() }
                XCTAssertTrue(entry.waitForExistence(timeout:5)); entry.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:5), app.debugDescription)
                let done = app.buttons["Done"].firstMatch
                if done.exists { done.tap() } else { app.navigationBars.buttons.firstMatch.tap() }
                XCTAssertTrue(app.buttons["adBlock." + id].waitForExistence(timeout:5), "Return from \(id), pass \(pass)")
            }
        }
    }

    func testCustomAdFilterListCanBeAddedValidatedRestoredAndDeleted() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchEnvironment["OS_ACTIVITY_MODE"] = "disable"
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-ad_block_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        func openLists() {
            app.open(URL(string: "soulo://")!)
            let menu = app.buttons["home.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
            app.buttons["Settings"].firstMatch.tap()
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
            let filtering = app.buttons["settings.adBlock"].firstMatch
            XCTAssertTrue(filtering.waitForExistence(timeout: 5)); filtering.tap()
            let lists = app.buttons["adBlock.subscriptions"]
            for _ in 0..<4 where !lists.isHittable { app.swipeUp() }
            XCTAssertTrue(lists.waitForExistence(timeout: 5)); lists.tap()
            XCTAssertTrue(app.buttons["adBlock.addSubscription"].waitForExistence(timeout: 5))
        }
        openLists()
        let name = "Personal QA " + UUID().uuidString.prefix(6)
        let address = "https://filters-qa.example/" + UUID().uuidString + ".txt"
        app.buttons["adBlock.addSubscription"].tap()
        let nameField = app.textFields["adBlock.subscription.name"]
        let urlField = app.textFields["adBlock.subscription.url"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5)); nameField.tap(); nameField.typeText(name)
        urlField.tap(); urlField.typeText("not-a-link")
        let save = app.buttons["adBlock.subscription.save"]
        save.tap()
        XCTAssertTrue(app.staticTexts["adBlock.subscription.error"].waitForExistence(timeout: 3))
        urlField.tap()
        urlField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "not-a-link".count) + address)
        XCTAssertFalse(app.staticTexts["adBlock.subscription.error"].exists, "Editing the input clears the previous validation error")
        let editorShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editorShot.name = "custom-filter-list-editor"; editorShot.lifetime = .keepAlways; add(editorShot)
        save.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5))

        app.buttons["adBlock.addSubscription"].tap()
        XCTAssertTrue(nameField.waitForExistence(timeout: 5)); nameField.tap(); nameField.typeText("Duplicate QA")
        urlField.tap(); urlField.typeText(address + "#duplicate")
        save.tap()
        XCTAssertTrue(app.staticTexts["This subscription URL has already been added."].waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()

        app.terminate(); app.launch(); openLists()
        XCTAssertTrue(app.staticTexts[name].waitForExistence(timeout: 5), "Custom subscriptions must survive restarting the app")
        let listShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        listShot.name = "custom-filter-list-persisted"; listShot.lifetime = .keepAlways; add(listShot)
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(row.exists); row.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3)); delete.tap()
        XCTAssertTrue(app.staticTexts[name].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["EasyList"].exists, "Deleting a custom list must preserve built-in lists")
    }

    func testWallpaperAppearanceOutlinesRemainVisibleOnBothCards() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        for appearance in ["light", "dark"] {
            let card = app.buttons["wallpaper.appearance." + appearance]
            for _ in 0..<3 where !card.isHittable { app.swipeUp() }
            XCTAssertTrue(card.waitForExistence(timeout: 5)); card.tap()
            XCTAssertTrue(card.isSelected)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "wallpaper-outline-" + appearance; shot.lifetime = .keepAlways; add(shot)
        }
    }

    func testLocalWallpaperPreviewAndAppearanceSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "photo", "-appearance", "light",
            "-wallpaper_refresh_interval", "60", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
            "-show_recent_searches_on_home", "NO", "-show_bookmarks_on_home", "NO", "-show_group_picker_on_home", "YES",
            "-home_title", "Soulo", "-home_subtitle", ""]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["home.wallpaper.topic"].exists)
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        home.name = "dark-photo-light-appearance-contrast"; home.lifetime = .keepAlways; add(home)
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let download = app.buttons["home.wallpaper.download"]
        XCTAssertTrue(download.waitForExistence(timeout: 5)); download.tap()
        let share = app.buttons["wallpaper.export.share"], save = app.buttons["wallpaper.export.save"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(save.exists)
        XCTAssertTrue(NSPredicate(format: "enabled == true").evaluate(with: save) ||
            XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 10) == .completed)
        XCTAssertFalse(app.buttons["wallpaper.export.saved"].exists, "Previewing does not save automatically")
        let preview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        preview.name = "wallpaper-export-preview-two-actions"; preview.lifetime = .keepAlways; add(preview)
        save.tap()
        XCTAssertTrue(app.otherElements["wallpaper.export.saved"].exists || app.staticTexts["Wallpaper saved to Photos"].waitForExistence(timeout: 10), app.debugDescription)
        share.tap()
        let activity = app.otherElements["ActivityListView"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.otherElements["LP.CaptionBar.TopCaption"].label, "Wallpaper")
        let systemShare = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        systemShare.name = "wallpaper-original-system-share"; systemShare.lifetime = .keepAlways; add(systemShare)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        // Relaunch dismisses the system activity sheet without depending on its language.
        app.terminate()
        let appearanceIndex = try XCTUnwrap(app.launchArguments.firstIndex(of: "-appearance"))
        app.launchArguments[appearanceIndex + 1] = "dark"
        app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["home.wallpaper.download"].tap()
        XCTAssertTrue(app.buttons["wallpaper.export.share"].waitForExistence(timeout: 5))
        let darkPreview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        darkPreview.name = "wallpaper-preview-follows-dark-theme"; darkPreview.lifetime = .keepAlways; add(darkPreview)
        app.buttons["wallpaper.export.close"].tap()
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let sources = app.scrollViews["wallpaper.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5)); sources.swipeLeft()
        for source in ["solid", "gradient", "photo"] {
            let tile = app.buttons["wallpaper.source." + source]
            XCTAssertTrue(tile.isHittable); tile.tap()
            XCTAssertFalse(app.switches["wallpaper.randomSources"].exists)
            let light = app.buttons["wallpaper.appearance.light"], dark = app.buttons["wallpaper.appearance.dark"]
            XCTAssertTrue(light.exists); XCTAssertTrue(dark.exists)
            dark.tap(); XCTAssertTrue(dark.isSelected)
            light.tap(); XCTAssertTrue(light.isSelected)
        }
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "wallpaper-separate-light-dark-photo-editor"; editor.lifetime = .keepAlways; add(editor)
    }

    func testWallpaperContrastAcrossAppearances() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for appearance in ["light", "dark"] {
            for color in ["#FFFFFF", "#18243E"] {
                app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-appearance", appearance,
                    "-wallpaper_solid_color_light", color, "-wallpaper_solid_color_dark", color,
                    "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES",
                    "-show_recent_searches_on_home", "NO", "-show_group_picker_on_home", "YES", "-home_title", "Soulo"]
                app.launch()
                let menu = app.buttons["home.menu"]
                XCTAssertTrue(menu.waitForExistence(timeout: 10))
                XCTAssertTrue(app.textFields["search.query"].exists)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "wallpaper-contrast-" + appearance + "-" + color.dropFirst()
                shot.lifetime = .keepAlways; add(shot)
                menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(app.buttons["Settings"].firstMatch.waitForExistence(timeout: 3))
                app.terminate()
            }
        }
    }

    func testTopTabOptionsCreateHideAndCloseTabs() async throws {
        continueAfterFailure = false
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Tab options fixture</h1>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/one": Data(html.utf8), "/two": Data(html.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO",
            "-show_top_tab_bar", "YES", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        func open(_ path: String) throws {
            var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
            route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent(path).absoluteString)]
            app.open(try XCTUnwrap(route.url))
            XCTAssertTrue(app.webViews.staticTexts["Tab options fixture"].waitForExistence(timeout: 15))
        }
        try open("one")
        let tabs = app.buttons["browser.tabs"]
        tabs.tap(); app.buttons["tabs.options"].tap()
        let closeOthers = app.buttons["tabs.close-others"]
        if closeOthers.exists { closeOthers.tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.18)).tap() }
        app.buttons["tabs.done"].tap()
        try open("two")
        let options = app.buttons["browser.top-tab-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        XCTAssertEqual(tabs.label, "2 Tabs", "Opening settings must not create a tab")
        XCTAssertTrue(app.switches["tabs.show-top-bar"].exists)
        XCTAssertTrue(app.buttons["tabs.close-others"].exists)
        XCTAssertTrue(app.buttons["tabs.close-all"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "top-tab-settings-with-new-tab"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["tabs.new-tab"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(tabs.label, "3 Tabs")
        options.tap(); app.buttons["tabs.close-others"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(tabs.label, "1 Tabs")
        XCTAssertFalse(options.exists)
        tabs.tap(); app.buttons["tabs.options"].tap(); app.buttons["tabs.new-tab"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(tabs.label, "2 Tabs")
        options.tap(); app.buttons["tabs.close-all"].coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(tabs.label, "1 Tabs")
        XCTAssertTrue(app.staticTexts["New Tab"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(options.exists)
    }

    func testHidingTopTabBarExplainsAndRestoresTheSettingsRoute() async throws {
        continueAfterFailure = false
        let html = "<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Recovery guide fixture</h1>"
        let server = try DownloadPlaybackHTTPFixture(files: ["/one": Data(html.utf8), "/two": Data(html.utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "solid", "-icloud_sync_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        func open(_ path: String) throws {
            var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
            route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent(path).absoluteString)]
            app.open(try XCTUnwrap(route.url))
            XCTAssertTrue(app.webViews.staticTexts["Recovery guide fixture"].waitForExistence(timeout: 15))
        }
        try open("one"); try open("two")
        let tabs = app.buttons["browser.tabs"]
        tabs.tap(); app.buttons["tabs.options"].tap()
        let toggle = app.switches["tabs.show-top-bar"]
        if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        app.buttons["tabs.done"].tap()
        let options = app.buttons["browser.top-tab-options"]
        XCTAssertTrue(options.waitForExistence(timeout: 5)); options.tap()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let done = app.buttons["tabs.recovery.dismiss"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(options.exists)
        XCTAssertTrue(app.staticTexts["Top Tab Bar Hidden"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "top-tab-bar-reopen-illustration"; shot.lifetime = .keepAlways; add(shot)
        done.tap()
        tabs.tap(); app.buttons["tabs.options"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        app.buttons["tabs.done"].tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
    }

    func testWallpaperImageOverlayPersistsAndIsOnlyOfferedForImages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "photo", "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        func settings() {
            let menu = app.buttons["home.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10)); menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            app.buttons["Settings"].firstMatch.tap()
            let entry = app.buttons["settings.wallpaper"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        }
        app.launch(); defer { app.terminate() }; settings()
        let overlay = app.switches["wallpaper.image-overlay"], blur = app.switches["wallpaper.image-blur"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 5)); XCTAssertTrue(blur.exists)
        let initial = overlay.value as? String, originalBlur = blur.value as? String
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = overlay.value as? String
        XCTAssertNotEqual(initial, changed)
        if changed == "0" { overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let overlaySlider = app.sliders["wallpaper.overlay-amount"]
        XCTAssertTrue(overlaySlider.waitForExistence(timeout: 5))
        overlaySlider.adjust(toNormalizedSliderPosition: 0.65)
        let overlayAmount = overlaySlider.value as? String
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertFalse(overlaySlider.exists)
        overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(overlaySlider.value as? String, overlayAmount)
        if originalBlur == "0" { blur.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        let slider = app.sliders["wallpaper.blur-amount"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5)); slider.adjust(toNormalizedSliderPosition: 0.75)
        let amount = slider.value as? String
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "wallpaper-mask-and-adjustable-frosted-glass"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch(); settings()
        XCTAssertEqual(overlay.value as? String, "1")
        XCTAssertEqual(overlaySlider.value as? String, overlayAmount)
        XCTAssertEqual(blur.value as? String, "1")
        XCTAssertEqual(slider.value as? String, amount)
        if initial == "0" { overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        if originalBlur == "0" { blur.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        app.scrollViews["wallpaper.sources"].swipeLeft()
        app.buttons["wallpaper.source.solid"].tap()
        XCTAssertFalse(overlay.exists); XCTAssertFalse(overlaySlider.exists); XCTAssertFalse(blur.exists); XCTAssertFalse(slider.exists)
        app.buttons["wallpaper.source.gradient"].tap()
        XCTAssertFalse(overlay.exists); XCTAssertFalse(overlaySlider.exists); XCTAssertFalse(blur.exists); XCTAssertFalse(slider.exists)
    }

    func testRemoteWallpaperSourceThumbnailCentersAndLabelsRemainSelectable() {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launchArguments += ["-wallpaper_source", "pixabay", "-wallpaper_refresh_interval", "0",
            "-wallpaper_only_favorites", "NO", "-wallpaper_image_overlay", "YES",
            "-wallpaper_image_blur", "YES", "-wallpaper_image_blur_amount", "0.75"]
        app.launch(); defer { app.terminate() }
        openCompactSettings(app)
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let sources = app.scrollViews["wallpaper.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["wallpaper.source.pixabay"].isSelected)
        for (source, y) in [("pexels", 0.35), ("bing", 0.35), ("pixabay", 0.35),
                            ("pexels", 0.9), ("bing", 0.9), ("pixabay", 0.9)] {
            let tile = app.buttons["wallpaper.source." + source]
            XCTAssertTrue(tile.isHittable)
            tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: y)).tap()
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tile.isSelected }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 3), .completed, "Tapping \(source) must select that source")
        }
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "wallpaper-remote-sources-thumbnail-hit-regions"; shot.lifetime = .keepAlways; add(shot)
    }

    func testWallpaperSettingsSwitchSourcesAndApplyGradient() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "aurora", "-wallpaper_refresh_interval", "0",
            "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES"]
        app.launch(); defer { app.terminate() }
        let menu = app.buttons["home.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.wallpaper"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let sources = app.scrollViews["wallpaper.sources"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5))
        sources.swipeLeft()
        let solid = app.buttons["wallpaper.source.solid"]
        XCTAssertTrue(solid.isHittable); solid.tap()
        XCTAssertTrue(solid.isSelected)
        let gradient = app.buttons["wallpaper.source.gradient"]
        gradient.tap(); XCTAssertTrue(gradient.isSelected)
        let forest = app.buttons["wallpaper.gradient.forest"]
        if !forest.isHittable { app.swipeUp() }
        XCTAssertTrue(forest.waitForExistence(timeout: 5)); forest.tap()
        XCTAssertTrue(forest.isSelected)
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "wallpaper-local-source-and-forest-applied"; shot.lifetime = .keepAlways; add(shot)
    }

    func testStartupAndForegroundKeepHomeMenuAndSearchResponsive() async throws {
        continueAfterFailure = false
        let title = "Startup interaction \(UUID().uuidString.prefix(6))"
        let server = try DownloadPlaybackHTTPFixture(files: ["/startup": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><title>\(title)</title><h1>\(title)</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        for wallpaper in ["gradient", "bing", "photo"] {
            app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO", "-appearance", "light",
                "-wallpaper_current_cache_file", "startup-qa.image", "-wallpaper_current_cache_id", "startup-qa",
                "-wallpaper_source", wallpaper, "-wallpaper_refresh_interval", "0", "-icloud_sync_enabled", "NO",
                "-review.requestedOnce", "YES",
                "-soulo_ad_block_subscription_auto_update_check", "0", "-privacy_https_upgrade_enabled", "NO",
                "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
            app.launch()
            let menu = app.buttons["home.menu"]
            XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
            let homeShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            homeShot.name = "startup-home-" + wallpaper; homeShot.lifetime = .keepAlways; add(homeShot)
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settings = app.buttons.matching(NSPredicate(
                format: "label == %@ AND NOT (identifier BEGINSWITH %@)", "Settings", "home.toolbar."
            )).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3), "The first home menu tap must work")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.25)).tap()
            XCTAssertTrue(settings.waitForNonExistence(timeout: 3))
            let field = app.textFields["search.query"].firstMatch
            field.tap()
            if app.buttons["search.clear"].exists { app.buttons["search.clear"].tap(); field.tap() }
            let url = root.appendingPathComponent("startup").absoluteString
            field.typeText(url)
            XCTAssertEqual(field.value as? String, url, "Startup work must not lose the first typed query")
            field.typeText("\n")
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 15))
            app.buttons["Home Screen"].firstMatch.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            let initialMenuWidth = menu.frame.width
            XCUIDevice.shared.press(.home)
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
            // runningForeground precedes the SpringBoard activation animation.
            // Its transient AX frames can still be scaled to the app preview.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                menu.exists && menu.frame.width >= max(1, initialMenuWidth * 0.95)
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 3) == .completed else {
                XCTFail("Home controls must become ready after the system activation transition")
                return
            }
            XCTAssertLessThan(menu.frame.maxY, app.frame.height * 0.25)
            // Native tap() can attempt to scroll this fixed button after a
            // scene transition and choose a point below its visible frame.
            menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(settings.waitForExistence(timeout: 3), "Returning from the background must preserve home hit testing")
            settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let settingsBar = app.navigationBars["Settings"]
            XCTAssertTrue(settingsBar.waitForExistence(timeout: 5), "The menu action must actually open Settings")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "startup-responsive-\(wallpaper)"; shot.lifetime = .keepAlways; add(shot)
            settingsBar.buttons["Done"].tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 5))
            field.tap()
            if app.buttons["search.clear"].exists { app.buttons["search.clear"].tap(); field.tap() }
            field.typeText("Foreground query")
            XCTAssertEqual(field.value as? String, "Foreground query", "Search must accept input after returning to the foreground")
            app.terminate()
        }
    }

    func testHomeTitleRecentSearchAndBookmarkKeepTapAndLongPressActions() async throws {
        continueAfterFailure = false
        let title = "Home press \(UUID().uuidString.prefix(6))"
        let server = try DownloadPlaybackHTTPFixture(files: ["/press": Data("<title>\(title)</title><h1>\(title)</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let url = root.appendingPathComponent("press")
        let query = "Press recent \(UUID().uuidString.prefix(6))"
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-home_title", "Soulo", "-is_incognito", "NO",
            "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-show_bookmarks_on_home", "YES", "-show_group_picker_on_home", "YES", "-show_recent_searches_on_home", "YES",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-browser_toolbar_actions", "(home,bookmark,tabs,more)"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 15))
        app.buttons["browser.action.bookmark"].tap()
        app.buttons["Home Screen"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        let bookmark = app.buttons[title]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        let firstBookmark = app.scrollViews["home.bookmarks"].buttons.firstMatch
        XCTAssertTrue(firstBookmark.exists)
        XCTAssertEqual(firstBookmark.frame.minX, app.otherElements["home.search.field"].frame.minX, accuracy: 2)
        app.buttons["Home title, Soulo"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()

        let field = app.textFields["search.query"].firstMatch
        field.tap(); field.typeText(query + "\n")
        XCTAssertTrue(app.buttons["Edit Address or Search"].firstMatch.waitForExistence(timeout: 10))
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        let recent = app.buttons["Recent search, \(query)"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        XCTAssertTrue(app.buttons["Edit Address or Search"].firstMatch.waitForExistence(timeout: 10), "A short tap must still search")
        app.open(URL(string: "soulo://")!)
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.press(forDuration: 1)
        let deleteRecent = app.buttons["Delete"].firstMatch
        XCTAssertTrue(deleteRecent.waitForExistence(timeout: 5), "Long press must reveal deletion without starting a search")
        deleteRecent.tap()
        XCTAssertTrue(recent.waitForNonExistence(timeout: 5), "The delete action must remain tappable")

        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        bookmark.press(forDuration: 1)
        let remove = app.buttons["Delete"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "Bookmark context menus must still open")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.18)).tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))
        bookmark.tap()
        XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 15), "A regular bookmark tap must still open the page")
        app.buttons["Bookmarks"].firstMatch.tap()
    }

    func testTelegramFeedbackPageShowsLinkAndExternalOpenInBothAppearances() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for (appearance, language, settings) in [("light", "zh-Hans", "设置"), ("dark", "en-US", "Settings")] {
            app.launchArguments = ["-app_language", language, "-appearance", appearance,
                "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
            app.launch(); app.open(URL(string: "soulo://")!)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
            app.buttons["home.menu"].tap()
            app.buttons[settings].firstMatch.tap()
            let entry = app.buttons["settings.telegram"]
            reveal(entry, in: app)
            // XCTest marks a partly visible bottom row as hittable even when
            // its center is behind the sheet's bottom safe area on iPhone.
            for _ in 0..<3 where entry.frame.maxY > app.frame.maxY - 80 { app.swipeUp() }
            entry.tap()
            let link = app.staticTexts["settings.telegram.link"]
            XCTAssertTrue(link.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(link.label, "https://t.me/soulobrowser")
            let open = app.buttons["settings.telegram.open"]
            XCTAssertTrue(open.isHittable, "The page must offer an explicit external app action")
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "telegram-feedback-\(appearance)"; image.lifetime = .keepAlways; add(image)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "Back must return to the bottom of Settings")
            app.terminate()
        }
    }

    func testIllustratedReviewPageReturnsToSettingsAndVersionInBothAppearances() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for (appearance, language, settings) in [("light", "zh-Hans", "设置"), ("dark", "en-US", "Settings")] {
            app.launchArguments = ["-app_language", language, "-appearance", appearance,
                "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
            app.launch(); app.open(URL(string: "soulo://")!)
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
            app.buttons["home.menu"].tap()
            app.buttons[settings].firstMatch.tap()
            let version = app.buttons["settings.version"]
            reveal(version, in: app); version.tap()
            let rate = app.buttons["settings.rate"]
            reveal(rate, in: app); rate.tap()
            let store = app.descendants(matching: .any)["review.write"].firstMatch
            XCTAssertTrue(store.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(store.isHittable, "The explicit App Store link must be reachable")
            XCTAssertEqual(store.label, language == "zh-Hans" ? "去 App Store 好评" : "Review on the App Store")
            let review = XCTAttachment(screenshot: app.screenshot())
            review.name = "illustrated-review-\(appearance)"; review.lifetime = .keepAlways; add(review)
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["settings.rate"].waitForExistence(timeout: 5), "Back must return to About & Support")
            XCTAssertTrue(app.descendants(matching: .any)["version.website"].firstMatch.waitForExistence(timeout: 5))
            let about = XCTAttachment(screenshot: app.screenshot())
            about.name = "illustrated-version-\(appearance)"; about.lifetime = .keepAlways; add(about)
            app.terminate()
        }
    }

    func testUndoIsFirstAndRestoresWithoutLeavingEitherOverviewLayout() async throws {
        continueAfterFailure = false
        let prefix = "Undo \(UUID().uuidString)"
        let pages = ["grouped", "carousel"]
        let server = try DownloadPlaybackHTTPFixture(files: Dictionary(uniqueKeysWithValues: pages.map { page in
            ("/undo-\(page)", Data("<title>\(prefix) \(page)</title><h1>\(prefix) \(page)</h1>".utf8))
        }))
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        defer { app.terminate() }
        for grouped in [true, false] {
            let page = grouped ? "grouped" : "carousel"
            let title = "\(prefix) \(page)"
            app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "NO",
                "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO",
                "-icloud_sync_enabled", "NO", "-wallpaper_source", "gradient",
                "-tab_overview_grouped", grouped ? "YES" : "NO"]
            app.open(root.appendingPathComponent("undo-\(page)"))
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
            app.buttons["browser.tabs"].tap()
            XCTAssertTrue(app.buttons["tabs.done"].waitForExistence(timeout: 5))
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                "tabs.card.", title)).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 5), app.debugDescription)
            // The top tab strip and recent history also expose "Close Tab" /
            // the page title. Tap the actual card's close control, in both layouts.
            card.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0))
                .withOffset(CGVector(dx: -22, dy: 22)).tap()
            XCTAssertTrue(card.waitForNonExistence(timeout: 5))
            let undo = app.buttons["tabs.tab_restore_last"]
            let mode = app.buttons["tabs.view-mode"]
            XCTAssertTrue(undo.waitForExistence(timeout: 5))
            XCTAssertLessThan(undo.frame.midX, mode.frame.midX)
            XCTAssertEqual(undo.frame.midY, mode.frame.midY, accuracy: 1)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = grouped ? "grouped-undo-first-orange" : "carousel-undo-first-orange"
            shot.lifetime = .keepAlways; add(shot)
            undo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["tabs.done"].isHittable, "Undo must leave tab management open")
            XCTAssertTrue(card.waitForExistence(timeout: 5), "Restored tab must reappear in the overview")
            app.buttons["tabs.done"].tap()
            XCTAssertTrue(app.webViews.staticTexts[title].firstMatch.waitForExistence(timeout: 20))
            app.terminate()
        }
    }

    func testHiddenToolbarLockOpensTheSharedSitePanel() async throws {
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data("<meta name='viewport' content='width=device-width,initial-scale=1'><h1>Site panel fixture</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "YES", "-keep_fullscreen_browsing", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Site panel fixture"].waitForExistence(timeout: 10))
        app.buttons["More"].firstMatch.tap()
        let lock = app.buttons["browser.hiddenSiteInformation"]
        XCTAssertTrue(lock.waitForExistence(timeout: 5), app.debugDescription)
        lock.tap()
        XCTAssertTrue(app.buttons["site.connection"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["site.user-agent"].exists)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Shared site information from the hidden toolbar lock"; shot.lifetime = .keepAlways; add(shot)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        XCTAssertTrue(app.buttons["site.user-agent"].waitForNonExistence(timeout: 3))
    }

    func testVideoSettingsAndTelegramFeedbackEntry() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "light", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-video.holdSpeed", "2"]
        app.launchArguments += ["-home_title", "Soulo QA \(UUID().uuidString)"]
        app.launch(); app.open(URL(string: "soulo://")!)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap(); app.buttons["设置"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
        }
        capture("Settings appearance and home icon columns")
        let video = app.buttons["settings.video"]
        reveal(video, in: app); video.tap()
        let holdSpeed = app.descendants(matching: .any)["video-settings.hold-speed"].firstMatch
        XCTAssertTrue(app.switches["video-settings.episode-dock"].waitForExistence(timeout: 5))
        XCTAssertTrue(holdSpeed.waitForExistence(timeout: 5))
        XCTAssertTrue(holdSpeed.label.contains("2") || (holdSpeed.value as? String)?.contains("2") == true, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["video-settings.player"].exists)
        capture("Video settings with automatic playback")
        app.navigationBars.buttons.firstMatch.tap()
        let backups = app.buttons["settings.backups"]
        reveal(backups, in: app); backups.tap()
        let save = app.buttons["settings.backups.save"]
        XCTAssertTrue(app.staticTexts["settings.backups.explanation"].exists)
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        let restoreButtons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore."))
        let existing = restoreButtons.allElementsBoundByIndex.map(\.identifier)
        save.tap()
        let copy = restoreButtons.matching(NSPredicate(format: "NOT (identifier IN %@)", existing)).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let identifier = copy.identifier
        reveal(copy, in: app)
        let menu = try XCTUnwrap(app.buttons.matching(identifier: "更多").allElementsBoundByIndex.first {
            $0.isHittable && abs($0.frame.midY - copy.frame.midY) < 12
        })
        menu.tap()
        let delete = app.buttons["删除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 3))
        app.alerts.buttons["删除"].tap()
        XCTAssertTrue(app.buttons[identifier].waitForNonExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()
        let version = app.buttons["settings.version"]
        reveal(version, in: app)
        capture("Settings other and support icon columns")
        version.tap()
        let feedback = app.buttons["settings.feedback"]
        reveal(feedback, in: app)
        feedback.tap()
        let telegram = app.descendants(matching: .any)["feedback.telegram"].firstMatch
        XCTAssertTrue(telegram.waitForExistence(timeout: 5))
        XCTAssertTrue(telegram.isHittable)
        XCTAssertTrue(app.staticTexts["加入群组，交流问题与建议。"].exists)
        capture("Feedback Telegram group entry")
        app.navigationBars["用户反馈"].buttons["取消"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let settingsTelegram = app.buttons["settings.telegram"]
        reveal(settingsTelegram, in: app)
        for _ in 0..<3 where settingsTelegram.frame.maxY > app.frame.maxY - 80 { app.swipeUp() }
        settingsTelegram.tap()
        XCTAssertTrue(app.staticTexts["settings.telegram.link"].waitForExistence(timeout: 5), app.debugDescription)
        capture("Settings Telegram group entry")
    }

    func testOverviewPlusReturnsHomeAndKeepsTheExistingTabCount() async throws {
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data("<h1>Keep this tab</h1>".utf8)])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch()
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("page").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        let tabs = app.buttons["browser.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), app.debugDescription)
        let countLabel = tabs.label
        tabs.tap()
        let home = app.buttons["tabs.browser_home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let dismissed = NSPredicate { _, _ in !app.otherElements["tabs.dock"].exists }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: dismissed, object: nil)], timeout: 5)
        XCTAssertTrue(app.buttons["home.menu"].isHittable, app.debugDescription)
        let homeTabs = app.descendants(matching: .any)["home.tabs"].firstMatch
        XCTAssertEqual(homeTabs.value as? String, countLabel.split(separator: " ").first.map(String.init), app.debugDescription)
    }

    func testBookmarkFromHomeOpensNewTabWithoutReplacingTheOriginalPage() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "bookmarks", returnHome: true)
    }

    func testHistoryFromBrowserOpensNewTabWithoutReplacingTheOriginalPage() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "history", returnHome: false)
    }

    func testHistoryFiltersForPagesWhereVideoToolsWereUsed() async throws {
        continueAfterFailure = false
        let token = UUID().uuidString.prefix(8)
        let marked = "Marked \(token)"
        let unmarked = "Unmarked \(token)"
        func page(_ title: String) -> Data {
            Data("""
                <meta name="viewport" content="width=device-width, initial-scale=1"><title>\(title)</title>
                <h1>\(title)</h1><video width="330" height="185" controls playsinline preload="metadata" src="/history.mp4"></video>
                """.utf8)
        }
        let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4"))
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/marked.html": page(marked), "/unmarked.html": page(unmarked), "/history.mp4": try Data(contentsOf: media)
        ], responseHeaders: ["/history.mp4": ["Content-Type": "video/mp4"]])
        let root = try await server.start()
        defer { server.stop() }
        server.releaseDownloads()
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO",
            "-soulo_primary_browser_window_id", UUID().uuidString, "-icloud_sync_enabled", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-privacy_clear_browsing_on_exit", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO",
            "-browser_toolbar_actions", "(home,bookmark,library,tabs)", "-video.showsWebTools", "YES"]
        app.launch()
        defer { app.terminate() }
        func open(_ url: URL, title: String) throws {
            var route = URLComponents()
            route.scheme = "soulo"; route.host = "open"
            route.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
            app.open(try XCTUnwrap(route.url))
            XCTAssertTrue(app.webViews.staticTexts[title].waitForExistence(timeout: 12), app.debugDescription)
        }
        let address = root.appendingPathComponent("marked.html")
        try open(address, title: marked)
        let tools = app.webViews.buttons["Video tools"].firstMatch
        XCTAssertTrue(tools.waitForExistence(timeout: 12), app.debugDescription)
        tools.tap()
        XCTAssertTrue(app.webViews.buttons["Fullscreen"].firstMatch.waitForExistence(timeout: 5))
        var revisit = try XCTUnwrap(URLComponents(url: address, resolvingAgainstBaseURL: false))
        revisit.queryItems = [URLQueryItem(name: "utm_source", value: "history-repeat")]
        try open(XCTUnwrap(revisit.url), title: marked)
        try open(root.appendingPathComponent("unmarked.html"), title: unmarked)
        XCTAssertTrue(tools.waitForExistence(timeout: 12))

        app.buttons["Library"].firstMatch.tap()
        let history = app.buttons["library.section.history"]
        XCTAssertTrue(history.waitForExistence(timeout: 6), app.debugDescription)
        history.tap()
        let markRows = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", marked + ","))
        let otherRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", unmarked + ",")).firstMatch
        XCTAssertTrue(otherRow.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertEqual(markRows.count, 1, "Revisiting the same page must keep only the latest row")
        let videoFilter = app.buttons["history.video-filter"]
        XCTAssertTrue(videoFilter.isHittable)
        videoFilter.tap()
        XCTAssertTrue(otherRow.waitForNonExistence(timeout: 4))
        XCTAssertEqual(markRows.count, 1)
        videoFilter.tap()
        XCTAssertTrue(otherRow.waitForExistence(timeout: 4))
    }

    func testBookmarkFromHomeReusesTheExplicitBlankTab() async throws {
        try await checkLibrarySelectionUsesSeparateTab(section: "bookmarks", returnHome: true, createBlank: true)
    }

    private func checkLibrarySelectionUsesSeparateTab(section: String, returnHome: Bool, createBlank: Bool = false) async throws {
        continueAfterFailure = false
        let token = UUID().uuidString.prefix(8)
        let savedTitle = "Saved \(token)"
        let originalTitle = "Original \(token)"
        let state = "Keep state \(token)"
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/saved.html": Data("<title>\(savedTitle)</title><h1>\(savedTitle)</h1>".utf8),
            "/original.html": Data("""
                <title>\(originalTitle)</title><h1>\(originalTitle)</h1>
                <input aria-label="Original note" onkeydown="if(event.key==='Enter'){this.blur();return false}">
                """.utf8)
        ])
        let root = try await server.start(); defer { server.stop() }
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-is_incognito", "NO",
            "-soulo_primary_browser_window_id", UUID().uuidString,
            "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO", "-show_top_tab_bar", "YES",
            "-browser_toolbar_actions", "(home,bookmark,library,tabs)"]
        if createBlank { app.launchArguments += ["-home_toolbar_actions", "(newTab)"] }
        app.launch(); defer { app.terminate() }
        var route = URLComponents(); route.scheme = "soulo"; route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: root.appendingPathComponent("saved.html").absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts[savedTitle].waitForExistence(timeout: 15), app.debugDescription)
        let tabs = app.buttons["browser.tabs"]
        if section == "bookmarks" {
            app.buttons["Bookmarks"].firstMatch.tap()
            XCTAssertTrue(app.buttons["bookmark.fill"].waitForExistence(timeout: 5))
        }
        app.buttons["Edit Address or Search"].firstMatch.tap()
        let address = app.textFields["addressEditor.query"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        app.buttons["addressEditor.clearQuery"].tap()
        address.tap(); address.typeText(root.appendingPathComponent("original.html").absoluteString + "\n")
        let note = app.webViews.textFields["Original note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 15), app.debugDescription)
        // Finish typing before sending the page's blur-on-Enter action, then
        // verify that the keyboard no longer covers the bottom toolbar.
        note.tap(); note.typeText(state)
        let returnKey = app.keyboards.buttons["Return"]
        guard returnKey.waitForExistence(timeout: 3) else {
            XCTFail("The page input must have its return key available")
            return
        }
        returnKey.tap()
        guard app.keyboards.firstMatch.waitForNonExistence(timeout: 5) else {
            XCTFail("Finish page input before tapping browser toolbar controls")
            return
        }
        // Restored simulator sessions can contain earlier tabs. Measure from the
        // occupied original document rather than assuming a single-tab session.
        let initialCount = try XCTUnwrap(Int(tabs.label.split(separator: " ").first.map(String.init) ?? ""))
        let expectedCount = initialCount + 1
        if createBlank {
            app.buttons["Home Screen"].firstMatch.tap()
            let newTab = app.buttons["home.toolbar.0"]
            guard newTab.waitForExistence(timeout: 5) else {
                XCTFail("The configured home New Tab control must be visible: \(app.debugDescription)")
                return
            }
            newTab.tap()
            XCTAssertTrue(tabs.waitForExistence(timeout: 5))
            XCTAssertEqual(tabs.label, "\(expectedCount) Tabs")
        }
        if returnHome {
            tabs.tap()
            app.buttons["tabs.browser_home"].tap()
            XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
            app.buttons["home.menu"].tap()
            let favorites = app.buttons["My Favorites"].firstMatch
            XCTAssertTrue(favorites.waitForExistence(timeout: 5), app.debugDescription)
            favorites.tap()
        } else {
            app.buttons["Library"].firstMatch.tap()
            let history = app.buttons["library.section.history"]
            guard history.waitForExistence(timeout: 5) else {
                XCTFail("Opening Library must reveal its History section: \(app.debugDescription)")
                return
            }
            history.tap()
        }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", savedTitle)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.webViews.staticTexts[savedTitle].waitForExistence(timeout: 15), app.debugDescription)
        // Clean only the bookmark created by this fixture, including on the pre-fix failure.
        if section == "bookmarks", app.buttons["bookmark.fill"].exists { app.buttons["Bookmarks"].firstMatch.tap() }
        XCTAssertEqual(tabs.label, "\(expectedCount) Tabs", "A library selection must preserve the occupied tab and reuse an explicit blank tab")
        guard tabs.label == "\(expectedCount) Tabs" else { return }
        let original = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", originalTitle + ", tab ")).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5), app.debugDescription)
        original.tap()
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.value as? String, state, "The original document must retain its live form state")
        app.buttons["Edit Address or Search"].firstMatch.tap()
        let pageURL = app.textFields["addressEditor.pageURL"]
        XCTAssertTrue(pageURL.waitForExistence(timeout: 5))
        XCTAssertEqual(pageURL.value as? String, root.appendingPathComponent("original.html").absoluteString)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Library preserves original \(section) blank-\(createBlank)"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func openSettings(_ app: XCUIApplication) {
        app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.toolbar"]
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }

    func testHomeToolbarDefaultsToButtonsAndOffersStorageAndMore() async throws {
        continueAfterFailure = false
        let server = try DownloadPlaybackHTTPFixture(files: ["/page": Data("<h1>Home toolbar fixture</h1>".utf8)])
        let page = try await server.start().appendingPathComponent("page")
        defer { server.stop() }
        let app = compactSettingsApp()
        app.launchArguments += ["-restore_last_page_on_launch", "NO", "-privacy_https_upgrade_enabled", "NO",
            "-is_incognito", "NO",
            "-home_toolbar_actions", "(settings)",
            "-home_toolbar_layout", "{ tabsPlacement = bottom; menuPlacement = bottom; }"]
        app.launch()
        defer { app.terminate() }
        var route = URLComponents()
        route.scheme = "soulo"
        route.host = "open"
        route.queryItems = [URLQueryItem(name: "url", value: page.absoluteString)]
        app.open(try XCTUnwrap(route.url))
        XCTAssertTrue(app.webViews.staticTexts["Home toolbar fixture"].waitForExistence(timeout: 12), app.debugDescription)

        let home = try XCTUnwrap(URL(string: "soulo://"))
        app.open(home)
        let settingsButton = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        settingsButton.tap()
        let toolbar = app.buttons["settings.toolbar"]
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5))
        toolbar.tap()

        let buttons = app.buttons["home-toolbar.editor.buttons"]
        let visibility = app.buttons["home-toolbar.editor.visibility"]
        let position = app.buttons["home-toolbar.editor.position"]
        XCTAssertTrue(buttons.waitForExistence(timeout: 5))
        XCTAssertTrue(buttons.isSelected)
        XCTAssertTrue(app.buttons["home-toolbar.style.tiles"].isHittable)
        XCTAssertLessThan(buttons.frame.midX, visibility.frame.midX)
        XCTAssertLessThan(visibility.frame.midX, position.frame.midX)
        compactSettingsCapture(app, name: "home-toolbar-buttons-default")

        position.tap()
        XCTAssertTrue(app.buttons["home-toolbar.search-position.bottom"].exists)
        XCTAssertFalse(app.buttons["home-toolbar.tabs-position.top"].exists)
        XCTAssertFalse(app.buttons["home-toolbar.menu-position.bottom"].exists)
        let previewTabs = app.descendants(matching: .any)["home-toolbar.preview.tabs"].firstMatch
        let previewMenu = app.descendants(matching: .any)["home-toolbar.preview.menu"].firstMatch
        let previewSlot = app.buttons["home-toolbar.slot.0"]
        XCTAssertTrue(previewTabs.exists && previewMenu.exists)
        XCTAssertEqual(previewTabs.frame.midY, previewMenu.frame.midY, accuracy: 2)
        XCTAssertLessThan(previewMenu.frame.midY, previewSlot.frame.midY)
        compactSettingsCapture(app, name: "home-toolbar-position-options")

        buttons.tap()
        for (slot, action) in [(1, "storage"), (2, "more")] {
            let add = app.buttons["home-toolbar.slot.\(slot)"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            let choice = app.buttons["home-toolbar.action." + action]
            let filter = app.textFields["home-toolbar.action-search"]
            XCTAssertTrue(filter.waitForExistence(timeout: 5))
            let list = app.scrollViews["home-toolbar.action-list"]
            XCTAssertTrue(list.waitForExistence(timeout: 5))
            let filterTop = filter.frame.minY
            for _ in 0..<8 where !choice.isHittable { list.swipeUp(velocity: .slow) }
            XCTAssertTrue(choice.isHittable)
            XCTAssertEqual(filter.frame.minY, filterTop, accuracy: 1)
            XCTAssertLessThan(filter.frame.maxY, choice.frame.minY)
            choice.tap()
            XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
        }
        let save = app.buttons["home-toolbar.save"]
        save.tap()
        let notice = app.descendants(matching: .any)["toolbar.saved"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertTrue(notice.waitForNonExistence(timeout: 8))
        XCTAssertTrue(save.isHittable)
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars["Settings"].buttons["Done"].tap()

        let menu = app.buttons["home.menu"]
        let tabs = app.descendants(matching: .any)["home.tabs"].firstMatch
        let storage = app.buttons["home.toolbar.1"]
        XCTAssertTrue(storage.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.exists && tabs.exists)
        XCTAssertEqual(menu.frame.midY, tabs.frame.midY, accuracy: 2)
        XCTAssertLessThan(menu.frame.midY, storage.frame.midY)
        storage.tap()
        let storagePage = app.navigationBars["Storage"]
        XCTAssertTrue(storagePage.waitForExistence(timeout: 5))
        storagePage.buttons["Done"].tap()

        let more = app.buttons["home.toolbar.2"]
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        let extensions = app.buttons["Scripts & Extensions"].firstMatch
        XCTAssertTrue(extensions.waitForExistence(timeout: 5))
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testHomeToolbarPreviewKeepsFreeToolbarClearAndPanelsEqual() throws {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launchArguments += ["-restore_last_page_on_launch", "NO", "-home_toolbar_actions", "(settings,wallpaper,search)",
            "-home_toolbar_layout", "{style=capsule;placement=free;}",
            "-home_title", "Soulo", "-home_subtitle", "Search anytime, anywhere.",
            "-show_bookmarks_on_home", "YES", "-show_recent_searches_on_home", "YES"]
        app.launch()
        defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        entry.tap()
        let editor = app.buttons["settings.toolbar"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let panel = app.scrollViews["home-toolbar.content"]
        let preview = app.descendants(matching: .any)["home-toolbar.preview"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.exists)
        let panelFrame = panel.frame
        let previewFrame = preview.frame
        XCTAssertLessThanOrEqual(panelFrame.height, 176)
        for tab in ["position", "visibility", "buttons"] {
            app.buttons["home-toolbar.editor." + tab].tap()
            XCTAssertEqual(panel.frame.minY, panelFrame.minY, accuracy: 1)
            XCTAssertEqual(panel.frame.height, panelFrame.height, accuracy: 1)
            XCTAssertEqual(preview.frame.maxY, previewFrame.maxY, accuracy: 1)
        }

        app.buttons["home-toolbar.editor.visibility"].tap()
        let searchToggle = app.buttons["home-toolbar.visibility.search"]
        if searchToggle.isSelected { searchToggle.tap() }
        XCTAssertFalse(searchToggle.isSelected)
        let tileRows = [["tabs", "menu", "title", "subtitle"], ["search", "bookmarks", "recentSearches", "liveActivity"]]
        for row in tileRows {
            let frames = row.map { app.buttons["home-toolbar.visibility." + $0].frame }
            for frame in frames {
                XCTAssertEqual(frame.height, searchToggle.frame.height, accuracy: 0.5)
                XCTAssertEqual(frame.minY, frames[0].minY, accuracy: 0.5)
                XCTAssertTrue(panel.frame.insetBy(dx: -1, dy: -1).contains(frame))
            }
        }
        func sample(_ name: String) -> XCUIElement {
            app.descendants(matching: .any)["home-toolbar.preview." + name].firstMatch
        }
        let heading = sample("heading")
        app.buttons["home-toolbar.editor.position"].tap()
        XCTAssertTrue(app.buttons["home-toolbar.position.free"].isSelected)
        let handle = app.descendants(matching: .any)["home-toolbar.drag"].firstMatch
        let origin = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        origin.press(forDuration: 0.06, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: heading.frame.midY - handle.frame.midY)))
        XCTAssertFalse(handle.frame.intersects(heading.frame))

        app.buttons["home-toolbar.editor.visibility"].tap()
        let toolbar = app.buttons["home-toolbar.slot.1"]
        let bookmarks = sample("bookmarks")
        let recent = sample("recentSearches")
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(heading.exists && bookmarks.exists && recent.exists)
        XCTAssertFalse(sample("search").exists)
        XCTAssertFalse(toolbar.frame.intersects(heading.frame))
        XCTAssertFalse(toolbar.frame.intersects(bookmarks.frame))
        XCTAssertFalse(toolbar.frame.intersects(recent.frame))
        XCTAssertGreaterThanOrEqual(preview.frame.maxY - recent.frame.maxY, 8)
        compactSettingsCapture(app, name: "home-toolbar-preview-with-hidden-search")
        searchToggle.tap()
        let search = sample("search")
        XCTAssertTrue(search.exists)
        XCTAssertTrue(toolbar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(toolbar.frame.intersects(search.frame))
        XCTAssertFalse(toolbar.frame.intersects(recent.frame))
    }

    func testHomeVisibilityKeepsPreviewFixedAndSharesSettingsAndSearch() throws {
        continueAfterFailure = false
        let app = compactSettingsApp()
        app.launchArguments += ["-show_group_picker_on_home", "YES"]
        app.launch()
        defer { app.terminate() }
        let home = try XCTUnwrap(URL(string: "soulo://"))
        app.open(home)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["International"].exists)
        openSettings(app)

        let visibility = app.buttons["home-toolbar.editor.visibility"]
        let searchPosition = app.buttons["home-toolbar.search-position.center"]
        app.buttons["home-toolbar.editor.position"].tap()
        XCTAssertTrue(searchPosition.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["home-toolbar.editor.style"].exists)
        XCTAssertLessThan(visibility.frame.maxY, searchPosition.frame.minY)
        searchPosition.tap()
        visibility.tap()

        let list = app.scrollViews["home-toolbar.content"]
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        let pageHeading = list.staticTexts["home_toolbar_visibility_page"]
        let searchHeading = list.staticTexts["home_toolbar_visibility_search_area"]
        XCTAssertEqual(pageHeading.label, "Home Elements")
        XCTAssertEqual(searchHeading.label, "Search Area")
        compactSettingsCapture(app, name: "home-toolbar-visibility-page")
        let listTop = list.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.32))
        let listBottom = list.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.72))
        func show(_ item: String) -> XCUIElement {
            let tile = app.buttons["home-toolbar.visibility." + item]
            for _ in 0..<10 {
                if tile.exists && tile.isHittable && list.frame.insetBy(dx: -1, dy: -1).contains(tile.frame) { return tile }
                if tile.exists && tile.frame.midY < list.frame.midY {
                    listTop.press(forDuration: 0.03, thenDragTo: listBottom, withVelocity: .slow, thenHoldForDuration: 0.15)
                } else {
                    listBottom.press(forDuration: 0.03, thenDragTo: listTop, withVelocity: .slow, thenHoldForDuration: 0.15)
                }
            }
            XCTAssertTrue(tile.isHittable, app.debugDescription)
            return tile
        }
        func setVisibility(_ item: String, shown: Bool) {
            let tile = show(item)
            if tile.isSelected != shown { tile.tap() }
            XCTAssertEqual(tile.isSelected, shown)
        }
        func saveAndReturn() {
            app.buttons["home-toolbar.save"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
            app.open(home)
        }

        func preview(_ item: String) -> XCUIElement {
            app.descendants(matching: .any)["home-toolbar.preview." + item].firstMatch
        }
        let hadRecentSearches = show("recentSearches").isSelected
        setVisibility("search", shown: true)
        setVisibility("bookmarks", shown: true)
        setVisibility("recentSearches", shown: true)
        let searchTile = app.buttons["home-toolbar.visibility.search"]
        let bookmarksTile = app.buttons["home-toolbar.visibility.bookmarks"]
        XCTAssertLessThan(searchHeading.frame.midY, searchTile.frame.midY)
        XCTAssertEqual(searchTile.frame.midY, bookmarksTile.frame.midY, accuracy: 1)
        XCTAssertLessThan(searchTile.frame.maxX, bookmarksTile.frame.minX)
        let topItems = ["tabs", "menu", "title"]
        let bottomItems = ["search", "bookmarks", "recentSearches"]
        for (top, bottom) in zip(topItems, bottomItems) {
            let upperFrame = app.buttons["home-toolbar.visibility." + top].frame
            let lowerFrame = app.buttons["home-toolbar.visibility." + bottom].frame
            XCTAssertEqual(upperFrame.minX, lowerFrame.minX, accuracy: 1)
            XCTAssertEqual(upperFrame.width, lowerFrame.width, accuracy: 1)
            XCTAssertEqual(upperFrame.height, lowerFrame.height, accuracy: 1)
        }
        XCTAssertFalse(preview("groups").exists)
        XCTAssertTrue(preview("bookmarks").label.contains("GitHub"))
        XCTAssertTrue(preview("recentSearches").label.contains("SwiftUI"))
        XCTAssertEqual(preview("bookmarks").frame.minX, preview("search").frame.minX, accuracy: 2)
        XCTAssertEqual(preview("bookmarks").frame.minX, preview("recentSearches").frame.minX, accuracy: 2)
        let scale = preview("search").frame.height / 46
        XCTAssertEqual(preview("bookmarks").frame.minY - preview("search").frame.maxY, 16 * scale, accuracy: 2)
        compactSettingsCapture(app, name: "home-toolbar-preview-examples")
        setVisibility("bookmarks", shown: false)
        XCTAssertFalse(preview("bookmarks").exists)
        setVisibility("bookmarks", shown: true)
        XCTAssertTrue(preview("bookmarks").exists)
        XCTAssertTrue(preview("recentSearches").exists)
        setVisibility("recentSearches", shown: hadRecentSearches)

        setVisibility("search", shown: false)
        let sectionY = visibility.frame.midY
        _ = show("recentSearches")
        XCTAssertEqual(visibility.frame.midY, sectionY, accuracy: 2)
        XCTAssertTrue(visibility.isHittable)
        for item in ["toolbar", "wallpaper", "quickSearch", "suggestions", "voice", "groups"] {
            XCTAssertFalse(app.buttons["home-toolbar.visibility." + item].exists)
        }
        compactSettingsCapture(app, name: "home-toolbar-pinned-visibility")
        saveAndReturn()

        let search = app.textFields["search.query"]
        let menu = app.buttons["home.menu"]
        let keyboard = app.keyboards.firstMatch
        XCTAssertFalse(search.exists)
        XCTAssertTrue(menu.waitForExistence(timeout: 8))
        // Start on the wallpaper to avoid competing with the text field's own selection gestures.
        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.49))
        let lower = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.72))
        middle.press(forDuration: 0.04, thenDragTo: lower)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "A downward swipe should reveal search")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        search.typeText("Swipe draft")
        let upper = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.28))
        upper.press(forDuration: 0.04, thenDragTo: lower)
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5), "Scrolling should dismiss the keyboard")
        XCTAssertTrue(search.isHittable)
        XCTAssertEqual(search.value as? String, "Swipe draft")
        search.tap()
        search.typeText(" survives")
        XCTAssertEqual(search.value as? String, "Swipe draft survives")
        middle.press(forDuration: 0.04, thenDragTo: upper)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Swiping back up should close temporary search")
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))

        lower.press(forDuration: 0.04, thenDragTo: middle)
        XCTAssertTrue(search.waitForExistence(timeout: 5), "An upward swipe should reveal search")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        XCTAssertEqual(search.value as? String, "Swipe draft survives")
        upper.press(forDuration: 0.04, thenDragTo: lower)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5), "Swiping back down should close temporary search")
        XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        app.open(home)
        XCTAssertTrue(search.waitForNonExistence(timeout: 6))

        menu.tap()
        let searchAction = app.buttons["home.menu.search"].firstMatch
        XCTAssertTrue(searchAction.waitForExistence(timeout: 5), app.debugDescription)
        searchAction.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.typeText("Soulo QA")
        XCTAssertEqual(search.value as? String, "Soulo QA")
        app.open(home)
        XCTAssertTrue(search.waitForNonExistence(timeout: 6), app.debugDescription)

        openSettings(app)
        visibility.tap()
        XCTAssertTrue(show("bookmarks").isSelected)
        setVisibility("bookmarks", shown: false)
        setVisibility("menu", shown: false)
        _ = show("search")
        compactSettingsCapture(app, name: "home-toolbar-visibility-hints")
        saveAndReturn()

        XCTAssertFalse(menu.exists)
        let recovery = app.descendants(matching: .any)["home.menu.recovery"].firstMatch
        XCTAssertTrue(recovery.waitForExistence(timeout: 5), app.debugDescription)
        let blankSpace = recovery.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.18))
        blankSpace.press(forDuration: 0.7)
        XCTAssertTrue(searchAction.waitForExistence(timeout: 5), app.debugDescription)
        searchAction.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        app.open(home)
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        blankSpace.press(forDuration: 0.7)
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()
        let toolbar = app.buttons["settings.toolbar"]
        reveal(toolbar, in: app); toolbar.tap()
        visibility.tap()
        setVisibility("menu", shown: true)
        setVisibility("search", shown: true)
        saveAndReturn()
    }

    func testFiveHomeShortcutsPersistAndOpenTheirPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        openSettings(app)
        let buttons = app.buttons["home-toolbar.editor.buttons"]
        func chooseStyle(_ value: String, title: String) {
            let choice = app.buttons["home-toolbar.style." + value]
            XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertEqual(choice.label, title)
            choice.tap()
            XCTAssertTrue(choice.isSelected)
        }
        buttons.tap()
        chooseStyle("tiles", title: "Separate")
        let actions = ["downloads", "files", "bookmarks", "history", "wallpaper"]
        for (index, action) in actions.enumerated() {
            app.buttons["home-toolbar.slot.\(index)"].tap()
            app.buttons["home-toolbar.action.\(action)"].tap()
        }
        app.buttons["home-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.toolbar.0"].waitForExistence(timeout: 5), app.debugDescription)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "five-home-framed-shortcuts"; shot.lifetime = .keepAlways; add(shot)
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        for (index, section) in actions.prefix(4).enumerated() {
            let button = app.buttons["home.toolbar.\(index)"]
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            button.tap()
            let tab = app.buttons["library.section.\(section)"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(tab.isSelected)
            app.navigationBars.buttons.firstMatch.tap()
        }
        let fifth = app.buttons["home.toolbar.4"]
        XCTAssertTrue(fifth.waitForExistence(timeout: 5)); XCTAssertTrue(fifth.isHittable)
        XCTAssertGreaterThanOrEqual(fifth.frame.minX, 0)
        XCTAssertLessThanOrEqual(fifth.frame.maxX, app.frame.width)
        fifth.tap()
        let appearance = app.navigationBars["Wallpaper"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["wallpaper.sources"].firstMatch.waitForExistence(timeout: 5))
        appearance.buttons["Done"].tap()
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "home-shortcuts-after-presentations"; returned.lifetime = .keepAlways; add(returned)
        openSettings(app)
        buttons.tap()
        XCTAssertTrue(app.buttons["home-toolbar.style.tiles"].isSelected)
        chooseStyle("icons", title: "Icons only")
        let setting = XCTAttachment(screenshot: app.screenshot())
        setting.name = "home-toolbar-background-setting"; setting.lifetime = .keepAlways; add(setting)
        app.buttons["home-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        let plain = XCTAttachment(screenshot: app.screenshot())
        plain.name = "five-home-plain-shortcuts"; plain.lifetime = .keepAlways; add(plain)
        openSettings(app)
        buttons.tap()
        XCTAssertTrue(app.buttons["home-toolbar.style.icons"].isSelected)
        app.buttons["toolbar.restore"].tap()
        app.alerts.buttons["Restore Defaults"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
        XCTAssertFalse(app.buttons["home.toolbar.4"].exists)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, downward: Bool = false) {
        let save = app.buttons["home-toolbar.save"]
        for _ in 0..<8 {
            let bottom = save.exists ? save.frame.minY - 12 : app.frame.maxY - 40
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 4 : app.frame.minY
            if element.exists && element.isHittable && (!save.exists || (element.frame.minY >= top && element.frame.maxY <= bottom)) { return }
            if downward { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
    }

    private func assertFourColumns(_ app: XCUIApplication, prefix: String, firstRow: [String], next: String) {
        let cells = firstRow.map { app.buttons[prefix + $0] }
        XCTAssertTrue(cells[0].waitForExistence(timeout: 5), app.debugDescription)
        for (index, cell) in cells.enumerated() {
            XCTAssertTrue(cell.exists)
            XCTAssertEqual(cell.frame.midY, cells[0].frame.midY, accuracy: 2)
            XCTAssertGreaterThanOrEqual(cell.frame.minX, 0)
            XCTAssertLessThanOrEqual(cell.frame.maxX, app.frame.width)
            if index > 0 { XCTAssertGreaterThan(cell.frame.minX, cells[index-1].frame.minX) }
        }
        XCTAssertGreaterThan(app.buttons[prefix + next].frame.minY, cells[0].frame.maxY)
    }

    func testSettingsLayoutWebsiteEntryAndRemovedCosmeticStatistics() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-icloud_sync_enabled", "NO"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let appearance = XCTAttachment(screenshot: app.screenshot())
        appearance.name = "settings-aligned-appearance-rows"; appearance.lifetime = .keepAlways; add(appearance)
        let toolbar = app.buttons["settings.toolbar"]
        reveal(toolbar, in: app); toolbar.tap()
        app.buttons["home-toolbar.slot.0"].tap()
        let normalHeight = app.buttons["home-toolbar.action.downloads"].frame.height
        let longTitle = app.buttons["home-toolbar.action.urlSchemes"]
        reveal(longTitle, in: app)
        XCTAssertEqual(longTitle.frame.height, normalHeight, accuracy: 1)
        XCTAssertEqual(longTitle.frame.height, app.buttons["home-toolbar.action.quickActions"].frame.height, accuracy: 1)
        let cards = XCTAttachment(screenshot: app.screenshot())
        cards.name = "toolbar-long-titles-uniform-height"; cards.lifetime = .keepAlways; add(cards)
        app.navigationBars.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        let version = app.buttons["settings.version"]
        reveal(version, in: app); version.tap()
        let website = app.buttons["version.website"]
        XCTAssertTrue(website.waitForExistence(timeout: 5), app.debugDescription)
        let about = XCTAttachment(screenshot: app.screenshot())
        about.name = "version-soulo-website-entry"; about.lifetime = .keepAlways; add(about)
        website.tap()
        let storeLink = app.webViews.links.matching(NSPredicate(format: "label CONTAINS[c] %@", "App Store")).firstMatch
        XCTAssertTrue(storeLink.waitForExistence(timeout: 25), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap(); app.navigationBars.buttons.firstMatch.tap()
        let adFiltering = app.buttons["settings.protection"]
        reveal(adFiltering, in: app, downward: true); adFiltering.tap()
        XCTAssertTrue(app.switches["adBlock.enabled"].waitForExistence(timeout: 5))
        app.swipeUp()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "adBlock.statistics").firstMatch.exists)
        let filtering = XCTAttachment(screenshot: app.screenshot())
        filtering.name = "ad-filtering-without-cosmetic-counts"; filtering.lifetime = .keepAlways; add(filtering)
    }

    func testDirectWallpaperChangeAndMatchingFourColumnPickers() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "dawn", "-wallpaper_refresh_interval", "0", "-wallpaper_favorites", "", "-wallpaper_only_favorites", "NO"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        openSettings(app)
        app.buttons["home-toolbar.slot.0"].tap()
        assertFourColumns(app, prefix: "home-toolbar.action.", firstRow: ["none", "downloads", "files", "bookmarks"], next: "history")
        let homePicker = XCTAttachment(screenshot: app.screenshot())
        homePicker.name = "home-toolbar-four-columns"; homePicker.lifetime = .keepAlways; add(homePicker)
        app.navigationBars.buttons["Cancel"].tap()
        for (index, action) in ["refreshWallpaper", "wallpaper", "version", "homeToolbar", "browserToolbar"].enumerated() {
            let slot = app.buttons["home-toolbar.slot.\(index)"]
            reveal(slot, in: app, downward: true); slot.tap()
            let choice = app.buttons["home-toolbar.action." + action]
            reveal(choice, in: app); choice.tap()
            XCTAssertTrue(choice.waitForNonExistence(timeout: 5))
        }
        app.buttons["home-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["Done"].firstMatch.tap()
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.toolbar.1"].waitForExistence(timeout: 10))
        app.buttons["home.toolbar.0"].tap()
        XCTAssertTrue(app.buttons["home.menu"].exists, "Changing wallpaper stays on the home page")
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "home-wallpaper-changed-borderless-buttons"; changed.lifetime = .keepAlways; add(changed)
        app.buttons["home.toolbar.1"].tap()
        let nextGradient = app.buttons["wallpaper.gradient.deep_sea"]
        reveal(nextGradient, in: app)
        XCTAssertTrue(nextGradient.isSelected, app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.2"].tap()
        XCTAssertTrue(app.navigationBars["About & Feedback"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.4"].tap()
        assertFourColumns(app, prefix: "browser-toolbar.action.", firstRow: ["none", "home", "back", "forward"], next: "tabs")
        app.buttons["browser-toolbar.action.none"].tap()
        XCTAssertTrue(app.buttons["browser-toolbar.action.none"].isSelected)
        let browserPicker = XCTAttachment(screenshot: app.screenshot())
        browserPicker.name = "browser-toolbar-four-columns"; browserPicker.lifetime = .keepAlways; add(browserPicker)
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.3"].tap()
        app.buttons["home-toolbar.slot.0"].tap()
        XCTAssertTrue(app.buttons["home-toolbar.action.refreshWallpaper"].isSelected)
        app.navigationBars.buttons["Cancel"].tap()
        app.buttons["toolbar.restore"].tap(); app.alerts.buttons["Restore Defaults"].tap()
        app.buttons["home-toolbar.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["toolbar.saved"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
    }

}
