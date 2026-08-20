import SwiftUI
import UniformTypeIdentifiers

private enum ExtensionCenterTab: String, CaseIterable, Identifiable {
    case installed
    case install

    var id: String { rawValue }
    var titleKey: String { self == .installed ? "userscripts_installed" : "userscripts_install" }
}

struct ExtensionCenterView: View {
    var onOpenInBrowser: ((URL) -> Void)? = nil

    @ObservedObject private var service = BrowserExtensionService.shared
    @State private var selectedTab: ExtensionCenterTab = .installed
    @State private var importWebExtension = false
    @State private var showStoreLinkInstaller = false
    @State private var importUserScript = false
    @State private var showNewScript = false
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var scriptPendingDeletion: UserScriptRecord?
    @State private var extensionActionRevision = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(ExtensionCenterTab.allCases) { tab in
                    Text(LanguageManager.shared.localizedString(tab.titleKey)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.45)

            if selectedTab == .installed {
                installedContent
            } else {
                installContent
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("userscripts"))
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $importWebExtension,
            allowedContentTypes: webExtensionContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result { errorMessage = error.localizedDescription }
                return
            }
            isInstalling = true
            Task {
                do {
                    let item = try await service.installWebExtension(from: url)
                    selectedTab = .installed
                    successMessage = AppAccessibility.formatted("extension_installed_success_desc", item.name)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch {
                    errorMessage = error.localizedDescription
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
                isInstalling = false
            }
        }
        .sheet(isPresented: $showStoreLinkInstaller) {
            WebExtensionStoreInstallView()
                .presentationDetents([.height(390), .large])
                .presentationDragIndicator(.visible)
        }
        .fileImporter(
            isPresented: $importUserScript,
            allowedContentTypes: userScriptContentTypes,
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else {
                if case let .failure(error) = result { errorMessage = error.localizedDescription }
                return
            }
            do {
                let script = try service.importUserScript(from: url)
                selectedTab = .installed
                successMessage = AppAccessibility.formatted("extension_installed_success_desc", script.name)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        .navigationDestination(isPresented: $showNewScript) {
            UserScriptEditorView(script: nil)
        }
        .alert(
            LanguageManager.shared.localizedString("userscript_install_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(
            LanguageManager.shared.localizedString("extension_install_success"),
            isPresented: Binding(
                get: { successMessage != nil },
                set: { if !$0 { successMessage = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("done"), role: .cancel) {}
        } message: {
            Text(successMessage ?? "")
        }
        .alert(
            LanguageManager.shared.localizedString("userscript_delete_title"),
            isPresented: Binding(
                get: { scriptPendingDeletion != nil },
                set: { if !$0 { scriptPendingDeletion = nil } }
            ),
            presenting: scriptPendingDeletion
        ) { script in
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                service.deleteUserScript(script.id)
            }
        } message: { script in
            Text(AppAccessibility.formatted("userscript_delete_message", script.name))
        }
        .overlay {
            if isInstalling {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(LanguageManager.shared.localizedString("extension_installing"))
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .browserExtensionActionsChanged)) { _ in
            extensionActionRevision &+= 1
        }
    }

    private var installedContent: some View {
        List {
            Section {
                userScriptExperimentalNotice
            }

            if service.userScripts.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("userscripts_empty"),
                    systemImage: "puzzlepiece.extension.fill",
                    description: Text(LanguageManager.shared.localizedString("userscripts_empty_desc"))
                )
            }

            // Kept behind a feature flag for the next release's device testing.
            if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled,
               !service.webExtensions.isEmpty {
                Section(LanguageManager.shared.localizedString("web_extensions")) {
                    ForEach(service.webExtensions) { item in
                        webExtensionRow(item)
                            .swipeActions {
                                Button(role: .destructive) {
                                    service.deleteWebExtension(item.id)
                                } label: {
                                    Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                                }
                            }
                    }
                }
            }

            if !service.userScripts.isEmpty {
                Section {
                    ForEach(service.userScripts) { script in
                        HStack(spacing: 12) {
                            NavigationLink {
                                UserScriptEditorView(script: script)
                            } label: {
                                userScriptRow(script)
                            }

                            Toggle("", isOn: Binding(
                                get: { script.isEnabled },
                                set: { service.setUserScriptEnabled(script.id, enabled: $0) }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            if script.isBuiltIn != true {
                                Button(role: .destructive) {
                                    scriptPendingDeletion = script
                                } label: {
                                    Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                                }
                            }
                        }
                    }
                } header: {
                    userScriptSectionHeader
                }
            }

            Section {
                Text(LanguageManager.shared.localizedString("userscripts_reload_note"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func webExtensionRow(_ item: WebExtensionRecord) -> some View {
        let action = service.webExtensionAction(for: item.id)
        return HStack(spacing: 12) {
            if let action {
                Button {
                    service.performWebExtensionAction(item.id)
                } label: {
                    webExtensionActionLabel(item, action: action)
                }
                .buttonStyle(.plain)
                .disabled(!action.isEnabled)
                .accessibilityLabel(action.label)
                .id("\(item.id.uuidString)-\(extensionActionRevision)")
            } else {
                webExtensionActionLabel(item, action: nil)
            }

            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { service.setWebExtensionEnabled(item.id, enabled: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func webExtensionActionLabel(
        _ item: WebExtensionRecord,
        action: WebExtensionActionPresentation?
    ) -> some View {
        HStack(spacing: 12) {
            if let image = action?.icon {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                extensionIcon(systemName: "puzzlepiece.extension.fill", tint: .blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(webExtensionDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }

    private func userScriptRow(_ script: UserScriptRecord) -> some View {
        HStack(spacing: 12) {
            extensionIcon(systemName: "chevron.left.forwardslash.chevron.right", tint: .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(BuiltInUserScripts.displayName(for: script))
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if script.isBuiltIn == true {
                        Text(LanguageManager.shared.localizedString("userscript_builtin_badge"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.purple.opacity(0.11), in: Capsule())
                    }
                    if let version = script.version, !version.isEmpty {
                        Text("v\(version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text((BuiltInUserScripts.displayDescription(for: script)
                    .flatMap { $0.isEmpty ? nil : $0 })
                    ?? script.matchPatterns.prefix(2).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(LanguageManager.shared.localizedString(
                    script.injectionTime == .documentStart
                        ? "userscript_document_start"
                        : "userscript_document_end"
                ))
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var installContent: some View {
        List {
            Section {
                userScriptExperimentalNotice
            }

            // Standard browser extension sources are intentionally hidden for
            // this release. The implementation stays compiled for later tests.
            if BrowserExtensionFeatureAvailability.standardWebExtensionsEnabled {
                Section {
                    Button { showStoreLinkInstaller = true } label: {
                        Label(
                            LanguageManager.shared.localizedString("web_extension_install_store_link"),
                            systemImage: "link.badge.plus"
                        )
                    }

                    Button { importWebExtension = true } label: {
                        Label(LanguageManager.shared.localizedString("extension_choose_file"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!nativeWebExtensionsAvailable)
                } header: {
                    Text(LanguageManager.shared.localizedString("web_extensions"))
                } footer: {
                    Text(LanguageManager.shared.localizedString(nativeWebExtensionsAvailable ? "web_extension_install_footer" : "web_extension_requires_ios"))
                }

                Section {
                    installSourceRow("Chrome Web Store", icon: "safari.fill", tint: .blue, url: "https://chromewebstore.google.com/category/extensions")
                    installSourceRow("Microsoft Edge Extensions", icon: "globe", tint: .cyan, url: "https://microsoftedge.microsoft.com/addons/Microsoft-Edge-Extensions-Home")
                    installSourceRow("Firefox Add-ons", icon: "flame.fill", tint: .orange, url: "https://addons.mozilla.org/")
                    installSourceRow("GitHub · Browser Extensions", icon: "chevron.left.forwardslash.chevron.right", tint: .primary, url: "https://github.com/topics/browser-extension")
                } header: {
                    Text(LanguageManager.shared.localizedString("web_extension_browse_sources"))
                } footer: {
                    Text(LanguageManager.shared.localizedString("web_extension_browse_sources_footer"))
                }
            }

            Section {
                installSourceRow("GreasyFork", icon: "gearshape.2.fill", tint: .secondary, url: "https://greasyfork.org/")
                installSourceRow("OpenUserJS", icon: "circle.circle", tint: .blue, url: "https://openuserjs.org/")
                installSourceRow("Userscript.Zone", icon: "curlybraces", tint: .green, url: "https://www.userscript.zone/")
                installSourceRow("GitHub", icon: "chevron.left.forwardslash.chevron.right", tint: .primary, url: "https://github.com/topics/userscript")

                Button { showNewScript = true } label: {
                    Label(LanguageManager.shared.localizedString("userscript_new"), systemImage: "plus.square")
                }
                Button { importUserScript = true } label: {
                    Label(LanguageManager.shared.localizedString("userscript_choose_file"), systemImage: "doc.badge.plus")
                }
                NavigationLink {
                    UserScriptDocumentationView()
                } label: {
                    Label(
                        LanguageManager.shared.localizedString("userscripts_documentation"),
                        systemImage: "book.pages"
                    )
                }
            } header: {
                userScriptSectionHeader
            } footer: {
                Text(LanguageManager.shared.localizedString("userscript_install_footer"))
            }
        }
        .listStyle(.insetGrouped)
    }

    private var userScriptSectionHeader: some View {
        HStack(spacing: 7) {
            Text(LanguageManager.shared.localizedString("userscripts"))
            Text(LanguageManager.shared.localizedString("userscript_experimental_badge"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.12), in: Capsule())
        }
    }

    private var userScriptExperimentalNotice: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(LanguageManager.shared.localizedString("userscript_experimental_title"))
                        .font(.subheadline.weight(.semibold))
                    Text(LanguageManager.shared.localizedString("userscript_experimental_badge"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Text(LanguageManager.shared.localizedString("userscript_experimental_desc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func installSourceRow(_ name: String, icon: String, tint: Color, url: String) -> some View {
        Button {
            guard let target = URL(string: url) else { return }
            onOpenInBrowser?(target)
        } label: {
            HStack(spacing: 12) {
                extensionIcon(systemName: icon, tint: tint)
                Text(name).foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint(LanguageManager.shared.localizedString("extension_source_open_hint"))
    }

    private func extensionIcon(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func webExtensionDetail(_ item: WebExtensionRecord) -> String {
        let version = item.version.map { "v\($0) · " } ?? ""
        return version + AppAccessibility.formatted(
            "extension_permissions_summary",
            item.requestedPermissionCount,
            item.requestedSiteCount
        )
    }

    private var nativeWebExtensionsAvailable: Bool {
        if #available(iOS 18.4, *) { return true }
        return false
    }

    private var webExtensionContentTypes: [UTType] {
        [.folder, .zip, UTType(filenameExtension: "xpi") ?? .data, UTType(filenameExtension: "crx") ?? .data]
    }

    private var userScriptContentTypes: [UTType] {
        [UTType(filenameExtension: "js") ?? .sourceCode, .sourceCode, .plainText]
    }
}

struct WebExtensionStoreInstallView: View {
    let initialValue: String
    let autoStart: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var linkText: String
    @State private var isInstalling = false
    @State private var installedName: String?
    @State private var errorMessage: String?
    @State private var didAutoStart = false

    init(initialValue: String = "", autoStart: Bool = false) {
        self.initialValue = initialValue
        self.autoStart = autoStart
        _linkText = State(initialValue: initialValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Label(
                        LanguageManager.shared.localizedString("web_extension_store_install_title"),
                        systemImage: "puzzlepiece.extension.fill"
                    )
                    .font(.title3.weight(.semibold))

                    Text(LanguageManager.shared.localizedString("web_extension_store_install_desc"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    VStack(spacing: 10) {
                        TextField(
                            LanguageManager.shared.localizedString("web_extension_store_link_placeholder"),
                            text: $linkText,
                            axis: .vertical
                        )
                        .lineLimit(2...4)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                        Button {
                            if let value = UIPasteboard.general.string {
                                linkText = value.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Label(LanguageManager.shared.localizedString("paste_from_clipboard"), systemImage: "doc.on.clipboard")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    Button(action: install) {
                        HStack(spacing: 9) {
                            if isInstalling {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "arrow.down.app.fill")
                            }
                            Text(LanguageManager.shared.localizedString(
                                isInstalling ? "extension_installing_short" : "install"
                            ))
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(20)
            }
            .navigationTitle(LanguageManager.shared.localizedString("extensions_install"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }
                        .disabled(isInstalling)
                }
            }
        }
        .interactiveDismissDisabled(isInstalling)
        .task {
            guard autoStart, !didAutoStart else { return }
            didAutoStart = true
            install()
        }
        .alert(
            LanguageManager.shared.localizedString("extension_install_success"),
            isPresented: Binding(
                get: { installedName != nil },
                set: { if !$0 { installedName = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("done")) { dismiss() }
        } message: {
            Text(AppAccessibility.formatted("extension_installed_success_desc", installedName ?? ""))
        }
        .alert(
            LanguageManager.shared.localizedString("extension_install_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task { @MainActor in
            do {
                let item = try await WebExtensionStoreInstallService.shared.install(from: linkText)
                installedName = item.name
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isInstalling = false
        }
    }
}

struct BrowserPackageInstallView: View {
    let candidate: BrowserExtensionInstallCandidate

    @Environment(\.dismiss) private var dismiss
    @State private var isInstalling = false
    @State private var installedName = ""
    @State private var showSuccess = false
    @State private var errorMessage: String?
    @State private var scriptPreview: UserScriptInstallPreview?

    var body: some View {
        NavigationStack {
            ScrollView {
              VStack(spacing: 20) {
                Image(systemName: candidate.kind == .userScript
                    ? "chevron.left.forwardslash.chevron.right"
                    : "puzzlepiece.extension.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(candidate.kind == .userScript ? .orange : .blue)
                    .frame(width: 68, height: 68)
                    .background(
                        (candidate.kind == .userScript ? Color.orange : Color.blue).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )

                VStack(spacing: 7) {
                    Text(LanguageManager.shared.localizedString(
                        candidate.kind == .userScript
                            ? "userscript_detected_title"
                            : "extension_detected_title"
                    ))
                    .font(.title3.weight(.semibold))

                    Text(scriptPreview?.name ?? candidate.fileURL.lastPathComponent)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    if let host = candidate.sourceURL?.host {
                        Label(host, systemImage: "globe")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(LanguageManager.shared.localizedString(
                    candidate.kind == .userScript
                        ? "userscript_detected_desc"
                        : "extension_detected_desc"
                ))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)

                if let preview = scriptPreview {
                    VStack(spacing: 0) {
                        previewRow(
                            icon: "globe",
                            title: LanguageManager.shared.localizedString("userscript_access_title"),
                            detail: preview.metadata.patterns.isEmpty
                                ? LanguageManager.shared.localizedString("userscript_access_all_sites")
                                : preview.metadata.patterns.joined(separator: "\n")
                        )
                        Divider().padding(.leading, 42)
                        previewRow(
                            icon: "checkmark.shield",
                            title: LanguageManager.shared.localizedString("userscript_permissions_title"),
                            detail: permissionSummary(preview.metadata)
                        )
                        if !preview.metadata.connectDomains.isEmpty {
                            Divider().padding(.leading, 42)
                            previewRow(
                                icon: "network",
                                title: LanguageManager.shared.localizedString("userscript_network_title"),
                                detail: preview.metadata.connectDomains.joined(separator: ", ")
                            )
                        }
                        if !preview.metadata.requiredURLs.isEmpty {
                            Divider().padding(.leading, 42)
                            previewRow(
                                icon: "exclamationmark.triangle",
                                title: LanguageManager.shared.localizedString("userscript_external_requirements"),
                                detail: preview.metadata.requiredURLs.joined(separator: "\n"),
                                tint: .orange
                            )
                        }
                    }
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.horizontal, 20)
                }

                Button(action: install) {
                    HStack(spacing: 9) {
                        if isInstalling {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.down.app.fill")
                        }
                        Text(LanguageManager.shared.localizedString(
                            isInstalling ? "extension_installing_short" : "install"
                        ))
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalling || (candidate.kind == .userScript && scriptPreview == nil))
                .padding(.horizontal, 20)

                Spacer(minLength: 8)
              }
            }
            .padding(.top, 24)
            .navigationTitle(LanguageManager.shared.localizedString(
                candidate.kind == .userScript ? "userscripts_install" : "extensions_install"
            ))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }
                        .disabled(isInstalling)
                }
            }
        }
        .task {
            guard candidate.kind == .userScript, scriptPreview == nil else { return }
            do {
                scriptPreview = try BrowserExtensionService.shared.previewUserScript(
                    from: candidate.fileURL,
                    sourceURL: candidate.sourceURL
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        .interactiveDismissDisabled(isInstalling)
        .alert(
            LanguageManager.shared.localizedString("extension_install_success"),
            isPresented: $showSuccess
        ) {
            Button(LanguageManager.shared.localizedString("done")) { dismiss() }
        } message: {
            Text(AppAccessibility.formatted("extension_installed_success_desc", installedName))
        }
        .alert(
            LanguageManager.shared.localizedString(
                candidate.kind == .userScript ? "userscript_install_failed" : "extension_install_failed"
            ),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func previewRow(
        icon: String,
        title: String,
        detail: String,
        tint: Color = .secondary
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func permissionSummary(_ metadata: UserScriptMetadata) -> String {
        let grants = metadata.grants.filter { $0.caseInsensitiveCompare("none") != .orderedSame }
        let summary = grants.isEmpty
            ? LanguageManager.shared.localizedString("userscript_no_extra_permissions")
            : grants.joined(separator: ", ")
        let unsupported = grants.filter {
            !UserScriptRuntime.supportedGrantNames.contains($0.lowercased())
        }
        guard !unsupported.isEmpty else { return summary }
        return summary + "\n" + AppAccessibility.formatted(
            "userscript_unsupported_permissions",
            unsupported.joined(separator: ", ")
        )
    }

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task { @MainActor in
            do {
                switch candidate.kind {
                case .userScript:
                    let script = try BrowserExtensionService.shared.importUserScript(
                        from: candidate.fileURL,
                        sourceURL: candidate.sourceURL
                    )
                    installedName = script.name
                case .webExtension:
                    let item = try await BrowserExtensionService.shared.installWebExtension(from: candidate.fileURL)
                    installedName = item.name
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                showSuccess = true
            } catch {
                errorMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isInstalling = false
        }
    }
}

struct UserScriptEditorView: View {
    private let scriptID: UUID?
    private let isBuiltIn: Bool
    private let builtInDescription: String?
    @State private var name: String
    @State private var patternsText: String
    @State private var source: String
    @State private var injectionTime: UserScriptInjectionTime
    @State private var errorMessage: String?
    @State private var sourceCopied = false
    @Environment(\.dismiss) private var dismiss

    init(script: UserScriptRecord?) {
        scriptID = script?.id
        isBuiltIn = script?.isBuiltIn == true
        builtInDescription = script.flatMap { record in
            record.isBuiltIn == true ? BuiltInUserScripts.displayDescription(for: record) : nil
        }
        _name = State(initialValue: script.map(BuiltInUserScripts.displayName)
            ?? LanguageManager.shared.localizedString("userscript_untitled"))
        _patternsText = State(initialValue: script?.matchPatterns.joined(separator: "\n") ?? "*://*/*")
        _source = State(initialValue: script?.source ?? "// ==UserScript==\n// @name New Script\n// @match *://*/*\n// @run-at document-end\n// ==/UserScript==\n\n")
        _injectionTime = State(initialValue: script?.injectionTime ?? .documentEnd)
    }

    var body: some View {
        let metadata = BrowserExtensionService.parseMetadata(from: source)
        let description = (isBuiltIn ? builtInDescription : metadata.description)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        Form {
            if isBuiltIn {
                Section {
                    LabeledContent(LanguageManager.shared.localizedString("userscript_name"), value: name)
                    LabeledContent(
                        LanguageManager.shared.localizedString("userscript_run_at"),
                        value: LanguageManager.shared.localizedString(
                            injectionTime == .documentStart
                                ? "userscript_document_start"
                                : "userscript_document_end"
                        )
                    )
                } footer: {
                    Text(LanguageManager.shared.localizedString("userscript_builtin_readonly_desc"))
                }
            } else {
                Section {
                    TextField(LanguageManager.shared.localizedString("userscript_name"), text: $name)
                    Picker(LanguageManager.shared.localizedString("userscript_run_at"), selection: $injectionTime) {
                        Text(LanguageManager.shared.localizedString("userscript_document_start")).tag(UserScriptInjectionTime.documentStart)
                        Text(LanguageManager.shared.localizedString("userscript_document_end")).tag(UserScriptInjectionTime.documentEnd)
                    }
                }
            }

            if let description, !description.isEmpty {
                Section(LanguageManager.shared.localizedString("userscript_description")) {
                    Text(description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Section(LanguageManager.shared.localizedString("userscript_metadata_title")) {
                LabeledContent(LanguageManager.shared.localizedString("userscript_permissions_title")) {
                    Text(metadata.grants.isEmpty ? LanguageManager.shared.localizedString("userscript_no_extra_permissions") : metadata.grants.joined(separator: ", "))
                        .multilineTextAlignment(.trailing)
                }
                if !metadata.connectDomains.isEmpty {
                    LabeledContent(LanguageManager.shared.localizedString("userscript_network_title")) {
                        Text(metadata.connectDomains.joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
                if !metadata.requiredURLs.isEmpty {
                    Label(
                        LanguageManager.shared.localizedString("userscript_external_requirements_desc"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
                let unsupported = metadata.grants.filter {
                    !UserScriptRuntime.supportedGrantNames.contains($0.lowercased())
                }
                if !unsupported.isEmpty {
                    Label(
                        AppAccessibility.formatted(
                            "userscript_unsupported_permissions",
                            unsupported.joined(separator: ", ")
                        ),
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section(LanguageManager.shared.localizedString("userscript_matches")) {
                if isBuiltIn {
                    Text(patternsText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    TextEditor(text: $patternsText)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 80)
                }
            }

            Section {
                if isBuiltIn {
                    ScrollView(.horizontal) {
                        Text(source)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 280, alignment: .topLeading)
                } else {
                    TextEditor(text: $source)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 280)
                }
            } header: {
                HStack {
                    Text(LanguageManager.shared.localizedString("userscript_code"))
                    Spacer()
                    Button {
                        copySource()
                    } label: {
                        Label(
                            LanguageManager.shared.localizedString(
                                sourceCopied ? "copied" : "userscript_copy_javascript"
                            ),
                            systemImage: sourceCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .disabled(source.isEmpty)
                }
            }
        }
        .navigationTitle(isBuiltIn
            ? LanguageManager.shared.localizedString("userscript_metadata_title")
            : LanguageManager.shared.localizedString(scriptID == nil ? "userscript_new" : "userscript_edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if !isBuiltIn {
                    Button(LanguageManager.shared.localizedString("save")) { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .alert(
            LanguageManager.shared.localizedString("save_failed"),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func copySource() {
        UIPasteboard.general.string = source
        sourceCopied = true
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            sourceCopied = false
        }
    }

    private func save() {
        do {
            _ = try BrowserExtensionService.shared.saveUserScript(
                id: scriptID,
                fallbackName: name,
                source: source,
                explicitPatterns: patternsText.components(separatedBy: .newlines),
                injectionTime: injectionTime,
                explicitName: name
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
