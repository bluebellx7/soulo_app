import SwiftUI

struct AdBlockManagementView: View {
    @ObservedObject private var service = AdBlockSettingsService.shared
    @ObservedObject private var subscriptionService = AdBlockSubscriptionService.shared
    @ObservedObject private var manualRules = ManualAdBlockService.shared
    @ObservedObject private var builtInRules = BuiltInAdRuleStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true
    @AppStorage(BrowserAutomaticNavigationPolicy.preferenceKey) private var allowsAutomaticNavigation = true
    @State private var showsStatistics = false

    let currentHost: String?
    var showsDoneButton = false
    var currentURL: URL? = nil
    var onMarkAdvertisement: (() -> Void)? = nil
    var onChanged: (() -> Void)? = nil

    private var currentHostUsesCompatibilityBypass: Bool {
        WebCompatibilityService.shouldBypassWebProtection(for: currentURL, fallbackHost: currentHost)
    }
    private var currentHostProtectionEnabled: Bool {
        adBlockEnabled && !service.isAllowlisted(currentHost) && !currentHostUsesCompatibilityBypass
    }

    var body: some View {
        List {
            Section(ToolText.text("ad_filter_settings")) {
                Toggle(isOn: $adBlockEnabled) {
                    Label(LanguageManager.shared.localizedString("ad_block"), systemImage: "shield.checkered")
                }
                .tint(.green)
                .accessibilityIdentifier("adBlock.enabled")
                Toggle(isOn: $allowsAutomaticNavigation) {
                    Label(ToolText.text("ad_allow_redirects"), systemImage: "arrow.turn.up.right")
                }
                .accessibilityIdentifier("adBlock.allowAutomaticNavigation")
            }

            if let currentHost {
                Section {
                    Toggle(isOn: Binding(
                        get: { !service.isAllowlisted(currentHost) },
                        set: { enabled in
                            if enabled { service.removeAllowlistedHost(currentHost) }
                            else { service.addAllowlistedHost(currentHost) }
                            onChanged?()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentHost).font(.body.weight(.medium))
                            Text(LanguageManager.shared.localizedString(currentHostProtectionEnabled ? "status_enabled" : "status_disabled"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tint(.green)
                    .disabled(!adBlockEnabled || currentHostUsesCompatibilityBypass)
                    .accessibilityIdentifier("adBlock.currentSite")
                    if let onMarkAdvertisement {
                        Button(action: onMarkAdvertisement) {
                            Label(ToolText.text("manual_ad_mark"), systemImage: "viewfinder")
                        }
                        .disabled(!currentHostProtectionEnabled)
                        .accessibilityIdentifier("adBlock.markAdvertisement")
                    }
                } header: {
                    Text(ToolText.text("manual_ad_current_site"))
                } footer: {
                    if currentHostUsesCompatibilityBypass {
                        Text(LanguageManager.shared.localizedString("site_privacy_compatibility_bypass"))
                    } else if !adBlockEnabled {
                        Text(LanguageManager.shared.localizedString("ad_block_master_disabled_desc"))
                    }
                }
            }

            Section(ToolText.text("ad_rule_management")) {
                NavigationLink {
                    ManualAdRulesView(currentHost: currentHost)
                } label: {
                    ruleRow(ToolText.text("manual_ad_rules"), icon: "eye.slash", count: manualRules.rules.count)
                }
                .accessibilityIdentifier("adBlock.manualRules")
                NavigationLink {
                    BuiltInAdRulesView(onChanged: onChanged)
                } label: {
                    ruleRow(ToolText.text("builtin_rules"), icon: "line.3.horizontal.decrease", count: builtInRules.rules.count)
                }
                .accessibilityIdentifier("adBlock.builtInRules")
                NavigationLink {
                    AdBlockSubscriptionsView(onChanged: onChanged)
                } label: {
                    ruleRow(LanguageManager.shared.localizedString("ad_block_subscriptions"), icon: "arrow.triangle.2.circlepath", count: subscriptionService.subscriptions.filter(\.isEnabled).count)
                }
                .accessibilityIdentifier("adBlock.subscriptions")
                NavigationLink {
                    AdBlockAllowedSitesView(onChanged: onChanged)
                } label: {
                    ruleRow(LanguageManager.shared.localizedString("ad_block_allowlist"), icon: "shield.slash", count: service.allowlistedHosts.count)
                }
                .accessibilityIdentifier("adBlock.allowedSites")
            }

            Section {
                DisclosureGroup(isExpanded: $showsStatistics) {
                    if currentHost != nil {
                        AdBlockMetricRow(title: LanguageManager.shared.localizedString("ad_block_current_site_hidden"), systemImage: "eye.slash", value: service.hiddenElementCount(for: currentHost), isHighlighted: false)
                    }
                    AdBlockMetricRow(title: LanguageManager.shared.localizedString("ad_block_total_hidden"), systemImage: "sum", value: service.hiddenElementCountByHost.values.reduce(0, +), isHighlighted: false)
                } label: {
                    Label(ToolText.text("ad_filter_statistics"), systemImage: "chart.bar")
                }
                .accessibilityIdentifier("adBlock.statistics")
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
        .onChange(of: adBlockEnabled) { _, _ in onChanged?() }
    }

    private func ruleRow(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(.blue).frame(width: 22)
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(count.formatted()).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

private struct AdBlockSubscriptionsView: View {
    @ObservedObject private var subscriptionService = AdBlockSubscriptionService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true
    var onChanged: (() -> Void)?
    var body: some View {
        List {
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
                Text(adBlockEnabled ? ToolText.text("ad_subscription_hint") : LanguageManager.shared.localizedString("ad_block_master_disabled_desc"))
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

        }
        .navigationTitle(LanguageManager.shared.localizedString("ad_block_subscriptions"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AdBlockAllowedSitesView: View {
    @ObservedObject private var service = AdBlockSettingsService.shared
    var onChanged: (() -> Void)?
    var body: some View {
        List {
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
        .overlay {
            if service.allowlistedHosts.isEmpty {
                ContentUnavailableView(ToolText.text("ad_allowlist_empty"), systemImage: "shield.checkered")
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("ad_block_allowlist"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BuiltInAdRulesView: View {
    @ObservedObject private var store = BuiltInAdRuleStore.shared
    @State private var search = ""
    @State private var confirmReset = false
    var onChanged: (() -> Void)?
    private var rules: [BuiltInAdRule] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.rules.filter { query.isEmpty || $0.pattern.localizedCaseInsensitiveContains(query)
            || $0.domains.joined(separator: " ").localizedCaseInsensitiveContains(query)
            || ($0.kind == .tiledBanner && ToolText.text("builtin_tiled").localizedCaseInsensitiveContains(query)) }
    }
    var body: some View {
        List {
            Section {
                Text(ToolText.text("builtin_hint")).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rules) { rule in
                NavigationLink {
                    BuiltInAdRuleEditor(rule: rule, onChanged: onChanged)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(rule.kind == .tiledBanner ? ToolText.text("builtin_tiled") : rule.pattern)
                            .font(.subheadline).lineLimit(2)
                        HStack {
                            Text(rule.domains.isEmpty ? ToolText.text("builtin_all_sites") : rule.domains.joined(separator: ", "))
                                .lineLimit(1)
                            Spacer()
                            Text(LanguageManager.shared.localizedString(rule.isEnabled ? "status_enabled" : "status_disabled"))
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                .accessibilityIdentifier("builtInRule.\(rule.id)")
            }
        }
        .searchable(text: $search, prompt: ToolText.text("builtin_search"))
        .navigationTitle(ToolText.text("builtin_rules"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(ToolText.text("builtin_reset")) { confirmReset = true }
            }
        }
        .confirmationDialog(ToolText.text("builtin_reset_all"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(ToolText.text("builtin_reset"), role: .destructive) { store.reset(); onChanged?() }
        }
    }
}

private struct BuiltInAdRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: BuiltInAdRule
    @State private var domains: String
    @State private var resources: String
    @State private var saving = false
    @State private var invalid = false
    var onChanged: (() -> Void)?
    init(rule: BuiltInAdRule, onChanged: (() -> Void)?) {
        _draft = State(initialValue: rule)
        _domains = State(initialValue: rule.domains.joined(separator: ", "))
        _resources = State(initialValue: rule.resourceTypes.joined(separator: ", "))
        self.onChanged = onChanged
    }
    var body: some View {
        Form {
            Section {
                Toggle(ToolText.text("builtin_enabled"), isOn: $draft.isEnabled)
                    .accessibilityIdentifier("builtInRule.enabled")
            }
            if draft.kind == .tiledBanner {
                Section { Text(ToolText.text("builtin_tiled_hint")) }
            } else {
                Section(ToolText.text(draft.kind == .network ? "builtin_url_pattern" : "builtin_selector")) {
                    TextEditor(text: $draft.pattern).font(.body.monospaced()).frame(minHeight: 100)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("builtInRule.pattern")
                }
                Section {
                    TextField(ToolText.text("builtin_all_sites"), text: $domains)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("builtInRule.domains")
                } header: { Text(ToolText.text("builtin_domains")) }
                  footer: { Text(ToolText.text("builtin_domains_hint")) }
                if draft.kind == .network {
                    Section(ToolText.text("builtin_resources")) {
                        TextField("script, image, raw", text: $resources)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                    }
                }
            }
            Section {
                Button(ToolText.text("builtin_reset")) {
                    if let original = AdBlockService.defaultBuiltInRules.first(where: { $0.id == draft.id }) {
                        draft = original
                        domains = original.domains.joined(separator: ", ")
                        resources = original.resourceTypes.joined(separator: ", ")
                    }
                }
            }
        }
        .disabled(saving)
        .navigationTitle(ToolText.text("builtin_edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LanguageManager.shared.localizedString("save")) {
                    draft.pattern = draft.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.domains = split(domains).map { $0.lowercased() }
                    draft.resourceTypes = split(resources)
                    saving = true
                    Task { @MainActor in
                        if await BuiltInAdRuleStore.shared.save(draft) { onChanged?(); dismiss() }
                        else { invalid = true }
                        saving = false
                    }
                }.disabled(saving).accessibilityIdentifier("builtInRule.save")
            }
        }
        .alert(ToolText.text("builtin_invalid"), isPresented: $invalid) {
            Button(ToolText.text("done"), role: .cancel) {}
        }
    }
    private func split(_ text: String) -> [String] {
        text.replacingOccurrences(of: "，", with: ",").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

private struct ManualAdRulesView: View {
    @ObservedObject private var service = ManualAdBlockService.shared
    @ObservedObject private var settings = AdBlockSettingsService.shared
    @AppStorage("ad_block_enabled") private var adBlockEnabled = true
    @State private var searchText = ""
    @State private var selectedRule: ManualAdRule?
    @State private var removedRules: [ManualAdRule] = []
    @State private var expandedHosts: [String: Bool] = [:]
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
                    DisclosureGroup(isExpanded: expansion(for: group.host)) {
                        Button {
                            removedRules = service.remove(host: group.host)
                        } label: {
                            Label(ToolText.text("manual_ad_restore_site"), systemImage: "arrow.uturn.backward")
                                .frame(minHeight: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("manualAds.restoreHost.\(group.host)")
                        ForEach(group.rules) { rule in ruleRow(rule) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(group.host).font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if group.host == currentHost?.lowercased() {
                                    Text(ToolText.text("manual_ad_current_site"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text("\(group.rules.count)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("manualAds.host.\(group.host)")
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
            if let rule = removedRules.first {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ToolText.text("manual_ad_removed")).font(.subheadline.weight(.medium))
                        Text(rule.host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button(ToolText.text("manual_ad_undo")) {
                        if service.restore(removedRules) { removedRules = [] }
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
                    if removedRules.first?.id == rule.id { removedRules = [] }
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
        removedRules = [rule]
    }

    private func expansion(for host: String) -> Binding<Bool> {
        Binding {
            expandedHosts[host] ?? (host == currentHost?.lowercased()
                || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } set: { expandedHosts[host] = $0 }
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
