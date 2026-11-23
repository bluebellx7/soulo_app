import Foundation

enum SouloWidgetWallpaper {
    static let kind = "com.dkluge.Soulo.bookshelf"
    static let maximumBytes = 256 * 1024

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SouloSharedConstants.appGroupIdentifier)?
            .appendingPathComponent("WidgetWallpaper.jpg", isDirectory: false)
    }

    static func load() -> Data? {
        guard let url = fileURL, let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0, size <= maximumBytes else { return nil }
        return try? Data(contentsOf: url)
    }
}
