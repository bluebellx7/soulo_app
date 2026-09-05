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
                .navigationBarTitleDisplayMode(.inline)
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
    var onOpenFiles: (() -> Void)? = nil
    @State private var previewItem: BrowserDownloadItem?
    @State private var shareItem: BrowserDownloadItem?
    @State private var showDownloadsFolder = false
    @State private var showClearConfirmation = false

    private var hasFinishedDownloads: Bool {
        downloadManager.downloads.contains { [.finished, .failed, .canceled].contains($0.status) }
    }

    init(highlightedItemID: UUID? = nil, onOpenFiles: (() -> Void)? = nil) {
        self.highlightedItemID = highlightedItemID
        self.onOpenFiles = onOpenFiles
    }

    var body: some View {
        List {
            if onOpenFiles == nil {
                Section { NavigationLink { LibraryFilesView() } label: { Label(ToolText.text("files_tools"), systemImage: "folder.badge.gearshape") } }
            }
            if downloadManager.downloads.isEmpty {
                IllustratedToolEmptyState(
                    scene: .files,
                    title: LanguageManager.shared.localizedString("downloads_empty"),
                    message: LanguageManager.shared.localizedString("downloads_empty_desc")
                )
            } else {
                Section {
                    ForEach(downloadManager.downloads) { item in
                        downloadRow(item)
                    }
                    .onDelete(perform: deleteDownloads)
                }

                if hasFinishedDownloads {
                    Section {
                        Button(role: .destructive) {
                            showClearConfirmation = true
                        } label: {
                            Label(
                                LanguageManager.shared.localizedString("downloads_clear_finished"),
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            LanguageManager.shared.localizedString("downloads_clear_finished"),
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                downloadManager.clearFinished()
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let onOpenFiles { onOpenFiles() } else { showDownloadsFolder = true }
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
                .accessibilityLabel(
                    LanguageManager.shared.localizedString("open_downloads_folder")
                )
            }
        }
        .sheet(item: $shareItem) { item in
            DownloadShareSheet(items: [item.localURL])
        }
        .navigationDestination(isPresented: Binding(get: { previewItem != nil }, set: { if !$0 { previewItem = nil } })) {
            if let item = previewItem { DownloadContentPreview(item: item) }
        }
        .navigationDestination(isPresented: $showDownloadsFolder) { LibraryFilesView() }
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
                        .frame(minWidth: 44, minHeight: 44)
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
                        .frame(minWidth: 44, minHeight: 44)
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
                        .frame(minWidth: 44, minHeight: 44)
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
                ? Color.themePrimary.opacity(0.12)
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
        case .inProgress: Color.themePrimary
        case .paused: Color.themePrimary
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

private struct DownloadShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DownloadContentPreview: View {
    let item: BrowserDownloadItem

    var body: some View {
        Group {
            if isPlayableMedia {
                VStack { MediaPlaybackSurface(); MediaControls() }
                    .task { MediaSession.shared.open(url: item.localURL, title: item.fileName) }
            } else {
                DownloadQuickLookPreview(url: item.localURL).mediaPlayerNavigation()
            }
        }
        .navigationTitle(item.fileName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isPlayableMedia: Bool {
        guard let type = UTType(filenameExtension: item.localURL.pathExtension) else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}

struct DownloadQuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        context.coordinator.prepare(controller)
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    static func dismantleUIViewController(_ controller: QLPreviewController, coordinator: Coordinator) { coordinator.cancel() }

    @MainActor final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let original: URL
        private var prepared: PreparedFilePreview?
        private var task: Task<Void, Never>?
        init(url: URL) { original = url }
        func prepare(_ controller: QLPreviewController) {
            let url = original
            task = Task { [weak self, weak controller] in
                let result = try? await Task.detached { try PreparedFilePreview.prepare(url) }.value
                guard !Task.isCancelled, let self, let controller else { result?.removeTemporaryFile(); return }
                self.prepared = result ?? PreparedFilePreview(url: url, temporaryDirectory: nil)
                controller.reloadData()
            }
        }
        func cancel() { task?.cancel(); prepared?.removeTemporaryFile(); prepared = nil }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { prepared == nil ? 0 : 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            (prepared?.url ?? original) as NSURL
        }
    }
}
