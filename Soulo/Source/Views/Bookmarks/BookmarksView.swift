import SwiftUI
import CoreData

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
    @Environment(\.libraryPageIsActive) private var libraryPageIsActive
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: BookmarkService.sortDescriptors) private var bookmarks: FetchedResults<BookmarkRecord>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(key: "dateAdded", ascending: true)]) private var folders: FetchedResults<BookmarkFolderRecord>
    @ObservedObject var searchVM: SearchViewModel
    var onOpen: ((String) -> Void)? = nil
    var embeddedInLibrary = false
    var onReadingListOpen: (() -> Void)? = nil
    @State private var path: [UUID] = []
    @State private var importing = false
    @State private var showReadingList = false
    @State private var exporting = false
    @State private var busy = false
    @State private var document: BookmarkHTMLDocument?
    @State private var notice: String?
    @State private var editingFolder: BookmarkFolderRecord?
    @State private var folderName = ""
    @State private var folderPrompt = false
    @State private var removingFolder: BookmarkFolderRecord?
    @State private var moving: BookmarkMoveTarget?
    @State private var search = ""
    @State private var showOnlyFavorites = false
    @State private var renamingBookmark: BookmarkRecord?
    @State private var bookmarkName = ""
    @State private var selecting = false
    @State private var selectedIDs = Set<UUID>()
    @State private var confirmDeletion = false
    @EnvironmentObject private var tabManager: TabManager

    private var parentID: UUID? { path.last }
    private var visibleFolders: [BookmarkFolderRecord] {
        guard !showOnlyFavorites else { return [] }
        return folders.filter { search.isEmpty ? $0.parentID == parentID : $0.title.localizedCaseInsensitiveContains(search) }
    }
    private var visibleBookmarks: [BookmarkRecord] {
        return bookmarks.filter { item in
            guard !showOnlyFavorites || item.isFavorite else { return false }
            let matches = search.isEmpty ? (showOnlyFavorites || item.folderID == parentID) : item.title.localizedCaseInsensitiveContains(search) || item.urlString.localizedCaseInsensitiveContains(search)
            return matches
        }
    }

    var body: some View {
        readingListNavigation
        .mediaPlayerNavigation(enabled: !embeddedInLibrary)
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
            if #available(iOS 17.0, *) {
                Button(ToolText.text("done")) { saveFolder() }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                // iOS 16 can omit an initially disabled alert action and never
                // restore it as the text changes. saveFolder validates the name.
                Button(ToolText.text("done")) { saveFolder() }
            }
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
        .alert(ToolText.text("favorites_rename"), isPresented: Binding(
            get: { renamingBookmark != nil }, set: { if !$0 { renamingBookmark = nil } })) {
            TextField(renamingBookmark?.title ?? "", text: $bookmarkName)
            Button(ToolText.text("cancel"), role: .cancel) { renamingBookmark = nil }
            Button(ToolText.text("done")) { saveBookmarkName() }
        }
        .alert(ToolText.text("favorites_manage"), isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done"), role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .sheet(item: $moving) { target in
            BookmarkFolderPicker(folders: Array(folders), target: target) { destination in
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
        .onCompatibleChange(of: folders.map(\.id)) { _, ids in
            while let last = path.last, !ids.contains(last) { path.removeLast() }
        }
    }

    private var bookmarksList: some View {
        let shownFolders = visibleFolders, shownBookmarks = visibleBookmarks
        let counts = shownFolders.isEmpty ? [:] : Dictionary(grouping: bookmarks, by: \.folderID).mapValues(\.count)
        let childCounts = shownFolders.isEmpty ? [:] : Dictionary(grouping: folders, by: \.parentID).mapValues(\.count)
        return List {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(LanguageManager.shared.localizedString("search"), text: $search)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("favorites.search")
                    if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless) }
                    Button {
                        showOnlyFavorites.toggle()
                        HapticsManager.selection()
                    } label: {
                        Image(systemName: showOnlyFavorites ? "heart.fill" : "heart")
                            .foregroundStyle(showOnlyFavorites ? Color.themePrimary : Color.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(LanguageManager.shared.localizedString("ntp_quick_links"))
                    .accessibilityIdentifier("favorites.heart-filter")
                    .accessibilityAddTraits(showOnlyFavorites ? .isSelected : [])
                }
                .frame(minHeight: AppControlMetrics.minimumHitSize)
                .preservesKeyboardFocusOnTap()
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            }
            if !showOnlyFavorites, let id = parentID, let folder = folders.first(where: { $0.id == id }) {
                Section {
                    Button { path.removeLast(); search = "" } label: {
                        Label(folder.title, systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    .accessibilityLabel(ToolText.text("favorites_parent") + " · " + folder.title)
                    .accessibilityIdentifier("favorites.parent")
                }
            }
            if shownFolders.isEmpty && shownBookmarks.isEmpty {
                Section {
                    if showOnlyFavorites {
                        VStack(spacing: 14) {
                            Image(systemName: "heart")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(Color.themePrimary)
                                .frame(width: 80, height: 80)
                                .background(Color.themePrimary.opacity(0.08), in: Circle())
                            Text(LanguageManager.shared.localizedString("ntp_quick_links")).font(.headline)
                            Text(FeatureText.text("Mark bookmarks with a heart to show them here."))
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 32)
                        .accessibilityIdentifier("favorites.heart-empty")
                    } else {
                        IllustratedToolEmptyState(scene: .bookmarks,
                            title: LanguageManager.shared.localizedString("no_bookmarks"),
                            message: ToolText.text("favorites_empty"))
                    }
                }
            } else {
                Section {
                    ForEach(shownFolders) { folder in folderRow(folder, count: (counts[folder.id] ?? 0) + (childCounts[folder.id] ?? 0)) }
                    ForEach(shownBookmarks) { item in bookmarkRow(item) }
                        .onMove { indices, destination in
                            var ids = shownBookmarks.map(\.id)
                            ids.move(fromOffsets: indices, toOffset: destination)
                            do { try BookmarkService.reorder(ids, context: modelContext) }
                            catch { modelContext.rollback(); notice = error.localizedDescription }
                        }
                        .moveDisabled(selecting)
                }
            }
            Section {
                Text(ToolText.text("favorites_format")).font(.footnote).foregroundStyle(.secondary)
            }.listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .compatibleListSectionSpacing(20)
        .compatibleScrollTopMargin(24)

    }

    @ViewBuilder private var readingListNavigation: some View {
        if onReadingListOpen == nil {
            managedList.navigationDestination(isPresented: $showReadingList) { ReadingListView() }
        } else { managedList }
    }

    private var managedList: some View {
        bookmarksList
        .disabled(busy)
        .overlay {
            if busy {
                ProgressView(ToolText.text("favorites_processing"))
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .toolbar {
            if libraryPageIsActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { if let onReadingListOpen { onReadingListOpen() } else { showReadingList = true } } label: {
                            Label(FeatureText.text("Reading list"), systemImage: "text.book.closed")
                        }
                        Button { editingFolder = nil; folderName = ""; folderPrompt = true } label: {
                            Label(ToolText.text("favorites_new_folder"), systemImage: "folder.badge.plus")
                        }
                        Button { selecting.toggle(); if !selecting { selectedIDs.removeAll() } } label: {
                            Label(ToolText.text(selecting ? "done" : "select"), systemImage: "checkmark.circle")
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
        }
        .safeAreaInset(edge: .bottom) {
            if selecting {
                HStack {
                    Button(FeatureText.text("Select visible")) { selectedIDs.formUnion(visibleBookmarks.map(\.id)) }
                    Spacer()
                    Text("\(selectedIDs.count)").monospacedDigit()
                    Button(role: .destructive) { confirmDeletion = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                        .disabled(selectedIDs.isEmpty)
                    Button(ToolText.text("done")) { selecting = false; selectedIDs.removeAll() }
                }.padding(.horizontal).background(.regularMaterial)
            }
        }
        .confirmationDialog(LanguageManager.shared.localizedString("delete"), isPresented: $confirmDeletion, titleVisibility: .visible) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                do {
                    try modelContext.save()
                    for item in bookmarks where selectedIDs.contains(item.id) { modelContext.delete(item) }
                    try modelContext.save(); selectedIDs.removeAll()
                } catch { modelContext.rollback(); notice = error.localizedDescription }
            }
        } message: { Text(String(format: FeatureText.text("Delete %lld selected bookmarks?"), Int64(selectedIDs.count))) }
        .onCompatibleChange(of: selecting ? bookmarks.map(\.id) : []) { _, ids in selectedIDs.formIntersection(Set(ids)) }

    }

    private func folderRow(_ folder: BookmarkFolderRecord, count: Int) -> some View {
        Button { path.append(folder.id); search = "" } label: {
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
        .background(LibrarySwipeActionsRegion())
    }

    private func bookmarkRow(_ item: BookmarkRecord) -> some View {
        Button {
            if selecting {
                if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                return
            }
            if let onOpen { onOpen(item.urlString); return }
            searchVM.searchText = item.urlString
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { searchVM.openLibrarySelection(item.urlString, tabManager: tabManager, context: modelContext) }
        } label: {
            HStack(spacing: 12) {
                if selecting { Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.themePrimary) }
                BookmarkFaviconView(urlString: item.urlString, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    HStack(spacing: 4) {
                        if item.isFavorite {
                            Image(systemName: "heart.fill").font(.system(size: 9))
                                .foregroundStyle(Color.themePrimary)
                                .accessibilityLabel(LanguageManager.shared.localizedString("ntp_quick_links"))
                        }
                        Text(URL(string: item.urlString)?.host ?? item.urlString)
                            .font(.system(size: 12)).foregroundStyle(.tertiary).lineLimit(1)
                    }
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
        .accessibilityIdentifier("favorites.bookmark.\(item.id)")
        .contextMenu {
            Button { toggleFavorite(item) } label: {
                Label(FeatureText.text(item.isFavorite ? "Remove from Quick Links" : "Add to Quick Links"), systemImage: item.isFavorite ? "heart.slash" : "heart")
            }
            Button { renamingBookmark = item; bookmarkName = item.title } label: {
                Label(ToolText.text("favorites_rename"), systemImage: "pencil")
            }
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
        .background(LibrarySwipeActionsRegion())
    }

    private func toggleFavorite(_ item: BookmarkRecord) {
        item.isFavorite.toggle()
        do { try modelContext.save(); HapticsManager.selection() }
        catch { modelContext.rollback(); notice = error.localizedDescription }
    }

    private func saveBookmarkName() {
        guard let item = renamingBookmark, !item.isDeleted else { renamingBookmark = nil; return }
        let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        item.title = name
        do { try modelContext.save() }
        catch { modelContext.rollback(); notice = error.localizedDescription }
        renamingBookmark = nil
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
            else { modelContext.insert(BookmarkFolderRecord(title: name, parentID: parentID)) }
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
    case bookmark(BookmarkRecord), folder(BookmarkFolderRecord)
    var id: UUID { switch self { case .bookmark(let item): item.id; case .folder(let folder): folder.id } }
    var parentID: UUID? { switch self { case .bookmark(let item): item.folderID; case .folder(let folder): folder.parentID } }
}

private struct BookmarkFolderPicker: View {
    @Environment(\.dismiss) private var dismiss
    let folders: [BookmarkFolderRecord]
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
