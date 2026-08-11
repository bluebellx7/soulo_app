import XCTest
import UIKit
import SwiftData
@testable import Soulo

@MainActor
final class WebViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: LiveActivityService.enabledKey)
        super.tearDown()
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
}
