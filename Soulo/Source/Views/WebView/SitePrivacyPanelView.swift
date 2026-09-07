import SwiftUI
import WebKit
import Security

struct SiteAdBlockToggleState: Equatable {
    let isGloballyEnabled: Bool
    let isAllowlisted: Bool
}

enum SiteAdBlockTogglePolicy {
    static func nextState(
        isGloballyEnabled: Bool,
        isAllowlisted: Bool
    ) -> SiteAdBlockToggleState {
        if !isGloballyEnabled {
            return SiteAdBlockToggleState(
                isGloballyEnabled: true,
                isAllowlisted: false
            )
        }

        return SiteAdBlockToggleState(
            isGloballyEnabled: true,
            isAllowlisted: !isAllowlisted
        )
    }
}

struct SiteInformationPopoverView: View {
    @ObservedObject var webViewModel: WebViewModel
    var onSetDesktopMode: (Bool) -> Void
    @State private var showUserAgent = false
    @ObservedObject private var privacyService = PrivacyProtectionService.shared
    @ObservedObject private var adBlockService = AdBlockSettingsService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true

    let currentURL: URL?
    let isPrivateMode: Bool
    var onSetPrivateMode: (Bool) -> Void
    var onReload: () -> Void
    var onShowDetails: () -> Void

    @State private var connectionExpanded = false
    @State private var panelHeight: CGFloat = 330
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var host: String {
        PrivacyProtectionService.normalizedHost(currentURL?.host)
    }

    private var isSecure: Bool {
        currentURL?.scheme?.lowercased() == "https"
    }

    private var usesCompatibilityBypass: Bool {
        WebCompatibilityService.shouldBypassWebProtection(
            for: currentURL,
            fallbackHost: host
        )
    }

    private var siteAdBlockingEnabled: Bool {
        adBlockEnabled
            && !usesCompatibilityBypass
            && !adBlockService.isAllowlisted(host)
    }

    private var trackingProtectionEnabled: Bool {
        !usesCompatibilityBypass && !privacyService.isProtectionDisabled(for: host)
    }

