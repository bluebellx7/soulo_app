import SwiftUI

enum BrowserAddressDisplay {
    static func text(keyword: String?, host: String, maximumKeywordLength: Int) -> String {
        guard maximumKeywordLength > 0,
              let keyword = normalizedKeyword(keyword) else {
            return host
        }
        let prefix = String(keyword.prefix(maximumKeywordLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return host }
        return "\(prefix)/\(host)"
    }

    static func fullText(keyword: String?, host: String) -> String {
        guard let keyword = normalizedKeyword(keyword) else { return host }
        return "\(keyword)/\(host)"
    }

    private static func normalizedKeyword(_ value: String?) -> String? {
        let normalized = (value ?? "")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard !normalized.isEmpty, !normalized.isValidURL else { return nil }
        return normalized
    }
}

struct WebViewToolbar: View {
    @ObservedObject var viewModel: WebViewModel
    @Binding var isBookmarked: Bool
    @ObservedObject private var privacyService = PrivacyProtectionService.shared
    @ObservedObject private var adBlockSettings = AdBlockSettingsService.shared
    @ObservedObject private var webAppearance = WebAppearanceService.shared
    @ObservedObject private var toolbarConfiguration = BrowserToolbarConfigurationService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true
    @AppStorage(AppConstants.StorageKeys.isIncognito) private var isIncognito = false
    @State private var showSiteInformation = false
    @State private var showZoomControls = false

    var tabManager: TabManager?
    var onShare: (() -> Void)?
    var onBookmarkToggle: (() -> Void)?
    var onShowPrivacy: (() -> Void)?
    var onSetPrivateMode: ((Bool) -> Void)?
    var onManageAdBlock: (() -> Void)?
    var onShowLibrary: (() -> Void)?
    var onShowExtensions: (() -> Void)?
    var onGoHome: (() -> Void)?
    var onEditAddress: (() -> Void)?
    var onHideToolbar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var isFullscreen: Bool = false
    var onToggleFullscreen: (() -> Void)?
    var onOpenSafariCompatibility: (() -> Void)?
    var onOpenDefaultBrowser: (() -> Void)?
    var onCapturePage: (() -> Void)?
    var onTranslatePage: (() -> Void)?
    var onMoreMenuPresentationChange: ((Bool) -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            if toolbarConfiguration.actions[0] != .none {
                toolbarAction(toolbarConfiguration.actions[0])
            }
            if toolbarConfiguration.actions[1] != .none {
                toolbarAction(toolbarConfiguration.actions[1])
            }

            addressControl

            if toolbarConfiguration.actions[2] != .none {
                toolbarAction(toolbarConfiguration.actions[2])
            }
            if toolbarConfiguration.actions[3] != .none {
                toolbarAction(toolbarConfiguration.actions[3])
            }
        }
        .padding(.horizontal, 10)
    }

