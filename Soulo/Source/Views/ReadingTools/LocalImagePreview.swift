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
        self.url = url; self.pageURL = frame?.request.url ?? webView.url; self.webView = webView; self.frame = frame
    }
}

struct WebImagePreview: View {
    let request: WebImagePreviewRequest
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var error: String?
    @State private var attempt = 0
    @State private var original: PreviewImageFile?
    @State private var sharing = false
    @State private var saving = false
    @State private var notice: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let image {
                ZoomableImageSurface(uiImage: image, onDismiss: { dismiss() })
            } else if let error {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button(ToolText.text("retry")) { attempt += 1 }.buttonStyle(.bordered)
                }.foregroundStyle(.white).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.black.opacity(0.6), in: Circle())
            }.accessibilityLabel(ToolText.text("close"))
                .accessibilityIdentifier("browser.imagePreview.close").padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            if let original, image != nil {
                HStack(spacing: 32) {
                    Button {
                        guard !saving else { return }
                        saving = true
                        Task {
                            defer { saving = false }
                            do {
                                try await WebResourceDownloadService.shared.saveImageToPhotos(original.url)
                                notice = LanguageManager.shared.localizedString("resource_saved_to_photos")
                            } catch { notice = error.localizedDescription }
                        }
                    } label: {
                        Label(LanguageManager.shared.localizedString("save_to_photos"), systemImage: "square.and.arrow.down")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .disabled(saving).accessibilityIdentifier("browser.imagePreview.save")
                    Button { sharing = true } label: {
                        Label(ToolText.text("share"), systemImage: "square.and.arrow.up")
                            .frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("browser.imagePreview.share")
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(.white)
                .buttonStyle(.plain).padding(.horizontal, 24).frame(minHeight: 48)
                .background(.ultraThinMaterial, in: Capsule())
                .environment(\.colorScheme, .dark).padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $sharing) {
            if let original { PreviewImageShare(file: original) }
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button(ToolText.text("close"), role: .cancel) { notice = nil }
        }
        .task(id: attempt) {
            error = nil
            do {
                let url = try await WebResourceDownloadService.shared.temporaryImageFile(
                    request.url, pageURL: request.pageURL, webView: request.webView, frame: request.frame)
                let file = try PreviewImageFile(url: url)
                let decoding = Task.detached(priority: .userInitiated) { LocalImagePreview.decode(file.url) }
                let loaded = await withTaskCancellationHandler { await decoding.value } onCancel: { decoding.cancel() }
                guard !Task.isCancelled else { return }
                guard let loaded else { throw WebResourceDownloadError.invalidImage }
                original = file
                image = loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
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
