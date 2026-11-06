import SwiftUI
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AVFoundation

/// Shares bounded, downsampled previews between list and grid cells.
actor FileThumbnailCache {
    static let shared = FileThumbnailCache()
    private let images = NSCache<NSString, UIImage>()
    init() { images.totalCostLimit = 24 * 1024 * 1024; images.countLimit = 120 }

    func thumbnail(_ file: LocalFile) async -> UIImage? {
        guard !file.directory, !Task.isCancelled else { return nil }
        let key = "\(file.id)|\(file.modifiedAt.timeIntervalSince1970)|\(file.info.size)|\(file.coverURL?.path ?? "")" as NSString
        if let cached = images.object(forKey: key) { return cached }
        let url = file.coverURL ?? file.url
        var image: UIImage?
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: 420,
           ] as CFDictionary) {
            image = UIImage(cgImage: cg)
        }
        if image == nil, file.info.kind == .video, !Task.isCancelled {
            image = await videoThumbnail(file.url)
        }
        // HLS references are media packages; Quick Look would show the reference
        // document rather than its video. Other files can use system type icons
        // when a document preview or embedded cover is unavailable.
        if image == nil, !Task.isCancelled,
           !["movpkg", OfflineHLSReference.fileExtension, "hls"].contains(file.url.pathExtension.lowercased()) {
            let request = QLThumbnailGenerator.Request(fileAt: file.url, size: CGSize(width: 280, height: 420), scale: 1, representationTypes: .all)
            image = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                        continuation.resume(returning: representation?.uiImage)
                    }
                }
            } onCancel: { QLThumbnailGenerator.shared.cancel(request) }
        }
        if let image, !Task.isCancelled {
            images.setObject(image, forKey: key, cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0))
        }
        return image
    }

    private func videoThumbnail(_ url: URL) async -> UIImage? {
        do {
            let playableURL: URL
            if url.pathExtension.lowercased() == OfflineHLSReference.fileExtension {
                playableURL = try OfflineHLSReference.packageURL(for: url)
            } else if LocalHLSMedia.extensions.contains(url.pathExtension.lowercased()) {
                playableURL = try LocalHLSMedia.playlistURL(for: url)
            } else { playableURL = url }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: playableURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 420, height: 420)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)
            let result = try await withTaskCancellationHandler {
                try await generator.image(at: .zero)
            } onCancel: { generator.cancelAllCGImageGeneration() }
            return UIImage(cgImage: result.image)
        } catch { return nil }
    }
}

struct FileThumbnailView: View {
    let file: LocalFile
    @State private var image: UIImage?
    private var contentMode: ContentMode {
        guard file.coverURL == nil, !file.directory else { return .fit }
        if file.info.kind == .video { return .fill }
        guard
              let type = UTType(filenameExtension: file.info.fileExtension),
              type.conforms(to: .image) || type.conforms(to: .movie) else { return .fit }
        return .fill
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    Image(uiImage: image).resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Image(systemName: file.info.symbol)
                        .font(.title2).foregroundStyle(Color.themePrimary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: file) {
            image = nil
            let result = await FileThumbnailCache.shared.thumbnail(file)
            guard !Task.isCancelled else { return }
            image = result
        }
        .accessibilityHidden(true)
    }
}
