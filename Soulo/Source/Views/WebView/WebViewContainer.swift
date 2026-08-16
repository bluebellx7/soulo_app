import SwiftUI
import SwiftData
import SafariServices

enum BrowserChromeLayout {
    static let controlHeight: CGFloat = 40
    static let bottomSpacing: CGFloat = 16
    static let pageContentClearance: CGFloat = 8

    static func showsBottomToolbar(isActiveTab: Bool, isFullscreen: Bool) -> Bool {
        isActiveTab && !isFullscreen
    }

    static func bottomToolbarHeight(
        isActiveTab: Bool,
        isFullscreen: Bool
    ) -> CGFloat {
        guard showsBottomToolbar(isActiveTab: isActiveTab, isFullscreen: isFullscreen) else {
            return 0
        }
        return controlHeight + bottomSpacing
    }

    static func pageBottomClearance(
        reportedSafeArea: CGFloat,
        windowSafeArea: CGFloat,
        visibleToolbarHeight: CGFloat
    ) -> CGFloat {
        let safeArea = max(max(reportedSafeArea, windowSafeArea), 0)
        let toolbarClearance = max(visibleToolbarHeight, 0) > 0
            ? visibleToolbarHeight + pageContentClearance
            : 0
        return max(safeArea, toolbarClearance)
    }

    static func videoViewportBottomInset(
        isActiveTab: Bool,
        isVideoPage: Bool,
        bottomClearance: CGFloat
    ) -> CGFloat {
        guard isActiveTab, isVideoPage else { return 0 }
        return max(bottomClearance, 0)
    }
}

enum BrowserChromeSymbol {
    /// A browser viewport with its bottom control area highlighted. Using the
    /// same object symbol for both states avoids implying navigation direction.
    static let toolbarVisibility = "rectangle.bottomthird.inset.filled"
}

enum FullscreenExitGesture {
    static func shouldExit(translation: CGSize) -> Bool {
        translation.height >= 28
            && abs(translation.height) > abs(translation.width) * 1.2
    }
}

enum FullscreenHandleRevealGesture {
    static func shouldReveal(translation: CGSize) -> Bool {
        translation.height >= 24
            && abs(translation.height) > abs(translation.width) * 1.2
    }
}

enum FullscreenHandleLayout {
    /// Keep the indicator visually compact while providing a forgiving target.
    static let indicatorSize = CGSize(width: 36, height: 4)
    static let minimumHitSize = CGSize(width: 104, height: 52)
}

struct WebViewContainer: View {
    @ObservedObject var webViewModel: WebViewModel
    @ObservedObject var bookmarkViewModel: BookmarkViewModel
    @Binding var isFullscreen: Bool
    var tabManager: TabManager? = nil
    var isActiveTab: Bool = true
    var addressEditorText: String? = nil
    var onGoHome: (() -> Void)? = nil
    var onAddressSearch: ((String) -> Void)? = nil
    var onRequestVoiceSearch: (() -> Void)? = nil
    var onOpenSettings: (() -> Void)? = nil
    var onAccessibilityPlatformPage: ((AccessibilityPlatformPagingDirection) -> Bool)? = nil
    var onPageStarted: (() -> Void)? = nil
    var onPageLoaded: (() -> Void)? = nil
    var topSafeAreaInset: CGFloat = 0
    var bottomSafeAreaInset: CGFloat = 0
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var searchVM: SearchViewModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(AppConstants.StorageKeys.keepFullscreenBrowsing) private var keepFullscreenBrowsing = false
    @StateObject private var safariCompatibilityPresenter = SafariCompatibilityPresenter()

