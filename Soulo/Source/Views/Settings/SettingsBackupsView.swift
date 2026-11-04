import SwiftUI

struct SettingsBackupsView: View {
    @ObservedObject private var sync = CloudSyncService.shared
    @State private var backups: [CloudSettingsBackup] = []
    @State private var selectedBackup: CloudSettingsBackup?
    @State private var deletingBackup: CloudSettingsBackup?
    @State private var showError = false

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
