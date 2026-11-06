import SwiftUI

struct LibraryQueryControls: View {
    @Binding var search: String
    @Binding var kind: LibraryFileFilter
    @Binding var sort: LibraryListSort
    var status: Binding<DownloadStatusFilter>?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(LanguageManager.shared.localizedString("search"), text: $search)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("library.search")
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(LanguageManager.shared.localizedString("accessibility_clear_search"))
            }
            Menu {
                if let status {
                    Menu(FeatureText.text("Status")) {
                        Picker(FeatureText.text("Status"), selection: status) {
                            ForEach(DownloadStatusFilter.allCases) { Text($0.title).tag($0) }
                        }
                    }
                }
                Menu(FeatureText.text("File type")) {
                    Picker(FeatureText.text("File type"), selection: $kind) {
                        ForEach(LibraryFileFilter.allCases) { Text($0.title).tag($0) }
                    }
                }
                Menu(FeatureText.text("Sort")) {
                    Picker(FeatureText.text("Sort"), selection: $sort) {
                        ForEach(LibraryListSort.allCases) { Text($0.title).tag($0) }
                    }
                }
            } label: {
                Image(systemName: kind != .all || status?.wrappedValue != nil && status?.wrappedValue != .all
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: AppControlMetrics.iconSize))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(FeatureText.text("Filter and sort"))
            .accessibilityIdentifier("library.filter-sort")
        }
    }
}

extension LibraryFileFilter {
    var title: String {
        FeatureText.text([.all: "All types", .folders: "Folders", .images: "Images", .videos: "Videos",
                          .audio: "Audio", .documents: "Documents", .archives: "Archives", .other: "Other"][self]!)
    }
}
extension LibraryListSort {
    var title: String {
        FeatureText.text([.newest: "Newest first", .oldest: "Oldest first", .nameAscending: "Name A–Z",
                          .nameDescending: "Name Z–A", .sizeLargest: "Largest first", .sizeSmallest: "Smallest first"][self]!)
    }
}
extension DownloadStatusFilter {
    var title: String {
        FeatureText.text([.all: "All statuses", .active: "Active", .paused: "Paused", .completed: "Completed",
                          .failed: "Failed", .canceled: "Canceled"][self]!)
    }
}
