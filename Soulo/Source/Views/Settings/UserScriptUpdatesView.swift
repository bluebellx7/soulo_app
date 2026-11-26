import SwiftUI

struct UserScriptUpdatesView: View {
    var onlyID: UUID? = nil
    var onUpdated: ((UserScriptRecord) -> Void)? = nil
    @ObservedObject private var service = BrowserExtensionService.shared
    @State private var updates: [UUID: UserScriptUpdatePreview] = [:]
    @State private var messages: [UUID: String] = [:]
    @State private var checking: UUID?
    @State private var task: Task<Void, Never>?
    @State private var review: UserScriptUpdatePreview?
    @State private var extensionReview: WebExtensionInstallPreview?
    @State private var extensionVersions: [UUID: String] = [:]
    private var scripts: [UserScriptRecord] {
        service.userScripts.filter { $0.isBuiltIn != true && (onlyID == nil || $0.id == onlyID) }
    }
    private var officialExtensions: [WebExtensionRecord] {
        guard onlyID == nil else { return [] }
        return service.webExtensions.filter { WebExtensionStoreInstallService.officialUpdateSource(for: $0.sourceURL) != nil }
    }
    private var checkableScripts: [UserScriptRecord] {
        scripts.filter { UserScriptUpdateLoader.checkURL(for: $0) != nil }
    }

    var body: some View {
        List {
            if !officialExtensions.isEmpty {
                Section(AppLocalization.string("web_extensions")) {
                    ForEach(officialExtensions) { record in
                        Button {
                            check([], extensions: [record], showReview: true)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.name).foregroundStyle(.primary)
                                    if let version = record.version {
                                        let label = extensionVersions[record.id].map { "v\(version) → v\($0)" } ?? "v\(version)"
                                        Text(label).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if let message = messages[record.id] {
                                        Text(message).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if checking == record.id { ProgressView() }
                                else if extensionVersions[record.id] != nil { Text(AppLocalization.string("extension_update")) }
                                else { Image(systemName: "arrow.clockwise") }
                            }.frame(minHeight: 44)
                        }
                        .disabled(checking != nil)
                        .accessibilityIdentifier("extensions.update.check." + record.id.uuidString)
                    }
                }
            }
            if !scripts.isEmpty {
                Section {
                    ForEach(scripts) { script in
                        Button {
                            if let update = updates[script.id] { review = update }
                            else { check([script], showReview: true) }
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(script.name).foregroundStyle(.primary)
                                    if let version = script.version { Text("v" + version).font(.caption).foregroundStyle(.secondary) }
                                    if let message = messages[script.id] {
                                        Text(message).font(.footnote).foregroundStyle(.secondary)
                                    } else if UserScriptUpdateLoader.checkURL(for: script) == nil {
                                        Text(ToolText.text("userscript_update_no_url")).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if checking == script.id { ProgressView() }
                                else if updates[script.id] != nil || service.availableUserScriptUpdateVersions[script.id] != nil { Text(LanguageManager.shared.localizedString("extension_update")) }
                                else { Image(systemName: "arrow.clockwise") }
                            }.frame(minHeight: 44)
                        }
                        .disabled(checking != nil || UserScriptUpdateLoader.checkURL(for: script) == nil)
                        .accessibilityIdentifier("userscripts.update.check." + script.id.uuidString)
                    }
                } footer: { Text(ToolText.text("userscript_update_manual_hint")) }
            }
        }
        .navigationTitle(ToolText.text("userscript_check_updates"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(ToolText.text("userscript_check_updates")) {
                    check(checkableScripts, extensions: officialExtensions, showReview: false)
                }
                .disabled(checking != nil || (checkableScripts.isEmpty && officialExtensions.isEmpty))
                .accessibilityIdentifier("userscripts.update.check-all")
            }
        }
        .sheet(item: $review) { preview in
            UserScriptUpdateReviewView(preview: preview) { record in
                updates[record.id] = nil
                messages[record.id] = ToolText.text("userscript_update_latest")
                onUpdated?(record)
            }
        }
        .sheet(item: $extensionReview) { preview in
            WebExtensionReviewView(preview: preview) { record in
                extensionVersions[record.id] = nil
                messages[record.id] = ToolText.text("userscript_update_latest")
            }
        }
        .onDisappear { task?.cancel() }
    }
    private func check(_ scripts: [UserScriptRecord], extensions: [WebExtensionRecord] = [], showReview: Bool) {
        guard checking == nil, let firstID = extensions.first?.id ?? scripts.first?.id else { return }
        checking = firstID
        task = Task { @MainActor in
            defer { checking = nil; task = nil }
            for record in extensions {
                guard !Task.isCancelled else { return }
                checking = record.id
                do {
                    let result = try await WebExtensionStoreInstallService.shared.previewOfficialUpdate(for: record)
                    extensionVersions[record.id] = result?.version
                    messages[record.id] = result == nil ? ToolText.text("userscript_update_latest") : nil
                    if showReview { extensionReview = result }
                    else if let result { service.discardWebExtensionPreview(result) }
                } catch is CancellationError { return }
                catch {
                    extensionVersions[record.id] = nil
                    messages[record.id] = error.localizedDescription
                }
            }
            for script in scripts {
                guard !Task.isCancelled else { return }
                checking = script.id
                do {
                    let result = try await service.previewUserScriptUpdate(script.id)
                    updates[script.id] = result
                    messages[script.id] = result == nil ? ToolText.text("userscript_update_latest") : nil
                    if showReview { review = result }
                } catch is CancellationError { return }
                catch { messages[script.id] = error.localizedDescription }
            }
        }
    }
}

