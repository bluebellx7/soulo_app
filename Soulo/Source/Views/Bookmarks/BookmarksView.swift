import SwiftUI
import SwiftData

struct BookmarksView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var searchVM: SearchViewModel

    var body: some View {
        NavigationStack {
            BookmarksContentView(searchVM: searchVM)
                .navigationTitle(LanguageManager.shared.localizedString("bookmarks"))
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                    }
                }
        }
    }
}

struct BookmarksContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookmarkItem.dateAdded, order: .reverse) private var bookmarks: [BookmarkItem]
    @Query(sort: \BookmarkFolder.dateAdded) private var folders: [BookmarkFolder]
    @ObservedObject var searchVM: SearchViewModel
    var onOpen: ((String) -> Void)? = nil
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var exporting = false
    @State private var busy = false
    @State private var document: BookmarkHTMLDocument?
    @State private var notice: String?
    @State private var editingFolder: BookmarkFolder?
    @State private var folderName = ""
    @State private var folderPrompt = false
    @State private var removingFolder: BookmarkFolder?
    @State private var moving: BookmarkMoveTarget?

    private var parentID: UUID? { path.last }
    private var visibleFolders: [BookmarkFolder] { folders.filter { $0.parentID == parentID } }
    private var visibleBookmarks: [BookmarkItem] { bookmarks.filter { $0.folderID == parentID } }

    var body: some View {
        let counts = Dictionary(grouping: bookmarks, by: \.folderID).mapValues(\.count)
        let childCounts = Dictionary(grouping: folders, by: \.parentID).mapValues(\.count)
        List {
            if let id = parentID, let folder = folders.first(where: { $0.id == id }) {
                Section {
                    Button { path.removeLast() } label: {
                        Label(folder.title, systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .accessibilityLabel(ToolText.text("favorites_parent") + " · " + folder.title)
                    .accessibilityIdentifier("favorites.parent")
                }
            }
            if visibleFolders.isEmpty && visibleBookmarks.isEmpty {
                Section {
                    IllustratedToolEmptyState(scene: .books,
                        title: LanguageManager.shared.localizedString("no_bookmarks"),
                        message: ToolText.text("favorites_empty"))
                }
            } else {
                Section {
                    ForEach(visibleFolders) { folder in folderRow(folder, count: (counts[folder.id] ?? 0) + (childCounts[folder.id] ?? 0)) }
                    ForEach(visibleBookmarks) { item in bookmarkRow(item) }
                }
            }
            Section {
                Text(ToolText.text("favorites_format")).font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .disabled(busy)
        .overlay {
            if busy {
                ProgressView(ToolText.text("favorites_processing"))
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { editingFolder = nil; folderName = ""; folderPrompt = true } label: {
                        Label(ToolText.text("favorites_new_folder"), systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button { importing = true } label: {
                        Label(ToolText.text("favorites_import"), systemImage: "square.and.arrow.down")
                    }
                    Button { exportBookmarks() } label: {
                        Label(ToolText.text("favorites_export"), systemImage: "square.and.arrow.up")
                    }.disabled(bookmarks.isEmpty && folders.isEmpty)
                } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
                .tint(.primary).disabled(busy)
                .accessibilityLabel(ToolText.text("favorites_manage"))
                .accessibilityIdentifier("favorites.manage")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.html], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { importBookmarks(url) }
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting, document: document, contentType: .html,
                      defaultFilename: "Soulo-Bookmarks") { result in
            switch result {
            case .success: notice = ToolText.text("favorites_exported")
            case .failure(let error): notice = error.localizedDescription
            }
        }
        .alert(ToolText.text(editingFolder == nil ? "favorites_new_folder" : "favorites_rename"), isPresented: $folderPrompt) {
            TextField(ToolText.text("favorites_folder_name"), text: $folderName)
            Button(ToolText.text("cancel"), role: .cancel) { }
            Button(ToolText.text("done")) { saveFolder() }
                .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(ToolText.text("favorites_remove_folder"), isPresented: Binding(
            get: { removingFolder != nil }, set: { if !$0 { removingFolder = nil } })) {
            Button(ToolText.text("cancel"), role: .cancel) { removingFolder = nil }
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                if let folder = removingFolder {
                    do { try BookmarkLibraryService.removeFolder(folder, context: modelContext) }
                    catch { notice = error.localizedDescription }
                }
                removingFolder = nil
            }
        } message: { Text(ToolText.text("favorites_remove_note")) }
        .alert(ToolText.text("favorites_manage"), isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done"), role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(item: $moving) { target in
            BookmarkFolderPicker(folders: folders, target: target) { destination in
                do {
                    try modelContext.save()
                    switch target {
                    case .bookmark(let item): item.folderID = destination
                    case .folder(let folder): folder.parentID = destination
                    }
                    try modelContext.save()
                } catch { modelContext.rollback(); notice = error.localizedDescription }
                moving = nil
            }
        }
        .onChange(of: folders.map(\.id)) { _, ids in
            while let last = path.last, !ids.contains(last) { path.removeLast() }
        }
    }

    private func folderRow(_ folder: BookmarkFolder, count: Int) -> some View {
        Button { path.append(folder.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Color.themePrimary).frame(width: 28)
                Text(folder.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { editingFolder = folder; folderName = folder.title; folderPrompt = true } label: {
                Label(ToolText.text("favorites_rename"), systemImage: "pencil")
            }
            Button { moving = .folder(folder) } label: { Label(ToolText.text("favorites_move"), systemImage: "folder") }
            Button(role: .destructive) { removingFolder = folder } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { removingFolder = folder } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }.tint(.red)
            Button { editingFolder = folder; folderName = folder.title; folderPrompt = true } label: {
                Label(ToolText.text("favorites_rename"), systemImage: "pencil")
            }.tint(.gray)
        }
    }

    private func bookmarkRow(_ item: BookmarkItem) -> some View {
        Button {
            if let onOpen { onOpen(item.urlString); return }
            searchVM.searchText = item.urlString
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchVM.performSearch(context: modelContext) }
        } label: {
            HStack(spacing: 12) {
                BookmarkFaviconView(urlString: item.urlString, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(URL(string: item.urlString)?.host ?? item.urlString)
                        .font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer()
                if let platform = item.platformName {
                    Text(platform).font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                Text(item.dateAdded, style: .date).font(.system(size: 11)).foregroundStyle(.quaternary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { moving = .bookmark(item) } label: { Label(ToolText.text("favorites_move"), systemImage: "folder") }
            ShareLink(item: item.urlString) { Label(ToolText.text("share"), systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { BookmarkService.delete(item, context: modelContext) } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { BookmarkService.delete(item, context: modelContext) } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }.tint(.red)
            Button { moving = .bookmark(item) } label: { Label(ToolText.text("favorites_move"), systemImage: "folder") }
                .tint(.gray)
        }
    }

    private func saveFolder() {
        let name = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let parent = editingFolder?.parentID ?? parentID
        guard !folders.contains(where: { $0.parentID == parent && $0.title == name && $0.id != editingFolder?.id }) else {
            notice = ToolText.text("favorites_name_exists"); return
        }
        do {
            try modelContext.save()
            if let folder = editingFolder { folder.title = name }
            else { modelContext.insert(BookmarkFolder(title: name, parentID: parentID)) }
            try modelContext.save()
        } catch { modelContext.rollback(); notice = error.localizedDescription }
        editingFolder = nil
    }

    private func importBookmarks(_ url: URL) {
        busy = true
        let destination = parentID
        Task { @MainActor in
            defer { busy = false }
            do {
                let archive = try await Task.detached(priority: .userInitiated) { try BookmarkHTML.read(url) }.value
                let result = try BookmarkLibraryService.importArchive(archive, into: destination, context: modelContext)
                notice = String(format: ToolText.text("favorites_import_result"), result.added, result.folders, result.duplicates, result.skipped)
            } catch { notice = error.localizedDescription }
        }
    }

    private func exportBookmarks() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let archive = try BookmarkLibraryService.archive(context: modelContext)
                let data = await Task.detached(priority: .userInitiated) { BookmarkHTML.encode(archive) }.value
                document = BookmarkHTMLDocument(data: data)
                exporting = true
            } catch { notice = error.localizedDescription }
        }
    }
}

private enum BookmarkMoveTarget: Identifiable {
    case bookmark(BookmarkItem), folder(BookmarkFolder)
    var id: UUID { switch self { case .bookmark(let item): item.id; case .folder(let folder): folder.id } }
    var parentID: UUID? { switch self { case .bookmark(let item): item.folderID; case .folder(let folder): folder.parentID } }
}

private struct BookmarkFolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [BookmarkFolder]
    let target: BookmarkMoveTarget
    let onSelect: (UUID?) -> Void

    private var choices: [(id: UUID, title: String, depth: Int)] {
        let grouped = Dictionary(grouping: folders, by: \.parentID)
        var result: [(UUID, String, Int)] = []
        var seen: Set<UUID> = []
        var pending = (grouped[nil] ?? []).reversed().map { ($0, 0) }
        while let (folder, depth) = pending.popLast() {
            guard seen.insert(folder.id).inserted else { continue }
            // Exclude the moved folder and its descendants to prevent cycles.
            if case .folder(let source) = target, source.id == folder.id { continue }
            result.append((folder.id, folder.title, depth))
            pending.append(contentsOf: (grouped[folder.id] ?? []).reversed().map { ($0, depth + 1) })
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                destination(nil, title: LanguageManager.shared.localizedString("bookmarks"), depth: 0)
                ForEach(choices, id: \.id) { choice in destination(choice.id, title: choice.title, depth: choice.depth + 1) }
            }
            .navigationTitle(ToolText.text("favorites_move"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("cancel")) { dismiss() } } }
        }
    }
    private func destination(_ id: UUID?, title: String, depth: Int) -> some View {
        Button { onSelect(id) } label: {
            HStack {
                Label(title, systemImage: id == nil ? "bookmark" : "folder").foregroundStyle(.primary).lineLimit(2)
                Spacer()
                if target.parentID == id { Image(systemName: "checkmark").foregroundStyle(Color.themePrimary) }
            }.padding(.leading, CGFloat(min(depth, 6)) * 12)
        }.disabled(target.parentID == id)
    }
}
