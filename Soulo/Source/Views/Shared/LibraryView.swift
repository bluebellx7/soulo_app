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
            LibrarySectionSwitcher(selectedSection: $selectedSection)

            Group {
                switch selectedSection {
                case .bookmarks:
                    BookmarksContentView(searchVM: searchVM, onOpen: openSelection)
                case .history:
                    SearchHistoryContentView(searchVM: searchVM, onOpen: openSelection)
                case .books:
                    BookshelfView()
                case .downloads:
                    DownloadManagerContentView(embeddedInLibrary: true)
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
        .onReceive(NotificationCenter.default.publisher(for: .openSouloBookshelf)) { _ in
            selectedSection = .books
        }
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

}

struct LibrarySectionSwitcher: View {
    @Binding var selectedSection: LibrarySection
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 11

    var body: some View {
        ViewThatFits(in: .horizontal) {
            sectionButtons
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    sectionButtons.fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityIdentifier("library.tabs")
                .fixedSize(horizontal: false, vertical: true)
                .onAppear { proxy.scrollTo(selectedSection, anchor: .center) }
                .onChange(of: selectedSection) { _, section in
                    withAnimation { proxy.scrollTo(section, anchor: .center) }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
        .background(Color(uiColor: .systemBackground))
    }

    private var sectionButtons: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                let selected = selectedSection == section
                let titleKey = section == .history ? "library_history_tab" : section == .files ? "library_files_tab" : section == .books ? "library_books_tab" : section.titleKey
                let title = LanguageManager.shared.localizedString(titleKey)
                Button {
                    guard !selected else { return }
                    HapticsManager.selection()
                    withAnimation(.easeOut(duration: 0.18)) { selectedSection = section }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .frame(height: 20)
                        Text(title)
                            .font(.system(size: captionSize, weight: selected ? .semibold : .medium))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    .foregroundStyle(selected ? Color.themePrimary : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(minWidth: 48, minHeight: 50)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.themePrimary.opacity(0.1))
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(section == .history ? LanguageManager.shared.localizedString("search_history") : title)
                .accessibilityIdentifier("library.section.\(section.rawValue)")
                .id(section)
                .accessibilityAddTraits(selected ? .isSelected : [])
                if section != .books { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
