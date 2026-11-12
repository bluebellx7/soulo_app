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
                CompatibleUnavailableView(LanguageManager.shared.localizedString("no_results"), systemImage: "magnifyingglass")
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
        article
        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
        .onAppear { paragraph = item.paragraph ?? 0 }
        .onDisappear { let position = paragraph; Task { try? await ReadingListStore.shared.updatePosition(id: item.id, paragraph: position) } }
        .toolbar { ShareLink(item: item.url) }
    }

    @ViewBuilder private var article: some View {
        if #available(iOS 17.0, *) {
            modernArticle
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                            paragraphText(text).id(index).background {
                                GeometryReader { geometry in
                                    Color.clear.preference(key: SavedParagraphPositions.self,
                                        value: [index: geometry.frame(in: .named("saved-article")).minY])
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: 760)
                }
                .coordinateSpace(name: "saved-article")
                .onPreferenceChange(SavedParagraphPositions.self) { positions in
                    let preceding = positions.filter { $0.value <= 0 }.max { $0.value < $1.value }
                    paragraph = preceding?.key ?? positions.min { $0.value < $1.value }?.key ?? paragraph
                }
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(item.paragraph ?? 0, anchor: .top) }
                }
            }
        }
    }

    private func paragraphText(_ text: String) -> some View {
        Text(text).font(.system(size: size)).textSelection(.enabled)
    }

    @available(iOS 17.0, *)
    private var modernArticle: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(Array(paragraphs.enumerated()), id: \.offset) { index, text in
                    Text(text).font(.system(size: size)).textSelection(.enabled).id(index)
                }
            }.scrollTargetLayout().padding(20).frame(maxWidth: 760)
        }
        .scrollPosition(id: $paragraph, anchor: .top)
    }
}

private struct SavedParagraphPositions: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
