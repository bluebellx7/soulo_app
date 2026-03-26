import SwiftUI

struct WebViewToolbar: View {
    @ObservedObject var viewModel: WebViewModel
    @Binding var isBookmarked: Bool

    var onShare: (() -> Void)?
    var onBookmarkToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            btn("chevron.left", enabled: viewModel.canGoBack) { viewModel.goBack() }
            btn("chevron.right", enabled: viewModel.canGoForward) { viewModel.goForward() }
            btn(viewModel.isLoading ? "xmark" : "arrow.clockwise", enabled: true) { viewModel.reload() }
            btn(isBookmarked ? "bookmark.fill" : "bookmark",
                enabled: true,
                tint: isBookmarked ? .blue : nil) { onBookmarkToggle?() }
            btn("square.and.arrow.up", enabled: viewModel.currentURL != nil) { onShare?() }
        }
    }

    // MARK: - Button

    private func btn(_ icon: String, enabled: Bool, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(
                    !enabled ? .white.opacity(0.35) :
                    tint ?? .white.opacity(0.85)
                )
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(.black.opacity(0.35))
                        .overlay(Circle().stroke(.white.opacity(0.1), lineWidth: 0.5))
                )
        }
        .disabled(!enabled)
    }
}
