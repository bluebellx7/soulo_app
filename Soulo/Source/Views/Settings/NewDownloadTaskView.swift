import SwiftUI
import UniformTypeIdentifiers

struct DownloadCreationRequest: Identifiable {
    let id = UUID()
    var url: URL?
}
extension Notification.Name {
    static let createSouloDownload = Notification.Name("createSouloDownload")
}

struct NewDownloadTaskView: View {
    @Environment(\.dismiss) private var dismiss
    var initialURL: URL?
    @State private var address = ""
    @State private var filename = ""
    @State private var torrentLink = false
    @State private var importing = false
    @State private var working = false
    @State private var error: String?
    @State private var path: [UUID] = []
    @State private var operation: Task<Void, Never>?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    TextField(ToolText.text("download_address"), text: $address, axis: .vertical)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .lineLimit(2...5).accessibilityIdentifier("downloads.new.address")
                    if !address.lowercased().hasPrefix("magnet:") {
                        Toggle(ToolText.text("torrent_link"), isOn: $torrentLink)
                        if !torrentLink {
                            TextField(ToolText.text("download_optional_name"), text: $filename)
                                .accessibilityIdentifier("downloads.new.filename")
                        }
                    }
                } header: { Text(ToolText.text("download_link")) }
                  footer: { Text(ToolText.text("download_link_hint")) }
                Section {
                    Button { importing = true } label: {
                        Label(ToolText.text("import_torrent"), systemImage: "doc.badge.plus")
                    }.accessibilityIdentifier("downloads.new.import")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Label(ToolText.text("download_create"), systemImage: "arrow.down.circle.fill")
                            Spacer()
                            if working { ProgressView() }
                        }
                    }.disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("downloads.new.create")
                }
            }
            .disabled(working)
            .navigationTitle(ToolText.text("new_download"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ToolText.text("cancel")) { operation?.cancel(); dismiss() }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                TorrentTaskDetailView(id: id, onStarted: { dismiss() })
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { result in
                do { importFile(try result.get()) } catch { self.error = error.localizedDescription }
            }
            .onAppear {
                guard !importedInitial, let initialURL else { return }
                if initialURL.isFileURL { importFile(initialURL) }
                else { address = initialURL.absoluteString; torrentLink = initialURL.pathExtension.lowercased() == "torrent" }
                self.initialImportCompleted()
            }
        }
        .interactiveDismissDisabled(working)
    }
    @State private var importedInitial = false
    private func initialImportCompleted() { importedInitial = true }
    private func importFile(_ url: URL) {
        guard !working else { return }
        working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw TorrentTaskError.oversized }
                    return try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                let id = try await TorrentDownloadService.shared.create(data: data, magnet: nil)
                path.append(id)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    private func submit() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["magnet", "http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.scheme?.lowercased() == "magnet" || (url.host?.isEmpty == false && url.user == nil && url.password == nil) else {
            error = ToolText.text("download_invalid_address"); return
        }
        working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                if url.scheme?.lowercased() == "magnet" {
                    path.append(try await TorrentDownloadService.shared.create(data: nil, magnet: url.absoluteString))
                } else if torrentLink || url.pathExtension.lowercased() == "torrent" {
                    let data = try await TorrentMetadataFetcher.fetch(url)
                    try Task.checkCancellation()
                    path.append(try await TorrentDownloadService.shared.create(data: data, magnet: nil))
                } else {
                    let suggested = filename.isEmpty
                        ? WebDownloadFilename.native(suggested: url.lastPathComponent, pageTitle: nil) : filename
                    let (item, _) = DownloadManagerService.shared.beginDownload(
                        suggestedFilename: suggested, sourceURL: url, transport: .background)
                    // The native session owns the transfer after this form closes.
                    Task {
                        do { _ = try await BackgroundDownloadService.shared.start(request: URLRequest(url: url), item: item) }
                        catch { DownloadManagerService.shared.markFailed(id: item.id, error: error) }
                    }
                    dismiss()
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

enum TorrentMetadataFetcher {
    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw TorrentTaskError.oversized }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 8 * 1024 * 1024 { throw TorrentTaskError.oversized }
            data.append(byte)
        }
        return data
    }
}

