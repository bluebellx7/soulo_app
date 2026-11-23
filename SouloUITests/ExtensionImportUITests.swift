import XCTest

@MainActor
final class ExtensionImportUITests: XCTestCase {
    private func openInstallPage() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-is_incognito", "NO",
            "-restore_last_page_on_launch", "NO", "-home_toolbar_actions", "(settings)"]
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        app.launch()
        let settings = app.buttons["home.toolbar.0"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), app.debugDescription)
        settings.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Scripts")
        let entry = app.buttons["settings.extensions"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
        let add = app.segmentedControls.buttons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        return app
    }

    private func checkPicker(_ app: XCUIApplication, label: String) {
        let entry = app.buttons[label].firstMatch
        for _ in 0..<8 where !entry.isHittable { app.swipeUp() }
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); XCTAssertTrue(entry.isEnabled)
        for pass in 0..<3 {
            XCTAssertTrue(entry.isHittable); entry.tap()
            let picker = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].firstMatch
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            let presented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                picker.exists || cancel.isHittable
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [presented], timeout: 20), .completed,
                "Picker did not open: \(label), pass \(pass)\n\(app.debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "extension-import-picker-\(label)-\(pass)"; attachment.lifetime = .keepAlways; add(attachment)
            if cancel.isHittable {
                cancel.tap()
            } else {
                picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).press(forDuration: 0.05,
                    thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
            }
            XCTAssertTrue(picker.waitForNonExistence(timeout: 6), app.debugDescription)
            XCTAssertTrue(entry.isHittable)
        }
    }

    func testStoreInstallsCurrentEdgeTampermonkeyWithoutExtraPermissionSheet() throws {
        guard #available(iOS 18.4, *), ProcessInfo.processInfo.environment["SOULO_LIVE_INSTALL_QA"] == "1" else {
            throw XCTSkip("Opt-in real Microsoft store download")
        }
        let app = openInstallPage(); defer { app.terminate() }
        let store = app.buttons["extensions.install-store-link"]
        XCTAssertTrue(store.waitForExistence(timeout: 5)); store.tap()
        let input = app.textFields["extensions.store-url"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap()
        input.typeText("https://microsoftedge.microsoft.com/addons/detail/tampermonkey/iikmkjmpaadaobahmlepeloendndfphd")
        let install = app.buttons["extensions.store-install"]
        XCTAssertTrue(install.isEnabled); install.tap()
        XCTAssertTrue(app.buttons["extensions.store-cancel"].isEnabled, "Cancel must remain available while preparing")
        let failure = app.alerts["Extension Could Not Be Installed"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            failure.exists || !install.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 150), .completed, app.debugDescription)
        XCTAssertFalse(failure.exists, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Permissions"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "edge-tampermonkey-two-step-success"; image.lifetime = .keepAlways; add(image)
        let installed = app.segmentedControls.buttons["Installed"]
        XCTAssertTrue(installed.waitForExistence(timeout: 8)); installed.tap()
        let toggle = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS[c] %@ OR label CONTAINS %@)", "extensions.toggle-", "Tampermonkey", "篡改猴")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), app.debugDescription)
        let action = app.buttons[toggle.identifier.replacingOccurrences(of: "extensions.toggle-", with: "extensions.action-")]
        XCTAssertTrue(action.exists)
        action.press(forDuration: 1)
        let manage = app.buttons["Manage"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 5)); manage.tap()
        let delete = app.buttons["extensions.management-delete"]
        for _ in 0..<8 where !delete.isHittable { app.swipeUp() }
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        let confirm = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.segmentedControls.buttons["Installed"].waitForExistence(timeout: 8))
        XCTAssertFalse(action.exists, "Deleting from management must remove the installed extension")
    }

    func testSouloCatalogOpensInstallerAndCancelsWithoutInstalling() throws {
        guard #available(iOS 18.4, *), SouloUITestApplication.bundleIdentifier.hasSuffix(".Acceptance"),
              let address = ProcessInfo.processInfo.environment["SOULO_CATALOG_TEST_URL"] else { throw XCTSkip("Local catalog acceptance server") }
        let app = openInstallPage(); defer { app.terminate() }
        let entry = app.buttons["extensions.soulo-catalog"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5)); XCTAssertTrue(entry.isHittable)
        var route = URLComponents(string: "soulo://open")!
        route.queryItems = [URLQueryItem(name: "url", value: address)]
        app.open(try XCTUnwrap(route.url))
        let installLink = app.webViews.links.matching(NSPredicate(format: "label IN %@", ["在 Soulo 中安装", "Install in Soulo"])).firstMatch
        XCTAssertTrue(installLink.waitForExistence(timeout: 15), app.debugDescription)
        installLink.tap()
        let input = app.textFields["extensions.store-url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue((input.value as? String ?? "").contains("kkeakohpadmbldjaiggikmnldlfkdfog"))
        XCTAssertTrue(app.buttons["extensions.store-install"].isEnabled)
        app.buttons["extensions.store-cancel"].tap()
        XCTAssertTrue(installLink.waitForExistence(timeout: 5), "Cancel must retain the source catalog document")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "soulo-catalog-retained-after-cancel"; image.lifetime = .keepAlways; add(image)
    }

    func testNativeExtensionFileAndFolderPickerOpensRepeatedly() throws {
        guard #available(iOS 18.4, *) else { throw XCTSkip("Native extensions require iOS 18.4") }
        let app = openInstallPage(); defer { app.terminate() }
        checkPicker(app, label: "Choose File or Folder…")
    }

    func testFilesWidgetURLColdLaunchAndAppIconRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-icloud_sync_enabled", "NO", "-restore_last_page_on_launch", "NO"]
        app.launch()
        app.terminate()
        defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let files = app.descendants(matching: .any)["library.section.files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 12), app.debugDescription)
        XCTAssertTrue(files.isSelected)
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 12), app.debugDescription)
    }

    func testOptInAddAndOpenFilesWidgetOnHomeScreen() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_WIDGET_GALLERY_QA"] == "1",
                          "Requires a disposable simulator with its default Home Screen layout")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func button(_ names: [String]) -> XCUIElement {
            springboard.buttons.matching(NSPredicate(format: "label IN %@", names)).firstMatch
        }
        app.launch()
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.46, dy: 0.67)).press(forDuration: 1.2)
        let edit = button(["Edit", "编辑", "編輯"])
        XCTAssertTrue(edit.waitForExistence(timeout: 5), springboard.debugDescription)
        edit.tap()
        let addWidget = springboard.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@", ["Add Widget", "Add Widgets", "添加小组件", "加入小工具"])).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5), springboard.debugDescription)
        addWidget.tap()
        let search = springboard.searchFields.matching(NSPredicate(format: "label IN %@",
            ["Search Widgets", "搜索小组件", "搜尋小工具"])).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 7), springboard.debugDescription)
        search.tap()
        search.typeText("Soulo")
        let result = springboard.cells["Soulo"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 7), springboard.debugDescription)
        result.tap()
        let add = springboard.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] %@ OR label CONTAINS %@ OR label CONTAINS %@",
            "Add Widget", "添加小组件", "加入小工具")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), springboard.debugDescription)
        let preview = XCTAttachment(screenshot: springboard.screenshot())
        preview.name = "Soulo wallpaper widget preview"; preview.lifetime = .keepAlways; self.add(preview)
        add.tap()
        let done = button(["Done", "完成"])
        if done.waitForExistence(timeout: 2) { done.tap() }
        app.terminate()
        let home = XCTAttachment(screenshot: springboard.screenshot())
        home.name = "Soulo files widget on Home Screen"; home.lifetime = .keepAlways; self.add(home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.20)).tap()
        let files = app.descendants(matching: .any)["library.section.files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(files.isSelected)
    }

    func testFilesCRXOpensPermissionReviewBeforeInstalling() throws {
        guard #available(iOS 18.4, *),
              let filename = ProcessInfo.processInfo.environment["SOULO_CRX_FILE_QA"] else {
            throw XCTSkip("Opt-in user-supplied CRX in the app's Downloads folder")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-icloud_sync_enabled", "NO", "-files.gridView", "NO",
            "-is_incognito", "NO", "-restore_last_page_on_launch", "NO"]
        app.launch()
        defer { app.terminate() }
        app.open(URL(string: "soulo://files")!)
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 12), app.debugDescription)
        file.tap()
        let install = app.buttons["extensions.review-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars["Permissions"].exists)
        app.navigationBars["Permissions"].buttons["Cancel"].tap()
        XCTAssertTrue(install.waitForNonExistence(timeout: 5))
        XCTAssertTrue(file.isHittable)
        file.tap()
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        install.tap()
        let failure = app.alerts["Extension Could Not Be Installed"]
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            failure.exists || !install.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 25), .completed, app.debugDescription)
        XCTAssertFalse(failure.exists, failure.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["files.extension-installed"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Extension install success"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(file.isHittable)
    }

    func testStoreExtensionsOpenFromHomeAfterRelaunch() throws {
        guard #available(iOS 18.4, *),
              let runMode = ProcessInfo.processInfo.environment["SOULO_EXTENSION_HOME_QA"] else {
            throw XCTSkip("Requires the official Cat Catch and Header Editor Lite CRX files in Downloads")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-is_incognito", "NO", "-restore_last_page_on_launch", "NO", "-review.requestedOnce", "YES",
            "-files.gridView", "NO", "-home_toolbar_actions", "(extensions)"]
        app.launch()
        defer { app.terminate() }
        if runMode != "installed" {
            app.open(URL(string: "soulo://files")!)
            for filename in ["catcatch-compatibility-qa.crx", "header-editor-lite-qa.crx"] {
                let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
                XCTAssertTrue(file.waitForExistence(timeout: 10), app.debugDescription)
                file.tap()
                let install = app.buttons["extensions.review-install"]
                XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
                install.tap()
                XCTAssertTrue(install.waitForNonExistence(timeout: 30), app.debugDescription)
                XCTAssertFalse(app.alerts["Extension Could Not Be Installed"].exists, app.debugDescription)
            }
            app.terminate()
            app.launch()
        }
        let extensions = app.buttons["home.toolbar.0"]
        XCTAssertTrue(extensions.waitForExistence(timeout: 10), app.debugDescription)
        extensions.tap()
        let close = app.buttons["extensions.popup.close"]
        func extensionButton(_ names: [String]) -> XCUIElement {
            let namesPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: names.map {
                NSPredicate(format: "label CONTAINS[c] %@", $0)
            })
            return app.buttons.matching(NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "identifier BEGINSWITH %@", "extensions.action-"), namesPredicate
            ])).firstMatch
        }
        let catCatch = extensionButton(["Cat Catch", "Cat-Catch", "猫抓"])
        XCTAssertTrue(catCatch.waitForExistence(timeout: 45), app.debugDescription)
        for _ in 0..<2 {
            catCatch.tap()
            XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8), app.debugDescription)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        }
        let headerEditor = extensionButton(["Header Editor Lite"])
        XCTAssertTrue(headerEditor.waitForExistence(timeout: 45), app.debugDescription)
        headerEditor.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), app.debugDescription)
        let manage = app.webViews.menuItems.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "setting")).firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 8), app.debugDescription)
        manage.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(extensions.waitForNonExistence(timeout: 10), app.debugDescription)
        let rules = app.webViews.staticTexts.matching(NSPredicate(format: "label IN[cd] %@", ["Rules list", "规则列表"])).firstMatch
        XCTAssertTrue(rules.waitForExistence(timeout: 15), app.debugDescription)
    }

    func testOriginalGoFullPageExportsTallCaptureFromBrowserToolbar() async throws {
        guard #available(iOS 18.4, *), let filename = ProcessInfo.processInfo.environment["SOULO_GOFULLPAGE_CRX"] else {
            throw XCTSkip("Requires the official GoFullPage CRX in the test app's files")
        }
        continueAfterFailure = false
        let page = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>GoFullPage capture fixture</title><h1>GoFullPage capture fixture</h1>
        <div style="height:2600px;background:linear-gradient(#182a58,#e8c485)"></div><p>End of the capture fixture</p>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/capture-fixture.html": Data(page.utf8)])
        let base = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-is_incognito", "NO", "-restore_last_page_on_launch", "NO",
            "-review.requestedOnce", "YES", "-files.gridView", "NO", "-browser_toolbar_hidden", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-browser_more_menu_actions", "(home,extensions,platforms)"]
        app.launch()
        defer { app.terminate() }

        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let package = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 10), app.debugDescription)
        package.tap()
        let install = app.buttons["extensions.review-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        let downloads = app.switches["downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 5), app.debugDescription)
        if downloads.value as? String != "1" {
            downloads.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let approved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: downloads)
        XCTAssertEqual(XCTWaiter.wait(for: [approved], timeout: 5), .completed, app.debugDescription)
        install.tap()
        XCTAssertTrue(install.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts["Extension Could Not Be Installed"].exists)

        app.open(base.appendingPathComponent("capture-fixture.html"))
        XCTAssertTrue(app.webViews.staticTexts["GoFullPage capture fixture"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let more = app.buttons["browser.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let extensions = app.buttons["browser.moreMenu.extensions"].firstMatch
        XCTAssertTrue(extensions.waitForExistence(timeout: 5), app.debugDescription)
        extensions.tap()
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "extensions.action-", "GoFullPage")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), app.debugDescription)
        action.tap()
        let image = app.webViews.images["Captured screenshot"].firstMatch
        let png = app.webViews.links.matching(NSPredicate(format: "label CONTAINS[c] %@", "Download image")).firstMatch
        let pdf = app.webViews.links["Download PDF"].firstMatch
        let missing = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Unable to load image")).firstMatch
        let result = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in image.exists || missing.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [result], timeout: 30), .completed, app.debugDescription)
        XCTAssertFalse(missing.exists, app.debugDescription)
        XCTAssertTrue(image.exists, app.debugDescription)
        XCTAssertGreaterThan(image.frame.height, 2 * image.frame.width)

        let pngOnly = ProcessInfo.processInfo.environment["SOULO_GOFULLPAGE_PNG_ONLY"] == "1"
        for link in pngOnly ? [png] : [png, pdf] {
            XCTAssertTrue(link.isHittable, app.debugDescription)
            if link == pdf {
                // The PDF link exposes its tooltip bounds. Its toolbar button
                // is one button-width to the left of the image button.
                let imageButton = png.frame
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: imageButton.midX - imageButton.width, dy: imageButton.midY)).tap()
            } else {
                link.tap()
            }
            let permission = app.alerts.firstMatch
            if permission.waitForExistence(timeout: 2) {
                let confirm = permission.buttons["Confirm"]
                XCTAssertTrue(confirm.exists, permission.debugDescription)
                confirm.tap()
            }
            if link == png && !pngOnly {
                // The download banner covers both export controls briefly.
                let banner = app.descendants(matching: .any)["downloads.completion-toast"].firstMatch
                XCTAssertTrue(banner.waitForExistence(timeout: 8), app.debugDescription)
                XCTAssertTrue(banner.waitForNonExistence(timeout: 10), app.debugDescription)
            }
            if link == pdf {
                let created = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Created PDF")).firstMatch
                _ = created.waitForExistence(timeout: 30)
            }
        }
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let name = "screencapture-127-0-0-1-\(try XCTUnwrap(base.port))-capture-fixture-html"
        for suffix in pngOnly ? [".png,"] : [".png,", ".pdf,"] {
            let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", name, suffix)).firstMatch
            XCTAssertTrue(file.waitForExistence(timeout: 20), app.debugDescription)
        }
    }

    func testOriginalQuickSnipSelectsAnAreaWithATouchDrag() async throws {
        guard #available(iOS 18.4, *), let filename = ProcessInfo.processInfo.environment["SOULO_QUICK_SNIP_CRX"] else {
            throw XCTSkip("Requires the official Quick Snip package in the test app's files")
        }
        continueAfterFailure = false
        let title = "Quick Snip touch \(UUID().uuidString.prefix(8))"
        let page = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title><h1>\(title)</h1>
        <p id="touch">Waiting for touch</p><div style="height:100svh;background:#335577"></div>
        <script>
        for (const type of ['pointerup', 'pointercancel']) {
            addEventListener(type, event => {
                if (event.pointerType !== 'touch') return;
                const area = document.querySelector('.qs-region-box');
                document.getElementById('touch').textContent = area ? type + ' ' + area.style.width + ' ' + area.style.height : type;
            }, true);
        }
        </script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/capture-touch.html": Data(page.utf8)])
        let base = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-is_incognito", "NO", "-restore_last_page_on_launch", "NO",
            "-review.requestedOnce", "YES", "-files.gridView", "NO", "-browser_toolbar_hidden", "NO",
            "-privacy_https_upgrade_enabled", "NO", "-browser_more_menu_actions", "(home,extensions,platforms)"]
        app.launch()
        defer { app.terminate() }

        let files = try XCTUnwrap(URL(string: "soulo://files"))
        app.open(files)
        let package = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 10), app.debugDescription)
        package.tap()
        let install = app.buttons["extensions.review-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        let downloads = app.switches["downloads"].firstMatch
        if downloads.exists, downloads.value as? String != "1" {
            downloads.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        install.tap()
        XCTAssertTrue(install.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts["Extension Could Not Be Installed"].exists, app.debugDescription)
        let manager = app.navigationBars["Scripts & Extensions"]
        if manager.exists {
            manager.buttons["Done"].tap()
            XCTAssertTrue(manager.waitForNonExistence(timeout: 8), app.debugDescription)
        }

        app.open(base.appendingPathComponent("capture-touch.html"))
        let browser = app.webViews.containing(.staticText, identifier: title).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 15), app.debugDescription)
        let more = app.buttons["browser.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "browser.moreMenu.extensionAction.", "Take a Screenshot")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), app.debugDescription)
        action.tap()
        let selection = app.webViews.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS %@",
            "Selected area", "选定区域")).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 10), app.debugDescription)
        selection.tap()
        XCTAssertTrue(selection.waitForNonExistence(timeout: 8), app.debugDescription)
        let guide = browser.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Drag to select an area")).firstMatch
        XCTAssertTrue(guide.waitForExistence(timeout: 8), app.debugDescription)
        let start = browser.coordinate(withNormalizedOffset: CGVector(dx: 0.22, dy: 0.24))
        let end = browser.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.46))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)

        let lastTouch = browser.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "pointerup ")).firstMatch
        XCTAssertTrue(lastTouch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(guide.waitForNonExistence(timeout: 8), app.debugDescription)
        app.open(files)
        let png = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, ".png,")).firstMatch
        XCTAssertTrue(png.waitForExistence(timeout: 15), app.debugDescription)
    }

    func testOriginalFetchVListsPlayingHLSFromTheToolbar() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard #available(iOS 18.4, *),
              let filename = environment["SOULO_FETCHV_CRX"],
              let media = environment["SOULO_FETCHV_HLS_FIXTURE"] else {
            throw XCTSkip("Requires the official FetchV package and the local HLS test assets")
        }
        continueAfterFailure = false
        let directory = URL(fileURLWithPath: media, isDirectory: true)
        let title = "Soulo HLS toolbar fixture"
        let markup = """
        <!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(title)</title><h1>\(title)</h1>
        <video muted autoplay controls playsinline style="width:100%" src="/sample.m3u8"></video>
        <p id="status">Loading the test stream</p>
        <script>document.querySelector('video').addEventListener('playing',()=>document.getElementById('status').textContent='Test stream playing');</script>
        """
        let server = try DownloadPlaybackHTTPFixture(files: [
            "/stream.html": Data(markup.utf8),
            "/sample.m3u8": Data(contentsOf: directory.appendingPathComponent("sample.m3u8")),
            "/sample-segment-0.ts": Data(contentsOf: directory.appendingPathComponent("sample-segment-0.ts"))
        ], responseHeaders: [
            "/stream.html": ["Content-Type": "text/html"],
            "/sample.m3u8": ["Content-Type": "application/vnd.apple.mpegurl"],
            "/sample-segment-0.ts": ["Content-Type": "video/mp2t"]
        ])
        let base = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-icloud_sync_enabled", "NO", "-is_incognito", "NO", "-restore_last_page_on_launch", "NO",
            "-review.requestedOnce", "YES", "-files.gridView", "NO", "-browser_toolbar_hidden", "NO",
            "-video.takeOverWebPlayers", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch()
        defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let package = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 10), app.debugDescription)
        package.tap()
        let install = app.buttons["extensions.review-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        install.tap()
        XCTAssertTrue(install.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts["Extension Could Not Be Installed"].exists, app.debugDescription)

        app.open(base.appendingPathComponent("stream.html"))
        let playing = app.webViews.staticTexts["Test stream playing"].firstMatch
        XCTAssertTrue(playing.waitForExistence(timeout: 15), app.debugDescription)
        let more = app.buttons["browser.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "browser.moreMenu.extensionAction.", "FetchV")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 10), app.debugDescription)
        action.tap()
        let mediaName = app.webViews.staticTexts["sample.m3u8"].firstMatch
        XCTAssertTrue(mediaName.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(server.receivedRequests.contains { $0.path == "/sample-segment-0.ts" })
    }

    func testOriginalWappalyzerDetectsWordPressAndExportsCSV() async throws {
        guard #available(iOS 18.4, *), let filename = ProcessInfo.processInfo.environment["SOULO_WAPPALYZER_CRX"] else {
            throw XCTSkip("Requires the official Wappalyzer CRX in the test app's files")
        }
        continueAfterFailure = false
        let page = """
        <!doctype html><meta name="generator" content="WordPress 6.8.1">
        <title>Soulo technology fixture</title><h1>Soulo technology fixture</h1>
        """
        let server = try DownloadPlaybackHTTPFixture(files: ["/technology-fixture.html": Data(page.utf8)],
            responseHeaders: ["/technology-fixture.html": ["Content-Type": "text/html"]])
        let base = try await server.start()
        server.releaseDownloads()
        defer { server.stop() }

        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-icloud_sync_enabled", "NO",
            "-is_incognito", "NO", "-restore_last_page_on_launch", "NO", "-review.requestedOnce", "YES",
            "-files.gridView", "NO", "-browser_toolbar_hidden", "NO", "-privacy_https_upgrade_enabled", "NO"]
        app.launch()
        defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let package = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", filename + ",")).firstMatch
        XCTAssertTrue(package.waitForExistence(timeout: 10), app.debugDescription)
        package.tap()
        let install = app.buttons["extensions.review-install"]
        XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
        let downloads = app.switches["downloads"].firstMatch
        XCTAssertTrue(downloads.waitForExistence(timeout: 5), app.debugDescription)
        if downloads.value as? String != "1" {
            downloads.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        let approved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: downloads)
        XCTAssertEqual(XCTWaiter.wait(for: [approved], timeout: 5), .completed, app.debugDescription)
        install.tap()
        XCTAssertTrue(install.waitForNonExistence(timeout: 30), app.debugDescription)
        XCTAssertFalse(app.alerts["Extension Could Not Be Installed"].exists, app.debugDescription)

        app.open(base.appendingPathComponent("technology-fixture.html"))
        let heading = app.webViews.staticTexts["Soulo technology fixture"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 15), app.debugDescription)
        app.buttons["browser.more"].firstMatch.tap()
        let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "browser.moreMenu.extensionAction.", "Wappalyzer")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 8), app.debugDescription)
        action.tap()
        let framework = app.webViews.links.matching(NSPredicate(format: "label BEGINSWITH %@", "WordPress 6.8.1")).firstMatch
        XCTAssertTrue(framework.waitForExistence(timeout: 18), app.debugDescription)
        let export = app.webViews.staticTexts.matching(NSPredicate(format: "label IN %@", ["Export", "导出"])).firstMatch
        XCTAssertTrue(export.isHittable, app.debugDescription)
        export.tap()
        XCTAssertTrue(app.buttons["downloads.completion-toast"].firstMatch.waitForExistence(timeout: 12), app.debugDescription)
        app.open(try XCTUnwrap(URL(string: "soulo://files")))
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@",
            "files.item.", ".csv,")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), app.debugDescription)
    }

    func testOptInSetSimulatorNotificationPermissionForSoulo() throws {
        guard let requested = ProcessInfo.processInfo.environment["SOULO_UI_TEST_NOTIFICATION_PERMISSION"],
              ["0", "1"].contains(requested) else { throw XCTSkip("Requires the isolated notification test device") }
        continueAfterFailure = false
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let permission = settings.switches.matching(NSPredicate(format: "label IN %@", ["Allow Notifications", "允许通知"])).firstMatch
        if !permission.exists {
            let cancel = settings.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            if cancel.isHittable { cancel.tap() }
            let apps = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["Apps", "App"])).firstMatch
            for _ in 0..<8 where !apps.isHittable { settings.swipeUp() }
            XCTAssertTrue(apps.isHittable, settings.debugDescription)
            apps.tap()
            let soulo = settings.staticTexts["Soulo"].firstMatch
            for _ in 0..<12 where !soulo.isHittable { settings.swipeUp() }
            XCTAssertTrue(soulo.isHittable, settings.debugDescription)
            soulo.tap()
            let notifications = settings.staticTexts.matching(NSPredicate(format: "label IN %@", ["Notifications", "通知"])).firstMatch
            XCTAssertTrue(notifications.waitForExistence(timeout: 5), settings.debugDescription)
            notifications.tap()
        }
        XCTAssertTrue(permission.waitForExistence(timeout: 8), settings.debugDescription)
        if permission.value as? String != requested { permission.tap() }
        XCTAssertEqual(permission.value as? String, requested)
    }

    func testUserScriptFilePickerOpensRepeatedly() {
        let app = openInstallPage(); defer { app.terminate() }
        checkPicker(app, label: "Choose Script…")
    }
}
