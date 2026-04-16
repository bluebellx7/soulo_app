import SwiftUI
import SwiftData

struct WebViewContainer: View {
    @ObservedObject var webViewModel: WebViewModel
    @ObservedObject var bookmarkViewModel: BookmarkViewModel
    @Binding var isFullscreen: Bool
    var tabManager: TabManager? = nil
    var isActiveTab: Bool = true
    var onPageLoaded: (() -> Void)? = nil
    @Environment(\.modelContext) private var modelContext

    @State private var isBookmarked: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var shareItems: [Any] = []
    @State private var showExternalConfirm: Bool = false
    @State private var showBookmarkToast: Bool = false
    @State private var externalURL: URL? = nil
    @State private var externalDismissTask: DispatchWorkItem? = nil
    @State private var showNewTabPage: Bool = true
    @State private var toolbarMinimized: Bool = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                // Find in Page bar (only on active tab)
                if isActiveTab, let tm = tabManager, tm.showFindInPage {
                    FindInPageBar(tabManager: tm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                WebViewProgressBar(
                    progress: webViewModel.estimatedProgress,
                    isLoading: webViewModel.isLoading
                )
                if !isFullscreen {
                    Rectangle()
                        .fill(Color(UIColor.separator).opacity(0.2))
                        .frame(height: 0.5)
                }

                ZStack {
                    WebViewRepresentable(viewModel: webViewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // New Tab Page overlay
                    if showNewTabPage && webViewModel.currentURL == nil && !webViewModel.isLoading {
                        NewTabPageView(tabManager: tabManager) { url in
                            webViewModel.loadURL(url)
                        }
                        .transition(.opacity)
                    }
                }
            }

            // Floating toolbar (only on active tab)
            if isActiveTab {
                VStack(spacing: 0) {
                    Spacer()
                    if toolbarMinimized {
                        // Mini pill — domain + tab count
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
                            onBookmarkToggle: { handleBookmarkToggle() }
                        )
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.8).combined(with: .opacity)
                        ))
                    }
                }
                .padding(.bottom, 16)
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: toolbarMinimized)
            }

            // Toast overlays
            if showBookmarkToast {
                toastView(
                    icon: isBookmarked ? "bookmark.fill" : "bookmark.slash",
                    text: LanguageManager.shared.localizedString(isBookmarked ? "bookmark_added" : "bookmark_removed")
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
                                Text(extURL.host ?? extURL.absoluteString)
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
                                UIApplication.shared.open(extURL)
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
                    .padding(.bottom, 72)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                            Text(webViewModel.downloadFileName)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.bottom, 72)
                }
                .allowsHitTesting(false)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: webViewModel.isScrollingUp) { _, scrollingUp in
            if isActiveTab {
                isFullscreen = scrollingUp
                // Minimize toolbar when scrolling down to read
                if scrollingUp && !toolbarMinimized {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        toolbarMinimized = true
                    }
                } else if !scrollingUp && toolbarMinimized {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        toolbarMinimized = false
                    }
                }
            }
        }
        .onChange(of: webViewModel.isLoading) { _, loading in
            if !loading { onPageLoaded?() }
        }
        .onChange(of: webViewModel.currentURL) { _, url in
            syncBookmarkState(for: url)
            if url != nil {
                withAnimation(.easeOut(duration: 0.2)) { showNewTabPage = false }
            }
        }
        // Scoped notifications — only process when this is the active tab
        .onReceive(NotificationCenter.default.publisher(for: .webViewExternalURLRequest)) { notification in
            guard isActiveTab else { return }
            if let url = notification.userInfo?["url"] as? URL {
                externalURL = url
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    showExternalConfirm = true
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                // Auto-dismiss after 4 seconds
                externalDismissTask?.cancel()
                externalDismissTask = DispatchWorkItem { [self] in
                    withAnimation { showExternalConfirm = false }
                }
                if let task = externalDismissTask {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: task)
                }
            }
        }
        // Link & image long-press handled by native WKUIDelegate context menus
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    // MARK: - Toast

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
            .padding(.bottom, 72)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Mini Toolbar Pill

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
            .background(
                Capsule()
                    .fill(.black.opacity(0.45))
                    .overlay(Capsule().stroke(.white.opacity(0.1), lineWidth: 0.5))
            )
            .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
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

            Button { tabManager.findNext() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tabManager.findMatchCount > 0 ? .primary : .tertiary)
            }
            .disabled(tabManager.findMatchCount == 0)

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
