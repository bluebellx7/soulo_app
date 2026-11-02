import Foundation
import CoreGraphics
import ImageIO

/// Decode only the pixels needed by the full-screen background. The original
/// compressed file stays intact for later export or editing.
enum WallpaperImageDecoder {
    static func decode(_ data: Data, targetPixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, targetPixels: targetPixels)
    }

    static func decode(file: URL, targetPixels: CGSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return decode(source, targetPixels: targetPixels)
    }

    private static func decode(_ source: CGImageSource, targetPixels: CGSize) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue > 0, height.doubleValue > 0,
              targetPixels.width.isFinite, targetPixels.height.isFinite,
              targetPixels.width > 0, targetPixels.height > 0 else { return nil }
        // Both orientations need a sharp aspect-fill image. A simple long-edge
        // screen limit would undersample a landscape photo on a portrait phone.
        let longestTarget = Double(max(targetPixels.width, targetPixels.height))
        let factor = min(1, longestTarget / min(width.doubleValue, height.doubleValue))
        let limit = min(8192, ceil(max(width.doubleValue, height.doubleValue) * factor))
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(limit)),
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
}
