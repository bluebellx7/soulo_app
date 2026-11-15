import XCTest
import Network

/// Does not depend on XCUIApplication.open, so the boundary runner can also
/// exercise the shipping app's minimum OS (iOS 16.0).
@MainActor
final class SettingsNavigationUITests: XCTestCase {
    func testSettingsBackupRestoreReturnsToInteractiveList() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Settings Backups")
        app.buttons["Settings Backups"].firstMatch.tap()
        let save = app.buttons["settings.backups.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 8)); save.tap()
        let restore = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.backups.restore.")).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
        let confirm = app.alerts.buttons["Restore"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); let start = Date(); confirm.tap()
        let interactive = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [interactive], timeout: 10), .completed)
        print("BACKUP RESTORE UI elapsed \(Date().timeIntervalSince(start))s")
        save.tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "configuration-backup-restored-interactive"; shot.lifetime = .keepAlways; add(shot)
    }

    func testStorageBulkCleanupDefaultsExcludeSavedContent() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launch(); defer { app.terminate() }
        app.buttons["home.toolbar.0"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap()
        let entry = app.buttons["storage.cleanup"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let safe = app.buttons["storage.cleanup.choice.webData"]
        XCTAssertTrue(safe.waitForExistence(timeout: 5)); XCTAssertEqual(safe.value as? String, "1")
        let saved = app.buttons["storage.cleanup.choice.backups"]
        for _ in 0..<8 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); XCTAssertEqual(saved.value as? String, "0"); saved.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: saved)], timeout: 3), .completed)
        let execute = app.buttons["storage.cleanup.execute"]
        XCTAssertFalse(execute.isEnabled)
        let field = app.textFields["storage.cleanup.confirmation"]
        for _ in 0..<4 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("CLEA")
        XCTAssertFalse(execute.isEnabled); field.typeText("R"); XCTAssertTrue(execute.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "storage-cleanup-explicit-saved-data"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
    }

    func testCompactBrowserPopoversStayAnchoredAndContentSized() async throws {
        let server = try AdSettingsPageFixture(); let url = try await server.start(); defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false)
        app.launchArguments += ["-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch(); defer { app.terminate() }
        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap(); query.typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Ad settings page fixture"].firstMatch.waitForExistence(timeout: 20))
        for (entry, child, name) in [("browser.siteInformation", "site.user-agent", "site-information"), ("browser.more", "browser.moreMenu.pageTools", "more-menu")] {
            let button = app.buttons[entry].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 8)); button.tap()
            let item = app.buttons[child].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
            if #unavailable(iOS 16.4) {
                let host = app.descendants(matching: .any).matching(identifier: "soulo.legacy-popover").firstMatch
                XCTAssertTrue(host.waitForExistence(timeout: 5)); XCTAssertLessThan(host.frame.height, app.frame.height * 0.82)
            }
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "compact-popover-" + name; shot.lifetime = .keepAlways; add(shot)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.15)).tap()
        }
    }

    func testHomeTitleAndSubtitleCanRestoreTheirDefaults() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Home")
        let home = app.buttons["settings.homeDisplay"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5)); home.tap()
        for (id, expected) in [("title", "Soulo"), ("subtitle", "Search anytime, anywhere.")] {
            let row = app.buttons["settings.homeDisplay." + id]
            XCTAssertTrue(row.waitForExistence(timeout: 5)); row.tap()
            let input = app.alerts.textFields.firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
            let value = input.value as? String ?? ""
            input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count) + "Custom QA " + id)
            app.alerts.buttons["Save"].tap()
            XCTAssertTrue(row.label.contains("Custom QA " + id)); row.tap()
            let restore = app.alerts.buttons["Reset to Defaults"]
            XCTAssertTrue(restore.waitForExistence(timeout: 5)); restore.tap()
            XCTAssertTrue(row.label.contains(expected), row.label)
        }
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "home-branding-defaults-restored"; image.lifetime = .keepAlways; add(image)
    }

    func testClearBookmarksRequiresTypedConfirmationAndCanBeCanceled() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO"]
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"; app.launchEnvironment["SOULO_ACCEPTANCE_BOOKMARKS"] = "1"
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Privacy")
        app.buttons.matching(NSPredicate(format: "label IN %@", ["Privacy", "Privacy Settings"])).firstMatch.tap()
        let clear = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Clear All Bookmarks")).firstMatch
        for _ in 0..<8 where !clear.isHittable { app.swipeUp() }
        XCTAssertTrue(clear.waitForExistence(timeout: 5)); clear.tap()
        let field = app.textFields["privacy.clear-bookmarks.confirmation"], execute = app.buttons["privacy.clear-bookmarks.execute"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertFalse(execute.isEnabled)
        field.tap(); field.typeText("CLEA"); XCTAssertFalse(execute.isEnabled)
        field.typeText("R"); XCTAssertTrue(execute.isEnabled)
        app.navigationBars.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(field.exists); XCTAssertTrue(clear.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "bookmark-clear-confirmation-canceled"; shot.lifetime = .keepAlways; add(shot)
    }

    func testBatchImportPromptAndNamedGroups() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let slot = try XCTUnwrap(app.launchArguments.firstIndex(of: "-home_toolbar_actions"))
        app.launchArguments[slot + 1] = "(platforms)"
        app.launchArguments += ["-icloud_bookmarks_sync_enabled", "NO", "-platform_management_layout", "grid"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        app.buttons["platform.managementMenu"].tap()
        app.buttons["Batch Import"].firstMatch.tap()
        let promptEntry = app.buttons["batch-import.ai-prompt"]
        XCTAssertTrue(promptEntry.waitForExistence(timeout: 5)); XCTAssertTrue(promptEntry.isHittable)
        let layout = XCTAttachment(screenshot: app.screenshot()); layout.name = "batch-import-compact-cards"; layout.lifetime = .keepAlways; add(layout)
        promptEntry.tap()
        let copy = app.buttons["batch-import.copy-prompt"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(copy.label.contains("Copied"), copy.label)
        let explanation = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Copy this prompt, add your requirements")).firstMatch
        XCTAssertTrue(explanation.exists)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "batch-import-ai-prompt"; shot.lifetime = .keepAlways; add(shot)
        app.navigationBars["AI Prompt"].buttons.firstMatch.tap()
        let field = app.textViews["batch-import.json"]
        for _ in 0..<3 where !field.isHittable { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap()
        let suffix = String(UUID().uuidString.prefix(6))
        let first = "QA Alpha " + suffix, second = "QA Beta " + suffix
        field.typeText("{\"groups\":[{\"name\":\"\(first)\",\"platforms\":[{\"name\":\"Alpha\",\"url\":\"https://alpha.example/\(suffix)?q=%@\"}]},{\"name\":\"\(second)\",\"platforms\":[{\"name\":\"Beta\",\"url\":\"https://beta.example/\(suffix)?q=%@\"}]}]}")
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        let execute = app.buttons["batch-import.execute"]
        XCTAssertTrue(execute.isHittable); XCTAssertTrue(execute.isEnabled); execute.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: execute)], timeout: 8), .completed)
        for name in [first, second] {
            let group = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
            for _ in 0..<15 where !group.isHittable { app.swipeUp() }
            XCTAssertTrue(group.exists, app.debugDescription)
        }
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "batch-import-multiple-named-groups"; result.lifetime = .keepAlways; add(result)
    }

    func testVideoTakeoverSwitchStartsOffAndCanBeChanged() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_VIDEO_TAKEOVER_RESET"] = "1"
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Video Settings")
        let video = app.buttons["Video Settings"].firstMatch
        XCTAssertTrue(video.waitForExistence(timeout: 5)); video.tap()
        let toggle = app.switches["video-settings.takeover"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "video-takeover-setting"; screenshot.lifetime = .keepAlways; add(screenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testPlatformAIExportAndConfirmedReplacement() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let toolbar = try XCTUnwrap(app.launchArguments.firstIndex(of: "-home_toolbar_actions"))
        app.launchArguments[toolbar + 1] = "(platforms)"
        app.launchArguments += ["-platform_management_layout", "grid", "-icloud_bookmarks_sync_enabled", "NO"]
        app.launch(); defer { app.terminate() }
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        app.buttons["platform.managementMenu"].tap(); app.buttons["Batch Import"].firstMatch.tap()
        app.buttons["batch-import.ai-prompt"].tap()
        let copy = app.buttons["batch-import.copy-platforms"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap(); XCTAssertTrue(copy.label.contains("Copied"))
        XCTAssertTrue(app.buttons["batch-import.export-platforms"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "platform-ai-copy-and-export"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.navigationBars["AI Prompt"].buttons.firstMatch.tap()
        let input = app.textViews["batch-import.json"]
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        let suffix = String(UUID().uuidString.prefix(6)), name = "Reorganized " + suffix
        input.typeText("{\"groups\":[{\"name\":\"\(name)\",\"platforms\":[{\"name\":\"AI platform\",\"url\":\"https://example.com/\(suffix)?q=%@\"}]}]}")
        let done = app.toolbars.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        let replace = app.segmentedControls["batch-import.mode"].buttons["Replace all"]
        for _ in 0..<3 where !replace.isHittable { app.swipeUp() }
        XCTAssertTrue(replace.waitForExistence(timeout: 5)); replace.tap()
        app.buttons["batch-import.execute"].tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "A settings backup is saved")).firstMatch.exists)
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(input.exists, "Cancel keeps the original configuration and editable import")
        app.buttons["batch-import.execute"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5)); alert.buttons["batch-import.replace-confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["batch-import.execute"].waitForNonExistence(timeout: 8))
        let group = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", name)).firstMatch
        for _ in 0..<12 where !group.isHittable { app.swipeUp() }
        XCTAssertTrue(group.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["AI platform"].exists)
        let result = XCTAttachment(screenshot: app.screenshot()); result.name = "platform-ai-replacement-applied"; result.lifetime = .keepAlways; add(result)
    }

    func testExitHistorySwitchClearsVisitsOnActualAppBackgroundAndKeepsSearchTerms() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_HISTORY"] = "1"
        app.launch(); defer { app.terminate() }
        let probe = app.staticTexts["qa.acceptance"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10))
        func waitFor(_ value: String) -> Bool {
            let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (probe.value as? String ?? "").contains(value) }, object: nil)
            return XCTWaiter.wait(for: [expected], timeout: 10) == .completed
        }
        XCTAssertTrue(waitFor("history-visits=1;history-queries=1"))
        app.buttons["home.toolbar.0"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Privacy")
        let privacy = app.buttons.matching(NSPredicate(format: "label IN %@", ["Privacy", "Privacy Settings"])).firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 5)); privacy.tap()
        let toggle = app.switches["privacy.clear-browsing-on-exit"]
        for _ in 0..<5 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons.firstMatch.tap()
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
        XCTAssertTrue(probe.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home); Thread.sleep(forTimeInterval: 2); app.activate()
        XCTAssertTrue(waitFor("history-visits=0;history-queries=1"), probe.value as? String ?? app.debugDescription)
    }

    func testPlatformManagementAutoHideWorksInBothLayoutsAndPersists() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        let position = app.launchArguments.firstIndex(of: "-home_toolbar_actions")!
        app.launchArguments[position + 1] = "(platforms)"
        app.launchEnvironment["SOULO_ACCEPTANCE_PROBE"] = "1"
        app.launchEnvironment["SOULO_ACCEPTANCE_PLATFORM_RESET"] = "1"
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["qa.acceptance"].waitForExistence(timeout: 10))
        let entry = app.buttons["home.toolbar.0"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10)); entry.tap()
        let toggle = app.switches["platform.auto-hide-platforms"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 8)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5)); app.alerts.buttons.firstMatch.tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.buttons["platform.layout"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        app.navigationBars.buttons["Done"].firstMatch.tap()
        entry.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap(); XCTAssertEqual(toggle.value as? String, "0")
    }

    func testWebsiteDataUsesChineseInStorageAndDetails() {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: false, fromSettings: true)
        app.launchArguments[1] = "zh-Hans"
        app.launch(); defer { app.terminate() }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("存储空间")
        app.buttons["存储空间"].firstMatch.tap()
        let websiteData = app.buttons["storage.manage.webData"]
        XCTAssertTrue(websiteData.waitForExistence(timeout: 8))
        XCTAssertTrue(websiteData.label.contains("网站数据"), websiteData.label)
        XCTAssertFalse(app.staticTexts["Website data"].exists)
        websiteData.tap()
        XCTAssertTrue(app.navigationBars["网站数据"].waitForExistence(timeout: 8), app.debugDescription)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "website-data-chinese"; image.lifetime = .keepAlways; add(image)
    }

    func testPopulatedRuleManagementFromStorage() {
        continueAfterFailure = false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:true,fromSettings:true,populated:true)
        app.launch();defer{app.terminate()}
        let settings=app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        let storage=app.buttons["Storage"].firstMatch
        for _ in 0..<8 where !storage.isHittable { app.swipeUp() }
        XCTAssertTrue(storage.waitForExistence(timeout:8)); XCTAssertTrue(storage.isHittable)
        storage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:8),app.debugDescription)
        let filtering=app.buttons["storage.manage.filterRules"]
        for _ in 0..<4 where !filtering.isHittable {app.swipeUp()}
        XCTAssertTrue(filtering.waitForExistence(timeout:8)); XCTAssertTrue(filtering.isHittable)
        filtering.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Ad Blocking"].waitForExistence(timeout:5))
        checkRuleRoutes(app,populated:true)
    }
    func testAdditionalStorageCategoriesAreVisibleAndManageable() {
        continueAfterFailure=false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:false,fromSettings:true);app.launch();defer{app.terminate()}
        let settings=app.buttons["home.toolbar.0"];XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        let search=app.searchFields.firstMatch;XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap();XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:8))
        XCTAssertTrue(app.staticTexts["App size"].exists);XCTAssertTrue(app.staticTexts["App data"].exists)
        let routes=[("wallpaperCache","Wallpaper cache"),("otherCaches","Other caches"),("temporaryFiles","Temporary files"),("ruleCache","Cached Rules"),
            ("downloadTasks","Download task data"),("extensions","Scripts & Extensions"),("personalData","Settings and records"),
            ("sharedData","Shared app data"),("otherData","Other app data")]
        for (id,title) in routes {
            let entry=app.buttons["storage.manage."+id]
            let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            let nav = app.navigationBars["Storage"]
            func visible() -> Bool {
                entry.exists && entry.isHittable && entry.frame.midY > nav.frame.maxY + 12 && entry.frame.midY < list.frame.maxY - 24
            }
            for _ in 0..<12 {
                if visible() { break }
                let start=list.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.55))
                let delta:CGFloat = entry.exists && entry.frame.midY <= nav.frame.maxY + 12 ? 180 : -180
                start.press(forDuration:0.05,thenDragTo:start.withOffset(CGVector(dx:0,dy:delta)),withVelocity:.slow,thenHoldForDuration:0.1)
            }
            XCTAssertTrue(entry.waitForExistence(timeout:5));XCTAssertTrue(visible(),app.debugDescription)
            entry.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:8),app.debugDescription)
            if ["wallpaperCache","otherCaches","temporaryFiles","ruleCache","downloadTasks"].contains(id) {
                XCTAssertTrue(app.buttons["storage.clear."+id].exists)
            }
            app.navigationBars[title].buttons.firstMatch.tap();XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:5))
        }
    }

    func testStorageManagementRoutesAndReadingExplanation() {
        continueAfterFailure = false
        let app=XCUIApplication(bundleIdentifier:SouloUITestApplication.bundleIdentifier)
        configure(app,enabled:false,fromSettings:true)
        app.launch();defer{app.terminate()}
        let settings=app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout:10));settings.tap()
        let search=app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout:5));search.tap();search.typeText("Storage")
        app.buttons["Storage"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:8))
        let routes=[("webData","Website data"),("downloads","Files"),("wallpapers","My Favorites"),("readingData","Reading data"),("filterRules","Ad Blocking"),("backups","Settings Backups")]
        for (id,title) in routes {
            let entry=app.buttons["storage.manage."+id]
            for _ in 0..<4 where !entry.isHittable {app.swipeUp()}
            for _ in 0..<4 where !entry.isHittable {app.swipeDown()}
            XCTAssertTrue(entry.waitForExistence(timeout:5));entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout:8),app.debugDescription)
            if id == "readingData" {
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label BEGINSWITH %@","Reading data includes saved article text")).firstMatch.exists)
                XCTAssertTrue(app.buttons["Reading list"].exists)
            }
            if id == "webData" {
                if #available(iOS 18.4, *) { XCTAssertTrue(app.buttons["storage.extension-cache"].exists) }
                else { XCTAssertFalse(app.buttons["storage.extension-cache"].exists) }
            }
            let shot=XCTAttachment(screenshot:app.screenshot());shot.name="storage-management-"+id;shot.lifetime = .keepAlways;add(shot)
            app.navigationBars[title].buttons.firstMatch.tap()
            XCTAssertTrue(app.navigationBars["Storage"].waitForExistence(timeout:5))
        }
    }
    func testRuleManagementWithFilteringEnabled() { checkRules(enabled: true) }
    func testRuleManagementWithFilteringDisabled() { checkRules(enabled: false) }
    func testRuleManagementFromSettings() { checkRules(enabled: true, fromSettings: true) }
    func testPopulatedRulesFromSettings() { checkRules(enabled: true, fromSettings: true, populated: true) }

    func testRuleManagementDuringAutomaticSubscriptionRefresh() async throws {
        let server = try AdSettingsPageFixture(ruleCount: 20_000)
        let url = try await server.start()
        defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: true, fromSettings: true, populated: true)
        let disabledDefaults = ["easylist", "easyprivacy", "easylist-china", "adguard-base", "adguard-chinese", "adguard-mobile", "adguard-annoyances"]
        var subscriptions: [[String: Any]] = disabledDefaults.map { id in
            ["id": id, "name": id, "urlString": url.appendingPathComponent("unused").absoluteString,
             "isEnabled": false, "networkRuleCount": 0, "cosmeticRuleCount": 0, "errorMessage": ""]
        }
        subscriptions.append(["id": "automatic-refresh-fixture", "name": "Automatic refresh fixture",
            "urlString": url.appendingPathComponent("rules.txt").absoluteString, "isEnabled": true,
            "networkRuleCount": 0, "cosmeticRuleCount": 0, "errorMessage": ""])
        let data = try JSONSerialization.data(withJSONObject: subscriptions, options: [.sortedKeys])
        app.launchArguments += ["-soulo_ad_block_subscriptions", "<" + data.map { String(format: "%02x", $0) }.joined() + ">",
            "-soulo_ad_block_subscription_auto_update_check", "0"]
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] { app.launchEnvironment[key] = "" }
        app.launchEnvironment["NO_PROXY"] = "127.0.0.1,localhost"
        app.launch(); defer { app.terminate() }
        // Wait for the actual idle-home automatic request, not a guessed
        // startup delay. Keep its response pending while navigation begins.
        for _ in 0..<450 {
            if server.hasRequestedRules { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let requested = server.hasRequestedRules
        XCTAssertTrue(requested, "The normal app activation must request the fixture: \(server.requestSummary)")
        guard requested else { return }
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
        app.buttons["Ad Blocking"].firstMatch.tap()
        checkRuleRoutes(app, populated: true, expectsAutomaticRefresh: true)
    }

    func testPopulatedRulesFromWebpageInformation() async throws {
        let server = try AdSettingsPageFixture()
        let url = try await server.start()
        defer { server.stop() }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: true, populated: true)
        app.launchArguments += ["-privacy_https_upgrade_enabled", "NO", "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
        app.launch(); defer { app.terminate() }
        // Use the real address field instead of XCUIApplication.open, which
        // is unavailable on the shipping iOS 16.0 boundary.
        let query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 10)); query.tap()
        let focused = app.textFields["search.query"].firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 5))
        focused.typeText(url.absoluteString + "\n")
        XCTAssertTrue(app.webViews.staticTexts["Ad settings page fixture"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["browser.siteInformation"].tap()
        let entry = app.buttons["site.ad-block-details"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        checkRuleRoutes(app, populated: true)
    }

    private func configure(_ app: XCUIApplication, enabled: Bool, fromSettings: Bool = false, populated: Bool = false) {
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-ad_block_enabled", enabled ? "YES" : "NO",
            "-home_toolbar_actions", fromSettings ? "(settings)" : "(adBlock)"]
        if populated {
            let records: [[String: Any]] = (0..<500).map { index in
                ["id": UUID().uuidString, "host": String(format: "qa-%03d.example.test", index % 20),
                 "selector": ".fixture-ad-\(index)", "createdAt": Double(index)]
            }
            let data = try! JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            let hosts = (0..<200).map { String(format: "\"allow-%03d.example.test\"", $0) }.joined(separator: ",")
            app.launchArguments += ["-soulo_manual_ad_rules_v1", "<" + data.map { String(format: "%02x", $0) }.joined() + ">",
                "-ad_block_cross_domain_allowlist", "(" + hosts + ")", "-soulo_ad_block_allowlisted_hosts", "(" + hosts + ")"]
        }
    }

    private func checkRules(enabled: Bool, fromSettings: Bool = false, populated: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        configure(app, enabled: enabled, fromSettings: fromSettings, populated: populated)
        app.launch(); defer { app.terminate() }
        let filtering = app.buttons["home.toolbar.0"]
        XCTAssertTrue(filtering.waitForExistence(timeout: 10)); filtering.tap()
        if fromSettings {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Ad Blocking")
            app.buttons["Ad Blocking"].firstMatch.tap()
        }
        checkRuleRoutes(app, populated: populated)
    }

    private func checkRuleRoutes(_ app: XCUIApplication, populated: Bool, expectsAutomaticRefresh: Bool = false) {
        let routes = [("domainAllowlist", "Trusted domains"), ("manualRules", "Marked ads"),
            ("builtInRules", "Built-in rules"), ("subscriptions", "Filter lists"), ("allowedSites", "Allowed Sites")]
        for pass in 0..<3 {
            for (id, title) in routes {
                let entry = app.buttons["adBlock." + id]
                for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
                for _ in 0..<4 where !entry.isHittable { app.swipeDown() }
                XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), app.debugDescription)
                if populated {
                    switch id {
                    case "manualRules":
                        XCTAssertTrue(app.descendants(matching: .any)["manualAds.host.qa-000.example.test"].firstMatch.waitForExistence(timeout: 5), "The 500-rule fixture must really be loaded")
                    case "domainAllowlist":
                        XCTAssertTrue(app.staticTexts["domainAllowlist.rule.allow-000.example.test"].waitForExistence(timeout: 5))
                    case "allowedSites": XCTAssertTrue(app.staticTexts["allow-000.example.test"].firstMatch.waitForExistence(timeout: 5))
                    default: break
                    }
                }
                if expectsAutomaticRefresh && id == "subscriptions" {
                    XCTAssertTrue(app.switches["adBlock.subscription.enabled.automatic-refresh-fixture"].exists)
                    let prefix = 20_000.formatted(.number.locale(Locale(identifier: "en_US"))) + " "
                    let refreshed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch.waitForExistence(timeout: 10)
                    XCTAssertTrue(refreshed,
                                  "The real automatic HTTP refresh must finish, not just render cached metadata")
                    guard refreshed else { return }
                }
                // Scope dismissal to the visible child bar. A global Done
                // query can select the still-mounted, underlying sheet's button.
                app.navigationBars[title].buttons.firstMatch.tap()
                let closed = NSPredicate(format: "exists == false")
                XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: app.navigationBars[title])], timeout: 5), .completed)
                XCTAssertTrue(entry.waitForExistence(timeout: 5), "Return from \(id), pass \(pass)")
            }
        }
    }
}