    private var addressControl: some View {
        HStack(spacing: 0) {
            Button {
                guard viewModel.currentURL?.host != nil else { return }
                HapticsManager.light()
                showSiteInformation.toggle()
            } label: {
                Image(systemName: isIncognito
                    ? "eye.slash.fill"
                    : viewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe"
                )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        isIncognito
                            ? Color.teal.opacity(0.9)
                            : Color.white.opacity(viewModel.currentURL?.host == nil ? 0.25 : 0.68)
                    )
                    .frame(width: 27, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentURL?.host == nil)
            .accessibilityLabel(
                LanguageManager.shared.localizedString(
                    isIncognito ? "privacy_incognito" : "site_information"
                )
            )
            .popover(
                isPresented: $showSiteInformation,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                SiteInformationPopoverView(
                    currentURL: viewModel.currentURL,
                    isPrivateMode: isIncognito,
                    onSetPrivateMode: { enabled in
                        showSiteInformation = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            onSetPrivateMode?(enabled)
                        }
                    },
                    onReload: {
                        viewModel.retryCurrentPage()
                    },
                    onShowDetails: {
                        showSiteInformation = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                            onShowPrivacy?()
                        }
                    }
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 0.5, height: 16)
                .accessibilityHidden(true)

            Button {
                HapticsManager.light()
                onEditAddress?()
            } label: {
                HStack(spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        compactAddressText(maximumKeywordLength: 6)
                        compactAddressText(maximumKeywordLength: 4)
                        compactAddressText(maximumKeywordLength: 2)

                        Text(displayHost)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))

                    Spacer(minLength: 0)

                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.white.opacity(0.75))
                    }
                }
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
            .accessibilityValue(fullAddressDisplayText)
            .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_address_hint"))
            .contextMenu {
                if let url = viewModel.currentURL {
                    Button {
                        UIPasteboard.general.url = url
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        NotificationCenter.default.post(name: .linkCopied, object: nil)
                    } label: {
                        Label(LanguageManager.shared.localizedString("copy_link"), systemImage: "doc.on.doc")
                    }
                }
            }

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 0.5, height: 16)
                .accessibilityHidden(true)

            Button {
                guard viewModel.currentURL != nil else { return }
                HapticsManager.light()
                viewModel.reload()
            } label: {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(viewModel.currentURL == nil ? 0.24 : 0.72))
                    .frame(width: 29, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.currentURL == nil)
            .accessibilityLabel(
                LanguageManager.shared.localizedString(
                    viewModel.isLoading ? "voice_stop" : "browser_reload"
                )
            )

            if toolbarConfiguration.addressAction != .none {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 0.5, height: 16)
                    .accessibilityHidden(true)

                Button {
                    performToolbarAction(toolbarConfiguration.addressAction)
                } label: {
                    Image(systemName: toolbarSymbol(for: toolbarConfiguration.addressAction))
                        .font(.system(size: 12, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .frame(width: 27, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isToolbarActionEnabled(toolbarConfiguration.addressAction))
                .accessibilityLabel(
                    LanguageManager.shared.localizedString(toolbarConfiguration.addressAction.titleKey)
                )
            }
        }
        .frame(minWidth: 120, maxWidth: 190, minHeight: 32)
        .frame(minHeight: 40)
        .browserToolbarCapsuleGlass()
        .shadow(color: .black.opacity(0.13), radius: 7, y: 3)
        .layoutPriority(1)
    }

    private var displayHost: String {
        guard let host = viewModel.currentURL?.host else {
            return LanguageManager.shared.localizedString("tab_new_tab")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var displayKeyword: String? {
        tabManager?.activeTab?.keyword
    }

    private var fullAddressDisplayText: String {
        BrowserAddressDisplay.fullText(keyword: displayKeyword, host: displayHost)
    }

    private func compactAddressText(maximumKeywordLength: Int) -> some View {
        Text(
            BrowserAddressDisplay.text(
                keyword: displayKeyword,
                host: displayHost,
                maximumKeywordLength: maximumKeywordLength
            )
        )
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - More Actions Menu

    private var siteProtectionEnabled: Bool {
        guard viewModel.currentURL?.host != nil else { return false }
        return !privacyService.isProtectionDisabled(for: viewModel.currentURL?.host)
            && !WebCompatibilityService.shouldBypassWebProtection(for: viewModel.currentURL)
    }

    private var siteAdBlockingEnabled: Bool {
        adBlockEnabled
            && !adBlockSettings.isAllowlisted(viewModel.currentURL?.host)
            && !WebCompatibilityService.shouldBypassWebProtection(for: viewModel.currentURL)
    }

    private func menuLabel(
        _ key: String,
        systemImage: String,
        isActive: Bool? = nil,
        activeColor: UIColor = .systemBlue
    ) -> some View {
        Label {
            Text(LanguageManager.shared.localizedString(key))
                .foregroundStyle(.primary)
        } icon: {
            menuIcon(systemImage, isActive: isActive, activeColor: activeColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            isActive.map {
                LanguageManager.shared.localizedString(
                    $0 ? "accessibility_enabled" : "accessibility_disabled"
                )
            } ?? ""
        )
    }

    private func menuIcon(
        _ systemName: String,
        isActive: Bool?,
        activeColor: UIColor
    ) -> Image {
        let color: UIColor
        switch isActive {
        case true:
            color = activeColor
        case false:
            color = .label
        case nil:
            color = .label
        }

        guard let image = UIImage(systemName: systemName)?.withTintColor(
            color,
            renderingMode: .alwaysOriginal
        ) else {
            return Image(systemName: systemName)
        }
        return Image(uiImage: image)
    }

    private var moreMenu: some View {
        Menu {
            // This menu opens upward, so builder order is the reverse of its
            // visual order. Keep the compact page actions at the visual bottom.
            if let url = viewModel.currentURL {
                ControlGroup {
                    Button {
                        onShare?()
                    } label: {
                        menuLabel("share", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        UIPasteboard.general.url = url
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        NotificationCenter.default.post(name: .linkCopied, object: nil)
                    } label: {
                        menuLabel("copy_link", systemImage: "doc.on.doc")
                    }

                    Button {
                        onBookmarkToggle?()
                    } label: {
                        menuLabel(
                            "bookmarks",
                            systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                            isActive: isBookmarked,
                            activeColor: .systemOrange
                        )
                    }
                }
            }

            Divider()

            if viewModel.currentURL != nil {
                ControlGroup {
                    Button {
                        onToggleFullscreen?()
                    } label: {
                        menuLabel(
                            isFullscreen ? "exit_fullscreen" : "enter_fullscreen",
                            systemImage: isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                            isActive: isFullscreen
                        )
                    }

                    if let tabManager {
                        Button {
                            tabManager.toggleDesktopMode()
                        } label: {
                            menuLabel(
                                "desktop_mode",
                                systemImage: "desktopcomputer",
                                isActive: tabManager.isDesktopMode
                            )
                        }
                    }

                    Button {
                        webAppearance.toggleForceDarkPages()
                        if let webView = viewModel.webView {
                            webAppearance.apply(to: webView)
                        }
                    } label: {
                        menuLabel(
                            "web_force_dark_short",
                            systemImage: "moon.fill",
                            isActive: webAppearance.forceDarkPages
                        )
                    }
                }
            }

            ControlGroup {
                Button {
                    onGoHome?()
                } label: {
                    menuLabel("home_screen", systemImage: "house.fill")
                }

                if let tabManager {
                    Button {
                        tabManager.createTab()
                    } label: {
                        menuLabel("tab_new_tab", systemImage: "plus.square")
                    }
                }

                Button {
                    onShowLibrary?()
                } label: {
                    menuLabel("library", systemImage: "books.vertical")
                }
            }

            if viewModel.currentURL != nil {
                Menu {
                    Button {
                        onOpenDefaultBrowser?()
                    } label: {
                        menuLabel("open_in_default_browser", systemImage: "arrow.up.right.square")
                    }

                    if WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(for: viewModel.currentURL) {
                        Button {
                            onOpenSafariCompatibility?()
                        } label: {
                            menuLabel("safari_compatibility_mode", systemImage: "safari")
                        }
                    }
                } label: {
                    menuLabel("browser_open_page", systemImage: "safari")
                }
            }

            Button {
                onShowExtensions?()
            } label: {
                menuLabel("userscripts", systemImage: "chevron.left.forwardslash.chevron.right")
            }

            Menu {
                if viewModel.currentURL != nil {
                    Button {
                        onCapturePage?()
                    } label: {
                        menuLabel("web_capture", systemImage: "camera.viewfinder")
                    }

                    // Page translation is intentionally hidden in 1.1.0. Keep
                    // the implementation for the next version's compatibility work.

                    Button {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                            showZoomControls = true
                        }
                    } label: {
                        Label {
                            Text(
                                "\(LanguageManager.shared.localizedString("web_zoom")) · "
                                    + "\(Int((viewModel.pageZoom * 100).rounded()))%"
                            )
                        } icon: {
                            menuIcon("plus.magnifyingglass", isActive: nil, activeColor: .label)
                        }
                    }
                }

                if viewModel.canGoForward {
                    Button {
                        viewModel.goForward()
                    } label: {
                        menuLabel("browser_forward", systemImage: "chevron.right")
                    }
                }

                if let tabManager = tabManager, viewModel.currentURL != nil {
                    Button {
                        tabManager.startFindInPage()
                    } label: {
                        menuLabel("find_in_page", systemImage: "doc.text.magnifyingglass")
                    }
                }

                if viewModel.currentURL?.host != nil {
                    Button {
                        onShowPrivacy?()
                    } label: {
                        menuLabel(
                            "site_privacy",
                            systemImage: "shield.checkered",
                            isActive: siteProtectionEnabled,
                            activeColor: .systemGreen
                        )
                    }

                    Button {
                        onManageAdBlock?()
                    } label: {
                        menuLabel(
                            "ad_block_management",
                            systemImage: "shield.lefthalf.filled",
                            isActive: siteAdBlockingEnabled,
                            activeColor: .systemGreen
                        )
                    }
                }
            } label: {
                menuLabel("browser_page_tools", systemImage: "wrench.and.screwdriver")
            }

            Divider()

            if let tabManager = tabManager {
                if !tabManager.recentlyClosed.isEmpty {
                    Button {
                        tabManager.restoreLastClosedTab()
                    } label: {
                        menuLabel(
                            "tab_restore_last",
                            systemImage: "arrow.uturn.backward",
                            isActive: true
                        )
                    }
                }
            }

            Divider()

            Button {
                onOpenSettings?()
            } label: {
                menuLabel("settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .browserToolbarButtonGlass()
                .shadow(color: .black.opacity(0.13), radius: 7, y: 3)
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
        .simultaneousGesture(
            TapGesture().onEnded {
                onMoreMenuPresentationChange?(true)
            }
        )
        .sheet(isPresented: $showZoomControls) {
            persistentZoomPanel
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: showZoomControls) { _, isPresented in
            onMoreMenuPresentationChange?(isPresented)
        }
    }

    private var persistentZoomPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    LanguageManager.shared.localizedString("web_zoom"),
                    systemImage: "plus.magnifyingglass"
                )
                .font(.headline)
                Spacer()
                Text("50%–200%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    showZoomControls = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("done"))
            }

            HStack(spacing: 10) {
                zoomPanelButton(
                    systemImage: "minus",
                    accessibilityKey: "web_zoom_out",
                    enabled: viewModel.pageZoom > 0.5
                ) {
                    viewModel.decreasePageZoom()
                }

                Button {
                    viewModel.resetPageZoom()
                } label: {
                    Text("\(Int((viewModel.pageZoom * 100).rounded()))%")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("web_zoom_reset"))

                zoomPanelButton(
                    systemImage: "plus",
                    accessibilityKey: "web_zoom_in",
                    enabled: viewModel.pageZoom < 2
                ) {
                    viewModel.increasePageZoom()
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 420)
    }

    private func zoomPanelButton(
        systemImage: String,
        accessibilityKey: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 46, height: 44)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(LanguageManager.shared.localizedString(accessibilityKey))
    }

    // MARK: - Button

    @ViewBuilder
    private func toolbarAction(_ action: BrowserToolbarAction) -> some View {
        switch action {
        case .none:
            EmptyView()
        case .tabs:
            if let tabManager {
                TabCountBadge(count: tabManager.tabCount) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    tabManager.refreshSnapshotsForSwitcher()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        tabManager.showTabOverview = true
                    }
                }
            } else {
                btn(action.systemImage, labelKey: action.titleKey, enabled: false) {}
            }
        case .more:
            moreMenu
        default:
            btn(
                toolbarSymbol(for: action),
                labelKey: action.titleKey,
                enabled: isToolbarActionEnabled(action),
                tint: toolbarTint(for: action)
            ) {
                performToolbarAction(action)
            }
        }
    }

    private func toolbarSymbol(for action: BrowserToolbarAction) -> String {
        switch action {
        case .bookmark: isBookmarked ? "bookmark.fill" : "bookmark"
        case .fullscreen: isFullscreen ? "arrow.down.right.and.arrow.up.left" : action.systemImage
        case .desktopMode: tabManager?.isDesktopMode == true ? "desktopcomputer.and.macbook" : action.systemImage
        case .darkMode: webAppearance.forceDarkPages ? "moon.fill" : "moon"
        default: action.systemImage
        }
    }

    private func toolbarTint(for action: BrowserToolbarAction) -> Color? {
        switch action {
        case .bookmark where isBookmarked: .orange
        case .darkMode where webAppearance.forceDarkPages: .blue
        case .desktopMode where tabManager?.isDesktopMode == true: .blue
        default: nil
        }
    }

    private func isToolbarActionEnabled(_ action: BrowserToolbarAction) -> Bool {
        if action.requiresPage && viewModel.currentURL == nil { return false }
        return switch action {
        case .none: true
        case .home: onGoHome != nil
        case .back: viewModel.canGoBack
        case .forward: viewModel.canGoForward
        case .share: onShare != nil
        case .bookmark: onBookmarkToggle != nil
        case .fullscreen: onToggleFullscreen != nil
        case .desktopMode: tabManager != nil
        case .settings: onOpenSettings != nil
        case .extensions: onShowExtensions != nil
        case .library: onShowLibrary != nil
        case .hideToolbar: onHideToolbar != nil
        case .screenshot: onCapturePage != nil
        case .translate: false // Temporarily hidden until the next version.
        default: true
        }
    }

    private func performToolbarAction(_ action: BrowserToolbarAction) {
        guard isToolbarActionEnabled(action) else { return }
        switch action {
        case .none:
            break
        case .home:
            onGoHome?()
        case .back:
            viewModel.goBack()
        case .forward:
            viewModel.goForward()
        case .tabs, .more:
            break
        case .share:
            onShare?()
        case .bookmark:
            onBookmarkToggle?()
        case .copyLink:
            guard let url = viewModel.currentURL else { return }
            UIPasteboard.general.url = url
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            NotificationCenter.default.post(name: .linkCopied, object: nil)
        case .fullscreen:
            onToggleFullscreen?()
        case .desktopMode:
            tabManager?.toggleDesktopMode()
        case .darkMode:
            webAppearance.toggleForceDarkPages()
            if let webView = viewModel.webView { webAppearance.apply(to: webView) }
        case .settings:
            onOpenSettings?()
        case .extensions:
            onShowExtensions?()
        case .library:
            onShowLibrary?()
        case .reload:
            viewModel.reload()
        case .hideToolbar:
            onHideToolbar?()
        case .screenshot:
            onCapturePage?()
        case .translate:
            break // Temporarily hidden; retained to decode saved toolbar layouts.
        }
    }

    private func btn(
        _ icon: String,
        labelKey: String,
        enabled: Bool,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard enabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(
                    !enabled ? Color.white.opacity(0.35) :
                    tint ?? Color.white.opacity(0.85)
                )
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .browserToolbarButtonGlass()
                .shadow(color: .black.opacity(0.13), radius: 7, y: 3)
        }
        .disabled(!enabled)
        .accessibilityLabel(LanguageManager.shared.localizedString(labelKey))
    }
}
