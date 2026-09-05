import XCTest
import SwiftUI
@testable import Soulo

@MainActor
final class BrowserUIPreferencesTests: XCTestCase {
    func testNewDefaultsDoNotWritePreferences() throws {
        let suite = "Soulo.InitialPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(BrowserInitialPreferences.wallpaperSource(in: defaults), .pixabay)
        XCTAssertEqual(BrowserInitialPreferences.wallpaperTopic(in: defaults), "Nature")
        let searchBar = AppStorage(wrappedValue: BrowserInitialPreferences.showTopSearchBar,
                                   "show_top_search_bar", store: defaults)
        XCTAssertFalse(searchBar.wrappedValue)
        XCTAssertNil(defaults.object(forKey: "wallpaper_source"))
        XCTAssertNil(defaults.object(forKey: "wallpaper_topic"))
        XCTAssertNil(defaults.object(forKey: "show_top_search_bar"))
    }

    func testSavedPreferencesTakePriorityOverNewDefaults() throws {
        let suite = "Soulo.SavedPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(WallpaperSource.pexels.rawValue, forKey: "wallpaper_source")
        defaults.set("Architecture", forKey: "wallpaper_topic")
        for enabled in [true, false] {
            defaults.set(enabled, forKey: "show_top_search_bar")
            let searchBar = AppStorage(wrappedValue: BrowserInitialPreferences.showTopSearchBar,
                                       "show_top_search_bar", store: defaults)
            XCTAssertEqual(searchBar.wrappedValue, enabled)
            XCTAssertEqual(BrowserInitialPreferences.wallpaperSource(in: defaults), .pexels)
            XCTAssertEqual(BrowserInitialPreferences.wallpaperTopic(in: defaults), "Architecture")
        }
        XCTAssertEqual(defaults.string(forKey: "wallpaper_source"), WallpaperSource.pexels.rawValue)
        XCTAssertEqual(defaults.string(forKey: "wallpaper_topic"), "Architecture")
    }

    func testNewToolbarOptionsRoundTripWithoutChangingExistingLayout() throws {
        let suite = "Soulo.ToolbarUpgrade.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldLayout = ["share", "none", "translate", "more"]
        defaults.set(oldLayout, forKey: BrowserToolbarConfigurationService.actionsKey)
        defaults.set("copyLink", forKey: BrowserToolbarConfigurationService.addressActionKey)
        let service = BrowserToolbarConfigurationService(defaults: defaults)
        service.reloadFromDefaults()
        XCTAssertEqual(service.actions.map(\.rawValue), oldLayout)
        XCTAssertEqual(service.addressAction, .copyLink)
        XCTAssertEqual(defaults.stringArray(forKey: BrowserToolbarConfigurationService.actionsKey), oldLayout)
        for action: BrowserToolbarAction in [.readerMode, .resources, .files, .books, .downloads, .wifiTransfer, .adBlock] {
            service.save(actions: [action, .back, .tabs, .more], addressAction: action)
            let restored = BrowserToolbarConfigurationService(defaults: defaults)
            XCTAssertEqual(restored.actions.first, action)
            XCTAssertEqual(restored.addressAction, action)
            XCTAssertFalse(action.localizedTitle.isEmpty)
            XCTAssertNotEqual(action.localizedTitle, action.titleKey)
        }
    }

