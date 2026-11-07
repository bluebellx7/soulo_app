import SwiftUI

struct ReadingListView: View {
    @ObservedObject private var store = ReadingListStore.shared
    @State private var search = ""
    @State private var error: String?
    private var visibleItems: [SavedReadingItem] {
        store.items.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.url.absoluteString.localizedCaseInsensitiveContains(search) }
            .sorted { ($0.lastOpenedAt ?? $0.savedAt) > ($1.lastOpenedAt ?? $1.savedAt) }
    }

    var body: some View {
        List {
            Section {
                IllustratedFeatureIntro(scene: .books,
                    message: FeatureText.text("Save an article from reader mode to read it offline.") + "\n"
                        + FeatureText.text("Saved articles contain the text loaded in reader mode. Images and linked pages are not downloaded."),
                    accessibilityID: "reading-list.explanation")
            }
            if !search.isEmpty && visibleItems.isEmpty {
                ContentUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "magnifyingglass")
            }
            ForEach(visibleItems) { item in
                NavigationLink { SavedArticleView(item: item) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).lineLimit(2)
                        Text(item.url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.onDelete { indices in
                let ids = Set(indices.compactMap { visibleItems.indices.contains($0) ? visibleItems[$0].id : nil })
                Task {
                    do { try await store.remove(ids: ids) }
                    catch { self.error = error.localizedDescription }
                }
            }
        }
        .task { do { try await store.load() } catch { self.error = error.localizedDescription } }
        .navigationTitle(FeatureText.text("Reading list"))
        .searchable(text: $search, prompt: LanguageManager.shared.localizedString("search"))
        .alert(ToolText.text("error"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(ToolText.text("done")) { error = nil }
        } message: { Text(error ?? "") }
    }
}

private struct SavedArticleView: View {
    let item: SavedReadingItem
    @State private var paragraph: Int?
    @AppStorage("reader.fontSize") private var size = 18.0
    private var paragraphs: [String] { item.text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                    Text(text).font(.system(size: size)).textSelection(.enabled).id(index)
                }
            }.scrollTargetLayout().padding(20).frame(maxWidth: 760)
        }
        .scrollPosition(id: $paragraph, anchor: .top)
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .onAppear { paragraph = item.paragraph ?? 0 }
        .onDisappear { let position = paragraph; Task { try? await ReadingListStore.shared.updatePosition(id: item.id, paragraph: position) } }
        .toolbar { ShareLink(item: item.url) }
    }
}
