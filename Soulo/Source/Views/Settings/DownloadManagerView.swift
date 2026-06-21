import SwiftUI

struct DownloadManagerView: View {
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: BrowserDownloadItem?

    var body: some View {
        List {
            if downloadManager.downloads.isEmpty {
                ContentUnavailableView(
                    LanguageManager.shared.localizedString("downloads_empty"),
                    systemImage: "arrow.down.circle",
                    description: Text(LanguageManager.shared.localizedString("downloads_empty_desc"))
                )
            } else {
                Section {
                    ForEach(downloadManager.downloads) { item in
                        downloadRow(item)
                    }
                    .onDelete { offsets in
                        offsets.map { downloadManager.downloads[$0] }.forEach(downloadManager.delete)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        downloadManager.clearFinished()
                    } label: {
                        Label(LanguageManager.shared.localizedString("downloads_clear_finished"), systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("downloads"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
            }
        }
        .sheet(item: $shareItem) { item in
            DownloadShareSheet(items: [item.localURL])
        }
        .onAppear {
            downloadManager.removeMissingFiles()
        }
    }

    private func downloadRow(_ item: BrowserDownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: item.status))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color(for: item.status))
                .frame(width: 34, height: 34)
                .background(Color(UIColor.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(statusText(for: item.status))
                    if let completedAt = item.completedAt {
                        Text("-")
                        Text(completedAt, style: .time)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if item.status == .finished {
                Button {
                    shareItem = item
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                downloadManager.delete(item)
            } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
    }

    private func icon(for status: BrowserDownloadStatus) -> String {
        switch status {
        case .inProgress: "arrow.down.circle"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    private func color(for status: BrowserDownloadStatus) -> Color {
        switch status {
        case .inProgress: .blue
        case .finished: .green
        case .failed: .orange
        case .canceled: .secondary
        }
    }

    private func statusText(for status: BrowserDownloadStatus) -> String {
        switch status {
        case .inProgress: LanguageManager.shared.localizedString("downloads_in_progress")
        case .finished: LanguageManager.shared.localizedString("downloads_finished")
        case .failed: LanguageManager.shared.localizedString("downloads_failed")
        case .canceled: LanguageManager.shared.localizedString("downloads_canceled")
        }
    }
}

private struct DownloadShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
