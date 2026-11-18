import SwiftUI
import CoreData
import StoreKit

struct HomeView: View {
    @Environment(\.colorScheme) private var homeColorScheme
    @AppStorage("appearance") private var appAppearance = "system"
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
    @StateObject private var keyboardContext = BrowserKeyboardContext()
    @State private var reviewTask: Task<Void, Never>?
    @Namespace private var searchBarNamespace

    @State private var showSettings = false
    @State private var showExtensionCenter = false
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
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("show_recent_searches_on_home") private var showRecentSearchesOnHome: Bool = true
    @FetchRequest(sortDescriptors: BookmarkService.sortDescriptors) private var bookmarks: FetchedResults<BookmarkRecord>
    @State private var dynamicTheme: DynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight

    private var displayedHomeTitle: String {
        homeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedHomeSubtitle: String {
        homeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
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
        .focusedSceneValue(\.souloBrowserKeyboardActions,
            BrowserKeyboardActions(enabled: keyboardCommandsEnabled,
                canPerform: { keyboardContext.canPerform },
                focus: {
                    if searchVM.isSearching, let model = tabManager.activeWebViewModel {
                        NotificationCenter.default.post(name: .focusSouloBrowserAddress, object: model)
                    } else { NotificationCenter.default.post(name: .focusHomeSearch, object: tabManager) }
                },
                newTab: { tabManager.createTab(); searchVM.isSearching = true },
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
                appearanceOverride: wallpaperAppearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            Group {
                if searchVM.isSearching {
                    SearchResultsView(
                        searchBarNamespace: searchBarNamespace,
                        speechService: speechService,
                        onOpenSettings: { showSettings = true }
                    )
                    .transition(.identity)
                } else {
                    homeContent
                        .environment(\.colorScheme, wallpaperAppearance == .dark ? .dark : .light)
                        .transition(.opacity)
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
        showAppShareSheet = false
        wallpaperPreview = nil
        if recreateStack { navigationSession = UUID() }
    }

    // MARK: - Home Content

    private var homeContent: some View {
        VStack(spacing: 0) {
            topBar.padding(.top, 8)
            GeometryReader { viewport in
                homeContent(width: viewport.size.width)
                    .overlay {
                        if showsHomeToolbar(.free) {
                            freeHomeToolbar
                                // Leave room for the home indicator without reserving the full safe area.
                                .padding(.bottom, min(viewport.safeAreaInsets.bottom, 16))
                                .ignoresSafeArea(.container, edges: .bottom)
                        }
                    }
            }
        }
        .buttonStyle(HomePressButtonStyle())
    }

    private var freeHomeToolbar: some View {
        GeometryReader { geometry in
            let sideMargin: CGFloat = 16
            let metrics = homeToolbarMetrics(width: max(0, geometry.size.width - 2 * sideMargin), height: geometry.size.height)
            let center = homeToolbar.layout.center(in: metrics.area, strip: metrics.size)
            liveHomeToolbar(metrics: metrics)
                .position(x: center.x + sideMargin, y: center.y)
        }
    }

    private func homeContent(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Keep the search field mounted while the window changes size.
            // Center when there is room, scroll when folding or the keyboard
            // reduces the available height.
            GeometryReader { geometry in
                ScrollView {
                    SearchLandingLayout(viewportHeight: max(0, geometry.size.height - 32),
                        headingGap: displayedHomeSubtitle.isEmpty ? (verticalSizeClass == .compact ? 8 : 12) : (verticalSizeClass == .compact ? 12 : 24),
                        detailsGap: verticalSizeClass == .compact ? 12 : 16, searchOffsetRatio: -0.5) {
                        homeHeading.padding(.horizontal, 24)
                        VStack(spacing: 12) {
                            homeSearchField
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("home.search.field")
                                .zIndex(1)
                            if showsHomeToolbar(.belowSearch) {
                                homeToolbarStrip(width: max(0, min(geometry.size.width - 32, 526)))
                            }
                        }
                        .zIndex(1)
                        homeSearchDetails
                    }
                    .frame(maxWidth: 656)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("home.search.area")
            }
            if showsHomeToolbar(.bottom) {
                homeToolbarStrip(width: min(526, max(0, width - 32)))
                    .frame(maxWidth: .infinity, alignment: homeToolbar.layout.alignment.frameAlignment)
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 20)
            }
        }
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
                    } else {
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
                    } else {
                        Text(" ")
                            .font(.system(size: 13, weight: .medium))
                            .hidden().accessibilityHidden(true)
                    }
                }

        }
    }

    private var homeSearchField: some View {
            SearchBarView(
                input: searchVM.input,
                isIncognito: searchVM.isIncognito,
                isRecording: speechService.isRecording,
                onSubmit: { performSearch() },
                onMicTap: { showVoiceInput = true },
                onIncognitoTap: { togglePrivateModeFromSearchBar() },
                onScanTap: { showScanner = true },
                selectedRegion: PlatformRegion(rawValue: lastRegion) ?? searchVM.selectedRegion,
                selectedGroupID: UUID(uuidString: lastGroupID),
                onRegionSelect: { region in
                    lastRegion = region.rawValue
                    lastGroupID = ""
                    searchVM.selectRegion(region)
                },
                onGroupSelect: { group in
                    lastGroupID = group.id.uuidString
                    lastRegion = ""
                    searchVM.prepareForHomeSearch(preferredRegion: nil, customGroup: group)
                },
                onPlatformManagementTap: { showPlatformManagement = true }
            )
            .matchedGeometryEffect(id: "searchBar", in: searchBarNamespace)
            .frame(maxWidth: 600)
            .padding(.horizontal, 28)

            .overlay(alignment: .bottom) {
                SearchAutocompleteOverlay(input: searchVM.input, darkVariant: true,
                maximumWidth: 600, horizontalPadding: 28, topPadding: 8,
                onSelect: { suggestion in
                    searchVM.searchText = suggestion
                    performSearch()
                }, onFill: { searchVM.searchText = $0 })
            }
    }

    private var homeSearchDetails: some View {
        VStack(spacing: verticalSizeClass == .compact ? 12 : 16) {
            // Group picker
            if showGroupPickerOnHome {
                homeGroupPicker
            }

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
                .padding(.top, 12)
            }
        }
    }


