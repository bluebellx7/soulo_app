import SwiftUI

struct WallpaperBackground: View {
    @ObservedObject var wallpaperManager = WallpaperManager.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                wallpaperLayer(size: geo.size)
                scrimLayer
            }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func wallpaperLayer(size: CGSize) -> some View {
        switch wallpaperManager.source {
        case .gradient:
            let p = wallpaperManager.currentGradient
            DynamicGradientView(colors: p.colors)

        case .solid:
            Color(hex: wallpaperManager.solidColor)

        case .photo:
            if let img = wallpaperManager.customImage {
                photoImage(img, size: size)
                    .id(wallpaperManager.currentImageID)
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                Color.black.opacity(0.3)
            } else {
                DynamicGradientView.fallback
            }

        case .bing, .pexels, .pixabay:
            if let img = wallpaperManager.currentImage {
                photoImage(img, size: size)
                    .id(wallpaperManager.currentImageID)
                    .transition(.opacity.animation(.easeInOut(duration: 0.8)))
                Color.black.opacity(0.3)
            } else {
                DynamicGradientView.fallback
            }
        }
    }

    private func photoImage(_ img: UIImage, size: CGSize) -> some View {
        Image(uiImage: img)
            .resizable()
            .scaledToFill()
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    private var scrimLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    .black.opacity(0.65),
                    .black.opacity(0.25),
                    .black.opacity(0.25),
                    .black.opacity(0.70),
                ],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [.clear, .black.opacity(0.2)],
                center: .center, startRadius: 150, endRadius: 500
            )
        }
    }
}

// MARK: - Dynamic Gradient View

/// Smooth organic gradient animation using Canvas.
/// 5 color pools drift slowly across the screen, blending into each other.
struct DynamicGradientView: View {
    let colors: [Color]

    static var fallback: DynamicGradientView {
        DynamicGradientView(colors: [
            Color(red: 0.05, green: 0.07, blue: 0.16),
            Color(red: 0.08, green: 0.12, blue: 0.22),
            Color(red: 0.15, green: 0.22, blue: 0.35),
        ])
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
            Canvas { ctx, size in
                render(ctx: ctx, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func render(ctx: GraphicsContext, size: CGSize, time: Double) {
        let w = size.width, h = size.height
        let c1 = colors.first ?? .purple
        let c2 = colors.count > 1 ? colors[1] : c1
        let c3 = colors.count > 2 ? colors[2] : c2

        // Dark base
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .linearGradient(Gradient(colors: [c1, c3]),
                                       startPoint: .zero, endPoint: CGPoint(x: w, y: h)))

        // 5 drifting color pools — each very large, very soft, overlapping
        let specs: [(bx: Double, by: Double, freq: Double, ph: Double, r: Double, color: Color, op: Double)] = [
            (0.20, 0.15, 0.07, 0.0, 0.7, c1, 0.45),
            (0.80, 0.25, 0.05, 1.5, 0.6, c2, 0.35),
            (0.50, 0.70, 0.06, 3.0, 0.65, c3, 0.40),
            (0.15, 0.60, 0.08, 4.5, 0.55, c2, 0.30),
            (0.75, 0.85, 0.04, 6.0, 0.6, c1, 0.35),
        ]

        for s in specs {
            let x = w * s.bx + sin(time * s.freq + s.ph) * w * 0.2
            let y = h * s.by + cos(time * s.freq * 0.8 + s.ph) * h * 0.15
            let radius = min(w, h) * s.r

            ctx.drawLayer { layerCtx in
                let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                layerCtx.fill(
                    Ellipse().path(in: rect),
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: s.color.opacity(s.op), location: 0.0),
                            .init(color: s.color.opacity(s.op * 0.4), location: 0.4),
                            .init(color: s.color.opacity(0), location: 1.0),
                        ]),
                        center: CGPoint(x: x, y: y),
                        startRadius: 0,
                        endRadius: radius
                    )
                )
            }
        }
    }
}

extension View {
    func readableText() -> some View {
        self
            .shadow(color: .black.opacity(0.65), radius: 3, y: 1)
            .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
    }
}
