import SwiftUI
import SwiftData
import StoreKit

struct HomeView: View {
    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var platformStore = PlatformDataStore.shared
    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @StateObject private var speechService = SpeechRecognitionService()
    @Environment(\.modelContext) private var modelContext
    @Environment(\.requestReview) private var requestReview
    @Environment(\.scenePhase) private var scenePhase
    @State private var keyboardVisible = false
    @State private var reviewTask: Task<Void, Never>?
    @Namespace private var searchBarNamespace

    @State private var showSettings = false
    @State private var showExtensionCenter = false
    @State private var librarySection: LibrarySection?
    @State private var showVoiceInput = false
    @State private var showAppShareSheet = false
    @State private var showTabOverviewFromHome = false
    @State private var showTitleEditor = false
    @State private var showSubtitleEditor = false
    @State private var editingTitle = ""
    @State private var editingSubtitle = ""
    @State private var wallpaperLoadTask: Task<Void, Never>?
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = ""
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @AppStorage("show_recent_searches_on_home") private var showRecentSearchesOnHome: Bool = true
    @Query(sort: \BookmarkItem.dateAdded, order: .reverse) private var bookmarks: [BookmarkItem]
    @State private var dynamicTheme: DynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight

    private var displayedHomeTitle: String {
        homeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedHomeSubtitle: String {
        homeSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            homeSurface
                .toolbar(.hidden, for: .navigationBar)
                .mediaPlayerNavigation()
        }
        .overlay { MediaMiniPlayer() }
    }

