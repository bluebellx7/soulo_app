import XCTest
import SwiftUI
@testable import Soulo

final class LocalizationLayoutTests: XCTestCase {
    func testToolLabelsUseSelectedAndRegionalLanguagesWithoutChangingPreferences() {
        let saved = UserDefaults.standard.object(forKey: "app_language") as? String
        XCTAssertEqual(ToolText.text("files", language: "de-DE"), "Dateien")
        XCTAssertEqual(ToolText.text("bookshelf", language: "fr-FR"), "Livres")
        XCTAssertEqual(ToolText.text("cancel", language: "ja-JP"), "キャンセル")
        XCTAssertEqual(ToolText.text("line_height", language: "zh-Hant-TW"), "行高")
        XCTAssertEqual(ToolText.text("wifi_hint", language: "de-DE"), ToolText.text("wifi_hint", language: "en-US"))
        XCTAssertEqual(UserDefaults.standard.object(forKey: "app_language") as? String, saved)
    }

    @MainActor
    func testLibraryCaptionsRenderAcrossAllLanguagesAtNarrowWidth() async throws {
        let manager = LanguageManager.shared
        let original = manager.currentLanguage
        defer { manager.currentLanguage = original }
        let snapshotLocales = Set(["zh-Hans", "de-DE", "fr-FR", "ar-SA", "ta-IN", "ja"])
        for language in AppConstants.supportedLanguages {
            manager.currentLanguage = language.code
            let rtl = Locale.Language(identifier: language.code).characterDirection == .rightToLeft
            let view = LibrarySectionSwitcher(selectedSection: .constant(.files))
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: 320)
            let image = try await snapshot(view)
            XCTAssertEqual(image.size.width, 320, accuracy: 0.5, language.code)
            XCTAssertGreaterThanOrEqual(image.size.height, 84, language.code)
            XCTAssertLessThan(image.size.height, 200, language.code)
            if snapshotLocales.contains(language.code) {
                let attachment = XCTAttachment(image: image)
                attachment.name = "library-320-\(language.code)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            for key in ["files", "bookshelf", "cancel", "done", "share", "delete_files"] {
                let value = ToolText.text(key, language: language.code)
                XCTAssertFalse(value.isEmpty, "\(language.code):\(key)")
                XCTAssertNotEqual(value, key, "\(language.code):\(key)")
            }
        }
    }

    @MainActor
    func testLongLanguageActionsCanGrowWithAccessibilityText() async throws {
        let manager = LanguageManager.shared
        let original = manager.currentLanguage
        defer { manager.currentLanguage = original }
        for code in ["de-DE", "fr-FR", "ar-SA", "ta-IN"] {
            manager.currentLanguage = code
            let view = VStack(spacing: 20) {
                LibrarySectionSwitcher(selectedSection: .constant(.files))
                AdaptiveActionRow {
                    Button(manager.localizedString("share")) {}.buttonStyle(CompactActionButtonStyle())
                    Button(manager.localizedString("delete")) {}.buttonStyle(CompactActionButtonStyle())
                }.padding(.horizontal, 16)
            }
            .environment(\.dynamicTypeSize, .accessibility3)
            .environment(\.layoutDirection, code == "ar-SA" ? .rightToLeft : .leftToRight)
            .frame(width: 320)
            let image = try await snapshot(view)
            XCTAssertEqual(image.size.width, 320, accuracy: 0.5)
            XCTAssertGreaterThan(image.size.height, 150)
            let attachment = XCTAttachment(image: image)
            attachment.name = "accessibility-320-\(code)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testFullscreenLongLanguageSnapshots() async throws {
        let manager = LanguageManager.shared
        let original = manager.currentLanguage
        defer { manager.currentLanguage = original }
        for code in ["de-DE", "fr-FR", "ar-SA", "ta-IN"] {
            manager.currentLanguage = code
            let model = WebViewModel()
            model.currentURL = URL(string: "https://example.com")
            let menu = FullscreenQuickMenu(webViewModel: model, title: "Example",
                isBookmarked: false, isDesktopMode: false, canSwitchContentMode: true, onAction: { _ in })
                .environment(\.layoutDirection, code == "ar-SA" ? .rightToLeft : .leftToRight)
                .frame(width: 320)
            let image = try await snapshot(menu)
            XCTAssertLessThan(image.size.height, 600, code)
            let attachment = XCTAttachment(image: image)
            attachment.name = "fullscreen-320-\(code)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func snapshot<V: View>(_ content: V) async throws -> UIImage {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        let size = host.sizeThatFits(in: CGSize(width: 320, height: 1200))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // ScrollView uses a UIKit-backed layer which ImageRenderer does not capture.
        try await Task.sleep(for: .milliseconds(100))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertGreaterThan(image.pngData()?.count ?? 0, 2500, "Snapshot must contain rendered controls")
        return image
    }
}
