import SwiftUI
import ImageIO

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

    private static func decode(_ url: URL) -> UIImage? {
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
