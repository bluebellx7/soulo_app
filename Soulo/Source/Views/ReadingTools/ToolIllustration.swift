import SwiftUI

/// Bundled, decorative artwork. Kept out of the home screen's startup path.
struct ToolIllustration: View {
    enum Scene: String {
        case files = "IllustrationFiles"
        case books = "IllustrationBooks"
        case transfer = "IllustrationTransfer"
    }

    let scene: Scene
    var height: CGFloat = 160
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark {
                artwork.saturation(0).colorInvert()
            } else {
                artwork
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private var artwork: some View {
        Image(scene.rawValue)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 280)
            .frame(height: height)
    }
}

struct IllustratedToolEmptyState: View {
    let scene: ToolIllustration.Scene
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: 16) {
            ToolIllustration(scene: scene)
            VStack(spacing: 8) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.primary)
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: 300)
                }
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
