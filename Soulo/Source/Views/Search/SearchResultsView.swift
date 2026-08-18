import SwiftUI
import SwiftData
import WebKit

enum PersistentFullscreenBehavior {
    static func shouldEnter(
        enabled: Bool,
        hasSearch: Bool,
        voiceOverEnabled: Bool
    ) -> Bool {
        enabled && hasSearch && !voiceOverEnabled
    }
}

struct SearchResultsView: View {
    var searchBarNamespace: Namespace.ID
    var speechService: SpeechRecognitionService
    var onOpenSettings: (() -> Void)? = nil

    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var platformStore = PlatformDataStore.shared
    @StateObject private var bookmarkVM = BookmarkViewModel()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    @State private var showBookmarkToast = false
    @State private var isFullscreen: Bool = false
    @State private var showVoiceInput = false
    @State private var showPlatformManagement = false
    @State private var pageReady = false
    /// Incremented each time performSearch runs; compared to detect new vs. returning
    @State private var lastSearchID: UUID = UUID()

    // Persist last selected group
    @AppStorage("last_selected_region") private var lastRegion: String = ""
    @AppStorage("last_selected_group_id") private var lastGroupID: String = ""
    @AppStorage("show_top_search_bar") private var showTopSearchBar = true
    @AppStorage(AppConstants.StorageKeys.keepFullscreenBrowsing) private var keepFullscreenBrowsing = false
    @AppStorage(AppConstants.StorageKeys.shakeAction) private var shakeAction = BrowserShakeAction.none.rawValue
    @AppStorage(AppConstants.StorageKeys.browserToolbarHidden) private var toolbarManuallyHidden = false

