import SwiftUI
import WebKit

struct SitePrivacyPanelView: View {
    @ObservedObject private var privacyService = PrivacyProtectionService.shared
    @ObservedObject private var adBlockService = AdBlockSettingsService.shared
    @Environment(\.dismiss) private var dismiss

    let currentURL: URL?
    var onChanged: (() -> Void)? = nil

    @State private var siteDataCleared = false

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

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: protectionEnabled.wrappedValue ? "shield.checkered" : "shield.slash")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(protectionEnabled.wrappedValue ? .green : .orange)
                        .frame(width: 44, height: 44)
                        .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(host.isEmpty ? LanguageManager.shared.localizedString("site_privacy_no_site") : host)
                            .font(.headline)
                            .lineLimit(1)
                        Text(
                            LanguageManager.shared.localizedString(
                                usesCompatibilityBypass
                                    ? "site_privacy_compatibility_bypass"
                                    : protectionEnabled.wrappedValue
                                        ? "site_privacy_protected"
                                        : "site_privacy_unprotected"
                            )
                        )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Toggle(isOn: protectionEnabled) {
                    Label(LanguageManager.shared.localizedString("site_protection"), systemImage: "shield.fill")
                }
                .disabled(host.isEmpty || usesCompatibilityBypass)
                .tint(.green)
            } footer: {
                Text(LanguageManager.shared.localizedString("site_privacy_scope_desc"))
            }

            Section {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                metricCard(
                    title: LanguageManager.shared.localizedString("site_blocked_trackers"),
                    value: summary.blockedTrackerCount,
                    icon: "shield.lefthalf.filled",
                    color: .green
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_detected_trackers"),
                    value: summary.detectedTrackerCount,
                    icon: "scope",
                    color: .purple
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_third_party_requests"),
                    value: summary.thirdPartyRequestCount,
                    icon: "network",
                    color: .teal
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_tracker_hosts"),
                    value: summary.trackerHostCount,
                    icon: "point.3.connected.trianglepath.dotted",
                    color: .purple
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_hidden_elements"),
                    value: max(summary.hiddenElementCount, adBlockService.hiddenElementCount(for: host)),
                    icon: "eye.slash",
                    color: .blue
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_https_upgrades"),
                    value: summary.httpsUpgradeCount,
                    icon: "lock.fill",
                    color: .green
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_stripped_params"),
                    value: summary.strippedTrackingParameterCount,
                    icon: "link.badge.minus",
                    color: .orange
                )
                metricCard(
                    title: LanguageManager.shared.localizedString("site_cookie_banners"),
                    value: summary.cookieBannerActionCount,
                    icon: "birthday.cake.fill",
                    color: .pink
                )
                }
                .padding(.vertical, 2)
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("site_privacy_activity"))
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowBackground(Color.clear)

            if !summary.trackerRequests.isEmpty {
                Section {
                    ForEach(Array(summary.trackerRequests).sorted(by: trackerRequestSort)) { request in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(for: request.state))
                                .foregroundStyle(color(for: request.state))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(request.networkNameForDisplay)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(request.host)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text(statusText(for: request.state))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(color(for: request.state))
                            }
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("site_tracker_requests"))
                }
            }

            if !summary.trackerHostsByCategory.isEmpty {
                Section {
                    ForEach(TrackerCategory.allCases) { category in
                        let hosts = Array(summary.trackerHostsByCategory[category] ?? []).sorted()
                        if !hosts.isEmpty {
                            DisclosureGroup {
                                ForEach(hosts, id: \.self) { host in
                                    Text(host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                Label("\(category.title) (\(hosts.count))", systemImage: category.systemImage)
                            }
                        }
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("site_tracker_categories"))
                }
            }

            if !summary.trackerCompanies.isEmpty {
                Section {
                    Text(Array(summary.trackerCompanies).sorted().joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("site_tracker_companies"))
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

                Button(role: .destructive) {
                    privacyService.resetSummary(for: host)
                    adBlockService.resetStats(for: host)
                } label: {
                    Label(LanguageManager.shared.localizedString("site_reset_stats"), systemImage: "arrow.counterclockwise")
                }
                .disabled(host.isEmpty)
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("site_privacy"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
            }
        }
    }

    private func metricCard(title: String, value: Int, icon: String, color: Color) -> some View {
        let activeColor = value > 0 ? color : Color.secondary
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(activeColor)
                    .frame(width: 30, height: 30)
                    .background(activeColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Spacer()
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.35))
            }

            Text("\(value)")
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(value > 0 ? activeColor : Color.secondary)
                .monospacedDigit()

            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(activeColor.opacity(value > 0 ? 0.18 : 0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
    }

    private func trackerRequestSort(_ lhs: TrackerRequest, _ rhs: TrackerRequest) -> Bool {
        if lhs.isBlocked != rhs.isBlocked {
            return lhs.isBlocked
        }
        return lhs.networkNameForDisplay < rhs.networkNameForDisplay
    }

    private func icon(for state: TrackerRequestState) -> String {
        switch state {
        case .blocked: return "shield.fill"
        case .allowedProtectionDisabled: return "shield.slash"
        case .allowedOwnedByFirstParty: return "building.2"
        case .allowedOtherThirdPartyRequest: return "network"
        }
    }

    private func color(for state: TrackerRequestState) -> Color {
        switch state {
        case .blocked: return .green
        case .allowedProtectionDisabled: return .orange
        case .allowedOwnedByFirstParty: return .blue
        case .allowedOtherThirdPartyRequest: return .secondary
        }
    }

    private func statusText(for state: TrackerRequestState) -> String {
        switch state {
        case .blocked:
            return LanguageManager.shared.localizedString("site_tracker_blocked")
        case .allowedProtectionDisabled:
            return LanguageManager.shared.localizedString("site_tracker_allowed_protection_disabled")
        case .allowedOwnedByFirstParty:
            return LanguageManager.shared.localizedString("site_tracker_allowed_first_party")
        case .allowedOtherThirdPartyRequest:
            return LanguageManager.shared.localizedString("site_tracker_allowed_third_party")
        }
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
