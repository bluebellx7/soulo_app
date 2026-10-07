import XCTest

/// Opt-in capture workflow. Run with SOULO_CAPTURE_STORE_ASSETS=1 in the
/// test runner environment after scripts/app_store_assets.py seeds a dedicated simulator.
final class AppStoreScreenshotUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_CAPTURE_STORE_ASSETS"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testCaptureChinese() throws { try capture(language: "zh-Hans") }
    func testCaptureEnglish() throws { try capture(language: "en-US") }

    func testCaptureEnglishPlatforms() {
        configure(language: "en-US")
        app.launch()
        openPlatforms(chinese: false)
        shot("02-platforms", "en-US")
        app.terminate()
    }

    private func configure(language: String) {
        app.launchArguments = ["-app_language", language, "-wallpaper_source", "gradient",
            "-wallpaper_gradient_id", "dawn", "-show_recent_searches_on_home", "NO",
            "-show_group_picker_on_home", "YES", "-files.gridView", "YES",
            "-platform_management_layout", "grid", "-reader.theme", "paper",
            "-reader.fontSize", "19", "-reader.lineHeight", "1.7", "-appearance", "light",
            "-browser_toolbar_hidden", "NO", "-keep_fullscreen_browsing", "NO"]
    }

    private func openPlatforms(chinese: Bool) {
        tap(app.buttons["home.menu"])
        tap(app.buttons[chinese ? "设置" : "Settings"].firstMatch)
        tap(app.buttons[chinese ? "平台" : "Platforms"].firstMatch)
        XCTAssertTrue(app.navigationBars[chinese ? "平台管理" : "Platform Management"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        // Capture the native initial section order. Avoid an arbitrary scroll
        // offset: iPad presents this page in a smaller settings sheet.
    }

    private func capture(language: String) throws {
        let chinese = language == "zh-Hans"
        configure(language: language)
        app.launch()
        tap(app.buttons["home.menu"], waitOnly: true)
        shot("01-home", language)

        openPlatforms(chinese: chinese)
        shot("02-platforms", language)
        app.terminate()

        app.launch()
        tap(app.buttons["home.menu"])
        tap(app.buttons[chinese ? "我的下载" : "My Downloads"].firstMatch)
        tap(app.buttons["library.section.files"])
        let filename = chinese ? "沿着河流慢慢走.txt" : "A Walk Along the River.txt"
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", filename)).firstMatch
        tap(file, waitOnly: true)
        shot("03-files", language)
        tap(file)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let chapter = app.webViews.staticTexts[chinese ? "第一章 清晨的河岸" : "Chapter One — The Morning River"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 15), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)).tap()
        tap(app.buttons["reader.style"], waitOnly: true)
        shot("04-reader", language)
        let capturesPrivacy = app.frame.width < 700
        app.terminate()

        // iPad delivery contains four images; the fifth privacy image is iPhone-only.
        if !capturesPrivacy { return }

        app.launch()
        tap(app.buttons["home.menu"])
        tap(app.buttons[chinese ? "设置" : "Settings"].firstMatch)
        let privacy = app.buttons[chinese ? "隐私设置" : "Privacy"].firstMatch
        for _ in 0..<5 {
            if privacy.exists && privacy.isHittable { break }
            app.swipeUp()
        }
        tap(privacy)
        XCTAssertTrue(app.staticTexts[chinese ? "自动升级 HTTPS" : "Upgrade HTTP to HTTPS"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        shot("05-privacy", language)
        app.terminate()
    }

    private func tap(_ element: XCUIElement, waitOnly: Bool = false) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(element.isHittable, app.debugDescription)
        if !waitOnly { element.tap() }
    }

    private func shot(_ name: String, _ language: String) {
        // Allow presentation and list loading animations to settle.
        Thread.sleep(forTimeInterval: 1)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "store-\(language)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