    @State private var selectedCustomGroup: CustomGroup? = nil

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !isFullscreen {
                    if showTopSearchBar {
                        topSearchBar
                            .padding(.horizontal, 10)
                            .padding(.top, 4)
                            .padding(.bottom, 2)

                        // Floating autocomplete — zero-height container with overlay extending below
                        Color.clear
                            .frame(height: 0)
                            .overlay(alignment: .top) {
                                if !searchVM.suggestions.isEmpty {
                                    SearchAutocompleteView(
                                        suggestions: searchVM.suggestions,
                                        query: searchVM.searchText,
                                        darkVariant: false,
                                        onSelect: { suggestion in
                                            searchVM.searchText = suggestion
                                            searchVM.performSearch(context: modelContext)
                                            loadCurrentPlatformURL()
                                        },
                                        onFill: { suggestion in
                                            searchVM.searchText = suggestion
                                        }
                                    )
                                    .padding(.horizontal, 10)
                                    .padding(.top, 4)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .zIndex(100)
                            .allowsHitTesting(!searchVM.suggestions.isEmpty)
                    }

                    // Tab bar — show when multiple tabs
                    if tabManager.tabs.count > 1 {
                        BrowserTabBar(tabManager: tabManager) {
                            tabManager.createTab()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if !searchVM.currentKeyword.isValidURL {
                        HStack(spacing: 2) {
                            PlatformTabBar(
                                platforms: currentPlatforms,
                                selectedPlatform: $searchVM.selectedPlatform,
                                usesContrastingControlSurface: !showTopSearchBar
                            )
                            .frame(maxWidth: .infinity)
                            .onChange(of: searchVM.selectedPlatform) { _, _ in
                                loadCurrentPlatformURL()
                            }

                            Rectangle()
                                .fill(Color(UIColor.separator).opacity(0.35))
                                .frame(width: 0.5, height: 18)

                            groupPickerMenu
                                .padding(.trailing, 6)
                        }
                    }

                    if let suggestion = searchVM.spellSuggestion {
                        SpellSuggestionBanner(
                            suggestion: suggestion,
                            onTap: {
                                searchVM.searchText = suggestion
                                searchVM.spellSuggestion = nil
                                searchVM.performSearch(context: modelContext)
                                loadCurrentPlatformURL()
                            },
                            onDismiss: { searchVM.spellSuggestion = nil }
                        )
                    }

                    if let translated = searchVM.translatedKeyword,
                       let targetLang = searchVM.translationTargetLanguage {
                        CrossLanguageBanner(
                            translatedKeyword: translated,
                            targetLanguage: targetLang,
                            onTap: {
                                searchVM.searchText = translated
                                searchVM.translatedKeyword = nil
                                searchVM.translationTargetLanguage = nil
                                searchVM.performSearch(context: modelContext)
                                loadCurrentPlatformURL()
                            }
                        )
                    }
                }

                // WebView — mount only the active tab; WebViewModel keeps the WKWebView alive for instant restores.
                ZStack {
                    let activeWebViewModel = tabManager.activeWebViewModel
                    let activeProgress = activeWebViewModel?.estimatedProgress ?? 0
                    let activePageIsLoading = activeWebViewModel?.isLoading == true
                        && activeWebViewModel?.currentURL != nil
                        && activeProgress < 0.98
                    let activePageIsRendered = pageReady || activeProgress >= 0.98
                    let shouldShowLoadingOverlay = activeWebViewModel?.currentURL != nil
                        && (activePageIsLoading || !activePageIsRendered)

                    if let activeTab = tabManager.activeTab {
                        WebViewContainer(
                            webViewModel: activeTab.webViewModel,
                            bookmarkViewModel: bookmarkVM,
                            isFullscreen: $isFullscreen,
                            tabManager: tabManager,
                            toolbarManuallyHiddenBinding: $toolbarManuallyHidden,
                            isActiveTab: true,
                            addressEditorText: searchVM.searchText.isEmpty
                                ? searchVM.currentKeyword
                                : searchVM.searchText,
                            onGoHome: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                                    isFullscreen = false
                                    searchVM.clearSearch()
                                }
                            },
                            onAddressSearch: { value in
                                searchVM.searchText = value
                                searchVM.performSearch(context: modelContext)
                                loadCurrentPlatformURL()
                            },
                            onRequestVoiceSearch: {
                                showVoiceInput = true
                            },
                            onOpenSettings: onOpenSettings,
                            onAccessibilityPlatformPage: { direction in
                                switchPlatformForAccessibility(direction)
                            },
                            onPageStarted: {
                                if pageReady { pageReady = false }
                            },
                            onPageLoaded: {
                                if !pageReady { pageReady = true }
                                recordCurrentPageVisit(from: activeTab.webViewModel)
                            },
                            topSafeAreaInset: geo.safeAreaInsets.top,
                            bottomSafeAreaInset: geo.safeAreaInsets.bottom
                        )
                        .id(activeTab.id)
                        .transition(.opacity)
                    }

                    // Loading — thin overlay spinner at top, WebView visible underneath
                    if shouldShowLoadingOverlay {
                        loadingOverlay
                    }

                    // AI loading overlay
                    if showAILoading {
                        aiLoadingOverlay
                    }

                    // Bookmark toast
                    if showBookmarkToast {
                        VStack {
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(Color(hex: "7C3AED"))
                                Text(languageManager.localizedString("bookmark_added"))
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            .glassCard(cornerRadius: 12)
                            .padding(.bottom, 80)
                        }
                        .frame(maxWidth: .infinity)
                        .allowsHitTesting(false)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .accessibilityHidden(true)
                        .onAppear {
                            AppAccessibility.announce(
                                languageManager.localizedString("bookmark_added")
                            )
                        }
                    }
                }
                // Extend WebView into the bottom safe area.
                .padding(.bottom, -geo.safeAreaInsets.bottom)
            }
        }
        .background(
            Group {
                if isShowingNewTabPage {
                    // Keep the new-tab wallpaper continuous behind the top
                    // platform controls instead of starting below them.
                    Color.clear
                } else {
                    // The browser chrome background belongs to the navigation
                    // state, not the document render state. Show it as soon as
                    // a URL starts loading so the top safe area never flashes
                    // the opaque system background while WebKit is rendering.
                    VStack(spacing: 0) {
                        LinearGradient(
                            colors: [
                                Color(hex: "4F46E5").opacity(0.08),
                                Color(hex: "7C3AED").opacity(0.04),
                                Color(UIColor.systemBackground)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 160)

                        Color(UIColor.systemBackground)

                        LinearGradient(
                            colors: [
                                Color(UIColor.systemBackground),
                                Color(hex: "7C3AED").opacity(0.04),
                                Color(hex: "4F46E5").opacity(0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 100)
                    }
                }
            }
            .ignoresSafeArea()
        )
        .ignoresSafeArea(isFullscreen ? .container : [], edges: .all)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .tabOverviewScale(isActive: tabManager.showTabOverview)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: tabManager.showTabOverview)
        .overlay(alignment: .top) {
            if showLoginAlert {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 16))
                        .foregroundStyle(.orange)
                    Text(LanguageManager.shared.localizedString("login_required_toast"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .onAppear {
                    AppAccessibility.announce(
                        LanguageManager.shared.localizedString("login_required_toast")
                    )
                    let delay: TimeInterval = voiceOverEnabled ? 8 : 3
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        withAnimation(.easeOut(duration: 0.3)) { showLoginAlert = false }
                    }
                }
            }
        }
        .overlay {
            if tabManager.showTabOverview {
                TabSwitcherOverlay(
                    tabManager: tabManager,
                    onSelectTab: { index in
                        tabManager.switchToTab(at: index)
                    },
                    onNewTab: {
                        tabManager.createTab()
                    },
                    onDismiss: {
                        tabManager.showTabOverview = false
                    }
                )
            }
        }
        .onChange(of: tabManager.activeTabIndex) { _, _ in
            if let vm = tabManager.activeWebViewModel {
                pageReady = vm.estimatedProgress >= 0.98 || (!vm.isLoading && vm.currentURL != nil)
            }
        }
        // Handle "open in new tab" from WebView (target="_blank" links)
        .onReceive(NotificationCenter.default.publisher(for: .openInNewTab)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                tabManager.createTab(url: url, keyword: searchVM.currentKeyword, platform: searchVM.selectedPlatform)
            }
        }
        .alert(
            languageManager.localizedString("tab_limit_title"),
            isPresented: $tabManager.didReachTabLimit
        ) {
            Button(languageManager.localizedString("confirm"), role: .cancel) {}
        } message: {
            Text(languageManager.localizedString("tab_limit_message"))
        }
        .sheet(isPresented: $showVoiceInput) {
            VoiceInputView(
                speechService: speechService,
                onConfirm: { text in
                    searchVM.searchText = text
                    showVoiceInput = false
                    searchVM.performSearch(context: modelContext)
                    loadCurrentPlatformURL()
                },
                onDismiss: { showVoiceInput = false }
            )
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
        .onAppear {
            if PersistentFullscreenBehavior.shouldEnter(
                enabled: keepFullscreenBrowsing,
                hasSearch: !searchVM.currentKeyword.isEmpty,
                voiceOverEnabled: voiceOverEnabled
            ) {
                isFullscreen = true
            }

            // Restore last selected group and select first platform
            if !lastGroupID.isEmpty,
               let group = platformStore.customGroups.first(where: { $0.id.uuidString == lastGroupID }) {
                selectedCustomGroup = group
                let platforms = platformStore.platformsForGroup(group)
                if let first = platforms.first {
                    searchVM.selectedPlatform = first
                }
            } else if !lastRegion.isEmpty, let region = PlatformRegion(rawValue: lastRegion) {
                searchVM.selectRegion(region)
            }

            if searchVM.searchID != lastSearchID && !searchVM.currentKeyword.isEmpty {
                // New search or bookmark click — load in active tab
                lastSearchID = searchVM.searchID
                loadCurrentPlatformURL()
            } else if tabManager.activeWebViewModel?.currentURL == nil {
                // Empty tab with no content — try loading
                if !searchVM.currentKeyword.isEmpty {
                    loadCurrentPlatformURL()
                }
            }
            // Otherwise: returning to existing tabs, keep as-is
        }
        .onChange(of: keepFullscreenBrowsing) { _, enabled in
            guard PersistentFullscreenBehavior.shouldEnter(
                enabled: enabled,
                hasSearch: !searchVM.currentKeyword.isEmpty,
                voiceOverEnabled: voiceOverEnabled
            ) else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isFullscreen = true
            }
        }
        .onChange(of: platformStore.platforms) { _, _ in
            synchronizeSelectedPlatformAfterStoreChange()
        }
        .background {
            DeviceShakeDetector(
                isEnabled: BrowserShakeAction(rawValue: shakeAction) != BrowserShakeAction.none
            ) {
                handleShakeAction()
            }
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Top Search Bar

    private var loadingOverlay: some View {
        VStack {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.primary.opacity(0.62))
                Text(languageManager.localizedString("loading"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 16)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 12)
            Spacer()
        }
        .transition(.opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            AppAccessibility.announce(languageManager.localizedString("loading"))
        }
    }

