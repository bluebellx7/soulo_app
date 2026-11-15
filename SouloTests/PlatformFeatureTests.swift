import XCTest
import WebKit
import AVKit
import SwiftUI
@testable import Soulo

@MainActor
final class PlatformFeatureTests: XCTestCase {
    private func manager() -> TabManager {
        let key = "platform-test-" + UUID().uuidString
        addTeardownBlock {
            for suffix in ["", ".overview_groups", ".desktop_mode"] { UserDefaults.standard.removeObject(forKey: key + suffix) }
        }
        return TabManager(storageKey: key)
    }

    func testWindowTransferPreservesDocumentAndBackHistoryAndClaimsOnlyOnce() async throws {
        let source = manager(), destination = manager()
        let tab = try XCTUnwrap(source.activeTab)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let web = WKWebView(frame: .zero)
        tab.webViewModel.webView = web
        for filename in ["first.html", "second.html"] {
            let file = directory.appendingPathComponent(filename)
            try Data("<title>\(filename)</title><p>Local transfer fixture</p>".utf8).write(to: file)
            web.loadFileURL(file, allowingReadAccessTo: directory)
            for _ in 0..<250 {
                if !web.isLoading, web.url == file { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(web.url, file)
            XCTAssertFalse(web.isLoading)
        }
        _ = try await web.evaluateJavaScript("window.transferSentinel=484")
        let backList = web.backForwardList.backList.map(\.url)
        XCTAssertFalse(backList.isEmpty)
        let configuration = try XCTUnwrap(BrowserWindowTransferService.shared.prepare(from: source, tabID: tab.id))
        XCTAssertTrue(source.tabs.contains { $0.id == tab.id }, "A request alone must not remove the source tab")
        XCTAssertTrue(BrowserWindowTransferService.shared.claim(windowID: configuration.id, into: destination))
        XCTAssertFalse(BrowserWindowTransferService.shared.claim(windowID: configuration.id, into: destination))
        XCTAssertFalse(source.tabs.contains { $0.id == tab.id })
        XCTAssertFalse(source.tabs.isEmpty)
        XCTAssertTrue(destination.activeWebViewModel === tab.webViewModel)
        XCTAssertEqual(destination.tabs.count, 1, "Do not retain the newly opened window's unused placeholder")
        XCTAssertTrue(destination.activeWebViewModel?.webView === web)
        XCTAssertEqual(web.backForwardList.backList.map(\.url), backList)
        let sentinel = try await web.evaluateJavaScript("window.transferSentinel") as? Int
        XCTAssertEqual(sentinel, 484)
        XCTAssertTrue(source.recentlyClosed.isEmpty)
    }

    func testWindowTransferDoesNotStealTabsWhenPrivacyChanges() throws {
        let previous = UserDefaults.standard.object(forKey: "is_incognito")
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: "is_incognito") }
            else { UserDefaults.standard.removeObject(forKey: "is_incognito") }
        }
        UserDefaults.standard.set(false, forKey: "is_incognito")
        let source = manager(), destination = manager()
        let tab = try XCTUnwrap(source.activeTab)
        let configuration = try XCTUnwrap(BrowserWindowTransferService.shared.prepare(from: source, tabID: tab.id))
        UserDefaults.standard.set(true, forKey: "is_incognito")
        XCTAssertFalse(BrowserWindowTransferService.shared.claim(windowID: configuration.id, into: destination))
        XCTAssertTrue(source.tabs.contains { $0.id == tab.id })
    }

    func testUnavailableSummaryModelRetainsDeterministicFallbackAndCancellation() async throws {
        let text = "Soulo is a browser with independent windows and local bookmarks. It supports webpage search across several platforms. All summary processing in this fixture stays on the device."
        let result = try await PageSummaryService.summarizeLocally(text: text, locale: Locale(identifier: "zz-ZZ"))
        XCTAssertEqual(result, PageSummaryService.summarize(text: text))
        let task = Task { try await PageSummaryService.summarizeLocally(text: text) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Canceled summaries must not publish output") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testWebPageEntityRejectsPrivateNetworkAndNonWebIdentifiers() async throws {
        let result = try await SouloWebPageQuery().entities(for: [
            "file:///private/example", "webkit-extension://owner/popup.html", "http://127.0.0.1/", "http://printer.local/",
            "https://user:password@example.com/", "https://example.com/article"
        ])
        XCTAssertEqual(result.map(\.id), ["https://example.com/article"])
        XCTAssertNil(BrowserHandoff.eligibleURL(URL(string: "https://example.com/private"), isPrivate: true))
    }

    func testBookmarkEntitiesSearchSavedPagesAndSaveIdempotently() async throws {
        let store = try LibraryStore(inMemory: true)
        let previous = BrowserIntentLibrary.shared.context
        BrowserIntentLibrary.shared.context = store.mainContext
        defer { BrowserIntentLibrary.shared.context = previous }
        let page = try XCTUnwrap(SouloWebPageEntity(url: URL(string: "https://example.com/article")!, title: "Orchid guide"))
        try BrowserIntentLibrary.shared.save(page)
        try BrowserIntentLibrary.shared.save(page)
        let all = try await SouloWebPageQuery().suggestedEntities()
        let matching = try await SouloWebPageQuery().entities(matching: "Orchid")
        let missing = try await SouloWebPageQuery().entities(matching: "not-a-saved-page")
        XCTAssertEqual(all.count, 1); XCTAssertEqual(matching.first?.id, page.id); XCTAssertTrue(missing.isEmpty)
    }

    func testAppIntentPerformSavesAndReturnsTheValidatedPage() async throws {
        let store = try LibraryStore(inMemory: true)
        let previous = BrowserIntentLibrary.shared.context
        BrowserIntentLibrary.shared.context = store.mainContext
        defer { BrowserIntentLibrary.shared.context = previous }
        let page = try XCTUnwrap(SouloWebPageEntity(url: URL(string: "https://example.com/intent-fixture")!, title: "Acceptance bookmark"))
        var save = SaveWebPageIntent(); save.page = page
        _ = try await save.perform()
        _ = try await save.perform()
        let matches = try await SouloWebPageQuery().entities(matching: "Acceptance bookmark")
        XCTAssertEqual(matches.map(\.id), [page.id])
        var link = WebPageLinkIntent(); link.page = page
        let result = try await link.perform()
        XCTAssertEqual(result.value, page.url)
    }

    func testScopedCookiesExcludeOtherHostsPathsAndSecureCookiesOnHTTP() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        for (domain, path, secure, name) in [
            ("example.com", "/", false, "public"), ("example.com", "/account", false, "account"),
            ("other.example", "/", false, "other"), ("example.com", "/", true, "secure")
        ] {
            var properties: [HTTPCookiePropertyKey: Any] = [.domain: domain, .path: path, .name: name, .value: "fixture"]
            if secure { properties[.secure] = "TRUE" }
            let cookie = try XCTUnwrap(HTTPCookie(properties: properties))
            await withCheckedContinuation { reply in store.setCookie(cookie) { reply.resume() } }
        }
        let cookies = await WebKitCookieAccess.cookies(for: URL(string: "http://example.com/video.mp4")!, in: store)
        XCTAssertEqual(cookies.map(\.name), ["public"])
    }

    func testNativeMediaWorldCanInspectClosedRootsWithoutChangingPageWorld() async throws {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires the public iOS27 content-world API") }
        let web = WKWebView(frame: .zero)
        web.loadHTMLString("<div id='host'></div><script>document.getElementById('host').attachShadow({mode:'closed'}).innerHTML='<video id=fixture></video>';</script>", baseURL: nil)
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("!!document.getElementById('host')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let source = "!!document.getElementById('host').shadowRoot?.querySelector('#fixture')"
        let inMedia = try await web.evaluateCompatibleJavaScript(source, in: nil, contentWorld: WebMediaSession.world)
        let inPage = try await web.evaluateJavaScript(source)
        XCTAssertEqual(inMedia as? Bool, true, "The retained native media world must find the video")
        XCTAssertEqual(inPage as? Bool, false, "Page scripts must retain the original closed-root boundary")
        _ = try await web.evaluateCompatibleJavaScript("window.mediaWorldSentinel=484", in: nil, contentWorld: WebMediaSession.world)
        let retained = try await web.evaluateCompatibleJavaScript("window.mediaWorldSentinel", in: nil, contentWorld: WebMediaSession.world)
        XCTAssertEqual(retained as? Int, 484)
        #else
        throw XCTSkip("Requires Xcode27 public SDK declarations")
        #endif
    }

    func testSystemSubtitleMenuUpdatesWhenTracksArriveAfterMounting() async throws {
        #if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("Requires the native subtitle controller") }
        var files = [String: Data]()
        let master = "#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"captions\",NAME=\"QA English\",LANGUAGE=\"en\",AUTOSELECT=YES,URI=\"subtitles.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=600000,SUBTITLES=\"captions\"\nvideo.m3u8\n"
        let video = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n" + (0..<4).map { "#EXTINF:2.0,\nsegment\($0).ts\n" }.joined() + "#EXT-X-ENDLIST\n"
        let captions = "#EXTM3U\n#EXT-X-TARGETDURATION:8\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:8.0,\nsubtitles.vtt\n#EXT-X-ENDLIST\n"
        files["/master.m3u8"] = Data(master.utf8); files["/video.m3u8"] = Data(video.utf8)
        files["/subtitles.m3u8"] = Data(captions.utf8)
        files["/subtitles.vtt"] = Data("WEBVTT\n\n00:00.000 --> 00:07.900\nSoulo subtitle fixture\n".utf8)
        for i in 0..<4 {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "segment\(i)", withExtension: "ts", subdirectory: "ReadingFixtures/HLSFragments"))
            files["/segment\(i).ts"] = try Data(contentsOf: url)
        }
        let server = try DownloadPlaybackHTTPFixture(files: files)
        let base = try await server.start(); server.releaseDownloads(); defer { server.stop() }
        let player = AVPlayer()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: SystemSubtitleMenu(player: player, interaction: {}))
        window.makeKeyAndVisible()
        defer { player.replaceCurrentItem(with: nil); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func subtitleButton(_ view: UIView) -> UIButton? {
            if let button = view as? UIButton, button.accessibilityIdentifier == "media.native.system-subtitles" { return button }
            return view.subviews.lazy.compactMap { subtitleButton($0) }.first
        }
        for _ in 0..<100 where subtitleButton(window) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let button = try XCTUnwrap(subtitleButton(window))
        // The SwiftUI view and AVPlayer identity stay fixed while the native
        // controller discovers a new item's tracks asynchronously.
        let asset = AVURLAsset(url: base.appendingPathComponent("master.m3u8"))
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        let option = try XCTUnwrap(group?.options.first)
        func titles(_ menu: UIMenu) -> [String] {
            menu.children.flatMap { element -> [String] in
                if let child = element as? UIMenu { return [child.title] + titles(child) }
                return [element.title]
            }
        }
        let reference=AVLegibleMediaOptionsMenuController(player:player)
        var expectedTitles=[String]()
        for _ in 0..<250 {
            expectedTitles=reference.menu(contents:.legible).map(titles)?.filter{!$0.isEmpty} ?? []
            if !expectedTitles.isEmpty, let menu = button.menu, expectedTitles.allSatisfy(titles(menu).contains) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(button.isEnabled)
        let facts: [String: Any] = ["assetOption":option.displayName,"menuTitles":button.menu.map(titles) ?? [],"nativeTrackMenu":expectedTitles]
        let attachment=XCTAttachment(data:try JSONSerialization.data(withJSONObject:facts,options:.prettyPrinted),uniformTypeIdentifier:"public.json")
        attachment.name="native-subtitle-options";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertFalse(expectedTitles.isEmpty,"The native controller must expose real track controls")
        XCTAssertTrue(button.menu.map { menu in expectedTitles.allSatisfy(titles(menu).contains) } ?? false,
                      "Native subtitle choices must refresh without replacing the SwiftUI control")
        #else
        throw XCTSkip("Requires Xcode27 public SDK declarations")
        #endif
    }

    func testSummaryAndTabGlassAppearances() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let tabs = manager()
        tabs.activeTab?.webViewModel.pageTitle = "Local article"
        tabs.createTab().webViewModel.pageTitle = "Bookmarks"
        tabs.createTab().webViewModel.pageTitle = "Summary"
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        for dark in [false, true] {
            for highContrast in [false, true] {
                let root = VStack(spacing: 12) {
                    BrowserTabBar(tabManager: tabs, onNewTab: {})
                        .padding(.top, 12)
                    SummarySheetView(summary: "This page explains how independent browser windows keep each tab’s navigation history.\n\n• Move a tab only when its new window is ready.\n• Preserve the original document and its back history.\n• Keep private pages out of system suggestions.",
                        pageTitle: "Independent browser windows", isLoading: false, onDismiss: {})
                }
                .background(Color.indigo.opacity(dark ? 0.7 : 0.22))
                .environment(\.colorScheme, dark ? .dark : .light)
                let host = UIHostingController(rootView: root)
                let container = UIViewController()
                container.addChild(host); container.view.addSubview(host.view)
                host.didMove(toParent: container)
                host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                container.setOverrideTraitCollection(UITraitCollection(accessibilityContrast: highContrast ? .high : .normal), forChild: host)
                container.overrideUserInterfaceStyle = dark ? .dark : .light
                window.rootViewController = container; window.makeKeyAndVisible()
                host.view.frame = container.view.bounds; host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(220))
                let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: screenshot)
                attachment.name = "summary-glass-\(dark ? "dark" : "light")-\(highContrast ? "high-contrast" : "standard")"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
