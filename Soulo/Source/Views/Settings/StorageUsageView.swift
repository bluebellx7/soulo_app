import SwiftUI

struct StorageUsageView: View {
    @EnvironmentObject private var tabManager: TabManager
    @State private var records: [StorageUsageRecord] = []
    @State private var clearing: StorageUsageCategory?
    @State private var requested: StorageUsageCategory?
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                Text(FeatureText.text("Cache cleanup keeps your downloads, reading progress, backups, history and website logins. Remove saved files from their own lists."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                HStack {
                    Text(record.category.title)
                    Spacer()
                    if clearing == record.category { ProgressView() }
                    else { Text(ByteCountFormatter.string(fromByteCount: record.bytes, countStyle: .file)).foregroundStyle(.secondary).monospacedDigit() }
                    if record.canClear {
                        Button { requested = record.category } label: { Image(systemName: "trash").frame(minWidth: 44, minHeight: 44) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(LanguageManager.shared.localizedString("delete") + " " + record.category.title)
                    }
                }
            }
            Section { Text(FeatureText.text("Website cache size is an estimate. Categories exclude system-managed temporary space."))
                .font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle(FeatureText.text("Storage"))
        .overlay { if loading { ProgressView() } }
        .disabled(clearing != nil)
        .task { await refresh() }
        .refreshable { await refresh() }
        .confirmationDialog(FeatureText.text("Clear this cache?"), isPresented: Binding(get: { requested != nil }, set: { if !$0 { requested = nil } }), presenting: requested) { category in
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                requested = nil; clearing = category
                Task {
                    do { try await StorageUsageService.clear(category, tabManager: tabManager) }
                    catch { self.error = error.localizedDescription }
                    clearing = nil; await refresh()
                }
            }
        } message: { category in Text(category.title) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func refresh() async { records = await StorageUsageService.scan(); loading = false }
}

extension StorageUsageCategory {
    var title: String {
        FeatureText.text([.webData: "Website cache", .tabSnapshots: "Tab previews", .favicons: "Website icons",
            .wallpapers: "Favorite wallpapers", .downloads: "Downloaded files", .readingData: "Reading data",
            .backups: "Settings backups", .filterRules: "Filter rules"][self]!)
    }
}