    @State private var isBookmarked: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    @State private var showExternalConfirm: Bool = false
    @State private var showBookmarkToast: Bool = false
    @State private var showLinkCopiedToast: Bool = false
    @State private var externalURL: URL? = nil
    @State private var externalRequestIsExplicit: Bool = false
    @State private var externalDismissTask: DispatchWorkItem? = nil
    @State private var showNewTabPage: Bool = true
    @State private var toolbarMinimized: Bool = false
    @State private var toolbarManuallyHidden: Bool = false
    @State private var toolbarInteractionLocked: Bool = false
    @State private var showAdBlockManager = false
    @State private var showPrivacyPanel = false
    @State private var librarySection: LibrarySection?
    @State private var showExtensionCenter = false
    @State private var extensionInstallCandidate: BrowserExtensionInstallCandidate?
    @State private var showExternalOpenFailed = false
    @State private var showDownloadFailed = false
    @State private var showAddressEditor = false
    @State private var showFullscreenExitHandle = false
    @State private var showFullscreenExitHint = false
    @State private var showFullscreenMenu = false
    @State private var fullscreenHintDismissTask: Task<Void, Never>?
    @State private var showCaptureOptions = false
    @State private var isCapturingPage = false
    @State private var captureResult: WebPageCaptureResult?
    @State private var captureError: String?
    @State private var showTranslationSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !isFullscreen {
                    // Find in Page bar (only on active tab)
                    if isActiveTab, let tm = tabManager, tm.showFindInPage {
                        FindInPageBar(tabManager: tm)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    WebViewProgressBar(
                        progress: webViewModel.estimatedProgress,
                        isLoading: webViewModel.isLoading
                    )

                    Rectangle()
                        .fill(Color(UIColor.separator).opacity(0.2))
                        .frame(height: 0.5)
                }

                ZStack {
                    WebViewRepresentable(
                        viewModel: webViewModel,
                        onAccessibilityPlatformPage: onAccessibilityPlatformPage
                    )
                        .id(webViewModel.runtimeRevision)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isShowingNewTabPage ? 0 : 1)
                        .allowsHitTesting(!isShowingNewTabPage)

                    if webViewModel.showSnapshotWhileRestoring,
                       let snapshot = webViewModel.snapshot,
                       webViewModel.currentURL != nil {
                        Image(uiImage: snapshot)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }

                    // New Tab Page overlay
                    if isShowingNewTabPage {
                        NewTabPageView(tabManager: tabManager) { url in
                            webViewModel.loadURL(url)
                        }
                        .transition(.opacity)
                    }

                    if let error = webViewModel.errorMessage,
                       !error.isEmpty,
                       !webViewModel.isLoading {
                        BrowserLoadErrorView(
                            message: error,
                            host: webViewModel.currentURL?.host,
                            onRetry: { webViewModel.retryCurrentPage() },
                            onGoHome: onGoHome,
                            onOpenCompatibility: canOpenSafariCompatibility
                                ? { openSafariCompatibilityMode() }
                                : nil
                        )
                        .transition(.opacity)
                    }
                }
                .padding(.bottom, videoViewportBottomInset)
            }

            if videoViewportBottomInset > 0 {
                videoBottomChromeBackdrop
                    .zIndex(40)
            }

            if BrowserChromeLayout.showsBottomToolbar(
                isActiveTab: isActiveTab,
                isFullscreen: isFullscreen
            ) {
                browserToolbarChrome
                    .frame(height: bottomToolbarHeight, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toolbarMinimized)
                    .zIndex(50)
            }

            if isActiveTab && isFullscreen {
                fullscreenHandleRevealArea
                    .zIndex(69)

                if showFullscreenMenu {
                    fullscreenMenuDismissBackdrop
                        .transition(.opacity)
                        .zIndex(69.5)
                }

                if showFullscreenExitHandle {
                    fullscreenExitHandle
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(70)
                }
            }

            // Toast overlays
            if showBookmarkToast {
                toastView(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark.slash",
                    text: LanguageManager.shared.localizedString(isBookmarked ? "bookmark_added" : "bookmark_removed")
                )
            }

            if showLinkCopiedToast {
                toastView(
                    icon: "checkmark",
                    text: LanguageManager.shared.localizedString("link_copied"),
                    iconColor: .green
                )
            }

            if showExternalOpenFailed {
                toastView(
                    icon: "exclamationmark.triangle.fill",
                    text: LanguageManager.shared.localizedString("open_external_failed"),
                    iconColor: .orange
                )
            }

            if showDownloadFailed {
                toastView(
                    icon: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                    text: LanguageManager.shared.localizedString("save_failed"),
                    iconColor: .orange
                )
            }

            // External app confirmation bar
            if showExternalConfirm, let extURL = externalURL {
                VStack {
                    Spacer()
                    VStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LanguageManager.shared.localizedString("open_external_title"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(WebNavigationPolicyService.shared.externalDestinationName(for: extURL))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        HStack(spacing: 10) {
                            Button {
                                withAnimation { showExternalConfirm = false }
                                externalDismissTask?.cancel()
                            } label: {
                                Text(LanguageManager.shared.localizedString("cancel"))
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            Button {
                                withAnimation { showExternalConfirm = false }
                                externalDismissTask?.cancel()
                                UIApplication.shared.open(extURL) { success in
                                    guard !success else { return }
                                    DispatchQueue.main.async {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                            showExternalOpenFailed = true
                                        }
                                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                            withAnimation { showExternalOpenFailed = false }
                                        }
                                    }
                                }
                            } label: {
                                Text(LanguageManager.shared.localizedString("confirm"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                    .padding(14)
                    .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomOverlayClearance)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .onAppear {
                    AppAccessibility.announce(
                        "\(LanguageManager.shared.localizedString("open_external_title")), \(WebNavigationPolicyService.shared.externalDestinationName(for: extURL))"
                    )
                }
            }

            // Download indicator
            if webViewModel.isDownloading {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LanguageManager.shared.localizedString("downloading"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Text(downloadStatusDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, bottomOverlayClearance)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: webViewModel.showSnapshotWhileRestoring)
        .onChange(of: webViewModel.isScrollingUp) { _, scrollingUp in
            if isActiveTab {
                guard !voiceOverEnabled else {
                    toolbarMinimized = false
                    return
                }
                // A visible More menu or tool sheet owns the browser chrome.
                // The first real page scroll after dismissal releases the lock,
                // but must not also compact the toolbar in the same event.
                if toolbarInteractionLocked {
                    toolbarInteractionLocked = false
                    toolbarMinimized = false
                    return
                }
                // Scrolling can compact browser controls, but full screen is an
                // explicit user choice handled by the toolbar action.
                if scrollingUp && !toolbarMinimized && !toolbarManuallyHidden {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        toolbarMinimized = true
                    }
                } else if !scrollingUp && toolbarMinimized && !toolbarManuallyHidden {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        toolbarMinimized = false
                    }
                }
            }
        }
        .onChange(of: voiceOverEnabled) { _, enabled in
            if enabled {
                toolbarMinimized = false
                toolbarManuallyHidden = false
            }
        }
        .onChange(of: isFullscreen) { _, fullscreen in
            updateFullscreenPresentation(isFullscreen: fullscreen)
        }
        .onAppear {
            updateFullscreenPresentation(isFullscreen: isFullscreen)
        }
        .onDisappear {
            fullscreenHintDismissTask?.cancel()
            fullscreenHintDismissTask = nil
        }
        .accessibilityAction(.escape) {
            if isFullscreen {
                exitFullscreen()
            }
        }
        .onChange(of: webViewModel.isLoading) { _, loading in
            if !loading { onPageLoaded?() }
        }
        .onChange(of: webViewModel.estimatedProgress) { _, progress in
            if progress >= 0.98 { onPageLoaded?() }
        }
        .onChange(of: webViewModel.currentURL) { _, url in
            onPageStarted?()
            syncBookmarkState(for: url)
            if url != nil {
                withAnimation(.easeOut(duration: 0.2)) { showNewTabPage = false }
            }
        }
        .onChange(of: videoViewportBottomInset) { _, _ in
            guard WebCompatibilityService.isDouyinVideoSurface(webViewModel.currentURL) else { return }
            DispatchQueue.main.async {
                webViewModel.synchronizePageViewport()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                webViewModel.synchronizePageViewport()
            }
        }
        // Scoped notifications — only process when this is the active tab
        .onReceive(NotificationCenter.default.publisher(for: .webViewExternalURLRequest)) { notification in
            guard isActiveTab else { return }
            if let url = notification.userInfo?["url"] as? URL {
                externalURL = url
                externalRequestIsExplicit = notification.userInfo?["explicitUserAction"] as? Bool ?? false
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showExternalConfirm = true
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                externalDismissTask?.cancel()
                externalDismissTask = nil
                if !externalRequestIsExplicit && !voiceOverEnabled {
                    // Unsolicited app-jump prompts remain lightweight. A prompt
                    // caused by an explicit download waits for the user's choice.
                    externalDismissTask = DispatchWorkItem { [self] in
                        withAnimation { showExternalConfirm = false }
                    }
                    if let task = externalDismissTask {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .linkCopied)) { _ in
            guard isActiveTab else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showLinkCopiedToast = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation { showLinkCopiedToast = false }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserDownloadFailed)) { notification in
            guard isActiveTab,
                  notification.object as AnyObject? === webViewModel else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showDownloadFailed = true
            }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showDownloadFailed = false }
            }
        }
        // Link & image long-press handled by native WKUIDelegate context menus
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showAddressEditor) {
            BrowserAddressEditorSheet(
                initialText: addressEditorText ?? webViewModel.currentURL?.absoluteString ?? "",
                initialURL: webViewModel.currentURL?.absoluteString ?? "",
                onOpen: { value in
                    showAddressEditor = false
                    onAddressSearch?(value)
                },
                onVoiceInput: {
                    showAddressEditor = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        onRequestVoiceSearch?()
                    }
                }
            )
            .presentationDetents([.height(302)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAdBlockManager) {
            NavigationStack {
                AdBlockManagementView(currentHost: webViewModel.currentURL?.host) {
                    webViewModel.reload()
                }
            }
        }
        .sheet(isPresented: $showPrivacyPanel) {
            NavigationStack {
                SitePrivacyPanelView(currentURL: webViewModel.currentURL) {
                    webViewModel.reload()
                }
            }
        }
        .sheet(item: $librarySection) { section in
            LibraryView(
                initialSection: section,
                searchVM: searchVM,
                onOpen: { value in
                    if let onAddressSearch {
                        onAddressSearch(value)
                    } else if value.isValidURL, let url = value.asURL {
                        webViewModel.loadURL(url)
                    }
                }
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showExtensionCenter) {
            NavigationStack {
                ExtensionCenterView(onOpenInBrowser: { url in
                    webViewModel.loadURL(url)
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
        .sheet(item: $extensionInstallCandidate) { candidate in
            BrowserPackageInstallView(candidate: candidate)
                .presentationDetents([.height(430)])
                .presentationDragIndicator(.visible)
        }
        .modifier(
            WebToolsPresentationModifier(
                webViewModel: webViewModel,
                showCaptureOptions: $showCaptureOptions,
                isCapturingPage: isCapturingPage,
                captureResult: $captureResult,
                captureError: $captureError,
                showTranslationSheet: $showTranslationSheet,
                onCapture: capturePage
            )
        )
        .onReceive(NotificationCenter.default.publisher(for: .browserExtensionInstallCandidate)) { notification in
            guard isActiveTab,
                  notification.object as AnyObject? === webViewModel,
                  let candidate = notification.userInfo?["candidate"] as? BrowserExtensionInstallCandidate else {
                return
            }
            extensionInstallCandidate = candidate
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserExtensionsChanged)) { _ in
            // Rebuild every loaded tab. Otherwise an inactive tab would keep
            // the old WKUserScript set when it becomes active later.
            guard webViewModel.currentURL != nil else { return }
            webViewModel.rebuildWebViewRuntime()
        }
    }

    // MARK: - Toast

    private var downloadStatusDetail: String {
        guard webViewModel.activeDownloadCount > 1 else {
            return webViewModel.downloadFileName
        }
        return "\(webViewModel.downloadFileName) · \(webViewModel.activeDownloadCount)"
    }

    private var canOpenSafariCompatibility: Bool {
        WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(
            for: webViewModel.currentURL
        )
    }

    private var isShowingNewTabPage: Bool {
        showNewTabPage && webViewModel.currentURL == nil && !webViewModel.isLoading
    }

    private func setPrivateMode(_ enabled: Bool) {
        guard searchVM.isIncognito != enabled else { return }
        let pageURL = webViewModel.currentURL
        searchVM.isIncognito = enabled

        guard let tabManager else { return }
        tabManager.resetTabsForPrivacy()
        if enabled, let pageURL {
            tabManager.activeWebViewModel?.loadURL(pageURL)
            searchVM.isSearching = true
        } else if !enabled {
            // Never carry a private page or its query into the normal session.
            searchVM.clearSearch()
        }
    }

    private func openSafariCompatibilityMode() {
        guard let url = webViewModel.currentURL,
              WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(for: url) else {
            return
        }
        HapticsManager.selection()
        safariCompatibilityPresenter.present(
            url: url,
            sourceView: webViewModel.webView
        )
    }

    private func openCurrentPageInDefaultBrowser() {
        guard let url = webViewModel.currentURL,
              WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(for: url) else {
            return
        }
        UIApplication.shared.open(url) { success in
            guard !success else { return }
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showExternalOpenFailed = true
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showExternalOpenFailed = false }
                }
            }
        }
    }

    private func toastView(icon: String, text: String, iconColor: Color = .white) -> some View {
        VStack {
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor)
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.bottom, bottomOverlayClearance)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .onAppear {
            AppAccessibility.announce(text)
        }
    }

    // MARK: - Browser Chrome

    private var bottomToolbarHeight: CGFloat {
        BrowserChromeLayout.bottomToolbarHeight(
            isActiveTab: isActiveTab,
            isFullscreen: isFullscreen
        )
    }

    private var bottomOverlayClearance: CGFloat {
        if isFullscreen {
            return max(bottomSafeAreaInset, windowSafeAreaInsets.bottom, 12) + 12
        }
        return bottomToolbarHeight + 12
    }

    private var pageBottomClearance: CGFloat {
        BrowserChromeLayout.pageBottomClearance(
            reportedSafeArea: bottomSafeAreaInset,
            windowSafeArea: windowSafeAreaInsets.bottom,
            visibleToolbarHeight: toolbarManuallyHidden ? 0 : bottomToolbarHeight
        )
    }

    private var videoViewportBottomInset: CGFloat {
        BrowserChromeLayout.videoViewportBottomInset(
            isActiveTab: isActiveTab,
            isVideoPage: WebCompatibilityService.isDouyinVideoSurface(webViewModel.currentURL),
            bottomClearance: pageBottomClearance
        )
    }

    private var videoBottomChromeBackdrop: some View {
        Rectangle()
            .fill(Color.black)
            .frame(maxWidth: .infinity)
            .frame(height: videoViewportBottomInset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow?
            .safeAreaInsets ?? .zero
    }

    private var browserToolbarChrome: some View {
        VStack(spacing: 0) {
            Group {
                if toolbarManuallyHidden {
                    toolbarRestoreButton
                        .transition(.scale(scale: 0.72).combined(with: .opacity))
                } else if toolbarMinimized {
                    miniToolbarPill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                } else {
                    WebViewToolbar(
                        viewModel: webViewModel,
                        isBookmarked: $isBookmarked,
                        tabManager: tabManager,
                        onShare: {
                            if let url = webViewModel.currentURL {
                                shareItems = [url]
                                showShareSheet = true
                            }
                        },
                        onBookmarkToggle: { handleBookmarkToggle() },
                        onShowPrivacy: { showPrivacyPanel = true },
                        onSetPrivateMode: { enabled in
                            setPrivateMode(enabled)
                        },
                        onManageAdBlock: { showAdBlockManager = true },
                        onShowLibrary: { librarySection = .bookmarks },
                        onShowExtensions: { showExtensionCenter = true },
                        onGoHome: onGoHome,
                        onEditAddress: { showAddressEditor = true },
                        onHideToolbar: { hideToolbar() },
                        onOpenSettings: onOpenSettings,
                        isFullscreen: false,
                        onToggleFullscreen: { toggleFullscreen() },
                        onOpenSafariCompatibility: { openSafariCompatibilityMode() },
                        onOpenDefaultBrowser: { openCurrentPageInDefaultBrowser() },
                        onCapturePage: { showCaptureOptions = true },
                        onTranslatePage: { showTranslationSheet = true },
                        onMoreMenuPresentationChange: { isPresented in
                            toolbarInteractionLocked = isPresented
                            if isPresented, toolbarMinimized {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                                    toolbarMinimized = false
                                }
                            }
                        }
                    )
                    .padding(.horizontal, 4)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.8).combined(with: .opacity)
                    ))
                }
            }
            .frame(minHeight: BrowserChromeLayout.controlHeight)
        }
        .padding(.bottom, BrowserChromeLayout.bottomSpacing)
        .frame(maxWidth: .infinity)
    }

    private var toolbarRestoreButton: some View {
        HStack(spacing: 0) {
            Button {
                HapticsManager.light()
                withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                    toolbarManuallyHidden = false
                    toolbarMinimized = false
                }
            } label: {
                Image(systemName: BrowserChromeSymbol.toolbarVisibility)
                    .font(.system(size: 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                    .browserToolbarButtonGlass()
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("restore_browser_toolbar"))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        // Keep the recovery control at the physical left edge so it remains
        // predictable and away from the common right-side video action stack.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func hideToolbar() {
        HapticsManager.selection()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            toolbarMinimized = false
            toolbarManuallyHidden = true
        }
    }

    private var fullscreenExitHandle: some View {
        VStack(spacing: 8) {
            Button {
                toggleFullscreenMenu()
            } label: {
                VStack(spacing: 5) {
                    Capsule()
                        .fill(.white.opacity(showFullscreenExitHint || showFullscreenMenu ? 0.94 : 0.72))
                        .frame(
                            width: FullscreenHandleLayout.indicatorSize.width,
                            height: FullscreenHandleLayout.indicatorSize.height
                        )

                    if showFullscreenExitHint {
                        Text(LanguageManager.shared.localizedString("fullscreen_exit_hint"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .padding(.horizontal, showFullscreenExitHint ? 13 : 10)
                .padding(.vertical, 8)
                .background(
                    .black.opacity(showFullscreenExitHint || showFullscreenMenu ? 0.58 : 0.28),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(.white.opacity(0.13), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.2), radius: 7, y: 3)
                .frame(
                    minWidth: FullscreenHandleLayout.minimumHitSize.width,
                    minHeight: FullscreenHandleLayout.minimumHitSize.height
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if FullscreenExitGesture.shouldExit(translation: value.translation) {
                            exitFullscreen()
                        }
                    }
            )
            .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
            .accessibilityHint(LanguageManager.shared.localizedString("fullscreen_exit_hint"))

            if showFullscreenMenu {
                fullscreenQuickMenu
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .top)
                                .combined(with: .opacity),
                            removal: .scale(scale: 0.97, anchor: .top)
                                .combined(with: .opacity)
                        )
                    )
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Geometry safe-area values can become zero after the parent enters an
        // edge-to-edge presentation. Keep the handle below a notch or Dynamic
        // Island by falling back to the active window's physical safe area.
        .padding(.top, max(topSafeAreaInset, windowSafeAreaInsets.top, 8) + 4)
        .padding(.horizontal, 16)
    }

    private var fullscreenMenuDismissBackdrop: some View {
        Color.black
            .opacity(0.08)
            .contentShape(Rectangle())
            .ignoresSafeArea()
            .onTapGesture {
                closeFullscreenMenu()
            }
            .accessibilityHidden(true)
    }

    private var fullscreenQuickMenu: some View {
        VStack(spacing: 0) {
            fullscreenAddressHeader

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 0.5)

            HStack(spacing: 8) {
                fullscreenPrimaryAction(
                    titleKey: "share",
                    systemImage: "square.and.arrow.up"
                ) {
                    closeFullscreenMenu()
                    if let url = webViewModel.currentURL {
                        shareItems = [url]
                        showShareSheet = true
                    }
                }

                fullscreenPrimaryAction(
                    titleKey: "copy_link",
                    systemImage: "doc.on.doc"
                ) {
                    closeFullscreenMenu()
                    copyCurrentPageLink()
                }

                fullscreenPrimaryAction(
                    titleKey: "bookmarks",
                    systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                    tint: isBookmarked ? .orange : .white
                ) {
                    closeFullscreenMenu()
                    handleBookmarkToggle()
                }
            }
            .padding(10)

            HStack(spacing: 8) {
                fullscreenPrimaryAction(
                    titleKey: "home_screen",
                    systemImage: "house.fill"
                ) {
                    closeFullscreenMenu()
                    onGoHome?()
                }

                fullscreenPrimaryAction(
                    titleKey: "web_capture",
                    systemImage: "camera.viewfinder"
                ) {
                    closeFullscreenMenu()
                    showCaptureOptions = true
                }

                // Page translation is hidden in 1.1.1 and will return after the
                // next round of webpage extraction and language-pack testing.

                fullscreenPrimaryAction(
                    titleKey: "settings",
                    systemImage: "gearshape"
                ) {
                    closeFullscreenMenu()
                    onOpenSettings?()
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            fullscreenContentModePicker
                .padding(10)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            fullscreenZoomControls
                .padding(10)

            Rectangle()
                .fill(.white.opacity(0.1))
                .frame(height: 0.5)
                .padding(.horizontal, 12)

            fullscreenNavigationActions
                .padding(10)
        }
        .frame(maxWidth: 340)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(.black.opacity(0.56))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var fullscreenAddressHeader: some View {
        HStack(spacing: 9) {
            Button {
                closeFullscreenMenu()
                showAddressEditor = true
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(fullscreenDisplayTitle)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)

                        if let address = webViewModel.currentURL?.absoluteString {
                            Text(address)
                                .font(.system(size: 9.5, weight: .regular, design: .rounded))
                                .foregroundStyle(.white.opacity(0.32))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
            .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_address_hint"))

            Button {
                closeFullscreenMenu()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("cancel"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
    }

    private func fullscreenPrimaryAction(
        titleKey: String,
        systemImage: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            HapticsManager.selection()
            action()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(tint.opacity(0.9))
                    .frame(height: 20)

                Text(LanguageManager.shared.localizedString(titleKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(webViewModel.currentURL == nil)
        .opacity(webViewModel.currentURL == nil ? 0.35 : 1)
    }

    private var fullscreenContentModePicker: some View {
        HStack(spacing: 6) {
            fullscreenContentModeButton(
                titleKey: "mobile_mode",
                systemImage: "iphone",
                isSelected: !(tabManager?.isDesktopMode ?? false)
            ) {
                setFullscreenDesktopMode(false)
            }

            fullscreenContentModeButton(
                titleKey: "desktop_mode",
                systemImage: "desktopcomputer",
                isSelected: tabManager?.isDesktopMode ?? false
            ) {
                setFullscreenDesktopMode(true)
            }
        }
        .padding(3)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func fullscreenContentModeButton(
        titleKey: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard !isSelected else { return }
            HapticsManager.selection()
            action()
        } label: {
            Label(LanguageManager.shared.localizedString(titleKey), systemImage: systemImage)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.9 : 0.48))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    isSelected ? .white.opacity(0.13) : .clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(tabManager == nil)
    }

    private var fullscreenNavigationActions: some View {
        HStack(spacing: 7) {
            fullscreenCompactAction(
                titleKey: "browser_back",
                systemImage: "chevron.left",
                enabled: webViewModel.canGoBack
            ) {
                closeFullscreenMenu()
                webViewModel.goBack()
            }

            fullscreenCompactAction(
                titleKey: "browser_reload",
                systemImage: webViewModel.isLoading ? "xmark" : "arrow.clockwise",
                enabled: webViewModel.currentURL != nil
            ) {
                closeFullscreenMenu()
                webViewModel.reload()
            }

            fullscreenCompactAction(
                titleKey: "browser_forward",
                systemImage: "chevron.right",
                enabled: webViewModel.canGoForward
            ) {
                closeFullscreenMenu()
                webViewModel.goForward()
            }

            Button {
                exitFullscreen()
            } label: {
                Label(
                    LanguageManager.shared.localizedString("exit_fullscreen"),
                    systemImage: "arrow.down.right.and.arrow.up.left"
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.red.opacity(0.88))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    private var fullscreenZoomControls: some View {
        HStack(spacing: 8) {
            fullscreenCompactAction(
                titleKey: "web_zoom_out",
                systemImage: "minus",
                enabled: webViewModel.pageZoom > 0.5
            ) {
                webViewModel.decreasePageZoom()
            }

            Button {
                webViewModel.resetPageZoom()
            } label: {
                Text("\(Int((webViewModel.pageZoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.76))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("web_zoom_reset"))

            fullscreenCompactAction(
                titleKey: "web_zoom_in",
                systemImage: "plus",
                enabled: webViewModel.pageZoom < 2
            ) {
                webViewModel.increasePageZoom()
            }
        }
    }

    private func fullscreenCompactAction(
        titleKey: String,
        systemImage: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            HapticsManager.selection()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 0.76 : 0.2))
                .frame(width: 34, height: 34)
                .background(.white.opacity(enabled ? 0.075 : 0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(LanguageManager.shared.localizedString(titleKey))
    }

    private var fullscreenHandleRevealArea: some View {
        VStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .frame(height: max(topSafeAreaInset, windowSafeAreaInsets.top, 8) + 36)
                .gesture(
                    DragGesture(minimumDistance: 10)
                        .onEnded { value in
                            if FullscreenHandleRevealGesture.shouldReveal(
                                translation: value.translation
                            ) {
                                revealFullscreenExitHandle()
                            }
                        }
                )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(!showFullscreenExitHandle)
        .accessibilityHidden(true)
    }

    private func toggleFullscreen() {
        if isFullscreen {
            exitFullscreen()
            return
        }
        HapticsManager.light()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            isFullscreen = true
            toolbarMinimized = false
        }
    }

    private func exitFullscreen() {
        guard isFullscreen else { return }
        fullscreenHintDismissTask?.cancel()
        if keepFullscreenBrowsing {
            keepFullscreenBrowsing = false
        }
        HapticsManager.light()
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) {
            showFullscreenMenu = false
            isFullscreen = false
            toolbarMinimized = false
        }
    }

    private func updateFullscreenPresentation(isFullscreen: Bool) {
        fullscreenHintDismissTask?.cancel()
        fullscreenHintDismissTask = nil

        guard isFullscreen else {
            showFullscreenMenu = false
            showFullscreenExitHandle = false
            showFullscreenExitHint = false
            return
        }

        toolbarManuallyHidden = false
        toolbarMinimized = false

        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showFullscreenMenu = false
            showFullscreenExitHandle = true
            showFullscreenExitHint = true
        }
        scheduleFullscreenHandleDismiss()
    }

    private func revealFullscreenExitHandle() {
        guard isFullscreen, !showFullscreenExitHandle else { return }
        fullscreenHintDismissTask?.cancel()

        HapticsManager.light()
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            showFullscreenMenu = false
            showFullscreenExitHint = false
            showFullscreenExitHandle = true
        }
        scheduleFullscreenHandleDismiss()
    }

    private func toggleFullscreenMenu() {
        guard isFullscreen, showFullscreenExitHandle else { return }
        fullscreenHintDismissTask?.cancel()
        fullscreenHintDismissTask = nil
        HapticsManager.selection()

        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
            showFullscreenExitHint = false
            showFullscreenMenu.toggle()
        }

        if !showFullscreenMenu {
            scheduleFullscreenHandleDismiss()
        }
    }

    private func closeFullscreenMenu() {
        guard showFullscreenMenu else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            showFullscreenMenu = false
        }
        scheduleFullscreenHandleDismiss()
    }

    private func setFullscreenDesktopMode(_ enabled: Bool) {
        guard let tabManager, tabManager.isDesktopMode != enabled else { return }
        tabManager.setDesktopModeEnabled(enabled)
    }

    private var fullscreenDisplayTitle: String {
        let pageTitle = webViewModel.pageTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pageTitle.isEmpty {
            return pageTitle
        }

        guard let host = webViewModel.currentURL?.host else {
            return LanguageManager.shared.localizedString("tab_new_tab")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func copyCurrentPageLink() {
        guard let url = webViewModel.currentURL else { return }
        UIPasteboard.general.url = url
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        NotificationCenter.default.post(name: .linkCopied, object: nil)
    }

    private func capturePage(_ mode: WebPageCaptureMode) {
        guard !isCapturingPage else { return }
        isCapturingPage = true
        Task { @MainActor in
            do {
                captureResult = try await WebPageCaptureService.capture(mode, from: webViewModel.webView)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                captureError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isCapturingPage = false
        }
    }

    private func scheduleFullscreenHandleDismiss() {
        fullscreenHintDismissTask?.cancel()
        fullscreenHintDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_400_000_000)
            guard !Task.isCancelled else { return }
            guard !showFullscreenMenu else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                showFullscreenExitHint = false
                showFullscreenExitHandle = false
            }
        }
    }

    private var miniToolbarPill: some View {
        Button {
            HapticsManager.light()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                toolbarMinimized = false
            }
        } label: {
            HStack(spacing: 8) {
                // Lock / globe icon
                Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))

                // Domain
                if let host = webViewModel.currentURL?.host {
                    Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }

                // Loading indicator
                if webViewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.6))
                }

                // Tab count
                if let tm = tabManager, tm.tabCount > 1 {
                    Text("\(tm.tabCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .browserToolbarCapsuleGlass()
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
    }

    // MARK: - Bookmark

    private func handleBookmarkToggle() {
        guard let url = webViewModel.currentURL?.absoluteString
                ?? webViewModel.webView?.url?.absoluteString else { return }
        let title = webViewModel.pageTitle.isEmpty ? url : webViewModel.pageTitle
        let added = bookmarkViewModel.toggleBookmark(
            title: title, url: url, platformName: nil, context: modelContext
        )
        isBookmarked = added
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showBookmarkToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showBookmarkToast = false }
        }
    }

    private func syncBookmarkState(for url: URL?) {
        guard let s = url?.absoluteString else { isBookmarked = false; return }
        isBookmarked = bookmarkViewModel.isBookmarked(url: s, context: modelContext)
    }
}

private struct WebToolsPresentationModifier: ViewModifier {
    @ObservedObject var webViewModel: WebViewModel
    @Binding var showCaptureOptions: Bool
    let isCapturingPage: Bool
    @Binding var captureResult: WebPageCaptureResult?
    @Binding var captureError: String?
    @Binding var showTranslationSheet: Bool
    let onCapture: (WebPageCaptureMode) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                LanguageManager.shared.localizedString("web_capture"),
                isPresented: $showCaptureOptions,
                titleVisibility: .visible
            ) {
                Button(LanguageManager.shared.localizedString("web_capture_viewport")) {
                    onCapture(.viewport)
                }
                Button(LanguageManager.shared.localizedString("web_capture_full_page")) {
                    onCapture(.fullPage)
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            } message: {
                Text(LanguageManager.shared.localizedString("web_capture_full_page_limit_desc"))
            }
            .sheet(item: $captureResult) { result in
                WebPageCapturePreview(result: result)
            }
            .sheet(isPresented: $showTranslationSheet) {
                WebPageTranslationSheet(
                    webView: webViewModel.webView,
                    pageURL: webViewModel.currentURL,
                    onOpenURL: { url in webViewModel.loadURL(url) }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .alert(
                LanguageManager.shared.localizedString("web_capture_failed"),
                isPresented: Binding(
                    get: { captureError != nil },
                    set: { if !$0 { captureError = nil } }
                )
            ) {
                Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
            } message: {
                Text(captureError ?? "")
            }
            .overlay {
                if isCapturingPage {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(LanguageManager.shared.localizedString("web_capture_processing"))
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(.horizontal, 22)
                        .padding(.vertical, 18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .transition(.opacity)
                }
            }
    }
}

// MARK: - Address Editor

private struct BrowserAddressEditorSheet: View {
    private enum Field: Hashable {
        case query
        case pageURL
    }

    let onOpen: (String) -> Void
    let onVoiceInput: () -> Void

    @State private var text: String
    @State private var pageURLText: String
    @State private var didCopyLink = false
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    init(
        initialText: String,
        initialURL: String,
        onOpen: @escaping (String) -> Void,
        onVoiceInput: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onVoiceInput = onVoiceInput
        _text = State(initialValue: initialText)
        _pageURLText = State(initialValue: initialURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(LanguageManager.shared.localizedString("browser_edit_address"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(focusedField == .query ? Color.accentColor : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)

                TextField(
                    LanguageManager.shared.localizedString("search_placeholder"),
                    text: $text
                )
                .font(.system(size: 15, weight: .medium))
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focusedField, equals: .query)
                .onSubmit(open)
                .accessibilityLabel(LanguageManager.shared.localizedString("search_placeholder"))

                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
                }

                Rectangle()
                    .fill(Color(UIColor.separator).opacity(0.35))
                    .frame(width: 1, height: 20)
                    .accessibilityHidden(true)

                Button {
                    HapticsManager.light()
                    onVoiceInput()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.11), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("voice_record"))
                .accessibilityHint(LanguageManager.shared.localizedString("accessibility_voice_search_hint"))
            }
            .padding(.horizontal, 10)
            .frame(height: 52)
            .background(Color(UIColor.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(focusedField == .query ? Color.accentColor.opacity(0.55) : Color(UIColor.separator).opacity(0.25), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(LanguageManager.shared.localizedString("current_page_link"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(focusedField == .pageURL ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)

                    TextField("https://", text: $pageURLText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focusedField, equals: .pageURL)
                        .onSubmit(openPageURL)
                        .accessibilityLabel(LanguageManager.shared.localizedString("current_page_link"))

                    Button {
                        let value = pageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty else { return }
                        UIPasteboard.general.string = value
                        HapticsManager.light()
                        withAnimation(.easeInOut(duration: 0.18)) { didCopyLink = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(.easeInOut(duration: 0.18)) { didCopyLink = false }
                        }
                    } label: {
                        Image(systemName: didCopyLink ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(didCopyLink ? Color.green : Color.secondary)
                            .frame(width: 28, height: 28)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(pageURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel(LanguageManager.shared.localizedString("copy_link"))

                    Button(action: openPageURL) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(pageURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(pageURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    .accessibilityLabel(LanguageManager.shared.localizedString("open_directly"))
                }
                .padding(.horizontal, 11)
                .frame(height: 42)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(focusedField == .pageURL ? Color.accentColor.opacity(0.45) : Color(UIColor.separator).opacity(0.2), lineWidth: 1)
                )
            }

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text(LanguageManager.shared.localizedString("cancel"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    open()
                } label: {
                    Text(
                        LanguageManager.shared.localizedString(
                            text.trimmingCharacters(in: .whitespacesAndNewlines).isValidURL
                                ? "open_directly"
                                : "search"
                        )
                    )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .onAppear {
            // Sheet presentation and keyboard activation happen on adjacent
            // run-loop passes. Focus first, then select the active field once
            // UIKit has installed its text input as first responder.
            DispatchQueue.main.async {
                focusedField = .query
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    guard focusedField == .query else { return }
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.selectAll(_:)),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                }
            }
        }
    }

    private func open() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        HapticsManager.selection()
        onOpen(value)
    }

    private func openPageURL() {
        let value = pageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        HapticsManager.selection()
        onOpen(value)
    }
}

// MARK: - Load Error

private struct BrowserLoadErrorView: View {
    let message: String
    let host: String?
    let onRetry: () -> Void
    let onGoHome: (() -> Void)?
    let onOpenCompatibility: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)

            Text(LanguageManager.shared.localizedString("load_error"))
                .font(.system(size: 18, weight: .semibold))

            if let host, !host.isEmpty {
                Text(host)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                if let onGoHome {
                    Button(LanguageManager.shared.localizedString("home_screen"), action: onGoHome)
                        .buttonStyle(.bordered)
                }

                Button(LanguageManager.shared.localizedString("retry"), action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: "6366F1"))
            }
            .padding(.top, 4)

            if let onOpenCompatibility {
                Button(action: onOpenCompatibility) {
                    Label(
                        LanguageManager.shared.localizedString("safari_compatibility_mode"),
                        systemImage: "safari"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Safari Compatibility Mode

@MainActor
private final class SafariCompatibilityPresenter: NSObject, ObservableObject, @preconcurrency SFSafariViewControllerDelegate {
    private weak var presentedController: SFSafariViewController?

    func present(url: URL, sourceView: UIView?) {
        guard presentedController == nil,
              let presentingController = topViewController(for: sourceView) else {
            return
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        controller.modalPresentationStyle = .fullScreen
        controller.delegate = self
        presentedController = controller
        presentingController.present(controller, animated: true)
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        controller.dismiss(animated: true) { [weak self] in
            self?.presentedController = nil
        }
    }

    private func topViewController(for sourceView: UIView?) -> UIViewController? {
        let sourceScene = sourceView?.window?.windowScene
        let foregroundScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene = sourceScene ?? foregroundScene,
              let root = scene.keyWindow?.rootViewController else {
            return nil
        }
        return visibleViewController(from: root)
    }

    private func visibleViewController(from root: UIViewController) -> UIViewController {
        if let presented = root.presentedViewController {
            return visibleViewController(from: presented)
        }
        if let navigation = root as? UINavigationController,
           let visible = navigation.visibleViewController {
            return visibleViewController(from: visible)
        }
        if let tabs = root as? UITabBarController,
           let selected = tabs.selectedViewController {
            return visibleViewController(from: selected)
        }
        return root
    }
}

// MARK: - Find in Page Bar

struct FindInPageBar: View {
    @ObservedObject var tabManager: TabManager
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                TextField(
                    LanguageManager.shared.localizedString("find_in_page"),
                    text: $tabManager.findText
                )
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .onSubmit { tabManager.findNext() }
                .onChange(of: tabManager.findText) { _, _ in
                    tabManager.performFind()
                }
                .accessibilityLabel(LanguageManager.shared.localizedString("find_in_page"))

                if !tabManager.findText.isEmpty {
                    Text("\(tabManager.findMatchCount)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(UIColor.tertiarySystemFill), in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Button { tabManager.findPrevious() } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tabManager.findMatchCount > 0 ? .primary : .tertiary)
            }
            .disabled(tabManager.findMatchCount == 0)
            .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_previous_match"))

            Button { tabManager.findNext() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tabManager.findMatchCount > 0 ? .primary : .tertiary)
            }
            .disabled(tabManager.findMatchCount == 0)
            .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_next_match"))

            Button {
                tabManager.dismissFindInPage()
            } label: {
                Text(LanguageManager.shared.localizedString("done"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(hex: "6366F1"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(UIColor.secondarySystemBackground))
        .onAppear { isFocused = true }
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
