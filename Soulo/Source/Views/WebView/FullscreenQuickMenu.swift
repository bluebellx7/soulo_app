import SwiftUI

/// A concrete View boundary prevents the fullscreen menu's nested SwiftUI types
/// and stack frames from being expanded inside WebViewContainer on first open.
struct FullscreenQuickMenu: View {
    enum Action {
        case share, copyLink, bookmark, home, capture, translate, settings
        case editAddress, close, mobileMode, desktopMode, back, reload, forward, exitFullscreen
    }

    @ObservedObject var webViewModel: WebViewModel
    let title: String
    let isBookmarked: Bool
    let isDesktopMode: Bool
    let canSwitchContentMode: Bool
    let onAction: (Action) -> Void

    var body: some View {
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
                    onAction(.share)
                }

                fullscreenPrimaryAction(
                    titleKey: "copy_link",
                    systemImage: "doc.on.doc"
                ) {
                    onAction(.copyLink)
                }

                fullscreenPrimaryAction(
                    titleKey: "bookmarks",
                    systemImage: isBookmarked ? "bookmark.fill" : "bookmark",
                    tint: isBookmarked ? .orange : .white
                ) {
                    onAction(.bookmark)
                }
            }
            .padding(10)

            HStack(spacing: 8) {
                fullscreenPrimaryAction(
                    titleKey: "home_screen",
                    systemImage: "house.fill"
                ) {
                    onAction(.home)
                }

                fullscreenPrimaryAction(
                    titleKey: "web_capture",
                    systemImage: "camera.viewfinder"
                ) {
                    onAction(.capture)
                }

                fullscreenPrimaryAction(
                    titleKey: "web_translate",
                    systemImage: "character.bubble"
                ) {
                    onAction(.translate)
                }

                fullscreenPrimaryAction(
                    titleKey: "settings",
                    systemImage: "gearshape"
                ) {
                    onAction(.settings)
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
                onAction(.editAddress)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: webViewModel.currentURL?.scheme == "https" ? "lock.fill" : "globe")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 20, height: 20)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
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
                onAction(.close)
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
            .accessibilityIdentifier("fullscreen.menu.close")
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
    ) -> FullscreenPrimaryActionButton {
        FullscreenPrimaryActionButton(titleKey: titleKey, systemImage: systemImage, tint: tint, enabled: webViewModel.currentURL != nil, action: action)
    }

    private var fullscreenContentModePicker: some View {
        HStack(spacing: 6) {
            fullscreenContentModeButton(
                titleKey: "mobile_mode",
                systemImage: "iphone",
                isSelected: !isDesktopMode
            ) {
                onAction(.mobileMode)
            }

            fullscreenContentModeButton(
                titleKey: "desktop_mode",
                systemImage: "desktopcomputer",
                isSelected: isDesktopMode
            ) {
                onAction(.desktopMode)
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
    ) -> FullscreenContentModeButton {
        FullscreenContentModeButton(titleKey: titleKey, systemImage: systemImage, isSelected: isSelected, enabled: canSwitchContentMode, action: action)
    }

    private var fullscreenNavigationActions: some View {
        HStack(spacing: 7) {
            fullscreenCompactAction(
                titleKey: "browser_back",
                systemImage: "chevron.left",
                enabled: webViewModel.canGoBack
            ) {
                onAction(.back)
            }

            fullscreenCompactAction(
                titleKey: "browser_reload",
                systemImage: webViewModel.isLoading ? "xmark" : "arrow.clockwise",
                enabled: webViewModel.currentURL != nil
            ) {
                onAction(.reload)
            }

            fullscreenCompactAction(
                titleKey: "browser_forward",
                systemImage: "chevron.right",
                enabled: webViewModel.canGoForward
            ) {
                onAction(.forward)
            }

            Button {
                onAction(.exitFullscreen)
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
    ) -> FullscreenCompactActionButton {
        FullscreenCompactActionButton(titleKey: titleKey, systemImage: systemImage, enabled: enabled, action: action)
    }

}

private struct FullscreenPrimaryActionButton: View {
    let titleKey: String
    let systemImage: String
    var tint: Color = .white
    let enabled: Bool
    let action: () -> Void

    var body: some View {
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
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}

private struct FullscreenContentModeButton: View {
    let titleKey: String
    let systemImage: String
    let isSelected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
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
        .disabled(!enabled)
    }
}

private struct FullscreenCompactActionButton: View {
    let titleKey: String
    let systemImage: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
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
}
