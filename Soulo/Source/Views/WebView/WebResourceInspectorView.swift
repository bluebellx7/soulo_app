import AVKit
import Combine
import SwiftUI
import WebKit

enum WebResourceInspectorDefaults {
    static let minimumImageWidth = 200.0
}

@MainActor
private final class WebResourceInspectorViewModel: ObservableObject {
    @Published var snapshot = WebResourceSnapshot.empty
    @Published var isLoading = false
    @Published var errorMessage = ""
    @Published var activeResourceIDs = Set<String>()
    @Published var statusMessage = ""

    private weak var webViewModel: WebViewModel?

    var sourceWebView: WKWebView? {
        webViewModel?.webView
    }
    var episodeList: WebEpisodeList? { webViewModel?.episodeList }

    init(webViewModel: WebViewModel) {
        self.webViewModel = webViewModel
    }

    func inspect() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            snapshot = try await WebResourceInspectionService.inspect(
                webView: webViewModel?.webView,
                frames: webViewModel?.mediaFrameInfos ?? []
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(
        url: URL,
        preferredFilename: String? = nil,
        saveToPhotos: Bool = false
    ) async {
        let identifier = url.absoluteString
        guard activeResourceIDs.insert(identifier).inserted else { return }
        defer { activeResourceIDs.remove(identifier) }

        do {
            if saveToPhotos {
                try await WebResourceDownloadService.shared.saveImageToPhotos(
                    url,
                    preferredFilename: preferredFilename,
                    pageURL: snapshot.pageURL,
                    webView: webViewModel?.webView
                )
            } else {
                _ = try await WebResourceDownloadService.shared.download(
                    url,
                    preferredFilename: preferredFilename,
                    pageURL: snapshot.pageURL,
                    webView: webViewModel?.webView
                )
            }
            statusMessage = LanguageManager.shared.localizedString(
                saveToPhotos ? "resource_saved_to_photos" : "resource_download_complete"
            )
            HapticsManager.success()
        } catch {
            statusMessage = error.localizedDescription
            HapticsManager.error()
        }
    }

    @discardableResult
    func download(media resource: WebMediaResource) async -> URL? {
        let identifier = downloadIdentifier(for: resource)
        guard activeResourceIDs.insert(identifier).inserted else { return nil }
        defer { activeResourceIDs.remove(identifier) }

        return await performDownload(media: resource)
    }

    func startDownload(media resource: WebMediaResource) {
        let identifier = downloadIdentifier(for: resource)
        guard activeResourceIDs.insert(identifier).inserted else { return }
        statusMessage = LanguageManager.shared.localizedString("downloading")
        HapticsManager.light()

        Task { [weak self] in
            guard let self else { return }
            _ = await self.performDownload(media: resource)
            self.activeResourceIDs.remove(identifier)
        }
    }

    private func performDownload(media resource: WebMediaResource) async -> URL? {
        do {
            let localURL = try await WebResourceDownloadService.shared.download(
                resource,
                preferredFilename: resource.suggestedFilename,
                pageURL: resource.sourcePageURL ?? snapshot.pageURL,
                webView: webViewModel?.webView
            )
            statusMessage = LanguageManager.shared.localizedString("resource_download_complete")
            HapticsManager.success()
            return localURL
        } catch {
            if let streamingError = error as? StreamingMediaDownloadError,
               case .alreadyInProgress = streamingError {
                statusMessage = LanguageManager.shared.localizedString("downloading")
                return nil
            }
            statusMessage = error.localizedDescription
            HapticsManager.error()
            return nil
        }
    }

    func downloadIdentifier(for resource: WebMediaResource) -> String {
        WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: snapshot.pageURL
        ).absoluteString
    }

    func playbackAsset(for resource: WebMediaResource, cacheForPlayback: Bool = true) async -> AVURLAsset {
        await WebResourceMediaService.asset(
            for: resource,
            webView: webViewModel?.webView,
            cacheForPlayback: cacheForPlayback
        )
    }
}

struct WebResourceInspectorView: View {
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    private enum ResourceSection: String, CaseIterable, Identifiable {
        var id: String { rawValue }
        case images
        case videos
        case audio
        case documents
        case links
        case text
        case colors
    }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: WebResourceInspectorViewModel
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    @State private var selectedSection: ResourceSection = .images
    @State private var minimumImageWidth = WebResourceInspectorDefaults.minimumImageWidth
    @State private var unavailableImageIDs = Set<String>()
    @State private var selectedImage: WebImageResource?
    @State private var selectedMedia: WebMediaResource?
    @State private var selectedDownloadedItem: BrowserDownloadItem?
    @State private var audioPlayer: AVPlayer?
    @State private var activeAudioURL: URL?
    @State private var inlineAudioTask: Task<Void, Never>?
    @State private var activeAudioID: String?
    @State private var isAudioPlaying = false
    @StateObject private var imageBatchSaver = WebImageBatchSaver()
    @State private var isSelectingImages = false
    @State private var selectedImageIDs = Set<String>()
    @State private var batchSaveMessage: String?
    @State private var batchSaveNotice: String?

