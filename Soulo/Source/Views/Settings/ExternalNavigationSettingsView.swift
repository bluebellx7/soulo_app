import SwiftUI

struct ExternalNavigationSettingsView: View {
    @ObservedObject private var service = ExternalNavigationService.shared

    var body: some View {
        List {
            Section {
                Toggle(LanguageManager.shared.localizedString("never_prompt_external"), isOn: $service.suppressPrompts)
            } footer: {
                Text(LanguageManager.shared.localizedString("never_prompt_external_desc"))
            }

            Section {
                ForEach(Array(service.blockedHosts).sorted(), id: \.self) { host in
                    HStack {
                        Text(host)
                        Spacer()
                        Button(LanguageManager.shared.localizedString("restore")) {
                            service.removeHost(host)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if !service.blockedHosts.isEmpty {
                    Button(role: .destructive) {
                        service.clear()
                        service.suppressPrompts = false
                    } label: {
                        Label(LanguageManager.shared.localizedString("clear_all"), systemImage: "trash")
                    }
                }
            } header: {
                SectionHeader(title: LanguageManager.shared.localizedString("blocked_external_hosts"))
            }
        }
        .overlay {
            if service.blockedHosts.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("no_external_hosts"),
                    systemImage: "arrow.up.forward.app",
                    description: Text(LanguageManager.shared.localizedString("no_external_hosts_desc"))
                )
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("external_navigation"))
    }
}
