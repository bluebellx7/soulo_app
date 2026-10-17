import SwiftUI

struct WebEpisodePickerView: View {
    @ObservedObject var viewModel: WebViewModel
    @ObservedObject private var downloads = WebEpisodeDownloadService.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("web_episodes_descending") private var descending = false
    @State private var selectedSourceID = ""
    @State private var isSelecting = false
    @State private var selectedIDs = Set<String>()
    @State private var showsFailures = false

    private var source: WebEpisodeSource? {
        viewModel.episodeList?.sources.first { $0.id == selectedSourceID }
            ?? viewModel.episodeList?.currentSource
    }
    private var currentIndex: Int? {
        guard let url = viewModel.currentURL else { return nil }
        return source?.episodes.firstIndex { WebEpisodeList.matches($0.url, url) }
    }
    private var episodes: [WebEpisode] {
        let all = source?.episodes ?? []
        return descending ? Array(all.reversed()) : all
    }
    private var jobs: [WebEpisodeDownloadJob] {
        let urls = Set(source?.episodes.map(\.url) ?? [])
        var latest: [URL: WebEpisodeDownloadJob] = [:]
        for job in downloads.jobs where urls.contains(job.episode.url) { latest[job.episode.url] = job }
        return source?.episodes.compactMap { latest[$0.url] } ?? []
    }
    private var failures: [WebEpisodeDownloadJob] { jobs.filter { $0.status == .failed } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let list = viewModel.episodeList, let source {
                    let sourceJobs = jobs
                    let jobsByURL = Dictionary(uniqueKeysWithValues: sourceJobs.map { ($0.episode.url, $0) })
                    HStack {
                        if list.sources.count > 1 {
                            Picker(ToolText.text("episodes_source"), selection: Binding(
                                get: { source.id }, set: { selectedSourceID = $0 }
                            )) {
                                ForEach(Array(list.sources.enumerated()), id: \.element.id) { index, item in
                                    Text(sourceTitle(item, index: index)).tag(item.id)
                                }
                            }
                            .pickerStyle(.menu)
                            .accessibilityIdentifier("browser.episodes-source")
                        } else {
                            Text(sourceTitle(source, index: 0)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { descending.toggle() } label: {
                            Label(ToolText.text(descending ? "episodes_descending" : "episodes_ascending"),
                                systemImage: descending ? "arrow.down" : "arrow.up")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("browser.episodes-order")
                    }
                    .font(.subheadline)

                    if !isSelecting {
                        HStack(spacing: 12) {
                            adjacentButton(offset: -1, key: "episodes_previous", symbol: "backward.end.fill")
                            Text(currentIndex.map { source.episodes[$0].title } ?? ToolText.text("episodes"))
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .frame(maxWidth: .infinity)
                            adjacentButton(offset: 1, key: "episodes_next", symbol: "forward.end.fill")
                        }
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10)], spacing: 10) {
                                ForEach(episodes) { episode in episodeButton(episode, job: jobsByURL[episode.url]) }
                            }
                            .padding(.bottom, 12)
                        }
                        .task(id: "\(source.id)|\(descending)") {
                            await Task.yield()
                            if let currentIndex { proxy.scrollTo(source.episodes[currentIndex].id, anchor: .center) }
                        }
                    }
                    if isSelecting {
                        HStack {
                            let allSelected = selectedIDs.count == source.episodes.count
                            Button(ToolText.text(allSelected ? "image_batch_deselect_all" : "image_batch_select_all")) {
                                selectedIDs = allSelected ? [] : Set(source.episodes.map(\.id))
                            }
                            .accessibilityIdentifier("browser.episodes-select-all")
                            Spacer()
                            Button {
                                let chosen = source.episodes.filter { selectedIDs.contains($0.id) }
                                downloads.enqueue(chosen, pageTitle: viewModel.pageTitle, viewModel: viewModel)
                                isSelecting = false
                                selectedIDs.removeAll()
                            } label: {
                                Label(String(format: ToolText.text("episodes_download_selected"), selectedIDs.count), systemImage: "arrow.down.circle")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedIDs.isEmpty || viewModel.webView == nil)
                            .accessibilityIdentifier("browser.episodes-download")
                        }
                        .font(.subheadline)
                    }
                    if !sourceJobs.isEmpty { downloadStatus(sourceJobs) }
                } else if viewModel.isLoading {
                    Spacer(); ProgressView(); Spacer()
                } else {
                    ContentUnavailableView(ToolText.text("episodes_unavailable"), systemImage: "list.number")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .navigationTitle(ToolText.text("episodes"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(ToolText.text(isSelecting ? "cancel" : "episodes_select")) {
                        isSelecting.toggle()
                        selectedIDs.removeAll()
                    }
                    .disabled(source == nil)
                    .accessibilityIdentifier("browser.episodes-select")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) { dismiss() }
                }
            }
            .onChange(of: source?.id) { _, _ in selectedIDs.removeAll() }
            .onChange(of: source?.episodes.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids ?? [])) }
            .alert(ToolText.text("error"), isPresented: $showsFailures) {
                Button(ToolText.text("retry")) {
                    downloads.enqueue(failures.map(\.episode), pageTitle: viewModel.pageTitle, viewModel: viewModel)
                }
                .disabled(viewModel.webView == nil)
                Button(ToolText.text("done"), role: .cancel) {}
            } message: {
                Text(failures.map { "\($0.episode.title): \($0.errorMessage)" }.joined(separator: "\n"))
            }
        }
    }

    private func downloadStatus(_ jobs: [WebEpisodeDownloadJob]) -> some View {
        let failures = jobs.filter { $0.status == .failed }
        return VStack(alignment: .leading, spacing: 6) {
            let completed = jobs.filter { !$0.isActive }.count
            if jobs.contains(where: \.isActive) {
                ProgressView(value: Double(completed), total: Double(jobs.count))
            }
            HStack {
                Text(String(format: ToolText.text("episodes_download_progress"), completed, jobs.count))
                Spacer()
                if !failures.isEmpty {
                    Button(String(format: ToolText.text("episodes_download_failed"), failures.count)) { showsFailures = true }
                        .accessibilityIdentifier("browser.episodes-download-failures")
                }
                if jobs.contains(where: { $0.status == .waiting }) {
                    Button(ToolText.text("episodes_download_stop_queue")) {
                        downloads.cancelQueued(episodeURLs: Set(source?.episodes.map(\.url) ?? []))
                    }
                }
            }
            Text(ToolText.text("episodes_download_hint")).foregroundStyle(.secondary)
        }
        .font(.caption)
        .accessibilityIdentifier("browser.episodes-download-status")
    }

    private func episodeButton(_ episode: WebEpisode, job: WebEpisodeDownloadJob?) -> some View {
        let current = viewModel.currentURL.map { WebEpisodeList.matches(episode.url, $0) } ?? false
        let selected = isSelecting ? selectedIDs.contains(episode.id) : current
        return Button {
            if isSelecting {
                if !selectedIDs.insert(episode.id).inserted { selectedIDs.remove(episode.id) }
            } else { open(episode) }
        } label: {
            HStack(spacing: 5) {
                if isSelecting {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .accessibilityHidden(true)
                } else if let job {
                    if job.isActive { ProgressView().controlSize(.mini) }
                    else if job.status == .finished { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    else if job.status == .failed { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                }
                Text(episode.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.themePrimary : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(episode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .id(episode.id)
    }

    private func sourceTitle(_ source: WebEpisodeSource, index: Int) -> String {
        source.title.isEmpty ? "\(ToolText.text("episodes_source")) \(index + 1)" : source.title
    }
    private func adjacentButton(offset: Int, key: String, symbol: String) -> some View {
        let target = currentIndex.flatMap { index -> WebEpisode? in
            guard let episodes = source?.episodes, episodes.indices.contains(index + offset) else { return nil }
            return episodes[index + offset]
        }
        return Button { if let target { open(target) } } label: {
            Image(systemName: symbol).frame(width: 44, height: 44)
        }
        .disabled(target == nil)
        .accessibilityLabel(ToolText.text(key))
        .accessibilityIdentifier(offset < 0 ? "browser.episodes-previous" : "browser.episodes-next")
    }
    private func open(_ episode: WebEpisode) { viewModel.loadURL(episode.url); dismiss() }
}
