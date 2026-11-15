import XCTest

@MainActor
final class ExtensionImportUITests: XCTestCase {
    private func openInstallPage() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: SouloUITestApplication.bundleIdentifier)
        app.launchArguments = ["-app_language", "en-US", "-appearance", "light", "-wallpaper_source", "gradient",
            "-keep_screen_awake", "YES", "-icloud_sync_enabled", "NO", "-review.requestedOnce", "YES", "-is_incognito", "NO"]
        app.launchEnvironment["SOULO_BROWSER_TRACE"] = "1"
        app.launch()
        if #available(iOS 16.4, *), SouloUITestApplication.bundleIdentifier == "com.dkluge.Soulo" { app.open(URL(string: "soulo://")!) }
        XCTAssertTrue(app.buttons["home.menu"].waitForExistence(timeout: 10)); app.buttons["home.menu"].tap()
        app.buttons["Settings"].firstMatch.tap()
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
            let cancel = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch
            XCTAssertTrue(cancel.waitForExistence(timeout: 8), "Picker did not open: \(label), pass \(pass)\n\(app.debugDescription)")
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "extension-import-picker-\(label)-\(pass)"; attachment.lifetime = .keepAlways; add(attachment)
            cancel.tap()
            XCTAssertTrue(entry.waitForExistence(timeout: 5))
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
        let success = app.alerts["Installed Successfully"]
        for _ in 0..<150 {
            if success.exists || app.alerts["Extension Could Not Be Installed"].exists { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertTrue(success.exists, app.debugDescription)
        XCTAssertFalse(app.navigationBars["Permissions"].exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "edge-tampermonkey-two-step-success"; image.lifetime = .keepAlways; add(image)
        success.buttons["Done"].tap()
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

    func testUserScriptFilePickerOpensRepeatedly() {
        let app = openInstallPage(); defer { app.terminate() }
        checkPicker(app, label: "Choose Script…")
    }
}
