import SwiftUI

struct ElementBlockManagementView: View {
    @ObservedObject private var service = ElementBlockService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showClearConfirm = false

    let currentHost: String?
    var onChanged: (() -> Void)? = nil

    private var currentHostRules: [BlockedElementRule] {
        service.storedRules(for: currentHost)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var otherRulesByHost: [(String, [BlockedElementRule])] {
        Dictionary(grouping: service.rules.filter { rule in
            guard let currentHost else { return true }
            return rule.host != AdBlockSettingsService.normalizedHost(currentHost)
        }, by: \.host)
        .sorted { $0.key < $1.key }
        .map { ($0.key, $0.value.sorted { $0.createdAt > $1.createdAt }) }
    }

    var body: some View {
        List {
            if let currentHost {
                Section {
                    Toggle(isOn: Binding(
                        get: { !service.isDisabled(for: currentHost) },
                        set: { enabled in
                            service.setDisabled(!enabled, for: currentHost)
                            onChanged?()
                        }
                    )) {
                        Label(LanguageManager.shared.localizedString("element_block_enabled_current_site"), systemImage: "nosign")
                    }
                    .tint(.red)

                    Button {
                        service.removeAll(for: currentHost)
                        onChanged?()
                    } label: {
                        Label(LanguageManager.shared.localizedString("restore_current_site"), systemImage: "arrow.uturn.backward.circle")
                    }
                    .disabled(currentHostRules.isEmpty)
                } header: {
                    SectionHeader(title: currentHost)
                }

                if !currentHostRules.isEmpty {
                    Section {
                        ForEach(currentHostRules) { rule in
                            ruleRow(rule)
                        }
                    } header: {
                        SectionHeader(title: LanguageManager.shared.localizedString("element_block_total_rules"))
                    }
                }
            }

            ForEach(otherRulesByHost, id: \.0) { host, rules in
                Section {
                    ForEach(rules) { rule in
                        ruleRow(rule)
                    }
                } header: {
                    SectionHeader(title: host)
                }
            }

            if !service.disabledHosts.isEmpty {
                Section {
                    ForEach(service.disabledHosts, id: \.self) { host in
                        HStack {
                            Label(host, systemImage: "pause.circle")
                            Spacer()
                            Button(LanguageManager.shared.localizedString("restore")) {
                                service.setDisabled(false, for: host)
                                onChanged?()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    SectionHeader(title: LanguageManager.shared.localizedString("element_block_disabled_sites"))
                }
            }

            if !service.rules.isEmpty || !service.disabledHosts.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label(LanguageManager.shared.localizedString("element_block_restore_all"), systemImage: "trash")
                    }
                }
            }
        }
        .overlay {
            if service.rules.isEmpty && service.disabledHosts.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("no_blocked_elements"),
                    systemImage: "nosign",
                    description: Text(LanguageManager.shared.localizedString("no_blocked_elements_desc"))
                )
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("manage_blocked_elements"))
        .alert(LanguageManager.shared.localizedString("element_block_restore_all"), isPresented: $showClearConfirm) {
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            Button(LanguageManager.shared.localizedString("restore"), role: .destructive) {
                service.removeAllRules()
                service.enableAllHosts()
                onChanged?()
            }
        } message: {
            Text(LanguageManager.shared.localizedString("element_block_restore_all_desc"))
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func ruleRow(_ rule: BlockedElementRule) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "eye.slash")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.label.isEmpty ? LanguageManager.shared.localizedString("block_element") : rule.label)
                    .font(.body)
                    .lineLimit(2)
                if !rule.pageTitle.isEmpty {
                    Text(rule.pageTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button(LanguageManager.shared.localizedString("restore")) {
                service.removeRule(rule)
                onChanged?()
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)
        }
        .swipeActions {
            Button(role: .destructive) {
                service.removeRule(rule)
                onChanged?()
            } label: {
                Label(LanguageManager.shared.localizedString("restore"), systemImage: "trash")
            }
        }
    }
}
