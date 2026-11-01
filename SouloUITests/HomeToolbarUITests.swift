import XCTest

@MainActor
final class HomeToolbarUITests: XCTestCase {
    private func openSettings(_ app: XCUIApplication) {
        app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
        let entry = app.buttons["settings.homeToolbar"]
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()
    }
    func testFiveHomeShortcutsPersistAndOpenTheirPages() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US", "-appearance", "dark", "-wallpaper_source", "gradient", "-wallpaper_gradient_id", "dawn"]
        app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10))
        openSettings(app)
        let background = app.switches["home-toolbar.background"].firstMatch
        XCTAssertTrue(background.waitForExistence(timeout: 5), app.debugDescription)
        if background.value as? String != "1" {
            background.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(background.value as? String, "1")
        let actions = ["downloads", "files", "bookmarks", "history", "wallpaper"]
        for (index, action) in actions.enumerated() {
            app.buttons["home-toolbar.slot.\(index)"].tap()
            app.buttons["home-toolbar.action.\(action)"].tap()
        }
        app.buttons["home-toolbar.save"].tap()
        app.alerts.buttons["Done"].tap()
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
        XCTAssertTrue(app.navigationBars["Wallpaper"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Done"].firstMatch.tap()
        let returned = XCTAttachment(screenshot: app.screenshot())
        returned.name = "home-shortcuts-after-presentations"; returned.lifetime = .keepAlways; add(returned)
        openSettings(app)
        let restoredBackground = app.switches["home-toolbar.background"].firstMatch
        XCTAssertEqual(restoredBackground.value as? String, "1")
        restoredBackground.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(restoredBackground.value as? String, "0")
        let setting = XCTAttachment(screenshot: app.screenshot())
        setting.name = "home-toolbar-background-setting"; setting.lifetime = .keepAlways; add(setting)
        app.buttons["home-toolbar.save"].tap()
        app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        let plain = XCTAttachment(screenshot: app.screenshot())
        plain.name = "five-home-plain-shortcuts"; plain.lifetime = .keepAlways; add(plain)
        openSettings(app)
        XCTAssertEqual(app.switches["home-toolbar.background"].firstMatch.value as? String, "0")
        app.buttons["Hide All"].firstMatch.tap()
        app.sheets.buttons["Hide All"].tap()
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
        XCTAssertTrue(app.switches["settings.keepScreenAwake"].waitForExistence(timeout: 5))
        let appearance = XCTAttachment(screenshot: app.screenshot())
        appearance.name = "settings-aligned-appearance-rows"; appearance.lifetime = .keepAlways; add(appearance)
        let toolbar = app.buttons["settings.homeToolbar"]
        reveal(toolbar, in: app); toolbar.tap()
        let normalHeight = app.buttons["home-toolbar.action.downloads"].frame.height
        let longTitle = app.buttons["home-toolbar.action.urlSchemes"]
        reveal(longTitle, in: app)
        XCTAssertEqual(longTitle.frame.height, normalHeight, accuracy: 1)
        XCTAssertEqual(longTitle.frame.height, app.buttons["home-toolbar.action.quickActions"].frame.height, accuracy: 1)
        let cards = XCTAttachment(screenshot: app.screenshot())
        cards.name = "toolbar-long-titles-uniform-height"; cards.lifetime = .keepAlways; add(cards)
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
        let adFiltering = app.buttons["Ad Blocking"].firstMatch
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
        assertFourColumns(app, prefix: "home-toolbar.action.", firstRow: ["none", "downloads", "files", "bookmarks"], next: "history")
        let background = app.switches["home-toolbar.background"].firstMatch
        let originalBackground = background.value as? String
        if originalBackground != "1" { background.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        let homePicker = XCTAttachment(screenshot: app.screenshot())
        homePicker.name = "home-toolbar-four-columns"; homePicker.lifetime = .keepAlways; add(homePicker)
        for (index, action) in ["refreshWallpaper", "wallpaper", "help", "homeToolbar", "browserToolbar"].enumerated() {
            let slot = app.buttons["home-toolbar.slot.\(index)"]
            reveal(slot, in: app, downward: true); slot.tap()
            XCTAssertTrue(slot.isSelected)
            let choice = app.buttons["home-toolbar.action." + action]
            reveal(choice, in: app); choice.tap()
            XCTAssertTrue(choice.isSelected, "The selected action must be assigned before saving")
        }
        app.buttons["home-toolbar.save"].tap(); app.alerts.buttons["Done"].tap()
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["Done"].firstMatch.tap()
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        XCTAssertTrue(app.buttons["home.toolbar.1"].waitForExistence(timeout: 10))
        app.buttons["home.toolbar.1"].tap()
        let randomSources = app.switches["wallpaper.randomSources"].firstMatch
        reveal(randomSources, in: app)
        let originalRandom = randomSources.value as? String
        if originalRandom == "1" { randomSources.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.0"].tap()
        XCTAssertTrue(app.buttons["home.menu"].exists, "Changing wallpaper stays on the home page")
        let changed = XCTAttachment(screenshot: app.screenshot())
        changed.name = "home-wallpaper-changed-borderless-buttons"; changed.lifetime = .keepAlways; add(changed)
        app.buttons["home.toolbar.1"].tap()
        let nextGradient = app.buttons["wallpaper.gradient.deep_sea"]
        reveal(nextGradient, in: app)
        XCTAssertTrue(nextGradient.isSelected, app.debugDescription)
        if originalRandom == "1" {
            reveal(randomSources, in: app, downward: true)
            randomSources.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        app.buttons["Done"].firstMatch.tap()
        app.buttons["home.toolbar.2"].tap()
        XCTAssertTrue(app.navigationBars["Help Center"].waitForExistence(timeout: 5), app.debugDescription)
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
        let restoredBackground = app.switches["home-toolbar.background"].firstMatch
        if restoredBackground.value as? String != originalBackground {
            restoredBackground.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        app.buttons["Hide All"].firstMatch.tap(); app.sheets.buttons["Hide All"].tap()
        app.buttons["home-toolbar.save"].tap(); app.alerts.buttons["Done"].tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["home.toolbar.0"].exists)
    }

}
