import SwiftUI

struct AddCustomPlatformView: View {
    var targetGroupID: UUID? = nil
    var defaultRegion: PlatformRegion? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var searchURLTemplate: String = ""
    @State private var selectedRegion: PlatformRegion = .international
    @State private var selectedGroupID: UUID? = nil

    @State private var nameError: String? = nil
    @State private var urlError: String? = nil
    @State private var isSaving = false
    @State private var shakeName = false
    @State private var shakeURL = false
    @State private var showURLHelp = false
    @State private var nameManuallyEdited = false

    private struct GroupItem: Identifiable {
        let id: String
        let name: String
        let region: PlatformRegion
        let groupID: UUID?
    }

    private var allGroups: [GroupItem] {
        var items: [GroupItem] = PlatformRegion.allCases.map { region in
            GroupItem(
                id: "region-\(region.rawValue)",
                name: PlatformDataStore.shared.regionDisplayName(for: region),
                region: region,
                groupID: nil
            )
        }
        for group in PlatformDataStore.shared.customGroups {
            items.append(GroupItem(
                id: "group-\(group.id.uuidString)",
                name: group.name,
                region: .international,
                groupID: group.id
            ))
        }
        return items
    }

    private func isSelected(_ item: GroupItem) -> Bool {
        if let gid = item.groupID {
            return selectedGroupID == gid
        }
        return selectedGroupID == nil && selectedRegion == item.region
    }

    private var currentGroupLabel: String {
        if let gid = selectedGroupID,
           let group = PlatformDataStore.shared.customGroups.first(where: { $0.id == gid }) {
            return group.name
        }
        return PlatformDataStore.shared.regionDisplayName(for: selectedRegion)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        searchURLTemplate.contains("%@")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(uiColor: .systemGroupedBackground),
                        Color(uiColor: .secondarySystemGroupedBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // MARK: - Header Card
                        VStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 64, height: 64)
                                    .shadow(color: .blue.opacity(0.4), radius: 12, x: 0, y: 6)
                                Image(systemName: "plus.magnifyingglass")
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.top, 8)

                            Text(LanguageManager.shared.localizedString("add_platform_title"))
                                .font(.title2)
                                .fontWeight(.bold)

                            Text(LanguageManager.shared.localizedString("add_platform_subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                        }
                        .padding(.bottom, 4)

                        // MARK: - Form Fields
                        VStack(spacing: 16) {
                            // Search URL Template field (first)
                            FormFieldCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Label(
                                            LanguageManager.shared.localizedString("add_platform_search_url"),
                                            systemImage: "magnifyingglass"
                                        )
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)

                                        Spacer()

                                        Button {
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                                showURLHelp.toggle()
                                            }
                                        } label: {
                                            Image(systemName: showURLHelp ? "questionmark.circle.fill" : "questionmark.circle")
                                                .foregroundStyle(.blue)
                                                .font(.system(size: 16))
                                        }
                                    }

                                    TextField(
                                        "https://example.com/search?q=%@",
                                        text: $searchURLTemplate,
                                        axis: .vertical
                                    )
                                    .font(.system(size: 13, design: .monospaced))
                                    .lineLimit(2...5)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .onChange(of: searchURLTemplate) { _, newValue in
                                        if newValue.contains("%@") { urlError = nil }
                                        // Auto-parse name from domain if user hasn't manually edited
                                        if !nameManuallyEdited {
                                            name = parseDomainName(from: newValue)
                                        }
                                    }

                                    if showURLHelp {
                                        URLHelpView()
                                            .transition(.opacity.combined(with: .move(edge: .top)))
                                    }

