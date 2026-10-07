import SwiftUI

struct WallpaperEditorView: View {
    let image: UIImage
    var onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var canvasSize: CGSize = .zero
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Image layer — clipped to screen bounds
            GeometryReader { geo in
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .clipped()
                    .onChange(of: geo.size, initial: true) { _, size in canvasSize = size }
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                offset = CGSize(
                                    width: lastOffset.width + v.translation.width,
                                    height: lastOffset.height + v.translation.height
                                )
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                    .gesture(
                        MagnificationGesture()
                            .onChanged { v in scale = lastScale * v }
                            .onEnded { _ in
                                scale = max(0.5, min(scale, 3.0))
                                lastScale = scale
                            }
                    )
            }
            .ignoresSafeArea()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                LanguageManager.shared.localizedString("accessibility_wallpaper_preview")
            )
            .accessibilityValue(
                AppAccessibility.formatted(
                    "accessibility_wallpaper_zoom",
                    Int((scale * 100).rounded())
                )
            )
            .accessibilityHint(
                LanguageManager.shared.localizedString("accessibility_wallpaper_adjust_hint")
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    scale = min(scale + 0.1, 3)
                case .decrement:
                    scale = max(scale - 0.1, 0.5)
                @unknown default:
                    break
                }
                lastScale = scale
            }
            .accessibilityAction(
                named: Text(LanguageManager.shared.localizedString("accessibility_move_left"))
            ) { moveWallpaper(dx: -24, dy: 0) }
            .accessibilityAction(
                named: Text(LanguageManager.shared.localizedString("accessibility_move_right"))
            ) { moveWallpaper(dx: 24, dy: 0) }
            .accessibilityAction(
                named: Text(LanguageManager.shared.localizedString("accessibility_move_up"))
            ) { moveWallpaper(dx: 0, dy: -24) }
            .accessibilityAction(
                named: Text(LanguageManager.shared.localizedString("accessibility_move_down"))
            ) { moveWallpaper(dx: 0, dy: 24) }

            // UI overlay
            VStack(spacing: 0) {
                Spacer()

                // Hint
                Text(LanguageManager.shared.localizedString("wallpaper_drag_hint"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, 24)

                // Bottom buttons
                HStack(spacing: 16) {
                    // Cancel
                    Button {
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .medium))
                            Text(LanguageManager.shared.localizedString("cancel"))
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.15), lineWidth: 0.5)
                        )
                    }

                    // Confirm
                    Button {
                        guard let result = WallpaperCropRenderer.render(
                            image, canvasSize: canvasSize, displayScale: displayScale,
                            zoom: scale, offset: offset
                        ) else { return }
                        onSave(result)
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .semibold))
                            Text(LanguageManager.shared.localizedString("confirm"))
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.white.opacity(0.25), lineWidth: 0.5)
                        )
                    }
                    .disabled(canvasSize.width <= 0 || canvasSize.height <= 0)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
    }

    private func moveWallpaper(dx: CGFloat, dy: CGFloat) {
        offset.width += dx
        offset.height += dy
        lastOffset = offset
    }
}

enum WallpaperCropRenderer {
    /// Match the preview's aspect-fill, zoom and offset in its local canvas,
    /// including a wide or resized window rather than the main screen.
    static func render(_ image: UIImage, canvasSize: CGSize, displayScale: CGFloat,
                       zoom: CGFloat, offset: CGSize) -> UIImage? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              canvasSize.width.isFinite, canvasSize.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              zoom > 0, zoom.isFinite, displayScale > 0, displayScale.isFinite else { return nil }
        let fill = max(canvasSize.width / image.size.width, canvasSize.height / image.size.height)
        let size = CGSize(width: image.size.width * fill * zoom, height: image.size.height * fill * zoom)
        let rect = CGRect(x: (canvasSize.width - size.width) / 2 + offset.width,
                          y: (canvasSize.height - size.height) / 2 + offset.height,
                          width: size.width, height: size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale
        format.opaque = true
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: canvasSize))
            image.draw(in: rect)
        }
    }
}
