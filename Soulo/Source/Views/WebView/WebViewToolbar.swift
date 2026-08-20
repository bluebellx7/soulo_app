import SwiftUI

private final class DraggableNativeMenuControl: UIButton {
    var onTap: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: ((CGSize) -> Void)?

    private let dragRecognizer = UIPanGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureControl()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureControl()
    }

    private func configureControl() {
        isAccessibilityElement = true
        accessibilityTraits = .button

        var buttonConfiguration: UIButton.Configuration
        if #available(iOS 26.0, *) {
            buttonConfiguration = .glass()
        } else {
            buttonConfiguration = .plain()
            buttonConfiguration.background.backgroundColor = .secondarySystemBackground
            buttonConfiguration.background.cornerRadius = 20
        }
        buttonConfiguration.image = UIImage(systemName: "ellipsis")
        buttonConfiguration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 14,
            weight: .regular
        )
        buttonConfiguration.baseForegroundColor = UIColor.label.withAlphaComponent(0.85)
        buttonConfiguration.contentInsets = .zero
        configuration = buttonConfiguration
        addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        dragRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        dragRecognizer.cancelsTouchesInView = true
        addGestureRecognizer(dragRecognizer)
    }

    @objc private func handleTap() {
        onTap?()
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: superview)
        switch recognizer.state {
        case .began, .changed:
            onDragChanged?(CGSize(width: translation.x, height: translation.y))
        case .ended, .cancelled, .failed:
            onDragEnded?(CGSize(width: translation.x, height: translation.y))
        default:
            break
        }
    }
}

private struct NativeMoreMenuButton: UIViewRepresentable {
    let accessibilityLabel: String
    let onTap: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onDragEnded: (CGSize) -> Void

    func makeUIView(context: Context) -> DraggableNativeMenuControl {
        let control = DraggableNativeMenuControl()
        control.accessibilityLabel = accessibilityLabel
        control.onTap = onTap
        control.onDragChanged = onDragChanged
        control.onDragEnded = onDragEnded
        return control
    }