                                    if let error = urlError {
                                        ErrorLabel(text: error)
                                    }
                                }
                            }
                            .modifier(ShakeModifier(trigger: shakeURL))

                            // Name field (auto-filled, editable)
                            FormFieldCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(
                                        LanguageManager.shared.localizedString("add_platform_name"),
                                        systemImage: "tag.fill"
                                    )
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                    TextField(
                                        LanguageManager.shared.localizedString("add_platform_name_placeholder"),
                                        text: $name
                                    )
                                    .font(.body)
                                    .onChange(of: name) { _, _ in
                                        if !name.isEmpty { nameError = nil }
                                        nameManuallyEdited = true
                                    }

                                    if let error = nameError {
                                        ErrorLabel(text: error)
                                    }
                                }
                            }
                            .modifier(ShakeModifier(trigger: shakeName))

                            // Group picker (built-in regions + custom groups)
                            FormFieldCard {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(
                                        LanguageManager.shared.localizedString("add_platform_region"),
                                        systemImage: "folder.fill"
                                    )
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)

                                    Menu {
                                        ForEach(allGroups, id: \.id) { item in
                                            Button {
                                                selectedRegion = item.region
                                                selectedGroupID = item.groupID
                                            } label: {
                                                HStack {
                                                    Text(item.name)
                                                    if isSelected(item) {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
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
                                        .padding(.vertical, 8)
                                        .padding(.horizontal, 12)
                                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)

                        // MARK: - Save Button
                        Button {
                            saveAndDismiss()
                        } label: {
                            HStack(spacing: 8) {
                                if isSaving {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white)
                                        .scaleEffect(0.9)
                                } else {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 18, weight: .semibold))
                                }
                                Text(LanguageManager.shared.localizedString("save"))
                                    .font(.body)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                            .background(
                                LinearGradient(
                                    colors: isValid ? [.blue, .purple] : [.gray.opacity(0.5), .gray.opacity(0.4)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .shadow(
                                color: isValid ? .blue.opacity(0.4) : .clear,
                                radius: 10,
                                x: 0,
                                y: 5
                            )
                        }
                        .disabled(!isValid || isSaving)
                        .animation(.spring(response: 0.3), value: isValid)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 32)
                    }
                    .padding(.top, 16)
                }
            }
            .onAppear {
                if let gid = targetGroupID {
                    selectedGroupID = gid
                } else if let region = defaultRegion {
                    selectedRegion = region
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) {
                        dismiss()
                    }
                }
            }
        }
    }

    /// Extract a readable name from a URL domain (e.g. "www.pianbs.com" -> "Pianbs")
    private func parseDomainName(from urlString: String) -> String {
        guard let url = URL(string: urlString.replacingOccurrences(of: "%@", with: "test")),
              let host = url.host else { return "" }
        // Remove www. prefix, take the domain name part, capitalize
        let domain = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let namePart = domain.components(separatedBy: ".").first ?? domain
        return namePart.prefix(1).uppercased() + namePart.dropFirst()
    }

    private func saveAndDismiss() {
        var hasError = false

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            nameError = LanguageManager.shared.localizedString("add_platform_error_name_empty")
            withAnimation(.default) { shakeName.toggle() }
            hasError = true
        }

        if !searchURLTemplate.contains("%@") {
            urlError = LanguageManager.shared.localizedString("add_platform_error_url_placeholder")
            withAnimation(.default) { shakeURL.toggle() }
            hasError = true
        }

        guard !hasError else { return }

        isSaving = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Auto-derive homeURL from searchURLTemplate
            let derivedHomeURL: String
            if let url = URL(string: searchURLTemplate.replacingOccurrences(of: "%@", with: "")),
               let scheme = url.scheme, let host = url.host {
                derivedHomeURL = "\(scheme)://\(host)"
            } else {
                derivedHomeURL = ""
            }

            PlatformDataStore.shared.addCustomPlatform(
                name: trimmedName,
                searchURL: searchURLTemplate,
                homeURL: derivedHomeURL,
                region: selectedRegion
            )
            // Add to custom group if selected
            let groupToAdd = selectedGroupID ?? targetGroupID
            if let groupID = groupToAdd,
               let newPlatform = PlatformDataStore.shared.platforms.last {
                PlatformDataStore.shared.addPlatformToGroup(groupID: groupID, platformID: newPlatform.id)
            }
            isSaving = false
            dismiss()
        }
    }
}

// MARK: - URL Help View

struct URLHelpView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.caption)
                Text(LanguageManager.shared.localizedString("add_platform_url_help_title"))
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }

            Text(LanguageManager.shared.localizedString("add_platform_url_help_desc"))
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(LanguageManager.shared.localizedString("add_platform_url_help_examples"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                ForEach(URLExamples.all, id: \.name) { example in
                    HStack(spacing: 4) {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("\(example.name):")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(example.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.blue)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(10)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(12)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private enum URLExamples {
    struct Example { let name: String; let url: String }
    static let all: [Example] = [
        Example(name: "Google",  url: "https://google.com/search?q=%@"),
        Example(name: "YouTube", url: "https://youtube.com/results?search_query=%@"),
        Example(name: "Bing",    url: "https://bing.com/search?q=%@")
    ]
}

// MARK: - Supporting Views

struct FormFieldCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
            )
    }
}

struct ErrorLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.red)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct ShakeModifier: ViewModifier {
    let trigger: Bool
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onChange(of: trigger) { _, _ in
                withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                    offset = -8
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) {
                    withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                        offset = 8
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                        offset = 0
                    }
                }
            }
    }
}


#Preview {
    AddCustomPlatformView()
}
