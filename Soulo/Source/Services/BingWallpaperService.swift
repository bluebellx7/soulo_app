import SwiftUI

// Deprecated: Migrated to WallpaperManager
class BingWallpaperService: ObservableObject {
    @Published var mode: BingWallpaperMode = .none
    @Published var currentImage: UIImage? = nil
    @Published var currentWallpaper: BingWallpaper? = nil
    
    enum BingWallpaperMode: String {
        case none, bing, custom
    }

    func setMode(_ mode: BingWallpaperMode) {}
    func applyWallpaper() {}
    func fetchWallpapers() async {}
}
