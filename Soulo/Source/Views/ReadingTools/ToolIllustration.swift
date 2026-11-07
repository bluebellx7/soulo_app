import SwiftUI

/// Bundled, decorative artwork. Kept out of the home screen's startup path.
struct ToolIllustration: View {
    enum Scene: String {
        case files = "IllustrationFiles"
        case books = "IllustrationBooks"
        case transfer = "IllustrationTransfer"
        case pageQR = "IllustrationPageQR"
        case downloads = "IllustrationDownloads"
        case bookmarks = "IllustrationBookmarks"
        case history = "IllustrationHistory"
        case about = "IllustrationAbout"
        case review = "IllustrationReview"
        case quickActions = "IllustrationQuickActions"
        case playback = "IllustrationPlayback"

        var preservesLogoColors: Bool { self == .about || self == .review || self == .quickActions }
    }

    let scene: Scene
    var height: CGFloat = 160
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if colorScheme == .dark && !scene.preservesLogoColors {
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

/// Explain a feature where it is configured, using the same quiet layout as
/// Home Screen quick actions. The artwork is decorative; the text remains accessible.
struct IllustratedFeatureIntro: View {
    let scene: ToolIllustration.Scene
    let message: String
    let accessibilityID: String
    var height: CGFloat = 160

    var body: some View {
        VStack(spacing: 12) {
            ToolIllustration(scene: scene, height: height)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
                .accessibilityIdentifier(accessibilityID)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
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
