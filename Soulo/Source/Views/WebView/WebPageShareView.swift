import LinkPresentation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@MainActor
enum WebPageShareImageRenderer {
    static func visibleRect(in bounds: CGRect, obscuredBottom: CGFloat) -> CGRect {
        let size = bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return .zero }
        let inset = obscuredBottom.isFinite ? min(max(0, obscuredBottom), size.height) : 0
        return CGRect(x: 0, y: 0, width: size.width, height: max(0, size.height - inset))
    }

    static func brandedImage(from screenshot: UIImage, brand: String) -> UIImage {
        let width = screenshot.size.width
        let unit = min(1.25, max(0.8, width / 390))
        let logoSide = 48 * unit
        let gap = 6 * unit
        let margin = 16 * unit
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.baseWritingDirection = .natural
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16 * unit, weight: .semibold),
            .foregroundColor: UIColor(white: 0.11, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let text = brand as NSString
        let maxTextWidth = max(1, width - margin * 2 - logoSide - gap)
        let textWidth = min(ceil(text.size(withAttributes: attributes).width), maxTextWidth)
        let textHeight = ceil(text.boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil).height)
        let footerHeight = ceil(max(64 * unit, textHeight + 24 * unit))
        let size = CGSize(width: width, height: screenshot.size.height + footerHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = screenshot.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            screenshot.draw(at: .zero)
            let top = screenshot.size.height
            UIColor(white: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: top, width: width, height: 1 / format.scale))
            let start = (width - logoSide - gap - textWidth) / 2
            let middle = top + footerHeight / 2
            let logoRect = CGRect(x: start, y: middle - logoSide / 2, width: logoSide, height: logoSide)
            UIImage(named: "SouloLogo")?.draw(in: logoRect)
            let borderWidth = unit
            let border = UIBezierPath(roundedRect: logoRect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                      cornerRadius: 10 * unit)
            border.lineWidth = borderWidth
            UIColor(white: 0.82, alpha: 1).setStroke()
            border.stroke()
            text.draw(in: CGRect(x: start + logoSide + gap, y: middle - textHeight / 2,
                                 width: textWidth, height: textHeight), withAttributes: attributes)
        }
    }
}

@MainActor
final class WebPageSharePreviewModel: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    @Published private(set) var image: UIImage?
    @Published private(set) var isCapturing = false
    @Published private(set) var error: String?
    private weak var webView: WKWebView?
    private let rect: CGRect
    let brand: String

    init(url: URL, title: String, webView: WKWebView?, obscuredBottom: CGFloat) {
        self.url = url
        self.title = title
        self.webView = webView
        rect = WebPageShareImageRenderer.visibleRect(in: webView?.bounds ?? .zero, obscuredBottom: obscuredBottom)
        brand = ToolText.text("page_share_brand")
    }

    // Start the WebKit request before presenting the preview sheet. Native
    // menus/chrome are never part of the pixels, and the document isn't scrolled.
    func capture() {
        guard !isCapturing else { return }
        error = nil
        guard let webView, webView.window != nil, webView.url == url else {
            error = WebPageCaptureError.unavailable.localizedDescription
            return
        }
        guard rect.width > 1, rect.height > 1 else {
            error = WebPageCaptureError.emptyPage.localizedDescription
            return
        }
        isCapturing = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width))
        configuration.afterScreenUpdates = true
        let warm = WebAppearanceService.hasWarmOverlay(on: webView)
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] screenshot, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isCapturing = false
                guard let webView, webView.url == self.url else {
                    self.error = WebPageCaptureError.unavailable.localizedDescription
                    return
                }
                guard let screenshot else {
                    self.error = WebPageCaptureError.captureFailed.localizedDescription
                    return
                }
                self.image = WebPageShareImageRenderer.brandedImage(
                    from: WebAppearanceService.applyingWarmColor(to: screenshot, enabled: warm), brand: self.brand)
            }
        }
    }
}

@MainActor
enum WebPageShareItems {
    static func link(url: URL, title: String) -> [Any] {
        if #available(iOS 17.4, *), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return [WebPageShareActivityItem(url: url, title: title)]
        }
        return [url]
    }
}

struct WebPageSharePreview: View {
    @ObservedObject var model: WebPageSharePreviewModel
    @Environment(\.dismiss) private var dismiss
    @State private var activity: WebPageShareActivityPresentation?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.title).font(.headline).lineLimit(2)
                            Text(model.url.host ?? model.url.absoluteString)
                                .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        preview
                            .frame(maxWidth: .infinity)
                            .frame(height: max(80, geometry.size.height - 128))
                    }
                    .padding(20)
                    .frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .navigationTitle(ToolText.text("share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) { dismiss() }
                        .accessibilityIdentifier("pageShare.close")
                }
            }
            .sheet(item: $activity) { WebPageShareActivitySheet(items: $0.items) }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .accessibilityIdentifier("pageShare.panel")
    }

    @ViewBuilder private var preview: some View {
        if let image = model.image {
            Image(uiImage: image).resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityLabel(ToolText.text("page_share_preview"))
                .accessibilityValue(model.brand)
                .accessibilityIdentifier("pageShare.preview")
        } else if model.isCapturing {
            ProgressView(ToolText.text("loading"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("pageShare.loading")
        } else {
            VStack(spacing: 14) {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.error ?? WebPageCaptureError.captureFailed.localizedDescription)
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button(ToolText.text("retry")) { model.capture() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("pageShare.retry")
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            Button {
                guard let image = model.image else { return }
                activity = WebPageShareActivityPresentation(items: [WebPageShareImageItem(image: image, title: model.title)])
            } label: {
                Label(ToolText.text("page_share_image"), systemImage: "square.and.arrow.up")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .disabled(model.image == nil)
            .accessibilityIdentifier("pageShare.shareImage")
            AdaptiveActionRow(spacing: 12) {
                Button {
                    UIPasteboard.general.url = model.url
                    copied = true
                    HapticsManager.success()
                    AppAccessibility.announce(LanguageManager.shared.localizedString("link_copied"))
                } label: {
                    Label(copied ? ToolText.text("copied") : LanguageManager.shared.localizedString("copy_link"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .accessibilityIdentifier("pageShare.copyLink")
                Button {
                    activity = WebPageShareActivityPresentation(items: WebPageShareItems.link(url: model.url, title: model.title))
                } label: {
                    Label(ToolText.text("page_share_link"), systemImage: "link")
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .accessibilityIdentifier("pageShare.shareLink")
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered).controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }
}

private struct WebPageShareActivityPresentation: Identifiable {
    let id = UUID()
    let items: [Any]
}

private struct WebPageShareActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

final class WebPageShareImageItem: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String
    init(image: UIImage, title: String) { self.image = image; self.title = title }
    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String { UTType.png.identifier }
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        if let logo = UIImage(named: "SouloLogo") { metadata.iconProvider = NSItemProvider(object: logo) }
        return metadata
    }
}
