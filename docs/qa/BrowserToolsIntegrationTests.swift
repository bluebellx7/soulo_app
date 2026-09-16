import XCTest
import UIKit

final class BrowserToolsIntegrationTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func openPage() {
        app.open(URL(string: "soulo://search")!)
        let field = app.textFields.firstMatch
        if !field.waitForExistence(timeout: 2) { app.buttons["首页"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap(); field.typeText("http://127.0.0.1:8898/reader.html\n")
        XCTAssertTrue(app.webViews.links["下载测试文件"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }
    func launch() {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-ad_block_enabled", "YES"]
        app.launch(); openPage()
    }
    func toolsMenu() {
        app.buttons["更多"].firstMatch.tap()
        app.buttons["网页工具"].firstMatch.tap()
    }
    func testHomeMenuIcons() {
        launch()
        app.buttons["首页"].firstMatch.tap()
        app.buttons["home.menu"].tap()
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5))
        shot("home-menu-neutral-icons")
    }
    func testClipboardTextPreview() {
        continueAfterFailure = false
        defer { UIPasteboard.general.items = [] }
        let clipboard = "https://example.com/clipboard-preview?text=" + String(repeating: "这是剪贴板预览内容", count: 50)
        UIPasteboard.general.string = clipboard
        app.launchArguments = ["-app_language", "zh-Hans"]
        app.launch()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["允许粘贴"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        let preview = app.staticTexts["clipboard.preview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(preview.label.hasPrefix("https://example.com/clipboard-preview"), preview.label)
        XCTAssertTrue(preview.label.hasSuffix("…"), preview.label)
        XCTAssertLessThanOrEqual(preview.label.count, 241)
        shot("clipboard-text-preview")
        app.buttons["取消"].firstMatch.tap()
    }

    func testReaderInExtensionCenterAndMediaIcon() {
        launch(); toolsMenu()
        let ad = app.buttons["browser.ad-block-management"]
        XCTAssertTrue(ad.waitForExistence(timeout: 5))
        let media = app.buttons["browser.media-speed"]
        XCTAssertTrue(media.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertLessThan(ad.frame.minY, media.frame.minY)
        shot("page-tools-ad-first")
        media.tap()
        XCTAssertTrue(app.buttons["1.5×"].waitForExistence(timeout: 5), app.debugDescription)
        shot("media-rate-neutral-icon")
        app.buttons["完成"].firstMatch.tap()
        toolsMenu(); app.buttons["browser.extensions"].tap()
        let reader = app.switches["extensions.reader-toggle"]
        for _ in 0..<4 {
            if reader.exists && reader.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(reader.waitForExistence(timeout: 5), app.debugDescription)
        let wasEnabled = reader.value as? String == "1"
        if !wasEnabled { reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(reader.value as? String, "1")
        shot("extension-built-in-reader-switch")
        app.buttons["完成"].firstMatch.tap()
        app.buttons["更多"].firstMatch.tap()
        app.buttons["脚本命令"].tap()
        app.buttons["browser.reader-command"].tap()
        XCTAssertTrue(app.navigationBars["阅读模式"].waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(app.webViews.staticTexts["阅读工具测试"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        shot("extension-reader-content")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(app.webViews.links["下载测试文件"].firstMatch.waitForExistence(timeout: 5))
        if !wasEnabled {
            toolsMenu(); app.buttons["browser.extensions"].tap()
            for _ in 0..<4 {
                if reader.exists && reader.isHittable { break }
                app.swipeUp()
            }
            reader.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            XCTAssertEqual(reader.value as? String, "0")
            app.buttons["完成"].firstMatch.tap()
            app.buttons["更多"].firstMatch.tap()
            if app.buttons["脚本命令"].exists { app.buttons["脚本命令"].tap() }
            XCTAssertFalse(app.buttons["browser.reader-command"].exists)
        }
    }

    func testDownloadCompletionToastOpensDownloads() {
        launch()
        app.buttons["首页"].firstMatch.tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("http://127.0.0.1:8898/Soulo-Toast-QA.bin\n")
        let toast = app.buttons["downloads.completion-toast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(toast.label.contains("下载完成"), toast.label)
        shot("download-completion-toast")
        toast.tap()
        XCTAssertTrue(app.navigationBars["资料库"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Soulo-Toast-QA")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        shot("download-toast-library")
    }
    func testTopTabBarToggle() {
        launch()
        let tabs = app.buttons["browser.tabs"]
        let initialCount = Int(tabs.label.split(separator: " ").first ?? "0") ?? 0
        tabs.tap()
        app.buttons["tabs.options"].tap()
        let toggle = app.switches["tabs.show-top-bar"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        let originalValue = toggle.value as? String
        if originalValue != "1" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        shot("tab-overview-top-bar-setting")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
        if initialCount < 2 {
            app.buttons["tabs.tab_new_tab"].tap()
            openPage()
        } else {
            app.buttons["tabs.done"].tap()
        }
        let bar = app.descendants(matching: .any).matching(identifier: "browser.top-tab-bar").firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), app.debugDescription)
        tabs.tap(); app.buttons["tabs.options"].tap(); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap(); app.buttons["tabs.done"].tap()
        XCTAssertTrue(bar.waitForNonExistence(timeout: 5), app.debugDescription)
        shot("top-tab-bar-hidden")
        tabs.tap(); app.buttons["tabs.options"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap(); app.buttons["tabs.done"].tap()
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        shot("top-tab-bar-visible")
        if initialCount < 2 {
            tabs.tap()
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.48))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)))
            app.buttons["tabs.done"].tap()
            XCTAssertEqual(Int(tabs.label.split(separator: " ").first ?? "0"), initialCount)
            XCTAssertTrue(bar.waitForNonExistence(timeout: 5))
        }
        if originalValue != "1" {
            tabs.tap(); app.buttons["tabs.options"].tap(); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap(); app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap(); app.buttons["tabs.done"].tap()
        }
    }
}
