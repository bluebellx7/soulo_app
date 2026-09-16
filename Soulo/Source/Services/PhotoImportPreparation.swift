import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PhotoImportPreparation {
    struct Resource: Sendable {
        let url: URL
        let typeIdentifier: String
    }

    /// Inspect bytes instead of trusting a URL suffix or Content-Type from a CDN.
    static func prepare(sourceURL: URL, directory: URL, filename: String?, convert: Bool = false) throws -> Resource {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete else {
            throw WebResourceDownloadError.invalidImage
        }
        let originalType = identifier as String
        let frames = CGImageSourceGetCount(source)
        let outputType = convert ? (frames > 1 ? UTType.gif : UTType.png) : UTType(originalType)
        guard let outputType, let ext = outputType.preferredFilenameExtension else {
            throw WebResourceDownloadError.invalidImage
        }
        let base = ((filename ?? "Image") as NSString).deletingPathExtension
        let name = DownloadFilenameSanitizer.sanitize(base.isEmpty ? "Image" : base)
        let output = directory.appendingPathComponent((convert ? "Compatible-" : "") + name).appendingPathExtension(ext)
        if !convert {
            try FileManager.default.copyItem(at: sourceURL, to: output)
            return Resource(url: output, typeIdentifier: originalType)
        }

        // Keep decoding off the main thread and bound pathological images/animations.
        guard frames <= 500 else { throw WebResourceDownloadError.imageTooLarge }
        var pixelCount = 0.0
        for index in 0..<frames {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw WebResourceDownloadError.invalidImage
            }
            let pixels = width.doubleValue * height.doubleValue
            pixelCount += pixels
            guard pixels > 0, pixels <= 40_000_000, pixelCount <= 120_000_000 else {
                throw WebResourceDownloadError.imageTooLarge
            }
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL,
            outputType.identifier as CFString, frames, nil) else { throw WebResourceDownloadError.invalidImage }
        if frames > 1 {
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
            let webp = properties?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let loop = webp?[kCGImagePropertyWebPLoopCount] ?? gif?[kCGImagePropertyGIFLoopCount] ?? 0
            CGImageDestinationSetProperties(destination,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
        }
        for index in 0..<frames {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let image = CGImageSourceCreateImageAtIndex(source, index,
                    [kCGImageSourceShouldCache: false] as CFDictionary) else { throw WebResourceDownloadError.invalidImage }
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
                var outputProperties: [CFString: Any] = [:]
                if let orientation = properties[kCGImagePropertyOrientation] {
                    outputProperties[kCGImagePropertyOrientation] = orientation
                }
                if frames > 1 {
                    let webp = properties[kCGImagePropertyWebPDictionary] as? [CFString: Any]
                    let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                    let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                    let webpDelay = webp?[kCGImagePropertyWebPUnclampedDelayTime] ?? webp?[kCGImagePropertyWebPDelayTime]
                    let gifDelay = gif?[kCGImagePropertyGIFUnclampedDelayTime] ?? gif?[kCGImagePropertyGIFDelayTime]
                    let pngDelay = png?[kCGImagePropertyAPNGUnclampedDelayTime] ?? png?[kCGImagePropertyAPNGDelayTime]
                    let delay = webpDelay ?? gifDelay ?? pngDelay ?? 0.1
                    outputProperties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay]
                }
                CGImageDestinationAddImage(destination, image, outputProperties as CFDictionary)
            }
        }
        guard CGImageDestinationFinalize(destination) else { throw WebResourceDownloadError.invalidImage }
        return Resource(url: output, typeIdentifier: outputType.identifier)
    }
}