struct TorrentTaskDetailView: View {
    let id: UUID
    var onStarted: (() -> Void)?
    @ObservedObject private var service = TorrentDownloadService.shared
    @ObservedObject private var manager = DownloadManagerService.shared
    @ObservedObject private var background = TorrentBackgroundCoordinator.shared
    private var record: BrowserDownloadItem? { manager.downloads.first { $0.id == id } }
    var body: some View {
        Group {
            if let job = service.job(id) {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(job.name, systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.headline).textSelection(.enabled)
                            Text(TorrentTaskLabels.state(job, snapshot: service.snapshots[job.id])).font(.subheadline).foregroundStyle(.secondary)
                            if let record { ProgressView(value: record.progress) }
                            if let s = service.snapshots[id], job.isActive {
                                HStack {
                                    Text(ByteCountFormatter.string(fromByteCount: s.speed, countStyle: .file) + "/s")
                                    Spacer()
                                    Text(String(format: ToolText.text("torrent_peers"), s.peers))
                                }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            }
                            if !job.error.isEmpty { Text(job.error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                        }.padding(.vertical, 6)
                    }
                    if !job.files.isEmpty {
                        Section {
                            if !job.isActive && job.state != .finished {
                                Button(job.selected.count == job.files.filter { !$0.pad }.count ? ToolText.text("torrent_select_none") : ToolText.text("torrent_select_all")) {
                                    service.select(id, indices: job.selected.count == job.files.filter { !$0.pad }.count ? [] : Set(job.files.filter { !$0.pad }.map(\.index)))
                                }
                                .accessibilityIdentifier("torrent.select-all")
                            }
                            ForEach(job.files.filter { !$0.pad }) { file in
                                Button {
                                    var selected = job.selected
                                    if selected.contains(file.index) { selected.remove(file.index) } else { selected.insert(file.index) }
                                    service.select(id, indices: selected)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: job.selected.contains(file.index) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(job.selected.contains(file.index) ? Color.accentColor : .secondary)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(file.path).font(.subheadline).foregroundStyle(.primary)
                                            Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(.vertical, 3)
                                }.buttonStyle(.plain).disabled(job.isActive || job.state == .finished)
                                    .accessibilityIdentifier("torrent.file.\(file.index)")
                                    .accessibilityValue(job.selected.contains(file.index) ? "selected" : "unselected")
                            }
                        } header: { Text(ToolText.text("torrent_files")) }
                    }
                    if let error = service.storageError { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !job.files.isEmpty {
                            Text(ByteCountFormatter.string(fromByteCount: job.selectedBytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        if job.state == .finished {
                            NavigationLink { LibraryFilesView(directory: URL(fileURLWithPath: job.directory)) } label: {
                                Label(ToolText.text("files"), systemImage: "folder")
                            }
                            .buttonStyle(CompactActionButtonStyle(prominent: true))
                        } else if job.isActive || job.state == .queued {
                            Button { service.pause(id) } label: { Label(ToolText.text("pause"), systemImage: "pause.circle") }
                                .buttonStyle(CompactActionButtonStyle())
                                .accessibilityIdentifier("torrent.pause")
                        } else {
                            Button { service.start(id); onStarted?() } label: {
                                Label(LanguageManager.shared.localizedString(job.state == .selection ? "download" : "resume"), systemImage: "arrow.down.circle.fill")
                            }.buttonStyle(CompactActionButtonStyle(prominent: true))
                                .disabled(!job.files.isEmpty && job.selected.isEmpty)
                                .accessibilityIdentifier("torrent.start")
                        }
                        Text(background.message ?? ToolText.text("torrent_background_hint"))
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            } else {
                ContentUnavailableView(LanguageManager.shared.localizedString("downloads_empty"), systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle(ToolText.text("torrent_task"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
enum TorrentTaskLabels {
    static func state(_ job: TorrentDownloadJob, snapshot: TorrentSnapshot? = nil) -> String {
        switch job.state {
        case .metadata: ToolText.text("torrent_metadata")
        case .selection: ToolText.text("torrent_choose_files")
        case .queued: ToolText.text("torrent_queued")
        case .starting: ToolText.text("loading")
        case .downloading: ToolText.text(snapshot?.checking == true ? "torrent_checking" : "torrent_downloading")
        case .paused: LanguageManager.shared.localizedString("downloads_paused")
        case .failed: job.error
        case .finished: LanguageManager.shared.localizedString("downloads_finished")
        }
    }
}

struct TorrentDownloadRow: View {
    let item: BrowserDownloadItem
    @ObservedObject private var service = TorrentDownloadService.shared
    var body: some View {
        NavigationLink { TorrentTaskDetailView(id: item.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 48)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                    if let job = service.job(item.id) {
                        Text(TorrentTaskLabels.state(job, snapshot: service.snapshots[job.id])).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if item.status == .inProgress { ProgressView(value: item.progress) }
                    if item.expectedBytes > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: item.expectedBytes, countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }.padding(.vertical, 3)
        }
        .accessibilityIdentifier("torrent.row.\(item.id)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { DownloadManagerService.shared.delete(item) } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
        .background(LibrarySwipeActionsRegion())
    }
}


/// Opening a saved torrent enters file selection; no payload is downloaded until Start.
struct TorrentDocumentContent: View {
    let url: URL
    @State private var id: UUID?
    @State private var error: String?
    var body: some View {
        Group {
            if let id { TorrentTaskDetailView(id: id) }
            else if let error {
                ContentUnavailableView(ToolText.text("error"), systemImage: "doc.badge.ellipsis", description: Text(error))
            } else { ProgressView() }
        }
        .task(id: url) {
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1024 * 1024 else { throw TorrentTaskError.oversized }
                    return try Data(contentsOf: url)
                }.value
                try Task.checkCancellation()
                id = try await TorrentDownloadService.shared.create(data: data, magnet: nil, openExisting: true)
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}
