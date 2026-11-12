import SwiftUI

struct WebsiteZoomSettingsView: View {
    @ObservedObject private var store = WebsiteZoomStore.shared
    @State private var confirmReset = false
    private var hosts: [String] { store.sites.keys.sorted() }

    var body: some View {
        List {
            Section {
                Toggle(ToolText.text("zoom_remember"), isOn: $store.isEnabled)
                    .accessibilityIdentifier("settings.zoom.remember")
            } footer: { Text(ToolText.text("zoom_hint")) }
            Section {
                if hosts.isEmpty {
                    Label(ToolText.text("zoom_empty"), systemImage: "text.magnifyingglass")
                        .foregroundStyle(.secondary).padding(.vertical, 16)
                }
                ForEach(hosts, id: \.self) { host in
                    Stepper(value: Binding(get: { store.sites[host] ?? 1 }, set: { store.set($0, for: URL(string: "https://" + host)) }),
                            in: 0.5...2, step: 0.1) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host).font(.body).lineLimit(2)
                            Text("\(Int(((store.sites[host] ?? 1) * 100).rounded()))%")
                                .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!store.isEnabled)
                    .accessibilityIdentifier("settings.zoom.site.\(host)")
                }.onDelete { offsets in
                    let current = hosts
                    for index in offsets { store.reset(host: current[index]) }
                }
            }
            if !hosts.isEmpty {
                Section {
                    Button(ToolText.text("zoom_reset_all"), role: .destructive) { confirmReset = true }
                }
            }
        }
        .listStyle(.insetGrouped).tint(.themePrimary)
        .navigationTitle(ToolText.text("page_zoom"))
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(ToolText.text("zoom_reset_all"), isPresented: $confirmReset, titleVisibility: .visible) {
            Button(ToolText.text("zoom_reset_all"), role: .destructive) { store.resetAll() }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
    }
}