    private var homeSurface: some View {
        ZStack {
            // Keep the wallpaper outside every content transition and tab-card
            // transform. Scaling the wallpaper with the page exposes the hosting
            // controller's default background around the safe-area edges.
            WallpaperBackground()
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
                        .transition(.opacity)
                }

                // Clipboard prompt
                if searchVM.showClipboardPrompt {
                    ClipboardPromptView()
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(100)
                }

                // Saved toast
                if showSavedToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(LanguageManager.shared.localizedString("wallpaper_saved"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 80)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
                    .accessibilityElement(children: .combine)
                    .onAppear {
                        AppAccessibility.announce(
                            LanguageManager.shared.localizedString("wallpaper_saved")
                        )
                    }
                }
            }
            .tabOverviewScale(isActive: showTabOverviewFromHome)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showTabOverviewFromHome)

            if showTabOverviewFromHome {
                TabSwitcherOverlay(
                    tabManager: tabManager,
                    onSelectTab: { index in
                        tabManager.switchToTab(at: index)
                        searchVM.isSearching = true
                    },
                    onNewTab: {
                        tabManager.createTab()
                        searchVM.isSearching = true
                    },
                    onDismiss: {
                        showTabOverviewFromHome = false
                    }
                )
            }
        }
        .background {
            // A non-white first frame while an image/Canvas wallpaper is being
            // decoded or the app is returning from a sheet/background state.
            Color(red: 0.05, green: 0.07, blue: 0.16)
                .ignoresSafeArea()
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showExtensionCenter) {
            NavigationStack {
                ExtensionCenterView(onOpenInBrowser: { url in
                    tabManager.activeWebViewModel?.loadURL(url)
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
        .navigationDestination(item: $librarySection) { section in
            LibraryView(initialSection: section, searchVM: searchVM)
        }
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
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showSubtitleEditor) {
            TextField(languageManager.localizedString("app_subtitle"), text: $editingSubtitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeSubtitle = editingSubtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .onAppear {
            ReviewPromptPolicy.recordUse()
            editingTitle = homeTitle
            editingSubtitle = homeSubtitle
            searchVM.loadRecentSearches(context: modelContext)
            wallpaperLoadTask?.cancel()
            wallpaperLoadTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
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
        .onChange(of: searchVM.isSearching) { _, isSearching in
            reviewTask?.cancel()
            if !isSearching {
                searchVM.loadRecentSearches(context: modelContext)
                reviewTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, !searchVM.isSearching, !keyboardVisible, scenePhase == .active,
                          !showSettings, !showExtensionCenter, librarySection == nil,
                          !showVoiceInput, !showAppShareSheet, !showTabOverviewFromHome,
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
    }

    // MARK: - Home Content

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isIPad: Bool { horizontalSizeClass == .regular }

    private var homeContent: some View {
        VStack(spacing: 0) {
            // Top controls (FocusLock-style mini buttons)
            topBar
                .padding(.top, 8)

            Spacer()
            Spacer()

            // Center: App name + Search
            VStack(spacing: 24) {
                if !displayedHomeTitle.isEmpty || !displayedHomeSubtitle.isEmpty {
                    VStack(spacing: 6) {
                        if !displayedHomeTitle.isEmpty {
                            Text(displayedHomeTitle)
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47") : .white)
                                .shadow(color: wallpaperManager.isCurrentWallpaperLight ? .black.opacity(0.05) : .black.opacity(0.2), radius: 4, x: 0, y: 2)
                                .onTapGesture { showTitleEditor = true }
                                .accessibilityLabel(
                                    AppAccessibility.formatted("accessibility_home_title", displayedHomeTitle)
                                )
                                .accessibilityHint(
                                    languageManager.localizedString("accessibility_edit_title_hint")
                                )
                                .accessibilityAddTraits([.isHeader, .isButton])
                                .accessibilityAction { showTitleEditor = true }
                        }

                        if !displayedHomeSubtitle.isEmpty {
                            Text(displayedHomeSubtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.6) : .white.opacity(0.4))
                                .tracking(1.5)
                                .onTapGesture { showSubtitleEditor = true }
                                .accessibilityLabel(
                                    AppAccessibility.formatted(
                                        "accessibility_home_subtitle",
                                        displayedHomeSubtitle
                                    )
                                )
                                .accessibilityHint(
                                    languageManager.localizedString("accessibility_edit_subtitle_hint")
                                )
                                .accessibilityAddTraits(.isButton)
                                .accessibilityAction { showSubtitleEditor = true }
                        }
                    }
                }

                // Search bar
                SearchBarView(
                    text: $searchVM.searchText,
                    isIncognito: searchVM.isIncognito,
                    isRecording: speechService.isRecording,
                    onSubmit: { performSearch() },
                    onMicTap: { showVoiceInput = true },
                    onIncognitoTap: { togglePrivateModeFromSearchBar() }
                )
                .matchedGeometryEffect(id: "searchBar", in: searchBarNamespace)
                .frame(maxWidth: isIPad ? 600 : .infinity)
                .padding(.horizontal, 28)

                // Floating autocomplete — zero-height anchor, overlay extends downward
                Color.clear
                    .frame(height: 0)
                    .overlay(alignment: .top) {
                        if !searchVM.suggestions.isEmpty {
                            SearchAutocompleteView(
                                suggestions: searchVM.suggestions,
                                query: searchVM.searchText,
                                darkVariant: true,
                                onSelect: { suggestion in
                                    searchVM.searchText = suggestion
                                    performSearch()
                                },
                                onFill: { suggestion in
                                    searchVM.searchText = suggestion
                                }
                            )
                            .frame(maxWidth: isIPad ? 600 : .infinity)
                            .padding(.horizontal, 28)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .zIndex(100)
                    .allowsHitTesting(!searchVM.suggestions.isEmpty)

                // Group picker
                if showGroupPickerOnHome {
                    homeGroupPicker
                        .padding(.top, 4)
                }

                // Bookmark icons
                if showBookmarksOnHome && !bookmarks.isEmpty {
                    homeBookmarksRow
                        .padding(.top, 4)
                }

                // Recent searches (hidden while typing, shown when empty)
                if showRecentSearchesOnHome
                    && !searchVM.recentSearches.isEmpty
                    && searchVM.searchText.isEmpty {
                    SearchSuggestionsView(
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
                    .padding(.top, 4)
                }
            }

            Spacer()
            Spacer()

            // Keep the footer informational only so search remains the single focal point.
            Text(wallpaperManager.source == .bing ? "Bing Daily" : wallpaperManager.searchTopic)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.28) : .white.opacity(0.16))
                .lineLimit(1)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Top Bar

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
                                    ? (wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47") : .white)
                                    : (wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.55) : .white.opacity(0.5))
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.12) : .white.opacity(0.2))
                                    : Capsule().fill(wallpaperManager.isCurrentWallpaperLight ? Color.black.opacity(0.04) : .white.opacity(0.06))
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
                                    ? (wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47") : .white)
                                    : (wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.55) : .white.opacity(0.5))
                            )
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.12) : .white.opacity(0.2))
                                    : Capsule().fill(wallpaperManager.isCurrentWallpaperLight ? Color.black.opacity(0.04) : .white.opacity(0.06))
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
            .frame(maxWidth: isIPad ? 600 : .infinity)
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
                                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.7) : .white.opacity(0.6))
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
                }
            }
            .frame(maxWidth: isIPad ? 600 : .infinity)
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
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    tabManager.refreshSnapshotsForSwitcher()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showTabOverviewFromHome = true
                    }
                } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.6), lineWidth: 1.2)
                                .frame(width: 16, height: 16)
                            Text("\(tabManager.tabCount)")
                                .font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.8) : .white.opacity(0.7))
                        }
                        Text(LanguageManager.shared.localizedString("tab_tabs"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.6) : .white.opacity(0.4))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        if wallpaperManager.isCurrentWallpaperLight {
                            Capsule().fill(Color.black.opacity(0.04))
                        } else {
                            Capsule().fill(.ultraThinMaterial.opacity(0.3))
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
            }

            Spacer()

            homeMenu
        }
        .padding(.horizontal, 16)
    }

    private var homeMenu: some View {
        Menu {
            Button {
                librarySection = .history
            } label: {
                Label(LanguageManager.shared.localizedString("search_history"), systemImage: "clock.arrow.circlepath")
            }

            Button {
                librarySection = .bookmarks
            } label: {
                Label(LanguageManager.shared.localizedString("my_favorites"), systemImage: "bookmark")
            }

            Button {
                librarySection = .downloads
            } label: {
                Label(LanguageManager.shared.localizedString("my_downloads"), systemImage: "arrow.down.circle")
            }

            Divider()

            Button {
                Task { await wallpaperManager.refreshRandom() }
            } label: {
                Label(LanguageManager.shared.localizedString("wallpaper_refresh"), systemImage: "sparkles")
            }

            if wallpaperManager.currentImage != nil || wallpaperManager.customImage != nil {
                Button {
                    saveWallpaperToPhotos()
                } label: {
                    Label(LanguageManager.shared.localizedString("wallpaper_download"), systemImage: "square.and.arrow.down")
                }
            }

            Divider()

            Button {
                showSettings = true
            } label: {
                Label(LanguageManager.shared.localizedString("settings"), systemImage: "gearshape")
            }

            Button {
                showExtensionCenter = true
            } label: {
                Label(LanguageManager.shared.localizedString("userscripts"), systemImage: "puzzlepiece.extension")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                .foregroundStyle(wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47").opacity(0.78) : .white.opacity(0.68))
                .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
                .background {
                    if wallpaperManager.isCurrentWallpaperLight {
                        Circle().fill(Color.black.opacity(0.04))
                    } else {
                        Circle().fill(.ultraThinMaterial.opacity(0.3))
                    }
                }
                .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
                .contentShape(Circle())
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
    }

    // MARK: - Actions

    @State private var showSavedToast = false
    @State private var showSwitchToBing = false

    private func saveWallpaperToPhotos() {
        if let image = wallpaperManager.currentImage {
            wallpaperManager.saveToAlbum(image: image)
        } else if let image = wallpaperManager.customImage {
            wallpaperManager.saveToAlbum(image: image)
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showSavedToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { showSavedToast = false }
        }
    }

    private func performSearch() {
        guard !searchVM.searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        let selectedGroup = lastGroupID.isEmpty
            ? nil
            : platformStore.customGroups.first { $0.id.uuidString == lastGroupID }
        let selectedRegion = PlatformRegion(rawValue: lastRegion)
        searchVM.prepareForHomeSearch(
            preferredRegion: selectedRegion,
            customGroup: selectedGroup
        )
        searchVM.performSearch(context: modelContext)
    }

    private func togglePrivateModeFromSearchBar() {
        let isEnteringPrivateMode = !searchVM.isIncognito
        searchVM.isIncognito = isEnteringPrivateMode
        tabManager.resetTabsForPrivacy()
        searchVM.clearSearch()
        searchVM.showClipboardPrompt = false
        LiveActivityService.shared.end()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        AppAccessibility.announce(
            languageManager.localizedString(
                isEnteringPrivateMode ? "privacy_enter_incognito" : "privacy_exit_incognito"
            )
        )
    }

    private func handleQuickAction(_ action: AppQuickAction) {
        switch action {
        case .search:
            searchVM.clearSearch()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .focusHomeSearch, object: nil)
            }
        case .newPrivateTab:
            searchVM.isIncognito = true
            tabManager.resetTabsForPrivacy()
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
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                AppAccessibility.announce(
                    LanguageManager.shared.localizedString("cache_cleared")
                )
            }
        case .shareApp:
            showAppShareSheet = true
        }
    }
}

private struct HomeActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
