import SwiftUI

struct GroupSearchSettingsView: View {
    let scope: SearchGroupScope
    let originalName: String
    let onSaveName: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = PlatformDataStore.shared
    @State private var groupName = ""
    @State private var engine = GroupDefaultSearchEngine.presets[0]
    @State private var engineName = ""
    @State private var template = ""
    @State private var error: String?
    private struct EngineOption: Identifiable {
        let source: String
        let engine: GroupDefaultSearchEngine
        var id: String { source + ":" + engine.id.uuidString }
    }
    private var groupOptions: [EngineOption] {
        GroupDefaultSearchEngine.groupOptions(for: scope, platforms: store.platforms, customGroups: store.customGroups)
            .map { EngineOption(source: scope.id, engine: $0) }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(LanguageManager.shared.localizedString("group_name"), text: $groupName)
                        .accessibilityIdentifier("group-search.name")
                }
                Section {
                    Menu {
                        Section(ToolText.text("group_default_search")) {
                            ForEach(GroupDefaultSearchEngine.presets.map { EngineOption(source: "preset", engine: $0) }) { option in
                                Button(LanguageManager.shared.localizedString(option.engine.name)) { setEngine(option.engine) }
                            }
                        }
                        if !groupOptions.isEmpty {
                            Section(groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? originalName : groupName) {
                                ForEach(groupOptions) { option in
                                    Button(LanguageManager.shared.localizedString(option.engine.name)) { setEngine(option.engine) }
                                        .disabled(!option.engine.hasValidURLs)
                                }
                            }
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
            .dismissKeyboardOnBackgroundTap()
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
        // Selecting a platform must preserve its explicit homepage, including
        // its path. Only derive a new homepage when the user edits the URL.
        if value != engine.template {
            next.homeURL = value.contains("%@") ? SearchPlatformURLInput.derivedHomeURL(from: value) : value
        }
        do {
            try GroupDefaultSearchService.shared.save(next, for: scope)
            onSaveName(groupName.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
