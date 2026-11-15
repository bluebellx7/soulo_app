import SwiftUI
import CoreData
import UIKit

/// Saved pages are shared with the library; favorite marks choose quick links.
struct NewTabPageView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @State private var sharingBookmark: BookmarkRecord?
    @State private var renamingBookmark: BookmarkRecord?
    @State private var bookmarkName = ""
    @State private var deletingBookmark: BookmarkRecord?
    @State private var notice: String?
    var tabManager: TabManager?
    var onSearch: ((String, PlatformRegion, UUID?) -> Void)? = nil
    var onNavigate: (URL) -> Void

    // Keep ownership without subscribing the entire quick-link page to typing.
    @State private var input = SearchInputState()
    @State private var selectedSearchRegion: PlatformRegion?
    @State private var selectedSearchGroupID: UUID?
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var wallpaperManager = WallpaperManager.shared
    @ObservedObject private var platformStore = PlatformDataStore.shared
    @FetchRequest(sortDescriptors: BookmarkService.sortDescriptors) private var bookmarks: FetchedResults<BookmarkRecord>

    private var primaryTextColor: Color {
        wallpaperManager.isCurrentWallpaperLight ? Color(hex: "2E2A47") : .white
    }

    private var secondaryTextColor: Color {
        primaryTextColor.opacity(0.62)
    }

    private var cardFillColor: Color {
        wallpaperManager.isCurrentWallpaperLight
            ? Color.white.opacity(0.68)
            : Color.white.opacity(0.1)
    }

    /// Detect the best region based on the current language.
    private var detectedRegion: PlatformRegion {
        let lang = LanguageManager.shared.currentLanguage
        switch lang {
        case "zh-Hans", "zh-Hant": return .china
        case "ja":                 return .japan
        case "ru":                 return .russia
        case "ko":                 return .korea
        default:                   return .international
        }
    }

    private var searchPlatforms: [SearchPlatform] {
        if let selectedSearchGroupID,
           let group = platformStore.customGroups.first(where: { $0.id == selectedSearchGroupID }) {
            return platformStore.visiblePlatforms(forGroup: group).filter { $0.interactionType == .urlSearch }
        }
        return platformStore.visiblePlatforms(for: selectedSearchRegion ?? detectedRegion)
            .filter { $0.interactionType == .urlSearch }
    }

    private var quickLinkBookmarks: [BookmarkRecord] {
        BookmarkService.quickLinks(from: Array(bookmarks))
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                SearchLandingLayout(viewportHeight: max(0, geometry.size.height - 32), headingGap: 24, detailsGap: 20, searchOffsetRatio: -0.65) {
                    VStack(spacing: 10) {
                        Image(systemName: "globe.desk")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(LinearGradient(colors: [Color(hex: "6366F1"), Color(hex: "A855F7")], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .accessibilityHidden(true)
                        Text(LanguageManager.shared.localizedString("tab_new_tab"))
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(primaryTextColor)
                            .accessibilityAddTraits(.isHeader)
                    }
                    searchBar.accessibilityElement(children: .contain)
                        .accessibilityIdentifier("new-tab.search.field")
                        .padding(.horizontal, 28)
                    VStack(spacing: 24) {
                        quickLinksSection
                        if let tm = tabManager, !tm.recentlyClosed.isEmpty { recentlyClosedSection(tm) }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 32)
                }
                .frame(maxWidth: 656).frame(maxWidth: .infinity).padding(.vertical, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("new-tab.search.area")
        }
        .onAppear {
            wallpaperManager.ensureLoaded()
            selectedSearchRegion = UserDefaults.standard.string(forKey: "last_selected_region").flatMap(PlatformRegion.init(rawValue:))
            selectedSearchGroupID = UserDefaults.standard.string(forKey: "last_selected_group_id").flatMap(UUID.init(uuidString:))
        }
        .sheet(item: $sharingBookmark) { item in
            if let url = item.url { QuickLinkShareSheet(url: url) }
        }
        .alert(ToolText.text("favorites_rename"), isPresented: Binding(get: { renamingBookmark != nil }, set: { if !$0 { renamingBookmark = nil } })) {
            TextField(renamingBookmark?.title ?? "", text: $bookmarkName)
            Button(ToolText.text("cancel"), role: .cancel) { renamingBookmark = nil }
            Button(ToolText.text("done")) {
                if let item = renamingBookmark {
                    let name = bookmarkName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { item.title = name; saveBookmarkChanges() }
                }
                renamingBookmark = nil
            }
        }
        .confirmationDialog(LanguageManager.shared.localizedString("delete"), isPresented: Binding(get: { deletingBookmark != nil }, set: { if !$0 { deletingBookmark = nil } }), titleVisibility: .visible) {
            Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                if let item = deletingBookmark { BookmarkService.delete(item, context: modelContext) }
                deletingBookmark = nil
            }
        }
        .alert(ToolText.text("favorites_manage"), isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("done"), role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func saveBookmarkChanges() {
        do { try modelContext.save() }
        catch { modelContext.rollback(); notice = error.localizedDescription }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        SearchBarView(
            input: input,
            respondsToHomeFocus: false,
            onSubmit: navigateToInput,
            selectedRegion: selectedSearchRegion ?? detectedRegion,
            selectedGroupID: selectedSearchGroupID,
            onRegionSelect: { region in
                selectedSearchRegion = region
                selectedSearchGroupID = nil
                UserDefaults.standard.set(region.rawValue, forKey: "last_selected_region")
                UserDefaults.standard.set("", forKey: "last_selected_group_id")
            },
            onGroupSelect: { group in
                selectedSearchGroupID = group.id
                UserDefaults.standard.set(group.id.uuidString, forKey: "last_selected_group_id")
                UserDefaults.standard.set("", forKey: "last_selected_region")
            }
        )
    }

    // MARK: - Saved Quick Links

    private var quickLinksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if quickLinkBookmarks.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "heart").font(.system(size: 22)).foregroundStyle(secondaryTextColor)
                    Text(FeatureText.text("Mark bookmarks with a heart to show them here."))
                        .font(.subheadline).foregroundStyle(secondaryTextColor).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(cardFillColor, in: RoundedRectangle(cornerRadius: 18))
            }
            BookmarkQuickLinkGrid(items: quickLinkBookmarks, foreground: primaryTextColor,
                onOpen: { if let url = $0.url { HapticsManager.light(); onNavigate(url) } },
                onOpenNewTab: { if let url = $0.url { tabManager?.createTab(url: url) } },
                onRename: { renamingBookmark = $0; bookmarkName = $0.title },
                onFavorite: { $0.isFavorite.toggle(); saveBookmarkChanges() },
                onShare: { sharingBookmark = $0 }, onDelete: { deletingBookmark = $0 },
                onReorder: { ids in
                    do { try BookmarkService.reorder(ids, context: modelContext) }
                    catch { modelContext.rollback(); notice = error.localizedDescription }
                })
                .frame(height: CGFloat((quickLinkBookmarks.count + 3) / 4) * 64 + (quickLinkBookmarks.count > 4 ? 16 : 0))

        }
    }

    // MARK: - Recently Closed

    private func recentlyClosedSection(_ tm: TabManager) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    LanguageManager.shared.localizedString("tab_recently_closed"),
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(secondaryTextColor)
                .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, 4)

            ForEach(tm.recentlyClosed.prefix(5)) { closed in
                Button {
                    HapticsManager.selection()
                    tm.restoreClosedTab(closed)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "globe")
                            .font(.system(size: 14))
                            .foregroundStyle(secondaryTextColor)
                            .frame(width: 28, height: 28)
                            .background(
                                Color(UIColor.tertiarySystemFill),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(closed.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(primaryTextColor)
                                .lineLimit(1)
                            if let host = closed.url?.host {
                                Text(host)
                                    .font(.system(size: 11))
                                    .foregroundStyle(secondaryTextColor.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: "6366F1"))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(cardFillColor)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(closed.title)
                .accessibilityValue(closed.url?.host ?? "")
                .accessibilityHint(
                    LanguageManager.shared.localizedString("accessibility_restore_tab_hint")
                )
            }
        }
    }

    // MARK: - Navigation

    private func navigateToInput() {
        guard !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let region = selectedSearchRegion ?? detectedRegion
        if let onSearch {
            onSearch(input.text, region, selectedSearchGroupID)
            return
        }
        let scope = selectedSearchGroupID.map(SearchGroupScope.custom) ?? .region(region)
        guard let url = BrowserNavigationResolver.resolve(
            input.text,
            preferredSearchPlatform: searchPlatforms.first ?? GroupDefaultSearchService.shared.platform(for: scope, region: region)
        ) else { return }
        onNavigate(url)
    }
}

