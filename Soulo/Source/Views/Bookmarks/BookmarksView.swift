import SwiftUI
import SwiftData

struct BookmarksView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \BookmarkItem.dateAdded, order: .reverse) private var bookmarks: [BookmarkItem]

    @ObservedObject var searchVM: SearchViewModel

    var body: some View {
        NavigationStack {
            List {
                if bookmarks.isEmpty {
                    Section {
                        ContentUnavailableView(
                            LanguageManager.shared.localizedString("no_bookmarks"),
                            systemImage: "bookmark",
                            description: Text(LanguageManager.shared.localizedString("no_bookmarks_desc"))
                        )
                    }
                } else {
                    ForEach(bookmarks) { item in
                        Button {
                            searchVM.searchText = item.urlString
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                searchVM.performSearch(context: modelContext)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                BookmarkFaviconView(urlString: item.urlString, size: 28)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    Text(domainFrom(item.urlString))
                                        .font(.system(size: 12))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if let platform = item.platformName {
                                    Text(platform)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.1), in: Capsule())
                                }

                                Text(item.dateAdded, style: .date)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.quaternary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                BookmarkService.delete(item, context: modelContext)
                            } label: {
                                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LanguageManager.shared.localizedString("bookmarks"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
        }
    }

    private func domainFrom(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else { return urlString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
