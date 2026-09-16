import XCTest

final class BookmarkLibraryUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    func tap(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8), app.debugDescription)
        Thread.sleep(forTimeInterval: 0.5); element.tap(); Thread.sleep(forTimeInterval: 0.7)
    }
    func menu() { tap(app.buttons["favorites.manage"]) }
    func launch() {
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", "light"]
        app.launch(); app.open(URL(string: "soulo://bookmarks")!)
        XCTAssertTrue(app.buttons["favorites.manage"].waitForExistence(timeout: 10))
    }
    func create(_ name: String) {
        menu(); tap(app.buttons["新建文件夹"])
        let field = app.alerts.textFields.firstMatch
        tap(field); field.typeText(name)
        tap(app.alerts.buttons["完成"])
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.waitForExistence(timeout: 5))
    }
    func testFolderCreateRenameMoveDeleteAndExport() {
        launch()
        let name = "QA Folder " + String(Int(Date().timeIntervalSince1970))
        create(name)
        let folder = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        tap(folder)
        create("QA Child")
        tap(app.buttons["favorites.parent"])
        Thread.sleep(forTimeInterval: 1.5)
        folder.swipeLeft()
        tap(app.buttons["重命名"])
        let field = app.alerts.textFields.firstMatch
        tap(field)
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: name.count) + name + " Renamed")
        tap(app.alerts.buttons["完成"])
        let renamed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name + " Renamed")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 5))
        shot("bookmark-folders-created")
        menu(); tap(app.buttons["导出"])
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        shot("bookmark-export-file-picker")
        let exportName = app.textFields["DOCPicker.filenameTextField"]
        tap(exportName)
        exportName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Soulo-Bookmarks".count) + "Soulo-QA-Export-" + String(Int(Date().timeIntervalSince1970)))
        tap(app.buttons["保存"])
        XCTAssertTrue(app.alerts.staticTexts["收藏已导出。"].waitForExistence(timeout: 8))
        tap(app.alerts.buttons["完成"])
        renamed.swipeLeft()
        tap(app.buttons["删除"])
        XCTAssertTrue(app.alerts["删除文件夹？"].waitForExistence(timeout: 5))
        shot("bookmark-folder-safe-removal")
        tap(app.alerts.buttons["删除"])
        let child = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA Child'")).firstMatch
        XCTAssertTrue(child.waitForExistence(timeout: 5))
        child.swipeLeft(); tap(app.buttons["删除"]); tap(app.alerts.buttons["删除"])
    }
    func testImportMoveAndDuplicateHandling() {
        launch(); menu(); tap(app.buttons["导入"])
        Thread.sleep(forTimeInterval: 2)
        shot("bookmark-import-file-picker")
        tap(app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Soulo-QA-Bookmarks, html'")).firstMatch)
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS '新增 2 条收藏、3 个文件夹'")).firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        shot("bookmark-import-result")
        tap(app.alerts.buttons["完成"])
        menu(); tap(app.buttons["导入"])
        tap(app.cells.matching(NSPredicate(format: "label BEGINSWITH 'Soulo-QA-Bookmarks, html'")).firstMatch)
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS '跳过 2 条重复收藏'")).firstMatch.waitForExistence(timeout: 8))
        tap(app.alerts.buttons["完成"])
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'QA Browser Bookmarks'")).firstMatch)
        shot("bookmark-imported-hierarchy")
        let example = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Example'")).firstMatch
        XCTAssertTrue(example.waitForExistence(timeout: 5)); example.press(forDuration: 1.2)
        tap(app.buttons["移动到文件夹"])
        tap(app.buttons.matching(NSPredicate(format: "label == 'Empty folder'")).firstMatch)
        tap(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Empty folder'")).firstMatch)
        XCTAssertTrue(example.waitForExistence(timeout: 5))
        shot("bookmark-moved-to-folder")
    }
}
