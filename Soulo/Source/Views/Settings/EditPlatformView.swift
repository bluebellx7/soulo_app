import SwiftUI

struct EditPlatformView: View {
    let platform: SearchPlatform
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var searchURL: String = ""
    @State private var homeURL: String = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageManager.shared.localizedString("add_platform_name"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("", text: $name)
                            .font(.system(size: 15))
                            .disabled(platform.isBuiltIn)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageManager.shared.localizedString("add_platform_search_url"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://example.com/search?q=%@", text: $searchURL, axis: .vertical)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(2...5)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(LanguageManager.shared.localizedString("add_platform_home_url"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField("https://example.com", text: $homeURL, axis: .vertical)
                            .font(.system(size: 13, design: .monospaced))
                            .lineLimit(2...4)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                } footer: {
                    Text(LanguageManager.shared.localizedString("search_url_hint"))
                        .font(.caption)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LanguageManager.shared.localizedString("edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("save")) {
                        save()
                    }
                    .fontWeight(.semibold)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                // Pre-fill with existing values
                // For built-in platforms, name is a localization key
                if platform.isBuiltIn {
                    name = LanguageManager.shared.localizedString(platform.name)
                } else {
                    name = platform.name
                }
                searchURL = platform.searchURLTemplate
                homeURL = platform.homeURL
            }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        if !searchURL.contains("%@") {
            errorMessage = LanguageManager.shared.localizedString("url_template_error")
            return
        }

        let trimmedHomeURL = homeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let template = SearchPlatformURLInput.searchTemplate(searchURL),
              trimmedHomeURL.isEmpty || SearchPlatformURLInput.webURL(from: trimmedHomeURL) != nil else {
            errorMessage = LanguageManager.shared.localizedString("platform_invalid_web_url")
            return
        }

        PlatformDataStore.shared.updatePlatform(
            id: platform.id,
            name: platform.isBuiltIn ? platform.name : trimmedName, // keep localization key for built-in
            searchURL: template,
            homeURL: trimmedHomeURL
        )
        dismiss()
    }
}
