import SwiftUI
import CoreImage.CIFilterBuiltins
import Photos
import LinkPresentation

/// Encodes the exact page URL locally. Integer module sizing and a white quiet zone
/// remain intact in both appearance modes and in the exported image.
enum WebPageQRCodeService {
    static func canEncode(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    @MainActor static func saveToPhotos(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Soulo.PageQRCode", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: ToolText.text("page_qr_photo_permission")])
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }

    static func image(for url: URL, favicon: UIImage? = nil) async -> UIImage? {
        guard canEncode(url) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(url.absoluteString.utf8)
            filter.correctionLevel = "H"
            guard let output = filter.outputImage,
                  let code = CIContext().createCGImage(output, from: output.extent) else { return nil }
            let modules = code.width
            let moduleSize = max(4, 1024 / (modules + 8))
            let side = CGFloat((modules + 8) * moduleSize)
            let inset = CGFloat(4 * moduleSize)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(x: 0, y: 0, width: side, height: side))
                context.cgContext.interpolationQuality = .none
                UIImage(cgImage: code).draw(in: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2))
                if let favicon {
                    // Small logo + level H correction; never cover finder patterns.
                    let size = CGFloat(modules * moduleSize) * 0.15
                    let tile = CGRect(x: (side - size) / 2, y: (side - size) / 2, width: size, height: size)
                    UIColor.white.setFill()
                    UIBezierPath(roundedRect: tile, cornerRadius: size * 0.18).fill()
                    let content = tile.insetBy(dx: size * 0.13, dy: size * 0.13)
                    let ratio = min(content.width / max(1, favicon.size.width), content.height / max(1, favicon.size.height))
                    let imageSize = CGSize(width: favicon.size.width * ratio, height: favicon.size.height * ratio)
                    context.cgContext.interpolationQuality = .high
                    favicon.draw(in: CGRect(x: content.midX - imageSize.width / 2, y: content.midY - imageSize.height / 2,
                                            width: imageSize.width, height: imageSize.height))
                }
            }
        }.value
    }
}

struct WebPageQRCodeView: View {
    let url: URL
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var generating = true
    @State private var saving = false
    @State private var saved = false
    @State private var copied = false
    @State private var showShare = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        ToolIllustration(scene: .pageQR, height: 100)
                        Text(title.isEmpty ? (url.host ?? "") : title)
                            .font(.title3.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                        Text(url.host ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Group {
                        if let image {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .accessibilityLabel(ToolText.text("page_qr_title"))
                                .accessibilityIdentifier("pageQR.image")
                        } else if generating {
                            ProgressView().frame(height: 260)
                        } else {
                            ContentUnavailableView(ToolText.text("page_qr_failed"), systemImage: "qrcode")
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 300)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.black.opacity(0.06), lineWidth: 1) }

                    Text(url.absoluteString)
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                    Text(ToolText.text("page_qr_hint"))
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("pageQR.error")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { saveButton; copyButton; shareButton }
                        VStack(spacing: 10) { saveButton; copyButton; shareButton }
                    }
                }
                .frame(maxWidth: 440).padding(20).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(ToolText.text("page_qr_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(ToolText.text("done")) { dismiss() }.disabled(saving)
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $showShare) {
                if let image { PageQRCodeShareSheet(image: image, title: title.isEmpty ? (url.host ?? "") : title) }
            }
            .task(id: copied) {
                guard copied else { return }
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
            .task(id: url) {
                image = await WebPageQRCodeService.image(for: url)
                guard !Task.isCancelled else { return }
                generating = false
                guard image != nil else { return }
                // A slow or missing favicon never delays access to the QR code.
                if let favicon = await WebsiteFaviconService.shared.image(for: url.absoluteString),
                   let decorated = await WebPageQRCodeService.image(for: url, favicon: favicon), !Task.isCancelled {
                    image = decorated
                }
            }
        }
    }

    private var saveButton: some View {
        Button {
            guard let image, !saving else { return }
            saving = true
            error = nil
            Task {
                defer { saving = false }
                do {
                    try await WebPageQRCodeService.saveToPhotos(image)
                    saved = true
                    HapticsManager.success()
                } catch { self.error = error.localizedDescription }
            }
        } label: {
            VStack(spacing: 7) {
                if saving { ProgressView().frame(height: 22) }
                else { Image(systemName: saved ? "checkmark" : "square.and.arrow.down").font(.system(size: 21)) }
                Text(saved ? ToolText.text("page_qr_saved_short") : LanguageManager.shared.localizedString("save"))
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(image == nil || saving || saved)
        .accessibilityIdentifier("pageQR.save")
        .accessibilityLabel(saved ? ToolText.text("page_qr_saved") : LanguageManager.shared.localizedString("save_to_photos"))
    }

    private var copyButton: some View {
        Button {
            guard let image else { return }
            UIPasteboard.general.image = image
            copied = true
            HapticsManager.success()
        } label: {
            actionLabel(copied ? ToolText.text("copied") : ToolText.text("page_qr_copy_image"),
                        symbol: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(image == nil || saving)
        .accessibilityIdentifier("pageQR.copy")
    }

    private func actionLabel(_ title: String, symbol: String) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 21))
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
    }

    private var shareButton: some View {
        Button { showShare = true } label: {
            actionLabel(ToolText.text("share"), symbol: "square.and.arrow.up")
        }
        .buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle(radius: 14))
        .disabled(image == nil || saving)
        .accessibilityIdentifier("pageQR.share")
    }
}

private struct PageQRCodeShareSheet: UIViewControllerRepresentable {
    let image: UIImage
    let title: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [PageQRCodeShareItem(image: image, title: title)], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private final class PageQRCodeShareItem: NSObject, UIActivityItemSource {
    let image: UIImage
    let title: String

    init(image: UIImage, title: String) { self.image = image; self.title = title }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { image }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { image }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { title }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.imageProvider = NSItemProvider(object: image)
        metadata.iconProvider = NSItemProvider(object: image)
        return metadata
    }
}
