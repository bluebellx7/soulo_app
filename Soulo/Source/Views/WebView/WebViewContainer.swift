import SwiftUI
import SwiftData
import SafariServices

enum BrowserChromeLayout {
    static let controlHeight: CGFloat = 40
    static let bottomSpacing: CGFloat = 16
    static let pageContentClearance: CGFloat = 8

    static func showsBottomToolbar(
        isActiveTab: Bool,
        isFullscreen: Bool,
        isManuallyHidden: Bool = false
    ) -> Bool {
        isActiveTab && !isFullscreen && !isManuallyHidden
    }

    static func showsFloatingMore(
        isActiveTab: Bool,
        isFullscreen: Bool,
        isManuallyHidden: Bool
    ) -> Bool {
        isActiveTab && !isFullscreen && isManuallyHidden
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

    static func pageViewportBottomInset(
        isActiveTab: Bool,
        isVideoPage: Bool,
        showsBottomToolbar: Bool,
        bottomClearance: CGFloat
    ) -> CGFloat {
        guard isActiveTab, isVideoPage || showsBottomToolbar else { return 0 }
        return max(bottomClearance, 0)
    }
}

enum BrowserAddressEditorLayout {
    static let compactHeight: CGFloat = 210
}

private struct WebExtensionInstallPresentation: Identifiable {
    let id = UUID()
    let link: String
    let autoStart: Bool
}

enum BrowserChromeSymbol {
    /// A browser viewport with its bottom control area highlighted. Using the
    /// same object symbol for both states avoids implying navigation direction.
    static let toolbarVisibility = "rectangle.bottomthird.inset.filled"
}

private enum FloatingMoreAttachment: Equatable {
    case left
    case right
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

