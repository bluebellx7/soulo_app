import UIKit
import WebKit
import XCTest
@testable import Soulo

@MainActor
final class KeyboardDismissalTests: XCTestCase {
    func testRepeatedPageAndSheetInstallationKeepsOneGesturePerWindow() {
        let window = UIWindow()
        AppKeyboardDismissal.install(on: window)
        AppKeyboardDismissal.install(on: window)
        XCTAssertEqual(window.gestureRecognizers?.filter { $0 is BackgroundKeyboardDismissGesture }.count, 1)
        let other = UIWindow()
        AppKeyboardDismissal.install(on: other)
        XCTAssertEqual(other.gestureRecognizers?.filter { $0 is BackgroundKeyboardDismissGesture }.count, 1)
        XCTAssertFalse(window.gestureRecognizers?.first === other.gestureRecognizers?.first)
    }

    func testBlankContentAcceptsDismissalAndEditorOrControlDescendantsKeepTheirInteraction() {
        XCTAssertTrue(AppKeyboardDismissal.acceptsBackgroundTap(on: UIView()))
        let editors: [UIView] = [UITextField(), UITextView(), UIButton(), UISlider(), WKWebView()]
        for editor in editors {
            let child = UIView()
            editor.addSubview(child)
            XCTAssertFalse(AppKeyboardDismissal.acceptsBackgroundTap(on: editor))
            XCTAssertFalse(AppKeyboardDismissal.acceptsBackgroundTap(on: child))
        }
        XCTAssertFalse(AppKeyboardDismissal.acceptsBackgroundTap(on: nil))
    }

    func testWindowTapDoesNotCancelOrDelayPageAndButtonTouches() throws {
        let window = UIWindow()
        AppKeyboardDismissal.install(on: window)
        let gesture = try XCTUnwrap(window.gestureRecognizers?.first { $0 is BackgroundKeyboardDismissGesture })
        XCTAssertFalse(gesture.cancelsTouchesInView)
        XCTAssertFalse(gesture.delaysTouchesBegan)
        XCTAssertFalse(gesture.delaysTouchesEnded)
    }

    func testEditorAccessoryRegionsUseTheirCurrentWindowAndAreReleasedWithTheirView() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let content = UIViewController()
        window.rootViewController = content
        window.addSubview(content.view)
        let gesture = AppKeyboardDismissal.install(on: window)
        var accessory: UIView? = UIView(frame: CGRect(x: 20, y: 40, width: 200, height: 44))
        content.view.addSubview(accessory!)
        gesture.preserveFocus(in: accessory!)
        XCTAssertTrue(gesture.preservesFocus(at: CGPoint(x: 30, y: 50), touchedView: content.view))
        XCTAssertFalse(gesture.preservesFocus(at: CGPoint(x: 10, y: 50), touchedView: content.view))
        let sheet = UIViewController()
        window.addSubview(sheet.view)
        XCTAssertFalse(gesture.preservesFocus(at: CGPoint(x: 30, y: 50), touchedView: sheet.view))
        accessory?.isHidden = true
        XCTAssertFalse(gesture.preservesFocus(at: CGPoint(x: 30, y: 50), touchedView: content.view))
        accessory?.isHidden = false
        accessory?.frame.origin.y = 100
        XCTAssertFalse(gesture.preservesFocus(at: CGPoint(x: 30, y: 50), touchedView: content.view))
        XCTAssertTrue(gesture.preservesFocus(at: CGPoint(x: 30, y: 110), touchedView: content.view))
        accessory?.removeFromSuperview()
        accessory = nil
        XCTAssertFalse(gesture.preservesFocus(at: CGPoint(x: 30, y: 110), touchedView: content.view))
    }
}
