import SwiftUI

struct AdBlockManagementView: View {
    @ObservedObject private var service = AdBlockSettingsService.shared
    @ObservedObject private var subscriptionService = AdBlockSubscriptionService.shared
    @Environment(\.dismiss) private var dismiss

    let currentHost: String?
    var onChanged: (() -> Void)? = nil

    private var currentHostIsAllowlisted: Bool {
        service.isAllowlisted(currentHost)
    }

    private var subscriptionRuleCount: Int {
        let rules = subscriptionService.enabledRuleSummary
        return rules.networkRules.count + rules.cosmeticRules.count
    }

    private var totalHiddenElementCount: Int {
        service.hiddenElementCountByHost.values.reduce(0, +)
    }

    private var currentHostHiddenElementCount: Int {
        service.hiddenElementCount(for: currentHost)
    }

    var body: some View {
        List {
            if let currentHost {
                Section {
                    Button {
                        service.toggleAllowlist(for: currentHost)
                        onChanged?()
                    } label: {
                        Label(
                            currentHostIsAllowlisted
                                ? LanguageManager.shared.localizedString("ad_block_enable_current_site")
                                : LanguageManager.shared.localizedString("ad_block_disable_current_site"),
                            systemImage: currentHostIsAllowlisted ? "shield.checkered" : "shield.slash"
                        )
                    }

                    HStack {
                        Label(LanguageManager.shared.localizedString("ad_block_current_site_hidden"), systemImage: "eye.slash")
                        Spacer()
                        Text("\(currentHostHiddenElementCount)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } header: {
                    SectionHeader(title: currentHost)
                } footer: {
                    Text(LanguageManager.shared.localizedString("ad_block_site_toggle_desc"))
                }
            }

            Section {
                HStack {
                    Label(LanguageManager.shared.localizedString("ad_block_total_hidden"), systemImage: "eye.slash.fill")
                    Spacer()
                    Text("\(totalHiddenElementCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    Label(LanguageManager.shared.localizedString("ad_block_allowlisted_count"), systemImage: "shield.slash")
                    Spacer()
                    Text("\(service.allowlistedHosts.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                HStack {
                    Label(LanguageManager.shared.localizedString("ad_block_subscription_rules"), systemImage: "shield.lefthalf.filled")
                    Spacer()
                    Text("\(subscriptionRuleCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if totalHiddenElementCount > 0 {
                    Button(role: .destructive) {
                        service.resetStats()
                    } label: {
                        Label(LanguageManager.shared.localizedString("ad_block_reset_stats"), systemImage: "arrow.counterclockwise")
                    }
                }
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("ad_block_stats"))
            } footer: {
                Text(LanguageManager.shared.localizedString("ad_block_stats_desc"))
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
                .disabled(subscriptionService.isUpdating)

                ForEach(subscriptionService.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: Binding(
                            get: { subscription.isEnabled },
                            set: { enabled in
                                subscriptionService.setEnabled(enabled, for: subscription)
                                onChanged?()
                            }
                        )) {
                            Text(subscription.name)
                        }
                        .tint(.green)

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
                }

                Button(role: .destructive) {
                    subscriptionService.resetToDefaults()
                    onChanged?()
                } label: {
                    Label(LanguageManager.shared.localizedString("ad_block_subscription_reset"), systemImage: "arrow.counterclockwise")
                }
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("ad_block_subscriptions"))
            } footer: {
                Text(LanguageManager.shared.localizedString("ad_block_subscriptions_desc"))
            }

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
    }
}