    var body: some View {
        ScrollView {
        VStack(spacing: 12) {
            connectionCard
            Button { showUserAgent = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "globe").frame(width: 25)
                    Text(ToolText.text("browser_identity")).font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(webViewModel.userAgentOverride == nil
                         ? LanguageManager.shared.localizedString(webViewModel.isDesktopModeEnabled ? "desktop_mode" : "mobile_mode")
                         : ToolText.text("custom_identity"))
                        .font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }.padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).accessibilityIdentifier("site.user-agent")

            HStack(spacing: 10) {
                protectionButton(
                    titleKey: "ad_block",
                    systemImage: "tag.fill",
                    isEnabled: siteAdBlockingEnabled,
                    isDisabled: host.isEmpty || usesCompatibilityBypass
                ) {
                    toggleSiteAdBlocking()
                }

                protectionButton(
                    titleKey: "site_tracking_protection",
                    systemImage: "shield.lefthalf.filled",
                    isEnabled: trackingProtectionEnabled,
                    isDisabled: host.isEmpty || usesCompatibilityBypass
                ) {
                    privacyService.setProtectionEnabled(!trackingProtectionEnabled, for: host)
                    HapticsManager.selection()
                    onReload()
                }
            }

            HStack(spacing: 10) {
                Toggle(isOn: Binding(
                    get: { isPrivateMode },
                    set: { onSetPrivateMode($0) }
                )) {
                    HStack(spacing: 10) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isPrivateMode ? .teal : .secondary)
                            .frame(width: 25)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LanguageManager.shared.localizedString("privacy_incognito"))
                                .font(.subheadline.weight(.semibold))
                            Text(LanguageManager.shared.localizedString("site_private_mode_desc"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .tint(.teal)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                Button {
                    onShowDetails()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .bold))
                        .frame(width: 58, height: 64)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("site_privacy_details"))
            }
        }
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(idealWidth: 350, maxWidth: 350)
        .frame(height: min(panelHeight, verticalSizeClass == .compact ? 250 : 580))
        .presentationCompactAdaptation(.popover)
        .sheet(isPresented: $showUserAgent) {
            BrowserIdentityView(viewModel: webViewModel, onSetDesktopMode: onSetDesktopMode)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { connectionExpanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: isSecure ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(isSecure ? .green : .orange).frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LanguageManager.shared.localizedString(isSecure ? "site_connection_secure" : "site_connection_not_secure"))
                            .font(.subheadline.weight(.semibold))
                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: connectionExpanded ? "chevron.up" : "chevron.right")
                        .font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("site.connection")
            if connectionExpanded {
                Divider().opacity(0.55)
                Text(LanguageManager.shared.localizedString(isSecure ? "site_https_verified_desc" : "site_http_warning_desc"))
                    .font(.caption).foregroundStyle(.secondary)
                if !webViewModel.pageTitle.isEmpty {
                    Text(webViewModel.pageTitle).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                }
                LabeledContent(ToolText.text("connection_protocol"), value: (currentURL?.scheme?.uppercased() ?? "—") + " · " + String(currentURL?.port ?? (isSecure ? 443 : 80)))
                    .font(.caption)
                if let trust = webViewModel.webView?.serverTrust,
                   let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                   let certificate = certificates.first,
                   let subject = SecCertificateCopySubjectSummary(certificate) {
                    LabeledContent(ToolText.text("certificate"), value: subject as String).font(.caption)
                }
                if isSecure, let web = webViewModel.webView, !web.isLoading, !web.hasOnlySecureContent {
                    Text(ToolText.text("mixed_content")).font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 8) {
                    Text(currentURL?.absoluteString ?? "").font(.caption2.monospaced())
                        .foregroundStyle(.secondary).textSelection(.enabled)
                        .lineLimit(5).truncationMode(.middle)
                    Button {
                        UIPasteboard.general.string = currentURL?.absoluteString
                    } label: { CompactIconLabel(systemImage: "doc.on.doc") }
                    .buttonStyle(.plain).accessibilityLabel(LanguageManager.shared.localizedString("copy_link"))
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func protectionButton(
        titleKey: String,
        systemImage: String,
        isEnabled: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Image(systemName: isEnabled ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(isEnabled ? Color.green : Color.secondary)

                Text(LanguageManager.shared.localizedString(titleKey))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.48 : 1)
    }

    private func toggleSiteAdBlocking() {
        let nextState = SiteAdBlockTogglePolicy.nextState(
            isGloballyEnabled: adBlockEnabled,
            isAllowlisted: adBlockService.isAllowlisted(host)
        )

        adBlockEnabled = nextState.isGloballyEnabled
        if nextState.isAllowlisted {
            adBlockService.addAllowlistedHost(host)
        } else {
            adBlockService.removeAllowlistedHost(host)
        }

        HapticsManager.selection()
        onReload()
    }
}

struct SitePrivacyPanelView: View {
    @ObservedObject private var privacyService = PrivacyProtectionService.shared
    @ObservedObject private var adBlockService = AdBlockSettingsService.shared
    @Environment(\.dismiss) private var dismiss

    let currentURL: URL?
    var onChanged: (() -> Void)? = nil

    @State private var siteDataCleared = false
    @State private var requestsExpanded = false

    private var host: String {
        PrivacyProtectionService.normalizedHost(currentURL?.host)
    }

    private var summary: SitePrivacySummary {
        privacyService.summary(for: host)
    }

    private var usesCompatibilityBypass: Bool {
        WebCompatibilityService.shouldBypassWebProtection(
            for: currentURL,
            fallbackHost: host
        )
    }

    private var protectionEnabled: Binding<Bool> {
        Binding(
            get: { !usesCompatibilityBypass && !privacyService.isProtectionDisabled(for: host) },
            set: { enabled in
                guard !usesCompatibilityBypass else { return }
                privacyService.setProtectionEnabled(enabled, for: host)
                onChanged?()
            }
        )
    }

    private var handledActionCount: Int {
        summary.httpsUpgradeCount
            + summary.strippedTrackingParameterCount
            + summary.cookieBannerActionCount
    }

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(LanguageManager.shared.localizedString(
                            currentURL?.scheme?.lowercased() == "https"
                                ? "site_connection_secure"
                                : "site_connection_not_secure"
                        ))
                        .font(.body.weight(.medium))
                        Text(host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: currentURL?.scheme?.lowercased() == "https" ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(currentURL?.scheme?.lowercased() == "https" ? .green : .orange)
                }
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("site_information"))
            }

            Section {
                Toggle(isOn: protectionEnabled) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LanguageManager.shared.localizedString("site_protection"))
                            Text(LanguageManager.shared.localizedString(
                                usesCompatibilityBypass
                                    ? "site_privacy_compatibility_bypass"
                                    : protectionEnabled.wrappedValue
                                        ? "site_privacy_protected"
                                        : "site_privacy_unprotected"
                            ))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: protectionEnabled.wrappedValue ? "shield.checkered" : "shield.slash")
                            .foregroundStyle(protectionEnabled.wrappedValue ? .green : .orange)
                    }
                }
                .disabled(host.isEmpty || usesCompatibilityBypass)
                .tint(.green)
            } footer: {
                Text(LanguageManager.shared.localizedString("site_protection_explanation"))
            }

            Section {
                summaryRow(
                    titleKey: "site_blocked_trackers",
                    value: summary.blockedTrackerCount,
                    systemImage: "shield.lefthalf.filled"
                )
                summaryRow(
                    titleKey: "site_hidden_elements",
                    value: max(summary.hiddenElementCount, adBlockService.hiddenElementCount(for: host)),
                    systemImage: "eye.slash"
                )
                summaryRow(
                    titleKey: "site_privacy_actions",
                    value: handledActionCount,
                    systemImage: "wand.and.stars"
                )
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("site_protection_summary"))
            } footer: {
                Text(LanguageManager.shared.localizedString("site_protection_summary_desc"))
            }

            if !summary.trackerRequests.isEmpty {
                Section {
                    DisclosureGroup(
                        isExpanded: $requestsExpanded,
                        content: {
                            ForEach(Array(summary.trackerRequests).sorted(by: trackerRequestSort).prefix(50)) { request in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: request.isBlocked ? "shield.fill" : "network")
                                        .foregroundStyle(request.isBlocked ? .green : .secondary)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(request.networkNameForDisplay)
                                            .font(.subheadline.weight(.medium))
                                        Text(request.host)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        },
                        label: {
                            Label(
                                AppAccessibility.formatted("site_request_details_count", summary.trackerRequests.count),
                                systemImage: "list.bullet.rectangle"
                            )
                        }
                    )
                }
            }

            Section {
                Button {
                    clearCurrentSiteData()
                } label: {
                    Label(
                        siteDataCleared
                            ? LanguageManager.shared.localizedString("site_data_cleared")
                            : LanguageManager.shared.localizedString("site_clear_data"),
                        systemImage: siteDataCleared ? "checkmark.circle.fill" : "trash"
                    )
                }
                .disabled(host.isEmpty)
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("site_privacy_details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
            }
        }
    }

    private func summaryRow(titleKey: String, value: Int, systemImage: String) -> some View {
        LabeledContent {
            Text("\(value)")
                .foregroundStyle(value > 0 ? .primary : .secondary)
                .monospacedDigit()
        } label: {
            Label(LanguageManager.shared.localizedString(titleKey), systemImage: systemImage)
        }
    }

    private func trackerRequestSort(_ lhs: TrackerRequest, _ rhs: TrackerRequest) -> Bool {
        if lhs.isBlocked != rhs.isBlocked { return lhs.isBlocked }
        return lhs.networkNameForDisplay < rhs.networkNameForDisplay
    }

    private func clearCurrentSiteData() {
        guard !host.isEmpty else { return }
        WKWebsiteDataStore.default().fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
            let matching = records.filter { record in
                let recordHost = PrivacyProtectionService.normalizedHost(record.displayName)
                return recordHost == host || recordHost.hasSuffix(".\(host)") || host.hasSuffix(".\(recordHost)")
            }
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) {
                DispatchQueue.main.async {
                    siteDataCleared = true
                    onChanged?()
                }
            }
        }
    }
}