    // MARK: - Top Bar

    private var homeToolbarIndices: [Int] { homeToolbar.actions.indices.filter { homeToolbar.actions[$0] != .none } }

    private func showsHomeToolbar(_ placement: HomeToolbarLayout.Placement) -> Bool {
        homeToolbar.isVisible && !keyboardVisible && homeToolbar.layout.placement == placement
    }

    private func homeToolbarMetrics(width: CGFloat, height: CGFloat = 0) -> HomeToolbarMetrics {
        HomeToolbarMetrics(width: width, height: height, count: homeToolbarIndices.count, style: homeToolbar.layout.style)
    }

    private func homeToolbarStrip(width: CGFloat) -> some View { liveHomeToolbar(metrics: homeToolbarMetrics(width: width)) }

    private func liveHomeToolbar(metrics: HomeToolbarMetrics) -> some View {
        HomeToolbarStrip(indices: homeToolbarIndices, metrics: metrics, style: homeToolbar.layout.style,
            lightWallpaper: usesLightWallpaperContent) { homeToolbarButton($0) }
    }

    private func homeToolbarButton(_ index: Int) -> some View {
        let action = homeToolbar.actions[index]
        return Button { performHomeToolbarAction(action) } label: {
            HomeToolbarButtonFace(action: action, lightWallpaper: usesLightWallpaperContent,
                isActive: action == .privateBrowsing && searchVM.isIncognito,
                isLoading: action == .refreshWallpaper && wallpaperManager.networkLoading,
                tabCount: tabManager.tabCount)
        }
        .buttonStyle(HomeToolbarButtonStyle(lightWallpaper: usesLightWallpaperContent, showsBackground: homeToolbar.layout.style == .tiles))
        .accessibilityLabel(action.title)
        .accessibilityIdentifier("home.toolbar.\(index)")
        .accessibilityAddTraits(action == .privateBrowsing && searchVM.isIncognito ? .isSelected : [])
        .disabled(action == .refreshWallpaper && wallpaperManager.networkLoading)
        .contextMenu {
            Button { homeToolbarDestination = .homeToolbar } label: {
                Label(ToolText.text("home_toolbar_customize"), systemImage: "slider.horizontal.3")
            }
        }
    }

    // MARK: - Home Group Picker

    @AppStorage("last_selected_region") private var lastRegion: String = ""
    @AppStorage("last_selected_group_id") private var lastGroupID: String = ""

