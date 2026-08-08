import SwiftUI

struct WebViewToolbar: View {
    @ObservedObject var viewModel: WebViewModel
    @Binding var isBookmarked: Bool

    var tabManager: TabManager?
    var onShare: (() -> Void)?
    var onBookmarkToggle: (() -> Void)?
    var onShowPrivacy: (() -> Void)?
    var onManageAdBlock: (() -> Void)?
    var onShowDownloads: (() -> Void)?
    var onFireButton: (() -> Void)?
    var onGoHome: (() -> Void)?
    var onEditAddress: (() -> Void)?
    var onOpenSafariCompatibility: (() -> Void)?
    var onOpenDefaultBrowser: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            btn("house.fill", labelKey: "home_screen", enabled: onGoHome != nil) { onGoHome?() }
            btn("chevron.left", labelKey: "browser_back", enabled: viewModel.canGoBack) { viewModel.goBack() }

            addressButton

            btn(
                viewModel.isLoading ? "xmark" : "arrow.clockwise",
                labelKey: viewModel.isLoading ? "voice_stop" : "browser_reload",
                enabled: viewModel.currentURL != nil
            ) { viewModel.reload() }

            // More actions menu
            moreMenu

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
        }
        .padding(.horizontal, 10)
    }

    private var addressButton: some View {
        Button {
            HapticsManager.light()
            onEditAddress?()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))

                Text(displayHost)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.75))
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: 144, minHeight: 32)
            .background(
                Capsule()
                    .fill(.black.opacity(0.4))
                    .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
            )
            .frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("browser_edit_address"))
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
    }

    private var displayHost: String {
        guard let host = viewModel.currentURL?.host else {
            return LanguageManager.shared.localizedString("tab_new_tab")
        }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - More Actions Menu

    private var moreMenu: some View {
        Menu {
            if viewModel.canGoForward {
                Button {
                    viewModel.goForward()
                } label: {
                    Label(LanguageManager.shared.localizedString("browser_forward"), systemImage: "chevron.right")
                }
            }

            // Share
            if viewModel.currentURL != nil {
                Button {
                    onShare?()
                } label: {
                    Label(LanguageManager.shared.localizedString("share"), systemImage: "square.and.arrow.up")
                }
            }

            // Copy Link
            if let url = viewModel.currentURL {
                Button {
                    UIPasteboard.general.url = url
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    NotificationCenter.default.post(name: .linkCopied, object: nil)
                } label: {
                    Label(LanguageManager.shared.localizedString("copy_link"), systemImage: "doc.on.doc")
                }
            }

            if WebNavigationPolicyService.shared.canUseSafariCompatibilityMode(for: viewModel.currentURL) {
                Divider()

                Button {
                    onOpenSafariCompatibility?()
                } label: {
                    Label(
                        LanguageManager.shared.localizedString("safari_compatibility_mode"),
                        systemImage: "safari"
                    )
                }

                Button {
                    onOpenDefaultBrowser?()
                } label: {
                    Label(
                        LanguageManager.shared.localizedString("open_in_default_browser"),
                        systemImage: "arrow.up.right.square"
                    )
                }
            }

            if viewModel.currentURL != nil {
                Button {
                    onBookmarkToggle?()
                } label: {
                    Label(
                        LanguageManager.shared.localizedString("bookmarks"),
                        systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
                    )
                }
            }

            Divider()

            if viewModel.currentURL?.host != nil {
                Button {
                    onShowPrivacy?()
                } label: {
                    Label(LanguageManager.shared.localizedString("site_privacy"), systemImage: "shield.checkered")
                }
            }

            // Find in Page
            if let tabManager = tabManager, viewModel.currentURL != nil {
                Button {
                    tabManager.startFindInPage()
                } label: {
                    Label(LanguageManager.shared.localizedString("find_in_page"), systemImage: "doc.text.magnifyingglass")
                }
            }

            if viewModel.currentURL?.host != nil {
                Button {
                    onManageAdBlock?()
                } label: {
                    Label(LanguageManager.shared.localizedString("ad_block_management"), systemImage: "shield.lefthalf.filled")
                }
            }

            Button {
                onShowDownloads?()
            } label: {
                Label(LanguageManager.shared.localizedString("downloads"), systemImage: "arrow.down.circle")
            }

            // Desktop Mode
            if let tabManager = tabManager {
                Button {
                    tabManager.toggleDesktopMode()
                } label: {
                    Label(
                        LanguageManager.shared.localizedString(tabManager.isDesktopMode ? "mobile_mode" : "desktop_mode"),
                        systemImage: tabManager.isDesktopMode ? "iphone" : "desktopcomputer"
                    )
                }
            }

            Divider()

            // New Tab
            if let tabManager = tabManager {
                Button {
                    tabManager.createTab()
                } label: {
                    Label(LanguageManager.shared.localizedString("tab_new_tab"), systemImage: "plus.square")
                }

                Button(role: .destructive) {
                    onFireButton?()
                } label: {
                    Label(LanguageManager.shared.localizedString("fire_button"), systemImage: "trash.fill")
                }

                // Restore Last Closed
                if !tabManager.recentlyClosed.isEmpty {
                    Button {
                        tabManager.restoreLastClosedTab()
                    } label: {
                        Label(LanguageManager.shared.localizedString("tab_restore_last"), systemImage: "arrow.uturn.backward")
                    }
                }
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
