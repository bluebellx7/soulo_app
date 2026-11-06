import SwiftUI
import UniformTypeIdentifiers

struct SettingsBackupsView: View {
    @ObservedObject private var sync = CloudSyncService.shared
    @State private var backups: [CloudSettingsBackup] = []
    @State private var selectedBackup: CloudSettingsBackup?
    @State private var deletingBackup: CloudSettingsBackup?
    @State private var showError = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = SettingsBackupDocument(data: Data())
    @State private var importNotice = false

    var body: some View {
        List {
            Section {
                Button {
                    do { try sync.saveBackup(); load() }
                    catch { showError = true }
                } label: {
                    Label(LanguageManager.shared.localizedString("save"), systemImage: "plus.circle")
                }
                .accessibilityIdentifier("settings.backups.save")
                ForEach(backups) { backup in
                    Button { selectedBackup = backup } label: {
                        HStack {
                            Text(backup.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(LanguageManager.shared.localizedString("restore"))
                        }
                    }
                    .accessibilityIdentifier("settings.backups.restore.\(backup.id.uuidString)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) { deletingBackup = backup } label: {
                            Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            do { exportDocument = SettingsBackupDocument(data: try sync.exportBackup(backup)); exporting = true }
                            catch { showError = true }
                        } label: { Label(FeatureText.text("Export backup"), systemImage: "square.and.arrow.up") }
                        Button(role: .destructive) { deletingBackup = backup } label: {
                            Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text(ToolText.text("settings_backup_intro"))
                    .textCase(nil)
            } footer: {
                Text(ToolText.text("settings_backup_manage_hint"))
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("settings_backups"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Label(FeatureText.text("Import backup"), systemImage: "square.and.arrow.down") }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw ReadingToolError.limit }
                _ = try sync.importBackup(Data(contentsOf: url))
                load(); importNotice = true
            } catch { showError = true }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "Soulo-Settings") { result in
            if case .failure = result { showError = true }
        }
        .alert(FeatureText.text("Import backup"), isPresented: $importNotice) {
            Button(ToolText.text("done")) {}
        } message: { Text(FeatureText.text("The imported backup has been added to the list. Choose Restore to apply it. Current settings have not changed.")) }
        .onAppear(perform: load)
        .onChange(of: sync.backupRevision) { _, _ in load() }
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
                do { try sync.restoreBackup(backup); selectedBackup = nil; load() }
                catch { selectedBackup = nil; showError = true }
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
