import SwiftUI
import UniformTypeIdentifiers

struct BookshelfView: View {
    @ObservedObject private var library = BookLibrary.shared
    @State private var importing = false
    @State private var selected: LibraryBook?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        List {
            if library.books.isEmpty {
                IllustratedToolEmptyState(
                    scene: .books, title: ToolText.text("bookshelf_empty"),
                    message: ToolText.text("bookshelf_hint"))
            }
            ForEach(library.books.sorted { $0.openedAt > $1.openedAt }) { book in
                Button {
                    selected = book
                } label: {
                    HStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.themePrimary.opacity(0.12))
                            if book.hasCover == true {
                                AsyncImage(url: book.coverURL) { image in
                                    image.resizable().scaledToFill()
                                } placeholder: {
                                    Image(systemName: "book.closed")
                                }
                            } else {
                                Image(systemName: book.url.pathExtension == "pdf" ? "doc.richtext" : "book.closed")
                                    .font(.title2).foregroundStyle(Color.themePrimary)
                            }
                        }.frame(width: 50, height: 66).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                            Text("\(book.url.pathExtension.uppercased()) · \(Int(book.fraction * 100))%").font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: book.fraction).tint(Color.themePrimary)
                        }
                    }.padding(.vertical, 8)
                }.contextMenu {
                    Button(ToolText.text("remove_from_shelf"), role: .destructive) { library.remove(book.id) }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Image(systemName: "plus").font(.system(size: AppControlMetrics.iconSize, weight: .semibold)) }
                    .accessibilityLabel(ToolText.text("import_book"))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            Task {
                busy = true
                defer { busy = false }
                do { for url in try result.get() { _ = try await library.add(url) } } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        .overlay {
            if busy { ProgressView().padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) }
        }
        .navigationDestination(item: $selected) { book in BookReaderView(book: book) }
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

struct LocalFile: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let directory: Bool
    let info: FilePresentation
}
struct LibraryFilesView: View {
    var directory: URL = BookLibrary.directory
    var embeddedInLibrary = false
    @State private var files: [LocalFile] = []
    @State private var hasLoaded = false
    @State private var selected = Set<String>()
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
    @State private var showDeleteConfirmation = false
    var body: some View {
        List {
            if hasLoaded && files.isEmpty {
                IllustratedToolEmptyState(scene: .files, title: ToolText.text("files_empty"))
            }
            ForEach(files) { file in
                HStack(spacing: 8) {
                    if !file.directory {
                        Button {
                            if !selected.insert(file.id).inserted { selected.remove(file.id) }
                        } label: {
                            Image(systemName: selected.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(ToolText.text("select") + " " + file.url.lastPathComponent)
                        .accessibilityAddTraits(selected.contains(file.id) ? .isSelected : [])
                    }
                    if file.directory {
                        NavigationLink { LibraryFilesView(directory: file.url) } label: { fileLabel(file) }
                    } else {
                        Button { open(file) } label: { fileLabel(file) }.buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    if !file.directory {
                        ShareLink(item: file.url) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
                        Button(ToolText.text("delete_files"), systemImage: "trash", role: .destructive) {
                            pendingDeletion = [file.url]; showDeleteConfirmation = true
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if !file.directory {
                        Button(role: .destructive) {
                            pendingDeletion = [file.url]; showDeleteConfirmation = true
                        } label: { Label(ToolText.text("delete_files"), systemImage: "trash") }
                    }
                }
            }
        }
        .disabled(busy)
        .overlay { if !hasLoaded { ProgressView() } }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !selected.isEmpty { selectionActions }
        }
        .confirmationDialog(ToolText.text("delete_files_confirm"), isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button(ToolText.text("delete_files"), role: .destructive) { deleteSelectedFiles() }
            Button(ToolText.text("cancel"), role: .cancel) { pendingDeletion = [] }
        } message: {
            Text(String(format: ToolText.text("delete_files_message"), pendingDeletion.count))
        }
        .navigationTitle(embeddedInLibrary ? LanguageManager.shared.localizedString("library") : directory == BookLibrary.directory ? ToolText.text("files") : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .mediaPlayerNavigation()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(ToolText.text("import_files"), systemImage: "square.and.arrow.down") { importing = true }
                    Button(ToolText.text("wifi_transfer"), systemImage: "wifi") { showTransfer = true }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                }
            }
        }
        .onAppear { reload() }
        .onDisappear { reloadTask?.cancel() }
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
            DownloadQuickLookPreview(url: file.url).mediaPlayerNavigation().navigationTitle(file.url.lastPathComponent)
                .navigationBarTitleDisplayMode(.inline)
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
    private var selectedURLs: [URL] { files.filter { selected.contains($0.id) }.map(\.url) }

    private func fileLabel(_ file: LocalFile) -> some View {
        HStack(spacing: 10) {
            Image(systemName: file.info.symbol)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(file.url.lastPathComponent).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    .lineLimit(2).truncationMode(.middle)
                if !file.directory {
                    Text(file.info.badge + " · " + ByteCountFormatter.string(fromByteCount: file.info.size, countStyle: .file))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 8)
    }

    private var selectionActions: some View {
        VStack(spacing: 8) {
            HStack {
                Text(String(format: ToolText.text("selected_files_count"), selected.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(ToolText.text("cancel")) { selected.removeAll() }.font(.caption)
            }
            AdaptiveActionRow(spacing: 8) {
                Button { compressing = true } label: { Label(ToolText.text("compress"), systemImage: "doc.zipper") }
                    .buttonStyle(CompactActionButtonStyle())
                ShareLink(items: selectedURLs) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(CompactActionButtonStyle())
                Button(role: .destructive) {
                    pendingDeletion = selectedURLs; showDeleteConfirmation = true
                } label: { Label(ToolText.text("delete_files"), systemImage: "trash") }
                    .buttonStyle(CompactActionButtonStyle())
            }
        }
        .padding(12).background(.regularMaterial)
        .disabled(busy)
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
        reloadTask = Task {
            do {
                let result = try await Task.detached {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    return try FileManager.default.contentsOfDirectory(at: directory,
                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
                        .compactMap { url -> LocalFile? in
                            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                            guard values.isSymbolicLink != true else { return nil }
                            return LocalFile(url: url, directory: values.isDirectory == true, info: FilePresentation.inspect(url))
                        }.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
                }.value
                guard !Task.isCancelled else { return }
                hasLoaded = true
                files = result; selected.formIntersection(Set(result.map(\.id)))
            } catch { if !Task.isCancelled { hasLoaded = true; self.error = error.localizedDescription } }
        }
    }
    private func open(_ file: LocalFile) {
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
