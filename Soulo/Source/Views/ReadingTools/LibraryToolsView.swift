import SwiftUI
import UniformTypeIdentifiers

struct LocalFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let directory: Bool
    let info: FilePresentation
    var modifiedAt: Date = .distantPast
    var coverURL: URL?
}
struct LibraryFilesView: View {
    var directory: URL = BookLibrary.directory
    var embeddedInLibrary = false
    @AppStorage("files.gridView") private var showsGrid = false
    @State private var files: [LocalFile] = []
    @State private var hasLoaded = false
    @State private var selected = Set<String>()
    @State private var isSelecting = false
    @State private var importing = false
    @State private var archive: LocalFile?
    @State private var book: LibraryBook?
    @State private var preview: LocalFile?
    @State private var showTransfer = false
    @State private var showMedia = false
    @State private var password = ""
    @State private var format = "zip"
    @State private var compressing = false
    @State private var compressionDirectory: URL?
    @State private var busy = false
    @State private var archiveRunning = false
    @State private var error: String?
    @State private var operation = FileOperationProgress()
    @State private var reloadTask: Task<Void, Never>?
    @State private var pendingDeletion: [URL] = []
    @State private var deletionAnchor: String?
    @State private var renamingFile: LocalFile?
    @State private var renameText = ""
    var body: some View {
        Group {
            if showsGrid { gridContent } else { listContent }
        }
        .disabled(busy)
        .overlay { if !hasLoaded { ProgressView() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting { selectionActions }
        }
        .navigationTitle(embeddedInLibrary ? LanguageManager.shared.localizedString("library") : directory == BookLibrary.directory ? ToolText.text("files") : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .mediaPlayerNavigation()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isSelecting {
                    Button { importing = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel(ToolText.text("import_files"))
                        .accessibilityIdentifier("files.import")
                    Button { showTransfer = true } label: { Image(systemName: "wifi") }
                        .accessibilityLabel(ToolText.text("wifi_transfer"))
                        .accessibilityIdentifier("files.wifi")
                }
                Button { showsGrid.toggle() } label: {
                    Image(systemName: showsGrid ? "list.bullet" : "square.grid.2x2")
                }
                .accessibilityLabel(LanguageManager.shared.localizedString(showsGrid ? "platform_list_view" : "platform_grid_view"))
                .accessibilityIdentifier("files.viewMode")
                Button {
                    if isSelecting { endSelection() } else { isSelecting = true }
                } label: {
                    Image(systemName: isSelecting ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .accessibilityLabel(ToolText.text(isSelecting ? "done" : "select"))
                .accessibilityIdentifier("files.selectionMode")
                .accessibilityAddTraits(isSelecting ? .isSelected : [])
                .disabled(busy || (!isSelecting && !files.contains(where: { !$0.directory })))
            }
        }
        .onAppear { reload() }
        .onDisappear { reloadTask?.cancel() }
        .alert(ToolText.text("rename_file"), isPresented: Binding(
            get: { renamingFile != nil }, set: { if !$0 { renamingFile = nil } }
        )) {
            TextField(ToolText.text("file_name"), text: $renameText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(LanguageManager.shared.localizedString("save")) {
                if let file = renamingFile { rename(file, to: renameText) }
                renamingFile = nil
            }.disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button(ToolText.text("cancel"), role: .cancel) { renamingFile = nil }
        } message: { Text(ToolText.text("rename_file_extension_hint")) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            Task {
                do {
                    let urls = try result.get()
                    busy = true
                    defer {
                        busy = false
                        reload()
                    }
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let target = FileSafety.availableURL(name: url.lastPathComponent, directory: directory)
                        try await Task.detached { try FileManager.default.copyItem(at: url, to: target) }.value
                    }
                } catch { self.error = error.localizedDescription }
            }
        }
        .navigationDestination(item: $book) { BookReaderView(book: $0) }
        .navigationDestination(item: $preview) { file in
            LocalDocumentContent(url: file.url)
        }
        .navigationDestination(item: $archive) { file in ArchiveBrowserView(url: file.url, directory: directory) }
        .navigationDestination(isPresented: $showMedia) { MediaPlayerPage() }
        .navigationDestination(isPresented: $showTransfer) { WiFiTransferView(directory: directory) }
        .navigationDestination(isPresented: $compressing) {

            Form {
                Picker(ToolText.text("format"), selection: $format) {
                    Text("ZIP").tag("zip")
                    Text("7z").tag("7z")
                }.pickerStyle(.segmented)
                NavigationLink {
                    FileDestinationView(selection: $compressionDirectory)
                } label: {
                    LabeledContent(
                        ToolText.text("destination"), value: (compressionDirectory ?? directory).lastPathComponent)
                }
                SecureField(ToolText.text("optional_password"), text: $password)
                Text(ToolText.text("compression_hint")).font(.footnote).foregroundStyle(.secondary)
                Button(ToolText.text("compress")) {
                    compressing = false
                    let files = files.filter { selected.contains($0.id) }.map(\.url)
                    let password = password.isEmpty ? nil : password
                    let selectedFormat = format
                    let destination = compressionDirectory ?? directory
                    run {
                        try ArchiveService.create(
                            files: files, format: selectedFormat, directory: destination, password: password,
                            operation: operation)
                    }
                }
            }.navigationTitle(ToolText.text("compress"))
                .toolbar { Button(ToolText.text("cancel")) { compressing = false } }

        }
        .overlay { if busy { if archiveRunning { FileOperationOverlay(operation: operation) } else { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } } }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
    private var listContent: some View {
        List {
            if hasLoaded && files.isEmpty {
                IllustratedToolEmptyState(scene: .files, title: ToolText.text("files_empty"))
            }
            ForEach(files) { file in
                HStack(spacing: 8) {
                    if file.directory {
                        NavigationLink { LibraryFilesView(directory: file.url) } label: { fileLabel(file) }
                    } else {
                        Button { open(file) } label: { fileLabel(file) }
                            .buttonStyle(.plain)
                        if isSelecting {
                            Button {
                                if !selected.insert(file.id).inserted { selected.remove(file.id) }
                            } label: {
                                Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 19, weight: .regular))
                                    .foregroundStyle(selected.contains(file.id) ? Color.themePrimary : Color.secondary.opacity(0.45))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(ToolText.text("select") + " " + file.url.lastPathComponent)
                            .accessibilityIdentifier("files.select.\(file.url.lastPathComponent)")
                            .accessibilityAddTraits(selected.contains(file.id) ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 12)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 8))
                .listRowBackground(selected.contains(file.id) ? Color.themePrimary.opacity(0.07) : Color.clear)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
                .alignmentGuide(.listRowSeparatorLeading) { _ in 56 }
                .contextMenu {
                    if !file.directory {
                        renameAction(file)
                        ShareLink(item: file.url) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
                        Button(ToolText.text("delete_files"), systemImage: "trash", role: .destructive) {
                            pendingDeletion = [file.url]; deletionAnchor = file.id
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if !file.directory {
                        // The destructive role makes List optimistically remove
                        // this row, taking its confirmation presenter with it.
                        Button {
                            pendingDeletion = [file.url]; deletionAnchor = file.id
                        } label: { Label(ToolText.text("delete_files"), systemImage: "trash") }
                        .tint(.red)
                    }
                }
                .fileDeletionConfirmation(isPresented: deletionBinding(file.id), count: pendingDeletion.count, confirm: deleteSelectedFiles)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 4, for: .scrollContent)
        .accessibilityIdentifier("files.list")
    }

    private var gridContent: some View {
        GeometryReader { geometry in
            ScrollView {
                if hasLoaded && files.isEmpty {
                    IllustratedToolEmptyState(scene: .files, title: ToolText.text("files_empty"))
                        .frame(maxWidth: .infinity, minHeight: geometry.size.height * 0.7)
                } else {
                    let count = geometry.size.width < 600 ? 3 : max(3, Int(geometry.size.width / 160))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: count), alignment: .leading, spacing: 24) {
                        ForEach(files) { file in
                            VStack(alignment: .leading, spacing: 8) {
                                if file.directory {
                                    NavigationLink { LibraryFilesView(directory: file.url) } label: { gridLabel(file) }
                                } else {
                                    Button { open(file) } label: { gridLabel(file) }
                                }
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) {
                                if isSelecting && !file.directory {
                                    Button {
                                        if !selected.insert(file.id).inserted { selected.remove(file.id) }
                                    } label: {
                                        Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 17, weight: .light))
                                            .foregroundStyle(selected.contains(file.id) ? Color.themePrimary : Color.secondary.opacity(0.5))
                                            .background {
                                                Circle().fill(.white.opacity(selected.contains(file.id) ? 0.9 : 0.25))
                                            }
                                            .frame(width: 44, height: 44)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(ToolText.text("select") + " " + file.url.lastPathComponent)
                                    .accessibilityIdentifier("files.select.\(file.url.lastPathComponent)")
                                    .accessibilityAddTraits(selected.contains(file.id) ? .isSelected : [])
                                }
                            }
                            .contextMenu {
                                if !file.directory {
                                    renameAction(file)
                                    ShareLink(item: file.url) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
                                    Button(ToolText.text("delete_files"), systemImage: "trash", role: .destructive) {
                                        pendingDeletion = [file.url]; deletionAnchor = file.id
                                    }
                                }
                            }
                            .fileDeletionConfirmation(isPresented: deletionBinding(file.id), count: pendingDeletion.count, confirm: deleteSelectedFiles)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 18)
                }
            }
            .accessibilityIdentifier("files.grid")
        }
    }

    private func gridLabel(_ file: LocalFile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            FileThumbnailView(file: file)
                .aspectRatio(0.68, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.06)) }
            Text(file.url.lastPathComponent)
                .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("files.item.\(file.url.lastPathComponent)")
    }

    private var selectedURLs: [URL] { files.filter { selected.contains($0.id) }.map(\.url) }

    private func fileLabel(_ file: LocalFile) -> some View {
        HStack(spacing: 12) {
            FileThumbnailView(file: file)
                .frame(width: 44, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(file.url.lastPathComponent)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                if !file.directory {
                    HStack(spacing: 8) {
                        Text(file.info.badge)
                            .font(.system(.caption2, design: .rounded).weight(.semibold))
                        Text(ByteCountFormatter.string(fromByteCount: file.info.size, countStyle: .file))
                            .font(.caption)
                    }.foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(minHeight: 48).contentShape(Rectangle())
        .accessibilityIdentifier("files.item.\(file.url.lastPathComponent)")
    }

    private var selectionActions: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(format: ToolText.text("selected_files_count"), selected.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ToolText.text("cancel")) { endSelection() }.font(.caption)
            }
            AdaptiveActionRow(spacing: 8) {
                Button { compressing = true } label: { Label(ToolText.text("compress"), systemImage: "doc.zipper") }
                    .buttonStyle(CompactActionButtonStyle())
                ShareLink(items: selectedURLs) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(CompactActionButtonStyle())
                Button(role: .destructive) {
                    pendingDeletion = selectedURLs; deletionAnchor = "selection"
                } label: { Label(ToolText.text("delete_files"), systemImage: "trash") }
                        .tint(.red)
                    .buttonStyle(CompactActionButtonStyle())
                    .fileDeletionConfirmation(isPresented: deletionBinding("selection"), count: pendingDeletion.count, confirm: deleteSelectedFiles)
            }
            .disabled(selected.isEmpty)
        }
        .padding(12).background(.regularMaterial)
        .disabled(busy)
    }

    private func deletionBinding(_ anchor: String) -> Binding<Bool> {
        Binding(get: { deletionAnchor == anchor }, set: {
            if !$0, deletionAnchor == anchor { deletionAnchor = nil }
        })
    }

    private func endSelection() {
        selected.removeAll()
        isSelecting = false
    }

    private func renameAction(_ file: LocalFile) -> some View {
        Button(ToolText.text("rename_file"), systemImage: "pencil") {
            renameText = file.url.deletingPathExtension().lastPathComponent
            renamingFile = file
        }
    }

    private func rename(_ file: LocalFile, to name: String) {
        guard !DownloadManagerService.shared.downloads.contains(where: {
            $0.localURL.standardizedFileURL == file.url.standardizedFileURL && [.inProgress, .paused].contains($0.status)
        }) else { error = ToolText.text("file_busy"); return }
        let bookIDs = Set(BookLibrary.shared.books.filter { $0.url.standardizedFileURL == file.url.standardizedFileURL }.map(\.id))
        let directory = directory
        busy = true
        Task {
            defer { busy = false; reload() }
            do {
                let target = try await Task.detached { try LibraryFileActions.rename(file.url, baseName: name, in: directory) }.value
                guard target != file.url else { return }
                do { try BookLibrary.shared.updateFileReference(bookIDs: bookIDs, to: target) }
                catch {
                    try await Task.detached { try FileManager.default.moveItem(at: target, to: file.url) }.value
                    throw error
                }
                DownloadManagerService.shared.updateFileReference(from: file.url, to: target)
                MediaSession.shared.updateFileReference(from: file.url, to: target)
                if selected.remove(file.id) != nil { selected.insert(target.path) }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func deleteSelectedFiles() {
        let targets = pendingDeletion
        pendingDeletion = []
        busy = true
        Task {
            do {
                try await Task.detached { try LibraryFileActions.delete(targets, in: directory) }.value
                DownloadManagerService.shared.removeMissingFiles()
                if let current = MediaSession.shared.url, targets.contains(current) { MediaSession.shared.stop() }
                for book in BookLibrary.shared.books where targets.contains(book.url) { BookLibrary.shared.remove(book.id) }
            } catch { self.error = error.localizedDescription }
            busy = false; reload()
        }
    }

    private func reload() {
        reloadTask?.cancel()
        let directory = directory
        let covers = Dictionary(BookLibrary.shared.books.filter { $0.hasCover == true }.map { ($0.url.standardizedFileURL, $0.coverURL) }, uniquingKeysWith: { first, _ in first })
        reloadTask = Task {
            do {
                let result = try await Task.detached {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey], options: .skipsHiddenFiles)
                        .compactMap { url -> LocalFile? in
                            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
                            guard values.isSymbolicLink != true else { return nil }
                            return LocalFile(url: url, directory: values.isDirectory == true, info: FilePresentation.inspect(url), modifiedAt: values.contentModificationDate ?? .distantPast, coverURL: covers[url.standardizedFileURL])
                        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                }.value
                guard !Task.isCancelled else { return }
                hasLoaded = true
                files = result; selected.formIntersection(Set(result.map(\.id)))
            } catch { if !Task.isCancelled { hasLoaded = true; self.error = error.localizedDescription } }
        }
    }
    private func open(_ file: LocalFile) {
        if isSelecting {
            if !selected.insert(file.id).inserted { selected.remove(file.id) }
            return
        }
        let ext = file.info.fileExtension
        if ArchiveService.extensions.contains(ext) {
            archive = file
        } else if BookFormat.extensions.contains(ext) && !file.url.pathExtension.isEmpty {
            Task {
                do { book = try await BookLibrary.shared.add(file.url) } catch {
                    self.error = error.localizedDescription
                }
            }
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) || type.conforms(to: .movie) {
            MediaSession.shared.open(url: file.url)
            showMedia = true
        } else {
            preview = file
        }
    }
    private func run(_ action: @escaping () throws -> URL) {
        operation = FileOperationProgress()
        archiveRunning = true
        busy = true
        Task {
            do { _ = try await Task.detached(priority: .userInitiated) { try action() }.value } catch {
                self.error = error.localizedDescription
            }
            busy = false
            archiveRunning = false
            password = ""
            selected.removeAll()
            reload()
        }
    }
}

struct FileOperationOverlay: View {
    let operation: FileOperationProgress
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            VStack(spacing: 16) {
                ProgressView(value: operation.progress.fractionCompleted)
                Button(ToolText.text("cancel")) { operation.progress.cancel() }
            }.padding(24).frame(width: 230).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct ArchiveBrowserView: View {
    let url: URL
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var destination: URL?
    @State private var entries: [ArchiveEntryInfo] = []
    @State private var error: String?
    @State private var busy = false
    @State private var operation = FileOperationProgress()
    var body: some View {

        List {
            Section {
                SecureField(ToolText.text("optional_password"), text: $password)
                Button(ToolText.text("preview_archive")) { list() }
                if let error { Text(error).font(.footnote).foregroundStyle(.secondary) }
            }
            Section(ToolText.text("contents")) {
                ForEach(entries) { entry in
                    Label {
                        VStack(alignment: .leading) {
                            Text(entry.path)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)).font(
                                .caption
                            ).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: entry.directory ? "folder" : "doc")
                    }
                }
            }
            Section {
                NavigationLink {
                    FileDestinationView(selection: $destination)
                } label: {
                    LabeledContent(ToolText.text("destination"), value: (destination ?? directory).lastPathComponent)
                }.disabled(busy)
                Button(ToolText.text("extract")) {
                    let pwd = password.isEmpty ? nil : password
                    busy = true
                    operation = FileOperationProgress()
                    let progress = operation
                    let target = destination ?? directory
                    Task {
                        do {
                            _ = try await Task.detached {
                                try ArchiveService.extract(url, to: target, password: pwd, operation: progress)
                            }.value
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(entries.isEmpty || busy)
                Text(ToolText.text("extract_hint")).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle(url.lastPathComponent).navigationBarTitleDisplayMode(.inline)
            .onDisappear { if busy { operation.progress.cancel() } }
            .overlay { if busy { FileOperationOverlay(operation: operation) } }
            .navigationBarBackButtonHidden(busy)
            .mediaPlayerNavigation()
            .task { if entries.isEmpty { list() } }

    }
    private func list() {
        guard !busy else { return }
        busy = true
        error = nil
        let pwd = password.isEmpty ? nil : password
        Task {
            do { entries = try await Task.detached { try ArchiveService.list(url, password: pwd) }.value } catch {
                entries = []
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// A page of app-owned folders. The selection stays within Downloads and never follows symlinks.
private struct FileDestinationView: View {
    @Binding var selection: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [URL] = []
    @State private var error: String?
    var body: some View {
        List {
            ForEach(folders, id: \.self) { folder in
                Button {
                    selection = folder
                    dismiss()
                } label: {
                    Label(
                        folder == BookLibrary.directory
                            ? ToolText.text("files")
                            : String(folder.path.dropFirst(BookLibrary.directory.path.count + 1)), systemImage: "folder"
                    )
                    .foregroundStyle(.primary)
                }
            }
            if let error { Text(error).foregroundStyle(.secondary) }
        }
        .navigationTitle(ToolText.text("destination"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                folders = try await Task.detached {
                    var result = [BookLibrary.directory]
                    guard
                        let enumerator = FileManager.default.enumerator(
                            at: BookLibrary.directory,
                            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                            options: [.skipsHiddenFiles])
                    else { return result }
                    while let url = enumerator.nextObject() as? URL {
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                        if values.isSymbolicLink == true {
                            enumerator.skipDescendants()
                            continue
                        }
                        if values.isDirectory == true { result.append(url) }
                        if result.count >= 1000 { break }
                    }
                    return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                }.value
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension View {
    func fileDeletionConfirmation(isPresented: Binding<Bool>, count: Int, confirm: @escaping () -> Void) -> some View {
        confirmationDialog(ToolText.text("delete_files_confirm"), isPresented: isPresented, titleVisibility: .visible) {
            Button(ToolText.text("delete_files"), role: .destructive, action: confirm)
            Button(ToolText.text("cancel"), role: .cancel) {}
        } message: {
            Text(String(format: ToolText.text("delete_files_message"), count))
        }
    }
}