    static func beginsNearTop(startY: CGFloat, maximumStartY: CGFloat) -> Bool {
        startY >= 0 && startY <= max(maximumStartY, 0)
    }
}

enum FullscreenHandleLayout {
    /// Keep the indicator visually compact while providing a forgiving target.
    static let indicatorSize = CGSize(width: 36, height: 4)
    static let minimumHitSize = CGSize(width: 104, height: 52)
}

private struct BrowserNavigationConfirmationBar: View {
    let icon: String
    let title: String
    let destination: String
    var address: String? = nil
    let cancelTitle: String
    let confirmTitle: String
    let identifier: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    var alternativeTitle: String? = nil
    var onAlternative: (() -> Void)? = nil
    var trustDomain: String? = nil
    var onTrust: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(destination)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(address == nil ? 1 : 2)
                }
                Spacer(minLength: 0)
            }
            if let address {
                Text(address)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("\(identifier).address")
            }
            if let trustDomain, let onTrust {
                Button(action: onTrust) {
                    Label(String(format: ToolText.text("cross_domain_trust"), trustDomain), systemImage: "checkmark.shield")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.yellow)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("\(identifier).trust")
            }
            HStack(spacing: 10) {
                Button(action: onCancel) {
                    Text(cancelTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("\(identifier).cancel")
                if let alternativeTitle, let onAlternative {
                    Button(action: onAlternative) {
                        Text(alternativeTitle)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("\(identifier).new-tab")
                }
                Button(action: onConfirm) {
                    Text(confirmTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.orange, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("\(identifier).continue")
            }
        }
        .buttonStyle(.plain)
        .padding(14)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

struct WebViewContainer: View {
    @ObservedObject var webViewModel: WebViewModel
    @ObservedObject var bookmarkViewModel: BookmarkViewModel
    @Binding var isFullscreen: Bool
    var tabManager: TabManager? = nil
    var toolbarManuallyHiddenBinding: Binding<Bool>? = nil
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
    @AppStorage(AppConstants.StorageKeys.keepPageAboveToolbar) private var keepPageAboveToolbar = false
    @StateObject private var safariCompatibilityPresenter = SafariCompatibilityPresenter()

    @State private var isBookmarked: Bool = false
    @State private var sharePresentation: PageSharePresentation?
    @State private var showExternalConfirm: Bool = false
    @State private var showBookmarkToast: Bool = false
    @State private var showLinkCopiedToast: Bool = false
    @State private var externalURL: URL? = nil
    @State private var showNewTabPage: Bool = true
    @State private var toolbarMinimized: Bool = false
    @State private var localToolbarManuallyHidden: Bool = false
    @State private var toolbarInteractionLocked: Bool = false
    @State private var floatingMoreAttachment: FloatingMoreAttachment = .left
    @State private var floatingMoreVerticalFraction: CGFloat = 0.88
    @State private var floatingMoreDragTranslation: CGSize = .zero
    @State private var showAdBlockManager = false
    @State private var markAdAfterDismiss = false
    @State private var showPrivacyPanel = false
    @State private var showPrivacySettings = false
    @State private var librarySection: LibrarySection?
    @State private var showExtensionCenter = false
    @State private var remoteExtensionInstallPresentation: WebExtensionInstallPresentation?
    @State private var extensionInstallCandidate: BrowserExtensionInstallCandidate?
    @State private var showExternalOpenFailed = false
    @State private var showDownloadFailed = false
    @State private var showAddressEditor = false
    @State private var requestVoiceAfterAddressEditorDismisses = false
    @State private var showFullscreenExitHandle = false
    @State private var showFullscreenExitHint = false
    @State private var showFullscreenMenu = false
    @State private var fullscreenHintDismissTask: Task<Void, Never>?
    @State private var showCaptureOptions = false
    @State private var showResourceInspector = false
    @State private var showArticleReader = false
    @State private var showWiFiTransfer = false
    @State private var imageTextResult: ImageTextRecognitionResult?
    @State private var imageTextError: String?
    @State private var isCapturingPage = false
    @State private var completedCaptureParts = 0
    @State private var totalCaptureParts = 0
    @State private var captureResult: WebPageCaptureResult?
    @State private var pdfResult: WebPagePDFResult?
    @State private var captureError: String?
    @State private var showTranslationSheet = false

    private var toolbarManuallyHidden: Bool {
        get {
            toolbarManuallyHiddenBinding?.wrappedValue ?? localToolbarManuallyHidden
        }
        nonmutating set {
            if let toolbarManuallyHiddenBinding {
                toolbarManuallyHiddenBinding.wrappedValue = newValue
            } else {
                localToolbarManuallyHidden = newValue
            }
        }
    }

    var body: some View {
        browserContent.modifier(SafariCompatibilityFeedback(presenter: safariCompatibilityPresenter))
    }

    private var browserPageLayers: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                if !isFullscreen {
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
                        onAccessibilityPlatformPage: onAccessibilityPlatformPage,
                        obscuredBottomInset: webViewObscuredBottomInset
                    )
                        .id(webViewModel.runtimeRevision)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(isShowingNewTabPage ? 0 : 1)
                        .allowsHitTesting(!isShowingNewTabPage)
                        .overlay {
                            if webViewModel.showSnapshotWhileRestoring,
                               let snapshot = webViewModel.snapshot,
                               webViewModel.currentURL != nil {
                                RestoringPageSnapshot(image: snapshot)
                            }
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
                            url: webViewModel.currentURL,
                            onRetry: { webViewModel.retryCurrentPage() },
                            onGoHome: onGoHome,
                            onOpenCompatibility: canOpenSafariCompatibility
                                ? { openSafariCompatibilityMode() }
                                : nil
                        )
                        .padding(.bottom, showsBottomToolbar ? max(0, pageBottomClearance - pageViewportBottomInset) : 0)
                        .transition(.opacity)
                    }
                }
                // A shorter viewport keeps fixed page controls above the floating toolbar.
                .padding(.bottom, pageViewportBottomInset)
            }

            if videoViewportBottomInset > 0 {
                videoBottomChromeBackdrop
                    .zIndex(40)
            }

            if showsBottomToolbar {
                browserToolbarChrome
                    .frame(height: bottomToolbarHeight, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toolbarMinimized)
                    .zIndex(50)
            }

            if webViewModel.manualAdSelection == nil && webViewModel.manualAdSavedRuleID == nil && BrowserChromeLayout.showsFloatingMore(
                isActiveTab: isActiveTab,
                isFullscreen: isFullscreen,
                isManuallyHidden: toolbarManuallyHidden
            ) {
                floatingMoreOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.72)))
                    .zIndex(51)
            }

            if isActiveTab && isFullscreen {
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
            if isActiveTab, let rate = webViewModel.videoHoldSpeed {
                VStack {
                    VideoPlaybackSpeedToast(rate: rate)
                        .padding(.top, 12)
                        .accessibilityIdentifier("browser.video-hold-speed")
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(80)
            }
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

            if isActiveTab, let request = webViewModel.domainNavigationConfirmation {
                VStack {
                    Spacer()
                    BrowserNavigationConfirmationBar(
                        icon: "arrow.up.forward.square",
                        title: ToolText.text("cross_domain_title"),
                        destination: "\(request.sourceURL.host ?? "") → \(request.destinationURL.host ?? "")",
                        address: request.destinationURL.absoluteString,
                        cancelTitle: ToolText.text("cancel"),
                        confirmTitle: ToolText.text("cross_domain_continue"),
                        identifier: "browser.domain-confirmation",
                        onCancel: {
                            withAnimation {
                                webViewModel.resolveDomainNavigationConfirmation(id: request.id, allowed: false)
                            }
                        },
                        onConfirm: {
                            withAnimation {
                                webViewModel.resolveDomainNavigationConfirmation(id: request.id, allowed: true)
                            }
                        },
                        alternativeTitle: tabManager != nil ? ToolText.text("cross_domain_new_tab") : nil,
                        onAlternative: {
                            tabManager?.openDomainNavigationInNewTab(from: webViewModel, confirmationID: request.id)
                        },
                        trustDomain: BrowserDomainNavigationPolicy.trustRule(for: request.destinationURL),
                        onTrust: {
                            guard webViewModel.domainNavigationConfirmation?.id == request.id,
                                  let rule = BrowserDomainNavigationPolicy.trustRule(for: request.destinationURL),
                                  BrowserDomainAllowlist.shared.add(rule) else { return }
                            withAnimation {
                                webViewModel.resolveDomainNavigationConfirmation(id: request.id, allowed: true)
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomOverlayClearance)
                }
                .id(request.id)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(80)
                .onAppear {
                    AppAccessibility.announce(
                        String(format: ToolText.text("cross_domain_message"),
                               request.sourceURL.host ?? "", request.destinationURL.host ?? "")
                    )
                }
            } else if isActiveTab, showExternalConfirm, let extURL = externalURL {
                VStack {
                    Spacer()
                    BrowserNavigationConfirmationBar(
                        icon: "arrow.up.forward.app",
                        title: LanguageManager.shared.localizedString("open_external_title"),
                        destination: WebNavigationPolicyService.shared.externalDestinationName(for: extURL),
                        cancelTitle: LanguageManager.shared.localizedString("cancel"),
                        confirmTitle: LanguageManager.shared.localizedString("confirm"),
                        identifier: "browser.external-app-confirmation",
                        onCancel: {
                            withAnimation { showExternalConfirm = false }
                        },
                        onConfirm: {
                            openExternalURL(extURL)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, bottomOverlayClearance)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(80)
                .onAppear {
                    AppAccessibility.announce(
                        "\(LanguageManager.shared.localizedString("open_external_title")), \(WebNavigationPolicyService.shared.externalDestinationName(for: extURL))"
                    )
                }
            }

            downloadFeedback
        }
    }

    private var browserLifecycle: some View {
        browserPageLayers
        .background {
            if #available(iOS 18.0, *) {
                FollowLinkTranslationRuntime(viewModel: webViewModel)
                    .frame(width: 0, height: 0)
            }
        }
        .animation(.easeOut(duration: 0.18), value: webViewModel.showSnapshotWhileRestoring)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: webViewModel.videoHoldSpeed)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            webViewModel.clearVideoHoldSpeed()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isActiveTab && (webViewModel.manualAdSelection != nil || webViewModel.manualAdSavedRuleID != nil) {
                ManualAdPickerPanel(model: webViewModel)
                    .padding(.bottom, windowSafeAreaInsets.bottom)
                    .background(.regularMaterial)
            }
        }
        .alert(ToolText.text("error"), isPresented: $webViewModel.manualAdError) {
            Button(ToolText.text("done"), role: .cancel) {}
        } message: {
            Text(ToolText.text("manual_ad_error"))
        }
        .modifier(VideoOrientationErrorAlert(message: $webViewModel.videoOrientationError))
        .onChange(of: isActiveTab) { _, active in
            if !active {
                webViewModel.clearVideoHoldSpeed()
                webViewModel.cancelMarkingAdvertisement()
                webViewModel.resolveDomainNavigationConfirmation(allowed: false)
                showExternalConfirm = false
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: webViewModel.domainNavigationConfirmation?.id)
        .onChange(of: webViewModel.domainNavigationConfirmation?.id) { _, id in
            guard id != nil else { return }
            guard isActiveTab else {
                webViewModel.resolveDomainNavigationConfirmation(id: id, allowed: false)
                return
            }
            showExternalConfirm = false
        }
        .simultaneousGesture(
            fullscreenHandleRevealGesture,
            including: isActiveTab && isFullscreen && !showFullscreenExitHandle
                ? .all
                : .none
        )
        .onChange(of: webViewModel.isScrollingUp) { _, scrollingUp in
            if isActiveTab {
                guard !voiceOverEnabled, !shouldKeepPageAboveToolbar else {
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
        .onChange(of: shouldKeepPageAboveToolbar) { _, enabled in
            if enabled {
                toolbarMinimized = false
            }
        }
        .onChange(of: isFullscreen) { _, fullscreen in
            updateFullscreenPresentation(isFullscreen: fullscreen)
        }
        .onChange(of: showTranslationSheet) { _, isPresented in
            guard !isPresented else { return }
            Task { @MainActor in
                await webViewModel.refreshPageTranslationState()
            }
        }
        .onAppear {
            updateFullscreenPresentation(isFullscreen: isFullscreen)
        }
        .onDisappear {
            webViewModel.clearVideoHoldSpeed()
            webViewModel.cancelMarkingAdvertisement()
            webViewModel.resolveDomainNavigationConfirmation(allowed: false)
            showExternalConfirm = false
            fullscreenHintDismissTask?.cancel()
            fullscreenHintDismissTask = nil
        }
    }

    private var browserNotifications: some View {
        browserLifecycle
        .onReceive(NotificationCenter.default.publisher(for: .searchSelectionInSoulo)) { _ in
            // Pop the library/reader through its presentation binding. Replacing
            // the entire NavigationStack during an edit-menu action can detach
            // the new WebView or leave UIKit navigation items on the old bar.
            librarySection = nil
            showArticleReader = false
        }
        .accessibilityAction(.escape) {
            if webViewModel.domainNavigationConfirmation != nil {
                webViewModel.resolveDomainNavigationConfirmation(allowed: false)
            } else if showExternalConfirm {
                showExternalConfirm = false
            } else if isFullscreen {
                exitFullscreen()
            }
        }
        .onChange(of: webViewModel.isLoading) { _, loading in
            if loading { onPageStarted?() } else { onPageLoaded?() }
        }
        .onChange(of: webViewModel.hasVisibleContent) { _, visible in
            if visible { onPageLoaded?() }
        }
        .onChange(of: webViewModel.estimatedProgress) { _, progress in
            if progress >= 0.98 { onPageLoaded?() }
        }
        .modifier(BrowserHandoffModifier(
            url: BrowserHandoff.eligibleURL(webViewModel.currentURL, isPrivate: searchVM.isIncognito),
            title: webViewModel.pageTitle, enabled: isActiveTab))
        .onChange(of: webViewModel.currentURL) { _, url in
            showExternalConfirm = false
            if isActiveTab { tabManager?.dismissFindInPage() }
            onPageStarted?()
            syncBookmarkState(for: url)
            if url != nil {
                withAnimation(.easeOut(duration: 0.2)) { showNewTabPage = false }
            }
        }
        .onChange(of: videoViewportBottomInset) { _, _ in
            guard webViewModel.needsVideoViewportClearance else { return }
            DispatchQueue.main.async {
                webViewModel.synchronizePageViewport()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                webViewModel.synchronizePageViewport()
            }
        }
        // Scoped notifications — only process when this is the active tab
        .onReceive(NotificationCenter.default.publisher(for: .webViewExternalURLRequest)) { notification in
            guard isActiveTab, notification.object as? WebViewModel === webViewModel else { return }
            if let url = notification.userInfo?["url"] as? URL {
                webViewModel.resolveDomainNavigationConfirmation(allowed: false)
                guard ExternalNavigationService.shared.promptEnabled else {
                    openExternalURL(url)
                    return
                }
                externalURL = url
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showExternalConfirm = true
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
    }

    private func openExternalURL(_ url: URL) {
        withAnimation { showExternalConfirm = false }
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

    private var browserContent: some View {
        browserNotifications
        .sheet(item: $sharePresentation) { presentation in
            ShareSheet(items: presentation.items)
        }
        .sheet(
            isPresented: $showAddressEditor,
            onDismiss: handleAddressEditorDismissal
        ) {
            BrowserAddressEditorSheet(
                initialText: addressEditorText ?? webViewModel.currentURL?.absoluteString ?? "",
                initialURL: webViewModel.currentURL?.absoluteString ?? "",
                onOpen: { value in
                    showAddressEditor = false
                    onAddressSearch?(value)
                },
                onOpenURL: { url in
                    showAddressEditor = false
                    webViewModel.loadURL(url)
                },
                onVoiceInput: {
                    requestVoiceAfterAddressEditorDismisses = true
                    showAddressEditor = false
                }
            )
            .presentationDetents([.height(BrowserAddressEditorLayout.compactHeight)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAdBlockManager, onDismiss: {
            if markAdAfterDismiss {
                markAdAfterDismiss = false
                webViewModel.beginMarkingAdvertisement()
            }
        }) {
            NavigationStack {
                AdBlockManagementView(currentHost: webViewModel.currentURL?.host, showsDoneButton: true,
                    currentURL: webViewModel.currentURL,
                    onMarkAdvertisement: webViewModel.canMarkAdvertisement ? {
                        markAdAfterDismiss = true
                        showAdBlockManager = false
                    } : nil) {
                    WebViewRepresentable.reloadWithCurrentAdRules(webViewModel)
                }
            }
        }
        .sheet(isPresented: $showPrivacySettings) {
            if let tabManager {
                NavigationStack {
                    PrivacySettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(LanguageManager.shared.localizedString("done")) { showPrivacySettings = false }
                            }
                        }
                }
                .environmentObject(tabManager)
                .environmentObject(searchVM)
            }
        }
        .sheet(isPresented: $showPrivacyPanel) {
            NavigationStack {
                SitePrivacyPanelView(currentURL: webViewModel.currentURL) {
                    webViewModel.reload()
                }
            }
        }
        .navigationDestination(item: $librarySection) { section in
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
        .sheet(item: $remoteExtensionInstallPresentation) { presentation in
            WebExtensionStoreInstallView(
                initialValue: presentation.link,
                autoStart: presentation.autoStart
            )
                .presentationDetents([.height(390), .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $extensionInstallCandidate) { candidate in
            BrowserPackageInstallView(candidate: candidate)
                .presentationDetents([.height(580), .large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showWiFiTransfer) {
            WiFiTransferView(directory: BookLibrary.directory).toolbar(.visible, for: .navigationBar)
        }
        .sheet(isPresented: $showArticleReader) {
            if let webView = webViewModel.webView { ArticleReaderView(source: webView) }
        }
        .sheet(isPresented: $webViewModel.showEpisodes) {
            WebEpisodePickerView(viewModel: webViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showResourceInspector) {
            NavigationStack {
                WebResourceInspectorView(webViewModel: webViewModel)
            }
        }
        .fullScreenCover(item: $webViewModel.imagePreview) { request in
            WebImagePreview(request: request)
        }
        .onChange(of: webViewModel.showMediaDownloads) { _, show in
            if show { showResourceInspector = true; webViewModel.showMediaDownloads = false }
        }
        .modifier(ImageTextRecognitionPresentationModifier(
            webViewModel: webViewModel,
            isActiveTab: isActiveTab,
            result: $imageTextResult,
            errorMessage: $imageTextError,
            onSearch: { onAddressSearch?($0) }
        ))
        .modifier(
            WebToolsPresentationModifier(
                webViewModel: webViewModel,
                showCaptureOptions: $showCaptureOptions,
                captureAtTop: isFullscreen,
                isCapturingPage: isCapturingPage,
                completedCaptureParts: completedCaptureParts,
                totalCaptureParts: totalCaptureParts,
                captureResult: $captureResult,
                pdfResult: $pdfResult,
                captureError: $captureError,
                showTranslationSheet: $showTranslationSheet,
                onCapture: capturePage,
                onExportPDF: exportPagePDF
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
        .onReceive(NotificationCenter.default.publisher(for: .webExtensionStoreInstallRequested)) { notification in
            guard isActiveTab,
                  notification.object as AnyObject? === webViewModel,
                  let value = notification.userInfo?["url"] as? String else { return }
            remoteExtensionInstallPresentation = WebExtensionInstallPresentation(
                link: value,
                autoStart: true
            )
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserExtensionsChanged)) { _ in
            // Rebuild every loaded tab. Otherwise an inactive tab would keep
            // the old WKUserScript set when it becomes active later.
            if let tabManager {
                for tab in tabManager.tabs where tab.webViewModel.currentURL != nil {
                    tab.webViewModel.rebuildWebViewRuntime()
                }
            } else if webViewModel.currentURL != nil {
                webViewModel.rebuildWebViewRuntime()
            }
        }
    }

    // MARK: - Toast

    @ViewBuilder
    private var downloadFeedback: some View {
        // Completion uses the shared DownloadCompletionToast, including its
        // VoiceOver announcement and the link to the downloads list.
        if webViewModel.isDownloading {
            VStack {
                Spacer()
                Button {
                    HapticsManager.selection()
                    librarySection = .downloads
                } label: {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small).tint(.white)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LanguageManager.shared.localizedString("downloading"))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                            Text(downloadStatusDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("downloading") + ", " + downloadStatusDetail)
                .accessibilityIdentifier("browser.downloadStatus")
                .padding(.bottom, bottomOverlayClearance)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

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
        if let pageURL {
            tabManager.activeWebViewModel?.loadURL(pageURL)
        }
        searchVM.isSearching = true
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
        if toolbarManuallyHidden {
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
        return BrowserChromeLayout.pageViewportBottomInset(
            isActiveTab: isActiveTab,
            isVideoPage: webViewModel.needsVideoViewportClearance,
            showsBottomToolbar: false,
            bottomClearance: pageBottomClearance
        )
    }

    private var showsBottomToolbar: Bool {
        webViewModel.manualAdSelection == nil
            && webViewModel.manualAdSavedRuleID == nil
            && BrowserChromeLayout.showsBottomToolbar(
                isActiveTab: isActiveTab,
                isFullscreen: isFullscreen,
                isManuallyHidden: toolbarManuallyHidden
            )
    }

    private var shouldKeepPageAboveToolbar: Bool {
        keepPageAboveToolbar || webViewModel.needsVideoViewportClearance
    }

    private var pageViewportBottomInset: CGFloat {
        guard shouldKeepPageAboveToolbar else { return 0 }
        if #available(iOS 26.0, *) {
            return videoViewportBottomInset
        }
        return BrowserChromeLayout.pageViewportBottomInset(
            isActiveTab: isActiveTab,
            isVideoPage: webViewModel.needsVideoViewportClearance,
            showsBottomToolbar: showsBottomToolbar,
            bottomClearance: pageBottomClearance
        )
    }

    private var webViewObscuredBottomInset: CGFloat {
        guard shouldKeepPageAboveToolbar, showsBottomToolbar,
              !webViewModel.needsVideoViewportClearance else { return 0 }
        return pageBottomClearance
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
        // The first foreground scene can belong to another browser window.
        // Use the page's own window when computing toolbar/video clearance.
        webViewModel.webView?.window?.safeAreaInsets ?? .zero
    }

    private var toolbarGlassTint: Color? {
        searchVM.isIncognito ? Color.teal.opacity(0.14) : nil
    }

    private var browserToolbarChrome: some View {
        VStack(spacing: 0) {
            Group {
                if toolbarMinimized && !shouldKeepPageAboveToolbar {
                    miniToolbarPill
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.6).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                } else {
                    configuredBrowserToolbar()
                    .frame(maxWidth: 720)
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

    private func configuredBrowserToolbar(
        showsOnlyMore: Bool = false,
        onFloatingMoreDragChanged: ((CGSize) -> Void)? = nil,
        onFloatingMoreDragEnded: ((CGSize) -> Void)? = nil
    ) -> some View {
        WebViewToolbar(
            viewModel: webViewModel,
            isBookmarked: $isBookmarked,
            tabManager: tabManager,
            onShare: {
                shareCurrentPage()
            },
            onBookmarkToggle: { handleBookmarkToggle() },
            onShowPrivacy: { showPrivacyPanel = true },
            onPrivacySettings: { showPrivacySettings = true },
            onSetPrivateMode: { enabled in
                setPrivateMode(enabled)
            },
            onManageAdBlock: { showAdBlockManager = true },
            onShowLibrary: { librarySection = .bookmarks },
            onOpenLibrarySection: { librarySection = $0 },
            onWiFiTransfer: { showWiFiTransfer = true },
            onShowExtensions: { showExtensionCenter = true },
            onGoHome: onGoHome,
            onEditAddress: { presentAddressEditor() },
            onAddressTranslation: { handleAddressTranslationAction() },
            onHideToolbar: { hideToolbar() },
            onOpenSettings: onOpenSettings,
            isFullscreen: false,
            onToggleFullscreen: { toggleFullscreen() },
            onOpenSafariCompatibility: { openSafariCompatibilityMode() },
            onOpenDefaultBrowser: { openCurrentPageInDefaultBrowser() },
            onCapturePage: { showCaptureOptions = true },
            onInspectResources: { showResourceInspector = true },
            onReadArticle: { showArticleReader = true },
            onTranslatePage: { showTranslationSheet = true },
            onMoreMenuPresentationChange: { isPresented in
                toolbarInteractionLocked = isPresented
                if isPresented, toolbarMinimized {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        toolbarMinimized = false
                    }
                }
            },
            showsOnlyMore: showsOnlyMore,
            onRestoreToolbar: { restoreToolbar() },
            onFloatingMoreDragChanged: onFloatingMoreDragChanged,
            onFloatingMoreDragEnded: onFloatingMoreDragEnded
        )
    }

    private var floatingMoreOverlay: some View {
        GeometryReader { proxy in
            let bounds = floatingMoreBounds(
                in: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
            let basePosition = floatingMorePosition(in: bounds)
            let dragPosition = clampedFloatingMorePosition(
                CGPoint(
                    x: basePosition.x + floatingMoreDragTranslation.width,
                    y: basePosition.y + floatingMoreDragTranslation.height
                ),
                in: bounds
            )

            configuredBrowserToolbar(
                showsOnlyMore: true,
                onFloatingMoreDragChanged: { translation in
                    floatingMoreDragTranslation = translation
                },
                onFloatingMoreDragEnded: { translation in
                    finishFloatingMoreDrag(
                        from: basePosition,
                        translation: translation,
                        in: bounds
                    )
                }
            )
                .position(dragPosition)
        }
        .accessibilityElement(children: .contain)
    }

    private func floatingMoreBounds(
        in size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> CGRect {
        let buttonCenterInset: CGFloat = 28
        let minimumX = safeAreaInsets.leading + buttonCenterInset
        let maximumX = max(minimumX, size.width - safeAreaInsets.trailing - buttonCenterInset)
        let minimumY = safeAreaInsets.top + buttonCenterInset
        let maximumY = max(minimumY, size.height - safeAreaInsets.bottom - buttonCenterInset)
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private func floatingMorePosition(in bounds: CGRect) -> CGPoint {
        let verticalFraction = min(max(floatingMoreVerticalFraction, 0), 1)
        let y = bounds.minY + bounds.height * verticalFraction
        let x: CGFloat = switch floatingMoreAttachment {
        case .left:
            bounds.minX
        case .right:
            bounds.maxX
        }
        return CGPoint(x: x, y: y)
    }

    private func clampedFloatingMorePosition(
        _ position: CGPoint,
        in bounds: CGRect
    ) -> CGPoint {
        CGPoint(
            x: min(max(position.x, bounds.minX), bounds.maxX),
            y: min(max(position.y, bounds.minY), bounds.maxY)
        )
    }

    private func finishFloatingMoreDrag(
        from start: CGPoint,
        translation: CGSize,
        in bounds: CGRect
    ) {
        let position = clampedFloatingMorePosition(
            CGPoint(
                x: start.x + translation.width,
                y: start.y + translation.height
            ),
            in: bounds
        )
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            floatingMoreDragTranslation = .zero
            if bounds.height > 0 {
                floatingMoreVerticalFraction = (position.y - bounds.minY) / bounds.height
            }
            floatingMoreAttachment = position.x <= bounds.midX ? .left : .right
        }
        HapticsManager.selection()
    }

    private func restoreToolbar() {
        HapticsManager.light()
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            toolbarManuallyHidden = false
            toolbarMinimized = false
        }
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
            .accessibilityIdentifier("fullscreen.handle")

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

    private var fullscreenQuickMenu: FullscreenQuickMenu {
        FullscreenQuickMenu(
            webViewModel: webViewModel,
            title: fullscreenDisplayTitle,
            isBookmarked: isBookmarked,
            isDesktopMode: tabManager?.isDesktopMode ?? false,
            canSwitchContentMode: tabManager != nil,
            onAction: performFullscreenMenuAction
        )
    }

    private func performFullscreenMenuAction(_ action: FullscreenQuickMenu.Action) {
        switch action {
        case .mobileMode: setFullscreenDesktopMode(false)
        case .desktopMode: setFullscreenDesktopMode(true)
        case .exitFullscreen: exitFullscreen()
        case .close: closeFullscreenMenu()
        default:
            closeFullscreenMenu()
            switch action {
            case .share: shareCurrentPage()
            case .copyLink: copyCurrentPageLink()
            case .bookmark: handleBookmarkToggle()
            case .library: librarySection = .bookmarks
            case .home: onGoHome?()
            case .capture: showCaptureOptions = true
            case .translate: showTranslationSheet = true
            case .settings: onOpenSettings?()
            case .editAddress: presentAddressEditor()
            case .back: webViewModel.goBack()
            case .reload: webViewModel.reload()
            case .forward: webViewModel.goForward()
            default: break
            }
        }
    }

    private var fullscreenHandleRevealGesture: some Gesture {
        DragGesture(minimumDistance: 10, coordinateSpace: .local)
            .onEnded { value in
                let maximumStartY = max(topSafeAreaInset, windowSafeAreaInsets.top, 8) + 36
                guard FullscreenHandleRevealGesture.beginsNearTop(
                    startY: value.startLocation.y,
                    maximumStartY: maximumStartY
                ), FullscreenHandleRevealGesture.shouldReveal(
                    translation: value.translation
                ) else {
                    return
                }
                revealFullscreenExitHandle()
            }
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

        // Full screen temporarily replaces browser chrome, but it must not
        // overwrite the user's persisted toolbar visibility preference.
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

    private func shareCurrentPage() {
        guard let url = webViewModel.currentURL else { return }
        // This one item behaves as a regular URL for every share extension and
        // also adopts SafariServices' native Add to Home Screen activity.
        if #available(iOS 17.4, *),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            sharePresentation = PageSharePresentation(items: [
                WebPageShareActivityItem(url: url, title: fullscreenDisplayTitle)
            ])
        } else {
            sharePresentation = PageSharePresentation(items: [url])
        }
    }

    private func handleAddressTranslationAction() {
        let isTranslated = webViewModel.isPageTranslationApplied
            || isGoogleTranslationPageURL(webViewModel.currentURL)
        if !isTranslated {
            presentAddressTranslationForAppLanguage()
            return
        }
        showTranslationSheet = true
    }

    private func presentAddressTranslationForAppLanguage() {
        let defaults = UserDefaults.standard
        let appLanguage = AppConstants.canonicalLanguageCode(
            defaults.string(forKey: AppConstants.StorageKeys.selectedLanguage)
                ?? AppConstants.preferredLanguageCode()
        )
        defaults.set(appLanguage, forKey: "web_translation_apple_target")
        defaults.set(appLanguage, forKey: "web_translation_google_target")
        showTranslationSheet = true
    }

    private func capturePage(_ mode: WebPageCaptureMode) {
        guard !isCapturingPage else { return }
        completedCaptureParts = 0; totalCaptureParts = 0
        isCapturingPage = true
        Task { @MainActor in
            do {
                captureResult = try await WebPageCaptureService.capture(mode, from: webViewModel.webView) { completed, total in
                    completedCaptureParts = completed; totalCaptureParts = total
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                captureError = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isCapturingPage = false
        }
    }

    private func exportPagePDF() {
        guard !isCapturingPage else { return }
        completedCaptureParts = 0; totalCaptureParts = 0
        isCapturingPage = true
        let title = webViewModel.pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            do {
                pdfResult = try await WebPagePDFService.export(
                    from: webViewModel.webView,
                    title: title,
                    onProgress: { completed, total in
                        completedCaptureParts = completed; totalCaptureParts = total
                    }
                )
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
                // Privacy / lock / globe icon
                Image(systemName: searchVM.isIncognito
                    ? "eye.slash.fill"
                    : webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe"
                )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        searchVM.isIncognito
                            ? Color.teal.opacity(0.9)
                            : Color.primary.opacity(0.6)
                    )

                // Domain
                if let host = webViewModel.currentURL?.host {
                    Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .lineLimit(1)
                }

                // Loading indicator
                if webViewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.primary.opacity(0.6))
                }

                // Tab count
                if let tm = tabManager, tm.tabCount > 1 {
                    Text("\(tm.tabCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .browserToolbarCapsuleGlass(tint: toolbarGlassTint)
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

    private func presentAddressEditor() {
        showAddressEditor = true
    }

    private func handleAddressEditorDismissal() {
        guard requestVoiceAfterAddressEditorDismisses else { return }
        requestVoiceAfterAddressEditorDismisses = false
        DispatchQueue.main.async {
            onRequestVoiceSearch?()
        }
    }
}

private struct WebToolsPresentationModifier: ViewModifier {
    @ObservedObject var webViewModel: WebViewModel
    @Binding var showCaptureOptions: Bool
    let captureAtTop: Bool
    let isCapturingPage: Bool
    let completedCaptureParts: Int
    let totalCaptureParts: Int
    @Binding var captureResult: WebPageCaptureResult?
    @Binding var pdfResult: WebPagePDFResult?
    @Binding var captureError: String?
    @Binding var showTranslationSheet: Bool
    let onCapture: (WebPageCaptureMode) -> Void
    let onExportPDF: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay(alignment: captureAtTop ? .top : .bottomTrailing) {
                Color.clear.frame(width: 44, height: 44)
                    .allowsHitTesting(false)
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
                        Button(LanguageManager.shared.localizedString("web_capture_pdf")) {
                            onExportPDF()
                        }
                        Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                    } message: {
                        Text(LanguageManager.shared.localizedString("web_capture_full_page_limit_desc"))
                    }
            }
            .sheet(item: $captureResult) { result in
                WebPageCapturePreview(result: result)
            }
            .sheet(item: $pdfResult) { result in
                WebPagePDFPreview(result: result)
            }
            .sheet(isPresented: $showTranslationSheet) {
                WebPageTranslationSheet(
                    webView: webViewModel.webView,
                    pageURL: webViewModel.currentURL,
                    onOpenURL: { url in webViewModel.loadURL(url) },
                    onAppleTranslationApplied: { source, target in
                        webViewModel.enableAppleFollowLinkTranslation(source: source, target: target)
                    },
                    onGoogleTranslationOpened: { target in
                        webViewModel.enableGoogleFollowLinkTranslation(target: target)
                    },
                    onRestore: { webViewModel.disableFollowLinkTranslation() }
                )
                .presentationDetents([.fraction(0.68), .large])
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
                            CountedProgressView(completed: completedCaptureParts, total: totalCaptureParts)
                                .frame(maxWidth: totalCaptureParts > 0 ? 250 : nil)
                                .accessibilityIdentifier("browser.captureProgress")
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

struct BrowserAddressEditorSheet: View {
    let onOpen: (String) -> Void
    let onOpenURL: (URL) -> Void
    let onVoiceInput: () -> Void

    @State private var text: String
    @State private var pageURLText: String
    @State private var didCopyLink = false
    @State private var copyFeedbackID = UUID()
    @FocusState private var pageURLFocused: Bool
    @State private var queryFocused = false
    @State private var queryFocusRequest = 0
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 54
    @Environment(\.dismiss) private var dismiss

    init(
        initialText: String,
        initialURL: String,
        onOpen: @escaping (String) -> Void,
        onOpenURL: @escaping (URL) -> Void,
        onVoiceInput: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.onOpenURL = onOpenURL
        self.onVoiceInput = onVoiceInput
        _text = State(initialValue: initialText)
        _pageURLText = State(initialValue: initialURL)
    }

    private var trimmedQuery: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedPageURL: String { pageURLText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var destinationURL: URL? { ScannedContent(text: trimmedPageURL).webURL }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                querySection
                pageURLSection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityAction(.escape) { dismiss() }
        .onChange(of: pageURLText) { _, _ in
            copyFeedbackID = UUID()
            didCopyLink = false
        }
        .task(id: copyFeedbackID) {
            guard didCopyLink else { return }
            do {
                try await Task.sleep(for: .seconds(1.2))
                withAnimation(.easeInOut(duration: 0.18)) { didCopyLink = false }
            } catch { /* A new copy, edit, or dismissal cancels the old feedback. */ }
        }
    }

    private var querySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("current_keyword")
            HStack(spacing: 2) {
                leadingIcon("magnifyingglass", focused: queryFocused)

                PresentationSearchField(
                    text: $text,
                    placeholder: LanguageManager.shared.localizedString("search_placeholder"),
                    focusRequest: queryFocusRequest,
                    onFocusChanged: { queryFocused = $0 },
                    onSubmit: open
                )
                .frame(minWidth: 40, maxWidth: .infinity, minHeight: 34)
                .accessibilityIdentifier("addressEditor.query")

                if !text.isEmpty {
                    clearButton(label: "accessibility_clear_search", identifier: "addressEditor.clearQuery") {
                        pageURLFocused = false
                        text = ""
                        queryFocusRequest += 1
                    }
                }

                Button {
                    HapticsManager.light()
                    onVoiceInput()
                } label: {
                    Image(systemName: "mic.fill")
                }
                .buttonStyle(AddressEditorIconButtonStyle(tinted: true))
                .accessibilityLabel(LanguageManager.shared.localizedString("voice_record"))
                .accessibilityHint(LanguageManager.shared.localizedString("accessibility_voice_search_hint"))
                .accessibilityIdentifier("addressEditor.voice")

                Button(action: open) {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(AddressEditorIconButtonStyle(prominent: true))
                .disabled(trimmedQuery.isEmpty)
                .accessibilityLabel(LanguageManager.shared.localizedString("search"))
                .accessibilityIdentifier("addressEditor.search")
            }
            .modifier(AddressEditorRowStyle(focused: queryFocused, height: rowHeight))
        }
    }

    private var pageURLSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("current_page_link")
            HStack(spacing: 2) {
                leadingIcon("link", focused: pageURLFocused)

                TextField("https://", text: $pageURLText)
                    .font(.subheadline)
                    .frame(minWidth: 40, maxWidth: .infinity)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($pageURLFocused)
                    .onSubmit(openPageURL)
                    .accessibilityLabel(LanguageManager.shared.localizedString("current_page_link"))
                    .accessibilityIdentifier("addressEditor.pageURL")

                if !pageURLText.isEmpty {
                    clearButton(label: "privacy_clear_action", identifier: "addressEditor.clearPageURL") {
                        pageURLText = ""
                        pageURLFocused = true
                    }
                    .accessibilityValue(LanguageManager.shared.localizedString("current_page_link"))
                }

                Button(action: copyPageURL) {
                    Image(systemName: didCopyLink ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(didCopyLink ? Color.green : Color.secondary)
                }
                .buttonStyle(AddressEditorIconButtonStyle())
                .disabled(trimmedPageURL.isEmpty)
                .accessibilityLabel(LanguageManager.shared.localizedString(didCopyLink ? "copied" : "copy_link"))
                .accessibilityIdentifier("addressEditor.copy")

                Button(action: openPageURL) {
                    Image(systemName: "arrow.up.right")
                }
                .buttonStyle(AddressEditorIconButtonStyle(prominent: true))
                .disabled(trimmedPageURL.isEmpty)
                .disabled(destinationURL == nil)
                .accessibilityLabel(LanguageManager.shared.localizedString("open_directly"))
                .accessibilityIdentifier("addressEditor.openURL")
            }
            .modifier(AddressEditorRowStyle(focused: pageURLFocused, height: rowHeight))
        }
    }

    private func sectionLabel(_ key: String) -> some View {
        Text(LanguageManager.shared.localizedString(key))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }

    private func leadingIcon(_ name: String, focused: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(focused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: 20)
            .accessibilityHidden(true)
    }

    private func clearButton(label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(AddressEditorIconButtonStyle())
        .accessibilityLabel(LanguageManager.shared.localizedString(label))
        .accessibilityIdentifier(identifier)
    }

    private func copyPageURL() {
        guard !trimmedPageURL.isEmpty else { return }
        UIPasteboard.general.string = trimmedPageURL
        HapticsManager.light()
        withAnimation(.easeInOut(duration: 0.18)) { didCopyLink = true }
        copyFeedbackID = UUID()
    }

    private func open() {
        guard !trimmedQuery.isEmpty else { return }
        HapticsManager.selection()
        onOpen(trimmedQuery)
    }

    private func openPageURL() {
        guard let url = destinationURL else { return }
        HapticsManager.selection()
        onOpenURL(url)
    }
}

private struct AddressEditorRowStyle: ViewModifier {
    let focused: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .frame(minHeight: max(54, height))
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(focused ? AnyShapeStyle(.tint.opacity(0.55)) : AnyShapeStyle(Color(uiColor: .separator).opacity(0.25)), lineWidth: 1)
            }
    }
}

private struct AddressEditorIconButtonStyle: ButtonStyle {
    var prominent = false
    var tinted = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .frame(width: AppControlMetrics.iconDiameter, height: AppControlMetrics.iconDiameter)
            .background {
                if prominent { Circle().fill(.tint) }
            }
            .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.3)
    }
}

// MARK: - Load Error

struct BrowserLoadErrorView: View {
    let message: String
    let url: URL?
    let onRetry: () -> Void
    let onGoHome: (() -> Void)?
    let onOpenCompatibility: (() -> Void)?
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                content
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color(UIColor.systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.error")
        .onChange(of: url) { _, _ in copied = false; copyResetTask?.cancel() }
        .onDisappear { copyResetTask?.cancel() }
    }

    // The same native content renders tab covers without an offscreen ScrollView.
    var content: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 27, weight: .regular))
                    .foregroundStyle(Color.themePrimary)
                    .frame(width: 64, height: 64)
                    .background(Color.themePrimary.opacity(0.1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityHidden(true)
                Text(LanguageManager.shared.localizedString("load_error"))
                    .font(.title2.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("browser.error.message")
            }

            if let url {
                VStack(alignment: .leading, spacing: 14) {
                    Text(verbatim: url.absoluteString)
                        .font(.subheadline)
                        .foregroundStyle(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("browser.error.url")
                    Divider()
                    Button { copyAddress(url) } label: {
                        Label(LanguageManager.shared.localizedString(copied ? "link_copied" : "copy_link"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.themePrimary)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .accessibilityIdentifier("browser.error.copy-url")
                }
                .padding(16)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color(uiColor: .separator).opacity(0.18), lineWidth: 0.5))
            }

            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Label(LanguageManager.shared.localizedString("retry"), systemImage: "arrow.clockwise")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Color.themePrimary, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .foregroundStyle(.white)
                }
                .accessibilityIdentifier("browser.error.retry")

                if let onGoHome {
                    Button(action: onGoHome) {
                        Label(LanguageManager.shared.localizedString("home_screen"), systemImage: "house")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("browser.error.home")
                }
                if let onOpenCompatibility {
                    Button(action: onOpenCompatibility) {
                        Label(LanguageManager.shared.localizedString("safari_compatibility_mode"), systemImage: "safari")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.error.compatibility")
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
    }

    private func copyAddress(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        HapticsManager.selection()
        copied = true
        AppAccessibility.announce(LanguageManager.shared.localizedString("link_copied"))
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }
}

// MARK: - Safari Compatibility Mode

@MainActor
private final class SafariCompatibilityPresenter: NSObject, ObservableObject, @preconcurrency SFSafariViewControllerDelegate {
    private weak var presentedController: SFSafariViewController?
    @Published private(set) var isOpening = false
    @Published var failedToOpen = false
    private var presentationTask: Task<Void, Never>?

    deinit { presentationTask?.cancel() }

    func present(url: URL, sourceView: UIView?) {
        guard presentedController == nil, !isOpening else { return }
        isOpening = true
        failedToOpen = false
        presentationTask = Task { [weak self, weak sourceView] in
            guard let self else { return }
            defer { self.isOpening = false }
            // Menu dismissal and keyboard transitions own the presentation stack.
            // Wait for a stable presenter instead of presenting on a disappearing popover.
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if let presenter = self.topViewController(for: sourceView),
                   !presenter.isBeingDismissed, !presenter.isBeingPresented,
                   presenter.transitionCoordinator == nil,
                   presenter.viewIfLoaded?.window != nil,
                   presenter.modalPresentationStyle != .popover {
                    self.show(url, from: presenter)
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            self.failedToOpen = true
        }
    }

    private func show(_ url: URL, from presentingController: UIViewController) {
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

private struct SafariCompatibilityFeedback: ViewModifier {
    @ObservedObject var presenter: SafariCompatibilityPresenter
    func body(content: Content) -> some View {
        content.overlay {
            if presenter.isOpening {
                ProgressView(ToolText.text("safari_opening"))
                    .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .alert(ToolText.text("error"), isPresented: $presenter.failedToOpen) {
            Button(ToolText.text("done"), role: .cancel) {}
        } message: { Text(ToolText.text("safari_open_failed")) }
    }
}

// MARK: - ShareSheet

private struct PageSharePresentation: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

@available(iOS 17.4, *)
final class WebPageShareActivityItem: NSObject, UIActivityItemSource, SFAddToHomeScreenActivityItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        url
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        subjectForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        title
    }
}

/// A preview must never participate in sizing the live page or its toolbar.
struct RestoringPageSnapshot: View {
    let image: UIImage

    var body: some View {
        GeometryReader { geometry in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
