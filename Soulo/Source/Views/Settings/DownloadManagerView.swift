import SwiftUI
import UniformTypeIdentifiers

struct DownloadManagerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DownloadManagerContentView()
                .navigationTitle(LanguageManager.shared.localizedString("downloads"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                    }
                }
        }
    }
}

struct DownloadManagerContentView: View {
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    @State private var shareItem: BrowserDownloadItem?
    @State private var showDownloadsFolder = false

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
                    .onDelete(perform: deleteDownloads)
                }

                Section {
                    Button(role: .destructive) {
                        downloadManager.clearFinished()
                    } label: {
                        Label(
                            LanguageManager.shared.localizedString("downloads_clear_finished"),
                            systemImage: "trash"
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showDownloadsFolder = true
                } label: {
                    Image(systemName: "folder.fill")
                }
                .accessibilityLabel(
                    LanguageManager.shared.localizedString("open_downloads_folder")
                )
            }
        }
        .sheet(item: $shareItem) { item in
            DownloadShareSheet(items: [item.localURL])
        }
        .sheet(isPresented: $showDownloadsFolder) {
            DownloadFolderBrowser(isPresented: $showDownloadsFolder)
                .ignoresSafeArea()
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
                .background(
                    Color(UIColor.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )

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
                .accessibilityLabel(LanguageManager.shared.localizedString("share"))
            }
        }
        .swipeActions(edge: .trailing) {
            if item.status != .inProgress {
                Button(role: .destructive) {
                    downloadManager.delete(item)
                } label: {
                    Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                }
            }
        }
    }

    private func deleteDownloads(at offsets: IndexSet) {
        offsets
            .compactMap { index in
                guard downloadManager.downloads.indices.contains(index) else { return nil }
                return downloadManager.downloads[index]
            }
            .filter { $0.status != .inProgress }
            .forEach(downloadManager.delete)
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

private struct DownloadFolderBrowser: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.item],
            asCopy: false
        )
        picker.directoryURL = DownloadManagerService.downloadsDirectory
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private var isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            isPresented.wrappedValue = false
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            isPresented.wrappedValue = false
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
