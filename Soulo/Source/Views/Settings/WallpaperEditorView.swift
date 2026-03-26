import SwiftUI

struct WallpaperEditorView: View {
    let image: UIImage
    var onSave: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

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
                        let result = renderImage()
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
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 50)
            }
        }
    }

    private func renderImage() -> UIImage {
        let screenSize = UIScreen.main.bounds.size
        let renderer = UIGraphicsImageRenderer(size: screenSize)
        return renderer.image { _ in
            let imgSize = image.size
            let aspect = imgSize.width / imgSize.height
            let drawH = screenSize.height * scale
            let drawW = drawH * aspect
            let x = (screenSize.width - drawW) / 2 + offset.width
            let y = (screenSize.height - drawH) / 2 + offset.height
            image.draw(in: CGRect(x: x, y: y, width: drawW, height: drawH))
        }
    }
}
