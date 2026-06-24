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

    var body: some View {
        HStack(spacing: 10) {
            btn("house.fill", enabled: onGoHome != nil) { onGoHome?() }
            btn("chevron.left", enabled: viewModel.canGoBack) { viewModel.goBack() }
            btn("chevron.right", enabled: viewModel.canGoForward) { viewModel.goForward() }
            btn(viewModel.isLoading ? "xmark" : "arrow.clockwise", enabled: true) { viewModel.reload() }
            if viewModel.currentURL != nil {
                btn(isBookmarked ? "bookmark.fill" : "bookmark",
                    enabled: true,
                    tint: isBookmarked ? .blue : nil) { onBookmarkToggle?() }
            }

            // More actions menu
            moreMenu

            // Tab count button
            if let tabManager = tabManager {
                TabCountBadge(count: tabManager.tabCount) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    // Snapshot current page before showing overview
                    tabManager.activeWebViewModel?.takeSnapshot()
                    tabManager.showTabOverview = true
                }
            }
        }
    }

    // MARK: - More Actions Menu

    private var moreMenu: some View {
        Menu {
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
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                )
        }
    }

    // MARK: - Button

    private func btn(_ icon: String, enabled: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(
                    !enabled ? .white.opacity(0.35) :
                    tint ?? .white.opacity(0.85)
                )
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                )
        }
        .disabled(!enabled)
    }
}
