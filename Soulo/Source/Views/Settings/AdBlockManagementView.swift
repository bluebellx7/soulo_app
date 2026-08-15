import SwiftUI

struct AdBlockManagementView: View {
    @ObservedObject private var service = AdBlockSettingsService.shared
    @ObservedObject private var subscriptionService = AdBlockSubscriptionService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true

    let currentHost: String?
    var onChanged: (() -> Void)? = nil

    private var currentHostIsAllowlisted: Bool {
        service.isAllowlisted(currentHost)
    }

    private var currentHostProtectionEnabled: Bool {
        adBlockEnabled && !currentHostIsAllowlisted && !currentHostUsesCompatibilityBypass
    }

    private var currentHostUsesCompatibilityBypass: Bool {
        WebCompatibilityService.shouldBypassWebProtection(
            for: nil,
            fallbackHost: currentHost
        )
    }

    private var currentHostHiddenElementCount: Int {
        service.hiddenElementCount(for: currentHost)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    IconBadge(
                        systemName: adBlockEnabled ? "shield.checkered" : "shield.slash",
                        color: adBlockEnabled ? .green : Color(uiColor: .systemGray3)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(LanguageManager.shared.localizedString("ad_block"))
                            .font(.body.weight(.semibold))
                        Text(LanguageManager.shared.localizedString(adBlockEnabled ? "status_enabled" : "status_disabled"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(adBlockEnabled ? Color.green : Color.secondary)
                    }

                    Spacer()

                    Toggle("", isOn: $adBlockEnabled)
                        .labelsHidden()
                        .tint(.green)
                        .accessibilityLabel(LanguageManager.shared.localizedString("ad_block"))
                        .accessibilityValue(
                            LanguageManager.shared.localizedString(
                                adBlockEnabled ? "accessibility_enabled" : "accessibility_disabled"
                            )
                        )
                }
                .padding(.vertical, 6)
                .listRowBackground(
                    adBlockEnabled
                        ? Color.green.opacity(0.09)
                        : Color(uiColor: .secondarySystemGroupedBackground)
                )
            } footer: {
                Text(LanguageManager.shared.localizedString("ad_block_desc"))
            }

            if let currentHost {
                Section {
                    Button {
                        service.toggleAllowlist(for: currentHost)
                        onChanged?()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: currentHostProtectionEnabled ? "shield.checkered" : "shield.slash")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(currentHostProtectionEnabled ? Color.green : Color.secondary)
                                .frame(width: 32, height: 32)
                                .background(
                                    (currentHostProtectionEnabled ? Color.green : Color.secondary)
                                        .opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                )

                            Text(
                                currentHostIsAllowlisted
                                    ? LanguageManager.shared.localizedString("ad_block_enable_current_site")
                                    : LanguageManager.shared.localizedString("ad_block_disable_current_site")
                            )
                            .foregroundStyle(.primary)

                            Spacer()

                            AdBlockStatusPill(isEnabled: currentHostProtectionEnabled)
                        }
                    }
                    .disabled(!adBlockEnabled || currentHostUsesCompatibilityBypass)

                    AdBlockMetricRow(
                        title: LanguageManager.shared.localizedString("ad_block_current_site_hidden"),
                        systemImage: "eye.slash",
                        value: currentHostHiddenElementCount,
                        isHighlighted: currentHostHiddenElementCount > 0
                    )
                } header: {
                    SectionHeader(title: currentHost)
                } footer: {
                    Text(
                        LanguageManager.shared.localizedString(
                            currentHostUsesCompatibilityBypass
                                ? "site_privacy_compatibility_bypass"
                                : "ad_block_site_toggle_desc"
                        )
                    )
                }
            }

            Section {
                Button {
                    Task {
                        await subscriptionService.updateEnabledSubscriptions()
                        onChanged?()
                    }
                } label: {
                    Label(
                        subscriptionService.isUpdating
                            ? LanguageManager.shared.localizedString("ad_block_subscription_updating")
                            : LanguageManager.shared.localizedString("ad_block_subscription_update"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(subscriptionService.isUpdating || !adBlockEnabled)

                ForEach(subscriptionService.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(subscription.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(subscription.isEnabled ? Color.primary : Color.secondary)
                                AdBlockStatusPill(isEnabled: adBlockEnabled && subscription.isEnabled)
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { subscription.isEnabled },
                                set: { enabled in
                                    subscriptionService.setEnabled(enabled, for: subscription)
                                    onChanged?()
                                }
                            ))
                            .labelsHidden()
                            .tint(.green)
                            .disabled(!adBlockEnabled)
                            .accessibilityLabel(subscription.name)
                            .accessibilityValue(
                                LanguageManager.shared.localizedString(
                                    subscription.isEnabled
                                        ? "accessibility_enabled"
                                        : "accessibility_disabled"
                                )
                            )
                        }

                        HStack(spacing: 8) {
                            Text("\(subscription.networkRuleCount + subscription.cosmeticRuleCount) \(LanguageManager.shared.localizedString("ad_block_subscription_rules_suffix"))")
                            if let lastUpdatedAt = subscription.lastUpdatedAt {
                                Text("-")
                                Text(lastUpdatedAt, style: .date)
                            }
                            if !subscription.errorMessage.isEmpty {
                                Text("-")
                                Text(subscription.errorMessage)
                                    .foregroundStyle(.red)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(
                        adBlockEnabled && subscription.isEnabled
                            ? Color.green.opacity(0.055)
                            : Color(uiColor: .secondarySystemGroupedBackground)
                    )
                }

                Button(role: .destructive) {
                    subscriptionService.resetToDefaults()
                    onChanged?()
                } label: {
                    Label(LanguageManager.shared.localizedString("ad_block_subscription_reset"), systemImage: "arrow.counterclockwise")
                }
                .disabled(!adBlockEnabled)
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("ad_block_subscriptions"))
            } footer: {
                Text(
                    LanguageManager.shared.localizedString(
                        adBlockEnabled ? "ad_block_subscriptions_desc" : "ad_block_master_disabled_desc"
                    )
                )
            }
            .opacity(adBlockEnabled ? 1 : 0.48)

            if !service.allowlistedHosts.isEmpty {
                Section {
                    ForEach(service.allowlistedHosts, id: \.self) { host in
                        HStack {
                            Label(host, systemImage: "shield.slash")
                            Spacer()
                            Button(LanguageManager.shared.localizedString("restore")) {
                                service.removeAllowlistedHost(host)
                                onChanged?()
                            }
                            .font(.subheadline.weight(.medium))
                            .buttonStyle(.borderless)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { service.allowlistedHosts[$0] }.forEach(service.removeAllowlistedHost)
                        onChanged?()
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("ad_block_allowlist"))
                }
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("ad_block_management"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
            }
        }
        .onChange(of: adBlockEnabled) { _, _ in
            onChanged?()
        }
    }
}

private struct AdBlockStatusPill: View {
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isEnabled ? Color.green : Color.secondary)
                .frame(width: 6, height: 6)
            Text(LanguageManager.shared.localizedString(isEnabled ? "status_enabled" : "status_disabled"))
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(isEnabled ? Color.green : Color.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            (isEnabled ? Color.green : Color.secondary).opacity(0.11),
            in: Capsule()
        )
        .fixedSize()
    }
}

private struct AdBlockMetricRow: View {
    let title: String
    let systemImage: String
    let value: Int
    let isHighlighted: Bool
    var highlightColor: Color = .green

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isHighlighted ? highlightColor : Color.secondary)
                .frame(width: 30, height: 30)
                .background(
                    (isHighlighted ? highlightColor : Color.secondary).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.weight(.semibold))
                .foregroundStyle(isHighlighted ? highlightColor : Color.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}
