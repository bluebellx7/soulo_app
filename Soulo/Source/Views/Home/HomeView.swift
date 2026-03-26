import SwiftUI
import SwiftData

struct HomeView: View {
    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var wallpaperVM: BingWallpaperService
    @StateObject private var speechService = SpeechRecognitionService()
    @Environment(\.modelContext) private var modelContext
    @Namespace private var searchBarNamespace

    @State private var showSettings = false
    @State private var showHistory = false
    @State private var showBookmarks = false
    @State private var showVoiceInput = false
    @State private var showTitleEditor = false
    @State private var showSubtitleEditor = false
    @State private var editingTitle = ""
    @State private var editingSubtitle = ""
    @AppStorage("home_title") private var homeTitle: String = "Soulo"
    @AppStorage("home_subtitle") private var homeSubtitle: String = ""
    @AppStorage("show_bookmarks_on_home") private var showBookmarksOnHome: Bool = false
    @AppStorage("show_group_picker_on_home") private var showGroupPickerOnHome: Bool = false
    @Query(sort: \BookmarkItem.dateAdded, order: .reverse) private var bookmarks: [BookmarkItem]
    @State private var dynamicTheme: DynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight

    var body: some View {
        ZStack {
            // Background
            backgroundLayer

            if searchVM.isSearching {
                SearchResultsView(
                    searchBarNamespace: searchBarNamespace,
                    speechService: speechService
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
            }
        }
        .onTapGesture {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showHistory) {
            SearchHistoryView(searchVM: searchVM)
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(searchVM: searchVM)
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
        .alert(LanguageManager.shared.localizedString("edit_title"), isPresented: $showTitleEditor) {
            TextField("Soulo", text: $editingTitle)
            Button(LanguageManager.shared.localizedString("save")) {
                let trimmed = editingTitle.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { homeTitle = trimmed }
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .alert(LanguageManager.shared.localizedString("edit_subtitle"), isPresented: $showSubtitleEditor) {
            TextField(languageManager.localizedString("app_subtitle"), text: $editingSubtitle)
            Button(LanguageManager.shared.localizedString("save")) {
                homeSubtitle = editingSubtitle
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .alert(LanguageManager.shared.localizedString("switch_to_bing"), isPresented: $showSwitchToBing) {
            Button(LanguageManager.shared.localizedString("confirm")) {
                wallpaperVM.setMode(.bing)
                Task { await wallpaperVM.fetchWallpapers() }
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        } message: {
            Text(LanguageManager.shared.localizedString("switch_to_bing_desc"))
        }
        .onAppear {
            editingTitle = homeTitle
            editingSubtitle = homeSubtitle
            searchVM.loadRecentSearches(context: modelContext)
            Task { await wallpaperVM.fetchWallpapers() }
        }
        .onChange(of: searchVM.isSearching) { _, isSearching in
            if !isSearching {
                searchVM.loadRecentSearches(context: modelContext)
            }
        }
        .onChange(of: wallpaperVM.mode) { _, _ in
            // Refresh dynamic theme when wallpaper mode changes
            dynamicTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let newTheme = DynamicTheme(rawValue: UserDefaults.standard.string(forKey: "dynamic_theme") ?? "midnight") ?? .midnight
            if newTheme != dynamicTheme {
                dynamicTheme = newTheme
            }
        }
    }

    // MARK: - Background (FocusLock style: wallpaper + dark gradient overlay)

    @ViewBuilder
    private var backgroundLayer: some View {
        ZStack {
            // Base dark color (FocusLock's deep navy)
            Color(red: 12/255, green: 10/255, blue: 32/255)
                .ignoresSafeArea()

            // Wallpaper image (clipped to prevent layout overflow)
            GeometryReader { geo in
                wallpaperImage
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            .ignoresSafeArea()
            .transition(.opacity.animation(.easeInOut(duration: 1.2)))

            // FocusLock-style overlay: dark edges, lighter center
            LinearGradient(
                colors: [
                    .black.opacity(0.50),
                    .black.opacity(0.15),
                    .black.opacity(0.50)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var wallpaperImage: some View {
        switch wallpaperVM.mode {
        case .bing, .custom:
            if let image = wallpaperVM.currentImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        case .none:
            AnimatedMeshBackground(theme: dynamicTheme)
        }
    }

    // MARK: - Home Content

    private var homeContent: some View {
        VStack(spacing: 0) {
            // Top controls (FocusLock-style mini buttons)
            topBar
                .padding(.top, 8)

            Spacer()
            Spacer()

            // Center: App name + Search
            VStack(spacing: 24) {
                // App name only
                VStack(spacing: 6) {
                    Text(homeTitle)
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
                        .onTapGesture { showTitleEditor = true }

                    Text(homeSubtitle.isEmpty ? languageManager.localizedString("app_subtitle") : homeSubtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .tracking(1.5)
                        .onTapGesture { showSubtitleEditor = true }
                }

                // Search bar (glass material style)
                SearchBarView(
                    text: $searchVM.searchText,
                    isRecording: speechService.isRecording,
                    onSubmit: { performSearch() },
                    onMicTap: { showVoiceInput = true },
                )
                .matchedGeometryEffect(id: "searchBar", in: searchBarNamespace)
                .padding(.horizontal, 28)

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

                // Recent searches
                if !searchVM.recentSearches.isEmpty {
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

            // Bottom bar: pinwheel left, credit center, download right
            HStack {
                // Pinwheel button - tap to switch wallpaper
                PinwheelButton {
                    if wallpaperVM.mode == .bing {
                        wallpaperVM.applyWallpaper()
                    } else {
                        showSwitchToBing = true
                    }
                }

                Spacer()

                // Wallpaper credit
                if wallpaperVM.mode == .bing, let wp = wallpaperVM.currentWallpaper {
                    Text(wp.copyright)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.15))
                        .lineLimit(1)
                }

                Spacer()

                // Download wallpaper button
                if wallpaperVM.currentImage != nil {
                    Button {
                        saveWallpaperToPhotos()
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }
    }

    // MARK: - Top Bar (FocusLock-style: small frosted glass buttons)

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
                        Text(PlatformDataStore.shared.regionDisplayName(for: region))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(.white.opacity(0.2))
                                    : Capsule().fill(.white.opacity(0.06))
                            )
                    }
                }
                ForEach(PlatformDataStore.shared.customGroups) { group in
                    let isSelected = lastGroupID == group.id.uuidString
                    Button {
                        lastGroupID = group.id.uuidString
                        lastRegion = ""
                    } label: {
                        Text(group.name)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.5))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected
                                    ? Capsule().fill(.white.opacity(0.2))
                                    : Capsule().fill(.white.opacity(0.06))
                            )
                    }
                }
            }
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
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                                .frame(width: 38)
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // Incognito indicator
            if searchVM.isIncognito {
                miniButton(icon: "eye.slash.fill", opacity: 0.5)
            }

            Spacer()

            miniButton(icon: "clock.arrow.circlepath") {
                showHistory = true
            }
            miniButton(icon: "bookmark") {
                showBookmarks = true
            }
            miniButton(icon: "gearshape") {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
    }

    // FocusLock-style mini button: ultraThinMaterial, 0.3 opacity, small circle
    private func miniButton(icon: String, opacity: Double = 0.3, action: (() -> Void)? = nil) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action?()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(opacity))
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial.opacity(0.3), in: Circle())
        }
    }

    // MARK: - Actions

    @State private var showSavedToast = false
    @State private var showSwitchToBing = false

    private func saveWallpaperToPhotos() {
        guard let image = wallpaperVM.currentImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
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
        searchVM.performSearch(context: modelContext)
    }
}
