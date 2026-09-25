import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    var isCompact: Bool = false
    var isIncognito: Bool = false
    var isRecording: Bool = false
    var respondsToHomeFocus: Bool = true
    var onSubmit: () -> Void
    var onMicTap: (() -> Void)? = nil
    var onClear: (() -> Void)?
    var onIncognitoTap: (() -> Void)?
    var onScanTap: (() -> Void)?
    var selectedRegion: PlatformRegion?
    var selectedGroupID: UUID?
    var onRegionSelect: ((PlatformRegion) -> Void)?
    var onGroupSelect: ((CustomGroup) -> Void)?
    var onPlatformManagementTap: (() -> Void)?

    @ObservedObject var wallpaperManager = WallpaperManager.shared
    @ObservedObject private var platformStore = PlatformDataStore.shared

    @FocusState private var isFocused: Bool
    @State private var animateGlow = false
    @State private var showSearchActions = false

    private var isLight: Bool {
        !isCompact && wallpaperManager.isCurrentWallpaperLight
    }

    // Adaptive colors based on mode
    private var iconColor: Color {
        isCompact ? Color(UIColor.secondaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.5) : .white.opacity(0.5))
    }
    private var iconActiveColor: Color {
        isCompact ? Color(UIColor.label) : (isLight ? Color(hex: "2E2A47").opacity(0.85) : .white.opacity(0.9))
    }
    private var textColor: Color {
        isCompact ? Color(UIColor.label) : (isLight ? Color(hex: "2E2A47") : .white)
    }
    private var placeholderColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.35) : .white.opacity(0.35))
    }
    private var clearColor: Color {
        isCompact ? Color(UIColor.tertiaryLabel) : (isLight ? Color(hex: "2E2A47").opacity(0.4) : .white.opacity(0.4))
    }
    private var dividerColor: Color {
        isCompact ? Color(UIColor.separator) : (isLight ? Color(hex: "2E2A47").opacity(0.15) : .white.opacity(0.15))
    }

    var body: some View {
        HStack(spacing: 10) {
            if onIncognitoTap != nil || onRegionSelect != nil || onGroupSelect != nil {
                Button {
                    showSearchActions = true
                } label: {
                    Image(systemName: isIncognito ? "eye.slash.fill" : "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isFocused ? iconActiveColor : iconColor)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("search.actions")
                .accessibilityLabel(
                    LanguageManager.shared.localizedString(
                        isIncognito ? "accessibility_incognito_active" : "search"
                    )
                )
                .accessibilityHint(
                    LanguageManager.shared.localizedString(
                        isIncognito ? "privacy_exit_incognito" : "privacy_enter_incognito"
                    )
                )
                .popover(isPresented: $showSearchActions, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                    searchActionsPanel(onIncognitoTap: onIncognitoTap, onScanTap: onScanTap)
                        .presentationCompactAdaptation(.popover)
                }
            } else {
                Image(systemName: isIncognito ? "eye.slash.fill" : "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isFocused ? iconActiveColor : iconColor)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
            }

            TextField(
                "",
                text: $text,
                prompt: Text(LanguageManager.shared.localizedString("search_placeholder"))
                    .foregroundStyle(placeholderColor)
            )
            .font(.system(size: isCompact ? 14 : 15))
            .foregroundStyle(textColor)
            .focused($isFocused)
            .submitLabel(.search)
            .onSubmit(onSubmit)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .accessibilityLabel(
                LanguageManager.shared.localizedString(
                    isIncognito ? "privacy_search_placeholder" : "search_placeholder"
                )
            )
            .onReceive(NotificationCenter.default.publisher(for: .focusHomeSearch)) { _ in
                guard respondsToHomeFocus && !isCompact else { return }
                isFocused = true
            }

            if !text.isEmpty {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { text = "" }
                    onClear?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(clearColor)
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
            }

            if let onMicTap {
                Rectangle()
                    .fill(dividerColor)
                    .frame(width: 1, height: 16)
                    .accessibilityHidden(true)

                Button(action: onMicTap) {
                    ZStack {
                        if isRecording {
                            Circle()
                                .fill(Color.red.opacity(0.2))
                                .frame(width: 26, height: 26)
                                .scaleEffect(animateGlow ? 1.4 : 1.0)
                                .opacity(animateGlow ? 0 : 0.8)
                        }
                        Image(systemName: isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isRecording ? .red : iconColor)
                    }
                    .frame(width: 26, height: 26)
                }
                .onChange(of: isRecording) { _, recording in
                    if recording {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: false)) {
                            animateGlow = true
                        }
                    } else {
                        animateGlow = false
                    }
                }
                .accessibilityLabel(
                    LanguageManager.shared.localizedString(isRecording ? "voice_stop" : "voice_record")
                )
                .accessibilityValue(
                    LanguageManager.shared.localizedString(
                        isRecording ? "accessibility_voice_recording" : "accessibility_voice_idle"
                    )
                )
                .accessibilityHint(LanguageManager.shared.localizedString("accessibility_voice_search_hint"))
            }

        }
        .padding(.horizontal, 14)
        .padding(.vertical, isCompact ? 6 : 10)
        .background {
            if isCompact {
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    Capsule().stroke(Color(UIColor.separator).opacity(0.3), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: 2)
            } else {
                ZStack {
                    if isLight {
                        Capsule().fill(.white.opacity(0.75))
                        Capsule().stroke(Color(hex: "2E2A47").opacity(isFocused ? 0.35 : 0.15), lineWidth: 0.5)
                    } else {
                        Capsule().fill(.ultraThinMaterial.opacity(0.6))
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().stroke(.white.opacity(isFocused ? 0.3 : 0.12), lineWidth: 0.5)
                    }
                }
                .shadow(color: isLight ? .black.opacity(0.04) : .black.opacity(0.2), radius: 16, x: 0, y: 4)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }

    private func searchActionsPanel(
        onIncognitoTap: (() -> Void)?,
        onScanTap: (() -> Void)?
    ) -> some View {
        VStack(spacing: 0) {
            if let onIncognitoTap {
                Button {
                    showSearchActions = false
                    isFocused = false
                    onIncognitoTap()
                } label: {
                    Label(LanguageManager.shared.localizedString(isIncognito ? "privacy_exit_incognito" : "privacy_enter_incognito"), systemImage: isIncognito ? "eye" : "eye.slash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
            }

            if let onScanTap {
                Button {
                    showSearchActions = false
                    isFocused = false
                    onScanTap()
                } label: {
                    Label(ToolText.text("scan_qr"), systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .frame(height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("search.scan")
            }

            if let onRegionSelect {
                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(PlatformRegion.sortedCases(preferring: selectedRegion ?? .international).filter { !platformStore.visiblePlatforms(for: $0).isEmpty }) { region in
                            searchActionRow(
                                title: "\(platformStore.regionDisplayName(for: region)) (\(platformStore.visiblePlatforms(for: region).count))",
                                systemImage: selectedGroupID == nil && selectedRegion == region ? "checkmark" : nil
                            ) {
                                showSearchActions = false
                                onRegionSelect(region)
                            }
                        }

                        if let onGroupSelect {
                            ForEach(platformStore.customGroups.filter { !platformStore.platformsForGroup($0).isEmpty }) { group in
                                searchActionRow(
                                    title: "\(group.name) (\(platformStore.platformsForGroup(group).count))",
                                    systemImage: selectedGroupID == group.id ? "checkmark" : nil
                                ) {
                                    showSearchActions = false
                                    onGroupSelect(group)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 190)

                if let onPlatformManagementTap {
                    Divider()
                    Button {
                        showSearchActions = false
                        DispatchQueue.main.async { onPlatformManagementTap() }
                    } label: {
                        Label(LanguageManager.shared.localizedString("platform_management"), systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .frame(height: 46)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 280)
        .padding(.vertical, 6)
    }

    private func searchActionRow(title: String, systemImage: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage ?? "checkmark")
                    .font(.system(size: 14, weight: .medium))
                    .opacity(systemImage == nil ? 0 : 1)
                Text(title)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