    func testPresentedKeywordSelectsAllOnceAndPreservesLaterEdits() async throws {
        struct Harness: View {
            @State var presented = false
            var body: some View {
                Color.clear.onAppear { presented = true }
                    .sheet(isPresented: $presented) {
                        BrowserAddressEditorSheet(initialText: "电影", initialURL: "https://example.com",
                                                  onOpen: { _ in }, onVoiceInput: {})
                    }
            }
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Harness())
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKeyAndVisible() }
        func field(in view: UIView) -> PresentationSearchField.Field? {
            if let value = view as? PresentationSearchField.Field { return value }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        var candidate: PresentationSearchField.Field?
        for _ in 0..<100 {
            candidate = field(in: window)
            if candidate?.isFirstResponder == true, candidate?.selectedTextRange?.isEmpty == false { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        let input = try XCTUnwrap(candidate)
        XCTAssertTrue(input.isFirstResponder)
        XCTAssertEqual(input.text(in: try XCTUnwrap(input.selectedTextRange)), "电影")
        input.insertText("小说")
        input.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(input.text, "小说", "Typing should replace the selected query")
        let caret = try XCTUnwrap(input.position(from: input.beginningOfDocument, offset: 1))
        input.selectedTextRange = input.textRange(from: caret, to: caret)
        input.selectInitialText()
        XCTAssertEqual(input.offset(from: input.beginningOfDocument,
                                    to: try XCTUnwrap(input.selectedTextRange).start), 1)
        input.resignFirstResponder()
        input.becomeFirstResponder()
        try await Task.sleep(for: .milliseconds(100))
        let selection = try XCTUnwrap(input.selectedTextRange)
        XCTAssertTrue(selection.isEmpty, "Re-focusing must not select everything again")
        input.resignFirstResponder()
        window.rootViewController?.dismiss(animated: false)
        try await Task.sleep(for: .milliseconds(300))
    }
    func testCapturePreviewFitsLargeImageInsideItsDisplayArea() async throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 2000)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 2000))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: WebPageCapturePreview(
            result: WebPageCaptureResult(image: image, mode: .viewport, wasHeightLimited: false)))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        func findImage(in view: UIView) -> UIImageView? {
            if let view = view as? UIImageView, view.image === image { return view }
            return view.subviews.lazy.compactMap { findImage(in: $0) }.first
        }
        let preview = try XCTUnwrap(findImage(in: window))
        let frame = preview.convert(preview.bounds, to: window)
        XCTAssertGreaterThan(frame.width, 100)
        XCTAssertLessThanOrEqual(frame.width, window.bounds.width - 32)
        XCTAssertGreaterThanOrEqual(frame.minX, 16)
        XCTAssertGreaterThan(frame.minY, window.safeAreaInsets.top + 44)
        XCTAssertLessThan(frame.maxY, window.bounds.height - window.safeAreaInsets.bottom - 44)
    }

    func testAdaptiveActionsStackWithoutClippingAndRespectRightToLeft() async throws {
        final class Frames { var values: [Int: CGRect] = [:] }
        let frames = Frames()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func render(width: CGFloat, large: Bool, rtl: Bool) async throws -> [CGRect] {
            frames.values = [:]
            let row = AdaptiveActionRow {
                ForEach(0..<2) { index in
                    Button(index == 0 ? "Restore default toolbar" : "Save") {}
                        .buttonStyle(CompactActionButtonStyle(prominent: index == 1, fillsHeight: true))
                        .background {
                            GeometryReader { geometry in
                                Color.clear.onAppear { frames.values[index] = geometry.frame(in: .global) }
                            }
                        }
                }
            }
            .frame(width: width)
            .environment(\.dynamicTypeSize, large ? .accessibility1 : .large)
            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
            window.rootViewController = UIHostingController(rootView: row)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(200))
            return try [XCTUnwrap(frames.values[0]), XCTUnwrap(frames.values[1])]
        }
        let stacked = try await render(width: 280, large: true, rtl: false)
        XCTAssertLessThanOrEqual(stacked[0].maxY, stacked[1].minY)
        for frame in stacked {
            XCTAssertEqual(frame.width, 280, accuracy: 1)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
        }
        let horizontal = try await render(width: 390, large: false, rtl: false)
        XCTAssertLessThan(horizontal[0].minX, horizontal[1].minX)
        XCTAssertEqual(horizontal[0].height, horizontal[1].height, accuracy: 1)
        let reversed = try await render(width: 390, large: false, rtl: true)
        XCTAssertGreaterThan(reversed[0].minX, reversed[1].minX)
        XCTAssertEqual(reversed[0].height, reversed[1].height, accuracy: 1)
    }

}
