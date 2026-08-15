import SwiftUI

enum LibrarySection: String, CaseIterable, Identifiable {
    case bookmarks
    case history
    case downloads

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .bookmarks: "bookmarks"
        case .history: "search_history"
        case .downloads: "downloads"
        }
    }

    var systemImage: String {
        switch self {
        case .bookmarks: "bookmark.fill"
        case .history: "clock.arrow.circlepath"
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
        NavigationStack {
            VStack(spacing: 0) {
                sectionSwitcher

                Divider()
                    .opacity(0.45)

                Group {
                    switch selectedSection {
                    case .bookmarks:
                        BookmarksContentView(searchVM: searchVM, onOpen: openSelection)
                    case .history:
                        SearchHistoryContentView(searchVM: searchVM, onOpen: openSelection)
                    case .downloads:
                        DownloadManagerContentView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle(LanguageManager.shared.localizedString("library"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) {
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
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

    private var sectionSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(LibrarySection.allCases) { section in
                let isSelected = selectedSection == section
                Button {
                    guard !isSelected else { return }
                    HapticsManager.selection()
                    withAnimation(.easeOut(duration: 0.18)) {
                        selectedSection = section
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: section.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(LanguageManager.shared.localizedString(section.titleKey))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color(uiColor: .systemBackground))
                                .shadow(color: .black.opacity(0.09), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            Color(uiColor: .secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
