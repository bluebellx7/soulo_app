import SwiftUI

struct GroupSearchSettingsView: View {
    let scope: SearchGroupScope
    let originalName: String
    let onSaveName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var groupName = ""
    @State private var engine = GroupDefaultSearchEngine.presets[0]
    @State private var engineName = ""
    @State private var template = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LanguageManager.shared.localizedString("group_name"), text: $groupName)
                        .accessibilityIdentifier("group-search.name")
                }
                Section {
                    Menu {
                        ForEach(GroupDefaultSearchEngine.presets) { preset in
                            Button(LanguageManager.shared.localizedString(preset.name)) { setEngine(preset) }
                        }
                    } label: {
                        LabeledContent(ToolText.text("group_default_search"), value: engineName)
                    }.accessibilityIdentifier("group-search.presets")
                    TextField(ToolText.text("group_engine_name"), text: $engineName)
                        .accessibilityIdentifier("group-search.engineName")
                    TextField(ToolText.text("group_search_url"), text: $template, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(2...4).accessibilityIdentifier("group-search.template")
                } header: { Text(ToolText.text("group_default_search")) }
                  footer: { Text(ToolText.text("group_default_search_hint")) }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(ToolText.text("group_search_settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("save")) { save() }
                        .disabled(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("group-search.save")
                }
            }
            .onAppear {
                groupName = originalName
                setEngine(GroupDefaultSearchService.shared.engine(for: scope))
            }
        }
    }
    private func setEngine(_ value: GroupDefaultSearchEngine) {
        engine = value; engineName = LanguageManager.shared.localizedString(value.name); template = value.template
    }
    private func save() {
        let value = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GroupDefaultSearchEngine.validTemplate(value), !engineName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = ToolText.text("group_search_url_invalid"); return
        }
        var next = engine
        // Keep localization keys for unchanged built-in names.
        next.name = engineName == LanguageManager.shared.localizedString(engine.name) ? engine.name : engineName.trimmingCharacters(in: .whitespacesAndNewlines)
        next.template = value
        if var home = URLComponents(string: value.replacingOccurrences(of: "%@", with: "test")) {
            home.path = ""; home.query = nil; home.fragment = nil
            next.homeURL = home.url?.absoluteString ?? ""
        }
        do {
            try GroupDefaultSearchService.shared.save(next, for: scope)
            onSaveName(groupName.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
