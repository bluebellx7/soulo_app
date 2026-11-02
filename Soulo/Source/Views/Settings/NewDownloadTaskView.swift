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
                    if !["magnet:", "ed2k:", "thunder:"].contains(where: { address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix($0) }) {
                        if URL(string: address)?.pathExtension.lowercased() != "torrent" {
                            TextField(ToolText.text("download_optional_name"), text: $filename)
                                .accessibilityIdentifier("downloads.new.filename")
                        }
                    }
                } header: { Text(ToolText.text("download_link")) }
                  footer: { Text(ToolText.text("download_link_hint")) }
                if let error {
                    Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
            .disabled(working)
            .dismissKeyboardOnBackgroundTap()
            .safeAreaInset(edge: .bottom) {
                Button(action: submit) {
                    HStack(spacing: 10) {
                        if working { ProgressView().tint(.white) }
                        Label(ToolText.text("download_create"), systemImage: "arrow.down.circle.fill")
                    }.frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(.blue)
                .disabled(working || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("downloads.new.create")
                .padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
            }
            .navigationTitle(ToolText.text("new_download"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ToolText.text("cancel")) { operation?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                    .disabled(working)
                    .accessibilityLabel(ToolText.text("import_torrent"))
                    .accessibilityIdentifier("downloads.new.import")
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
                else { address = initialURL.absoluteString }
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
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        guard let link = try? PeerDownloadLink.parse(address) else {
            error = ToolText.text("download_invalid_address"); return
        }
        working = true; error = nil
        operation = Task {
            defer { working = false }
            do {
                switch link {
                case .ed2k(let file):
                    try await ED2KDownloadService.shared.create(file)
                    dismiss()
                case .magnet(let url):
                    path.append(try await TorrentDownloadService.shared.create(data: nil, magnet: url.absoluteString))
                case .web(let url):
                    if let data = try await TorrentMetadataFetcher.fetchIfTorrent(url) {
                        try Task.checkCancellation()
                        path.append(try await TorrentDownloadService.shared.create(data: data, magnet: nil))
                        return
                    }
                    let suggested = filename.isEmpty
                        ? WebDownloadFilename.native(suggested: url.lastPathComponent, pageTitle: nil) : filename
                    let (item, _) = DownloadManagerService.shared.beginDownload(
                        suggestedFilename: suggested, sourceURL: url, transport: .background)
                    // The native session owns the transfer after this form closes.
                    Task {
                        do {
                            let local = try await BackgroundDownloadService.shared.start(request: URLRequest(url: url), item: item)
                            if let data = await TorrentMetadataFetcher.validTorrentData(at: local),
                               (try? await TorrentDownloadService.shared.create(data: data, magnet: nil, openExisting: true)) != nil {
                                DownloadManagerService.shared.delete(item)
                            }
                        }
                        catch { DownloadManagerService.shared.markFailed(id: item.id, error: error) }
                    }
                    dismiss()
                }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
}

enum TorrentMetadataFetcher {
    /// Recognizable torrent URLs open immediately. Ambiguous downloads are
    /// inspected after their existing background transfer, avoiding a second
    /// GET or a preflight that could consume a signed/one-use URL.
    static func fetchIfTorrent(_ url: URL) async throws -> Data? {
        guard url.pathExtension.lowercased() == "torrent" else { return nil }
        return try await fetch(url)
    }

    static func validTorrentData(at url: URL) async -> Data? {
        let data = await Task.detached(priority: .utility) { () -> Data? in
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= 8 * 1024 * 1024,
                  let file = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? file.close() }
            guard let prefix = try? file.read(upToCount: 128), looksLikeTorrent(prefix) else { return nil }
            return try? Data(contentsOf: url)
        }.value
        guard let data, (try? await TorrentEngineWorker().inspect(data: data)) != nil else { return nil }
        return data
    }

    static func looksLikeTorrent(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.first == 100, let colon = bytes.firstIndex(of: 58), (2...4).contains(colon),
              let count = Int(String(decoding: bytes[1..<colon], as: UTF8.self)), count > 0,
              colon + 1 + count <= bytes.count else { return false }
        let key = String(decoding: bytes[(colon + 1)..<(colon + 1 + count)], as: UTF8.self)
        return ["announce", "announce-list", "info", "comment", "created by", "creation date", "encoding", "nodes", "url-list", "piece layers"].contains(key)
    }

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
    @State private var playingFile: TorrentFileEntry?
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
                                VStack(alignment: .leading, spacing: 2) {
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
                                  if service.canStream(id, file: file) {
                                    Button { playingFile = file } label: {
                                        Label(job.state == .finished ? ToolText.text("play") : LanguageManager.shared.localizedString("downloads_play_while_downloading"),
                                              systemImage: "play.circle")
                                            .font(.subheadline).frame(minHeight: 44, alignment: .leading)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("torrent.play.\(file.index)")
                                  }
                                }
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
        .sheet(item: $playingFile) { file in
            NavigationStack {
                TorrentFilePlaybackView(id: id, file: file)
            }
        }
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