    init(webViewModel: WebViewModel) {
        _viewModel = StateObject(
            wrappedValue: WebResourceInspectorViewModel(webViewModel: webViewModel)
        )
    }

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.snapshot.isEmpty {
                loadingView
            } else if !viewModel.errorMessage.isEmpty && viewModel.snapshot.isEmpty {
                errorView
            } else {
                resourcesView
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("resource_inspector_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                    .disabled(imageBatchSaver.isSaving)
            }
            ToolbarItem(placement: .primaryAction) {
                if selectedSection == .images && !filteredImages.isEmpty {
                    Button {
                        isSelectingImages.toggle()
                        selectedImageIDs.removeAll()
                    } label: {
                        Image(systemName: isSelectingImages ? "xmark" : "checkmark.circle")
                            .foregroundStyle(.primary)
                    }
                    .disabled(imageBatchSaver.isSaving)
                    .accessibilityLabel(ToolText.text(isSelectingImages ? "cancel" : "image_batch_select"))
                    .accessibilityIdentifier("resources.images.select")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    unavailableImageIDs.removeAll()
                    stopInlineAudio()
                    Task { await viewModel.inspect() }
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: AppControlMetrics.iconSize, weight: .semibold))
                    }
                }
                .disabled(viewModel.isLoading || imageBatchSaver.isSaving)
                .accessibilityLabel(LanguageManager.shared.localizedString("resource_rescan"))
            }
        }
        .task {
            downloadManager.removeMissingFiles()
            if viewModel.snapshot.isEmpty {
                await viewModel.inspect()
                if count(for: selectedSection) == 0 {
                    selectedSection = ResourceSection.allCases.first { count(for: $0) > 0 } ?? .images
                }
            }
        }
        .fullScreenCover(item: $selectedMedia) { media in
            WebResourceMediaPlayerView(
                resource: media,
                pageURL: media.sourcePageURL ?? viewModel.snapshot.pageURL,
                sourceWebView: viewModel.sourceWebView,
                assetProvider: { await viewModel.playbackAsset(for: media) },
                downloadAction: { await viewModel.download(media: media) }, episodeList: viewModel.episodeList
            )
        }
        .navigationDestination(isPresented: Binding(get: { selectedDownloadedItem != nil }, set: { if !$0 { selectedDownloadedItem = nil } })) {
            if let item = selectedDownloadedItem { DownloadManagerContentView(highlightedItemID: item.id).navigationTitle(LanguageManager.shared.localizedString("downloads")) }
        }
        .fullScreenCover(item: $selectedImage) { image in
            WebResourceImageViewer(
                images: filteredImages,
                initialImageID: image.id,
                viewModel: viewModel
            )
        }
        .onReceive(MediaSession.shared.$playing) { playing in
            isAudioPlaying = playing && MediaSession.shared.url == activeAudioURL
        }
        .onDisappear {
            stopInlineAudio()
            imageBatchSaver.cancel()
        }
        .onCompatibleChange(of: filteredImages.map(\.id)) { _, ids in
            selectedImageIDs.formIntersection(ids)
        }
        .onCompatibleChange(of: selectedSection) { _, section in
            if section != .images && !imageBatchSaver.isSaving {
                isSelectingImages = false
                selectedImageIDs.removeAll()
            }
        }
        .interactiveDismissDisabled(imageBatchSaver.isSaving)
        .safeAreaInset(edge: .bottom) {
            if isSelectingImages { imageBatchBar }
        }
        .statusNotice($batchSaveNotice)
        .alert(ToolText.text("image_batch_result"), isPresented: Binding(
            get: { batchSaveMessage != nil }, set: { if !$0 { batchSaveMessage = nil } }
        )) {
            Button(LanguageManager.shared.localizedString("done")) { batchSaveMessage = nil }
        } message: { Text(batchSaveMessage ?? "") }
        .overlay(alignment: .bottom) {
            if !viewModel.statusMessage.isEmpty {
                Text(viewModel.statusMessage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: viewModel.statusMessage) {
                        try? await Task.sleep(for: .seconds(2.4))
                        withAnimation { viewModel.statusMessage = "" }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)
    }

    private func count(for section: ResourceSection) -> Int {
        switch section {
        case .images: viewModel.snapshot.images.count
        case .videos: viewModel.snapshot.videos.count
        case .audio: viewModel.snapshot.audio.count
        case .documents: viewModel.snapshot.documents.count
        case .links: viewModel.snapshot.links.count
        case .text: viewModel.snapshot.textFragments.count
        case .colors: viewModel.snapshot.colors.count
        }
    }

    private func titleKey(for section: ResourceSection) -> String {
        section == .text ? "resource_text_fragments" : "resource_" + section.rawValue
    }

    private func symbol(for section: ResourceSection) -> String {
        switch section {
        case .images: "photo"
        case .videos: "play.rectangle"
        case .audio: "waveform"
        case .documents: "doc"
        case .links: "link"
        case .text: "text.quote"
        case .colors: "paintpalette"
        }
    }

    private var availableSections: [ResourceSection] {
        ResourceSection.allCases.filter { count(for: $0) > 0 }
    }

    private var resourcesView: some View {
        VStack(spacing: 0) {
            if !availableSections.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(availableSections) { section in
                            Button {
                                selectedSection = section
                                if section != .audio { stopInlineAudio() }
                                withAnimation { proxy.scrollTo(section, anchor: .center) }
                            } label: {
                                VStack(spacing: 7) {
                                    Image(systemName: symbol(for: section)).font(.system(size: 17, weight: .medium)).frame(height: 20)
                                    HStack(spacing: 4) {
                                        Text(LanguageManager.shared.localizedString(titleKey(for: section)))
                                        Text(count(for: section).formatted()).monospacedDigit().foregroundStyle(.secondary)
                                    }.font(.caption2.weight(.medium)).fixedSize()
                                }
                                .padding(.horizontal, 12).frame(minHeight: 64)
                                .foregroundStyle(selectedSection == section ? Color.themePrimary : .secondary)
                                .background(selectedSection == section ? Color.themePrimary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain).id(section)
                            .disabled(imageBatchSaver.isSaving)
                            .accessibilityIdentifier("resources.tab." + section.rawValue)
                            .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
                        }
                    }.padding(.horizontal, 16).padding(.vertical, 10)
                }.scrollIndicators(.hidden)
                .onCompatibleChange(of: selectedSection) { _, section in
                    withAnimation { proxy.scrollTo(section, anchor: .center) }
                }
            }
            Divider().opacity(0.4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if count(for: selectedSection) == 0 {
                        emptyView.frame(maxWidth: .infinity).padding(.top, 50)
                    } else {
                        switch selectedSection {
                        case .videos: videoRows
                        case .audio: audioRows
                        case .images:
                            imageWidthFilter
                            if filteredImages.isEmpty {
                                emptyView.padding(.top, 24)
                            } else { imageGrid }
                        case .documents: documentRows
                        case .text:
                            copyAndShareAllButtons(titleKey: "resource_copy_all_text", value: viewModel.snapshot.textFragments.map(\.text).joined(separator: "\n\n"))
                            textRows
                        case .colors: colorGrid
                        case .links:
                            copyAndShareAllButtons(titleKey: "resource_copy_all_links", value: viewModel.snapshot.links.map(\.url.absoluteString).joined(separator: "\n"))
                            linkRows
                        }
                    }
                }.padding(18)
            }.id(selectedSection)
        }.background(Color(uiColor: .systemBackground))
        .onCompatibleChange(of: availableSections, initial: true) { _, sections in
            if !sections.contains(selectedSection) {
                selectedSection = sections.first ?? .images
                stopInlineAudio()
            }
        }
    }

    private var maximumImageWidth: Double {
        let width = viewModel.snapshot.images.map(\.width).max() ?? 0
        return Double(max(min(width, 3000), 200))
    }

    private var filteredImages: [WebImageResource] {
        viewModel.snapshot.images.filter { image in
            !unavailableImageIDs.contains(image.id)
                && Double(image.width) >= minimumImageWidth
        }
    }

    private var imageWidthFilter: some View {
        VStack(spacing: 6) {
            HStack {
                Text(LanguageManager.shared.localizedString("resource_minimum_image_width"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(minimumImageWidth <= 0 ? LanguageManager.shared.localizedString("all") : "≥ \(Int(minimumImageWidth)) px")
                    .font(.system(size: 12, design: .rounded).weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Slider(value: $minimumImageWidth, in: 0...maximumImageWidth, step: 20)
                .disabled(imageBatchSaver.isSaving)
                .accessibilityLabel(LanguageManager.shared.localizedString("resource_minimum_image_width"))
        }
    }

    private var imageGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 10)], spacing: 10) {
            ForEach(filteredImages) { image in
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        if isSelectingImages {
                            if !selectedImageIDs.insert(image.id).inserted { selectedImageIDs.remove(image.id) }
                        } else { selectedImage = image }
                    } label: {
                        WebResourceImagePreview(resource: image) {
                            unavailableImageIDs.insert(image.id)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 124)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if isSelectingImages {
                                Image(systemName: selectedImageIDs.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 21, weight: .medium))
                                    .foregroundStyle(selectedImageIDs.contains(image.id) ? Color.accentColor : .secondary)
                                    .padding(4).background(.regularMaterial, in: Circle()).padding(6)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(imageBatchSaver.isSaving)
                    .accessibilityAddTraits(selectedImageIDs.contains(image.id) ? .isSelected : [])
                    .accessibilityIdentifier("resources.image." + image.id)
                    .accessibilityLabel(imageAccessibilityLabel(image))

                    HStack(spacing: 5) {
                        Text(image.width > 0 ? "\(image.width) × \(image.height)" : image.url.host ?? "")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        if !isSelectingImages { resourceDownloadMenu(for: image) }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var imageBatchBar: some View {
        VStack(spacing: 10) {
            if imageBatchSaver.isSaving {
                ProgressView(value: Double(imageBatchSaver.completed), total: Double(max(1, imageBatchSaver.total)))
                HStack {
                    Text(String(format: ToolText.text("image_batch_progress"), imageBatchSaver.completed, imageBatchSaver.total))
                        .font(.subheadline).monospacedDigit()
                    Spacer()
                    Button(ToolText.text("cancel")) { imageBatchSaver.cancel() }
                        .accessibilityIdentifier("resources.images.cancel-save")
                }
            } else {
                HStack {
                    let allSelected = !filteredImages.isEmpty && selectedImageIDs.count == filteredImages.count
                    Button(ToolText.text(allSelected ? "image_batch_deselect_all" : "image_batch_select_all")) {
                        selectedImageIDs = allSelected ? [] : Set(filteredImages.map(\.id))
                    }
                    .disabled(filteredImages.isEmpty)
                    .accessibilityIdentifier("resources.images.select-all")
                    Spacer()
                    Button(action: saveSelectedImages) {
                        Label(String(format: ToolText.text("image_batch_save"), selectedImageIDs.count), systemImage: "photo.badge.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedImageIDs.isEmpty)
                    .accessibilityIdentifier("resources.images.save-selected")
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private func saveSelectedImages() {
        let images = filteredImages.filter { selectedImageIDs.contains($0.id) }
        let pageURL = viewModel.snapshot.pageURL
        let webView = viewModel.sourceWebView
        imageBatchSaver.start(images: images) { image in
            try await WebResourceDownloadService.shared.saveImageToPhotos(
                image.url, preferredFilename: image.url.lastPathComponent, pageURL: pageURL, webView: webView
            )
        } completion: { result in
            selectedImageIDs.subtract(result.savedIDs)
            let summary = String(format: ToolText.text("image_batch_summary"), result.savedIDs.count, result.failedIDs.count)
            if result.permissionDenied {
                batchSaveMessage = WebResourceDownloadError.photoAccessDenied.localizedDescription
            } else if result.wasCancelled {
                batchSaveMessage = String(format: ToolText.text("image_batch_cancelled"), result.savedIDs.count)
            } else if result.failedIDs.isEmpty {
                batchSaveNotice = summary
            } else {
                batchSaveMessage = summary
            }
            if selectedImageIDs.isEmpty { isSelectingImages = false }
            if result.failedIDs.isEmpty && !result.wasCancelled { HapticsManager.success() }
            else if !result.wasCancelled { HapticsManager.error() }
        }
    }

    private func resourceDownloadMenu(for image: WebImageResource) -> some View {
        Group {
            if viewModel.activeResourceIDs.contains(image.id) {
                downloadProgressIndicator(for: image.url)
            } else if let item = finishedDownload(for: image.url) {
                openDownloadedItemButton(item)
            } else {
                Menu {
                    Button {
                        Task {
                            await viewModel.download(
                                url: image.url,
                                preferredFilename: image.url.lastPathComponent,
                                saveToPhotos: true
                            )
                        }
                    } label: {
                        Label(LanguageManager.shared.localizedString("save_to_photos"), systemImage: "photo.badge.arrow.down")
                    }
                    Button {
                        Task { await viewModel.download(url: image.url) }
                    } label: {
                        Label(LanguageManager.shared.localizedString("download"), systemImage: "arrow.down.circle")
                    }
                    Button {
                        copyToPasteboard(image.url.absoluteString)
                    } label: {
                        Label(LanguageManager.shared.localizedString("copy_link"), systemImage: "doc.on.doc")
                    }
                    ShareLink(item: image.url) {
                        Label(LanguageManager.shared.localizedString("share"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    CompactIconLabel(systemImage: "ellipsis")
                        .frame(width: 26, height: 26)
                }
            }
        }
    }

    private func imageAccessibilityLabel(_ image: WebImageResource) -> String {
        let imageName = image.title.isEmpty ? image.url.lastPathComponent : image.title
        return [imageName, "\(image.width) × \(image.height)"]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    private var videoRows: some View {
        LazyVStack(spacing: 12) {
            ForEach(viewModel.snapshot.videos) { resource in
                VStack(alignment: .leading, spacing: 9) {
                    Button {
                        selectedMedia = resource
                    } label: {
                        ZStack {
                            WebResourceVideoPreview(
                                resource: resource,
                                pageURL: viewModel.snapshot.pageURL,
                                assetProvider: { await viewModel.playbackAsset(for: resource, cacheForPlayback: false) },
                                pageFrameProvider: {
                                    await WebResourceMediaService.pageVideoFrame(
                                        in: viewModel.sourceWebView
                                    )
                                }
                            )
                                .frame(maxWidth: .infinity)
                                .aspectRatio(16 / 9, contentMode: .fit)

                            Image(systemName: "play.fill")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 48, height: 48)
                                .background(.black.opacity(0.58), in: Circle())
                                .overlay {
                                    Circle().stroke(.white.opacity(0.32), lineWidth: 0.5)
                                }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ToolText.text("play"))
                    .accessibilityIdentifier("resources.video.play")

                    HStack(spacing: 8) {
                        resourceText(title: resource.title, url: resource.url)
                        Spacer(minLength: 4)
                        mediaResourceActions(for: resource)
                    }
                    if let item = activeDownload(for: downloadIdentityURL(for: resource)),
                       downloadManager.foregroundRequiredDownloadIDs.contains(item.id) {
                        Label(LanguageManager.shared.localizedString("downloads_keep_app_open"), systemImage: "iphone")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.themePrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("resources.video.foregroundRequired")
                    }
                }
                .padding(.vertical, 8)
                if resource.id != viewModel.snapshot.videos.last?.id { Divider() }
            }
        }
    }

    private var audioRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.audio) { resource in
                let isCurrentAudioPlaying = activeAudioID == resource.id && isAudioPlaying
                HStack(spacing: 10) {
                    Button {
                        toggleInlineAudio(resource)
                    } label: {
                        Image(systemName: isCurrentAudioPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(.tint, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        LanguageManager.shared.localizedString("resource_audio_player")
                    )

                    resourceText(title: resource.title, url: resource.url)
                    Spacer(minLength: 4)
                    mediaResourceActions(for: resource)
                }
                .padding(.vertical, 8)
                if resource.id != viewModel.snapshot.audio.last?.id { Divider() }
            }
        }
    }

    private func toggleInlineAudio(_ resource: WebMediaResource) {
        let session = MediaSession.shared
        inlineAudioTask?.cancel()
        activeAudioID = resource.id
        activeAudioURL = resource.url
        audioPlayer = session.player
        if session.url == resource.url {
            session.toggle()
            isAudioPlaying = session.playing
            return
        }
        let reservation = session.reservePreparation()
        inlineAudioTask = Task {
            let asset = await viewModel.playbackAsset(for: resource)
            guard !Task.isCancelled, session.ownsPreparation(reservation) else { return }
            session.open(url: resource.url, title: resource.title, pageURL: viewModel.snapshot.pageURL,
                         asset: asset, webView: viewModel.sourceWebView, reservation: reservation)
        }
    }

    private func stopInlineAudio() {
        // Closing the inspector detaches its controls; the shared mini-player keeps playing.
        inlineAudioTask?.cancel(); inlineAudioTask = nil
        audioPlayer = nil; activeAudioID = nil; activeAudioURL = nil; isAudioPlaying = false
    }

    @ViewBuilder
    private func mediaResourceActions(for resource: WebMediaResource) -> some View {
        let identityURL = downloadIdentityURL(for: resource)
        let identifier = identityURL.absoluteString
        HStack(spacing: 2) {
            if let item = finishedDownload(for: identityURL) {
                openDownloadedItemButton(item)
            } else if viewModel.activeResourceIDs.contains(identifier)
                        || activeDownload(for: identityURL) != nil {
                downloadProgressIndicator(for: identityURL)
            } else if resource.kind != .video || showsVideoDownloadControls {
                Button {
                    viewModel.startDownload(media: resource)
                } label: {
                    CompactIconLabel(systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("download"))
                .accessibilityIdentifier("resources.media.download." + resource.kind.rawValue)
            }

            copyResourceURLButton(url: resource.url)
            shareURLButton(resource.url)
        }
    }

    private var documentRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.documents) { resource in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    resourceText(title: resource.title, url: resource.url)
                    Spacer(minLength: 4)
                    HStack(spacing: 2) {
                        downloadButton(url: resource.url)
                        copyResourceURLButton(url: resource.url)
                        shareURLButton(resource.url)
                    }
                }
                .padding(.vertical, 8)
                if resource.id != viewModel.snapshot.documents.last?.id { Divider() }
            }
        }
    }

    private var linkRows: some View {
        let groups = WebLinkDomainGroup.group(viewModel.snapshot.links)
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(groups) { group in
                if groups.count > 1 {
                    HStack {
                        Text(group.domain).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(group.links.count)").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 12)
                    .accessibilityIdentifier("resources.domain.\(group.domain)")
                }
                ForEach(group.links) { resource in
                    linkRow(resource)
                    if resource.id != group.links.last?.id { Divider() }
                }
            }
        }
    }

    private func linkRow(_ resource: WebLinkResource) -> some View {
                HStack(spacing: 6) {
                    Button {
                        copyToPasteboard(resource.url.absoluteString)
                    } label: {
                        HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        resourceText(title: resource.title, url: resource.url)
                        Spacer(minLength: 4)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    shareURLButton(resource.url)
                }
    }

    private var textRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.textFragments) { resource in
                HStack(alignment: .top, spacing: 6) {
                    Button {
                        copyToPasteboard(resource.text)
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                        Text(resource.text)
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(5)
                        Spacer(minLength: 4)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    shareTextButton(resource.text)
                        .padding(.top, 5)
                }
                if resource.id != viewModel.snapshot.textFragments.last?.id { Divider() }
            }
        }
    }

    private var colorGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 130), spacing: 9)], spacing: 9) {
            ForEach(viewModel.snapshot.colors) { resource in
                Button {
                    copyToPasteboard(resource.value)
                } label: {
                    HStack(spacing: 7) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(hex: resource.value))
                            .frame(width: 28, height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                            }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(resource.value)
                                .font(.system(size: 10, design: .monospaced).weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Text("×\(resource.count)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityLabel(resource.value)
                .accessibilityValue("×\(resource.count)")
            }
        }
    }

    private func copyAndShareAllButtons(titleKey: String, value: String) -> some View {
        HStack(spacing: 8) {
            Button {
                copyToPasteboard(value)
            } label: {
                Label(LanguageManager.shared.localizedString(titleKey), systemImage: "doc.on.doc.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            ShareLink(item: value) {
                Label(LanguageManager.shared.localizedString("share"), systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.small)
    }

    private func downloadButton(url: URL) -> some View {
        Group {
            if let item = finishedDownload(for: url) {
                openDownloadedItemButton(item)
            } else if viewModel.activeResourceIDs.contains(url.absoluteString) {
                downloadProgressIndicator(for: url)
            } else {
                Button {
                    Task { await viewModel.download(url: url) }
                } label: {
                    CompactIconLabel(systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("download"))
            }
        }
    }

    private func copyResourceURLButton(url: URL) -> some View {
        Button {
            copyToPasteboard(url.absoluteString)
        } label: {
            CompactIconLabel(systemImage: "doc.on.doc")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("resource_copy_url"))
    }

    @ViewBuilder
    private func downloadProgressIndicator(for url: URL) -> some View {
        if let item = activeDownload(for: url) {
            Button {
                selectedDownloadedItem = item
            } label: {
                if item.expectedBytes > 0 {
                    VStack(spacing: 2) {
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 36)
                        Text("\(Int((item.progress * 100).rounded()))%")
                            .font(.system(size: 8, design: .monospaced).weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
                } else {
                    Image(systemName: item.status == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 17))
                        .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("downloads"))
            .accessibilityValue("\(Int((item.progress * 100).rounded()))%")
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: AppControlMetrics.minimumHitSize, height: AppControlMetrics.minimumHitSize)
        }
    }

    private func activeDownload(for url: URL) -> BrowserDownloadItem? {
        downloadManager.activeDownload(for: url)
    }

    private func finishedDownload(for url: URL) -> BrowserDownloadItem? {
        downloadManager.finishedDownload(for: url)
    }

    private func downloadIdentityURL(for resource: WebMediaResource) -> URL {
        WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: viewModel.snapshot.pageURL
        )
    }

    private func openDownloadedItemButton(_ item: BrowserDownloadItem) -> some View {
        Button {
            selectedDownloadedItem = item
        } label: {
            CompactIconLabel(systemImage: "folder.fill")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("open_downloads_folder"))
    }

    private func shareURLButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            CompactIconLabel(systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("share"))
    }

    private func shareTextButton(_ value: String) -> some View {
        ShareLink(item: value) {
            CompactIconLabel(systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("share"))
    }

    private func resourceText(title: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.isEmpty ? (url.lastPathComponent.isEmpty ? url.host ?? url.absoluteString : url.lastPathComponent) : title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(url.absoluteString)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func copyToPasteboard(_ value: String) {
        UIPasteboard.general.string = value
        viewModel.statusMessage = LanguageManager.shared.localizedString("copied")
        HapticsManager.success()
    }

    private var loadingView: some View {
        CompatibleUnavailableView {
            ProgressView()
        } description: {
            Text(LanguageManager.shared.localizedString("resource_scanning"))
        }
    }

    private var emptyView: some View {
        CompatibleUnavailableView(
            LanguageManager.shared.localizedString("resource_none_found"),
            systemImage: "doc.text.magnifyingglass",
            description: Text(LanguageManager.shared.localizedString("resource_none_found_desc"))
        )
    }

    private var errorView: some View {
        CompatibleUnavailableView {
            Label(
                LanguageManager.shared.localizedString("resource_scan_failed"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(viewModel.errorMessage)
        } actions: {
            Button(LanguageManager.shared.localizedString("retry")) {
                Task { await viewModel.inspect() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

private struct WebResourceImagePreview: View {
    let resource: WebImageResource
    let onUnavailable: () -> Void
    @State private var didReportFailure = false

    var body: some View {
        AsyncImage(url: resource.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            case .failure:
                Color.clear
                    .onAppear {
                        guard !didReportFailure else { return }
                        didReportFailure = true
                        onUnavailable()
                    }
            case .empty:
                ProgressView()
            @unknown default:
                EmptyView()
            }
        }
    }
}

private struct WebResourceVideoPreview: View {
    let resource: WebMediaResource
    let pageURL: URL?
    let assetProvider: @MainActor () async -> AVURLAsset
    let pageFrameProvider: @MainActor () async -> UIImage?
    @State private var firstFrame: UIImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let firstFrame {
                Image(uiImage: firstFrame)
                    .resizable()
                    .scaledToFit()
            } else {
                fallback
            }
            if let posterURL = resource.posterURL {
                AsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        Color.clear
                    case .empty:
                        if firstFrame == nil {
                            ProgressView().tint(.white)
                        }
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .task(id: resource.id) {
            await loadFirstFrame()
        }
    }

    @MainActor
    private func loadFirstFrame() async {
        let identityURL = WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: pageURL
        )
        if let cachedImage = WebResourceMediaService.cachedThumbnail(for: identityURL) {
            firstFrame = cachedImage
            return
        }
        if requiresDownloadedPlayback,
           DownloadManagerService.shared.finishedDownload(for: identityURL) == nil {
            await loadPageFrame()
            return
        }
        let asset = await assetProvider()
        do {
            guard try await asset.load(.isPlayable) else {
                await loadPageFrame()
                return
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 720)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

            // Network streams often do not have a decodable keyframe at the
            // exact zero timestamp. Keep looking near the beginning so the
            // card shows the earliest real frame instead of silently falling
            // back to generic artwork.
            let candidateTimes = [0.0, 0.1, 0.5, 1.0].map {
                CMTime(seconds: $0, preferredTimescale: 600)
            }
            for time in candidateTimes {
                guard !Task.isCancelled else { return }
                if let result = try? await generator.image(at: time) {
                    let image = UIImage(cgImage: result.image)
                    WebResourceMediaService.cacheThumbnail(image, for: identityURL)
                    firstFrame = image
                    return
                }
            }
            await loadPageFrame()
        } catch {
            // A playable stream may disallow frame extraction. Keep its poster or
            // fallback artwork rather than incorrectly hiding the resource.
            _ = try? await asset.load(.isPlayable)
            await loadPageFrame()
        }
    }

    @MainActor
    private func loadPageFrame() async {
        guard !Task.isCancelled,
              let image = await pageFrameProvider() else { return }
        let identityURL = WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: pageURL
        )
        WebResourceMediaService.cacheThumbnail(image, for: identityURL)
        firstFrame = image
    }

    private var requiresDownloadedPlayback: Bool {
        resource.delivery == .separateTracks
            || resource.delivery == .youtubeSABR
    }

    private var fallback: some View {
        Image(systemName: "film.stack")
            .font(.system(size: 32, weight: .medium))
            .foregroundStyle(.white.opacity(0.48))
    }
}

private struct WebResourceImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    let images: [WebImageResource]
    @ObservedObject var viewModel: WebResourceInspectorViewModel
    @State private var selectedImageID: String
    @State private var selectedDownloadedItem: BrowserDownloadItem?

    init(
        images: [WebImageResource],
        initialImageID: String,
        viewModel: WebResourceInspectorViewModel
    ) {
        self.images = images
        self.viewModel = viewModel
        _selectedImageID = State(initialValue: initialImageID)
    }

    private var selectedImage: WebImageResource? {
        images.first(where: { $0.id == selectedImageID }) ?? images.first
    }

    private var selectedIndex: Int {
        images.firstIndex(where: { $0.id == selectedImageID }) ?? 0
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedImageID) {
                ForEach(images) { image in
                    WebResourceFullSizeImage(resource: image, onDismiss: { dismiss() })
                        .tag(image.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .foregroundStyle(.white)
                    .accessibilityLabel(LanguageManager.shared.localizedString("done"))

                    Spacer()

                    if images.count > 1 {
                        Text("\(selectedIndex + 1) / \(images.count)")
                            .font(.system(size: 13, design: .rounded).weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                if let selectedImage {
                    VStack(spacing: 10) {
                        if !viewModel.statusMessage.isEmpty {
                            Text(viewModel.statusMessage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .task(id: viewModel.statusMessage) {
                                    try? await Task.sleep(for: .seconds(2.4))
                                    withAnimation { viewModel.statusMessage = "" }
                                }
                        }

                        VStack(spacing: 3) {
                            if !selectedImage.title.isEmpty {
                                Text(selectedImage.title)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                            }
                            Text("\(selectedImage.width) × \(selectedImage.height)")
                                .font(.system(size: 11, design: .rounded))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())

                        imageActions(for: selectedImage)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .statusBarHidden()
        .onAppear {
            viewModel.statusMessage = ""
        }
        .animation(.easeInOut(duration: 0.2), value: viewModel.statusMessage)
        .navigationDestination(isPresented: Binding(get: { selectedDownloadedItem != nil }, set: { if !$0 { selectedDownloadedItem = nil } })) {
            if let item = selectedDownloadedItem { DownloadManagerContentView(highlightedItemID: item.id).navigationTitle(LanguageManager.shared.localizedString("downloads")) }
        }
    }

    private func imageActions(for image: WebImageResource) -> some View {
        let isDownloading = viewModel.activeResourceIDs.contains(image.id)
        return HStack(spacing: 4) {
            imageActionButton(
                titleKey: "save_to_photos",
                systemImage: "photo.badge.arrow.down",
                isLoading: isDownloading
            ) {
                Task {
                    await viewModel.download(
                        url: image.url,
                        preferredFilename: image.url.lastPathComponent,
                        saveToPhotos: true
                    )
                }
            }
            .disabled(isDownloading)

            if let item = finishedDownload(for: image.url) {
                imageActionButton(
                    titleKey: "open_downloads_folder",
                    systemImage: "folder.fill",
                    isLoading: false
                ) {
                    selectedDownloadedItem = item
                }
            } else {
                imageActionButton(
                    titleKey: "download",
                    systemImage: "arrow.down.circle",
                    isLoading: isDownloading
                ) {
                    Task { await viewModel.download(url: image.url) }
                }
                .disabled(isDownloading)
            }

            imageActionButton(
                titleKey: "copy_link",
                systemImage: "doc.on.doc",
                isLoading: false
            ) {
                UIPasteboard.general.string = image.url.absoluteString
                viewModel.statusMessage = LanguageManager.shared.localizedString("copied")
                HapticsManager.success()
            }

            ShareLink(item: image.url) {
                VStack(spacing: 5) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 20)
                    Text(LanguageManager.shared.localizedString("share"))
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func imageActionButton(
        titleKey: String,
        systemImage: String,
        isLoading: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Group {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .font(.system(size: 17, weight: .semibold))
                .frame(height: 20)

                Text(LanguageManager.shared.localizedString(titleKey))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func finishedDownload(for url: URL) -> BrowserDownloadItem? {
        downloadManager.finishedDownload(for: url)
    }
}

private struct WebResourceFullSizeImage: View {
    let resource: WebImageResource
    var onDismiss: () -> Void

    var body: some View {
        AsyncImage(url: resource.url) { phase in
            switch phase {
            case .success(let image):
                ZoomableImageSurface(image: image, onDismiss: onDismiss)
            case .failure:
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 36))
                    .foregroundStyle(.white.opacity(0.7))
            case .empty:
                ProgressView()
                    .tint(.white)
            @unknown default:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)

    }
}

struct WebResourceMediaPlayerView: View {
    @AppStorage(VideoPlaybackPreferences.showsWebDownloadControlsKey) private var showsVideoDownloadControls = true
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    let resource: WebMediaResource
    let pageURL: URL?
    let sourceWebView: WKWebView?
    let assetProvider: @MainActor () async -> AVURLAsset
    let downloadAction: @MainActor () async -> URL?
    var souloStartAt: Double?
    var souloPlaying = true
    var initialRate: Float?
    var initialFullscreenLandscape: Bool?
    var episodeList: WebEpisodeList?
    var showsEpisodes = false
    private var player: AVPlayer { MediaSession.shared.player }
    private let restoringPlayback: Bool
    private let embedded: Bool
    @State private var playbackContext: WebMediaPlaybackContext
    @State private var isDownloading = false
    @State private var isPreparing = true
    @State private var hasPreparedPlayer = false
    @State private var resolvedFullscreenLandscape: Bool?
    @State private var pendingInitialAsset: AVURLAsset?
    @State private var isPlaying = false
    @State private var playbackError = ""
    @State private var selectedDownloadedItem: BrowserDownloadItem?
    @State private var downloadedPlaybackURL: URL?
    @State private var useYouTubeWebPlayback = false
    @State private var playbackRequestID = UUID()
    @State private var directSouloSource: DownloadPlaybackSource?
    @State private var selectedResource: WebMediaResource?
    @State private var selectedEpisodeID: String?
    @State private var originalPlayingEpisodeID: String?
    @State private var selectedSourceID: String?
    @State private var resolvingEpisodeID: String?
    @State private var episodeFailure: String?
    @State private var episodeTask: Task<Void, Never>?
    @State private var episodeRequestID = UUID()
    @State private var failedEpisode: WebEpisode?
    @State private var showEpisodeFailure = false
    private var currentResource: WebMediaResource { selectedResource ?? resource }
    private var fullscreenLandscapeHint: Bool? { initialFullscreenLandscape ?? resolvedFullscreenLandscape }

    init(
        resource: WebMediaResource,
        pageURL: URL?,
        sourceWebView: WKWebView?,
        assetProvider: @escaping @MainActor () async -> AVURLAsset,
        downloadAction: @escaping @MainActor () async -> URL?,
        souloStartAt: Double? = nil,
        souloPlaying: Bool = true,
        initialRate: Float? = nil,
        initialFullscreenLandscape: Bool? = nil,
        preparedAsset: AVURLAsset? = nil,
        episodeList: WebEpisodeList? = nil,
        showsEpisodes: Bool = false,
        restoredContext: WebMediaPlaybackContext? = nil,
        embedded: Bool = false
    ) {
        self.resource = resource
        self.pageURL = pageURL
        self.sourceWebView = sourceWebView
        self.assetProvider = assetProvider
        self.downloadAction = downloadAction
        self.souloStartAt = souloStartAt
        self.souloPlaying = souloPlaying
        self.initialRate = initialRate
        self.initialFullscreenLandscape = initialFullscreenLandscape
        _pendingInitialAsset = State(initialValue: preparedAsset)
        self.episodeList = episodeList
        self.showsEpisodes = showsEpisodes
        self.restoringPlayback = restoredContext != nil
        self.embedded = embedded
        _playbackContext = State(initialValue: restoredContext ?? WebMediaPlaybackContext(
            resource: resource, pageURL: pageURL, sourceWebView: sourceWebView, episodeList: episodeList))
        _selectedEpisodeID = State(initialValue: restoredContext?.selectedEpisodeID)
        _selectedSourceID = State(initialValue: restoredContext?.selectedSourceID)
        _isPreparing = State(initialValue: restoredContext == nil)
        _hasPreparedPlayer = State(initialValue: restoredContext != nil)
    }

    @ViewBuilder var body: some View {
        if embedded { playerContent }
        else if resource.kind == .video {
            if let landscape = fullscreenLandscapeHint {
                let window = sourceWebView?.window
                let insets = window?.safeAreaInsets ?? .zero
                VideoFullscreenCanvas(landscape: landscape ? nil : false,
                    entryLandscapeDirection: landscape ? VideoOrientation.landscapePresentation(in: window?.windowScene) : nil,
                    insets: EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right),
                    identifier: "media.web.preparation.canvas") { insets in
                        playerContent.padding(insets)
                    }
                    .preferredColorScheme(.dark)
                    .statusBarHidden()
            } else {
                playerContent
                    .background(Color.black.ignoresSafeArea())
                    .preferredColorScheme(.dark)
            }
        }
        else { NavigationStack { playerContent } }
    }

    private var playerContent: some View {
            VStack(spacing: 0) {
                ZStack {
                    if useYouTubeWebPlayback, let youtubeEmbedURL {
                        YouTubeWebPlaybackView(
                            url: youtubeEmbedURL,
                            sourceWebView: sourceWebView,
                            isLoading: $isPreparing,
                            errorMessage: $playbackError
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                    } else if hasPreparedPlayer {
                        MediaPlaybackContent(initialSouloPlayback: directSouloSource != nil
                                                ? (time: selectedEpisodeID == nil ? (souloStartAt ?? 0) : 0,
                                                   playing: selectedEpisodeID == nil ? souloPlaying : true) : nil,
                                             initialSouloSource: directSouloSource,
                                             initialRate: selectedEpisodeID == nil ? initialRate : nil,
                                             restoredSoulo: restoringPlayback ? MediaSession.shared.soulo : nil,
                                             initialFullscreen: currentResource.kind == .video,
                                             initialFullscreenLandscape: fullscreenLandscapeHint,
                                             fullscreenOnly: currentResource.kind == .video,
                                             initialSystemPlayer: restoringPlayback && directSouloSource == nil
                                                 && MediaSession.shared.soulo == nil,
                                             initialEpisodes: showsEpisodes,
                                             initialTitle: currentResource.title, audioOnly: currentResource.kind == .audio,
                                             ownsExplicitSource: true, externalPlaylist: videoPlaylist,
                                             onFullscreenClose: { episodeTask?.cancel(); dismiss() },
                                             downloadAction: { downloadCurrentMedia() },
                                             downloadIsVideo: currentResource.kind == .video)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                    } else { Color.black }

                    if isPreparing || (resource.kind == .video && !useYouTubeWebPlayback && playbackError.isEmpty) {
                        ProgressView()
                            .tint(.white)
                            .accessibilityIdentifier("media.web.preparing")
                    } else if !playbackError.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "play.slash.fill")
                                .font(.system(size: 34))
                            Text(playbackError)
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                            Button(LanguageManager.shared.localizedString("retry")) {
                                retryPlayback()
                            }
                            .buttonStyle(.bordered)
                        }
                        .foregroundStyle(.white)
                        .padding(24)
                    }
                }

                // Media URLs remain available through Share; video playback has
                // only fullscreen chrome, never a URL-bearing preview page.
                if currentResource.kind != .video && !hasPreparedPlayer {
                    HStack(spacing: 12) {
                        Button {
                            UIPasteboard.general.string = currentResource.url.absoluteString
                            HapticsManager.success()
                        } label: {
                            Text(currentResource.url.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(LanguageManager.shared.localizedString("copy_link"))
                        .accessibilityValue(currentResource.url.absoluteString)
                        .accessibilityIdentifier("media.copy-url")

                        Spacer(minLength: 0)
                    }
                    .padding()
                }

                if currentResource.kind != .video, let item = activeDownload {
                    Button {
                        selectedDownloadedItem = item
                    } label: {
                        VStack(spacing: 5) {
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                            Text("\(Int((item.progress * 100).rounded()))%")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .accessibilityLabel(LanguageManager.shared.localizedString("downloads"))
                } else if currentResource.kind != .video, isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 12)
                }
            }
            .overlay(alignment: .top) {
                if resource.kind == .video, !embedded {
                    HStack(spacing: 12) {
                        VideoFullscreenBackTitle(title: currentResource.title, identifier: "media.web.close") {
                            episodeTask?.cancel(); dismiss()
                        }
                        Spacer(minLength: 0)
                        if !playbackError.isEmpty || useYouTubeWebPlayback {
                            mediaActions
                                .frame(minWidth: 44, minHeight: 44)
                        }
                    }
                    .foregroundStyle(.white).padding(12)
                }
            }
            .navigationTitle(
                LanguageManager.shared.localizedString(
                    currentResource.kind == .video ? "resource_video_player" : "resource_audio_player"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(currentResource.kind == .audio && hasPreparedPlayer ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    mediaActions
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { episodeTask?.cancel(); dismiss() }
                        .accessibilityIdentifier("media.web.close")
                }
            }
            .task {
                if restoringPlayback { storePlaybackContext() }
                else { await prepareAndPlay() }
            }
            .onDisappear { storePlaybackContext(); playbackRequestID = UUID(); episodeRequestID = UUID(); episodeTask?.cancel() }
            .alert(ToolText.text("media_unavailable"), isPresented: Binding(
                get: { showEpisodeFailure && (currentResource.kind != .video || useYouTubeWebPlayback) },
                set: { showEpisodeFailure = $0 }
            )) {
                if let episode = failedEpisode {
                    Button(ToolText.text("retry")) { selectEpisode(episode) }
                }
                Button(ToolText.text("done"), role: .cancel) { }
            } message: { Text(episodeFailure ?? ToolText.text("media_unavailable")) }
            .onCompatibleChange(of: selectedSourceID) { _, _ in storePlaybackContext() }
            .onCompatibleChange(of: episodeList) { _, _ in storePlaybackContext() }
            .onCompatibleChange(of: playbackError) { _, error in
                guard !error.isEmpty, failedEpisode == nil, let selectedEpisodeID,
                      let episode = playbackContext.episodeList?.sources.flatMap(\.episodes).first(where: { $0.id == selectedEpisodeID }) else { return }
                failedEpisode = episode; episodeFailure = episode.title + " · " + error; showEpisodeFailure = true
            }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                isPlaying = status == .playing
            }
            .onReceive(player.publisher(for: \.status)) { status in
                guard directSouloSource == nil, status == .failed else { return }
                if activateYouTubeWebPlaybackIfAvailable() { return }
                playbackError = player.error?.localizedDescription
                    ?? AppLocalization.string("resource_download_invalid_response")
                isPreparing = false
            }
            .onReceive(MediaSession.shared.$error) { error in
                guard let error, !useYouTubeWebPlayback,
                      let currentURL = MediaSession.shared.url,
                      currentURL == currentResource.url || currentURL == downloadedPlaybackURL
                        || currentURL == finishedDownload?.localURL else { return }
                if activateYouTubeWebPlaybackIfAvailable() { return }
                playbackError = error
                isPreparing = false
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { notification in
                guard let failedItem = notification.object as? AVPlayerItem,
                      failedItem === player.currentItem else { return }
                if activateYouTubeWebPlaybackIfAvailable() { return }
                playbackError = player.currentItem?.error?.localizedDescription
                    ?? AppLocalization.string("resource_download_invalid_response")
                isPreparing = false
            }

            .navigationDestination(isPresented: Binding(get: { (resource.kind != .video || embedded) && selectedDownloadedItem != nil }, set: { if !$0 { selectedDownloadedItem = nil } })) {
                if let item = selectedDownloadedItem { DownloadManagerContentView(highlightedItemID: item.id).navigationTitle(LanguageManager.shared.localizedString("downloads")) }
            }
            .sheet(item: Binding(get: { resource.kind == .video && !embedded ? selectedDownloadedItem : nil }, set: { selectedDownloadedItem = $0 })) { item in
                NavigationStack {
                    DownloadManagerContentView(highlightedItemID: item.id)
                        .navigationTitle(LanguageManager.shared.localizedString("downloads"))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(ToolText.text("done")) { selectedDownloadedItem = nil }
                            }
                        }
                }
            }
    }

    @ViewBuilder private var mediaActions: some View {
        ShareLink(item: currentResource.url) {
            Image(systemName: "square.and.arrow.up")
        }
        .accessibilityLabel(LanguageManager.shared.localizedString("share"))

        if let item = finishedDownload {
            Button { selectedDownloadedItem = item } label: { Image(systemName: "folder.fill") }
                .accessibilityLabel(LanguageManager.shared.localizedString("open_downloads_folder"))
        } else if let item = activeDownload {
            Button { selectedDownloadedItem = item } label: {
                Image(systemName: item.status == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
            }
            .accessibilityLabel(LanguageManager.shared.localizedString("downloads"))
        } else if currentResource.kind != .video || showsVideoDownloadControls {
            Button { downloadCurrentMedia(activateDownloaded: true) } label: {
                if isDownloading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.down.circle") }
            }
            .disabled(isDownloading)
            .accessibilityLabel(LanguageManager.shared.localizedString("download"))
            .accessibilityIdentifier("media.web.download")
        }
    }

    private func storePlaybackContext() {
        playbackContext.resource = currentResource
        playbackContext.updateEpisodeList(episodeList)
        playbackContext.selectedEpisodeID = selectedEpisodeID
        playbackContext.selectedSourceID = selectedSourceID
    }

    private func sourceForPlayback(asset: AVURLAsset, pageURL: URL?) -> DownloadPlaybackSource {
        storePlaybackContext()
        let source = DownloadPlaybackSource(asset: asset, pageURL: pageURL, webView: sourceWebView)
        source.webMediaContext = playbackContext
        return source
    }

    private var videoPlaylist: FileVideoPlaylist? {
        guard let list = episodeList.flatMap({ playbackContext.accepts($0) ? $0 : nil }) ?? playbackContext.episodeList,
              let source = list.sources.first(where: { $0.id == selectedSourceID })
                ?? list.sources.first(where: { group in group.episodes.contains { episode in
                    episode.matchesCurrentPage(currentResource.url)
                        || (currentResource.sourcePageURL.map { episode.matchesCurrentPage($0) } ?? false)
                } }) ?? list.currentSource else { return nil }
        let currentID: String
        if let playingID = selectedEpisodeID ?? originalPlayingEpisodeID {
            currentID = source.episodes.contains(where: { $0.id == playingID }) ? playingID : ""
        } else {
            currentID = source.episodes.first { episode in
                episode.matchesCurrentPage(currentResource.url)
                    || (currentResource.sourcePageURL.map { episode.matchesCurrentPage($0) } ?? false)
            }?.id ?? (selectedSourceID == nil ? source.episodes.first { $0.matchesCurrentPage(list.pageURL) }?.id : nil) ?? ""
        }
        return FileVideoPlaylist(episodes: source.episodes.map { FileVideoEpisode(id: $0.id, title: $0.title) },
            selectedID: currentID, sources: list.sources.enumerated().map { index, source in
                .init(id: source.id, title: source.title.isEmpty ? "\(ToolText.text("episodes_source")) \(index + 1)" : source.title)
            },
            selectedSourceID: source.id, selectSource: {
                episodeTask?.cancel(); episodeRequestID = UUID(); resolvingEpisodeID = nil
                selectedSourceID = $0; episodeFailure = nil; failedEpisode = nil; showEpisodeFailure = false
                #if SOULO_ACCEPTANCE
                NSLog("[SouloEpisodeSource] selected %@", $0)
                #endif
            },
            asynchronous: true, resolvingID: resolvingEpisodeID, failure: episodeFailure,
            retry: failedEpisode.map { episode in { selectEpisode(episode) } }) { id in
                guard let episode = source.episodes.first(where: { $0.id == id }) else { return }
                if id == currentID && playbackError.isEmpty && episodeFailure == nil { return }
                selectEpisode(episode, currentID: currentID)
            }
    }

    private func selectEpisode(_ episode: WebEpisode, currentID: String? = nil) {
        guard resolvingEpisodeID != episode.id else { return }
        if selectedEpisodeID == nil, originalPlayingEpisodeID == nil, let currentID, !currentID.isEmpty {
            // SPA controls can update the webpage's selection before the native
            // player has switched. Keep the marker on the actual player source.
            originalPlayingEpisodeID = currentID
        }
        episodeTask?.cancel()
        let requestID = UUID(); episodeRequestID = requestID
        resolvingEpisodeID = episode.id; episodeFailure = nil; failedEpisode = nil; showEpisodeFailure = false
        episodeTask = Task { @MainActor in
            defer { if episodeRequestID == requestID { resolvingEpisodeID = nil; episodeTask = nil } }
            do {
                let media: WebMediaResource
                if let direct = episode.directMediaResource { media = direct }
                else if let sourceWebView {
                    if episode.action != nil {
                        media = try await WebEpisodeRuntime.resolveActionMedia(episode, in: sourceWebView,
                            timeout: 20, excluding: currentResource.url)
                    } else {
                        let resolver = WebEpisodeMediaResolver(episode: episode, sourceView: sourceWebView)
                        defer { resolver.invalidate() }
                        media = try await resolver.resolve()
                    }
                } else { throw CocoaError(.fileReadUnsupportedScheme) }
                try Task.checkCancellation()
                let asset = await WebResourceMediaService.asset(for: media, webView: sourceWebView, cacheForPlayback: true)
                try Task.checkCancellation()
                guard episodeRequestID == requestID else { return }
                // Publish the new episode metadata before constructing the
                // decoder's retained context; otherwise it contains the old URL.
                selectedResource = WebMediaResource(kind: media.kind, url: media.url, title: episode.title,
                    posterURL: media.posterURL, delivery: media.delivery, companionAudioURL: media.companionAudioURL,
                    sourcePageURL: media.sourcePageURL ?? episode.url)
                selectedEpisodeID = episode.id
                downloadedPlaybackURL = nil; playbackError = ""
                storePlaybackContext()
                if MediaSession.shared.soulo == nil {
                    MediaSession.shared.open(url: media.url, title: episode.title,
                        pageURL: media.sourcePageURL ?? episode.url, asset: asset, webView: sourceWebView,
                        downloadSource: sourceForPlayback(asset: asset, pageURL: media.sourcePageURL ?? episode.url), startAt: 0)
                    directSouloSource = nil
                } else {
                    directSouloSource = sourceForPlayback(asset: asset, pageURL: media.sourcePageURL ?? episode.url)
                }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, episodeRequestID == requestID else { return }
                let message = error is WebEpisodeDownloadError ? ToolText.text("media_unavailable") : error.localizedDescription
                episodeFailure = episode.title + " · " + message
                failedEpisode = episode; showEpisodeFailure = true
            }
        }
    }

    @MainActor
    private func prepareAndPlay(localURL: URL? = nil) async {
        let requestID = UUID(); playbackRequestID = requestID
        let reservation = MediaSession.shared.reservePreparation()
        isPreparing = true
        playbackError = ""
        let resolvedLocalURL = localURL ?? downloadedPlaybackURL ?? finishedDownload?.localURL
        if requiresDownloadedPlayback, resolvedLocalURL == nil {
            if !activateYouTubeWebPlaybackIfAvailable() {
                MediaSession.shared.stop()
                playbackError = AppLocalization.string("resource_stream_playback_download_first")
                isPreparing = false
            }
            return
        }
        useYouTubeWebPlayback = false
        let prepared = pendingInitialAsset
        pendingInitialAsset = nil
        let asset: AVURLAsset
        if let resolvedLocalURL {
            do {
                if resolvedLocalURL.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
                    asset = try OfflineHLSReference.playableAsset(for: resolvedLocalURL)
                } else if resolvedLocalURL.pathExtension.lowercased() == "movpkg" {
                    asset = try OfflineHLSReference.playablePackage(at: resolvedLocalURL)
                } else { asset = AVURLAsset(url: resolvedLocalURL) }
            } catch {
                playbackError = error.localizedDescription; isPreparing = false; return
            }
        } else if selectedResource == nil, let prepared {
            asset = prepared
        } else {
            asset = selectedResource != nil ? await WebResourceMediaService.asset(for: currentResource, webView: sourceWebView, cacheForPlayback: true)
                : await assetProvider()
        }
        guard !Task.isCancelled, playbackRequestID == requestID, MediaSession.shared.ownsPreparation(reservation) else { return }
        if !embedded, currentResource.kind == .video, initialFullscreenLandscape == nil,
           UIDevice.current.userInterfaceIdiom == .phone {
            let size = await MediaSession.videoTrackDisplaySize(in: asset)
            guard !Task.isCancelled, playbackRequestID == requestID, MediaSession.shared.ownsPreparation(reservation) else { return }
            resolvedFullscreenLandscape = size.flatMap(MediaSession.fullscreenLandscape(for:))
        }
        directSouloSource = sourceForPlayback(asset: asset, pageURL: pageURL)
        hasPreparedPlayer = true
        isPreparing = false
    }

    private func retryPlayback() {
        useYouTubeWebPlayback = false
        Task { await prepareAndPlay() }
    }

    @discardableResult
    private func activateYouTubeWebPlaybackIfAvailable() -> Bool {
        guard currentResource.delivery == .youtubeSABR, youtubeEmbedURL != nil else { return false }
        MediaSession.shared.stop()
        playbackError = ""
        isPreparing = true
        useYouTubeWebPlayback = true
        return true
    }

    private var youtubeEmbedURL: URL? {
        WebResourceMediaService.youtubeEmbedURL(for: currentResource.url)
            ?? pageURL.flatMap { WebResourceMediaService.youtubeEmbedURL(for: $0) }
    }

    private func downloadCurrentMedia(activateDownloaded: Bool = false) {
        guard !isDownloading, activeDownload == nil else { return }
        isDownloading = true
        let resourceID = currentResource.id
        Task { @MainActor in
            defer { isDownloading = false }
            let localURL = selectedResource != nil
                ? try? await WebResourceDownloadService.shared.download(currentResource,
                    pageURL: currentResource.sourcePageURL ?? pageURL, webView: sourceWebView)
                : await downloadAction()
            guard currentResource.id == resourceID else { return }
            if activateDownloaded, let localURL {
                downloadedPlaybackURL = localURL
                useYouTubeWebPlayback = false
                await prepareAndPlay(localURL: localURL)
            }
        }
    }

    private var activeDownload: BrowserDownloadItem? {
        downloadManager.activeDownload(for: downloadIdentityURL)
    }

    private var finishedDownload: BrowserDownloadItem? {
        downloadManager.finishedDownload(for: downloadIdentityURL)
    }

    private var downloadIdentityURL: URL {
        WebResourceMediaService.downloadIdentityURL(
            for: currentResource,
            pageURL: pageURL
        )
    }

    private var requiresDownloadedPlayback: Bool {
        currentResource.delivery == .separateTracks
            || currentResource.delivery == .youtubeSABR
    }
}

private struct YouTubeWebPlaybackView: UIViewRepresentable {
    let url: URL
    let sourceWebView: WKWebView?
    @Binding var isLoading: Bool
    @Binding var errorMessage: String

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, errorMessage: $errorMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sourceWebView?.configuration.websiteDataStore ?? .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = sourceWebView?.customUserAgent ?? AppConstants.mobileWebViewUserAgent
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        load(url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL != url else { return }
        load(url, in: webView, coordinator: context.coordinator)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private func load(_ url: URL, in webView: WKWebView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        var request = URLRequest(url: url)
        request.setValue("https://m.youtube.com/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var isLoading: Bool
        @Binding private var errorMessage: String
        var loadedURL: URL?

        init(isLoading: Binding<Bool>, errorMessage: Binding<String>) {
            _isLoading = isLoading
            _errorMessage = errorMessage
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            errorMessage = ""
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            errorMessage = ""
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading = false
            errorMessage = error.localizedDescription
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }
}