    private var aiLoadingOverlay: some View {
        ZStack {
            VStack(spacing: 16) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolEffect(.pulse.wholeSymbol, options: .repeating)
                    .accessibilityHidden(true)

                Text(aiLoadingText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(
                .ultraThinMaterial.opacity(0.8),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            AppAccessibility.announce(aiLoadingText)
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showAILoading)
    }

    private var topSearchBar: some View {
        SearchBarView(
            text: $searchVM.searchText,
            isCompact: true,
            isIncognito: searchVM.isIncognito,
            isRecording: speechService.isRecording,
            onSubmit: {
                searchVM.performSearch(context: modelContext)
                loadCurrentPlatformURL()
            },
            onMicTap: {
                showVoiceInput = true
            }
        )
        .matchedGeometryEffect(id: "searchBar", in: searchBarNamespace)
    }

    private var groupPickerMenu: some View {
        Menu {
            ForEach(PlatformRegion.sortedCases(preferring: searchVM.selectedRegion).filter { !platformStore.visiblePlatforms(for: $0).isEmpty }) { region in
                let count = platformStore.visiblePlatforms(for: region).count
                Button {
                    selectedCustomGroup = nil
                    lastGroupID = ""
                    lastRegion = region.rawValue
                    searchVM.selectRegion(region)
                    loadCurrentPlatformURL()
                } label: {
                    HStack {
                        Text("\(platformStore.regionDisplayName(for: region)) (\(count))")
                        if selectedCustomGroup == nil && searchVM.selectedRegion == region {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            ForEach(platformStore.customGroups.filter { !platformStore.platformsForGroup($0).isEmpty }) { group in
                let count = platformStore.platformsForGroup(group).count
                Button {
                    selectedCustomGroup = group
                    lastGroupID = group.id.uuidString
                    lastRegion = ""
                    loadCurrentPlatformURL()
                } label: {
                    HStack {
                        Text("\(group.name) (\(count))")
                        if selectedCustomGroup?.id == group.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Button {
                showPlatformManagement = true
            } label: {
                Label(
                    languageManager.localizedString("platform_management"),
                    systemImage: "slider.horizontal.3"
                )
            }
        } label: {
            Image(systemName: selectedCustomGroup != nil ? "folder.fill" : "square.stack.3d.up.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    showTopSearchBar
                        ? Color.primary.opacity(0.58)
                        : Color(uiColor: .systemGray).opacity(0.88)
                )
                .frame(width: 32, height: 32)
                .background {
                    if showTopSearchBar {
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 26)
                    }
                }
                .frame(width: 40, height: 36)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("select_region"))
        .accessibilityValue(
            selectedCustomGroup?.name
                ?? platformStore.regionDisplayName(for: searchVM.selectedRegion)
        )
        .accessibilityHint(languageManager.localizedString("accessibility_group_picker_hint"))
    }

    // Computed: platforms for current selection (region or custom group)
    private var currentPlatforms: [SearchPlatform] {
        if let group = selectedCustomGroup {
            return platformStore.platformsForGroup(group)
        }
        return platformStore.visiblePlatforms(for: searchVM.selectedRegion)
    }

    private func synchronizeSelectedPlatformAfterStoreChange() {
        let availablePlatforms = currentPlatforms
        guard !availablePlatforms.isEmpty else {
            searchVM.selectedPlatform = nil
            return
        }
        guard let selectedID = searchVM.selectedPlatform?.id,
              availablePlatforms.contains(where: { $0.id == selectedID }) else {
            searchVM.selectedPlatform = availablePlatforms[0]
            return
        }
    }

    @discardableResult
    private func switchPlatformForAccessibility(
        _ direction: AccessibilityPlatformPagingDirection
    ) -> Bool {
        let platforms = currentPlatforms
        guard !platforms.isEmpty else { return false }

        let currentIndex = searchVM.selectedPlatform
            .flatMap { selected in platforms.firstIndex(where: { $0.id == selected.id }) }
            ?? 0
        guard let targetIndex = PlatformAccessibilityNavigation.adjacentIndex(
            currentIndex: currentIndex,
            count: platforms.count,
            direction: direction
        ) else {
            let key = direction == .next
                ? "accessibility_last_platform"
                : "accessibility_first_platform"
            AppAccessibility.announce(languageManager.localizedString(key))
            return true
        }

        let target = platforms[targetIndex]
        searchVM.selectedPlatform = target
        AppAccessibility.announce(
            AppAccessibility.formatted(
                "accessibility_platform_loading",
                languageManager.localizedString(target.name),
                targetIndex + 1,
                platforms.count
            )
        )
        return true
    }

    private var isShowingNewTabPage: Bool {
        guard let viewModel = tabManager.activeWebViewModel else { return false }
        return viewModel.currentURL == nil && !viewModel.isLoading
    }

    // MARK: - Actions

    @State private var showLoginAlert = false
    @State private var didShowXiaohongshuLoginHint = false
    @State private var showAILoading = false
    @State private var aiLoadingText = ""

    private func loadCurrentPlatformURL() {
        guard let webVM = tabManager.activeWebViewModel else { return }
        guard let platform = searchVM.selectedPlatform else { return }
        let keyword = searchVM.currentKeyword
        let directURL = keyword.isValidURL ? keyword.asURL : nil

        // Apply the platform's required content mode before starting navigation,
        // so the very first request already carries the correct user agent.
        let requiresDesktopMode = directURL.map {
            WebCompatibilityService.requiresDesktopMode(for: $0)
        } ?? platform.requiresDesktopMode
        tabManager.setDesktopModeEnabled(requiresDesktopMode, reload: false)

        let isXiaohongshu = platform.name == "platform_xiaohongshu"
            || WebCompatibilityService.requiresDesktopMode(for: directURL)
        if isXiaohongshu {
            showXiaohongshuLoginHintIfNeeded(
                for: platform,
                using: webVM
            )
        }

        // Update active tab metadata
        if let index = tabManager.tabs.firstIndex(where: { $0.id == tabManager.activeTab?.id }) {
            tabManager.tabs[index].keyword = keyword
            tabManager.tabs[index].platform = platform
        }

        // Check if the keyword is a direct URL
        if let url = directURL {
            webVM.loadURL(url)
            return
        }

        switch platform.interactionType {
        case .aiChat:
            if let url = URL(string: platform.homeURL) {
                // Show AI loading indicator
                withAnimation { showAILoading = true }
                aiLoadingText = LanguageManager.shared.localizedString("ai_loading_page")
                webVM.loadURL(url)

                // Poll until page finishes loading or timeout (10s max)
                func waitForPageLoad(attempt: Int = 0) {
                    // Timeout after 20 attempts * 0.5s = 10 seconds
                    if attempt > 20 {
                        withAnimation { showAILoading = false }
                        return
                    }
                    // Page loaded (skip first attempt to allow loading to start)
                    if !webVM.isLoading && attempt > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            let checkJS = AIPlatformInteractionService.loginDetectionScript(for: platform.name)
                            webVM.webView?.evaluateJavaScript(checkJS) { result, _ in
                                Task { @MainActor in
                                    if let status = result as? String, status == "needs_login" {
                                        withAnimation { showAILoading = false }
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            showLoginAlert = true
                                        }
                                    } else {
                                        aiLoadingText = LanguageManager.shared.localizedString("ai_loading_input")
                                        AIPlatformInteractionService.interact(
                                            webView: webVM.webView,
                                            platform: platform,
                                            keyword: keyword
                                        )
                                        // Hide loading after injection completes
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                                            withAnimation { showAILoading = false }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Still loading, check again in 0.5s
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            waitForPageLoad(attempt: attempt + 1)
                        }
                    }
                }
                waitForPageLoad()
            }
        case .urlSearch:
            if let url = platform.searchURL(for: keyword) {
                webVM.loadURL(url)
            }
        }
    }

    private func handleShakeAction() {
        guard let action = BrowserShakeAction(rawValue: shakeAction), action != .none else { return }
        var didPerformAction = true

        switch action {
        case .none:
            break
        case .fullscreen:
            if isFullscreen && keepFullscreenBrowsing {
                keepFullscreenBrowsing = false
            }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                isFullscreen.toggle()
            }
        case .darkMode:
            WebAppearanceService.shared.toggleForceDarkPages()
            if let webView = tabManager.activeWebViewModel?.webView {
                WebAppearanceService.shared.apply(to: webView)
            }
        case .reload:
            if let viewModel = tabManager.activeWebViewModel,
               viewModel.currentURL != nil {
                // A shake always means refresh, even if the previous navigation is still loading.
                viewModel.retryCurrentPage()
            } else {
                didPerformAction = false
            }
        case .closeTab:
            tabManager.closeTab(at: tabManager.activeTabIndex)
        }

        if didPerformAction {
            HapticsManager.success()
        }
    }

    private func recordCurrentPageVisit(from webViewModel: WebViewModel) {
        guard !searchVM.isIncognito,
              let url = webViewModel.currentURL
        else { return }

        SearchHistoryService.recordWebVisit(
            url: url,
            title: webViewModel.pageTitle,
            context: modelContext
        )
    }

    private func showXiaohongshuLoginHintIfNeeded(
        for platform: SearchPlatform,
        using webViewModel: WebViewModel
    ) {
        guard !didShowXiaohongshuLoginHint else { return }
        didShowXiaohongshuLoginHint = true

        let cookieStore = webViewModel.webView?.configuration.websiteDataStore.httpCookieStore
            ?? WKWebsiteDataStore.default().httpCookieStore
        let platformID = platform.id

        cookieStore.getAllCookies { cookies in
            Task { @MainActor in
                guard searchVM.selectedPlatform?.id == platformID else { return }
                guard !WebCompatibilityService.hasAuthenticatedXiaohongshuSession(in: cookies) else {
                    return
                }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showLoginAlert = true
                }
            }
        }
    }

    private func toggleBookmark() {
        guard let webVM = tabManager.activeWebViewModel else { return }
        guard let url = webVM.currentURL?.absoluteString else { return }
        let title = webVM.pageTitle.isEmpty ? url : webVM.pageTitle
        let platformName = searchVM.selectedPlatform.map { languageManager.localizedString($0.name) }

        let isAdded = BookmarkService.toggleBookmark(
            title: title,
            url: url,
            platformName: platformName,
            context: modelContext
        )

        if isAdded {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showBookmarkToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { showBookmarkToast = false }
            }
        }

        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
