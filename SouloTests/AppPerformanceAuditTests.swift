import XCTest
import SwiftUI
import CoreData
import WebKit
import PDFKit
@testable import Soulo

/// Opt-in initial-layout and main-runloop audit, independent of XCTest tap/idle
/// latency. These are hosting/layout proxies, not GPU presentation or web TTFB.
@MainActor final class AppPerformanceAuditTests: XCTestCase {
    struct Sample: Codable {
        let page: String
        let iteration: Int
        let width: Double
        let layoutMS: Double
        /// Historical field name: a CADisplayLink interval, not a main-thread stall.
        let maxRunloopGapMS: Double
        let maxMainQueueDelayMS: Double
        let frameIntervalsMS: [Double]
    }
    private struct Page {
        let name: String
        let make: () -> AnyView
    }

    func testScreenLayoutAndDataScalingAudit() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_APP_PERF_AUDIT"] == "1" else {
            throw XCTSkip("Opt-in application page performance audit")
        }
        let defaults = UserDefaults.standard
        let keys = ["app_language", "icloud_sync_enabled", "wallpaper_source", "wallpaper_refresh_interval", "tab_overview_grouped", "is_incognito"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        let language = LanguageManager.shared.currentLanguage
        let storage = "performance-audit-" + UUID().uuidString
        defaults.set(false, forKey: "icloud_sync_enabled")
        defaults.set("gradient", forKey: "wallpaper_source")
        defaults.set(0, forKey: "wallpaper_refresh_interval")
        defaults.set(false, forKey: "is_incognito")
        LanguageManager.shared.currentLanguage = "en-US"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(storage, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modelContainer = try LibraryStore(inMemory: true)
        let search = SearchViewModel()
        let tabs = TabManager(storageKey: storage)
        tabs.tabs = (0..<24).map { index in
            let tab = BrowserTab()
            tab.webViewModel.loadCachedURL(URL(string: "https://audit-\(index % 4).invalid/page/\(index)")!)
            tab.webViewModel.updateTitle("Audit page \(index)")
            return tab
        }
        tabs.activeTabIndex = 0
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        window.isHidden = false
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            MediaSession.shared.stop()
            tabs.tabs.forEach { $0.webViewModel.webView?.stopLoading(); $0.webViewModel.webView = nil }
            tabs.saveToDisk(); defaults.removeObject(forKey: storage)
            for key in keys { defaults.set(saved[key] ?? nil, forKey: key) }
            LanguageManager.shared.currentLanguage = language
            try? FileManager.default.removeItem(at: directory)
        }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 400)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 400))
        }
        let imageURL = directory.appendingPathComponent("preview.png")
        try image.pngData()?.write(to: imageURL)
        let bookName = storage + ".txt"
        try FileManager.default.createDirectory(at: BookLibrary.directory, withIntermediateDirectories: true)
        let bookURL = BookLibrary.directory.appendingPathComponent(bookName)
        try String(repeating: "A local reading performance fixture. 中文阅读示例。\n", count: 500).write(to: bookURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: bookURL) }
        let book = LibraryBook(id: storage, name: "Audit book", fileName: bookName)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage()
            ("Audit PDF" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        let web = WKWebView()
        web.loadHTMLString("<meta name='viewport' content='width=device-width'><title>Audit</title><article><h1>Audit article</h1>" + String(repeating: "<p>Local article text for reader and browser tools.</p>", count: 60) + "</article>", baseURL: URL(string: "https://audit.invalid"))
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let webModel = WebViewModel()
        webModel.currentURL = URL(string: "https://audit.invalid/article")
        webModel.webView = web
        let url = URL(string: "https://audit.invalid/article")!
        let share = WebPageSharePreviewModel(url: url, title: "Audit page", webView: web, obscuredBottom: 0)
        let platform = try XCTUnwrap(PlatformDataStore.shared.platforms.first)
        let group = CustomGroup(name: "Audit group")
        let mediaURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "playback-h264-aac", withExtension: "mp4", subdirectory: "ReadingFixtures"))
        let archiveURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "test", withExtension: "rar", subdirectory: "ReadingFixtures"))
        let pages: [Page] = [
            Page(name: "home", make: { AnyView(HomeView()) }),
            Page(name: "settings", make: { AnyView(SettingsView()) }),
            Page(name: "platforms", make: { AnyView(PlatformManagementView()) }),
            Page(name: "platform_add", make: { AnyView(AddCustomPlatformView()) }),
            Page(name: "platform_edit", make: { AnyView(EditPlatformView(platform: platform)) }),
            Page(name: "platform_batch_import", make: { AnyView(BatchImportView()) }),
            Page(name: "platform_url_help", make: { AnyView(URLHelpView()) }),
            Page(name: "groups", make: { AnyView(GroupManagementView()) }),
            Page(name: "group_edit", make: { AnyView(GroupEditView(group: group, onDismiss: {})) }),
            Page(name: "language", make: { AnyView(LanguageSettingsView()) }),
            Page(name: "wallpaper", make: { AnyView(WallpaperSettingsView()) }),
            Page(name: "wallpaper_editor", make: { AnyView(WallpaperEditorView(image: image, onSave: { _ in })) }),
            Page(name: "web_appearance", make: { AnyView(WebAppearanceSettingsView()) }),
            Page(name: "video_settings", make: { AnyView(VideoSettingsView()) }),
            Page(name: "shake", make: { AnyView(ShakeActionSettingsView()) }),
            Page(name: "gestures", make: { AnyView(BrowserGestureSettingsView()) }),
            Page(name: "website_zoom", make: { AnyView(WebsiteZoomSettingsView()) }),
            Page(name: "toolbar", make: { AnyView(BrowserToolbarSettingsView()) }),
            Page(name: "home_toolbar", make: { AnyView(HomeToolbarSettingsView()) }),
            Page(name: "adblock", make: { AnyView(AdBlockManagementView(currentHost: nil)) }),
            Page(name: "privacy", make: { AnyView(PrivacySettingsView()) }),
            Page(name: "external_navigation", make: { AnyView(ExternalNavigationSettingsView()) }),
            Page(name: "extensions", make: { AnyView(ExtensionCenterView()) }),
            Page(name: "extension_install", make: { AnyView(WebExtensionStoreInstallView()) }),
            Page(name: "script_editor", make: { AnyView(UserScriptEditorView(script: nil)) }),
            Page(name: "script_updates", make: { AnyView(UserScriptUpdatesView()) }),
            Page(name: "script_docs", make: { AnyView(UserScriptDocumentationView()) }),
            Page(name: "backups", make: { AnyView(SettingsBackupsView()) }),
            Page(name: "quick_actions", make: { AnyView(AppQuickActionSettingsView()) }),
            Page(name: "url_schemes", make: { AnyView(URLSchemeGuideView()) }),
            Page(name: "version", make: { AnyView(AppVersionView(version: "1.2.11")) }),
            Page(name: "review", make: { AnyView(AppReviewSupportView()) }),
            Page(name: "feedback", make: { AnyView(FeedbackView()) }),
            Page(name: "storage", make: { AnyView(StorageUsageView()) }),
            Page(name: "library_bookmarks", make: { AnyView(LibraryView(initialSection: .bookmarks, searchVM: search)) }),
            Page(name: "library_history", make: { AnyView(LibraryView(initialSection: .history, searchVM: search)) }),
            Page(name: "library_downloads", make: { AnyView(LibraryView(initialSection: .downloads, searchVM: search)) }),
            Page(name: "library_files", make: { AnyView(LibraryView(initialSection: .files, searchVM: search)) }),
            Page(name: "bookmarks", make: { AnyView(BookmarksView(searchVM: search)) }),
            Page(name: "history", make: { AnyView(SearchHistoryView(searchVM: search)) }),
            Page(name: "downloads", make: { AnyView(DownloadManagerView()) }),
            Page(name: "new_download", make: { AnyView(NewDownloadTaskView()) }),
            Page(name: "files", make: { AnyView(LibraryFilesView(directory: directory)) }),
            Page(name: "reading_list", make: { AnyView(ReadingListView()) }),
            Page(name: "book_reader", make: { AnyView(BookReaderView(book: book)) }),
            Page(name: "image_preview", make: { AnyView(LocalImagePreview(url: imageURL)) }),
            Page(name: "wifi_transfer", make: { AnyView(WiFiTransferView(directory: directory)) }),
            Page(name: "licenses", make: { AnyView(ReadingToolsLicensesView()) }),
            Page(name: "media_player_shell", make: { AnyView(MediaPlayerPage()) }),
            Page(name: "new_tab", make: { AnyView(NewTabPageView(tabManager: tabs, onNavigate: { _ in })) }),
            Page(name: "tabs_carousel_24", make: {
                defaults.set(false, forKey: "tab_overview_grouped")
                return AnyView(TabSwitcherOverlay(tabManager: tabs, onSelectTab: { _ in }, onGoHome: {}, onDismiss: {}))
            }),
            Page(name: "tabs_grouped_24", make: {
                defaults.set(true, forKey: "tab_overview_grouped")
                return AnyView(TabSwitcherOverlay(tabManager: tabs, onSelectTab: { _ in }, onGoHome: {}, onDismiss: {}))
            }),
            Page(name: "web_loading", make: { AnyView(BrowserInitialLoadingView(url: url)) }),
            Page(name: "web_error", make: { AnyView(BrowserLoadErrorView(message: "Audit network failure", url: url, onRetry: {}, onGoHome: {}, onOpenCompatibility: {})) }),
            Page(name: "web_share", make: { AnyView(WebPageSharePreview(model: share)) }),
            Page(name: "web_qrcode", make: { AnyView(WebPageQRCodeView(url: url, title: "Audit page")) }),
            Page(name: "web_certificate", make: { AnyView(SiteCertificateView(host: "audit.invalid", certificates: [])) }),
            Page(name: "web_site_info", make: { AnyView(SiteInformationPopoverView(webViewModel: webModel, onSetDesktopMode: { _ in },
                currentURL: url, isPrivateMode: false, onSetPrivateMode: { _ in }, onReload: {}, onShowDetails: {},
                onManageAdBlock: {}, onMarkAdvertisement: {}, onPrivacySettings: {})) }),
            Page(name: "web_resources", make: { AnyView(WebResourceInspectorView(webViewModel: webModel)) }),
            Page(name: "web_episodes", make: { AnyView(WebEpisodePickerView(viewModel: webModel)) }),
            Page(name: "article_reader", make: { AnyView(ArticleReaderView(source: web)) }),
            Page(name: "web_summary_shell", make: { AnyView(SummarySheetView(summary: String(repeating: "Local summary. ", count: 100), pageTitle: "Audit page", isLoading: false, onDismiss: {})) }),
            Page(name: "capture_preview", make: { AnyView(WebPageCapturePreview(result: WebPageCaptureResult(image: image, mode: .viewport, wasHeightLimited: false))) }),
            Page(name: "pdf_preview", make: { AnyView(WebPagePDFPreview(result: WebPagePDFResult(data: pdf, fileName: "Audit.pdf", pageCount: 1, wasPageLimited: false))) }),
            Page(name: "privacy_policy", make: { AnyView(PrivacyPolicyView()) }),
            Page(name: "terms", make: { AnyView(TermsOfServiceView()) }),
            Page(name: "group_search", make: { AnyView(GroupSearchSettingsView(scope: .region(.china), originalName: "Audit", onSaveName: { _ in })) }),
            Page(name: "group_add_platform", make: { AnyView(AddPlatformToGroupSheet(group: group)) }),
            Page(name: "platform_move", make: { AnyView(MovePlatformToRegionSheet(targetRegion: .china)) }),
            Page(name: "platform_trial", make: { AnyView(PlatformTrialSearch(template: "https://audit.invalid/?q=%@")) }),
            Page(name: "web_privacy_panel", make: { AnyView(SitePrivacyPanelView(currentURL: url)) }),
            Page(name: "web_address", make: { AnyView(BrowserAddressEditorSheet(initialText: "Audit", initialURL: url.absoluteString, onOpen: { _ in }, onOpenURL: { _ in }, onVoiceInput: {})) }),
            Page(name: "web_fullscreen_menu", make: { AnyView(FullscreenQuickMenu(webViewModel: webModel, title: "Audit page", isBookmarked: false, isDesktopMode: false, canSwitchContentMode: true, onAction: { _ in })) }),
            Page(name: "web_translation_shell", make: { AnyView(WebPageTranslationSheet(webView: web, pageURL: url, onOpenURL: { _ in }, onAppleTranslationApplied: { _, _ in }, onGoogleTranslationOpened: { _ in }, onRestore: {})) }),
            Page(name: "image_text_result", make: { AnyView(ImageTextRecognitionView(result: ImageTextRecognitionResult(image: image, text: "Audit text", sourceURL: url), onSearch: { _ in })) }),
            Page(name: "scan_result", make: { AnyView(LocalScanResultView(content: ScannedContent(text: "Audit text"))) }),
            Page(name: "archive_browser", make: { AnyView(ArchiveBrowserView(url: archiveURL, directory: directory)) }),
            Page(name: "text_document", make: { AnyView(TextDocumentPreview(url: bookURL)) }),
            Page(name: "web_container", make: { AnyView(WebViewContainer(webViewModel: webModel, bookmarkViewModel: BookmarkViewModel(), isFullscreen: .constant(false), tabManager: tabs)) }),
            Page(name: "video_soulo", make: { AnyView(FileMediaPlaybackView(url: mediaURL, persistPosition: false, initialSystemPlayer: false)) }),
            Page(name: "video_system", make: { AnyView(FileMediaPlaybackView(url: mediaURL, persistPosition: false, initialSystemPlayer: true)) })
        ]
        var samples: [Sample] = []
        func root(_ content: AnyView) -> AnyView {
            AnyView(NavigationStack { content }
                .environmentObject(search).environmentObject(tabs)
                .environmentObject(LanguageManager.shared).environmentObject(ThemeManager.shared)
                .environment(\.managedObjectContext, (modelContainer).mainContext)
                .transaction { $0.disablesAnimations = true })
        }
        window.rootViewController = UIHostingController(rootView: root(AnyView(Color.clear)))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(2))
        func run(_ page: Page, iteration: Int, suffix: String = "") async throws {
            let probe = FrameProbe(); probe.start()
            let mainQueue = MainQueueProbe(); mainQueue.start()
            // Ensure the background timer is armed before synchronous layout.
            try await Task.sleep(for: .milliseconds(30))
            let started = CACurrentMediaTime()
            let host = UIHostingController(rootView: root(page.make()))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            CATransaction.flush()
            let layout = (CACurrentMediaTime() - started) * 1000
            try await Task.sleep(for: .milliseconds(250))
            probe.stop()
            mainQueue.stop()
            let sample = Sample(page: page.name + suffix, iteration: iteration,
                width: Double(window.bounds.width), layoutMS: layout,
                maxRunloopGapMS: probe.intervals.max() ?? 0,
                maxMainQueueDelayMS: mainQueue.delays.max() ?? 0, frameIntervalsMS: probe.intervals)
            samples.append(sample)
            let line = try JSONEncoder().encode(sample)
            print("APP_PAGE_PERF|" + String(decoding: line, as: UTF8.self)); fflush(stdout)
            XCTAssertGreaterThan(host.view.bounds.width, 0)
            window.rootViewController = nil
            if page.name.hasPrefix("video_") { MediaSession.shared.stop() }
            try await Task.sleep(for: .milliseconds(30))
        }
        let environment = ProcessInfo.processInfo.environment
        let filter = Set((environment["SOULO_APP_PERF_PAGES"] ?? "").split(separator: ",").map(String.init))
        let selectedPages = pages.filter { filter.isEmpty || filter.contains($0.name) }
        let repeats = max(1, min(10, Int(environment["SOULO_APP_PERF_REPEATS"] ?? "3") ?? 3))
        XCTAssertFalse(selectedPages.isEmpty, "Page filter must match an entry")
        for page in selectedPages {
            for iteration in 0..<repeats { try await run(page, iteration: iteration) }
        }
        let context = modelContainer.mainContext
        let counts = (environment["SOULO_APP_PERF_ROWS"] ?? "100,1000,5000").split(separator: ",").compactMap { Int($0) }.filter { (1...10_000).contains($0) }
        var stressPageCount = 0
        for count in counts {
            for item in try context.fetch(SearchHistoryRecord.request()) { context.delete(item) }
            for item in try context.fetch(BookmarkRecord.request()) { context.delete(item) }
            for index in 0..<count {
                context.insert(SearchHistoryRecord(keyword: "Audit entry \(index)", visitedURLString: index.isMultiple(of: 2) ? "https://audit.invalid/\(index)" : nil))
                context.insert(BookmarkRecord(title: "Audit bookmark \(index)", urlString: "https://audit.invalid/\(index)"))
            }
            try context.save()
            for name in ["home", "history", "bookmarks", "library_history", "library_bookmarks"] where filter.isEmpty || filter.contains(name) {
                stressPageCount += 1
                let page = try XCTUnwrap(pages.first { $0.name == name })
                for iteration in 0..<repeats { try await run(page, iteration: iteration, suffix: "_rows\(count)") }
            }
        }
        let report = try JSONEncoder().encode(samples)
        let attachment = XCTAttachment(data: report, uniformTypeIdentifier: "public.json")
        attachment.name = "application-page-performance.json"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(samples.count, (selectedPages.count + stressPageCount) * repeats)
        webModel.webView = nil; web.stopLoading()
    }

    func testWebsiteNetworkTimingAudit() async throws {
        guard ProcessInfo.processInfo.environment["SOULO_APP_PERF_AUDIT"] == "1" else {
            throw XCTSkip("Opt-in public website timing audit")
        }
        let defaults = UserDefaults.standard
        let keys = ["ad_block_enabled", "is_incognito", "privacy_https_upgrade_enabled"]
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defaults.set(true, forKey: "is_incognito")
        defaults.set(false, forKey: "privacy_https_upgrade_enabled")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        defer {
            window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible()
            for key in keys { defaults.set(saved[key] ?? nil, forKey: key) }
        }
        let environment = ProcessInfo.processInfo.environment
        let addresses = environment["SOULO_APP_PERF_URL"].map { [$0] } ?? ["https://www.baidu.com/", "https://stockclaw.dkluge.com/",
                         "https://platform.deepseek.com/usage", "https://www.apple.com.cn/"]
        let modes = (environment["SOULO_APP_PERF_MODES"] ?? "webkit,soulo_ads_on").split(separator: ",").map(String.init)
        XCTAssertFalse(modes.isEmpty)
        XCTAssertTrue(modes.allSatisfy { ["webkit", "soulo_ads_on", "soulo_ads_off"].contains($0) })
        let repeats = max(1, min(10, Int(environment["SOULO_APP_PERF_REPEATS"] ?? "2") ?? 2))
        var rows: [[String: Any]] = []
        for address in addresses {
            for iteration in 0..<repeats {
                let offset = iteration % modes.count
                let orderedModes = Array(modes.dropFirst(offset)) + Array(modes.prefix(offset))
                for mode in orderedModes {
                    defaults.set(mode != "soulo_ads_off", forKey: "ad_block_enabled")
                    let started = CACurrentMediaTime()
                    let url = try XCTUnwrap(URL(string: address))
                    var raw: WKWebView?
                    var model: WebViewModel?
                    if mode == "webkit" {
                        let config = WKWebViewConfiguration()
                        config.websiteDataStore = .nonPersistent()
                        let web = WKWebView(frame: window.bounds, configuration: config)
                        let controller = UIViewController(); controller.view = web
                        window.rootViewController = controller
                        raw = web
                        web.load(URLRequest(url: url))
                    } else {
                        let browser = WebViewModel()
                        model = browser
                        browser.loadURL(url)
                        window.rootViewController = UIHostingController(rootView: AdBlockPreparedWebView(viewModel: browser))
                    }
                    window.makeKeyAndVisible()
                    window.rootViewController?.view.layoutIfNeeded()
                    while CACurrentMediaTime() - started < 20 {
                        if let web = raw ?? model?.webView, web.url != nil,
                           !web.isLoading, web.estimatedProgress >= 0.99 { break }
                        if let error = model?.errorMessage, !error.isEmpty { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    let elapsed = (CACurrentMediaTime() - started) * 1000
                    // Let first paint become observable, without changing native load time.
                    try await Task.sleep(for: .milliseconds(200))
                    let web = raw ?? model?.webView
                    let timing = try? await web?.evaluateJavaScript("""
                    (()=>{const n=performance.getEntriesByType('navigation')[0];if(!n)return {};
                    const p=performance.getEntriesByType('paint');return {
                      title:document.title,readyState:document.readyState,bodyCharacters:document.body?.innerText?.length||0,
                      dns_ms:n.domainLookupEnd-n.domainLookupStart,connect_ms:n.connectEnd-n.connectStart,
                      tls_ms:n.secureConnectionStart>0?n.connectEnd-n.secureConnectionStart:0,
                      ttfb_ms:n.responseStart-n.requestStart,response_ms:n.responseEnd-n.responseStart,
                      document_ms:n.domContentLoadedEventEnd,load_ms:n.loadEventEnd,
                      transferred:n.transferSize,resources:performance.getEntriesByType('resource').length,
                      paints:p.map(e=>({name:e.name,start:e.startTime}))};})()
                    """)
                    var row: [String: Any] = ["url": address, "mode": mode, "iteration": iteration,
                        "native_total_ms": elapsed, "deadline_reached": elapsed >= 20_000,
                        "final_url": web?.url?.absoluteString ?? "", "error": model?.errorMessage ?? ""]
                    row["navigation"] = timing ?? [String: Any]()
                    rows.append(row)
                    print("APP_NETWORK_PERF|" + String(decoding: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self)); fflush(stdout)
                    web?.stopLoading()
                    window.rootViewController = nil
                    model?.webView = nil
                    try await Task.sleep(for: .milliseconds(300))
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        let report = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        report.name = "website-navigation-performance.json"; report.lifetime = .keepAlways; add(report)
        XCTAssertEqual(rows.count, addresses.count * modes.count * repeats)
    }
}

/// Separately measures main-queue scheduling delay. Display callbacks can be
/// throttled by the OS, so their cadence alone is insufficient to detect stalls.
@MainActor private final class MainQueueProbe {
    private var timer: DispatchSourceTimer?
    private var running = false
    private(set) var delays: [Double] = []
    func start() {
        running = true
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "soulo.audit.main-probe"))
        source.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            let scheduled = CACurrentMediaTime()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.running else { return }
                self.delays.append((CACurrentMediaTime() - scheduled) * 1000)
            }
        }
        timer = source; source.resume()
    }
    func stop() { running = false; timer?.cancel(); timer = nil }
}