    func updateUIView(_ control: DraggableNativeMenuControl, context: Context) {
        control.accessibilityLabel = accessibilityLabel
        control.onTap = onTap
        control.onDragChanged = onDragChanged
        control.onDragEnded = onDragEnded
    }
}

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
    @ObservedObject private var extensionService = BrowserExtensionService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true
    @AppStorage(AppConstants.StorageKeys.isIncognito) private var isIncognito = false
    @State private var showSiteInformation = false
    @State private var showZoomControls = false
    @State private var showMoreMenu = false
    @State private var extensionActionRevision = 0

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
    var onInspectResources: (() -> Void)?
    var onTranslatePage: (() -> Void)?
    var onMoreMenuPresentationChange: ((Bool) -> Void)?
    var showsOnlyMore: Bool = false
    var onRestoreToolbar: (() -> Void)?
    var onFloatingMoreDragChanged: ((CGSize) -> Void)?
    var onFloatingMoreDragEnded: ((CGSize) -> Void)?

    @ViewBuilder
    var body: some View {
        if showsOnlyMore {
            moreMenu
        } else if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                toolbarContent
            }
        } else {
            toolbarContent
        }
    }

    private var toolbarContent: some View {
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
                            : Color.primary.opacity(viewModel.currentURL?.host == nil ? 0.25 : 0.68)
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
                .fill(Color.primary.opacity(0.12))
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
                        .foregroundStyle(Color.primary.opacity(0.9))

                    Spacer(minLength: 0)

                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.primary.opacity(0.75))
                    }
                }
                .padding(.leading, 7)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
            .accessibilityValue(fullAddressDisplayText)
            .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_address_hint"))

            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: 0.5, height: 16)
                .accessibilityHidden(true)

            Button {
                guard viewModel.currentURL != nil else { return }
                HapticsManager.light()
                viewModel.reload()
            } label: {
                Image(systemName: viewModel.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(viewModel.currentURL == nil ? 0.24 : 0.72))
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
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 0.5, height: 16)
                    .accessibilityHidden(true)

                Button {
                    performToolbarAction(toolbarConfiguration.addressAction)
                } label: {
                    Image(systemName: toolbarSymbol(for: toolbarConfiguration.addressAction))
                        .font(.system(size: 12, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Color.primary.opacity(0.68))
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
        .browserToolbarCapsuleGlass(tint: toolbarGlassTint)
        .layoutPriority(1)
    }

    private var toolbarGlassTint: Color? {
        isIncognito ? Color.teal.opacity(0.14) : nil
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
        Group {
            if showsOnlyMore,
               let onFloatingMoreDragChanged,
               let onFloatingMoreDragEnded {
                NativeMoreMenuButton(
                    accessibilityLabel: LanguageManager.shared.localizedString("show_more"),
                    onTap: presentMoreMenu,
                    onDragChanged: onFloatingMoreDragChanged,
                    onDragEnded: onFloatingMoreDragEnded
                )
                .frame(width: 40, height: 40)
                .contentShape(Circle())
            } else {
                Button(action: presentMoreMenu) {
                    moreMenuLauncherLabel
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
            }
        }
        .popover(
            isPresented: $showMoreMenu,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            moreMenuPanel
                .presentationCompactAdaptation(.popover)
                .presentationBackground(.ultraThinMaterial)
                .presentationCornerRadius(26)
        }
        .sheet(isPresented: $showZoomControls) {
            persistentZoomPanel
                .presentationDetents([.height(190)])
                .presentationDragIndicator(.visible)
                .presentationBackground(.ultraThinMaterial)
        }
        .onChange(of: showMoreMenu) { _, _ in
            reportMoreMenuPresentationState()
        }
        .onChange(of: showZoomControls) { _, _ in
            reportMoreMenuPresentationState()
        }
    }

    private var moreMenuLauncherLabel: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color.primary.opacity(0.85))
            .frame(width: 40, height: 40)
            .contentShape(Circle())
            .browserToolbarButtonGlass(tint: toolbarGlassTint)
    }

    private var moreMenuPanel: some View {
        VStack(spacing: 0) {
            moreMenuActionRow(
                "settings",
                systemImage: "gearshape"
            ) {
                onOpenSettings?()
            }

            if showsOnlyMore {
                moreMenuActionRow(
                    "restore_browser_toolbar",
                    systemImage: BrowserChromeSymbol.toolbarVisibility
                ) {
                    onRestoreToolbar?()
                }
            } else if onHideToolbar != nil {
                moreMenuActionRow(
                    "hide_browser_toolbar",
                    systemImage: BrowserChromeSymbol.toolbarVisibility
                ) {
                    onHideToolbar?()
                }
            }

            if let tabManager, !tabManager.recentlyClosed.isEmpty {
                moreMenuDivider
                moreMenuActionRow(
                    "tab_restore_last",
                    systemImage: "arrow.uturn.backward",
                    isActive: true
                ) {
                    tabManager.restoreLastClosedTab()
                }
            }

            moreMenuDivider

            if viewModel.currentURL != nil {
                openPageMenu
            }

            pageToolsMenu

            if !webExtensionActionItems.isEmpty {
                moreMenuDivider
                webExtensionActionStrip
            }

            if !viewModel.userScriptMenuCommands.isEmpty {
                userScriptCommandsMenu
            }

            moreMenuDivider
            moreMenuShortcutGrid

            if showsOnlyMore {
                moreMenuDivider
                hiddenToolbarAddressRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
        .onReceive(NotificationCenter.default.publisher(for: .browserExtensionActionsChanged)) { _ in
            extensionActionRevision &+= 1
        }
    }

    private var hiddenToolbarAddressRow: some View {
        let isSecurePage = viewModel.currentURL?.scheme == "https"
        let urlText = viewModel.currentURL?.absoluteString

        return Button {
            performMoreMenuAction {
                onEditAddress?()
            }
        } label: {
            HStack(spacing: 10) {
                Image(
                    systemName: isIncognito
                        ? "eye.slash.fill"
                        : isSecurePage ? "lock.fill" : "globe"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isIncognito ? Color.teal : Color.primary.opacity(0.72))
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(fullAddressDisplayText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let urlText, !urlText.isEmpty {
                        Text(urlText)
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(onEditAddress == nil)
        .opacity(onEditAddress == nil ? 0.35 : 1)
        .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
        .accessibilityValue(urlText ?? fullAddressDisplayText)
        .accessibilityHint(LanguageManager.shared.localizedString("accessibility_edit_address_hint"))
    }

    private var pageToolsMenu: some View {
        Menu {
            if let tabManager, viewModel.currentURL != nil {
                Button {
                    performMoreMenuAction {
                        tabManager.startFindInPage()
                    }
                } label: {
                    menuLabel("find_in_page", systemImage: "doc.text.magnifyingglass")
                }
            }

            if viewModel.currentURL?.host != nil {
                Button {
                    performMoreMenuAction {
                        onShowPrivacy?()
                    }
                } label: {
                    menuLabel(
                        "site_privacy",
                        systemImage: "shield.checkered",
                        isActive: siteProtectionEnabled,
                        activeColor: .systemGreen
                    )
                }

                Button {
                    performMoreMenuAction {
                        onManageAdBlock?()
                    }
                } label: {
                    menuLabel(
                        "ad_block_management",
                        systemImage: "shield.lefthalf.filled",
                        isActive: siteAdBlockingEnabled,
                        activeColor: .systemGreen
                    )
                }
            }

            Divider()

            Button {
                performMoreMenuAction {
                    onShowExtensions?()
                }
            } label: {
                menuLabel(
                    "userscripts",
                    systemImage: "puzzlepiece.extension.fill"
                )
            }
            .disabled(onShowExtensions == nil)

            Button {
                performMoreMenuAction {
                    showZoomControls = true
                }
            } label: {
                menuLabel("web_zoom", systemImage: "plus.magnifyingglass")
            }

            Button {
                performMoreMenuAction {
                    onCapturePage?()
                }
            } label: {
                menuLabel("web_capture", systemImage: "camera.viewfinder")
            }
            .disabled(onCapturePage == nil)

            Button {
                performMoreMenuAction {
                    onInspectResources?()
                }
            } label: {
                menuLabel(
                    "resource_inspector_title",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .disabled(onInspectResources == nil)
        } label: {
            moreMenuRowLabel(
                "browser_page_tools",
                systemImage: "wrench.and.screwdriver",
                showsDisclosure: true
            )
        }
        .buttonStyle(.plain)
        .disabled(viewModel.currentURL == nil)
        .opacity(viewModel.currentURL == nil ? 0.35 : 1)
    }

    private var userScriptCommandsMenu: some View {
        Menu {
            ForEach(viewModel.userScriptMenuCommands) { command in
                Button {
                    performMoreMenuAction {
                        viewModel.executeUserScriptMenuCommand(command)
                    }
                } label: {
                    Label {
                        VStack(alignment: .leading) {
                            Text(command.title)
                            Text(command.scriptName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        menuIcon(
                            "chevron.left.forwardslash.chevron.right",
                            isActive: nil,
                            activeColor: .systemBlue
                        )
                    }
                }
            }
        } label: {
            moreMenuRowLabel(
                "userscript_commands",
                systemImage: "play.square.stack",
                showsDisclosure: true
            )
        }
        .buttonStyle(.plain)
    }

    private var webExtensionActionItems: [(record: WebExtensionRecord, action: WebExtensionActionPresentation)] {
        _ = extensionActionRevision
        return extensionService.webExtensions.compactMap { record in
            guard record.isEnabled,
                  let action = extensionService.webExtensionAction(for: record.id) else { return nil }
            return (record, action)
        }
    }

    private var webExtensionActionStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(webExtensionActionItems, id: \.record.id) { item in
                        Button {
                            performWebExtensionAction(item.record.id)
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                if let icon = item.action.icon {
                                    Image(uiImage: icon)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 18, height: 18)
                                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                } else {
                                    Image(systemName: "puzzlepiece.extension.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, height: 18)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                }

                                if !item.action.badgeText.isEmpty {
                                    Text(item.action.badgeText)
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                        .padding(.horizontal, 3)
                                        .frame(minWidth: 11, minHeight: 11)
                                        .background(.red, in: Capsule())
                                        .offset(x: 5, y: -5)
                                }
                            }
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.action.isEnabled)
                        .opacity(item.action.isEnabled ? 1 : 0.38)
                        .accessibilityLabel(item.action.label)
                        .accessibilityValue(item.action.badgeText)
                        .help(item.action.label)
                    }
                }
                .padding(.leading, 4)
            }
            .scrollIndicators(.hidden)

            Divider()
                .frame(height: 24)

            Button {
                performMoreMenuAction {
                    onShowExtensions?()
                }
            } label: {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onShowExtensions == nil)
            .accessibilityLabel(LanguageManager.shared.localizedString("userscripts"))
        }
        .frame(width: 288, height: 48)
    }

    private var openPageMenu: some View {
        Menu {
            Button {
                performMoreMenuAction {
                    onOpenDefaultBrowser?()
                }
            } label: {
                menuLabel("open_in_default_browser", systemImage: "arrow.up.right.square")
            }

            if WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(
                for: viewModel.currentURL
            ) {
                Button {
                    performMoreMenuAction {
                        onOpenSafariCompatibility?()
                    }
                } label: {
                    menuLabel("safari_compatibility_mode", systemImage: "safari")
                }
            }
        } label: {
            moreMenuRowLabel(
                "browser_open_page",
                systemImage: "safari",
                showsDisclosure: true
            )
        }
        .buttonStyle(.plain)
    }

    private var moreMenuShortcutGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 2) {
            GridRow {
                moreMenuShortcut(
                    "home_screen",
                    systemImage: "house.fill",
                    isEnabled: onGoHome != nil
                ) {
                    onGoHome?()
                }
                moreMenuShortcut(
                    "browser_reload",
                    systemImage: "arrow.clockwise",
                    isEnabled: viewModel.currentURL != nil
                ) {
                    viewModel.reload()
                }
                moreMenuShortcut(
                    "browser_back",
                    systemImage: "chevron.left",
                    isEnabled: viewModel.canGoBack
                ) {
                    viewModel.goBack()
                }
                moreMenuShortcut(
                    "browser_forward",
                    systemImage: "chevron.right",
                    isEnabled: viewModel.canGoForward
                ) {
                    viewModel.goForward()
                }
            }

            GridRow {
                moreMenuShortcut(
                    isFullscreen ? "exit_fullscreen" : "enter_fullscreen",
                    systemImage: isFullscreen
                        ? "arrow.down.right.and.arrow.up.left"
                        : "arrow.up.left.and.arrow.down.right",
                    isEnabled: viewModel.currentURL != nil && onToggleFullscreen != nil,
                    isActive: isFullscreen
                ) {
                    onToggleFullscreen?()
                }
                moreMenuShortcut(
                    "desktop_mode",
                    systemImage: "desktopcomputer",
                    isEnabled: viewModel.currentURL != nil && tabManager != nil,
                    isActive: tabManager?.isDesktopMode ?? false
                ) {
                    tabManager?.toggleDesktopMode()
                }
                moreMenuShortcut(
                    "web_force_dark_short",
                    systemImage: webAppearance.forceDarkPages ? "moon.fill" : "moon",
                    isEnabled: viewModel.currentURL != nil,
                    isActive: webAppearance.forceDarkPages
                ) {
                    webAppearance.toggleForceDarkPages()
                    if let webView = viewModel.webView {
                        webAppearance.apply(to: webView)
                    }
                }
                moreMenuShortcut(
                    "browser_tabs",
                    systemImage: "square.on.square",
                    isEnabled: tabManager != nil
                ) {
                    guard let tabManager else { return }
                    tabManager.refreshSnapshotsForSwitcher()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        tabManager.showTabOverview = true
                    }
                }
            }

            GridRow {
                moreMenuShortcut(
                    "share",
                    systemImage: "square.and.arrow.up",
                    isEnabled: viewModel.currentURL != nil && onShare != nil
                ) {
                    onShare?()
                }
                moreMenuShortcut(
                    "copy_link",
                    systemImage: "doc.on.doc",
                    isEnabled: viewModel.currentURL != nil
                ) {
                    guard let url = viewModel.currentURL else { return }
                    UIPasteboard.general.url = url
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NotificationCenter.default.post(name: .linkCopied, object: nil)
                }
                moreMenuShortcut(
                    "bookmarks",
                    systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                    isEnabled: viewModel.currentURL != nil && onBookmarkToggle != nil,
                    isActive: isBookmarked,
                    activeColor: .systemOrange
                ) {
                    onBookmarkToggle?()
                }
                moreMenuShortcut(
                    "library",
                    systemImage: "books.vertical",
                    isEnabled: onShowLibrary != nil
                ) {
                    onShowLibrary?()
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func moreMenuActionRow(
        _ titleKey: String,
        systemImage: String,
        isEnabled: Bool = true,
        isActive: Bool = false,
        activeColor: UIColor = .systemBlue,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            performMoreMenuAction(action)
        } label: {
            moreMenuRowLabel(
                titleKey,
                systemImage: systemImage,
                isActive: isActive,
                activeColor: activeColor
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
    }

    private func moreMenuRowLabel(
        _ titleKey: String,
        systemImage: String,
        showsDisclosure: Bool = false,
        isActive: Bool = false,
        activeColor: UIColor = .systemBlue
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isActive ? Color(uiColor: activeColor) : Color.primary)
                .frame(width: 28, height: 28)

            Text(LanguageManager.shared.localizedString(titleKey))
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 43)
        .contentShape(Rectangle())
    }

    private func moreMenuShortcut(
        _ titleKey: String,
        systemImage: String,
        isEnabled: Bool = true,
        isActive: Bool = false,
        activeColor: UIColor = .systemBlue,
        action: @escaping () -> Void
    ) -> some View {
        let title = LanguageManager.shared.localizedString(titleKey)
        return Button {
            performMoreMenuAction(action)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(isActive ? Color(uiColor: activeColor) : Color.primary)
                    .frame(height: 23)

                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 74)
            .frame(minHeight: 57)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(
            isActive
                ? LanguageManager.shared.localizedString("accessibility_enabled")
                : ""
        )
    }

    private var moreMenuDivider: some View {
        Divider()
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
    }

    private func presentMoreMenu() {
        HapticsManager.light()
        showMoreMenu = true
    }

    private func performMoreMenuAction(_ action: @escaping () -> Void) {
        showMoreMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            action()
        }
    }

    private func performWebExtensionAction(_ id: UUID) {
        showMoreMenu = false
        // Let the native More popover finish dismissing before an extension presents its popup.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            extensionService.performWebExtensionAction(id)
        }
    }

    private func reportMoreMenuPresentationState() {
        onMoreMenuPresentationChange?(showMoreMenu || showZoomControls)
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
                TabCountBadge(count: tabManager.tabCount, glassTint: toolbarGlassTint) {
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
                    !enabled ? Color.primary.opacity(0.35) :
                    tint ?? Color.primary.opacity(0.85)
                )
                .frame(width: 40, height: 40)
                .contentShape(Circle())
                .browserToolbarButtonGlass(tint: toolbarGlassTint)
        }
        .disabled(!enabled)
        .accessibilityLabel(LanguageManager.shared.localizedString(labelKey))
    }
}
