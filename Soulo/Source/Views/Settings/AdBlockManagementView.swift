import SwiftUI

struct AdBlockManagementView: View {
    @ObservedObject private var service = AdBlockSettingsService.shared
    @ObservedObject private var subscriptionService = AdBlockSubscriptionService.shared
    @ObservedObject private var manualRules = ManualAdBlockService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true

    let currentHost: String?
    var showsDoneButton = false
    var currentURL: URL? = nil
    var onMarkAdvertisement: (() -> Void)? = nil
    var onChanged: (() -> Void)? = nil

    private var currentHostIsAllowlisted: Bool {
        service.isAllowlisted(currentHost)
    }

    private var currentHostProtectionEnabled: Bool {
        adBlockEnabled && !currentHostIsAllowlisted && !currentHostUsesCompatibilityBypass
    }

    private var currentHostUsesCompatibilityBypass: Bool {
        WebCompatibilityService.shouldBypassWebProtection(
            for: currentURL,
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
                if let onMarkAdvertisement {
                    Button(action: onMarkAdvertisement) {
                        Label(ToolText.text("manual_ad_mark"), systemImage: "viewfinder")
                    }
                    .disabled(!currentHostProtectionEnabled)
                }
                if manualRules.rules.isEmpty {
                    Text(ToolText.text("manual_ad_hint")).foregroundStyle(.secondary)
                } else {
                    NavigationLink {
                        ManualAdRulesView(currentHost: currentHost)
                    } label: {
                        HStack {
                            Label(ToolText.text("manual_ad_rules"), systemImage: "eye.slash")
                            Spacer()
                            Text("\(manualRules.rules.count)").foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("adBlock.manualRules")
                }
            } header: {
                Text(ToolText.text("manual_ad_rules"))
            } footer: {
                Text(ToolText.text("manual_ad_footer"))
            }

            Section {
                ForEach(subscriptionService.subscriptions) { subscription in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(subscription.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(subscription.isEnabled ? Color.primary : Color.secondary)
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
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        if !subscription.errorMessage.isEmpty {
                            Label(subscription.errorMessage, systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    SectionHeader(title: LanguageManager.shared.localizedString("ad_block_subscriptions"))
                    Spacer()
                    Button {
                        Task {
                            await subscriptionService.updateEnabledSubscriptions()
                            onChanged?()
                        }
                    } label: {
                        if subscriptionService.isUpdating { ProgressView().frame(width: 44, height: 44) }
                        else { CompactIconLabel(systemImage: "arrow.clockwise", emphasized: true) }
                    }
                    .buttonStyle(.plain)
                    .disabled(subscriptionService.isUpdating || !adBlockEnabled)
                    .accessibilityLabel(LanguageManager.shared.localizedString("ad_block_subscription_update"))
                }.textCase(nil)
            } footer: {
                Text(
                    LanguageManager.shared.localizedString(
                        adBlockEnabled ? "ad_block_subscriptions_desc" : "ad_block_master_disabled_desc"
                    )
                )
            }
            .opacity(adBlockEnabled ? 1 : 0.48)

            Section(ToolText.text("rule_maintenance")) {
                Button(role: .destructive) {
                    subscriptionService.resetToDefaults()
                    onChanged?()
                } label: {
                    Label(LanguageManager.shared.localizedString("ad_block_subscription_reset"), systemImage: "arrow.counterclockwise")
                }
                .disabled(!adBlockEnabled)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
        .onChange(of: adBlockEnabled) { _, _ in
            onChanged?()
        }
    }
}

private struct ManualAdRulesView: View {
    @ObservedObject private var service = ManualAdBlockService.shared
    @ObservedObject private var settings = AdBlockSettingsService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true
    @State private var searchText = ""
    @State private var selectedRule: ManualAdRule?
    @State private var removedRule: ManualAdRule?
    @State private var showUndoError = false
    let currentHost: String?

    private var groupedRules: [(host: String, rules: [ManualAdRule])] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = service.rules.filter {
            query.isEmpty || $0.host.localizedCaseInsensitiveContains(query)
                || ($0.path?.removingPercentEncoding ?? $0.path ?? "").localizedCaseInsensitiveContains(query)
                || $0.selector.localizedCaseInsensitiveContains(query)
        }
        return Dictionary(grouping: filtered, by: \.host).map { host, rules in
            (host, rules.sorted { $0.createdAt > $1.createdAt })
        }.sorted {
            let current = currentHost?.lowercased()
            if ($0.host == current) != ($1.host == current) { return $0.host == current }
            return $0.host < $1.host
        }
    }

    var body: some View {
        List {
            if !service.rules.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: ToolText.text("manual_ad_summary"), service.rules.count, Set(service.rules.map(\.host)).count))
                            .font(.headline)
                        Text(ToolText.text("manual_ad_list_hint"))
                            .font(.footnote).foregroundStyle(.secondary)
                        if !adBlockEnabled {
                            Label(ToolText.text("manual_ad_paused"), systemImage: "pause.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                }
            }
            ForEach(groupedRules, id: \.host) { group in
                Section {
                    ForEach(group.rules) { rule in ruleRow(rule) }
                } header: {
                    HStack {
                        Text(group.host).textCase(nil)
                        if group.host == currentHost?.lowercased() {
                            Text(ToolText.text("manual_ad_current_site"))
                                .font(.caption2).textCase(nil)
                        }
                        Spacer()
                        Text("\(group.rules.count)").monospacedDigit()
                    }
                } footer: {
                    if AdBlockSettingsService.isHostAllowlisted(group.host, allowlistedHosts: settings.allowlistedHosts) {
                        Text(ToolText.text("manual_ad_site_paused"))
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: Text(ToolText.text("manual_ad_search")))
        .overlay {
            if service.rules.isEmpty {
                ContentUnavailableView(ToolText.text("manual_ad_empty"), systemImage: "eye.slash",
                    description: Text(ToolText.text("manual_ad_empty_hint")))
            } else if groupedRules.isEmpty {
                ContentUnavailableView.search(text: searchText)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let rule = removedRule {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ToolText.text("manual_ad_removed")).font(.subheadline.weight(.medium))
                        Text(rule.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(ToolText.text("manual_ad_undo")) {
                        if service.restore(rule) { removedRule = nil }
                        else { showUndoError = true }
                    }
                    .accessibilityIdentifier("manualAds.undo")
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16).padding(.bottom, 8)
                .task(id: rule.id) {
                    do { try await Task.sleep(for: .seconds(8)) }
                    catch { return }
                    if removedRule?.id == rule.id { removedRule = nil }
                }
            }
        }
        .navigationTitle(ToolText.text("manual_ad_rules"))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedRule) { rule in
            NavigationStack {
                Form {
                    Section {
                        LabeledContent(ToolText.text("manual_ad_domain"), value: rule.host)
                        LabeledContent(ToolText.text("manual_ad_scope"), value: ToolText.text(rule.path == nil ? "manual_ad_site" : "manual_ad_page_rule"))
                        if let path = rule.path {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ToolText.text("manual_ad_path")).foregroundStyle(.secondary)
                                Text(path.removingPercentEncoding ?? path).textSelection(.enabled)
                            }
                        }
                        LabeledContent(ToolText.text("manual_ad_created")) {
                            Text(rule.createdAt, format: .dateTime.year().month().day().hour().minute())
                        }
                    }
                    Section {
                        Text(rule.selector).font(.footnote.monospaced()).textSelection(.enabled)
                    } header: {
                        Text(ToolText.text("manual_ad_selector"))
                    } footer: {
                        Text(ToolText.text("manual_ad_selector_hint"))
                    }
                    Section {
                        Button(LanguageManager.shared.localizedString("restore")) {
                            remove(rule)
                            selectedRule = nil
                        }
                    } footer: {
                        Text(ToolText.text("manual_ad_list_hint"))
                    }
                }
                .navigationTitle(ToolText.text("manual_ad_details"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LanguageManager.shared.localizedString("done")) { selectedRule = nil }
                    }
                }
            }
        }
        .alert(ToolText.text("manual_ad_undo_failed"), isPresented: $showUndoError) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        }
    }

    private func ruleRow(_ rule: ManualAdRule) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { selectedRule = rule } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: rule.path == nil ? "globe" : "doc.text")
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 38)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(ToolText.text(rule.path == nil ? "manual_ad_site" : "manual_ad_page_rule"))
                            .font(.subheadline.weight(.semibold))
                        Text(rule.path.map { $0.removingPercentEncoding ?? $0 } ?? ToolText.text("manual_ad_all_paths"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(rule.selector).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("manualAds.rule.\(rule.id)")
            HStack {
                Text(rule.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { remove(rule) } label: {
                    Label(LanguageManager.shared.localizedString("restore"), systemImage: "arrow.uturn.backward")
                        .font(.subheadline)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderless)
                .tint(.primary)
            }
        }.padding(.vertical, 4)
    }

    private func remove(_ rule: ManualAdRule) {
        service.remove(rule.id)
        removedRule = rule
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