@MainActor private final class FrameProbe: NSObject {
    private var display: CADisplayLink?
    private var previous: CFTimeInterval = 0
    private(set) var intervals: [Double] = []
    func start() {
        previous = CACurrentMediaTime()
        let display = CADisplayLink(target: self, selector: #selector(frame))
        self.display = display
        display.add(to: .main, forMode: .common)
    }
    func stop() { display?.invalidate(); display = nil }
    @objc private func frame() {
        let now = CACurrentMediaTime()
        intervals.append((now - previous) * 1000)
        previous = now
    }
}

extension AppPerformanceAuditTests {
    @MainActor func testWallpaperAppearanceAndLoadingProgressVisuals() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow, window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(Color.black))
        window.rootViewController = host; window.makeKeyAndVisible()
        let manager = WallpaperManager.shared, oldSource = manager.source, oldImage = manager.customImage
        // The audit runs with a local gradient default; no wallpaper provider is queried.
        guard oldSource == .gradient else { throw XCTSkip("Visual fixture requires the local gradient wallpaper") }
        defer { manager.source = oldSource; manager.customImage = oldImage; window.isHidden = true; previous?.makeKeyAndVisible() }
        let renderFormat = UIGraphicsImageRendererFormat()
        renderFormat.preferredRange = .standard
        manager.customImage = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: renderFormat).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        manager.source = .photo
        var centerSamples: [Int] = []
        for scheme in [ColorScheme.light, .dark] {
            host.rootView = AnyView(WallpaperBackground(isAnimating: false).environment(\.colorScheme, scheme))
            host.view.setNeedsLayout(); host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(250))
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: renderFormat).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "photo-wallpaper-" + (scheme == .light ? "light" : "dark"); attachment.lifetime = .keepAlways; add(attachment)
            if let cg = image.cgImage, let data = cg.dataProvider?.data {
                let bytes = CFDataGetBytePtr(data)!, offset = (cg.height / 2) * cg.bytesPerRow + (cg.width / 2) * (cg.bitsPerPixel / 8)
                centerSamples.append(Int(bytes[offset]))
            }
        }
        XCTAssertEqual(centerSamples.count, 2)
        XCTAssertGreaterThan(centerSamples[0] - centerSamples[1], 50, "Light appearance must remove the fixed dark photo scrim")
        host.rootView = AnyView(ZStack { Color.black; VideoTransportButtons(playing: false, buffering: true, identifier: "qa.loading", toggle: {}, seek: { _ in }) })
        try await Task.sleep(for: .milliseconds(200))
        var image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: renderFormat).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        var attachment = XCTAttachment(image: image); attachment.name = "single-loading-control"; attachment.lifetime = .keepAlways; add(attachment)
        host.rootView = AnyView(TorrentProgressIndicator(progress: 0.375).padding(24).frame(width: 360).background(Color(uiColor: .systemBackground)))
        try await Task.sleep(for: .milliseconds(200))
        image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: renderFormat).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        attachment = XCTAttachment(image: image); attachment.name = "torrent-progress-with-percentage"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
