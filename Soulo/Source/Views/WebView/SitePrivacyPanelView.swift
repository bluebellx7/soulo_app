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

    private var protectionEnabled: Binding<Bool> {
        Binding(
            get: { !privacyService.isProtectionDisabled(for: host) },
            set: { enabled in
                privacyService.setProtectionEnabled(enabled, for: host)
                onChanged?()
            }
        )
    }

    private var adBlockingEnabled: Binding<Bool> {
        Binding(
            get: { !adBlockService.isAllowlisted(host) },
            set: { enabled in
                if enabled {
                    adBlockService.removeAllowlistedHost(host)
                } else {
                    adBlockService.addAllowlistedHost(host)
                }
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
                        Text(LanguageManager.shared.localizedString(protectionEnabled.wrappedValue ? "site_privacy_protected" : "site_privacy_unprotected"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                Toggle(isOn: protectionEnabled) {
                    Label(LanguageManager.shared.localizedString("site_protection"), systemImage: "shield.fill")
                }
                .disabled(host.isEmpty)
                .tint(.green)

                Toggle(isOn: adBlockingEnabled) {
                    Label(LanguageManager.shared.localizedString("site_ad_blocking"), systemImage: "eye.slash.fill")
                }
                .disabled(host.isEmpty || !protectionEnabled.wrappedValue)
                .tint(.blue)
            }

            Section {
                metricRow(
                    title: LanguageManager.shared.localizedString("site_tracker_hosts"),
                    value: summary.trackerHostCount,
                    icon: "scope",
                    color: .purple
                )
                metricRow(
                    title: LanguageManager.shared.localizedString("site_hidden_elements"),
                    value: max(summary.hiddenElementCount, adBlockService.hiddenElementCount(for: host)),
                    icon: "eye.slash",
                    color: .blue
                )
                metricRow(
                    title: LanguageManager.shared.localizedString("site_https_upgrades"),
                    value: summary.httpsUpgradeCount,
                    icon: "lock.fill",
                    color: .green
                )
                metricRow(
                    title: LanguageManager.shared.localizedString("site_stripped_params"),
                    value: summary.strippedTrackingParameterCount,
                    icon: "link.badge.minus",
                    color: .orange
                )
                metricRow(
                    title: LanguageManager.shared.localizedString("site_cookie_banners"),
                    value: summary.cookieBannerActionCount,
                    icon: "birthday.cake.fill",
                    color: .pink
                )
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("site_privacy_activity"))
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

    private func metricRow(title: String, value: Int, icon: String, color: Color) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Spacer()
            Text("\(value)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
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
