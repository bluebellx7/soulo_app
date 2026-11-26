import SwiftUI
import UniformTypeIdentifiers

struct SettingsBackupsView: View {
    @ObservedObject private var sync = CloudSyncService.shared
    @ObservedObject private var bookmarkSync = BookmarkCloudSyncService.shared
    @AppStorage(BookmarkCloudSyncService.enabledKey) private var bookmarkSyncEnabled = false
    @AppStorage(AppConstants.StorageKeys.iCloudSyncEnabled) private var iCloudSyncEnabled = false
    @State private var backups: [CloudSettingsBackup] = []
    @State private var selectedBackup: CloudSettingsBackup?
    @State private var deletingBackup: CloudSettingsBackup?
    @State private var showError = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = SettingsBackupDocument(data: Data())
    @State private var importNotice: String?
    @State private var clearNotice = false
    @State private var restoring = false

    private var manualBackups: [CloudSettingsBackup] { backups.filter { $0.isManual == true } }

    var body: some View {
        let recoveryDays = CloudSettingsBackupStore.recoveryDays(from: backups)
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "info.circle")
                        .font(.body).foregroundStyle(Color.themePrimary)
                        .accessibilityHidden(true)
                    Text(FeatureText.text("Settings backups contain appearance, home, browsing, privacy and platform preferences. They exclude bookmarks, history, logins and downloaded files. Bookmark import and export use HTML in the bookmark list."))
                        .font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.backups.explanation")
                }
                .padding(.vertical, 4)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            Section {
                Toggle(isOn: $iCloudSyncEnabled) {
                    SettingsDescriptionLabel(
                        icon: "icloud.fill",
                        color: iCloudSyncEnabled ? Color.themePrimary : Color(uiColor: .systemGray3),
                        title: LanguageManager.shared.localizedString("icloud_settings_sync"),
                        description: LanguageManager.shared.localizedString("icloud_settings_sync_desc")
                    )
                }
                .tint(Color.themePrimary)
                .onCompatibleChange(of: iCloudSyncEnabled) { _, enabled in
                    CloudSyncService.shared.setEnabled(enabled)
                }
                .accessibilityIdentifier("settings.icloud-sync")
                if sync.hasSyncIssue {
                    Text(LanguageManager.shared.localizedString("settings_backup_error"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if iCloudSyncEnabled {
                        Button(LanguageManager.shared.localizedString("retry")) { sync.refresh() }
                    }
                }
                Toggle(isOn: $bookmarkSyncEnabled) {
                    SettingsDescriptionLabel(icon: "bookmark.fill", color: bookmarkSyncEnabled ? .themePrimary : Color(uiColor: .systemGray3),
                        title: ToolText.text("icloud_bookmark_sync"),
                        description: FeatureText.text("Bookmarks merge across devices. Only explicit deletions remove items."))
                }
                .tint(.themePrimary)
                .accessibilityIdentifier("settings.icloud-bookmarks")
                .onCompatibleChange(of: bookmarkSyncEnabled) { _, value in bookmarkSync.setEnabled(value) }
                if bookmarkSync.hasSyncIssue {
                    Text(LanguageManager.shared.localizedString("settings_backup_error")).font(.footnote).foregroundStyle(.secondary)
                    Button(LanguageManager.shared.localizedString("retry")) { bookmarkSync.refresh() }
                }
                if bookmarkSync.isSynchronizing { ProgressView().accessibilityLabel("iCloud") }
            }
            Section {
                HStack(spacing: 3) {
                    Button {
                        do { try sync.saveBackup(); load() }
                        catch { showError = true }
                    } label: {
                        backupActionFace(ToolText.text("create_settings_backup"), symbol: "plus", primary: true)
                    }.accessibilityIdentifier("settings.backups.save")
                    Button { importing = true } label: {
                        backupActionFace(ToolText.text("favorites_import"), symbol: "square.and.arrow.down")
                    }.accessibilityIdentifier("settings.backups.import")
                    Menu {
                        if !manualBackups.isEmpty {
                            Section(ToolText.text("manual_settings_backups")) {
                                ForEach(manualBackups) { backup in exportChoice(backup) }
                            }
                        }
                        if !recoveryDays.isEmpty {
                            Section(ToolText.text("recovery_settings_backups")) {
                                ForEach(backups.filter { $0.isManual != true }) { backup in exportChoice(backup) }
                            }
                        }
                    } label: {
                        backupActionFace(ToolText.text("favorites_export"), symbol: "square.and.arrow.up")
                    }
                    .disabled(backups.isEmpty)
                    .accessibilityIdentifier("settings.backups.export")
                }
                .buttonStyle(.plain)
                .padding(3)
                .background(Color.themePrimary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 8, trailing: 12))
                .listRowSeparator(.hidden)
                if manualBackups.isEmpty {
                    Text(ToolText.text("manual_backups_empty"))
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .accessibilityIdentifier("settings.backups.empty")
                }
                ForEach(manualBackups) { backup in backupRow(backup) }
            } header: {
                HStack {
                    Text(ToolText.text("manual_settings_backups"))
                    Spacer()
                    Menu {
                        Button(role: .destructive) { clearNotice = true } label: {
                            Label(ToolText.text("clear_manual_backups"), systemImage: "trash")
                        }.accessibilityIdentifier("settings.backups.clear")
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.body)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(LanguageManager.shared.localizedString("extension_manage"))
                    .accessibilityIdentifier("settings.backups.manage")
                    .disabled(manualBackups.isEmpty)
                    .confirmationDialog(ToolText.text("clear_manual_backups"), isPresented: $clearNotice, titleVisibility: .visible) {
                        Button(ToolText.text("clear_manual_backups"), role: .destructive) {
                            do { try sync.clearManualBackups(); load() }
                            catch { load(); showError = true }
                        }.accessibilityIdentifier("settings.backups.confirm-clear")
                        Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                    } message: { Text(ToolText.text("clear_manual_backups_message")) }
                }
                .textCase(nil)
            } footer: {
                Text(ToolText.text("clear_manual_backups_message"))
            }
            if !recoveryDays.isEmpty {
                Section {
                    ForEach(recoveryDays) { day in backupRow(day.latest, earlier: day.earlier) }
                } header: {
                    Text(ToolText.text("recovery_settings_backups"))
                } footer: {
                    Text(String(format: FeatureText.text("iCloud sync saves a backup before settings change. Keeps the latest %lld backups plus the initial copy."), Int64(CloudSettingsBackupStore.maximumRecentBackups)))
                        .accessibilityIdentifier("settings.backups.retention")
                }
            }
        }
        .navigationTitle(ToolText.text("settings_sync_backup"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(restoring)
        .overlay { if restoring { ProgressView().accessibilityIdentifier("settings.backups.restoring") } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let limit = CloudSettingsBackupStore.maximumPortableBackupSize
                restoring = true
                Task { @MainActor in
                    defer { restoring = false }
                    do {
                        // Files providers may download before returning bytes.
                        // Keep that wait and the bounded read off the UI thread.
                        let data = try await Task.detached(priority: .userInitiated) {
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            let file = try FileHandle(forReadingFrom: url)
                            defer { try? file.close() }
                            let data = try file.read(upToCount: limit + 1) ?? Data()
                            guard data.count <= limit else { throw ReadingToolError.limit }
                            return data
                        }.value
                        _ = try sync.importBackup(data)
                        load()
                        importNotice = FeatureText.text("The imported backup has been added to the list. Choose Restore to apply it. Current settings have not changed.")
                    } catch { showError = true }
                }
            } catch { showError = true }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Soulo-Settings") { result in
            if case .failure = result { showError = true }
        }
        .statusNotice($importNotice)
        .onAppear(perform: load)
        .onCompatibleChange(of: sync.backupRevision) { _, _ in load() }
        .alert(LanguageManager.shared.localizedString("delete"), isPresented: Binding(
            get: { deletingBackup != nil }, set: { if !$0 { deletingBackup = nil } }
        ), presenting: deletingBackup) { backup in
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                do { try sync.deleteBackup(backup); deletingBackup = nil; load() }
                catch { deletingBackup = nil; showError = true }
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { deletingBackup = nil }
        } message: { _ in Text(ToolText.text("settings_backup_delete_message")) }
        .alert(LanguageManager.shared.localizedString("restore"), isPresented: Binding(
            get: { selectedBackup != nil }, set: { if !$0 { selectedBackup = nil } }
        ), presenting: selectedBackup) { backup in
            Button(LanguageManager.shared.localizedString("restore")) {
                selectedBackup = nil
                restoring = true
                Task { @MainActor in
                    // Finish dismissing the legacy alert before changing every
                    // AppStorage observer in the settings navigation hierarchy.
                    try? await Task.sleep(for: .milliseconds(200))
                    do { try sync.restoreBackup(backup); load() }
                    catch { showError = true }
                    restoring = false
                }
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) { selectedBackup = nil }
        } message: { _ in
            Text(LanguageManager.shared.localizedString("settings_backup_restore_message"))
        }
        .alert(LanguageManager.shared.localizedString("settings_backups"), isPresented: $showError) {
            Button(LanguageManager.shared.localizedString("done"), role: .cancel) {}
        } message: {
            Text(LanguageManager.shared.localizedString("settings_backup_error"))
        }
    }

    private func export(_ backup: CloudSettingsBackup) {
        do { exportDocument = SettingsBackupDocument(data: try sync.exportBackup(backup)); exporting = true }
        catch { showError = true }
    }

    private func exportChoice(_ backup: CloudSettingsBackup) -> some View {
        Button { export(backup) } label: {
            Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
        }
        .accessibilityIdentifier("settings.backups.export.\(backup.id.uuidString)")
    }

    private func backupActionFace(_ title: String, symbol: String, primary: Bool = false) -> some View {
        let icon = Image(systemName: symbol).font(.subheadline.weight(.semibold))
        let text = Text(title).font(.subheadline.weight(.medium))
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                icon
                text
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 3) {
                icon
                text.multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(primary ? Color.white : Color.themePrimary)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(primary ? Color.themePrimary : .clear, in: RoundedRectangle(cornerRadius: 11))
        .contentShape(RoundedRectangle(cornerRadius: 11))
    }

    private func backupRow(_ backup: CloudSettingsBackup, earlier: [CloudSettingsBackup] = []) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 19, weight: .regular)).foregroundStyle(.secondary)
                .frame(width: 36, height: 44)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(backup.createdAt, format: .dateTime.year().month().day())
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color(uiColor: .label))
                Text(backup.createdAt, format: .dateTime.hour().minute().second())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { selectedBackup = backup } label: {
                Text(LanguageManager.shared.localizedString("restore"))
                    .font(.caption.weight(.semibold)).foregroundStyle(Color.themePrimary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.themePrimary.opacity(0.09), in: Capsule())
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.backups.restore.\(backup.id.uuidString)")
            Menu { backupActions(backup, earlier: earlier) } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
                    .frame(minWidth: 32, minHeight: 44)
            }
            .accessibilityLabel(LanguageManager.shared.localizedString("show_more"))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 48 }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if backup.isManual == true {
                Button(role: .destructive) { deletingBackup = backup } label: {
                    Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                }
            }
        }
        .contextMenu { backupActions(backup, earlier: earlier) }
    }

    @ViewBuilder private func backupActions(_ backup: CloudSettingsBackup, earlier: [CloudSettingsBackup]) -> some View {
        Button { export(backup) } label: { Label(FeatureText.text("Export backup"), systemImage: "square.and.arrow.up") }
        if !earlier.isEmpty {
            Menu {
                ForEach(earlier) { previous in
                    Menu {
                        Button { selectedBackup = previous } label: {
                            Label(LanguageManager.shared.localizedString("restore"), systemImage: "arrow.counterclockwise")
                        }
                        exportChoice(previous)
                    } label: {
                        Text(previous.createdAt, format: .dateTime.hour().minute().second())
                    }
                }
            } label: {
                Label(ToolText.text("recovery_settings_backups"), systemImage: "clock.arrow.circlepath")
            }
        }
        if backup.isManual == true {
            Button(role: .destructive) { deletingBackup = backup } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
    }

    private func load() {
        do { backups = try sync.listBackups() }
        catch { showError = true }
    }
}

private struct SettingsBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
