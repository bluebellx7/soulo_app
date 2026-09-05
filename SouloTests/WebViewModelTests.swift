import XCTest
import UIKit
import SwiftData
import CoreImage
import PDFKit
import WebKit
@testable import Soulo

@MainActor
final class WebViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
        UserDefaults.standard.set(false, forKey: AppConstants.StorageKeys.isIncognito)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
        UserDefaults.standard.set(false, forKey: AppConstants.StorageKeys.isIncognito)
        super.tearDown()
    }

    func testLanguageSettingsExposeEveryRuntimeSupportedLanguage() {
        let settingsLanguages = Set(AppConstants.supportedLanguages.map(\.code))
        XCTAssertEqual(settingsLanguages.count, 50)
        for language in settingsLanguages {
            XCTAssertNotNil(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "Missing runtime localization for \(language)"
            )
        }
    }

    func testWebPagePDFLabelsExistInEveryRuntimeLanguage() throws {
        for language in AppConstants.supportedLanguages.map(\.code) {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "Missing localization bundle for \(language)"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["web_capture_pdf", "web_capture_pdf_limited"] {
                XCTAssertNotEqual(
                    bundle.localizedString(forKey: key, value: nil, table: nil),
                    key,
                    "Missing \(key) for \(language)"
                )
            }
        }
    }

    func testFavoriteWallpaperLabelsExistInEveryRuntimeLanguage() throws {
        for language in AppConstants.supportedLanguages.map(\.code) {
            let path = try XCTUnwrap(
                Bundle.main.path(forResource: language, ofType: "lproj"),
                "Missing localization bundle for \(language)"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in ["wallpaper_only_favorites", "wallpaper_only_favorites_desc"] {
                XCTAssertNotEqual(
                    bundle.localizedString(forKey: key, value: nil, table: nil),
                    key,
                    "Missing \(key) for \(language)"
                )
            }
        }
    }

    func testWebPageShareItemKeepsStandardURLSharing() throws {
        guard #available(iOS 17.4, *) else { return }
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let item = WebPageShareActivityItem(url: url, title: "Example")
        let controller = UIActivityViewController(
            activityItems: [item],
            applicationActivities: nil
        )

        XCTAssertEqual(
            item.activityViewControllerPlaceholderItem(controller) as? URL,
            url
        )
        XCTAssertEqual(
            item.activityViewController(controller, itemForActivityType: .copyToPasteboard) as? URL,
            url
        )
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.title, "Example")
    }

    func testFavoriteWallpaperRefreshAvoidsCurrentImageWhenPossible() throws {
        let current = RemoteWallpaper(
            id: "current",
            url: "https://example.com/current.jpg",
            previewURL: "https://example.com/current-preview.jpg",
            source: "pexels"
        )
        let alternative = RemoteWallpaper(
            id: "alternative",
            url: "https://example.com/alternative.jpg",
            previewURL: "https://example.com/alternative-preview.jpg",
            source: "pexels"
        )

        XCTAssertEqual(
            WallpaperManager.favoriteWallpaperForRefresh(
                in: [current, alternative],
                currentImageID: current.id
            )?.id,
            alternative.id
        )
        XCTAssertNil(
            WallpaperManager.favoriteWallpaperForRefresh(
                in: [],
                currentImageID: current.id
            )
        )
    }

    func testLegacyAndRegionalLanguageCodesResolveToSupportedLocales() {
        XCTAssertEqual(AppConstants.canonicalLanguageCode("en"), "en-US")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("fr"), "fr-FR")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("de"), "de-DE")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("es"), "es-ES")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("ar"), "ar-SA")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("zh-HK"), "zh-Hant")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("zh-CN"), "zh-Hans")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("pt-BR"), "pt-BR")
        XCTAssertEqual(AppConstants.canonicalLanguageCode("en_NZ"), "en-US")
    }

    func testProtocolErrorLocalizationFallsBackToEnglishInsteadOfInternalKey() {
        let defaults = UserDefaults.standard
        let previousLanguage = defaults.string(forKey: "app_language")
        defaults.set("de", forKey: "app_language")
        defer {
            if let previousLanguage {
                defaults.set(previousLanguage, forKey: "app_language")
            } else {
                defaults.removeObject(forKey: "app_language")
            }
        }

        XCTAssertNotEqual(AppLocalization.string("web_capture_failed"), "web_capture_failed")
    }

    func testLoadURLImmediatelyMarksPageAsLoadingBeforeWebViewExists() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com")!

        model.loadURL(url)

        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0.0)
        XCTAssertNil(model.errorMessage)
    }

    func testCompletedEstimatedProgressClearsLoadingState() {
        let model = WebViewModel()
        model.loadURL(URL(string: "https://example.com")!)

        model.updateProgress(1.0)

        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 1.0)
    }

    func testRebuildingWebRuntimePreservesURLAndForcesFreshNavigation() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com/article")!
        model.loadURL(url)
        model.updateProgress(1)
        let previousRevision = model.runtimeRevision

        model.rebuildWebViewRuntime()

        XCTAssertEqual(model.currentURL, url)
        XCTAssertNotEqual(model.runtimeRevision, previousRevision)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0)
        XCTAssertFalse(model.isWebViewRuntimeInstalled)
    }

    func testReleasingWebViewResetsStreamingHandlerInstallationState() {
        let model = WebViewModel()
        model.webView = WKWebView(frame: .zero)
        model.isStreamingDownloadHandlerInstalled = true

        model.releaseWebViewRuntime()

        XCTAssertFalse(model.isStreamingDownloadHandlerInstalled)
    }

    func testRetryCurrentPageStartsFreshNavigationAndClearsError() {
        let model = WebViewModel()
        let url = URL(string: "https://example.com/article")!
        model.loadURL(url)
        model.setError("Offline")

        model.retryCurrentPage()

        XCTAssertEqual(model.currentURL, url)
        XCTAssertTrue(model.isLoading)
        XCTAssertEqual(model.estimatedProgress, 0)
        XCTAssertNil(model.errorMessage)
    }

    func testModerateShakePeaksTriggerRepeatedActionsAfterCooldown() {
        var classifier = ShakeMotionClassifier()

        XCTAssertFalse(classifier.register(magnitude: 0.64, at: 1.00))
        XCTAssertTrue(classifier.register(magnitude: 0.68, at: 1.12))

        // Motion from the same physical shake is ignored during the short cooldown.
        XCTAssertFalse(classifier.register(magnitude: 0.72, at: 1.30))

        // A later, second shake is detected normally instead of being lost.
        XCTAssertFalse(classifier.register(magnitude: 0.63, at: 2.00))
        XCTAssertTrue(classifier.register(magnitude: 0.66, at: 2.11))
    }

    func testShakeIntensityProvidesFourIncreasingThresholds() {
        let intensities = BrowserShakeIntensity.allCases

        XCTAssertEqual(intensities.count, 4)
        XCTAssertEqual(intensities.map(\.peakThreshold), intensities.map(\.peakThreshold).sorted())

        var light = ShakeMotionClassifier(intensity: .light)
        XCTAssertFalse(light.register(magnitude: 0.46, at: 1.00))
        XCTAssertTrue(light.register(magnitude: 0.47, at: 1.12))

        var strong = ShakeMotionClassifier(intensity: .strong)
        XCTAssertFalse(strong.register(magnitude: 0.90, at: 1.00))
        XCTAssertFalse(strong.register(magnitude: 0.95, at: 1.12))
        XCTAssertFalse(strong.register(magnitude: 1.05, at: 2.00))
        XCTAssertTrue(strong.register(magnitude: 1.08, at: 2.12))
    }

    func testPhoneAddressEditorUsesCompactDetent() {
        XCTAssertLessThanOrEqual(BrowserAddressEditorLayout.compactHeight, 260)
        XCTAssertGreaterThanOrEqual(BrowserAddressEditorLayout.compactHeight, 240)
    }

    func testShakeClassifierIgnoresEverydayMovementAndWidelySpacedPeaks() {
        var classifier = ShakeMotionClassifier()

        XCTAssertFalse(classifier.register(magnitude: 0.35, at: 1.00))
        XCTAssertFalse(classifier.register(magnitude: 0.65, at: 1.10))
        XCTAssertFalse(classifier.register(magnitude: 0.66, at: 1.70))
    }

    func testBrowserNavigationResolverAcceptsWebURLsAndBareHosts() {
        XCTAssertEqual(
            BrowserNavigationResolver.resolve("https://example.com/path"),
            URL(string: "https://example.com/path")
        )
        XCTAssertEqual(
            BrowserNavigationResolver.resolve("example.com/docs"),
            URL(string: "https://example.com/docs")
        )
    }

    func testBrowserNavigationResolverSearchesUnsafeSchemesInsteadOfExecutingThem() {
        let result = BrowserNavigationResolver.resolve("javascript://example.com/alert(1)")

        XCTAssertEqual(result?.scheme, "https")
        XCTAssertEqual(result?.host, "www.google.com")
        XCTAssertTrue(result?.query?.contains("javascript") == true)
    }

    func testWebMediaCapturePermissionPromptsOnlyForSecureOrigins() {
        XCTAssertEqual(
            WebMediaCapturePermissionPolicy.decision(forScheme: "https"),
            .prompt
        )
        XCTAssertEqual(
            WebMediaCapturePermissionPolicy.decision(forScheme: "HTTPS"),
            .prompt
        )
        XCTAssertEqual(
            WebMediaCapturePermissionPolicy.decision(forScheme: "http"),
            .deny
        )
        XCTAssertEqual(
            WebMediaCapturePermissionPolicy.decision(forScheme: nil),
            .deny
        )
    }

    func testLibrarySectionsKeepTheExpectedThreeWayOrder() {
        XCTAssertEqual(
            LibrarySection.allCases.map(\.rawValue),
            ["bookmarks", "history", "downloads"]
        )
        XCTAssertEqual(
            LibrarySection.allCases.map(\.titleKey),
            ["bookmarks", "search_history", "downloads"]
        )
    }

    func testSiteAdBlockCardEnablesGlobalFilteringWhenItWasOff() {
        XCTAssertEqual(
            SiteAdBlockTogglePolicy.nextState(
                isGloballyEnabled: false,
                isAllowlisted: true
            ),
            SiteAdBlockToggleState(
                isGloballyEnabled: true,
                isAllowlisted: false
            )
        )
    }

    func testSiteAdBlockCardTogglesCurrentSiteWhenGlobalFilteringIsOn() {
        XCTAssertEqual(
            SiteAdBlockTogglePolicy.nextState(
                isGloballyEnabled: true,
                isAllowlisted: false
            ),
            SiteAdBlockToggleState(
                isGloballyEnabled: true,
                isAllowlisted: true
            )
        )
        XCTAssertEqual(
            SiteAdBlockTogglePolicy.nextState(
                isGloballyEnabled: true,
                isAllowlisted: true
            ),
            SiteAdBlockToggleState(
                isGloballyEnabled: true,
                isAllowlisted: false
            )
        )
    }

    func testBrowsingHistoryUpsertsCanonicalURLAndRefreshesTitle() throws {
        let context = try makeHistoryContext()
        let url = URL(string: "https://Example.com/article?reloadNavStart=1&aweme_id=42#first")!
        let later = Date(timeIntervalSince1970: 10_000)

        SearchHistoryService.recordWebVisit(
            url: url,
            title: "Old title",
            visitedAt: later.addingTimeInterval(-30),
            context: context
        )
        SearchHistoryService.recordWebVisit(
            url: URL(string: "https://example.com/article?reloadNavStart=2&aweme_id=42#second")!,
            title: "New title",
            visitedAt: later,
            context: context
        )

        let entries = try context.fetch(FetchDescriptor<SearchHistoryItem>())
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.keyword, "New title")
        XCTAssertEqual(entries.first?.visitedURLString, "https://example.com/article?aweme_id=42")
        XCTAssertEqual(entries.first?.timestamp, later)
    }

    func testBrowsingHistoryKeepsOnlyLastThreeDaysWithoutDeletingSearchTerms() throws {
        let context = try makeHistoryContext()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let search = SearchHistoryItem(
            keyword: "永久保留的搜索词",
            timestamp: now.addingTimeInterval(-10 * 24 * 60 * 60)
        )
        let expiredVisit = SearchHistoryItem(
            keyword: "Old page",
            timestamp: now.addingTimeInterval(-SearchHistoryService.browsingHistoryLifetime - 1),
            visitedURLString: "https://old.example.com"
        )
        let recentVisit = SearchHistoryItem(
            keyword: "Recent page",
            timestamp: now.addingTimeInterval(-SearchHistoryService.browsingHistoryLifetime + 1),
            visitedURLString: "https://recent.example.com"
        )
        context.insert(search)
        context.insert(expiredVisit)
        context.insert(recentVisit)
        try context.save()

        SearchHistoryService.purgeExpiredBrowsingHistory(
            referenceDate: now,
            context: context
        )

        let entries = try context.fetch(FetchDescriptor<SearchHistoryItem>())
        XCTAssertTrue(entries.contains { $0.keyword == search.keyword })
        XCTAssertFalse(entries.contains { $0.visitedURLString == expiredVisit.visitedURLString })
        XCTAssertTrue(entries.contains { $0.visitedURLString == recentVisit.visitedURLString })
    }

    func testClearingBrowserCacheAlsoRemovesVisitsAndPreservesSearchTerms() async throws {
        let context = try makeHistoryContext()
        context.insert(SearchHistoryItem(keyword: "search term"))
        context.insert(
            SearchHistoryItem(
                keyword: "Visited page",
                visitedURLString: "https://example.com/page"
            )
        )
        try context.save()

        await BrowserCacheService.clear(tabManager: nil, historyContext: context)

        let entries = try context.fetch(FetchDescriptor<SearchHistoryItem>())
        XCTAssertEqual(entries.map(\.keyword), ["search term"])
        XCTAssertNil(entries.first?.visitedURLString)
    }

    func testDownloadStateStaysActiveUntilEveryDownloadFinishes() {
        let model = WebViewModel()

        model.updateDownloadState(activeCount: 2, fileName: "First.pdf")
        XCTAssertTrue(model.isDownloading)
        XCTAssertEqual(model.activeDownloadCount, 2)

        model.updateDownloadState(activeCount: 1, fileName: "Second.pdf")
        XCTAssertTrue(model.isDownloading)
        XCTAssertEqual(model.downloadFileName, "Second.pdf")

        model.updateDownloadState(activeCount: 0)
        XCTAssertFalse(model.isDownloading)
        XCTAssertEqual(model.downloadFileName, "")
    }

    private func makeHistoryContext() throws -> ModelContext {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SearchHistoryItem.self,
            configurations: configuration
        )
        return ModelContext(container)
    }

    func testBrowserChromeUsesStableBottomToolbarOverlayHeight() {
        XCTAssertEqual(
            BrowserChromeLayout.bottomToolbarHeight(
                isActiveTab: true,
                isFullscreen: false
            ),
            56
        )
    }

    func testFullscreenAndInactiveTabsDoNotShowBottomToolbarOverlay() {
        XCTAssertEqual(
            BrowserChromeLayout.bottomToolbarHeight(
                isActiveTab: true,
                isFullscreen: true
            ),
            0
        )
        XCTAssertEqual(
            BrowserChromeLayout.bottomToolbarHeight(
                isActiveTab: false,
                isFullscreen: false
            ),
            0
        )
    }

    func testFullscreenTransitionPreservesManuallyHiddenToolbarPresentation() {
        XCTAssertFalse(
            BrowserChromeLayout.showsBottomToolbar(
                isActiveTab: true,
                isFullscreen: true,
                isManuallyHidden: true
            )
        )
        XCTAssertFalse(
            BrowserChromeLayout.showsFloatingMore(
                isActiveTab: true,
                isFullscreen: true,
                isManuallyHidden: true
            )
        )

        XCTAssertFalse(
            BrowserChromeLayout.showsBottomToolbar(
                isActiveTab: true,
                isFullscreen: false,
                isManuallyHidden: true
            )
        )
        XCTAssertTrue(
            BrowserChromeLayout.showsFloatingMore(
                isActiveTab: true,
                isFullscreen: false,
                isManuallyHidden: true
            )
        )
    }

    func testFullscreenExitGestureRequiresAnIntentionalDownwardDrag() {
        XCTAssertTrue(
            FullscreenExitGesture.shouldExit(translation: CGSize(width: 4, height: 34))
        )
        XCTAssertFalse(
            FullscreenExitGesture.shouldExit(translation: CGSize(width: 32, height: 30))
        )
        XCTAssertFalse(
            FullscreenExitGesture.shouldExit(translation: CGSize(width: 2, height: -40))
        )
        XCTAssertFalse(
            FullscreenExitGesture.shouldExit(translation: CGSize(width: 2, height: 20))
        )
    }

    func testFullscreenHandleRevealGestureRequiresAnIntentionalDownwardPull() {
        XCTAssertTrue(
            FullscreenHandleRevealGesture.shouldReveal(
                translation: CGSize(width: 3, height: 30)
            )
        )
        XCTAssertFalse(
            FullscreenHandleRevealGesture.shouldReveal(
                translation: CGSize(width: 28, height: 26)
            )
        )
        XCTAssertFalse(
            FullscreenHandleRevealGesture.shouldReveal(
                translation: CGSize(width: 2, height: -30)
            )
        )
        XCTAssertFalse(
            FullscreenHandleRevealGesture.shouldReveal(
                translation: CGSize(width: 2, height: 18)
            )
        )

        XCTAssertTrue(
            FullscreenHandleRevealGesture.beginsNearTop(
                startY: 42,
                maximumStartY: 80
            )
        )
        XCTAssertFalse(
            FullscreenHandleRevealGesture.beginsNearTop(
                startY: 120,
                maximumStartY: 80
            )
        )
    }

    func testFullscreenHandleKeepsAComfortableTouchTarget() {
        XCTAssertEqual(FullscreenHandleLayout.indicatorSize, CGSize(width: 36, height: 4))
        XCTAssertGreaterThanOrEqual(FullscreenHandleLayout.minimumHitSize.width, 44)
        XCTAssertGreaterThanOrEqual(FullscreenHandleLayout.minimumHitSize.height, 44)
        XCTAssertGreaterThan(
            FullscreenHandleLayout.minimumHitSize.width,
            FullscreenHandleLayout.indicatorSize.width
        )
        XCTAssertGreaterThan(
            FullscreenHandleLayout.minimumHitSize.height,
            FullscreenHandleLayout.indicatorSize.height
        )
    }

    func testPageBottomClearanceCoversVisibleToolbarAndSystemGestureArea() {
        XCTAssertEqual(
            BrowserChromeLayout.pageBottomClearance(
                reportedSafeArea: 34,
                windowSafeArea: 0,
                visibleToolbarHeight: 56
            ),
            64
        )
        XCTAssertEqual(
            BrowserChromeLayout.pageBottomClearance(
                reportedSafeArea: 0,
                windowSafeArea: 34,
                visibleToolbarHeight: 0
            ),
            34
        )
        XCTAssertEqual(
            BrowserChromeLayout.pageBottomClearance(
                reportedSafeArea: -4,
                windowSafeArea: -2,
                visibleToolbarHeight: 0
            ),
            0
        )
        XCTAssertEqual(
            BrowserChromeLayout.pageBottomClearance(
                reportedSafeArea: 70,
                windowSafeArea: 0,
                visibleToolbarHeight: 56
            ),
            70
        )
    }

    func testVideoViewportInsetUsesNativeBottomClearanceOnlyForActiveVideo() {
        XCTAssertEqual(
            BrowserChromeLayout.videoViewportBottomInset(
                isActiveTab: true,
                isVideoPage: true,
                bottomClearance: 64
            ),
            64
        )

        for state in [
            (isActiveTab: false, isVideoPage: true),
            (isActiveTab: true, isVideoPage: false),
        ] {
            XCTAssertEqual(
                BrowserChromeLayout.videoViewportBottomInset(
                    isActiveTab: state.isActiveTab,
                    isVideoPage: state.isVideoPage,
                    bottomClearance: 64
                ),
                0
            )
        }

        XCTAssertEqual(
            BrowserChromeLayout.videoViewportBottomInset(
                isActiveTab: true,
                isVideoPage: true,
                bottomClearance: 34
            ),
            34
        )
    }

    func testToolbarVisibilityUsesADedicatedNonNavigationSymbol() {
        XCTAssertEqual(
            BrowserChromeSymbol.toolbarVisibility,
            "rectangle.bottomthird.inset.filled"
        )
        XCTAssertNotNil(UIImage(systemName: BrowserChromeSymbol.toolbarVisibility))
        XCTAssertFalse(BrowserChromeSymbol.toolbarVisibility.contains("chevron"))
        XCTAssertFalse(BrowserChromeSymbol.toolbarVisibility.contains("arrow"))
    }

    func testBrowserAddressDisplayCombinesKeywordPrefixAndHost() {
        XCTAssertEqual(
            BrowserAddressDisplay.text(
                keyword: "星星颜色不同",
                host: "so.douyin.com",
                maximumKeywordLength: 4
            ),
            "星星颜色/so.douyin.com"
        )
        XCTAssertEqual(
            BrowserAddressDisplay.text(
                keyword: "  VITAS   live  ",
                host: "so.douyin.com",
                maximumKeywordLength: 6
            ),
            "VITAS/so.douyin.com"
        )
    }

    func testBrowserAddressDisplayKeepsDirectURLsAndEmptySearchesHostOnly() {
        XCTAssertEqual(
            BrowserAddressDisplay.fullText(
                keyword: "https://example.com/article",
                host: "example.com"
            ),
            "example.com"
        )
        XCTAssertEqual(
            BrowserAddressDisplay.fullText(keyword: "   ", host: "example.com"),
            "example.com"
        )
    }

    func testPersistentFullscreenOnlyEntersForAnActiveAccessibleSearch() {
        XCTAssertTrue(
            PersistentFullscreenBehavior.shouldEnter(
                enabled: true,
                hasSearch: true,
                voiceOverEnabled: false
            )
        )
        XCTAssertFalse(
            PersistentFullscreenBehavior.shouldEnter(
                enabled: false,
                hasSearch: true,
                voiceOverEnabled: false
            )
        )
        XCTAssertFalse(
            PersistentFullscreenBehavior.shouldEnter(
                enabled: true,
                hasSearch: false,
                voiceOverEnabled: false
            )
        )
        XCTAssertFalse(
            PersistentFullscreenBehavior.shouldEnter(
                enabled: true,
                hasSearch: true,
                voiceOverEnabled: true
            )
        )
    }

    func testCloudSettingsPayloadRoundTripsWhitelistedValuesAndMissingKeys() throws {
        let sourceSuite = "CloudSettingsPayload.source.\(UUID().uuidString)"
        let targetSuite = "CloudSettingsPayload.target.\(UUID().uuidString)"
        let source = try XCTUnwrap(UserDefaults(suiteName: sourceSuite))
        let target = try XCTUnwrap(UserDefaults(suiteName: targetSuite))
        defer {
            source.removePersistentDomain(forName: sourceSuite)
            target.removePersistentDomain(forName: targetSuite)
        }

        source.set("dark", forKey: "appearance")
        source.set(["example.com"], forKey: "allowlist")
        target.set("stale", forKey: "missing_setting")

        let data = try CloudSettingsPayloadCodec.encode(
            defaults: source,
            keys: ["appearance", "allowlist", "missing_setting"]
        )
        try CloudSettingsPayloadCodec.apply(
            data,
            defaults: target,
            allowedKeys: ["appearance", "allowlist", "missing_setting"]
        )

        XCTAssertEqual(target.string(forKey: "appearance"), "dark")
        XCTAssertEqual(target.stringArray(forKey: "allowlist"), ["example.com"])
        XCTAssertNil(target.object(forKey: "missing_setting"))
    }

    func testCloudSyncInitializationDoesNotStartSynchronously() {
        let suiteName = "CloudSyncService.startup.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(true, forKey: AppConstants.StorageKeys.iCloudSyncEnabled)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = CloudSyncService(defaults: defaults)

        XCTAssertFalse(service.isStarted)
    }

    func testPageZoomUsesTenPercentStepsAndSafeBounds() {
        let model = WebViewModel()

        model.setPageZoom(0.01)
        XCTAssertEqual(model.pageZoom, 0.5)

        model.increasePageZoom()
        XCTAssertEqual(model.pageZoom, 0.6)

        model.setPageZoom(4)
        XCTAssertEqual(model.pageZoom, 2)

        model.resetPageZoom()
        XCTAssertEqual(model.pageZoom, 1)
    }

    func testPrivateSearchDoesNotStoreHistoryOrUsageButKeepsExistingRecentsVisible() throws {
        let context = try makeHistoryContext()
        context.insert(SearchHistoryItem(keyword: "existing search"))
        try context.save()

        let model = SearchViewModel()
        model.isIncognito = true
        model.searchText = "private query"
        let usageBefore = model.selectedPlatform?.usageCount

        model.performSearch(context: context)
        model.loadRecentSearches(context: context)

        let items = try context.fetch(FetchDescriptor<SearchHistoryItem>())
        XCTAssertEqual(items.map(\.keyword), ["existing search"])
        XCTAssertEqual(model.selectedPlatform?.usageCount, usageBefore)
        XCTAssertEqual(model.recentSearches, ["existing search"])
    }

    func testToolbarConfigurationNormalizesFourSlotsAndAddressAction() throws {
        let suite = "BrowserToolbarConfiguration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let service = BrowserToolbarConfigurationService(defaults: defaults)
        service.save(actions: [.share, .screenshot], addressAction: .more)

        XCTAssertEqual(service.actions, [.share, .screenshot, .tabs, .more])
        XCTAssertEqual(service.addressAction, .darkMode)
        XCTAssertEqual(defaults.string(forKey: BrowserToolbarConfigurationService.addressActionKey), "darkMode")
        XCTAssertEqual(
            BrowserToolbarAction.allCases.first,
            Optional(BrowserToolbarAction.none)
        )

        service.save(actions: [.none, .share, .none, .more], addressAction: .none)
        XCTAssertEqual(service.actions, [.none, .share, .none, .more])
        XCTAssertEqual(service.addressAction, .none)

        service.save(actions: [.translate, .share, .tabs, .more], addressAction: .translate)
        XCTAssertEqual(service.actions, [.translate, .share, .tabs, .more])
        XCTAssertEqual(service.addressAction, .translate)

        service.save(actions: [.home, .back, .tabs, .more], addressAction: .hideToolbar)
        XCTAssertEqual(service.addressAction, .hideToolbar)

        service.reset()
        XCTAssertEqual(service.actions, BrowserToolbarConfigurationService.defaultActions)
        XCTAssertEqual(service.addressAction, .darkMode)
        XCTAssertEqual(
            defaults.string(forKey: BrowserToolbarConfigurationService.addressActionKey),
            "darkMode"
        )
    }

    func testScrollingCaptureUsesViewportFloorAndMaximumHeight() {
        XCTAssertEqual(
            WebPageCaptureService.fullPageCaptureHeight(contentHeight: 300, viewportHeight: 800),
            800
        )
        XCTAssertEqual(
            WebPageCaptureService.fullPageCaptureHeight(contentHeight: 25_000, viewportHeight: 800),
            WebPageCaptureService.maximumFullPageHeight
        )
        let longPageScale = WebPageCaptureService.fullPageCaptureScale(
            width: WebPageCaptureService.fullPageCaptureWidth(
                contentWidth: 390,
                viewportWidth: 390
            ),
            height: WebPageCaptureService.maximumFullPageHeight,
            displayScale: 3
        )
        XCTAssertGreaterThan(longPageScale, 1)
        XCTAssertLessThanOrEqual(longPageScale, 3)
        XCTAssertLessThanOrEqual(
            WebPageCaptureService.fullPageCaptureWidth(
                contentWidth: 390,
                viewportWidth: 390
            )
                * WebPageCaptureService.maximumFullPageHeight
                * longPageScale
                * longPageScale,
            WebPageCaptureService.maximumFullPagePixelCount + 1
        )
        XCTAssertEqual(
            WebPageCaptureService.fullPageCaptureWidth(contentWidth: 980, viewportWidth: 390),
            980
        )
        XCTAssertEqual(
            WebPageCaptureService.fullPageCaptureWidth(contentWidth: 8_000, viewportWidth: 390),
            WebPageCaptureService.maximumFullPageWidth
        )
    }

    func testWebCaptureKeepsSnapshotWidthInViewCoordinates() {
        let bounds = CGRect(x: 18, y: 24, width: 390, height: 720)
        let configuration = WebPageCaptureService.snapshotConfiguration(for: bounds)

        XCTAssertEqual(configuration.rect, CGRect(x: 0, y: 0, width: 390, height: 720))
        XCTAssertEqual(configuration.snapshotWidth?.doubleValue, 390)
        XCTAssertTrue(configuration.afterScreenUpdates)
    }

    func testWebCaptureTilesCoverTheEntireHorizontalDocument() {
        let spans = WebPageCaptureService.tileSpans(
            totalLength: 980,
            viewportLength: 390,
            maximumContentOffset: 590
        )

        XCTAssertEqual(
            spans,
            [
                .init(destinationOrigin: 0, contentOffset: 0, sourceOrigin: 0, length: 390),
                .init(destinationOrigin: 390, contentOffset: 390, sourceOrigin: 0, length: 390),
                .init(destinationOrigin: 780, contentOffset: 590, sourceOrigin: 190, length: 200)
            ]
        )
        XCTAssertEqual(spans.reduce(0) { $0 + $1.length }, 980)
    }

    func testViewportCaptureIncludesAllFourVisibleEdges() async throws {
        let html = #"""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;width:100%;min-height:1200px;background:#fff;overflow-x:hidden}
        .m{position:fixed;width:36px;height:36px;z-index:9999}
        #tl{left:0;top:0;background:#ff0000} #tr{right:0;top:0;background:#0000ff}
        #bl{left:0;bottom:0;background:#00ff00} #br{right:0;bottom:0;background:#ff00ff}
        </style></head><body>
        <div id="tl" class="m"></div><div id="tr" class="m"></div>
        <div id="bl" class="m"></div><div id="br" class="m"></div>
        </body></html>
        """#
        let (window, webView) = try await makeCaptureWebView(
            html: html,
            size: CGSize(width: 390, height: 500)
        )
        defer { window.isHidden = true }

        let result = try await WebPageCaptureService.capture(.viewport, from: webView)

        XCTAssertEqual(result.image.size.width, 390, accuracy: 0.5)
        XCTAssertEqual(result.image.size.height, 500, accuracy: 0.5)
        assertPixel(result.image, at: CGPoint(x: 12, y: 12), resembles: (255, 0, 0))
        assertPixel(result.image, at: CGPoint(x: 378, y: 12), resembles: (0, 0, 255))
        assertPixel(result.image, at: CGPoint(x: 12, y: 488), resembles: (0, 255, 0))
        assertPixel(result.image, at: CGPoint(x: 378, y: 488), resembles: (255, 0, 255))
    }

    func testFullPageCaptureIncludesHorizontalAndVerticalEdges() async throws {
        let html = #"""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;padding:0;width:780px;min-width:780px;height:1200px;background:#fff}
        .edge{position:absolute;z-index:1}
        #left{left:0;top:0;width:36px;height:1200px;background:#ff0000}
        #right{left:744px;top:0;width:36px;height:1200px;background:#0000ff}
        #bottom{left:0;top:1164px;width:780px;height:36px;background:#00ff00;z-index:2}
        </style></head><body>
        <div id="left" class="edge"></div><div id="right" class="edge"></div>
        <div id="bottom" class="edge"></div>
        </body></html>
        """#
        let (window, webView) = try await makeCaptureWebView(
            html: html,
            size: CGSize(width: 390, height: 500)
        )
        defer { window.isHidden = true }

        let result = try await WebPageCaptureService.capture(.fullPage, from: webView)

        XCTAssertEqual(result.image.size.width, 780, accuracy: 1)
        XCTAssertEqual(result.image.size.height, 1200, accuracy: 1)
        assertPixel(result.image, at: CGPoint(x: 12, y: 100), resembles: (255, 0, 0))
        assertPixel(result.image, at: CGPoint(x: 768, y: 100), resembles: (0, 0, 255))
        assertPixel(result.image, at: CGPoint(x: 390, y: 1188), resembles: (0, 255, 0))
    }

    func testWebCaptureUsesThePageBackgroundForItsHorizontalFrame() throws {
        let color = try XCTUnwrap(
            WebPageCaptureService.colorFromComputedCSS("rgba(245, 246, 248, 0.9)")
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, 245 / 255, accuracy: 0.001)
        XCTAssertEqual(green, 246 / 255, accuracy: 0.001)
        XCTAssertEqual(blue, 248 / 255, accuracy: 0.001)
        XCTAssertEqual(alpha, 0.9, accuracy: 0.001)
        XCTAssertTrue(WebPageCaptureService.pageBackgroundColorScript.contains("document.body"))
        XCTAssertTrue(WebPageCaptureService.pageBackgroundColorScript.contains("document.documentElement"))
    }

    func testWebPagePDFLayoutUsesConsistentPagesAndCapsPathologicalDocuments() {
        let layout = WebPagePDFService.pageLayout(
            contentSize: CGSize(width: 390, height: 1_400),
            viewportSize: CGSize(width: 390, height: 500)
        )

        XCTAssertEqual(layout.rects.count, 3)
        XCTAssertFalse(layout.wasLimited)
        XCTAssertTrue(layout.rects.allSatisfy { rect in
            abs(rect.height / rect.width - WebPagePDFService.pageAspectRatio) < 0.001
        })
        XCTAssertEqual(layout.rects[1].minY, layout.rects[0].maxY, accuracy: 0.001)

        let limited = WebPagePDFService.pageLayout(
            contentSize: CGSize(width: 390, height: 1_000_000),
            viewportSize: CGSize(width: 390, height: 500)
        )
        XCTAssertEqual(limited.rects.count, WebPagePDFService.maximumPageCount)
        XCTAssertTrue(limited.wasLimited)
    }

    func testWebPagePDFExportKeepsTextSelectableAcrossPages() async throws {
        let html = #"""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html,body{margin:0;width:100%;height:1400px;background:white;color:black}
        h1{margin:24px;font-size:32px} p{margin:760px 24px 0;font-size:20px}
        </style></head><body>
        <h1>Selectable Vector Heading</h1>
        <p>Selectable text on a later PDF page.</p>
        </body></html>
        """#
        let (window, webView) = try await makeCaptureWebView(
            html: html,
            size: CGSize(width: 390, height: 500)
        )
        defer { window.isHidden = true }

        let result = try await WebPagePDFService.export(from: webView, title: "Vector PDF Test")
        let document = try XCTUnwrap(PDFDocument(data: result.data))
        let selectableText = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        XCTAssertEqual(document.pageCount, result.pageCount)
        XCTAssertGreaterThan(document.pageCount, 1)
        XCTAssertTrue(
            selectableText.contains("Selectable Vector Heading"),
            "Extracted PDF text: \(selectableText)"
        )
        XCTAssertTrue(
            selectableText.contains("Selectable text on a later PDF page"),
            "Extracted PDF text: \(selectableText)"
        )
        XCTAssertEqual(result.fileName, "Vector PDF Test.pdf")
    }

    private func makeCaptureWebView(
        html: String,
        size: CGSize
    ) async throws -> (UIWindow, WKWebView) {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        let viewController = UIViewController()
        let webView = WKWebView(frame: CGRect(origin: .zero, size: size))
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        viewController.loadViewIfNeeded()
        viewController.view.frame = window.bounds
        viewController.view.addSubview(webView)
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.layoutIfNeeded()
        webView.loadHTMLString(html, baseURL: URL(string: "https://capture.test"))

        var didFinish = false
        for _ in 0..<80 {
            let state = try? await webView.evaluateJavaScript("document.readyState") as? String
            if state == "complete" {
                didFinish = true
                break
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(didFinish)
        try await Task.sleep(nanoseconds: 150_000_000)
        return (window, webView)
    }

    private func assertPixel(
        _ image: UIImage,
        at point: CGPoint,
        resembles expected: (UInt8, UInt8, UInt8),
        tolerance: Int = 24,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let ciImage = CIImage(image: image) else {
            XCTFail("Unable to create CIImage", file: file, line: line)
            return
        }
        let scale = image.scale
        let pixelX = ciImage.extent.minX + point.x * scale
        let pixelY = ciImage.extent.maxY - point.y * scale - 1
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.cacheIntermediates: false]).render(
            ciImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: pixelX, y: pixelY, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        XCTAssertLessThanOrEqual(abs(Int(pixel[0]) - Int(expected.0)), tolerance, file: file, line: line)
        XCTAssertLessThanOrEqual(
            abs(Int(pixel[1]) - Int(expected.1)),
            tolerance,
            "Pixel was \(pixel)",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            abs(Int(pixel[2]) - Int(expected.2)),
            tolerance,
            "Pixel was \(pixel)",
            file: file,
            line: line
        )
    }

    func testGoogleTranslationURLMapsSimplifiedChineseAndPreservesPageURL() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/article?q=hello world"))
        let url = try XCTUnwrap(googleTranslationURL(pageURL: pageURL, target: "zh-Hans"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(values["sl"], "auto")
        XCTAssertEqual(values["tl"], "zh-CN")
        XCTAssertEqual(values["u"], pageURL.absoluteString)
    }

    func testGoogleTranslationCatalogCoversEveryAppLanguage() {
        let targets = WebTranslationLanguageCatalog.googleTargets()

        XCTAssertGreaterThan(targets.count, 180)
        XCTAssertNotNil(targets.first { $0.id == "zh-CN" })
        XCTAssertNotNil(targets.first { $0.id == "zh-TW" })
        for language in AppConstants.supportedLanguages {
            XCTAssertNotNil(
                WebTranslationLanguageCatalog.bestMatch(for: language.code, in: targets),
                "Missing Google translation target for \(language.code)"
            )
        }
    }

    func testGoogleTranslationURLMapsTraditionalChineseAndRejectsLocalFiles() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/article"))
        let url = try XCTUnwrap(googleTranslationURL(pageURL: pageURL, target: "zh-Hant"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(values["tl"], "zh-TW")
        XCTAssertNil(
            googleTranslationURL(
                pageURL: URL(fileURLWithPath: "/tmp/private.html"),
                target: "en"
            )
        )
    }

    func testGoogleTranslationURLChangesTargetWithoutNestingTranslatedPage() throws {
        let firstTranslation = try XCTUnwrap(
            googleTranslationURL(
                pageURL: URL(string: "https://example.com/article?q=swift"),
                target: "zh-CN"
            )
        )
        let changedTranslation = try XCTUnwrap(
            googleTranslationURL(pageURL: firstTranslation, target: "ja")
        )
        let components = try XCTUnwrap(
            URLComponents(url: changedTranslation, resolvingAgainstBaseURL: false)
        )
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap {
            item in item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(values["tl"], "ja")
        XCTAssertEqual(values["u"], "https://example.com/article?q=swift")
    }

    func testGoogleTranslationURLRecoversOriginalURLFromProxyHost() throws {
        let proxyURL = try XCTUnwrap(
            URL(string: "https://docs--example-com.translate.goog/guide?item=1&_x_tr_sl=auto&_x_tr_tl=zh-CN")
        )
        let sourceURL = try XCTUnwrap(googleTranslationSourcePageURL(from: proxyURL))

        XCTAssertEqual(sourceURL.absoluteString, "https://docs-example.com/guide?item=1")
    }

    func testAddressTranslationLanguageMatchingHandlesLocalesAndChineseScripts() {
        XCTAssertFalse(
            WebPageLanguageMatcher.shouldOfferTranslation(
                pageIdentifier: "en",
                appIdentifier: "en-GB"
            )
        )
        XCTAssertTrue(
            WebPageLanguageMatcher.shouldOfferTranslation(
                pageIdentifier: "fr",
                appIdentifier: "en-US"
            )
        )
        XCTAssertFalse(
            WebPageLanguageMatcher.shouldOfferTranslation(
                pageIdentifier: "zh-CN",
                appIdentifier: "zh-Hans"
            )
        )
        XCTAssertTrue(
            WebPageLanguageMatcher.shouldOfferTranslation(
                pageIdentifier: "zh-TW",
                appIdentifier: "zh-Hans"
            )
        )
        XCTAssertFalse(
            WebPageLanguageMatcher.shouldOfferTranslation(
                pageIdentifier: nil,
                appIdentifier: "en-US"
            )
        )
    }

    func testGoogleTranslationPageRecognition() throws {
        XCTAssertTrue(
            isGoogleTranslationPageURL(
                URL(string: "https://translate.google.com/translate?sl=auto&tl=fr&u=https://example.com")
            )
        )
        XCTAssertTrue(
            isGoogleTranslationPageURL(
                URL(string: "https://docs--example-com.translate.goog/guide?_x_tr_tl=fr")
            )
        )
        XCTAssertFalse(isGoogleTranslationPageURL(URL(string: "https://example.com/article")))
    }

    func testTranslationLanguageIdentifierUsesMinimalUnambiguousIdentifier() {
        XCTAssertEqual(
            WebTranslationLanguageCatalog.identifier(for: Locale.Language(identifier: "zh-Hans")),
            "zh"
        )
        XCTAssertEqual(
            WebTranslationLanguageCatalog.identifier(for: Locale.Language(identifier: "pt-BR")),
            "pt"
        )
        XCTAssertEqual(
            WebTranslationLanguageCatalog.identifier(for: Locale.Language(identifier: "pt-PT")),
            "pt-PT"
        )
    }

    func testTranslationSourceDetectorUsesDominantPageLanguageAndFiltersConfidentOutlier() throws {
        let fragments = [
            PageTranslationFragment(
                id: "article-1",
                text: "Artificial intelligence enables computers to learn patterns, reason, and solve complex problems."
            ),
            PageTranslationFragment(
                id: "article-2",
                text: "Modern systems combine language understanding with visual perception and planning."
            ),
            PageTranslationFragment(id: "short-label", text: "Home"),
            PageTranslationFragment(
                id: "outlier",
                text: "这是一段明显属于另一种语言的较长网页内容，不应放进同一个批量翻译请求。"
            )
        ]

        let source = try XCTUnwrap(WebTranslationSourceDetector.dominantLanguage(in: fragments))
        XCTAssertEqual(source.languageCode?.identifier, "en")

        let matching = WebTranslationSourceDetector.matchingFragments(fragments, source: source)
        XCTAssertTrue(matching.contains { $0.id == "article-1" })
        XCTAssertTrue(matching.contains { $0.id == "article-2" })
        XCTAssertTrue(matching.contains { $0.id == "short-label" })
        XCTAssertFalse(matching.contains { $0.id == "outlier" })
    }

    func testWebViewModelDetectsPageLanguageAndAppliedTranslation() async throws {
        let html = #"""
        <!doctype html><html lang="fr"><body>
        <main>La traduction de cette page permet aux utilisateurs de lire clairement le contenu
        dans leur langue préférée. Cette phrase fournit suffisamment de texte français fiable.</main>
        </body></html>
        """#
        let (window, webView) = try await makeCaptureWebView(
            html: html,
            size: CGSize(width: 390, height: 500)
        )
        defer { window.isHidden = true }
        _ = try await webView.evaluateJavaScript(
            "window.__souloPageTranslation = { isTranslated: true, entries: {} }"
        )

        let viewModel = WebViewModel()
        viewModel.webView = webView
        await viewModel.refreshPageTranslationState()

        XCTAssertEqual(
            Locale.Language(identifier: viewModel.pageLanguageIdentifier ?? "")
                .languageCode?.identifier,
            "fr"
        )
        XCTAssertTrue(viewModel.isPageTranslationApplied)
    }

    func testPageTranslationBridgePreservesDOMAndRestoresOriginalText() async throws {
        let html = #"""
        <!doctype html><html><body>
        <main id="article">  Hello <strong>world</strong><code>do-not-translate</code></main>
        </body></html>
        """#
        let (window, webView) = try await makeCaptureWebView(
            html: html,
            size: CGSize(width: 390, height: 500)
        )
        defer { window.isHidden = true }
        let originalValue = try await webView.evaluateJavaScript(
            "document.getElementById('article').innerHTML"
        )
        let originalHTML = try XCTUnwrap(originalValue as? String)

        let snapshot = try await WebPageTranslationBridge.extract(from: webView)
        let extractedValue = try await webView.evaluateJavaScript(
            "document.getElementById('article').innerHTML"
        )
        let extractedHTML = try XCTUnwrap(extractedValue as? String)

        XCTAssertEqual(extractedHTML, originalHTML)
        XCTAssertEqual(Set(snapshot.fragments.map(\.text)), Set(["Hello", "world"]))

        let translations = snapshot.fragments.map { fragment in
            (id: fragment.id, text: fragment.text == "Hello" ? "你好" : "世界")
        }
        try await WebPageTranslationBridge.apply(translations, snapshot: snapshot, to: webView)
        let translatedValue = try await webView.evaluateJavaScript(
            "document.getElementById('article').textContent"
        )
        let translatedText = try XCTUnwrap(translatedValue as? String)
        XCTAssertTrue(translatedText.contains("你好"))
        XCTAssertTrue(translatedText.contains("世界"))
        XCTAssertTrue(translatedText.contains("do-not-translate"))

        try await WebPageTranslationBridge.restore(on: webView)
        let restoredValue = try await webView.evaluateJavaScript(
            "document.getElementById('article').innerHTML"
        )
        let restoredHTML = try XCTUnwrap(restoredValue as? String)
        XCTAssertEqual(restoredHTML, originalHTML)
    }

    @MainActor
    func testUserScriptMenuCommandsRegisterUpdateAndClearPerScript() {
        let viewModel = WebViewModel()
        let scriptID = UUID()

        viewModel.registerUserScriptMenuCommand(
            id: "reader-toggle",
            scriptID: scriptID,
            scriptName: "Reader",
            title: "Enable Reader"
        )
        viewModel.registerUserScriptMenuCommand(
            id: "reader-toggle",
            scriptID: scriptID,
            scriptName: "Reader",
            title: "Disable Reader"
        )

        XCTAssertEqual(viewModel.userScriptMenuCommands.count, 1)
        XCTAssertEqual(viewModel.userScriptMenuCommands.first?.title, "Disable Reader")
        viewModel.unregisterUserScriptMenuCommand(id: "reader-toggle", scriptID: scriptID)
        XCTAssertTrue(viewModel.userScriptMenuCommands.isEmpty)

        viewModel.registerUserScriptMenuCommand(
            id: "again",
            scriptID: scriptID,
            scriptName: "Reader",
            title: "Again"
        )
        viewModel.clearUserScriptMenuCommands()
        XCTAssertTrue(viewModel.userScriptMenuCommands.isEmpty)
    }
}
