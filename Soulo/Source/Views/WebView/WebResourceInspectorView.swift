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

    init(webViewModel: WebViewModel) {
        self.webViewModel = webViewModel
    }

    func inspect() async {
        isLoading = true
        errorMessage = ""
        defer { isLoading = false }
        do {
            snapshot = try await WebResourceInspectionService.inspect(
                webView: webViewModel?.webView
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
                pageURL: snapshot.pageURL,
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

    func playbackAsset(for resource: WebMediaResource) async -> AVURLAsset {
        await WebResourceMediaService.asset(
            for: resource,
            webView: webViewModel?.webView
        )
    }
}

struct WebResourceInspectorView: View {
    private enum ResourceSection: Hashable {
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
    @State private var expandedSections: Set<ResourceSection> = [.images, .videos]
    @State private var minimumImageWidth = WebResourceInspectorDefaults.minimumImageWidth
    @State private var unavailableImageIDs = Set<String>()
    @State private var selectedImage: WebImageResource?
    @State private var selectedMedia: WebMediaResource?
    @State private var selectedDownloadedItem: BrowserDownloadItem?
    @State private var audioPlayer: AVPlayer?
    @State private var activeAudioID: String?
    @State private var isAudioPlaying = false

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
            } else if viewModel.snapshot.isEmpty {
                emptyView
            } else {
                resourcesView
            }
        }
        .navigationTitle(LanguageManager.shared.localizedString("resource_inspector_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(LanguageManager.shared.localizedString("done")) { dismiss() }
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
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.isLoading)
                .accessibilityLabel(LanguageManager.shared.localizedString("resource_rescan"))
            }
        }
        .task {
            downloadManager.removeMissingFiles()
            if viewModel.snapshot.isEmpty {
                await viewModel.inspect()
            }
        }
        .sheet(item: $selectedMedia) { media in
            WebResourceMediaPlayerView(
                resource: media,
                pageURL: viewModel.snapshot.pageURL,
                sourceWebView: viewModel.sourceWebView,
                assetProvider: { await viewModel.playbackAsset(for: media) },
                downloadAction: { await viewModel.download(media: media) }
            )
        }
        .sheet(item: $selectedDownloadedItem) { item in
            DownloadManagerView(highlightedItemID: item.id)
        }
        .fullScreenCover(item: $selectedImage) { image in
            WebResourceImageViewer(
                images: filteredImages,
                initialImageID: image.id,
                viewModel: viewModel
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem === audioPlayer?.currentItem else { return }
            audioPlayer?.seek(to: .zero)
            isAudioPlaying = false
        }
        .onDisappear {
            stopInlineAudio()
        }
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

    private var resourcesView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if !viewModel.snapshot.videos.isEmpty {
                    resourceSection(
                        .videos,
                        titleKey: "resource_videos",
                        systemImage: "play.rectangle.fill",
                        count: viewModel.snapshot.videos.count
                    ) {
                        videoRows
                    }
                }

                if !viewModel.snapshot.audio.isEmpty {
                    resourceSection(
                        .audio,
                        titleKey: "resource_audio",
                        systemImage: "waveform",
                        count: viewModel.snapshot.audio.count
                    ) {
                        audioRows
                    }
                }

                if !viewModel.snapshot.images.isEmpty {
                    resourceSection(
                        .images,
                        titleKey: "resource_images",
                        systemImage: "photo.on.rectangle.angled",
                        count: filteredImages.count
                    ) {
                        imageWidthFilter
                        imageGrid
                    }
                }

                if !viewModel.snapshot.documents.isEmpty {
                    resourceSection(
                        .documents,
                        titleKey: "resource_documents",
                        systemImage: "doc.on.doc.fill",
                        count: viewModel.snapshot.documents.count
                    ) {
                        documentRows
                    }
                }

                if !viewModel.snapshot.textFragments.isEmpty {
                    resourceSection(
                        .text,
                        titleKey: "resource_text_fragments",
                        systemImage: "text.quote",
                        count: viewModel.snapshot.textFragments.count
                    ) {
                        copyAndShareAllButtons(
                            titleKey: "resource_copy_all_text",
                            value: viewModel.snapshot.textFragments.map(\.text).joined(separator: "\n\n")
                        )
                        textRows
                    }
                }

                if !viewModel.snapshot.colors.isEmpty {
                    resourceSection(
                        .colors,
                        titleKey: "resource_colors",
                        systemImage: "paintpalette.fill",
                        count: viewModel.snapshot.colors.count
                    ) {
                        colorGrid
                    }
                }

                if !viewModel.snapshot.links.isEmpty {
                    resourceSection(
                        .links,
                        titleKey: "resource_links",
                        systemImage: "link",
                        count: viewModel.snapshot.links.count
                    ) {
                        copyAndShareAllButtons(
                            titleKey: "resource_copy_all_links",
                            value: viewModel.snapshot.links.map(\.url.absoluteString).joined(separator: "\n")
                        )
                        linkRows
                    }
                }
            }
            .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func resourceSection<Content: View>(
        _ section: ResourceSection,
        titleKey: String,
        systemImage: String,
        count: Int,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                if expandedSections.contains(section) {
                    expandedSections.remove(section)
                } else {
                    expandedSections.insert(section)
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                    Text(LanguageManager.shared.localizedString(titleKey))
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expandedSections.contains(section) ? 0 : -90))
                        .animation(.easeInOut(duration: 0.16), value: expandedSections.contains(section))
                }
                .foregroundStyle(.primary)
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expandedSections.contains(section) {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 10) {
                    content()
                }
                .padding(14)
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
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
                    .foregroundStyle(.blue)
            }
            Slider(value: $minimumImageWidth, in: 0...maximumImageWidth, step: 20)
                .accessibilityLabel(LanguageManager.shared.localizedString("resource_minimum_image_width"))
        }
    }

    private var imageGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118, maximum: 180), spacing: 10)], spacing: 10) {
            ForEach(filteredImages) { image in
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        selectedImage = image
                    } label: {
                        WebResourceImagePreview(resource: image) {
                            unavailableImageIDs.insert(image.id)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 124)
                        .background(Color(uiColor: .tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(imageAccessibilityLabel(image))

                    HStack(spacing: 5) {
                        Text(image.width > 0 ? "\(image.width) × \(image.height)" : image.url.host ?? "")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        resourceDownloadMenu(for: image)
                    }
                }
                .padding(8)
                .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
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
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16))
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
                                assetProvider: { await viewModel.playbackAsset(for: resource) },
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

                    HStack(spacing: 8) {
                        resourceText(title: resource.title, url: resource.url)
                        Spacer(minLength: 4)
                        mediaResourceActions(for: resource)
                    }
                }
                .padding(9)
                .background(
                    Color(uiColor: .tertiarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
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
                            .background(Color.blue, in: Circle())
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
        if activeAudioID == resource.id, let audioPlayer {
            if isAudioPlaying {
                audioPlayer.pause()
                isAudioPlaying = false
            } else {
                audioPlayer.play()
                isAudioPlaying = true
            }
            return
        }

        audioPlayer?.pause()
        let player = AVPlayer(url: resource.url)
        audioPlayer = player
        activeAudioID = resource.id
        isAudioPlaying = true
        player.play()
    }

    private func stopInlineAudio() {
        audioPlayer?.pause()
        audioPlayer = nil
        activeAudioID = nil
        isAudioPlaying = false
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
            } else {
                Button {
                    viewModel.startDownload(media: resource)
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 16))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LanguageManager.shared.localizedString("download"))
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
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.links) { resource in
                HStack(spacing: 6) {
                    Button {
                        copyToPasteboard(resource.url.absoluteString)
                    } label: {
                        HStack(spacing: 10) {
                        Image(systemName: "link")
                            .foregroundStyle(.blue)
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
                if resource.id != viewModel.snapshot.links.last?.id { Divider() }
            }
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
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 18))
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
            Image(systemName: "doc.on.doc")
                .font(.system(size: 16))
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
                    .frame(width: 40, height: 30)
                } else {
                    Image(systemName: item.status == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                        .font(.system(size: 17))
                        .frame(width: 30, height: 30)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LanguageManager.shared.localizedString("downloads"))
            .accessibilityValue("\(Int((item.progress * 100).rounded()))%")
        } else {
            ProgressView()
                .controlSize(.small)
                .frame(width: 30, height: 30)
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
            Image(systemName: "folder.fill")
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("open_downloads_folder"))
    }

    private func shareURLButton(_ url: URL) -> some View {
        ShareLink(item: url) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LanguageManager.shared.localizedString("share"))
    }

    private func shareTextButton(_ value: String) -> some View {
        ShareLink(item: value) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14))
                .frame(width: 30, height: 30)
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
        ContentUnavailableView {
            ProgressView()
        } description: {
            Text(LanguageManager.shared.localizedString("resource_scanning"))
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            LanguageManager.shared.localizedString("resource_none_found"),
            systemImage: "doc.text.magnifyingglass",
            description: Text(LanguageManager.shared.localizedString("resource_none_found_desc"))
        )
    }

    private var errorView: some View {
        ContentUnavailableView {
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
                    WebResourceFullSizeImage(resource: image)
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
        .sheet(item: $selectedDownloadedItem) { item in
            DownloadManagerView(highlightedItemID: item.id)
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

    var body: some View {
        AsyncImage(url: resource.url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFit()
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
        .padding(.horizontal, 8)
        .padding(.vertical, 64)
    }
}

private struct WebResourceMediaPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var downloadManager = DownloadManagerService.shared
    let resource: WebMediaResource
    let pageURL: URL?
    let sourceWebView: WKWebView?
    let assetProvider: @MainActor () async -> AVURLAsset
    let downloadAction: @MainActor () async -> URL?
    @State private var player = AVPlayer()
    @State private var isDownloading = false
    @State private var isPreparing = true
    @State private var isPlaying = false
    @State private var playbackError = ""
    @State private var selectedDownloadedItem: BrowserDownloadItem?
    @State private var downloadedPlaybackURL: URL?
    @State private var useYouTubeWebPlayback = false

    init(
        resource: WebMediaResource,
        pageURL: URL?,
        sourceWebView: WKWebView?,
        assetProvider: @escaping @MainActor () async -> AVURLAsset,
        downloadAction: @escaping @MainActor () async -> URL?
    ) {
        self.resource = resource
        self.pageURL = pageURL
        self.sourceWebView = sourceWebView
        self.assetProvider = assetProvider
        self.downloadAction = downloadAction
    }

    var body: some View {
        NavigationStack {
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
                    } else {
                        VideoPlayer(player: player)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.black)
                    }

                    if isPreparing {
                        ProgressView()
                            .tint(.white)
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

                HStack(spacing: 12) {
                    if !useYouTubeWebPlayback {
                        Button {
                            togglePlayback()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isPreparing || !playbackError.isEmpty)
                        .accessibilityLabel(
                            LanguageManager.shared.localizedString(
                                isPlaying ? "pause" : "resource_video_player"
                            )
                        )
                    }

                    Text(resource.url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)
                }
                .padding()

                if let item = activeDownload {
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
                } else if isDownloading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle(
                LanguageManager.shared.localizedString(
                    resource.kind == .video ? "resource_video_player" : "resource_audio_player"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    ShareLink(item: resource.url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(LanguageManager.shared.localizedString("share"))

                    if let item = finishedDownload {
                        Button {
                            selectedDownloadedItem = item
                        } label: {
                            Image(systemName: "folder.fill")
                        }
                        .accessibilityLabel(
                            LanguageManager.shared.localizedString("open_downloads_folder")
                        )
                    } else if let item = activeDownload {
                        Button {
                            selectedDownloadedItem = item
                        } label: {
                            Image(systemName: item.status == .paused ? "pause.circle.fill" : "arrow.down.circle.fill")
                        }
                        .accessibilityLabel(LanguageManager.shared.localizedString("downloads"))
                    } else {
                        Button {
                            guard !isDownloading else { return }
                            isDownloading = true
                            Task {
                                let localURL = await downloadAction()
                                downloadedPlaybackURL = localURL
                                isDownloading = false
                                if let localURL {
                                    useYouTubeWebPlayback = false
                                    await prepareAndPlay(localURL: localURL)
                                }
                            }
                        } label: {
                            if isDownloading {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .disabled(isDownloading)
                        .accessibilityLabel(LanguageManager.shared.localizedString("download"))
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
            .task { await prepareAndPlay() }
            .onReceive(player.publisher(for: \.timeControlStatus)) { status in
                isPlaying = status == .playing
            }
            .onReceive(player.publisher(for: \.status)) { status in
                guard status == .failed else { return }
                if activateYouTubeWebPlaybackIfAvailable() { return }
                playbackError = player.error?.localizedDescription
                    ?? AppLocalization.string("resource_download_invalid_response")
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
            .onDisappear { player.pause() }
            .sheet(item: $selectedDownloadedItem) { item in
                DownloadManagerView(highlightedItemID: item.id)
            }
        }
    }

    @MainActor
    private func prepareAndPlay(localURL: URL? = nil) async {
        isPreparing = true
        playbackError = ""
        let resolvedLocalURL = localURL ?? downloadedPlaybackURL ?? finishedDownload?.localURL
        if requiresDownloadedPlayback, resolvedLocalURL == nil {
            if !activateYouTubeWebPlaybackIfAvailable() {
                player.replaceCurrentItem(with: nil)
                playbackError = AppLocalization.string("resource_stream_playback_download_first")
                isPreparing = false
            }
            return
        }
        useYouTubeWebPlayback = false
        let asset: AVURLAsset
        if let resolvedLocalURL {
            asset = AVURLAsset(url: resolvedLocalURL)
        } else {
            asset = await assetProvider()
        }
        do {
            guard try await asset.load(.isPlayable) else {
                throw WebResourceDownloadError.invalidResponse
            }
            let item = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: item)
            player.play()
        } catch {
            player.replaceCurrentItem(with: nil)
            if resolvedLocalURL != nil || !activateYouTubeWebPlaybackIfAvailable() {
                playbackError = error.localizedDescription
            }
        }
        if !useYouTubeWebPlayback {
            isPreparing = false
        }
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func retryPlayback() {
        useYouTubeWebPlayback = false
        Task { await prepareAndPlay() }
    }

    @discardableResult
    private func activateYouTubeWebPlaybackIfAvailable() -> Bool {
        guard resource.delivery == .youtubeSABR, youtubeEmbedURL != nil else { return false }
        player.pause()
        player.replaceCurrentItem(with: nil)
        playbackError = ""
        isPreparing = true
        useYouTubeWebPlayback = true
        return true
    }

    private var youtubeEmbedURL: URL? {
        WebResourceMediaService.youtubeEmbedURL(for: resource.url)
            ?? pageURL.flatMap { WebResourceMediaService.youtubeEmbedURL(for: $0) }
    }

    private var activeDownload: BrowserDownloadItem? {
        downloadManager.activeDownload(for: downloadIdentityURL)
    }

    private var finishedDownload: BrowserDownloadItem? {
        downloadManager.finishedDownload(for: downloadIdentityURL)
    }

    private var downloadIdentityURL: URL {
        WebResourceMediaService.downloadIdentityURL(
            for: resource,
            pageURL: pageURL
        )
    }

    private var requiresDownloadedPlayback: Bool {
        resource.delivery == .separateTracks
            || resource.delivery == .youtubeSABR
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