struct UserScriptUpdateReviewView: View {
    let preview: UserScriptUpdatePreview
    let onUpdated: (UserScriptRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(preview.metadata.name ?? preview.installed.name).font(.headline)
                    Text("\(preview.installed.version ?? "—") → \(preview.metadata.version ?? "—")").monospacedDigit()
                    if let description = preview.metadata.description { Text(description).font(.subheadline).foregroundStyle(.secondary) }
                }
                Section(LanguageManager.shared.localizedString("userscript_access_title")) {
                    Text(preview.metadata.patterns.isEmpty ? LanguageManager.shared.localizedString("userscript_access_all_sites") : preview.metadata.patterns.joined(separator: "\n"))
                    if !preview.metadata.excludePatterns.isEmpty { Text(preview.metadata.excludePatterns.joined(separator: "\n")).foregroundStyle(.secondary) }
                }
                Section(LanguageManager.shared.localizedString("userscript_permissions_title")) {
                    Text(preview.metadata.grants.isEmpty ? LanguageManager.shared.localizedString("userscript_no_extra_permissions") : preview.metadata.grants.joined(separator: ", "))
                    if !preview.metadata.connectDomains.isEmpty { Text(preview.metadata.connectDomains.joined(separator: ", ")) }
                }
                if !preview.metadata.requiredURLs.isEmpty {
                    Section(LanguageManager.shared.localizedString("userscript_external_requirements")) {
                        Text(preview.metadata.requiredURLs.joined(separator: "\n"))
                    }
                }
                Section {
                    DisclosureGroup(LanguageManager.shared.localizedString("userscript_code")) {
                        ScrollView(.horizontal) {
                            Text(preview.source).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                    Text(preview.sourceURL.absoluteString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(.red) }
                Button {
                    guard !saving else { return }; saving = true
                    Task { @MainActor in
                        defer { saving = false }
                        do {
                            let record = try await BrowserExtensionService.shared.applyUserScriptUpdate(preview)
                            onUpdated(record); dismiss()
                        } catch is CancellationError { error = ToolText.text("userscript_update_changed") }
                        catch { self.error = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        if saving { ProgressView().tint(.white) }
                        Text(LanguageManager.shared.localizedString("extension_update"))
                    }.frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("userscripts.update.install")
            }
            .disabled(saving)
            .navigationTitle(LanguageManager.shared.localizedString("extension_update"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(LanguageManager.shared.localizedString("cancel")) { dismiss() }.disabled(saving) }
        }
        .interactiveDismissDisabled(saving)
    }
}
