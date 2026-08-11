import SwiftUI
import SwiftData

struct SearchHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SearchHistoryItem.timestamp, order: .reverse) private var allHistory: [SearchHistoryItem]

    @ObservedObject var searchVM: SearchViewModel
    @State private var filterText = ""
    @State private var showClearAlert = false

    private var visibleHistory: [SearchHistoryItem] {
        allHistory.filter { SearchHistoryService.isVisibleInHistory($0) }
    }

    private var deduped: [SearchHistoryItem] {
        var seen = Set<String>()
        var result: [SearchHistoryItem] = []
        let source = filterText.trimmingCharacters(in: .whitespaces).isEmpty
            ? visibleHistory
            : visibleHistory.filter {
                $0.keyword.localizedCaseInsensitiveContains(filterText)
                    || ($0.visitedURLString?.localizedCaseInsensitiveContains(filterText) == true)
            }
        for item in source {
            let key = item.visitedURLString.map { "url:\($0.lowercased())" }
                ?? "search:\(item.keyword.lowercased())"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(item)
            }
        }
        return result
    }

    private var grouped: [(title: String, items: [SearchHistoryItem])] {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let yesterdayStart = cal.date(byAdding: .day, value: -1, to: todayStart)!

        var today: [SearchHistoryItem] = []
        var yesterday: [SearchHistoryItem] = []
        var earlier: [SearchHistoryItem] = []

        for item in deduped {
            let d = cal.startOfDay(for: item.timestamp)
            if d >= todayStart { today.append(item) }
            else if d >= yesterdayStart { yesterday.append(item) }
            else { earlier.append(item) }
        }

        var result: [(String, [SearchHistoryItem])] = []
        if !today.isEmpty { result.append((LanguageManager.shared.localizedString("today"), today)) }
        if !yesterday.isEmpty { result.append((LanguageManager.shared.localizedString("yesterday"), yesterday)) }
        if !earlier.isEmpty { result.append((LanguageManager.shared.localizedString("earlier"), earlier)) }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                // Filter bar — always visible when there's history
                if !visibleHistory.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 13))
                            .accessibilityHidden(true)
                        TextField(LanguageManager.shared.localizedString("search_placeholder"), text: $filterText)
                            .font(.system(size: 14))
                            .autocorrectionDisabled()
                        if !filterText.isEmpty {
                            Button { filterText = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .accessibilityLabel(
                                LanguageManager.shared.localizedString("accessibility_clear_search")
                            )
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }

                // Content
                if visibleHistory.isEmpty {
                    // No history at all
                    ContentUnavailableView(
                        LanguageManager.shared.localizedString("no_history"),
                        systemImage: "clock.arrow.circlepath",
                        description: Text(LanguageManager.shared.localizedString("no_history_desc"))
                    )
                } else if deduped.isEmpty {
                    // Has history but filter returned nothing
                    ContentUnavailableView(
                        LanguageManager.shared.localizedString("no_results"),
                        systemImage: "magnifyingglass",
                        description: Text("")
                    )
                } else {
                    ForEach(grouped, id: \.title) { section in
                        Section(section.title) {
                            ForEach(section.items) { item in
                                historyRow(item)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(LanguageManager.shared.localizedString("search_history"))
            .navigationBarTitleDisplayMode(.large)
            .onTapGesture {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) { showClearAlert = true } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(visibleHistory.isEmpty)
                    .accessibilityLabel(LanguageManager.shared.localizedString("clear_all"))
                }
            }
            .alert(LanguageManager.shared.localizedString("confirm_clear_history"), isPresented: $showClearAlert) {
                Button(LanguageManager.shared.localizedString("delete"), role: .destructive) {
                    SearchHistoryService.clearAll(context: modelContext)
                    searchVM.recentSearches = []
                }
                Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
            }
            .onAppear {
                SearchHistoryService.purgeExpiredBrowsingHistory(context: modelContext)
            }
        }
    }

    private func historyRow(_ item: SearchHistoryItem) -> some View {
        Button {
            searchVM.searchText = item.visitedURLString ?? item.keyword
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                searchVM.performSearch(context: modelContext)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isWebVisit ? "globe" : "clock")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.keyword)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let host = item.visitedURLString
                        .flatMap({ URL(string: $0)?.host }) {
                        Text(host)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Text(formatTime(item.timestamp))
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)

                Image(systemName: item.isWebVisit ? "arrow.up.right" : "arrow.up.left")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.keyword)
        .accessibilityValue(formatTime(item.timestamp))
        .accessibilityHint(
            LanguageManager.shared.localizedString(
                item.isWebVisit ? "current_page_link" : "accessibility_search_history_hint"
            )
        )
        .accessibilityAction(named: Text(LanguageManager.shared.localizedString("delete"))) {
            for history in matchingHistoryEntries(for: item) {
                SearchHistoryService.deleteEntry(history, context: modelContext)
            }
        }
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                for h in matchingHistoryEntries(for: item) {
                    SearchHistoryService.deleteEntry(h, context: modelContext)
                }
            } label: {
                Label(LanguageManager.shared.localizedString("delete"), systemImage: "trash")
            }
        }
    }

    private func matchingHistoryEntries(for item: SearchHistoryItem) -> [SearchHistoryItem] {
        if let url = item.visitedURLString {
            return allHistory.filter { $0.visitedURLString == url }
        }
        return allHistory.filter {
            !$0.isWebVisit && $0.keyword.caseInsensitiveCompare(item.keyword) == .orderedSame
        }
    }

    private func formatTime(_ date: Date) -> String {
        let cal = Calendar.current
        let now = Date()

        if cal.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if cal.isDateInYesterday(date) {
            return LanguageManager.shared.localizedString("yesterday")
        } else {
            let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
            if days < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                return formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "M/d"
                return formatter.string(from: date)
            }
        }
    }
}
