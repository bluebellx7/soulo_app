import SwiftUI
import UniformTypeIdentifiers

struct WebExtensionReviewView: View {
    let preview: WebExtensionInstallPreview
    var actionKey: String? = nil
    var onInstalled: (WebExtensionRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access: WebExtensionAccess
    @State private var isInstalling = false
    @State private var errorMessage: String?

    init(preview: WebExtensionInstallPreview, actionKey: String? = nil, onInstalled: @escaping (WebExtensionRecord) -> Void) {
        self.preview = preview; self.actionKey = actionKey; self.onInstalled = onInstalled
        _access = State(initialValue: preview.access)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(preview.name, value: preview.version.map { "v" + $0 } ?? "")
                    if let source = preview.sourceURL, let host = URL(string: source)?.host {
                        Label(host, systemImage: "globe").font(.caption).foregroundStyle(.secondary)
                    }
                } footer: { Text(AppLocalization.string("extension_review_access")) }
                Section(AppLocalization.string("userscript_permissions_title")) {
                    if preview.permissions.isEmpty { Text(AppLocalization.string("userscript_no_extra_permissions")) }
                    ForEach(preview.permissions, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { access.allowsPermission(name) }, set: { access.setPermission(name, allowed: $0) }))
                    }
                }
                Section(AppLocalization.string("userscript_access_title")) {
                    ForEach(preview.sites, id: \.self) { pattern in
                        Toggle(pattern, isOn: Binding(get: { access.sites[pattern].map { $0 > Date() } == true && access.deniedSites[pattern].map { $0 > Date() } != true },
                            set: { access.setSite(pattern, allowed: $0) }))
                            .font(.subheadline)
                    }
                }
                ExtensionDiagnosticsSection(messages: preview.warnings)
            }
            .navigationTitle(AppLocalization.string("userscript_permissions_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalization.string("cancel")) { dismiss() }.disabled(isInstalling)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string(actionKey ?? (preview.replacingID == nil ? "install" : "extension_update"))) {
                        isInstalling = true
                        Task { @MainActor in
                            defer { isInstalling = false }
                            do {
                                let record = try await BrowserExtensionService.shared.installWebExtension(preview, access: access)
                                dismiss()
                                onInstalled(record)
                            } catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(isInstalling)
                    .accessibilityIdentifier("extensions.review-install")
                }
            }
            .disabled(isInstalling)
            .overlay { if isInstalling { ProgressView() } }
        }
        .interactiveDismissDisabled(isInstalling)
        .onDisappear { BrowserExtensionService.shared.discardWebExtensionPreview(preview) }
        .alert(AppLocalization.string("extension_install_failed"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(AppLocalization.string("done"), role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }
}

struct WebExtensionManagementView: View {
    let id: UUID
    @ObservedObject private var service = BrowserExtensionService.shared
    @State private var hostText = ""
    @State private var choosingFile = false
    @State private var preparing = false
    @State private var preview: WebExtensionInstallPreview?
    @State private var reviewAction: String?
    @State private var errorMessage: String?

    private var record: WebExtensionRecord? { service.webExtensions.first { $0.id == id } }
    private var access: WebExtensionAccess { service.webExtensionAccess(id) }

    var body: some View {
        Form {
            if let record {
                let details = service.webExtensionDetails(id)
                let permissions = Array(Set(details.permissions + Array(access.permissions.keys) + Array(access.deniedPermissions.keys))).sorted()
                let sites = Array(Set(details.sites + Array(access.sites.keys) + Array(access.deniedSites.keys))).sorted()
                Section(AppLocalization.string("userscript_permissions_title")) {
                    ForEach(permissions, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { access.allowsPermission(name) }, set: { allowed in
                            update { $0.setPermission(name, allowed: allowed) }
                        }))
                    }
                }
                Section(AppLocalization.string("userscript_access_title")) {
                    ForEach(sites, id: \.self) { pattern in
                        Toggle(pattern, isOn: Binding(get: {
                            access.sites[pattern].map { $0 > Date() } == true && access.deniedSites[pattern].map { $0 > Date() } != true
                        }, set: { allowed in update { $0.setSite(pattern, allowed: allowed) } }))
                        .font(.subheadline)
                    }
                }
                Section(AppLocalization.string("extension_blocked_sites")) {
                    ForEach(access.blockedHosts.sorted(), id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button(role: .destructive) { update { $0.blockedHosts.remove(host) } } label: {
                                Image(systemName: "minus.circle")
                            }.accessibilityLabel(AppLocalization.string("delete"))
                        }
                    }
                    HStack {
                        TextField("example.com", text: $hostText)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("extensions.block-host")
                        Button {
                            guard let host = WebExtensionAccess.normalizedHost(hostText) else { return }
                            update { $0.blockedHosts.insert(host) }; hostText = ""
                        } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(WebExtensionAccess.normalizedHost(hostText) == nil)
                        .accessibilityLabel(AppLocalization.string("confirm"))
                    }
                }
                Section {
                    if let source = record.sourceURL {
                        Button(AppLocalization.string("extension_update")) {
                            prepare { try await WebExtensionStoreInstallService.shared.preview(from: source, replacing: id) }
                        }
                    }
                    Button(AppLocalization.string("extension_choose_file")) { choosingFile = true }
                    if let previous = record.previousVersion {
                        Button {
                            reviewAction = "restore"
                            prepare { try await service.previewPreviousWebExtension(id) }
                        } label: {
                            LabeledContent(AppLocalization.string("extension_rollback"), value: previous.version.map { "v" + $0 } ?? previous.name)
                        }
                    }
                }
                ExtensionDiagnosticsSection(messages: service.webExtensionDiagnostics(id))
            }
        }
        .navigationTitle(record?.name ?? AppLocalization.string("extension_manage"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(preparing || service.loadingWebExtensions.contains(id))
        .overlay { if preparing { ProgressView() } }
        .fileImporter(isPresented: $choosingFile,
            allowedContentTypes: [.folder, .zip, UTType(filenameExtension: "xpi") ?? .data, UTType(filenameExtension: "crx") ?? .data]) { result in
            switch result {
            case .success(let url): prepare { try await service.previewWebExtension(from: url, replacing: id) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .sheet(item: $preview, onDismiss: { reviewAction = nil }) { item in
            WebExtensionReviewView(preview: item, actionKey: reviewAction) { _ in }
        }
        .alert(AppLocalization.string("save_failed"), isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button(AppLocalization.string("done"), role: .cancel) {} } message: { Text(errorMessage ?? "") }
    }

    private func update(_ change: (inout WebExtensionAccess) -> Void) {
        var next = access; change(&next)
        do { try service.setWebExtensionAccess(next, id: id) } catch { errorMessage = error.localizedDescription }
    }

    private func prepare(_ operation: @escaping () async throws -> WebExtensionInstallPreview) {
        guard !preparing else { return }
        preparing = true
        Task { @MainActor in
            defer { preparing = false }
            do { preview = try await operation() } catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct ExtensionDiagnosticsSection: View {
    let messages: [String]
    var body: some View {
        if !messages.isEmpty {
            Section(AppLocalization.string("extension_diagnostics")) {
                ForEach(Array(Set(messages)).sorted(), id: \.self) { message in
                    Label(detail(message), systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
        }
    }
    private func detail(_ message: String) -> String {
        switch message {
        case "commands": AppLocalization.string("extension_limit_commands")
        case "offscreen", "offscreen: AUDIO_PLAYBACK": AppLocalization.string("extension_limit_offscreen")
        case "notifications", "notifications: onClicked / onClosed": AppLocalization.string("extension_limit_notifications")
        default: message
        }
    }
}
