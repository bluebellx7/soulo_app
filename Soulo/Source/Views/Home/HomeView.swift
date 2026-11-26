import SwiftUI
import CoreData
import StoreKit

private let homeSearchScrollTarget = "home.search.scroll-target"
private let homeSearchBottomScrollTarget = "home.search.bottom-target"

struct HomeView: View {
    @Environment(\.colorScheme) private var homeColorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appAppearance = "system"
    @AppStorage(PlatformBarPreferences.homeQuickSearchKey) private var homeQuickSearch = false
    private var wallpaperAppearance: WallpaperAppearance {
        // Refresh for trait changes, but never use browser chrome's override
        // to select a different home wallpaper or gradient preset.
        let _ = homeColorScheme
        return .appPreference(appAppearance, systemIsDark: UIScreen.main.traitCollection.userInterfaceStyle == .dark)
    }
    private var usesLightWallpaperContent: Bool {
        wallpaperManager.prefersDarkForeground(for: wallpaperAppearance)
    }
    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var homeToolbar = HomeToolbarConfigurationService.shared
    @State private var homeToolbarDestination: HomeToolbarAction?
    @ObservedObject private var platformStore = PlatformDataStore.shared
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @StateObject private var speechService = SpeechRecognitionService()
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var keyboardVisible = false
    @State private var homeSearchReveal: HomeSearchSwipeDirection?
    @State private var wallpaperFrame: CGRect = .zero
    @State private var landscapeIPadWindow = false
    @StateObject private var keyboardContext = BrowserKeyboardContext()
    @State private var reviewTask: Task<Void, Never>?

    @State private var showSettings = false
    @State private var showExtensionCenter = false
    @State private var isRefreshingWallpaper = false
    @State private var librarySection: LibrarySection?
    @State private var navigationSession = UUID()
    @State private var pendingSelectionSearch: (text: String, platform: SearchPlatform, url: URL)?
    @State private var selectionSearchID = UUID()
    @State private var pendingURLRoute: SouloURLRoute?
    @State private var urlRouteID = UUID()
    @State private var downloadCreation: DownloadCreationRequest?
    @State private var extensionStoreRequest: ExtensionStoreRequest?
    @State private var incomingDocument: IncomingDocument?
    @State private var showScanner = false
    @State private var showPlatformManagement = false
    @State private var pendingScan: String?
    @State private var scannedContent: ScannedContent?
    @State private var showVoiceInput = false
    @State private var showAppShareSheet = false
    @State private var wallpaperPreview: WallpaperExportPreviewModel?
    @State private var showTabOverviewFromHome = false
    @State private var showTitleEditor = false
    @State private var showSubtitleEditor = false
    @State private var editingTitle = ""
    @State private var editingSubtitle = ""
    @State private var wallpaperLoadTask: Task<Void, Never>?
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = AppConstants.defaultHomeSubtitle
    @AppStorage(HomePageElement.bookmarksKey) private var showBookmarksOnHome = HomePageElement.bookmarks.defaultVisibility
    @AppStorage(HomePageElement.recentSearchesKey) private var showRecentSearchesOnHome = HomePageElement.recentSearches.defaultVisibility
    @AppStorage("last_selected_region") private var lastRegion: String = ""
    @AppStorage("last_selected_group_id") private var lastGroupID: String = ""
    @FetchRequest(sortDescriptors: BookmarkService.sortDescriptors) private var bookmarks: FetchedResults<BookmarkRecord>
    @State private var dynamicTheme: DynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight

    private var displayedHomeTitle: String {
        showsHomeElement(.title) ? homeTitle.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private var displayedHomeSubtitle: String {
        showsHomeElement(.subtitle) ? homeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    private func showsHomeElement(_ element: HomePageElement) -> Bool {
        homeToolbar.layout.shows(element, in: homeToolbar.actions)
    }

    private static let homeSearchTransitionDuration = 0.24
    private var homeSearchAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: Self.homeSearchTransitionDuration)
    }
    private var showsHomeSearch: Bool { showsHomeElement(.search) || homeSearchReveal != nil }
    private var usesHomeSuggestions: Bool { showsHomeSearch && !homeQuickSearch }
    private var searchAtBottom: Bool {
        showsHomeSearch && homeToolbar.layout.searchPlacement == .bottom
    }
    private var freeToolbarSharesBottom: Bool {
        searchAtBottom && showsHomeToolbar(.free) && homeToolbar.layout.freeToolbarAtBottom
    }

    private var showsTabOverview: Bool {
        showTabOverviewFromHome || tabManager.showTabOverview
    }

    private var keyboardCommandsEnabled: Bool {
        scenePhase == .active && !showSettings && librarySection == nil && !showExtensionCenter
            && !showScanner && !showPlatformManagement && !showVoiceInput && !showAppShareSheet && wallpaperPreview == nil
            && !showTitleEditor && !showSubtitleEditor && !showsTabOverview && homeToolbarDestination == nil
            && downloadCreation == nil && incomingDocument == nil && scannedContent == nil
            && extensionStoreRequest == nil
    }

