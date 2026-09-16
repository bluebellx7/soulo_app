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
    var embeddedInLibrary = false
    @State private var previewItem: BrowserDownloadItem?
    @State private var shareItem: BrowserDownloadItem?
    @State private var showDownloadsFolder = false
    @State private var showClearConfirmation = false
    @State private var systemFile: URL?
    @State private var fileError: String?

    private var hasFinishedDownloads: Bool {
        downloadManager.downloads.contains { [.finished, .failed, .canceled].contains($0.status) }
    }

    init(highlightedItemID: UUID? = nil, embeddedInLibrary: Bool = false) {
        self.highlightedItemID = highlightedItemID
        self.embeddedInLibrary = embeddedInLibrary
    }

    var body: some View {
        List {
            if !embeddedInLibrary {
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
                                ToolText.text("clear_download_records"),
                                systemImage: "trash"
                            )
                        }
                        .confirmationDialog(
                            ToolText.text("clear_download_records"),
                            isPresented: $showClearConfirmation,
                            titleVisibility: .visible
                        ) {
                            Button(ToolText.text("clear_download_records"), role: .destructive) {
                                downloadManager.clearFinished()
                            }
                            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
                        } message: {
                            Text(ToolText.text("download_records_keep_files"))
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDownloadsFolder = true
                } label: {
                    Image(systemName: "folder.fill")
                        .font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
                .accessibilityLabel(
                    ToolText.text("system_files")
                )
            }
        }
        .sheet(item: $shareItem) { item in
            DownloadShareSheet(items: [item.localURL])
        }
        .navigationDestination(isPresented: Binding(get: { previewItem != nil }, set: { if !$0 { previewItem = nil } })) {
            if let item = previewItem { DownloadContentPreview(item: item) }
        }
        .fileImporter(isPresented: $showDownloadsFolder, allowedContentTypes: [.data]) { result in
            Task {
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    systemFile = try await Task.detached { try ExternalDocumentImporter.copyToLibrary(url) }.value
                } catch { fileError = error.localizedDescription }
            }
        }
        .navigationDestination(item: $systemFile) { LocalDocumentContent(url: $0) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button(ToolText.text("done")) { fileError = nil }
        } message: { Text(fileError ?? "") }
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
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("downloads.open.\(item.id)")
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
                Label(
                    [.inProgress, .paused].contains(item.status)
                        ? LanguageManager.shared.localizedString("cancel")
                        : ToolText.text("remove_download_record"),
                    systemImage: "trash"
                )
            }.tint(.red)
        }
        .listRowBackground(
            item.id == highlightedItemID
                ? Color.themePrimary.opacity(0.12)
                : Color(uiColor: .secondarySystemGroupedBackground)
        )
    }

    private func downloadSummary(_ item: BrowserDownloadItem) -> some View {
        HStack(spacing: 12) {
            if item.status == .finished {
                DownloadFileThumbnail(item: item)
                    .frame(width: 44, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: icon(for: item.status))
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color(for: item.status))
                .frame(width: 44, height: 54)
                .background(
                    Color(UIColor.tertiarySystemFill),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }

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

private struct DownloadFileThumbnail: View {
    let item: BrowserDownloadItem
    @ObservedObject private var library = BookLibrary.shared
    @State private var file: LocalFile?

    private var fileWithCover: LocalFile? {
        guard var file else { return nil }
        file.coverURL = library.books.first {
            $0.hasCover == true && $0.url.standardizedFileURL == file.url.standardizedFileURL
        }?.coverURL
        return file
    }

    var body: some View {
        Group {
            if let file = fileWithCover {
                FileThumbnailView(file: file)
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(Color.themePrimary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .secondarySystemBackground))
            }
        }
        .accessibilityHidden(true)
        .task(id: item.localPath) {
            file = nil
            let url = item.localURL
            let result = await Task.detached(priority: .utility) {
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return LocalFile(url: url, directory: false, info: FilePresentation.inspect(url), modifiedAt: modifiedAt)
            }.value
            guard !Task.isCancelled else { return }
            file = result
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

struct DownloadContentPreview: View {
    let item: BrowserDownloadItem
    var body: some View { LocalDocumentContent(url: item.localURL) }
}

struct LocalDocumentContent: View {
    let url: URL
    @State private var book: LibraryBook?
    @State private var error: String?

    @State private var fileKind: FilePresentation.Kind?

    private var isBook: Bool { BookFormat.extensions.contains(url.pathExtension.lowercased()) }

    var body: some View {
        Group {
            if fileKind == .image {
                LocalImagePreview(url: url)
            } else if fileKind == nil {
                ProgressView()
            } else if isBook {
                if let book {
                    BookReaderView(book: book)
                } else if let error {
                    ContentUnavailableView(ToolText.text("reading_failed"), systemImage: "book.closed", description: Text(error))
                } else {
                    ProgressView().task {
                        do { book = try await BookLibrary.shared.add(url) }
                        catch { self.error = error.localizedDescription }
                    }
                }
            } else if ArchiveService.extensions.contains(url.pathExtension.lowercased()) {
                ArchiveBrowserView(url: url, directory: url.deletingLastPathComponent())
            } else if FilePresentation.textExtensions.contains(url.pathExtension.lowercased())
                        || UTType(filenameExtension: url.pathExtension)?.conforms(to: .plainText) == true
                        || UTType(filenameExtension: url.pathExtension)?.conforms(to: .sourceCode) == true {
                TextDocumentPreview(url: url)
            } else if isPlayableMedia {
                MediaPlaybackContent()
                    .task { MediaSession.shared.open(url: url, title: url.lastPathComponent) }
            } else {
                DownloadQuickLookPreview(url: url).mediaPlayerNavigation()
            }
        }
        .task(id: url) {
            fileKind = await Task.detached { FilePresentation.inspect(url).kind }.value
        }
        .navigationTitle(isBook ? "" : url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isPlayableMedia: Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else {
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

struct IncomingDocument: Identifiable, Hashable {
    let id = UUID()
    let url: URL
}

struct ExternalDocumentView: View {
    let source: URL
    @State private var localURL: URL?
    @State private var error: String?
    var body: some View {
        Group {
            if let localURL { LocalDocumentContent(url: localURL) }
            else if let error { ContentUnavailableView(ToolText.text("reading_failed"), systemImage: "doc", description: Text(error)) }
            else { ProgressView() }
        }
        .task(id: source) {
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ExternalDocumentImporter.copyToLibrary(source)
                }.value
                guard !Task.isCancelled else { return }
                localURL = imported
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct TextDocumentPreview: View {
    let url: URL
    @State private var encoding = "auto"
    @State private var text: String?
    @State private var error: String?
    var body: some View {
        Group {
            if let text { SelectableDocumentText(text: text) }
            else if let error { ContentUnavailableView(ToolText.text("reading_failed"), systemImage: "doc.text", description: Text(error)) }
            else { ProgressView() }
        }
        .task(id: url.absoluteString + encoding) {
            text = nil; error = nil
            let selectedEncoding = encoding
            do {
                let decoded = try await Task.detached(priority: .userInitiated) {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 16 * 1024 * 1024 else { throw ReadingToolError.limit }
                    return try TextBookDecoder.decode(Data(contentsOf: url, options: .mappedIfSafe), encoding: selectedEncoding)
                }.value
                guard !Task.isCancelled else { return }
                text = decoded
            } catch ReadingToolError.invalid {
                if !Task.isCancelled { self.error = ToolText.text("text_encoding_failed") }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(ToolText.text("encoding"), selection: $encoding) {
                        ForEach(TextBookDecoder.encodings, id: \.self) { value in
                            Text(value == "auto" ? ToolText.text("auto") : value).tag(value)
                        }
                    }
                    ShareLink(item: url) { ToolMenuLabel(key: "share", symbol: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel(ToolText.text("encoding"))
                .accessibilityIdentifier("text.options")
            }
        }
    }
}
private struct SelectableDocumentText: UIViewRepresentable {
    let text: String
    func makeUIView(context: Context) -> UITextView {
        let view = SelectionSearchTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 24, right: 16)
        view.text = text
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) { if view.text != text { view.text = text } }
}


/// A transient completion event, shared by all download transports. Persisted
/// download history is deliberately not replayed as a new success notification.
struct DownloadCompletionToast: View {
    let onOpenDownloads: () -> Void
    @State private var completed: BrowserDownloadItem?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    var body: some View {
        Group {
            if let completed {
                Button {
                    self.completed = nil
                    onOpenDownloads()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(LanguageManager.shared.localizedString("resource_download_complete"))
                                .font(.subheadline.weight(.semibold))
                            Text(completed.fileName)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("downloads.completion-toast")
                .accessibilityHint(LanguageManager.shared.localizedString("downloads"))
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: completed.id) {
                    do { try await Task.sleep(for: .seconds(voiceOverEnabled ? 8 : 4)) }
                    catch { return }
                    guard self.completed?.id == completed.id else { return }
                    self.completed = nil
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: completed?.id)
        .onReceive(DownloadManagerService.shared.didFinishDownload) { item in
            guard scenePhase == .active else { return }
            completed = item
            AppAccessibility.announce(LanguageManager.shared.localizedString("resource_download_complete") + ", " + item.fileName)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { completed = nil }
        }
    }
}