    private var homeGroupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PlatformRegion.sortedCases(preferring: searchVM.selectedRegion), id: \.self) { region in
                    let isSelected = lastGroupID.isEmpty && lastRegion == region.rawValue
                    Button {
                        lastRegion = region.rawValue
                        lastGroupID = ""
                    } label: {
                        Text(platformStore.regionDisplayName(for: region))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? (usesLightWallpaperContent ? Color(hex: "2E2A47") : .white)
                                    : (usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.8))
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.12) : .white.opacity(0.2))
                                    : Capsule().fill(usesLightWallpaperContent ? Color.black.opacity(0.04) : .white.opacity(0.06))
                            )
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(
                        isSelected
                            ? languageManager.localizedString("accessibility_selected")
                            : ""
                    )
                }
                ForEach(platformStore.customGroups) { group in
                    let isSelected = lastGroupID == group.id.uuidString
                    Button {
                        lastGroupID = group.id.uuidString
                        lastRegion = ""
                    } label: {
                        Text(group.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? (usesLightWallpaperContent ? Color(hex: "2E2A47") : .white)
                                    : (usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.8))
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.12) : .white.opacity(0.2))
                                    : Capsule().fill(usesLightWallpaperContent ? Color.black.opacity(0.04) : .white.opacity(0.06))
                            )
                    }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityValue(
                        isSelected
                            ? languageManager.localizedString("accessibility_selected")
                            : ""
                    )
                }
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 32)
        }
    }

    // MARK: - Home Bookmarks Row

    private var homeBookmarksRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(bookmarks.prefix(10)) { bookmark in
                    Button {
                        searchVM.searchText = bookmark.urlString
                        performSearch()
                    } label: {
                        VStack(spacing: 6) {
                            BookmarkFaviconView(urlString: bookmark.urlString, size: 24)
                            Text(bookmark.title)
                                .font(.system(size: 9))
                                .foregroundStyle(usesLightWallpaperContent ? Color(hex: "2E2A47").opacity(0.7) : .white.opacity(0.6))
                                .lineLimit(1)
                                .frame(width: 38)
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
            .frame(maxWidth: 600)
            .padding(.horizontal, 32)
        }
    }

    /// Show the tab switcher whenever there is anything worth restoring or previewing.
    private var shouldShowTabEntry: Bool {
        tabManager.tabs.count > 1 || tabManager.tabs.contains {
            $0.webViewModel.currentURL != nil || $0.webViewModel.snapshot != nil
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // Existing tabs and the tab switcher remain available in private mode.
            // Privacy changes what is persisted, not which browser controls are shown.
            if shouldShowTabEntry || searchVM.isIncognito {
                Button {
                    HapticsManager.light()
                    tabManager.refreshSnapshotsForSwitcher()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showTabOverviewFromHome = true
                    }
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

            homeMenu
        }
        .padding(.horizontal, 16)
    }

    private var homeMenu: some View {
        Menu {
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
                Task { await wallpaperManager.refreshRandom() }
            } label: {
                homeMenuLabel("wallpaper_refresh", systemImage: "sparkles")
            }

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

            Button {
                showSettings = true
            } label: {
                homeMenuLabel("settings", systemImage: "gearshape")
            }

            Button {
                showExtensionCenter = true
            } label: {
                homeMenuLabel("userscripts", systemImage: "puzzlepiece.extension")
            }
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

    private func performHomeToolbarAction(_ action: HomeToolbarAction) {
        HapticsManager.selection()
        switch action {
        case .none: break
        case .refreshWallpaper: Task { await wallpaperManager.refreshRandom() }
        case .search: NotificationCenter.default.post(name: .focusHomeSearch, object: nil)
        case .newTab:
            tabManager.createTab()
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
        case .tabs: showTabOverviewFromHome = true
        default: homeToolbarDestination = action
        }
    }

    // MARK: - Actions

    @State private var showSwitchToBing = false

    private func performSearch() {
        let selectedGroup = lastGroupID.isEmpty
            ? nil
            : platformStore.customGroups.first { $0.id.uuidString == lastGroupID }
        let selectedRegion = PlatformRegion(rawValue: lastRegion)
        searchVM.performHomeSearch(
            tabManager: tabManager,
            preferredRegion: selectedRegion,
            customGroup: selectedGroup,
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
                NotificationCenter.default.post(name: .focusHomeSearch, object: nil)
            }
        case .newPrivateTab:
            if !searchVM.setPrivateBrowsing(true, tabManager: tabManager) {
                tabManager.resetTabsForPrivacy()
            }
            searchVM.clearSearch()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .focusHomeSearch, object: nil)
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

/// Keep the search field's position stable when the first marked letter arrives.
/// Only this small section observes the draft; typing never rebuilds HomeView.
private struct HomeRecentSearches: View {
    @ObservedObject var input: SearchInputState
    let recentSearches: [String]
    let onTap: (String) -> Void
    let onDelete: (String) -> Void

    var body: some View {
        SearchSuggestionsView(recentSearches: recentSearches, onTap: onTap, onDelete: onDelete)
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

/// Anchor the field itself, so branding and the number of rows below it cannot
/// move the search target. Short windows still get a scrollable content height.
struct SearchLandingLayout: Layout {
    var viewportHeight: CGFloat
    var headingGap: CGFloat
    var detailsGap: CGFloat
    var searchOffsetRatio: CGFloat = 0

    private func metrics(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (CGFloat, [CGSize], CGFloat) {
        let width = proposal.width ?? 656
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
        let center = max(viewportHeight / 2 + sizes[1].height * searchOffsetRatio, sizes[0].height + headingGap + sizes[1].height / 2)
        return (width, sizes, center)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let (width, sizes, center) = metrics(proposal, subviews)
        return CGSize(width: width, height: max(viewportHeight, center + sizes[1].height / 2 + detailsGap + sizes[2].height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (width, sizes, center) = metrics(ProposedViewSize(width: bounds.width, height: nil), subviews)
        let y = bounds.minY + center
        let tops = [y - sizes[1].height / 2 - headingGap - sizes[0].height,
                    y - sizes[1].height / 2, y + sizes[1].height / 2 + detailsGap]
        for i in subviews.indices {
            subviews[i].place(at: CGPoint(x: bounds.midX, y: tops[i]), anchor: .top,
                proposal: ProposedViewSize(width: width, height: sizes[i].height))
        }
    }
}
