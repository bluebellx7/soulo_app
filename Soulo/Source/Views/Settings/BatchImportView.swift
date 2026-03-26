import SwiftUI

struct BatchImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var jsonText = ""
    @State private var groupName = ""
    @State private var selectedRegion: PlatformRegion = .international
    @State private var selectedCustomGroupID: UUID? = nil
    @State private var useNewGroup = false
    @State private var importResult: String? = nil
    @State private var isImporting = false

    private enum GroupSelection {
        case region(PlatformRegion)
        case customGroup(UUID)
        case newGroup
    }
    @State private var selection: GroupSelection = .region(.international)

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Instructions
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        LanguageManager.shared.localizedString("batch_import_format"),
                        systemImage: "info.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.blue)

                    Text("[{\"name\": \"xxx\", \"url\": \"https://...?wd=%@\"}, ...]")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 20)

                // JSON input
                VStack(alignment: .leading, spacing: 6) {
                    Text("JSON")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 20)

                    TextEditor(text: $jsonText)
                        .font(.system(size: 13, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 160)
                        .padding(10)
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.horizontal, 20)
                }

                // Paste from clipboard button
                Button {
                    if let clip = UIPasteboard.general.string, !clip.isEmpty {
                        jsonText = clip
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 14))
                        Text(LanguageManager.shared.localizedString("paste_from_clipboard"))
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.blue)
                }

                // Group selection
                VStack(alignment: .leading, spacing: 6) {
                    Text(LanguageManager.shared.localizedString("batch_import_group"))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Menu {
                        // All groups (built-in + custom) in one flat list
                        ForEach(PlatformRegion.allCases, id: \.self) { region in
                            Button {
                                selection = .region(region)
                            } label: {
                                HStack {
                                    Text(PlatformDataStore.shared.regionDisplayName(for: region))
                                    if case .region(let r) = selection, r == region {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        ForEach(PlatformDataStore.shared.customGroups) { group in
                            Button {
                                selection = .customGroup(group.id)
                            } label: {
                                HStack {
                                    Text(group.name)
                                    if case .customGroup(let gid) = selection, gid == group.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Divider()

                        Button {
                            selection = .newGroup
                            groupName = ""
                        } label: {
                            Label(LanguageManager.shared.localizedString("add_group"), systemImage: "folder.badge.plus")
                        }
                    } label: {
                        HStack {
                            Text(currentGroupLabel)
                                .foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if case .newGroup = selection {
                        TextField(
                            LanguageManager.shared.localizedString("batch_import_group_placeholder"),
                            text: $groupName
                        )
                        .font(.body)
                        .padding(12)
                        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 20)

                // Result
                if let result = importResult {
                    Text(result)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(result.contains("0") ? .orange : .green)
                        .padding(.horizontal, 20)
                }

                Spacer()

                // Import button
                Button {
                    doImport()
                } label: {
                    HStack(spacing: 8) {
                        if isImporting {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        Text(LanguageManager.shared.localizedString("batch_import_action"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(
                        LinearGradient(
                            colors: jsonText.isEmpty ? [.gray.opacity(0.4), .gray.opacity(0.3)] : [Color(hex: "6366F1"), Color(hex: "7C3AED")],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14)
                    )
                }
                .disabled(jsonText.isEmpty || isImporting)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
            .padding(.top, 16)
            .navigationTitle(LanguageManager.shared.localizedString("batch_import"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }
                }
            }
        }
    }

    private var currentGroupLabel: String {
        switch selection {
        case .region(let r):
            return PlatformDataStore.shared.regionDisplayName(for: r)
        case .customGroup(let gid):
            return PlatformDataStore.shared.customGroups.first(where: { $0.id == gid })?.name ?? ""
        case .newGroup:
            return LanguageManager.shared.localizedString("add_group")
        }
    }

    private func doImport() {
        isImporting = true

        // Determine region and group name
        let region: PlatformRegion
        let importGroupName: String?

        switch selection {
        case .region(let r):
            region = r
            importGroupName = nil
        case .customGroup(let gid):
            region = .international
            importGroupName = PlatformDataStore.shared.customGroups.first(where: { $0.id == gid })?.name
        case .newGroup:
            region = .international
            importGroupName = groupName.isEmpty ? nil : groupName
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let count = PlatformDataStore.shared.importPlatformsFromJSON(
                jsonText,
                groupName: importGroupName,
                region: region
            )
            importResult = String(format: LanguageManager.shared.localizedString("batch_import_result"), count)
            isImporting = false
            if count > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            }
        }
    }
}
