import XCTest
import UIKit
import CoreImage

final class PageQRCodeUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.dkluge.Soulo")
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func openPage(appearance: String) {
        continueAfterFailure = false
        app.launchArguments = ["-app_language", "zh-Hans", "-appearance", appearance]
        app.launch(); app.open(URL(string: "soulo://search")!)
        let field = app.textFields.firstMatch
        if !field.waitForExistence(timeout: 2) { app.buttons["首页"].firstMatch.tap() }
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        field.tap(); field.typeText("http://127.0.0.1:8898/index.html\n")
        XCTAssertTrue(app.webViews.staticTexts["正常文章内容"].waitForExistence(timeout: 10))
        app.buttons["browser.siteInformation"].tap()
        XCTAssertTrue(app.buttons["site.qr-code"].waitForExistence(timeout: 5))
        shot("site-card-contrast-" + appearance)
        app.buttons["site.qr-code"].tap()
        XCTAssertTrue(app.images["pageQR.image"].waitForExistence(timeout: 10), app.debugDescription)
        shot("page-qr-" + appearance)
    }
    func testQRCodeShareAndSave() {
        openPage(appearance: "light")
        XCTAssertTrue(app.buttons["pageQR.share"].isEnabled)
        app.buttons["pageQR.share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 8), app.debugDescription)
        shot("page-qr-share")
        app.buttons["header.closeButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["pageQR.save"].waitForExistence(timeout: 5))
        app.buttons["pageQR.save"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label == 'Allow' OR label == '允许' OR label == '好' OR label == '允许添加照片'")).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'pageQR.save' AND label CONTAINS '已保存'")).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        shot("page-qr-saved")
        app.buttons["完成"].firstMatch.tap()
    }
    // Run after `simctl privacy ... revoke photos-add com.dkluge.Soulo`.
    func testDeniedPhotoPermissionShowsError() {
        openPage(appearance: "light")
        app.buttons["pageQR.save"].tap()
        XCTAssertTrue(app.otherElements["pageQR.error"].waitForExistence(timeout: 5)
                      || app.staticTexts["请在系统设置中允许 Soulo 添加照片，然后重试。"].exists,
                      app.debugDescription)
        XCTAssertTrue(app.buttons["pageQR.save"].isEnabled)
        shot("page-qr-permission-denied")
        app.buttons["完成"].firstMatch.tap()
    }
    func testCopyQRCodeImageRoundTripsAddress() throws {
        openPage(appearance: "light")
        let copy = app.buttons["pageQR.copy"]
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        XCTAssertTrue(copy.label.contains("已复制"))
        shot("page-qr-copied")
        let image = try XCTUnwrap(UIPasteboard.general.image, "The clipboard must contain an image, not just a URL")
        let cgImage = try XCTUnwrap(image.cgImage)
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let address = detector.features(in: CIImage(cgImage: cgImage)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
        XCTAssertEqual(address, "http://127.0.0.1:8898/index.html")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == '复制图片'"), object: copy)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        app.buttons["完成"].firstMatch.tap()
    }
    func testDarkQRCode() {
        openPage(appearance: "dark")
        XCTAssertTrue(app.buttons["pageQR.share"].isEnabled)
        app.buttons["完成"].firstMatch.tap()
    }
}
