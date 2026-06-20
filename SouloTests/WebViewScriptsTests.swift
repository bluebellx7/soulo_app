import XCTest
@testable import Soulo

final class WebViewScriptsTests: XCTestCase {
    func testElementPickerPublishesSelectorAndXPath() {
        let script = WebViewScripts.elementPicker

        XCTAssertTrue(script.contains("selectorCandidates"))
        XCTAssertTrue(script.contains("xpathFor"))
        XCTAssertTrue(script.contains("souloElementBlocker"))
        XCTAssertTrue(script.contains("selector: selector"))
        XCTAssertTrue(script.contains("xpath: xpath"))
        XCTAssertTrue(script.contains("cssAttributeValue"))
        XCTAssertTrue(script.contains("isUsableSelector"))
        XCTAssertTrue(script.contains("dedupe"))
    }

    func testElementPickerCancelsPageClicksWhileSelecting() {
        let script = WebViewScripts.elementPicker

        XCTAssertTrue(script.contains("stopImmediatePropagation"))
        XCTAssertTrue(script.contains("soulo-element-picker-shield"))
        XCTAssertTrue(script.contains("touch-action:none"))
        XCTAssertTrue(script.contains("underlyingElementAt"))
        XCTAssertTrue(script.contains("passive: false"))
        XCTAssertTrue(script.contains("s.addEventListener('pointerdown', onPreClick, eventOptions)"))
        XCTAssertTrue(script.contains("s.addEventListener('pointerup', onClick, eventOptions)"))
        XCTAssertTrue(script.contains("document.addEventListener('auxclick', onPreClick, eventOptions)"))
        XCTAssertTrue(script.contains("shield.remove()"))
    }

    func testElementPickerSupportsParentSelectionFallback() {
        let script = WebViewScripts.elementPicker

        XCTAssertTrue(script.contains("选择父级"))
        XCTAssertTrue(script.contains("showHighlight(el.parentElement)"))
        XCTAssertTrue(script.contains("showMenu(el.parentElement, x, y)"))
    }

    func testInitialElementBlockStyleEscapesInjectedCSS() {
        let script = WebViewScripts.initialElementBlockStyle(css: #"div[data-title="ad"]"#)

        XCTAssertTrue(script.contains("soulo-element-block-style"))
        XCTAssertTrue(script.contains(#"div[data-title="ad"]"#))
    }

    func testAdHidingScriptPublishesHiddenElementStats() {
        let script = AdBlockService.adHidingScript(cosmetic: true, popups: true)

        XCTAssertTrue(script.contains("souloAdBlocker"))
        XCTAssertTrue(script.contains("hiddenCount"))
        XCTAssertTrue(script.contains("location.hostname"))
    }

    func testAdHidingScriptCoversChineseVideoSiteFloatingAds() {
        let script = AdBlockService.adHidingScript(cosmetic: true, popups: true)

        XCTAssertTrue(script.contains(".cpcad"))
        XCTAssertTrue(script.contains("gudingwei"))
        XCTAssertTrue(script.contains("isLikelyFloatingAd"))
        XCTAssertTrue(script.contains("position !== 'fixed' && position !== 'absolute'"))
    }
}
