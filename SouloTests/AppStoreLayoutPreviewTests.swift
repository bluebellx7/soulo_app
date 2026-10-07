import SwiftData
import SwiftUI
import XCTest
@testable import Soulo

/// These are real view renders at requested canvas sizes, NOT Duo simulator
/// screenshots. Keep the exported images in a clearly marked preview folder.
@MainActor final class AppStoreLayoutPreviewTests: XCTestCase {
    private static var retainedContainer: ModelContainer?

    func testCaptureDuoLayoutPreviews() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SOULO_CAPTURE_STORE_ASSETS"] == "1")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.keyWindow
        let container = try ModelContainer(for: SearchHistoryItem.self, BookmarkItem.self, BookmarkFolder.self,
            configurations: ModelConfiguration("StoreLayoutPreviews", isStoredInMemoryOnly: true))
        Self.retainedContainer = container
        let oldLanguage = LanguageManager.shared.selectedLanguage
        let wallpaper = WallpaperManager.shared
        let oldSource = wallpaper.source
        let oldGradient = wallpaper.selectedGradientId
        let defaults = UserDefaults.standard
        let keys = ["show_recent_searches_on_home", "show_group_picker_on_home", "platform_management_layout", "reader.theme", "reader.fontSize"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            LanguageManager.shared.selectedLanguage = oldLanguage
            wallpaper.source = oldSource; wallpaper.selectedGradientId = oldGradient
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            previous?.makeKeyAndVisible()
        }
        defaults.set(false, forKey: keys[0]); defaults.set(true, forKey: keys[1])
        defaults.set("grid", forKey: keys[2]); defaults.set("paper", forKey: keys[3]); defaults.set(19.0, forKey: keys[4])
        wallpaper.source = .gradient; wallpaper.selectedGradientId = "dawn"
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "store-samples", withExtension: "json", subdirectory: "ReadingFixtures"))
        let samples = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: fixtureURL))
        for language in ["zh-Hans", "en-US"] {
            LanguageManager.shared.selectedLanguage = language
            let search = SearchViewModel()
            let storageKey = "store-preview-tabs-\(language)"
            defaults.set(Data(), forKey: storageKey)
            let tabs = TabManager(storageKey: storageKey)
            let file = BookLibrary.directory.appendingPathComponent(language == "zh-Hans" ? "沿着河流慢慢走.txt" : "A Walk Along the River.txt")
            try FileManager.default.createDirectory(at: BookLibrary.directory, withIntermediateDirectories: true)
            try XCTUnwrap(samples[language]).write(to: file, atomically: true, encoding: .utf8)
            let book = try await BookLibrary.shared.add(file)
            let views: [(String, CGSize, AnyView, UIUserInterfaceSizeClass)] = [
                ("01-outer-home", CGSize(width: 466, height: 678), AnyView(HomeView()), .compact),
                ("02-inner-platforms", CGSize(width: 669, height: 951), AnyView(NavigationStack { PlatformManagementView() }), .regular),
                ("03-inner-reader", CGSize(width: 951, height: 669), AnyView(NavigationStack { BookReaderView(book: book) }), .regular)
            ]
            for (name, size, view, horizontal) in views {
                let host = UIHostingController(rootView: AnyView(view
                    .environmentObject(search).environmentObject(tabs)
                    .environmentObject(LanguageManager.shared).environmentObject(ThemeManager.shared)
                    .environmentObject(wallpaper).modelContainer(container)
                    .environment(\.colorScheme, .light)))
                host.traitOverrides.horizontalSizeClass = horizontal
                host.traitOverrides.verticalSizeClass = .regular
                host.traitOverrides.userInterfaceIdiom = .phone
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = host; window.makeKeyAndVisible()
                host.view.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                try await Task.sleep(for: .seconds(3))
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = true
                let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.systemBackground.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let data = try XCTUnwrap(image.pngData())
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "duo-preview-\(language)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
                host.rootView = AnyView(EmptyView())
                window.isHidden = true; window.rootViewController = nil
                try await Task.sleep(for: .milliseconds(200))
            }
            defaults.removeObject(forKey: storageKey)
        }
    }
}
