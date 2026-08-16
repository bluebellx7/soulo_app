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
    @State private var importUserScript = false
    @State private var showNewScript = false
    @State private var isInstalling = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

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
    }

    private var installedContent: some View {
        List {
            Section {
                userScriptExperimentalNotice
            }

            if service.userScripts.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("userscripts_empty"),
                    systemImage: "chevron.left.forwardslash.chevron.right",
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
                            Button(role: .destructive) {
                                service.deleteUserScript(script.id)
                            } label: {
                                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
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
        HStack(spacing: 12) {
            extensionIcon(systemName: "puzzlepiece.extension.fill", tint: .blue)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                Text(webExtensionDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { item.isEnabled },
                set: { service.setWebExtensionEnabled(item.id, enabled: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 3)
    }

    private func userScriptRow(_ script: UserScriptRecord) -> some View {
        HStack(spacing: 12) {
            extensionIcon(systemName: "chevron.left.forwardslash.chevron.right", tint: .orange)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name).font(.body.weight(.medium)).lineLimit(1)
                    if let version = script.version, !version.isEmpty {
                        Text("v\(version)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(script.matchPatterns.prefix(2).joined(separator: ", "))
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
                    installSourceRow("Chrome Web Store", icon: "safari.fill", tint: .blue, url: "https://chromewebstore.google.com/category/extensions")
                    installSourceRow("Microsoft Edge Extensions", icon: "globe", tint: .cyan, url: "https://microsoftedge.microsoft.com/addons/Microsoft-Edge-Extensions-Home")
                    installSourceRow("Firefox Add-ons", icon: "flame.fill", tint: .orange, url: "https://addons.mozilla.org/")
                    installSourceRow("GitHub · Browser Extensions", icon: "chevron.left.forwardslash.chevron.right", tint: .primary, url: "https://github.com/topics/browser-extension")

                    Button { importWebExtension = true } label: {
                        Label(LanguageManager.shared.localizedString("extension_choose_file"), systemImage: "folder.badge.plus")
                    }
                    .disabled(!nativeWebExtensionsAvailable)
                } header: {
                    Text(LanguageManager.shared.localizedString("web_extensions"))
                } footer: {
                    Text(LanguageManager.shared.localizedString(nativeWebExtensionsAvailable ? "web_extension_install_footer" : "web_extension_requires_ios"))
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
            Image(systemName: "flask.fill")
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

struct BrowserPackageInstallView: View {
    let candidate: BrowserExtensionInstallCandidate

    @Environment(\.dismiss) private var dismiss
    @State private var isInstalling = false
    @State private var installedName = ""
    @State private var showSuccess = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
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

                    Text(candidate.fileURL.lastPathComponent)
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
                .disabled(isInstalling)
                .padding(.horizontal, 20)

                Spacer(minLength: 0)
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

    private func install() {
        guard !isInstalling else { return }
        isInstalling = true
        Task { @MainActor in
            do {
                switch candidate.kind {
                case .userScript:
                    let script = try BrowserExtensionService.shared.importUserScript(from: candidate.fileURL)
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
    @State private var name: String
    @State private var patternsText: String
    @State private var source: String
    @State private var injectionTime: UserScriptInjectionTime
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(script: UserScriptRecord?) {
        scriptID = script?.id
        _name = State(initialValue: script?.name ?? LanguageManager.shared.localizedString("userscript_untitled"))
        _patternsText = State(initialValue: script?.matchPatterns.joined(separator: "\n") ?? "*://*/*")
        _source = State(initialValue: script?.source ?? "// ==UserScript==\n// @name New Script\n// @match *://*/*\n// @run-at document-end\n// ==/UserScript==\n\n")
        _injectionTime = State(initialValue: script?.injectionTime ?? .documentEnd)
    }

    var body: some View {
        Form {
            Section {
                TextField(LanguageManager.shared.localizedString("userscript_name"), text: $name)
                Picker(LanguageManager.shared.localizedString("userscript_run_at"), selection: $injectionTime) {
                    Text(LanguageManager.shared.localizedString("userscript_document_start")).tag(UserScriptInjectionTime.documentStart)
                    Text(LanguageManager.shared.localizedString("userscript_document_end")).tag(UserScriptInjectionTime.documentEnd)
                }
            }

            Section(LanguageManager.shared.localizedString("userscript_matches")) {
                TextEditor(text: $patternsText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 80)
            }

            Section(LanguageManager.shared.localizedString("userscript_code")) {
                TextEditor(text: $source)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minHeight: 280)
            }
        }
        .navigationTitle(scriptID == nil ? LanguageManager.shared.localizedString("userscript_new") : LanguageManager.shared.localizedString("userscript_edit"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(LanguageManager.shared.localizedString("save")) { save() }
                    .fontWeight(.semibold)
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