private final class AdSettingsPageFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Soulo.AdSettingsPageFixture")
    private let rules: String
    private let requestLock = NSLock()
    private var requestedRules = false
    private var requestLines: [String] = []
    var requestSummary: String {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestLines.joined(separator: " | ")
    }
    private func recordRequest(_ data: Data?) {
        requestLock.lock(); defer { requestLock.unlock() }
        requestLines.append(data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? "no request bytes")
    }
    var hasRequestedRules: Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestedRules
    }
    private func recordRulesRequest() {
        requestLock.lock(); defer { requestLock.unlock() }
        requestedRules = true
    }
    init(ruleCount: Int = 0) throws {
        listener = try NWListener(using: .tcp, on: .any)
        rules = (0..<ruleCount).map { "||ad-\($0).example.test^" }.joined(separator: "\n")
    }
    func start() async throws -> URL {
        listener.newConnectionHandler = { [weak self, queue, rules] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { request, _, _, _ in
                self?.recordRequest(request)
                let isRules = request.flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix("GET /rules.txt ") == true
                if isRules { self?.recordRulesRequest() }
                let body = isRules ? rules : "<meta name='viewport' content='width=device-width,initial-scale=1'><p>Ad settings page fixture</p>"
                let type = isRules ? "text/plain" : "text/html"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: \(type); charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                // Return new rule metadata while the user navigates the child
                // pages, reproducing the live-update/legacy-navigation overlap.
                queue.asyncAfter(deadline: .now() + (isRules ? 8 : 0)) {
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
        return try await withCheckedThrowingContinuation { reply in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = self?.listener.port else { return }
                    self?.listener.stateUpdateHandler = nil
                    reply.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/")!)
                case .failed(let error): self?.listener.stateUpdateHandler = nil; reply.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
}
