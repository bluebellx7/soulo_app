import SwiftUI
import WidgetKit

@MainActor final class WidgetWallpaperPublisher {
    static let shared = WidgetWallpaperPublisher()

    private struct Style: Equatable {
        let source: WallpaperSource
        let appearance: WallpaperAppearance
        let colorID: String
        let image: ObjectIdentifier?
        let overlay: Double
        let blur: CGFloat
    }

    private var updateTask: Task<Void, Never>?
    private var publishedStyle: Style?

    func schedule(_ manager: WallpaperManager) {
        updateTask?.cancel()
        updateTask = Task { @MainActor [weak self, weak manager] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let manager else { return }
            self?.publish(manager)
        }
    }

    private func publish(_ manager: WallpaperManager) {
        let appearance = manager.displayAppearance
        let image = manager.source == .photo ? manager.customImage : manager.currentImage
        let colorID = manager.source == .solid ? manager.solidColor(for: appearance) : manager.gradientID(for: appearance)
        let style = Style(source: manager.source, appearance: appearance, colorID: colorID,
                          image: image.map(ObjectIdentifier.init), overlay: manager.imageOverlayEnabled ? manager.imageOverlayOpacity : 0,
                          blur: manager.imageBlurRadius)
        guard style != publishedStyle, let url = SouloWidgetWallpaper.fileURL else { return }
        let artwork = WallpaperBackground(isAnimating: false, appearanceOverride: appearance,
                                          reportsAppearance: false, wallpaperManager: manager)
            .frame(width: 360, height: 360)
        let renderer = ImageRenderer(content: artwork)
        renderer.scale = 1
        guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.8), data.count <= SouloWidgetWallpaper.maximumBytes else { return }
        if data != SouloWidgetWallpaper.load() {
            do { try data.write(to: url, options: .atomic) } catch { return }
            WidgetCenter.shared.reloadTimelines(ofKind: SouloWidgetWallpaper.kind)
        }
        publishedStyle = style
    }
}
