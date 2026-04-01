import SwiftUI
import SwiftData

struct SearchResultsView: View {
    var searchBarNamespace: Namespace.ID
    var speechService: SpeechRecognitionService

    @EnvironmentObject var searchVM: SearchViewModel
    @EnvironmentObject var languageManager: LanguageManager
    @EnvironmentObject var wallpaperVM: BingWallpaperService
    @StateObject private var webVM = WebViewModel()
    @StateObject private var bookmarkVM = BookmarkViewModel()
    @Environment(\.modelContext) private var modelContext

    @State private var showBookmarkToast = false
    @State private var isFullscreen: Bool = false
    @State private var showVoiceInput = false
    @State private var pageReady = false

    // Persist last selected group
    @AppStorage("last_selected_region") private var lastRegion: String = ""
    @AppStorage("last_selected_group_id") private var lastGroupID: String = ""

    @State private var selectedCustomGroup: CustomGroup? = nil

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                if !isFullscreen {
                    topSearchBar
                        .padding(.horizontal, 10)
                        .padding(.top, 4)
                        .padding(.bottom, 2)

                    if !searchVM.currentKeyword.isValidURL {
                        if !searchVM.recommendedPlatforms.isEmpty {
                            RecommendedPlatformsView(
                                recommendations: searchVM.recommendedPlatforms,
                                selectedPlatform: $searchVM.selectedPlatform
                            )
                        }

                        PlatformTabBar(
                            platforms: currentPlatforms,
                            selectedPlatform: $searchVM.selectedPlatform
                        )
                        .onChange(of: searchVM.selectedPlatform) { _, _ in
                            loadCurrentPlatformURL()
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

                // WebView — extend into bottom safe area via extra padding
                ZStack {
                    WebViewContainer(
                        webViewModel: webVM,
                        bookmarkViewModel: bookmarkVM,
                        isFullscreen: $isFullscreen
                    )

                    // Loading — thin overlay spinner at top, WebView visible underneath
                    if !pageReady {
                        VStack {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Color(hex: "7C3AED"))
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
                    }

                    // WebView error overlay
                    if let error = webVM.errorMessage, !error.isEmpty, !webVM.isLoading {
                        VStack(spacing: 16) {
                            Image(systemName: "wifi.exclamationmark")
                                .font(.system(size: 36))
                                .foregroundStyle(.secondary)
                            Text(error)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Button {
                                webVM.reload()
                            } label: {
                                Text(languageManager.localizedString("retry"))
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 24)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: "6366F1"), in: Capsule())
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(UIColor.systemBackground))
                    }

                    // AI loading overlay
                    if showAILoading {
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

                                Text(aiLoadingText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 28)
                            .padding(.vertical, 24)
                            .background(.ultraThinMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 6)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: showAILoading)
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
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                // Extend WebView into the bottom safe area
                .padding(.bottom, -geo.safeAreaInsets.bottom)
            }
        }
        .background(
            Group {
                if pageReady {
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
                } else {
                    Color(UIColor.systemBackground)
                }
            }
            .ignoresSafeArea()
        )
        .ignoresSafeArea(isFullscreen ? .container : [], edges: .top)
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
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation(.easeOut(duration: 0.3)) { showLoginAlert = false }
                    }
                }
            }
        }
        .onChange(of: webVM.isScrollingUp) { _, scrollingUp in
            isFullscreen = scrollingUp
        }
        .onChange(of: webVM.isLoading) { _, loading in
            if !loading && !pageReady {
                pageReady = true
            }
        }
        .onAppear {
            // Restore last selected group and select first platform
            if !lastGroupID.isEmpty,
               let group = PlatformDataStore.shared.customGroups.first(where: { $0.id.uuidString == lastGroupID }) {
                selectedCustomGroup = group
                let platforms = PlatformDataStore.shared.platformsForGroup(group)
                if let first = platforms.first {
                    searchVM.selectedPlatform = first
                }
            } else if !lastRegion.isEmpty, let region = PlatformRegion(rawValue: lastRegion) {
                searchVM.selectRegion(region)
            }
            // else: uses SearchViewModel.defaultRegion (auto-detected)
            loadCurrentPlatformURL()
        }
    }

    // MARK: - Top Search Bar

    private var topSearchBar: some View {
        HStack(spacing: 8) {
            // Back button
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    searchVM.clearSearch()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(UIColor.label))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }

            // Search bar
            SearchBarView(
                text: $searchVM.searchText,
                isCompact: true,
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

            // Region + custom group picker
            Menu {
                // Built-in regions (only with visible platforms)
                ForEach(PlatformRegion.sortedCases(preferring: searchVM.selectedRegion).filter { !PlatformDataStore.shared.visiblePlatforms(for: $0).isEmpty }) { region in
                    let count = PlatformDataStore.shared.visiblePlatforms(for: region).count
                    Button {
                        selectedCustomGroup = nil
                        lastGroupID = ""
                        lastRegion = region.rawValue
                        searchVM.selectRegion(region)
                        loadCurrentPlatformURL()
                    } label: {
                        HStack {
                            Text("\(PlatformDataStore.shared.regionDisplayName(for: region)) (\(count))")
                            if selectedCustomGroup == nil && searchVM.selectedRegion == region {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                // Custom groups (only with platforms)
                ForEach(PlatformDataStore.shared.customGroups.filter { !PlatformDataStore.shared.platformsForGroup($0).isEmpty }) { group in
                    let count = PlatformDataStore.shared.platformsForGroup(group).count
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
            } label: {
                Image(systemName: selectedCustomGroup != nil ? "folder.fill" : "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(UIColor.label))
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
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
    }

    // Computed: platforms for current selection (region or custom group)
    private var currentPlatforms: [SearchPlatform] {
        if let group = selectedCustomGroup {
            return PlatformDataStore.shared.platformsForGroup(group)
        }
        return PlatformDataStore.shared.visiblePlatforms(for: searchVM.selectedRegion)
    }

    // MARK: - Actions

    @State private var showLoginAlert = false
    @State private var showAILoading = false
    @State private var aiLoadingText = ""

    private func loadCurrentPlatformURL() {
        guard let platform = searchVM.selectedPlatform else { return }
        let keyword = searchVM.currentKeyword

        // Check if the keyword is a direct URL
        if keyword.isValidURL, let url = keyword.asURL {
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

    private func toggleBookmark() {
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
