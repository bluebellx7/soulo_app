import SwiftUI
import ImageIO
import WebKit

struct LocalImagePreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image { ZoomableImageSurface(uiImage: image, onDismiss: { dismiss() }) }
            else if failed { Image(systemName: "photo.badge.exclamationmark").font(.largeTitle).foregroundStyle(.white) }
            else { ProgressView().tint(.white) }
        }
        .task(id: url) {
            let decoding = Task.detached(priority: .userInitiated) { Self.decode(url) }
            let result = await withTaskCancellationHandler {
                await decoding.value
            } onCancel: { decoding.cancel() }
            guard !Task.isCancelled else { return }
            image = result; failed = result == nil
        }
    }

    nonisolated static func decode(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }
        // Keep animation frames while bounding their combined decoded memory.
        let pixelLimit = count > 1 ? min(1600, Int(sqrt(Double(48 * 1024 * 1024) / Double(count * 4)))) : 4096
        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<count {
            guard !Task.isCancelled, let cg = CGImageSourceCreateThumbnailAtIndex(source, index, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(pixelLimit, 1),
            ] as CFDictionary) else { return frames.first }
            frames.append(UIImage(cgImage: cg))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let png = properties?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
            duration += max((gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double) ?? 0.1, 0.02)
        }
        return count > 1 ? UIImage.animatedImage(with: frames, duration: duration) : frames.first
    }
}

@MainActor final class WebImagePreviewRequest: Identifiable {
    let id = UUID()
    let url: URL
    let pageURL: URL?
    weak var webView: WKWebView?
    let frame: WKFrameInfo?
    init(url: URL, webView: WKWebView, frame: WKFrameInfo?) {
        self.url = url; self.pageURL = frame?.requestURL ?? webView.url; self.webView = webView; self.frame = frame
    }
}

struct WebImagePreview: View {
    let request: WebImagePreviewRequest
    var onOpenResources: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var items: [WebImageGalleryItem]
    @State private var selectedID: String

    init(request: WebImagePreviewRequest, onOpenResources: @escaping () -> Void) {
        self.request = request; self.onOpenResources = onOpenResources
        _items = State(initialValue: [.init(url: request.url, pageURL: request.pageURL, frame: request.frame)])
        _selectedID = State(initialValue: request.url.absoluteString)
    }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selectedID) {
                ForEach(items) { item in
                    WebImagePreviewPage(request: request, item: item, isActive: selectedID == item.id,
                        onDismiss: { dismiss() }, onOpenResources: onOpenResources)
                        .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle())
                }.accessibilityLabel(ToolText.text("close"))
                    .accessibilityIdentifier("browser.imagePreview.close")
                Spacer()
                if items.count > 1 {
                    Text("\((items.firstIndex { $0.id == selectedID } ?? 0) + 1) / \(items.count)")
                        .font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 14).frame(height: 36)
                        .background(.black.opacity(0.6), in: Capsule())
                        .accessibilityIdentifier("browser.imagePreview.position")
                }
            }.padding(12)
        }
        .statusBarHidden()
        .task {
            let gallery = await WebImageGalleryService.collect(for: request)
            guard !Task.isCancelled else { return }
            selectedID = gallery.selectedID; items = gallery.items
        }
    }
}

private struct WebImagePreviewPage: View {
    let request: WebImagePreviewRequest
    let item: WebImageGalleryItem
    let isActive: Bool
    let onDismiss: () -> Void
    let onOpenResources: () -> Void
    @State private var image: UIImage?
    @State private var error: String?
    @State private var attempt = 0
    @State private var original: PreviewImageFile?
    @State private var sharing = false
    @State private var saving = false
    @State private var notice: String?

    var body: some View {
        ZStack {
            if let image {
                ZoomableImageSurface(uiImage: image, onDismiss: onDismiss)
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button(ToolText.text("retry")) { attempt += 1 }.buttonStyle(.bordered)
                }.foregroundStyle(.white).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 0) {
                Button {
                    guard !saving, let original else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await WebResourceDownloadService.shared.saveImageToPhotos(original.url)
                            notice = LanguageManager.shared.localizedString("resource_saved_to_photos")
                        } catch { notice = error.localizedDescription }
                    }
                } label: {
                    actionLabel(LanguageManager.shared.localizedString("save_to_photos"), icon: "square.and.arrow.down")
                }.disabled(original == nil || saving).accessibilityIdentifier("browser.imagePreview.save")
                Button { sharing = true } label: {
                    actionLabel(ToolText.text("share"), icon: "square.and.arrow.up")
                }.disabled(original == nil).accessibilityIdentifier("browser.imagePreview.share")
                Button(action: onOpenResources) {
                    actionLabel(ToolText.text("image_resources"), icon: "square.stack.3d.up")
                }.accessibilityIdentifier("browser.imagePreview.resources")
            }
            .font(.subheadline.weight(.medium)).foregroundStyle(.white)
            .buttonStyle(.plain).padding(.horizontal, 10).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .environment(\.colorScheme, .dark).padding(.horizontal, 16).padding(.bottom, 12)
        }
        .sheet(isPresented: $sharing) {
            if let original { PreviewImageShare(file: original) }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("close"), role: .cancel) { notice = nil }
        }
        .task(id: "\(isActive)-\(attempt)") {
            image = nil; original = nil; error = nil
            guard isActive else { return }
            do {
                let url = try await WebResourceDownloadService.shared.temporaryImageFile(
                    item.url, pageURL: item.pageURL, webView: request.webView, frame: item.frame)
                let file = try PreviewImageFile(url: url)
                let decoding = Task.detached(priority: .userInitiated) { LocalImagePreview.decode(file.url) }
                let loaded = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
                guard !Task.isCancelled else { return }
                guard let loaded else { throw WebResourceDownloadError.invalidImage }
                original = file; image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
    private func actionLabel(_ title: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 18, weight: .medium))
            Text(title).font(.caption).lineLimit(1)
        }.frame(maxWidth: .infinity, minHeight: 48).contentShape(Rectangle())
    }
}

/// Retain original bytes until both preview and any save/share operation finish.
private final class PreviewImageFile {
    let url: URL
    private let directory: URL
    init(url source: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SouloImagePreview-" + UUID().uuidString)
        url = directory.appendingPathComponent("Image").appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source, to: url)
        } catch {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

private struct PreviewImageShare: UIViewControllerRepresentable {
    let file: PreviewImageFile
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
