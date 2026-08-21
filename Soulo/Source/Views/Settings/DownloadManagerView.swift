import AVKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct DownloadManagerView: View {
    @Environment(\.dismiss) private var dismiss
    let highlightedItemID: UUID?

    init(highlightedItemID: UUID? = nil) {
        self.highlightedItemID = highlightedItemID
    }

    var body: some View {
        NavigationStack {
            DownloadManagerContentView(highlightedItemID: highlightedItemID)
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
    let highlightedItemID: UUID?
    @State private var previewItem: BrowserDownloadItem?
    @State private var shareItem: BrowserDownloadItem?
    @State private var showDownloadsFolder = false

    init(highlightedItemID: UUID? = nil) {
        self.highlightedItemID = highlightedItemID
    }

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
        .sheet(item: $previewItem) { item in
            DownloadContentPreview(item: item)
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
            if canPreview(item) {
                Button {
                    previewItem = item
                } label: {
                    downloadSummary(item)
                }
                .buttonStyle(.plain)
            } else {
                downloadSummary(item)
            }

            if item.status == .finished {
                Button {
                    shareItem = item
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LanguageManager.shared.localizedString("share"))
            } else if item.status == .inProgress {
                Button {
                    switch item.transport {
                    case .background:
                        BackgroundDownloadService.shared.pause(id: item.id)
                    case .webKit:
                        NotificationCenter.default.post(name: .pauseBrowserDownload, object: nil, userInfo: ["id": item.id])
                    case .streaming, .hls:
                        StreamingMediaDownloadService.shared.pause(itemID: item.id)
                    }
                } label: {
                    Image(systemName: "pause.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LanguageManager.shared.localizedString("pause"))
            } else if item.status == .paused {
                Button {
                    switch item.transport {
                    case .background:
                        BackgroundDownloadService.shared.resume(id: item.id)
                    case .webKit:
                        NotificationCenter.default.post(name: .resumeBrowserDownload, object: nil, userInfo: ["id": item.id])
                    case .streaming, .hls:
                        StreamingMediaDownloadService.shared.resume(itemID: item.id)
                    }
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LanguageManager.shared.localizedString("resume"))
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                downloadManager.delete(item)
            } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
        .listRowBackground(
            item.id == highlightedItemID
                ? Color.accentColor.opacity(0.12)
                : Color(uiColor: .secondarySystemGroupedBackground)
        )
    }

    private func downloadSummary(_ item: BrowserDownloadItem) -> some View {
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
                if item.status == .inProgress || item.status == .paused {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                    Text(progressText(item))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func canPreview(_ item: BrowserDownloadItem) -> Bool {
        item.status == .finished
            && FileManager.default.fileExists(atPath: item.localPath)
    }

    private func deleteDownloads(at offsets: IndexSet) {
        offsets
            .compactMap { index in
                guard downloadManager.downloads.indices.contains(index) else { return nil }
                return downloadManager.downloads[index]
            }
            .forEach(downloadManager.delete)
    }

    private func icon(for status: BrowserDownloadStatus) -> String {
        switch status {
        case .inProgress: "arrow.down.circle"
        case .paused: "pause.circle.fill"
        case .finished: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "xmark.circle.fill"
        }
    }

    private func color(for status: BrowserDownloadStatus) -> Color {
        switch status {
        case .inProgress: .blue
        case .paused: .blue
        case .finished: .green
        case .failed: .orange
        case .canceled: .secondary
        }
    }

    private func statusText(for status: BrowserDownloadStatus) -> String {
        switch status {
        case .inProgress: LanguageManager.shared.localizedString("downloads_in_progress")
        case .paused: LanguageManager.shared.localizedString("downloads_paused")
        case .finished: LanguageManager.shared.localizedString("downloads_finished")
        case .failed: LanguageManager.shared.localizedString("downloads_failed")
        case .canceled: LanguageManager.shared.localizedString("downloads_canceled")
        }
    }

    private func progressText(_ item: BrowserDownloadItem) -> String {
        let percent = Int((item.progress * 100).rounded())
        guard item.expectedBytes > 0 else { return "\(percent)%" }
        return "\(percent)% · \(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: item.expectedBytes, countStyle: .file))"
    }
}

extension Notification.Name {
    static let pauseBrowserDownload = Notification.Name("soulo.pauseBrowserDownload")
    static let resumeBrowserDownload = Notification.Name("soulo.resumeBrowserDownload")
    static let cancelBrowserDownload = Notification.Name("soulo.cancelBrowserDownload")
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

private struct DownloadContentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let item: BrowserDownloadItem

    var body: some View {
        NavigationStack {
            Group {
                if isPlayableMedia {
                    DownloadMediaPreview(url: item.localURL)
                } else {
                    DownloadQuickLookPreview(url: item.localURL)
                }
            }
            .navigationTitle(item.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                }
            }
        }
    }

    private var isPlayableMedia: Bool {
        guard let type = UTType(filenameExtension: item.localURL.pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}

private struct DownloadMediaPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        controller.showsPlaybackControls = true
        DispatchQueue.main.async {
            controller.player?.play()
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: AVPlayerViewController,
        coordinator: Void
    ) {
        uiViewController.player?.pause()
        uiViewController.player = nil
    }
}

private struct DownloadQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
