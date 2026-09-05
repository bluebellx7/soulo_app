import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks
    case history
    case downloads
    case files
    case books

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .bookmarks: "bookmarks"
        case .history: "search_history"
        case .files: "files"
        case .books: "bookshelf"
        case .downloads: "downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmarks: "bookmark.fill"
        case .history: "clock.arrow.circlepath"
        case .files: "folder.fill"
        case .books: "books.vertical.fill"
        case .downloads: "arrow.down.circle.fill"
        }
    }
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @ObservedObject var searchVM: SearchViewModel
    @State private var selectedSection: LibrarySection
    private let onOpen: ((String) -> Void)?

    init(
        initialSection: LibrarySection = .bookmarks,
        searchVM: SearchViewModel,
        onOpen: ((String) -> Void)? = nil
    ) {
        self.searchVM = searchVM
        self.onOpen = onOpen
        _selectedSection = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionSwitcher

            Group {
                switch selectedSection {
                case .bookmarks:
                    BookmarksContentView(searchVM: searchVM, onOpen: openSelection)
                case .history:
                    SearchHistoryContentView(searchVM: searchVM, onOpen: openSelection)
                case .books:
                    BookshelfView()
                case .downloads:
                    DownloadManagerContentView(onOpenFiles: { selectedSection = .files })
                case .files:
                    LibraryFilesView(embeddedInLibrary: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(LanguageManager.shared.localizedString("library"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .mediaPlayerNavigation()
    }

    private func openSelection(_ value: String) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if let onOpen {
                onOpen(value)
            } else {
                searchVM.searchText = value
                searchVM.performSearch(context: modelContext)
            }
        }
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                let selected = selectedSection == section
                let title = [.books, .files].contains(section)
                    ? ToolText.text(section.titleKey) : LanguageManager.shared.localizedString(section.titleKey)
                Button {
                    guard !selected else { return }
                    HapticsManager.selection()
                    withAnimation(.easeOut(duration: 0.18)) { selectedSection = section }
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .frame(height: 20)
                        Text(title)
                            .font(.system(size: 11, weight: selected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(selected ? Color.themePrimary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.themePrimary.opacity(0.1))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(Color(uiColor: .systemBackground))
    }
}
