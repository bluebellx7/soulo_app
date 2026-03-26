import SwiftUI
import SwiftData

struct WebViewContainer: View {
    @ObservedObject var webViewModel: WebViewModel
    @ObservedObject var bookmarkViewModel: BookmarkViewModel
    @Binding var isFullscreen: Bool
    @Environment(\.modelContext) private var modelContext

    @State private var isBookmarked: Bool = false
    @State private var showShareSheet: Bool = false
    @State private var showExternalAlert: Bool = false
    @State private var showBookmarkToast: Bool = false
    @State private var externalURL: URL? = nil

    var body: some View {
        ZStack(alignment: .bottom) {
            // WebView fills everything, extends to bottom edge
            VStack(spacing: 0) {
                WebViewProgressBar(
                    progress: webViewModel.estimatedProgress,
                    isLoading: webViewModel.isLoading
                )
                if !isFullscreen {
                    Rectangle()
                        .fill(Color(UIColor.separator).opacity(0.2))
                        .frame(height: 0.5)
                }

                WebViewRepresentable(viewModel: webViewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Floating toolbar always on top of WebView
            WebViewToolbar(
                viewModel: webViewModel,
                isBookmarked: $isBookmarked,
                onShare: { showShareSheet = true },
                onBookmarkToggle: { handleBookmarkToggle() }
            )
            .padding(.bottom, 16)

            // Bookmark toast
            if showBookmarkToast {
                VStack {
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark.slash")
                            .font(.system(size: 13))
                        Text(LanguageManager.shared.localizedString(isBookmarked ? "bookmark_added" : "bookmark_removed"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.bottom, 72)
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: webViewModel.currentURL) { _, url in
            syncBookmarkState(for: url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .webViewExternalURLRequest)) { notification in
            if let url = notification.userInfo?["url"] as? URL {
                externalURL = url
                showExternalAlert = true
            }
        }
        .alert(
            LanguageManager.shared.localizedString("open_external_title"),
            isPresented: $showExternalAlert
        ) {
            Button(LanguageManager.shared.localizedString("confirm")) {
                if let url = externalURL { UIApplication.shared.open(url) }
            }
            Button(LanguageManager.shared.localizedString("cancel"), role: .cancel) {}
        } message: {
            Text(LanguageManager.shared.localizedString("open_external_message"))
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = webViewModel.currentURL {
                ShareSheet(items: [url])
            }
        }
    }

    // MARK: - Bookmark

    private func handleBookmarkToggle() {
        guard let url = webViewModel.currentURL?.absoluteString
                ?? webViewModel.webView?.url?.absoluteString else { return }
        let title = webViewModel.pageTitle.isEmpty ? url : webViewModel.pageTitle
        let added = bookmarkViewModel.toggleBookmark(
            title: title, url: url, platformName: nil, context: modelContext
        )
        isBookmarked = added
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showBookmarkToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { showBookmarkToast = false }
        }
    }

    private func syncBookmarkState(for url: URL?) {
        guard let s = url?.absoluteString else { isBookmarked = false; return }
        isBookmarked = bookmarkViewModel.isBookmarked(url: s, context: modelContext)
    }
}

// MARK: - ShareSheet

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
