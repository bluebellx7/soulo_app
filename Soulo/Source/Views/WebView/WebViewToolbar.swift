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
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled: Bool = true

    var tabManager: TabManager?
    var onShare: (() -> Void)?
    var onBookmarkToggle: (() -> Void)?
    var onShowPrivacy: (() -> Void)?
    var onManageAdBlock: (() -> Void)?
    var onShowDownloads: (() -> Void)?
    var onGoHome: (() -> Void)?
    var onEditAddress: (() -> Void)?
    var onHideToolbar: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var isFullscreen: Bool = false
    var onToggleFullscreen: (() -> Void)?
    var onOpenSafariCompatibility: (() -> Void)?
    var onOpenDefaultBrowser: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            btn("house.fill", labelKey: "home_screen", enabled: onGoHome != nil) { onGoHome?() }
            btn("chevron.left", labelKey: "browser_back", enabled: viewModel.canGoBack) { viewModel.goBack() }

            addressControl

            btn(
                viewModel.isLoading ? "xmark" : "arrow.clockwise",
                labelKey: viewModel.isLoading ? "voice_stop" : "browser_reload",
                enabled: viewModel.currentURL != nil
            ) { viewModel.reload() }

            // Tab count button
            if let tabManager = tabManager {
                TabCountBadge(count: tabManager.tabCount) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    tabManager.refreshSnapshotsForSwitcher()
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        tabManager.showTabOverview = true
                    }
                }
            }

            // Keep the overflow menu at the trailing edge, matching common
            // browser toolbar placement and making its position predictable.
            moreMenu
        }
        .padding(.horizontal, 10)
    }

    private var addressControl: some View {
        HStack(spacing: 0) {
            Button {
                HapticsManager.light()
                onEditAddress?()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: viewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))

                    ViewThatFits(in: .horizontal) {
                        compactAddressText(maximumKeywordLength: 6)
                        compactAddressText(maximumKeywordLength: 4)
                        compactAddressText(maximumKeywordLength: 2)

                        Text(displayHost)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))

                    Spacer(minLength: 0)

                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.white.opacity(0.75))
                    }
                }
                .padding(.leading, 8)
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
                .fill(.white.opacity(0.12))
                .frame(width: 0.5, height: 16)
                .accessibilityHidden(true)

            Button {
                onHideToolbar?()
            } label: {
                Image(systemName: BrowserChromeSymbol.toolbarVisibility)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(width: 27, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("hide_browser_toolbar"))
        }
        .frame(minWidth: 80, maxWidth: 150, minHeight: 32)
        .background(
            Capsule()
                .fill(.black.opacity(0.4))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
        )
        .frame(minHeight: 40)
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
            && siteProtectionEnabled
            && !adBlockSettings.isAllowlisted(viewModel.currentURL?.host)
    }

    private var hasDownloads: Bool {
        viewModel.isDownloading || !downloadManager.downloads.isEmpty
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
            if viewModel.canGoForward {
                Button {
                    viewModel.goForward()
                } label: {
                    menuLabel("browser_forward", systemImage: "chevron.right")
                }
            }

            // Share
            if viewModel.currentURL != nil {
                Button {
                    onShare?()
                } label: {
                    menuLabel("share", systemImage: "square.and.arrow.up")
                }
            }

            // Copy Link
            if let url = viewModel.currentURL {
                Button {
                    UIPasteboard.general.url = url
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NotificationCenter.default.post(name: .linkCopied, object: nil)
                } label: {
                    menuLabel("copy_link", systemImage: "doc.on.doc")
                }
            }

            // Keep bookmark with the other page-saving/link actions.
            if viewModel.currentURL != nil {
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

            if viewModel.currentURL != nil {
                Divider()

                if WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(for: viewModel.currentURL) {
                    Button {
                        onOpenSafariCompatibility?()
                    } label: {
                        menuLabel("safari_compatibility_mode", systemImage: "safari")
                    }

                    Button {
                        onOpenDefaultBrowser?()
                    } label: {
                        menuLabel("open_in_default_browser", systemImage: "arrow.up.right.square")
                    }
                }

                // Desktop mode belongs with the browser-opening/mode actions.
                if let tabManager = tabManager {
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
            }

            Divider()

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
            }

            // SwiftUI presents this upward-opening menu in reverse visual order.
            // Keep ad management first in the builder so Find in Page appears
            // immediately above it on screen.
            if viewModel.currentURL?.host != nil {
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

            if let tabManager = tabManager, viewModel.currentURL != nil {
                Button {
                    tabManager.startFindInPage()
                } label: {
                    menuLabel("find_in_page", systemImage: "doc.text.magnifyingglass")
                }
            }

            Button {
                onShowDownloads?()
            } label: {
                menuLabel("downloads", systemImage: "arrow.down.circle", isActive: hasDownloads)
            }

            if viewModel.currentURL != nil {
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
            }

            Divider()

            // New Tab
            if let tabManager = tabManager {
                Button {
                    tabManager.createTab()
                } label: {
                    menuLabel("tab_new_tab", systemImage: "plus.square")
                }

                // Restore Last Closed
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

            // The menu opens upward, so the final builder item is presented at
            // the visual top. Keep Settings easy to reach and separate from
            // tab-management actions.
            Button {
                onOpenSettings?()
            } label: {
                menuLabel("settings", systemImage: "gearshape")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                )
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
    }

    // MARK: - Button

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
                    !enabled ? .white.opacity(0.35) :
                    tint ?? .white.opacity(0.85)
                )
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                )
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .disabled(!enabled)
        .accessibilityLabel(LanguageManager.shared.localizedString(labelKey))
    }
}
