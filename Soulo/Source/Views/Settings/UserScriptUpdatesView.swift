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
    private var scripts: [UserScriptRecord] {
        service.userScripts.filter { $0.isBuiltIn != true && (onlyID == nil || $0.id == onlyID) }
    }
    var body: some View {
        List {
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
                            else if updates[script.id] != nil { Text(LanguageManager.shared.localizedString("extension_update")) }
                            else { Image(systemName: "arrow.clockwise") }
                        }.frame(minHeight: 44)
                    }
                    .disabled(checking != nil || UserScriptUpdateLoader.checkURL(for: script) == nil)
                    .accessibilityIdentifier("userscripts.update.check." + script.id.uuidString)
                }
            } footer: { Text(ToolText.text("userscript_update_manual_hint")) }
        }
        .navigationTitle(ToolText.text("userscript_check_updates"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(ToolText.text("userscript_check_updates")) {
                    check(scripts.filter { UserScriptUpdateLoader.checkURL(for: $0) != nil }, showReview: false)
                }
                .disabled(checking != nil || !scripts.contains { UserScriptUpdateLoader.checkURL(for: $0) != nil })
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
        .onDisappear { task?.cancel() }
    }
    private func check(_ scripts: [UserScriptRecord], showReview: Bool) {
        guard checking == nil, let first = scripts.first else { return }
        checking = first.id
        task = Task { @MainActor in
            defer { checking = nil; task = nil }
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