/// UIKit owns the whole drag session, including context-menu previews and
/// cancellation. Saving on a completed drop keeps canceled drags out of Core Data.
private struct BookmarkQuickLinkGrid: UIViewControllerRepresentable {
    var items: [BookmarkRecord]
    var foreground: Color
    var onOpen: (BookmarkRecord) -> Void
    var onOpenNewTab: (BookmarkRecord) -> Void
    var onRename: (BookmarkRecord) -> Void
    var onFavorite: (BookmarkRecord) -> Void
    var onShare: (BookmarkRecord) -> Void
    var onDelete: (BookmarkRecord) -> Void
    var onReorder: ([UUID]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UICollectionViewController {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 16; layout.minimumInteritemSpacing = 12
        let controller = UICollectionViewController(collectionViewLayout: layout)
        // Drag/drop delegates own reordering. The controller's separate legacy
        // long-press recognizer must not compete with dragging or the menu.
        controller.installsStandardGestureForInteractiveMovement = false
        controller.view.backgroundColor = .clear
        let view: UICollectionView = controller.collectionView
        view.contentInsetAdjustmentBehavior = .never
        view.backgroundColor = .clear; view.isScrollEnabled = false
        view.dragInteractionEnabled = true
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "bookmark")
        view.dataSource = context.coordinator; view.delegate = context.coordinator
        view.dragDelegate = context.coordinator; view.dropDelegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICollectionViewController, context: Context) {
        let view: UICollectionView = controller.collectionView
        let oldColor = context.coordinator.owner.foreground
        context.coordinator.owner = self
        let keys = items.map { "\($0.id):\($0.title):\($0.urlString):\($0.isFavorite)" }
        guard keys != context.coordinator.renderedKeys || oldColor != foreground else { return }
        context.coordinator.items = items
        context.coordinator.renderedKeys = keys
        view.reloadData(); view.collectionViewLayout.invalidateLayout()
    }

