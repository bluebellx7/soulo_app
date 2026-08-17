import AVKit
import SwiftUI

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
    @State private var expandedSections: Set<ResourceSection> = [.images, .videos]
    @State private var minimumImageWidth = WebResourceInspectorDefaults.minimumImageWidth
    @State private var unavailableImageIDs = Set<String>()
    @State private var selectedImage: WebImageResource?
    @State private var selectedMedia: WebMediaResource?
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
            if viewModel.snapshot.isEmpty {
                await viewModel.inspect()
            }
        }
        .sheet(item: $selectedMedia) { media in
            WebResourceMediaPlayerView(resource: media)
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

                if !viewModel.snapshot.videos.isEmpty {
                    resourceSection(
                        .videos,
                        titleKey: "resource_videos",
                        systemImage: "play.rectangle.fill",
                        count: viewModel.snapshot.videos.count
                    ) {
                        mediaRows(viewModel.snapshot.videos)
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
                        copyAllButton(
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
                        copyAllButton(
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
                ProgressView().controlSize(.small)
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

    private func mediaRows(_ resources: [WebMediaResource]) -> some View {
        VStack(spacing: 0) {
            ForEach(resources) { resource in
                HStack(spacing: 10) {
                    Button {
                        selectedMedia = resource
                    } label: {
                        Image(systemName: resource.kind == .video ? "play.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Color.blue, in: Circle())
                    }
                    .buttonStyle(.plain)

                    resourceText(title: resource.title, url: resource.url)
                    Spacer(minLength: 4)
                    copyResourceURLButton(url: resource.url)
                }
                .padding(.vertical, 8)
                if resource.id != resources.last?.id { Divider() }
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
                    copyResourceURLButton(url: resource.url)
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

    private var documentRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.documents) { resource in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill")
                        .foregroundStyle(.orange)
                        .frame(width: 30)
                    resourceText(title: resource.title, url: resource.url)
                    Spacer(minLength: 4)
                    downloadButton(url: resource.url)
                }
                .padding(.vertical, 8)
                if resource.id != viewModel.snapshot.documents.last?.id { Divider() }
            }
        }
    }

    private var linkRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.links) { resource in
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
                if resource.id != viewModel.snapshot.links.last?.id { Divider() }
            }
        }
    }

    private var textRows: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.snapshot.textFragments) { resource in
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
                            Text("×\(resource.count)")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .padding(7)
                    .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyAllButton(titleKey: String, value: String) -> some View {
        Button {
            copyToPasteboard(value)
        } label: {
            Label(LanguageManager.shared.localizedString(titleKey), systemImage: "doc.on.doc.fill")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func downloadButton(url: URL) -> some View {
        Button {
            Task { await viewModel.download(url: url) }
        } label: {
            if viewModel.activeResourceIDs.contains(url.absoluteString) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 18))
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.activeResourceIDs.contains(url.absoluteString))
        .accessibilityLabel(LanguageManager.shared.localizedString("download"))
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

private struct WebResourceImageViewer: View {
    @Environment(\.dismiss) private var dismiss
    let images: [WebImageResource]
    @ObservedObject var viewModel: WebResourceInspectorViewModel
    @State private var selectedImageID: String

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

            imageActionButton(
                titleKey: "download",
                systemImage: "arrow.down.circle",
                isLoading: isDownloading
            ) {
                Task { await viewModel.download(url: image.url) }
            }
            .disabled(isDownloading)

            imageActionButton(
                titleKey: "copy_link",
                systemImage: "doc.on.doc",
                isLoading: false
            ) {
                UIPasteboard.general.string = image.url.absoluteString
                viewModel.statusMessage = LanguageManager.shared.localizedString("copied")
                HapticsManager.success()
            }
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
    let resource: WebMediaResource
    @State private var player: AVPlayer

    init(resource: WebMediaResource) {
        self.resource = resource
        _player = State(initialValue: AVPlayer(url: resource.url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)

                Text(resource.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding()
            }
            .navigationTitle(
                LanguageManager.shared.localizedString(
                    resource.kind == .video ? "resource_video_player" : "resource_audio_player"
                )
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
        }
    }
}
