import XCTest

@MainActor
final class ScreenAwakeSettingsUITests: XCTestCase {
    private func openSetting(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["home.menu"].tap(); app.buttons["Settings"].firstMatch.tap()
        let toggle = app.switches["settings.keepScreenAwake"].firstMatch
        for _ in 0..<7 {
            if toggle.exists && toggle.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        return toggle
    }
    func testSettingIsOffInitiallyPersistsAndCanBeDisabledAgain() throws {
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
        app.launchArguments = ["-app_language", "en-US"]
        app.launch(); app.open(URL(string: "soulo://")!)
        let toggle = openSetting(app)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        app.terminate(); app.launch(); app.open(URL(string: "soulo://")!)
        let restored = openSetting(app)
        XCTAssertEqual(restored.value as? String, "1")
        restored.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertEqual(restored.value as? String, "0")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "keep-screen-on-default-off"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.buttons["Done"].firstMatch.tap()
    }
}
