import SwiftUI
import UIKit

@MainActor
class BingWallpaperService: ObservableObject {
    static let shared = BingWallpaperService()

    @Published var wallpapers: [BingWallpaper] = []
    @Published var currentWallpaper: BingWallpaper?
    @Published var currentImage: UIImage?
    @Published var isLoading: Bool = false

    var mode: WallpaperMode {
        get {
            WallpaperMode(rawValue: UserDefaults.standard.string(forKey: "wallpaper_mode") ?? "bing") ?? .bing
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "wallpaper_mode")
            objectWillChange.send()
        }
    }

    private let cacheKey = "bing_wallpapers_cache"

    private init() {
        wallpapers = loadCachedWallpapers()
    }

    // MARK: - Fetch & Apply (call this from HomeView.onAppear)

    func fetchWallpapers() async {
        // First: if we have cached wallpapers but no image yet, load one immediately
        if currentImage == nil && mode == .bing && !wallpapers.isEmpty {
            await applyRandomWallpaper()
        }

        // Then fetch fresh wallpapers from Bing
        isLoading = true
        defer { isLoading = false }

        var fetched: [BingWallpaper] = []
        let markets = ["en-US", "zh-CN", "ja-JP"]

        for market in markets {
            for idx in [0, 8] {
                let urlString = "https://www.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=8&mkt=\(market)"
                guard let url = URL(string: urlString) else { continue }

                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    let decoded = try JSONDecoder().decode(BingAPIResponse.self, from: data)
                    fetched.append(contentsOf: decoded.images)
                } catch {
                    // Silently continue on error
                }
            }
        }

        // Merge with cache
        let existingURLs = Set(wallpapers.map { $0.url })
        let newItems = fetched.filter { !existingURLs.contains($0.url) }
        wallpapers.append(contentsOf: newItems)
        saveCachedWallpapers(wallpapers)

        // If still no image displayed, apply now
        if currentImage == nil && mode == .bing && !wallpapers.isEmpty {
            await applyRandomWallpaper()
        }
    }

    // MARK: - Apply

    private func applyRandomWallpaper() async {
        guard let wallpaper = wallpapers.randomElement() else { return }
        currentWallpaper = wallpaper
        guard let url = wallpaper.fullURL else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let image = UIImage(data: data) {
                currentImage = image
            }
        } catch {
            // Failed to load image
        }
    }

    func applyWallpaper() {
        switch mode {
        case .bing:
            Task { await applyRandomWallpaper() }
        case .custom:
            if let data = UserDefaults.standard.data(forKey: "custom_wallpaper_data"),
               let image = UIImage(data: data) {
                currentImage = image
            }
        case .none:
            currentImage = nil
            currentWallpaper = nil
        }
    }

    // MARK: - Custom Wallpaper

    func setCustomWallpaper(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        UserDefaults.standard.set(data, forKey: "custom_wallpaper_data")
        mode = .custom
        currentImage = image
    }

    func setMode(_ newMode: WallpaperMode) {
        mode = newMode
        applyWallpaper()
    }

    // MARK: - Cache

    private func saveCachedWallpapers(_ items: [BingWallpaper]) {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    private func loadCachedWallpapers() -> [BingWallpaper] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode([BingWallpaper].self, from: data) else {
            return []
        }
        return decoded
    }
}

// MARK: - API Response

private struct BingAPIResponse: Decodable {
    let images: [BingWallpaper]
}