    var body: some View {
        NavigationStack {
            homeSurface
                .toolbar(.hidden, for: .navigationBar)
                .mediaPlayerNavigation()
        }
        .background { BrowserKeyboardWindowReader(context: keyboardContext).frame(width: 0, height: 0).allowsHitTesting(false) }
        .background {
            if homeQuickSearch && UIDevice.current.userInterfaceIdiom == .pad {
                ViewWindowReader { window in
                    let size = window?.bounds.size ?? .zero
                    landscapeIPadWindow = size.width > size.height
                }
                .allowsHitTesting(false)
            }
        }
        .focusedSceneValue(\.souloBrowserKeyboardActions,
            BrowserKeyboardActions(enabled: keyboardCommandsEnabled,
                canPerform: { keyboardContext.canPerform },
                focus: {
                    if searchVM.isSearching, let model = tabManager.activeWebViewModel {
                        NotificationCenter.default.post(name: .focusSouloBrowserAddress, object: model)
                    } else { focusHomeSearch() }
                },
                newTab: { tabManager.openNewTab(); searchVM.isSearching = true },
                closeTab: { tabManager.closeTab(at: tabManager.activeTabIndex) },
                restoreTab: { tabManager.restoreLastClosedTab(); searchVM.isSearching = true },
                reload: { tabManager.activeWebViewModel?.reload() },
                back: { tabManager.activeWebViewModel?.goBack() },
                forward: { tabManager.activeWebViewModel?.goForward() },
                find: { tabManager.startFindInPage() },
                newWindow: { openWindow(value: BrowserWindowConfiguration()) },
                moveTabToWindow: {
                    if let id = tabManager.activeTab?.id,
                       let configuration = BrowserWindowTransferService.shared.prepare(from: tabManager, tabID: id) {
                        openWindow(value: configuration)
                    }
                }, showTabs: { tabManager.showTabOverview = true },
                showDownloads: { librarySection = .downloads },
                showExtensions: { showExtensionCenter = true }))
        .tabOverviewBackground(isActive: showsTabOverview)
        .onCompatibleChange(of: tabManager.lastTabClosedRevision) { _, _ in
            returnHomeFromTabOverview()
        }
        .onReceive(tabManager.extensionForegroundNavigation) {
            showExtensionCenter = false
            showSettings = false
            showTabOverviewFromHome = false
            searchVM.isSearching = true
        }
        .animation(.easeInOut(duration: 0.22), value: showsTabOverview)
        .id(navigationSession)
        .task(id: urlRouteID) {
            guard let route = pendingURLRoute else { return }
            pendingURLRoute = nil
            handleURLRoute(route)
        }
        .task(id: selectionSearchID) {
            // Dismiss reader destinations before publishing a new tab, while
            // keeping the navigation controller and browser root mounted.
            guard let request = pendingSelectionSearch else { return }
            pendingSelectionSearch = nil
            let tab = tabManager.createTab(keyword: request.text, platform: request.platform)
            tabManager.setDesktopModeForCurrentNavigation(request.platform.requiresDesktopMode)
            tab.webViewModel.loadURL(request.url)
        }
        .overlay { MediaMiniPlayer() }
        #if SOULO_ACCEPTANCE
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.environment["SOULO_ACCEPTANCE_PROBE"] == "1" {
                DeviceAcceptanceProbe(speech: speechService, openVoice: { showVoiceInput = true })
            }
        }
        #endif
        .overlay(alignment: .top) {
            DownloadCompletionToast { librarySection = .downloads }
        }
        // Present once above the entire navigation surface, including browser
        // chrome and safe areas. A page-local overlay leaves hard backdrop edges.
        .overlay {
            if showsTabOverview {
                TabSwitcherOverlay(
                    tabManager: tabManager,
                    onSelectTab: { index in
                        tabManager.switchToTab(at: index)
                        searchVM.isSearching = true
                    },
                    onGoHome: returnHomeFromTabOverview,
                    onDismiss: {
                        showTabOverviewFromHome = false
                        tabManager.showTabOverview = false
                    }
                )
            }
        }
    }

    private func returnHomeFromTabOverview() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showTabOverviewFromHome = false
            tabManager.showTabOverview = false
            searchVM.clearSearch()
        }
    }

    private var homeSurfaceBase: some View {
        ZStack {
            // Keep the wallpaper outside every content transition and tab-card
            // transform. Scaling the wallpaper with the page exposes the hosting
            // controller's default background around the safe-area edges.
            WallpaperBackground(isAnimating: !searchVM.isSearching && !showsTabOverview
                && !keyboardVisible && !showSettings && librarySection == nil && wallpaperPreview == nil,
                appearanceOverride: wallpaperAppearance, onFrameChange: { wallpaperFrame = $0 })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            Group {
                if searchVM.isSearching {
                    SearchResultsView(
                        speechService: speechService,
                        onOpenSettings: { showSettings = true }
                    )
                    .transition(.identity)
                } else {
                    homeContent
                        .environment(\.colorScheme, wallpaperAppearance == .dark ? .dark : .light)
                        .transition(.opacity)
                    if isRefreshingWallpaper && !homeToolbar.actions.contains(.refreshWallpaper) {
                        VStack {
                            ProgressView()
                                .padding(11)
                                .background(.regularMaterial, in: Circle())
                                .accessibilityLabel(ToolText.text("wallpaper_refresh"))
                                .padding(.top, 12)
                            Spacer()
                        }
                        .allowsHitTesting(false)
                    }
                }

                // Clipboard prompt
                if searchVM.showClipboardPrompt {
                    ClipboardPromptView(onSearch: { performSearch() })
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                }


            }
        }
        .background {
            // A non-white first frame while an image/Canvas wallpaper is being
            // decoded or the app is returning from a sheet/background state.
            Color(red: 0.05, green: 0.07, blue: 0.16)
                .ignoresSafeArea()
        }
    }

    private var homeSurfaceDestinations: some View {
        homeSurfaceBase
        .sheet(item: $homeToolbarDestination) { HomeToolbarDestinationView(action: $0) }
        .sheet(item: $downloadCreation) { NewDownloadTaskView(initialURL: $0.url) }
        .sheet(item: $extensionStoreRequest) { request in
            WebExtensionStoreInstallView(initialValue: request.url.absoluteString)
                .presentationDetents([.height(390), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPlatformManagement) {
            NavigationStack {
                PlatformManagementView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(languageManager.localizedString("done")) {
                                showPlatformManagement = false
                            }
                        }
                    }
            }
        }
        .sheet(isPresented: $showExtensionCenter) {
            NavigationStack {
                ExtensionCenterView(onOpenInBrowser: { url in
                    tabManager.openURLFromBrowserControls(url, searchID: searchVM.searchID, inNewTab: true)
                    searchVM.isSearching = true
                    showExtensionCenter = false
                })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(LanguageManager.shared.localizedString("done")) {
                                showExtensionCenter = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .compatibleNavigationDestination(item: $librarySection) { section in
            LibraryView(initialSection: section, searchVM: searchVM)
        }
        .compatibleNavigationDestination(item: $incomingDocument) { document in
            ExternalDocumentView(source: document.url)
        }
    }

    private var homeSurfacePresentation: some View {
        homeSurfaceDestinations
        .sheet(isPresented: $showScanner, onDismiss: {
            guard let value = pendingScan else { return }
            pendingScan = nil
            let result = ScannedContent(text: value)
            if let url = result.webURL {
                searchVM.searchText = url.absoluteString
                performSearch()
            } else { scannedContent = result }
        }) {
            QRCodeScannerView { value in pendingScan = value; showScanner = false }
        }
        .compatibleNavigationDestination(item: $scannedContent) { content in LocalScanResultView(content: content) }
        .sheet(isPresented: $showVoiceInput) {
            VoiceInputView(
                speechService: speechService,
                onConfirm: { text in
                    searchVM.searchText = text
                    showVoiceInput = false
                    performSearch()
                },
                onDismiss: { showVoiceInput = false }
            )
        }
        .sheet(item: $wallpaperPreview) { WallpaperExportPreview(model: $0) }
        .sheet(isPresented: $showAppShareSheet) {
            HomeActivityView(items: [
                LanguageManager.shared.localizedString("share_app_message"),
                URL(string: "https://apps.apple.com/app/id6761165330")!
            ])
        }
        .alert(LanguageManager.shared.localizedString("edit_title"), isPresented: $showTitleEditor) {
            TextField("Soulo", text: $editingTitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeTitle = editingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button(LanguageManager.shared.localizedString("platform_reset_defaults")) { homeTitle = "Soulo" }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showSubtitleEditor) {
            TextField(languageManager.localizedString("app_subtitle"), text: $editingSubtitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeSubtitle = editingSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button(LanguageManager.shared.localizedString("platform_reset_defaults")) { homeSubtitle = AppConstants.defaultHomeSubtitle }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
    }

    private var homeSurface: some View {
        homeSurfacePresentation
        .onAppear {
            BrowserStartupTrace.mark("home_appear")
            ReviewPromptPolicy.recordUse()
            editingTitle = homeTitle
            editingSubtitle = homeSubtitle
            searchVM.loadRecentSearches(context: modelContext)
            searchVM.setHomeAutocompleteEnabled(usesHomeSuggestions)
            wallpaperLoadTask?.cancel()
            wallpaperLoadTask = Task { @MainActor in
                guard !Task.isCancelled else { return }
                while searchVM.input.isEditing {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                }
                wallpaperManager.ensureLoaded()
            }
            if let action = AppQuickActionService.shared.consumePendingAction() {
                handleQuickAction(action)
            }
        }
        .onDisappear {
            reviewTask?.cancel()
            wallpaperLoadTask?.cancel()
        }
        .onCompatibleChange(of: searchVM.isSearching) { _, isSearching in
            reviewTask?.cancel()
            if isSearching { homeSearchReveal = nil }
            if !isSearching {
                searchVM.loadRecentSearches(context: modelContext)
                reviewTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, !searchVM.isSearching, !keyboardVisible, scenePhase == .active,
                          !showSettings, !showExtensionCenter, librarySection == nil,
                          !showVoiceInput, !showAppShareSheet, wallpaperPreview == nil, !showTabOverviewFromHome,
                          !showTitleEditor, !showSubtitleEditor, !MediaSession.shared.expanded else { return }
                    if ReviewPromptPolicy.consumeIfEligible() { requestReview() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            keyboardVisible = false
        }
        .onCompatibleChange(of: showsHomeElement(.search)) { _, _ in homeSearchReveal = nil }
        .onCompatibleChange(of: usesHomeSuggestions) { _, enabled in searchVM.setHomeAutocompleteEnabled(enabled) }
        .onReceive(NotificationCenter.default.publisher(for: .appQuickActionReceived)) { notification in
            guard let action = notification.object as? AppQuickAction else { return }
            _ = AppQuickActionService.shared.consumePendingAction()
            handleQuickAction(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSouloDownloads)) { _ in
            librarySection = .downloads
        }
        .onReceive(NotificationCenter.default.publisher(for: .createSouloDownload)) { notification in
            downloadCreation = DownloadCreationRequest(url: notification.object as? URL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSouloDocument)) { notification in
            if let url = notification.object as? URL {
                if url.pathExtension.lowercased() == "torrent" {
                    downloadCreation = DownloadCreationRequest(url: url)
                    return
                }
                resetNavigationForExternalEntry()
                incomingDocument = IncomingDocument(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchSelectionInSoulo), perform: handleSelectionSearchNotification)
        .onContinueUserActivity(BrowserHandoff.activityType) { activity in
            guard let url = BrowserHandoff.eligibleURL(activity.webpageURL, isPrivate: false) else { return }
            resetNavigationForExternalEntry(recreateStack: false)
            pendingURLRoute = .open(url)
            urlRouteID = UUID()
        }
        .onOpenURL { url in
            guard !ExternalBrowserService.shared.consumeReturnedURL(url) else { return }
            guard let route = SouloURLRoute.parse(url) else { return }
            // Reusing the browser's live navigation items in a replacement stack
            // can make UIKit attach the same item to two navigation bars.
            // Opening/searching a URL only needs to dismiss external destinations.
            switch route {
            case .open, .search, .installExtension: resetNavigationForExternalEntry(recreateStack: false)
            default: resetNavigationForExternalEntry()
            }
            pendingURLRoute = route
            urlRouteID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .prepareSouloExternalEntry)) { notification in
            guard (notification.object as? SearchViewModel) === searchVM else { return }
            resetNavigationForExternalEntry(recreateStack: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSouloWebURL)) { notification in
            guard (notification.userInfo?["owner"] as? SearchViewModel) === searchVM,
                  let url = notification.object as? URL else { return }
            resetNavigationForExternalEntry(recreateStack: false)
            pendingURLRoute = .open(url)
            urlRouteID = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSouloFiles)) { _ in
            resetNavigationForExternalEntry()
            librarySection = .files
        }
    }

    private func handleSelectionSearchNotification(_ notification: Notification) {
        guard let text = notification.object as? String, !text.isEmpty else { return }
        searchVM.searchText = text
        searchVM.performSearch(context: modelContext)
        searchVM.isSelectionSearch = true
        if let platform = searchVM.selectedPlatform, let url = platform.searchURL(for: text) {
            pendingSelectionSearch = (text, platform, url)
            resetNavigationForExternalEntry(recreateStack: false)
            selectionSearchID = UUID()
        }
    }

    private func handleURLRoute(_ route: SouloURLRoute) {
        searchVM.showClipboardPrompt = false
        switch route {
        case .home:
            homeSearchReveal = nil
            searchVM.clearSearch()
        case .search(let text):
            if let text {
                searchVM.searchText = text
                performSearch()
                searchVM.externalSearchRequestID = searchVM.searchID
            } else {
                handleQuickAction(.search)
            }
        case .open(let url):
            searchVM.searchText = url.absoluteString
            performSearch()
            searchVM.externalSearchRequestID = searchVM.searchID
        case .scan:
            searchVM.clearSearch()
            showScanner = true
        case .files: librarySection = .files
        case .bookmarks: librarySection = .bookmarks
        case .history: librarySection = .history
        case .downloads: librarySection = .downloads
        case .download(let url):
            librarySection = .downloads
            Task {
                // The existing background service owns progress, errors and the
                // completion toast. No website cookies are attached to an external URL.
                _ = try? await WebResourceDownloadService.shared.download(url)
            }
        case .installExtension(let url):
            extensionStoreRequest = ExtensionStoreRequest(url: url)
        }
    }

    private func resetNavigationForExternalEntry(recreateStack: Bool = true) {
        // A widget or Open In request must work even with a reader pushed above
        // the library. Recreate the navigation stack while retaining tab models.
        librarySection = nil
        extensionStoreRequest = nil
        incomingDocument = nil
        scannedContent = nil
        pendingScan = nil
        showScanner = false
        showSettings = false
        showExtensionCenter = false
        showVoiceInput = false
        showTabOverviewFromHome = false
        homeSearchReveal = nil
        showAppShareSheet = false
        wallpaperPreview = nil
        if recreateStack { navigationSession = UUID() }
    }

    // MARK: - Home Content

    private var homeContent: some View {
        VStack(spacing: 0) {
            if showsHomeTabs || !hidesHomeMenu {
                homeShortcutBar.padding(.top, 8)
            }
            GeometryReader { viewport in
                let width = max(0, viewport.size.width - 2 * HomeLandingSpacing.toolbarSideInset)
                let toolbar = HomeToolbarMetrics(width: homeToolbar.layout.placement == .bottom ? min(526, width) : width,
                    count: homeToolbarIndices.count, style: homeToolbar.layout.style)
                homeContent(toolbar: toolbar, bottomSafeArea: viewport.safeAreaInsets.bottom)
                    .overlayPreferenceValue(HomeToolbarContentBounds.self) { bounds in
                        ZStack {
                            Color.clear.allowsHitTesting(false)
                            if showsHomeToolbar(.free) {
                                freeHomeToolbar(width: width, toolbar: toolbar, avoiding: bounds)
                            } else if showsHomeToolbar(.bottom) {
                                liveHomeToolbar(metrics: toolbar)
                                    .frame(maxWidth: .infinity, alignment: homeToolbar.layout.alignment.frameAlignment)
                                    .padding(.horizontal, HomeLandingSpacing.toolbarSideInset)
                                    .padding(.bottom, HomeLandingSpacing.bottomToolbarLift)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                        // Leave room for the home indicator at the edge.
                        .padding(.bottom, min(viewport.safeAreaInsets.bottom, HomeLandingSpacing.toolbarSafeInset))
                        .ignoresSafeArea(.container, edges: .bottom)
                    }
            }
        }
        .buttonStyle(HomePressButtonStyle())
    }

    private func freeHomeToolbar(width: CGFloat, toolbar: HomeToolbarMetrics, avoiding bounds: [Anchor<CGRect>]) -> some View {
        GeometryReader { geometry in
            let sideMargin = HomeLandingSpacing.toolbarSideInset
            let area = CGSize(width: width, height: geometry.size.height)
            let obstacles = bounds.map { geometry[$0].offsetBy(dx: -sideMargin, dy: 0) }
            if let center = homeToolbar.layout.freeCenter(in: area, strip: toolbar.size, avoiding: obstacles,
                dockAtBottom: homeToolbar.layout.freeToolbarAtBottom) {
                liveHomeToolbar(metrics: toolbar)
                    .position(x: center.x + sideMargin, y: center.y)
            }
        }
    }

    private func homeContent(toolbar: HomeToolbarMetrics, bottomSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Keep the search field mounted while the window or keyboard changes the viewport.
            GeometryReader { geometry in
                let bottomInset = homeSearchBottomInset(toolbar: toolbar, bottomSafeArea: bottomSafeArea)
                let bottomSearchViewportHeight = searchAtBottom ? geometry.size.height.rounded() : nil
                let prioritizesPlatformSearch = homeQuickSearch && landscapeIPadWindow && keyboardVisible
                    && showsHomeSearch && !searchAtBottom
                ScrollViewReader { scroll in
                    ScrollView {
                        SearchLandingLayout(viewportHeight: max(0, geometry.size.height - 16 - bottomInset),
                            headingGap: prioritizesPlatformSearch ? 0 : HomeLandingSpacing.headingGap(
                                for: verticalSizeClass, showsSubtitle: !displayedHomeSubtitle.isEmpty),
                            detailsGap: HomeLandingSpacing.detailsGap(for: verticalSizeClass),
                            searchOffsetRatio: -0.5, searchAtBottom: searchAtBottom,
                            alignsSearchAtTop: prioritizesPlatformSearch) {
                            VStack(spacing: 0) {
                                if !prioritizesPlatformSearch {
                                    homeHeading
                                        .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
                                        .padding(.horizontal, 24)
                                }
                            }
                            VStack(spacing: 0) {
                                if showsHomeSearch {
                                    homeSearchField(width: min(600, max(0, geometry.size.width - 2 * HomeLandingSpacing.contentInset)))
                                        .id(homeSearchScrollTarget)
                                        .zIndex(1)
                                        .transition(homeSearchTransition)
                                        .task(id: homeSearchReveal) {
                                            guard let direction = homeSearchReveal else { return }
                                            await Task.yield()
                                            guard !Task.isCancelled, homeSearchReveal == direction else { return }
                                            withAnimation(homeSearchAnimation) {
                                                if searchAtBottom { scroll.scrollTo(homeSearchBottomScrollTarget, anchor: .bottom) }
                                                else { scroll.scrollTo(homeSearchScrollTarget, anchor: .center) }
                                            }
                                            // Let the field slide in before the keyboard resizes the landing view.
                                            if !reduceMotion {
                                                try? await Task.sleep(for: .seconds(Self.homeSearchTransitionDuration))
                                            }
                                            guard !Task.isCancelled, homeSearchReveal == direction else { return }
                                            postHomeSearchFocus()
                                        }
                                }
                            }
                            .zIndex(1)
                            homeSearchDetails
                                .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
                        }
                        .frame(maxWidth: 656)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                        .padding(.bottom, bottomInset)
                        .id(homeSearchBottomScrollTarget)
                        .background {
                            if hidesHomeMenu { homeMenuRecovery }
                        }
                        .background(alignment: .topLeading) {
                            if !showsHomeElement(.search) {
                                HomeSearchSwipeObserver(onSwipe: handleHomeSearchSwipe)
                                    .frame(width: 0, height: 0)
                            }
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .accessibilityIdentifier("home.search.area")
                    .task(id: bottomSearchViewportHeight) {
                        guard bottomSearchViewportHeight != nil else { return }
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        scroll.scrollTo(homeSearchBottomScrollTarget, anchor: .bottom)
                    }
                }
                // Anchor over the visible viewport so the panels can receive taps
                // without changing the scroll content or sitting behind the keyboard.
                .overlayPreferenceValue(HomeSearchBounds.self) { bounds in
                    if let bounds {
                        GeometryReader { viewport in
                            HomeSearchPanel(input: searchVM.input, searchFrame: viewport[bounds],
                                viewportHeight: viewport.size.height, prefersAbove: searchAtBottom,
                                rowLimit: landscapeIPadWindow ? 4 : 3, platformPicker: homePlatformPicker,
                                onSuggestionSelect: { suggestion in
                                    searchVM.searchText = suggestion
                                    performSearch()
                                }, onSuggestionFill: { searchVM.searchText = $0 })
                        }
                    }
                }
            }
        }
        .padding(.bottom, showsHomeToolbar(.bottom) ? max(0, toolbar.size.height + HomeLandingSpacing.bottomToolbarTopInset
            + HomeLandingSpacing.bottomToolbarLift
            - HomeLandingSpacing.toolbarSafeAreaExtension(bottomSafeArea)) : 0)
    }

    private func homeSearchBottomInset(toolbar: HomeToolbarMetrics, bottomSafeArea: CGFloat) -> CGFloat {
        guard searchAtBottom, !keyboardVisible else { return 16 }
        if showsHomeToolbar(.bottom) { return HomeLandingSpacing.searchAboveToolbarInset }
        if freeToolbarSharesBottom {
            let strip = toolbar.size.height
            let safeAreaExtension = HomeLandingSpacing.toolbarSafeAreaExtension(bottomSafeArea)
            return max(HomeLandingSpacing.searchAboveToolbarInset, strip + HomeToolbarLayout.searchClearance - safeAreaExtension)
        }
        return 16
    }

    private var homeHeading: some View {
        Group {
                VStack(spacing: 6) {
                    if !displayedHomeTitle.isEmpty {
                        Button { showTitleEditor = true } label: {
                            Text(displayedHomeTitle)
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47") : .white)
                                .shadow(color: usesLightWallpaperContent ? .black.opacity(0.05) : .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        }
                        .accessibilityLabel(
                            AppAccessibility.formatted("accessibility_home_title", displayedHomeTitle)
                        )
                        .accessibilityHint(
                            languageManager.localizedString("accessibility_edit_title_hint")
                        )
                        .accessibilityAddTraits(.isHeader)
                    } else if showsHomeElement(.title) {
                        Text("Soulo")
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .hidden().accessibilityHidden(true)
                    }

                    if !displayedHomeSubtitle.isEmpty {
                        Button { showSubtitleEditor = true } label: {
                            Text(displayedHomeSubtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.8))
                                .tracking(1.5)
                        }
                        .accessibilityLabel(
                            AppAccessibility.formatted(
                                "accessibility_home_subtitle",
                                displayedHomeSubtitle
                            )
                        )
                        .accessibilityHint(
                            languageManager.localizedString("accessibility_edit_subtitle_hint")
                        )
                    } else if showsHomeElement(.subtitle) {
                        Text(" ")
                            .font(.system(size: 13, weight: .medium))
                            .hidden().accessibilityHidden(true)
                    }
                }

        }
    }

    private var homeSearchRegion: PlatformRegion {
        PlatformRegion(rawValue: lastRegion) ?? searchVM.selectedRegion
    }

    private var homeSearchGroup: CustomGroup? {
        platformStore.customGroups.first { $0.id.uuidString == lastGroupID }
    }

    private var homeSearchScope: SearchGroupScope {
        homeSearchGroup.map { .custom($0.id) } ?? .region(homeSearchRegion)
    }

    private var homePlatformPicker: BrowserPlatformPickerContext? {
        guard homeQuickSearch else { return nil }
        return BrowserPlatformPickerContext(scope: homeSearchScope,
            selectedPlatformID: nil, onSelect: searchOnHomePlatform,
            onManage: { showPlatformManagement = true },
            onScopeChange: { scope in
                selectHomeSearchScope(scope)
                retainHomePlatformSearchFocus()
            })
    }

    private func selectHomeSearchScope(_ scope: SearchGroupScope) {
        switch scope {
        case .region(let region):
            lastRegion = region.rawValue
            lastGroupID = ""
            searchVM.selectRegion(region)
        case .custom(let id):
            guard let group = platformStore.customGroups.first(where: { $0.id == id }) else { return }
            lastGroupID = group.id.uuidString
            lastRegion = ""
            searchVM.selectCustomGroup(group)
        }
    }

    private func searchOnHomePlatform(_ scope: SearchGroupScope, _ platform: SearchPlatform) {
        guard case .search? = BrowserNavigationResolver.classify(searchVM.searchText) else { return }
        if scope != homeSearchScope { selectHomeSearchScope(scope) }
        performSearch(platform: platform)
    }

    private func retainHomePlatformSearchFocus() {
        if let window = keyboardContext.window { AppKeyboardDismissal.cancelPendingDismissal(in: window) }
        if showsHomeSearch, keyboardCommandsEnabled, !searchVM.input.isEditing { postHomeSearchFocus() }
    }

    private func homeSearchField(width: CGFloat) -> some View {
        SearchBarView(
                input: searchVM.input,
                isIncognito: searchVM.isIncognito,
                isRecording: speechService.isRecording,
                searchActionsArrowEdge: searchAtBottom ? .bottom : .top,
                onSubmit: { performSearch() },
                onMicTap: { showVoiceInput = true },
                onIncognitoTap: { togglePrivateModeFromSearchBar() },
                onScanTap: { showScanner = true },
                selectedRegion: homeSearchRegion,
                selectedGroupID: homeSearchGroup?.id,
                onRegionSelect: { selectHomeSearchScope(.region($0)) },
                onGroupSelect: { selectHomeSearchScope(.custom($0.id)) },
                onPlatformManagementTap: { showPlatformManagement = true }
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home.search.field")

            .frame(width: width)
            .anchorPreference(key: HomeSearchBounds.self, value: .bounds) { $0 }
            .anchorPreference(key: HomeToolbarContentBounds.self, value: .bounds) { [$0] }
            .padding(.horizontal, HomeLandingSpacing.contentInset)
    }

    private var homeSearchDetails: some View {
        VStack(spacing: HomeLandingSpacing.detailsGap(for: verticalSizeClass)) {
            // Bookmark icons
            if showBookmarksOnHome && !bookmarks.isEmpty {
                homeBookmarksRow
            }

            // Recent searches (hidden while typing, shown when empty)
            if showRecentSearchesOnHome
                && !searchVM.recentSearches.isEmpty {
                HomeRecentSearches(
                    input: searchVM.input,
                    recentSearches: searchVM.recentSearches,
                    contrast: wallpaperManager.contrast(in: wallpaperFrame),
                    onTap: { keyword in
                        searchVM.searchText = keyword
                        performSearch()
                    },
                    onDelete: { keyword in
                        searchVM.deleteHistoryItem(keyword: keyword, context: modelContext)
                    }
                )
                .frame(maxWidth: .infinity)
                .clipped()
                .padding(.top, HomeLandingSpacing.recentSearchInset)
            }
        }
    }


    // MARK: - Top Bar

    private var homeToolbarIndices: [Int] { homeToolbar.actions.indices.filter { homeToolbar.actions[$0] != .none } }

    private func showsHomeToolbar(_ placement: HomeToolbarLayout.Placement) -> Bool {
        homeToolbar.isVisible && !keyboardVisible && homeToolbar.layout.placement == placement
    }

    private func liveHomeToolbar(metrics: HomeToolbarMetrics) -> some View {
        WallpaperForegroundRegion(contrast: wallpaperManager.contrast(in: wallpaperFrame),
            fallbackDarkInk: wallpaperManager.source == .solid && usesLightWallpaperContent) { darkInk in
            let appearance = HomeToolbarAppearance(lightWallpaper: darkInk, source: wallpaperManager.source)
            HomeToolbarStrip(indices: homeToolbarIndices, metrics: metrics, style: homeToolbar.layout.style,
                appearance: appearance) { homeToolbarButton($0, appearance: appearance) }
        }
    }

    private func homeToolbarButton(_ index: Int, appearance: HomeToolbarAppearance) -> some View {
        let action = homeToolbar.actions[index]
        let face = HomeToolbarButtonFace(action: action, appearance: appearance,
            isActive: action == .privateBrowsing && searchVM.isIncognito,
            isLoading: action == .refreshWallpaper && isRefreshingWallpaper,
            tabCount: tabManager.tabCount)
        return Group {
            if action == .more {
                Menu {
                    homeMenuActions(includesSettings: true)
                } label: { face }
            } else {
                Button { performHomeToolbarAction(action) } label: { face }
                    .contextMenu {
                        if action == .settings && hidesHomeMenu {
                            homeMenuActions(includesSettings: false)
                            Divider()
                        }
                        Button { homeToolbarDestination = .homeToolbar } label: {
                            Label(ToolText.text("home_toolbar_customize"), systemImage: "slider.horizontal.3")
                        }
                    }
            }
        }
        .buttonStyle(HomeToolbarButtonStyle(appearance: appearance, showsBackground: homeToolbar.layout.style == .tiles))
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("home.toolbar.\(index)")
        .accessibilityAddTraits(action == .privateBrowsing && searchVM.isIncognito ? .isSelected : [])
        .disabled(action == .refreshWallpaper && (isRefreshingWallpaper || wallpaperManager.networkLoading))
    }

    // MARK: - Home Bookmarks Row

    private var homeBookmarksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HomeLandingSpacing.bookmarkSpacing) {
                ForEach(bookmarks.prefix(10)) { bookmark in
                    Button {
                        searchVM.searchText = bookmark.urlString
                        performSearch()
                    } label: {
                        HomeBookmarkTile(title: bookmark.title, lightWallpaper: usesLightWallpaperContent) {
                            BookmarkFaviconView(urlString: bookmark.urlString, size: HomeLandingSpacing.bookmarkIconSize)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(bookmark.title)
                    .accessibilityValue(URL(string: bookmark.urlString)?.host ?? bookmark.urlString)
                    .accessibilityHint(
                        languageManager.localizedString("accessibility_open_bookmark_hint")
                    )
                    .contextMenu {
                        Button { librarySection = .bookmarks } label: {
                            Label(languageManager.localizedString("my_favorites"), systemImage: "bookmark")
                        }
                        Button(role: .destructive) {
                            BookmarkService.delete(bookmark, context: modelContext)
                        } label: {
                            Label(languageManager.localizedString("delete"), systemImage: "trash")
                        }
                    }
                }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, HomeLandingSpacing.contentInset)
        }
        .accessibilityIdentifier("home.bookmarks")
    }

    /// Show the tab switcher whenever there is anything worth restoring or previewing.
    private var shouldShowTabEntry: Bool {
        tabManager.tabs.count > 1 || tabManager.tabs.contains {
            $0.webViewModel.currentURL != nil || $0.webViewModel.snapshot != nil
        }
    }

    private var showsHomeTabs: Bool {
        showsHomeElement(.tabs) && (shouldShowTabEntry || searchVM.isIncognito)
    }

    private var hidesHomeMenu: Bool {
        !showsHomeElement(.menu)
    }

    private var homeMenuRecovery: some View {
        Color.clear
            .contentShape(Rectangle())
            .contextMenu { homeMenuActions(includesSettings: true) }
            .accessibilityElement()
            .accessibilityLabel(languageManager.localizedString("show_more"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showSettings = true }
            .accessibilityIdentifier("home.menu.recovery")
    }

    private var homeShortcutBar: some View {
        HStack(spacing: 10) {
            // Existing tabs and the tab switcher remain available in private mode.
            // Privacy changes what is persisted, not which browser controls are shown.
            if showsHomeTabs {
                Button {
                    HapticsManager.light()
                    openHomeTabSwitcher()
                } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.6), lineWidth: 1.2)
                                .frame(width: 16, height: 16)
                            Text("\(tabManager.tabCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.7))
                        }
                        Text(LanguageManager.shared.localizedString("tab_tabs"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.8))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if usesLightWallpaperContent {
                            Capsule().fill(Color.black.opacity(0.04))
                        } else {
                            Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(tabManager.tabCount) \(LanguageManager.shared.localizedString("tab_tabs"))"
                )
                .accessibilityHint(
                    languageManager.localizedString("accessibility_tab_overview_hint")
                )
                .accessibilityIdentifier("home.tabs")
                .accessibilityValue("\(tabManager.tabCount)")
            }

            Spacer()

            if !hidesHomeMenu { homeMenu }
        }
        .padding(.horizontal, HomeLandingSpacing.toolbarSideInset)
    }

    private var homeMenu: some View {
        Menu {
            homeMenuActions(includesSettings: true)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.9) : .white.opacity(0.9))
                .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
                .background {
                    if usesLightWallpaperContent {
                        Circle().fill(Color.black.opacity(0.04))
                    } else {
                        Circle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                    }
                }
                .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
                .contentShape(Circle())
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
        .accessibilityIdentifier("home.menu")
    }

    @ViewBuilder
    private func homeMenuActions(includesSettings: Bool) -> some View {
        if !showsHomeElement(.search) {
            Button { focusHomeSearch() } label: {
                homeMenuLabel("search", systemImage: "magnifyingglass")
            }
            .accessibilityIdentifier("home.menu.search")
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            Button { openWindow(value: BrowserWindowConfiguration()) } label: {
                Label(FeatureText.text("New window"), systemImage: "rectangle.badge.plus")
            }
            if let id = tabManager.activeTab?.id {
                Button(FeatureText.text("Move tab to new window")) {
                    if let configuration = BrowserWindowTransferService.shared.prepare(from: tabManager, tabID: id) {
                        openWindow(value: configuration)
                    }
                }
            }
        }
        Button {
            librarySection = .bookmarks
        } label: {
            homeMenuLabel("my_favorites", systemImage: "bookmark")
        }

        Button {
            librarySection = .history
        } label: {
            homeMenuLabel("search_history", systemImage: "clock.arrow.circlepath")
        }

        Button {
            librarySection = .downloads
        } label: {
            homeMenuLabel("my_downloads", systemImage: "arrow.down.circle")
        }

        Divider()

        Button {
            refreshHomeWallpaper()
        } label: {
            homeMenuLabel("wallpaper_refresh", systemImage: "sparkles")
        }
        .disabled(isRefreshingWallpaper || wallpaperManager.networkLoading)

        if wallpaperManager.canPreviewCurrentWallpaper {
            Button {
                wallpaperPreview = wallpaperManager.exportPreview()
                HapticsManager.light()
            } label: {
                homeMenuLabel("wallpaper_download", systemImage: "square.and.arrow.down")
            }
            .accessibilityIdentifier("home.wallpaper.download")
        }

        Divider()

        if includesSettings {
            Button {
                showSettings = true
            } label: {
                homeMenuLabel("settings", systemImage: "gearshape")
            }
        }

        Button {
            showExtensionCenter = true
        } label: {
            homeMenuLabel("userscripts", systemImage: "puzzlepiece.extension")
        }
    }

    private func homeMenuLabel(_ key: String, systemImage: String) -> some View {
        Label {
            Text(languageManager.localizedString(key))
        } icon: {
            if let image = UIImage(systemName: systemImage)?.withTintColor(.label, renderingMode: .alwaysOriginal) {
                Image(uiImage: image)
            } else {
                Image(systemName: systemImage).foregroundStyle(.primary)
            }
        }
    }

    private func openHomeTabSwitcher() {
        tabManager.refreshSnapshotsForSwitcher()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showTabOverviewFromHome = true
        }
    }

    private func performHomeToolbarAction(_ action: HomeToolbarAction) {
        HapticsManager.selection()
        switch action {
        case .none, .more: break
        case .refreshWallpaper: refreshHomeWallpaper()
        case .search: focusHomeSearch()
        case .newTab:
            tabManager.openNewTab()
            searchVM.isSearching = true
        case .privateBrowsing: togglePrivateModeFromSearchBar()
        case .shareApp: showAppShareSheet = true
        case .downloads: librarySection = .downloads
        case .files: librarySection = .files
        case .bookmarks: librarySection = .bookmarks
        case .history: librarySection = .history
        case .settings: showSettings = true
        case .platforms: showPlatformManagement = true
        case .extensions: showExtensionCenter = true
        case .newDownload: downloadCreation = DownloadCreationRequest()
        case .scanner: showScanner = true
        case .tabs: openHomeTabSwitcher()
        case .restoreTab:
            guard !tabManager.recentlyClosed.isEmpty else { return }
            tabManager.restoreLastClosedTab()
            searchVM.isSearching = true
        default: homeToolbarDestination = action
        }
    }

    private func refreshHomeWallpaper() {
        guard !isRefreshingWallpaper, !wallpaperManager.networkLoading else { return }
        if wallpaperManager.source == .photo {
            homeToolbarDestination = .wallpaper
            return
        }
        isRefreshingWallpaper = wallpaperManager.source.isRemote
        Task {
            defer { isRefreshingWallpaper = false }
            await wallpaperManager.refreshRandom(appearance: wallpaperAppearance)
        }
    }

    // MARK: - Actions

    @State private var showSwitchToBing = false

    private var homeSearchTransition: AnyTransition {
        guard !reduceMotion, let direction = homeSearchReveal else { return .identity }
        return .offset(x: 0, y: direction == .down ? -22 : 22).combined(with: .opacity)
    }

    private func handleHomeSearchSwipe(_ direction: HomeSearchSwipeDirection, startedAtEdge: Bool) {
        if let revealDirection = homeSearchReveal {
            guard direction != revealDirection else { return }
            withAnimation(homeSearchAnimation) { homeSearchReveal = nil }
        } else if startedAtEdge {
            withAnimation(homeSearchAnimation) { homeSearchReveal = direction }
        }
    }

    private func focusHomeSearch() {
        if showsHomeSearch { postHomeSearchFocus() }
        else { withAnimation(homeSearchAnimation) { homeSearchReveal = .down } }
    }

    private func postHomeSearchFocus() {
        NotificationCenter.default.post(name: .focusHomeSearch, object: tabManager)
    }

    private func performSearch(platform: SearchPlatform? = nil) {
        searchVM.performHomeSearch(
            tabManager: tabManager,
            preferredRegion: homeSearchRegion,
            customGroup: homeSearchGroup,
            platform: platform,
            context: modelContext
        )
    }

    private func togglePrivateModeFromSearchBar() {
        let isEnteringPrivateMode = !searchVM.isIncognito
        searchVM.setPrivateBrowsing(isEnteringPrivateMode, tabManager: tabManager)
        searchVM.clearSearch()
        searchVM.showClipboardPrompt = false
        LiveActivityService.shared.end()
        HapticsManager.light()
        AppAccessibility.announce(
            languageManager.localizedString(
                isEnteringPrivateMode ? "privacy_enter_incognito" : "privacy_exit_incognito"
            )
        )
    }

    private func handleQuickAction(_ action: AppQuickAction) {
        switch action {
        case .scan:
            resetNavigationForExternalEntry()
            searchVM.clearSearch()
            showScanner = true
        case .search:
            searchVM.clearSearch()
            DispatchQueue.main.async {
                focusHomeSearch()
            }
        case .newPrivateTab:
            if !searchVM.setPrivateBrowsing(true, tabManager: tabManager) {
                tabManager.resetTabsForPrivacy()
            }
            searchVM.clearSearch()
            DispatchQueue.main.async {
                focusHomeSearch()
            }
        case .clearCache:
            Task {
                await BrowserCacheService.clear(
                    tabManager: tabManager,
                    historyContext: modelContext
                )
                HapticsManager.success()
                AppAccessibility.announce(
                    LanguageManager.shared.localizedString("cache_cleared")
                )
            }
        case .files, .bookmarks, .downloads, .history:
            resetNavigationForExternalEntry()
            librarySection = action.librarySection
        case .shareApp:
            showAppShareSheet = true
        }
    }
}

private enum HomeSearchSwipeDirection: Equatable { case up, down }

/// Listen to the landing scroll view's pan so links and scrolling retain their normal gestures.
private struct HomeSearchSwipeObserver: UIViewRepresentable {
    let onSwipe: (HomeSearchSwipeDirection, Bool) -> Void

    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) { view.onSwipe = onSwipe }
    static func dismantleUIView(_ view: Marker, coordinator: ()) { view.disconnect() }

    final class Marker: UIView {
        var onSwipe: ((HomeSearchSwipeDirection, Bool) -> Void)?
        private weak var scrollView: UIScrollView?
        private var wasAlwaysBouncing = false
        private var startedAtTop = false
        private var startedAtBottom = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            disconnect()
            guard window != nil else { return }
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            guard let scroll = ancestor as? UIScrollView else { return }
            scrollView = scroll
            wasAlwaysBouncing = scroll.alwaysBounceVertical
            scroll.alwaysBounceVertical = true
            scroll.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        func disconnect() {
            scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(handlePan(_:)))
            scrollView?.alwaysBounceVertical = wasAlwaysBouncing
            scrollView = nil
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let scrollView else { return }
            switch pan.state {
            case .began:
                let top = -scrollView.adjustedContentInset.top
                let bottom = max(top, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
                startedAtTop = scrollView.contentOffset.y <= top + 2
                startedAtBottom = scrollView.contentOffset.y >= bottom - 2
            case .ended:
                let translation = pan.translation(in: nil)
                guard abs(translation.y) >= 48, abs(translation.y) > abs(translation.x) * 1.25 else { return }
                let direction: HomeSearchSwipeDirection = translation.y > 0 ? .down : .up
                onSwipe?(direction, direction == .down ? startedAtTop : startedAtBottom)
            default: break
            }
        }
    }
}

/// Keep the search field's position stable when the first marked letter arrives.
/// Only this small section observes the draft; typing never rebuilds HomeView.
private struct HomeRecentSearches: View {
    @ObservedObject var input: SearchInputState
    let recentSearches: [String]
    let contrast: WallpaperRegionContrast?
    let onTap: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        SearchSuggestionsView(recentSearches: recentSearches, onTap: onTap, onDelete: onDelete, contrast: contrast)
            .opacity(input.text.isEmpty ? 1 : 0)
            .allowsHitTesting(input.text.isEmpty)
            .accessibilityHidden(!input.text.isEmpty)
    }
}

private struct ExtensionStoreRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct HomeActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct HomeSearchPanel: View {
    @ObservedObject var input: SearchInputState
    let searchFrame: CGRect
    let viewportHeight: CGFloat
    let prefersAbove: Bool
    let rowLimit: Int
    let platformPicker: BrowserPlatformPickerContext?
    let onSuggestionSelect: (String) -> Void
    let onSuggestionFill: (String) -> Void
    @State private var dismissedText: String?

    private var showsPanel: Bool {
        guard input.isEditing, !input.edit.isComposing else { return false }
        guard platformPicker != nil else { return !input.suggestions.isEmpty }
        guard input.text != dismissedText else { return false }
        if case .search? = BrowserNavigationResolver.classify(input.text) { return true }
        return false
    }

    var body: some View {
        let gap: CGFloat = 8
        let above = searchFrame.minY - gap
        let below = viewportHeight - searchFrame.maxY - gap
        let minimumHeight = platformPicker == nil ? 44 : BrowserPlatformPanel.inlineChromeHeight + 24
        let opensAbove = prefersAbove ? above >= minimumHeight || above >= below
                                      : below < minimumHeight && above > below
        let availableHeight = opensAbove ? above : below
        return Group {
            if showsPanel, searchFrame.width > 0, searchFrame.minY >= 0,
               searchFrame.maxY <= viewportHeight + 1, availableHeight >= minimumHeight {
                Group {
                    if let platformPicker {
                        BrowserPlatformPanel(context: platformPicker, inlineWidth: searchFrame.width,
                            inlineHeight: availableHeight, inlineRowLimit: rowLimit, onSelect: platformPicker.onSelect,
                            onManage: { platformPicker.onManage?() }, onClose: { dismissedText = input.text })
                            .scrollDismissesKeyboard(.never)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                            .accessibilityIdentifier("home.quick-search.platforms")
                            .preservesKeyboardFocusOnTap()
                    } else {
                        ViewThatFits(in: .vertical) {
                            suggestions.fixedSize(horizontal: false, vertical: true)
                            ScrollView { suggestions }
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home.search.suggestions")
                    }
                }
                .frame(width: searchFrame.width, height: availableHeight, alignment: opensAbove ? .bottom : .top)
                .position(x: searchFrame.midX, y: opensAbove ? above / 2 : viewportHeight - below / 2)
            }
        }
        .onCompatibleChange(of: input.text) { _, _ in dismissedText = nil }
    }

    private var suggestions: some View {
        SearchAutocompleteView(suggestions: input.suggestions, query: input.text,
            onSelect: onSuggestionSelect, onFill: onSuggestionFill)
    }
}

struct HomeSearchBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        if let next = nextValue() { value = next }
    }
}

struct HomeToolbarContentBounds: PreferenceKey {
    static var defaultValue: [Anchor<CGRect>] { [] }

    static func reduce(value: inout [Anchor<CGRect>], nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

enum HomeLandingSpacing {
    static let toolbarSideInset: CGFloat = 16
    static let contentInset: CGFloat = 28
    static let bottomToolbarTopInset: CGFloat = 8
    static let bottomToolbarLift: CGFloat = 10
    static let searchAboveToolbarInset: CGFloat = 4
    static let toolbarSafeInset: CGFloat = 12
    static let recentSearchInset: CGFloat = 12
    static let bookmarkSpacing: CGFloat = 16
    static let bookmarkIconSize: CGFloat = 24

    static func toolbarSafeAreaExtension(_ safeArea: CGFloat) -> CGFloat {
        max(0, safeArea - toolbarSafeInset)
    }

    static func detailsGap(for sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        sizeClass == .compact ? 12 : 16
    }

    static func headingGap(for sizeClass: UserInterfaceSizeClass?, showsSubtitle: Bool) -> CGFloat {
        if showsSubtitle { return sizeClass == .compact ? 12 : 24 }
        return sizeClass == .compact ? 8 : 12
    }
}

struct HomeBookmarkTile<Icon: View>: View {
    let title: String
    let lightWallpaper: Bool
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            icon()
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(lightWallpaper ? Color(hex: "2E2A47").opacity(0.7) : .white.opacity(0.6))
                .lineLimit(1)
                .frame(width: 38, alignment: .leading)
        }
    }
}

/// Anchor the field itself, so branding and the number of rows below it cannot
/// move the search target. Short windows still get a scrollable content height.
struct SearchLandingLayout: Layout {
    var viewportHeight: CGFloat
    var headingGap: CGFloat
    var detailsGap: CGFloat
    var searchOffsetRatio: CGFloat = 0
    var searchAtBottom = false
    var centeredDetailsBottomInset: CGFloat?
    var alignsSearchAtTop = false

    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (width: CGFloat, sizes: [CGSize], tops: [CGFloat], height: CGFloat) {
        let width = proposal.width ?? 656
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let preferredCenter = viewportHeight / 2 + sizes[1].height * searchOffsetRatio
        let maxCenter = centeredDetailsBottomInset.map { inset in
            sizes[2].height > 0 ? viewportHeight - inset - detailsGap - sizes[2].height - sizes[1].height / 2 : preferredCenter
        } ?? preferredCenter
        let minimumCenter = sizes[0].height + headingGap + sizes[1].height / 2
        let center = alignsSearchAtTop ? minimumCenter : max(min(preferredCenter, maxCenter), minimumCenter)
        let headingTop = center - sizes[1].height / 2 - headingGap - sizes[0].height
        if searchAtBottom {
            let detailsHeight = sizes[2].height
            let belowHeading = detailsHeight > 0 ? detailsHeight + detailsGap : 0
            let searchTop = max(viewportHeight - sizes[1].height, sizes[0].height + headingGap + belowHeading)
            let detailsTop = searchTop - belowHeading
            let top = min(headingTop, detailsTop - headingGap - sizes[0].height)
            return (width, sizes, [top, searchTop, detailsTop], searchTop + sizes[1].height)
        }
        let detailsTop = center + sizes[1].height / 2 + detailsGap
        return (width, sizes, [headingTop, center - sizes[1].height / 2, detailsTop], max(viewportHeight, detailsTop + sizes[2].height))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = metrics(proposal, subviews)
        return CGSize(width: layout.width, height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = metrics(ProposedViewSize(width: bounds.width, height: nil), subviews)
        for i in subviews.indices {
            subviews[i].place(at: CGPoint(x: bounds.midX, y: bounds.minY + layout.tops[i]), anchor: .top,
                proposal: ProposedViewSize(width: layout.width, height: layout.sizes[i].height))
        }
    }
}