private struct BrowserIdentityView: View {
    @ObservedObject var viewModel: WebViewModel
    let onSetDesktopMode: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = "automatic"
    @State private var custom = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker(ToolText.text("browser_identity"), selection: $mode) {
                        Text(ToolText.text("default_identity")).tag("automatic")
                        Text("iPhone · Safari").tag("mobile")
                        Text("Mac · Safari").tag("desktop")
                        Text(ToolText.text("custom_identity")).tag("custom")
                    }.pickerStyle(.inline)
                } footer: { Text(ToolText.text("identity_hint")) }
                if mode == "custom" {
                    Section {
                        TextEditor(text: $custom).font(.body.monospaced()).frame(minHeight: 120)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    } header: { Text("User-Agent") } footer: { Text(ToolText.text("identity_validation")) }
                }
                Section(ToolText.text("current_identity")) {
                    Text(viewModel.webView?.customUserAgent ?? "").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            .navigationTitle(ToolText.text("browser_identity")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) {
                        guard viewModel.setUserAgentOverride(mode == "custom" ? custom : nil) else { return }
                        if mode == "mobile" || mode == "desktop" { onSetDesktopMode(mode == "desktop") }
                        viewModel.retryCurrentPage()
                        dismiss()
                    }.disabled(mode == "custom" && !WebViewModel.isValidUserAgent(custom))
                }
            }
            .onAppear {
                custom = viewModel.userAgentOverride ?? viewModel.webView?.customUserAgent ?? ""
                mode = viewModel.userAgentOverride == nil ? "automatic" : "custom"
            }
        }
    }
}