    @MainActor final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
        UICollectionViewDragDelegate, UICollectionViewDropDelegate {
        var owner: BookmarkQuickLinkGrid
        var items: [BookmarkRecord]
        var renderedKeys: [String] = []
        init(_ owner: BookmarkQuickLinkGrid) { self.owner = owner; items = owner.items }

        func collectionView(_ view: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ view: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            let cell = view.dequeueReusableCell(withReuseIdentifier: "bookmark", for: indexPath)
            let item = items[indexPath.item]
            let title = item.title.count > 8 ? String(item.title.prefix(8)) + "…" : item.title
            let urlString = item.urlString, foreground = owner.foreground
            cell.contentConfiguration = UIHostingConfiguration {
                VStack(spacing: 8) {
                    BookmarkFaviconView(urlString: urlString, size: 28).frame(width: 40, height: 40)
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(foreground).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }.margins(.all, 0)
            cell.backgroundColor = .clear
            cell.isAccessibilityElement = true
            cell.accessibilityTraits = .button
            cell.accessibilityLabel = item.title
            cell.accessibilityIdentifier = "new-tab.quick-link.\(item.id)"
            return cell
        }
        func collectionView(_ view: UICollectionView, layout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
            CGSize(width: max(1, floor((view.bounds.width - 36) / 4)), height: 64)
        }
        func collectionView(_ view: UICollectionView, didSelectItemAt indexPath: IndexPath) {
            guard items.indices.contains(indexPath.item) else { return }
            owner.onOpen(items[indexPath.item])
        }
        func collectionView(_ view: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
            #if SOULO_ACCEPTANCE
            NSLog("[SouloBookmarkDrag] menu count:%d", indexPaths.count)
            #endif
            guard let index = indexPaths.first?.item, items.indices.contains(index) else { return nil }
            let item = items[index]
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self, !item.isDeleted else { return nil }
                return UIMenu(children: [
                    UIAction(title: LanguageManager.shared.localizedString("tab_open_new"), image: UIImage(systemName: "plus.square")) { [weak self] _ in self?.owner.onOpenNewTab(item) },
                    UIAction(title: ToolText.text("favorites_rename"), image: UIImage(systemName: "pencil")) { [weak self] _ in self?.owner.onRename(item) },
                    UIAction(title: FeatureText.text(item.isFavorite ? "Remove from Quick Links" : "Add to Quick Links"), image: UIImage(systemName: item.isFavorite ? "heart.slash" : "heart")) { [weak self] _ in self?.owner.onFavorite(item) },
                    UIAction(title: ToolText.text("share"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.owner.onShare(item) },
                    UIAction(title: LanguageManager.shared.localizedString("delete"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.owner.onDelete(item) }
                ])
            }
        }
        func collectionView(_ view: UICollectionView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
            #if SOULO_ACCEPTANCE
            NSLog("[SouloBookmarkDrag] begin index:%d", indexPath.item)
            #endif
            guard items.indices.contains(indexPath.item) else { return [] }
            let item = items[indexPath.item]
            let drag = UIDragItem(itemProvider: NSItemProvider(object: item.id.uuidString as NSString))
            drag.localObject = item.id; session.localContext = self
            return [drag]
        }
        func collectionView(_ view: UICollectionView, dragSessionIsRestrictedToDraggingApplication session: UIDragSession) -> Bool { true }
        #if SOULO_ACCEPTANCE
        func collectionView(_ view: UICollectionView, dragSessionWillBegin session: UIDragSession) { NSLog("[SouloBookmarkDrag] lifted") }
        func collectionView(_ view: UICollectionView, dragSessionDidEnd session: UIDragSession) { NSLog("[SouloBookmarkDrag] ended") }
        #endif
        func collectionView(_ view: UICollectionView, canHandle session: UIDropSession) -> Bool {
            (session.localDragSession?.localContext as? Coordinator) === self
        }
        func collectionView(_ view: UICollectionView, dropSessionDidUpdate session: UIDropSession,
                            withDestinationIndexPath destination: IndexPath?) -> UICollectionViewDropProposal {
            UICollectionViewDropProposal(operation: collectionView(view, canHandle: session) ? .move : .forbidden, intent: .insertAtDestinationIndexPath)
        }
        func collectionView(_ view: UICollectionView, performDropWith drop: UICollectionViewDropCoordinator) {
            #if SOULO_ACCEPTANCE
            NSLog("[SouloBookmarkDrag] drop count:%d target:%d own:%d", drop.items.count, drop.destinationIndexPath?.item ?? -1, collectionView(view, canHandle: drop.session))
            #endif
            guard collectionView(view, canHandle: drop.session), let dragged = drop.items.first,
                  let id = dragged.dragItem.localObject as? UUID, let from = items.firstIndex(where: { $0.id == id }),
                  !items.isEmpty else { return }
            let to = min(items.count - 1, max(0, drop.destinationIndexPath?.item ?? items.count - 1))
            let destination = IndexPath(item: to, section: 0)
            if from != to {
                view.performBatchUpdates {
                    let item = items.remove(at: from); items.insert(item, at: to)
                    renderedKeys = items.map { "\($0.id):\($0.title):\($0.urlString):\($0.isFavorite)" }
                    view.moveItem(at: IndexPath(item: from, section: 0), to: destination)
                }
                owner.onReorder(items.map(\.id))
            }
            drop.drop(dragged.dragItem, toItemAt: destination)
        }
    }
}

private struct QuickLinkShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
