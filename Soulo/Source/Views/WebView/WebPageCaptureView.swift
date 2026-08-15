import Photos
import SwiftUI
import VisionKit
import WebKit

enum WebPageCaptureMode: String, Identifiable {
    case viewport
    case fullPage

    var id: String { rawValue }
    var titleKey: String { self == .viewport ? "web_capture_viewport" : "web_capture_full_page" }
}

struct WebPageCaptureResult: Identifiable {
    let id = UUID()
    let image: UIImage
    let mode: WebPageCaptureMode
    let wasHeightLimited: Bool
}

enum WebPageCaptureError: LocalizedError {
    case unavailable
    case emptyPage
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .unavailable: AppLocalization.string("web_capture_unavailable")
        case .emptyPage: AppLocalization.string("web_capture_empty")
        case .captureFailed: AppLocalization.string("web_capture_failed")
        }
    }
}

@MainActor
enum WebPageCaptureService {
    static let maximumFullPageHeight: CGFloat = 12_000
    /// Keeps the finished bitmap near 80 MB while retaining Retina detail for
    /// ordinary pages. Very long pages scale down gradually instead of always
    /// being flattened to a blurry 1× canvas.
    static let maximumFullPagePixelCount: CGFloat = 20_000_000
    /// Matches the breathing room around the live browser page so a stitched
    /// image does not look horizontally cropped when viewed on its own.
    static let fullPageHorizontalInset: CGFloat = 16
    static let pageBackgroundColorScript = #"""
    (function() {
        function usable(color) {
            if (!color || color === 'transparent') return null;
            var compact = String(color).replace(/\s+/g, '');
            if (compact === 'rgba(0,0,0,0)') return null;
            return color;
        }
        var bodyColor = document.body ? usable(getComputedStyle(document.body).backgroundColor) : null;
        var rootColor = document.documentElement
            ? usable(getComputedStyle(document.documentElement).backgroundColor)
            : null;
        return bodyColor || rootColor || 'rgb(255, 255, 255)';
    })();
    """#
    static let resourcePreparationScript = #"""
    const originalX = window.scrollX;
    const originalY = window.scrollY;
    const viewport = Math.max(window.innerHeight || 0, 1);
    const documentHeight = Math.max(
        document.documentElement ? document.documentElement.scrollHeight : 0,
        document.body ? document.body.scrollHeight : 0,
        viewport
    );
    const limit = Math.min(documentHeight, maximumHeight);
    const step = Math.max(viewport * 0.8, 320);
    const pause = (milliseconds) => new Promise(resolve => setTimeout(resolve, milliseconds));

    // Visit the capture range so intersection observers and native lazy-loading
    // have a chance to request off-screen images before the snapshot is taken.
    for (let y = 0; y < limit; y += step) {
        window.scrollTo(originalX, y);
        await pause(90);
    }
    window.scrollTo(originalX, Math.max(0, limit - viewport));
    await pause(160);

    const imageTasks = Array.from(document.images).slice(0, 240).map(image => {
        if (image.complete) {
            return typeof image.decode === 'function' ? image.decode().catch(() => {}) : Promise.resolve();
        }
        return new Promise(resolve => {
            const finish = () => resolve();
            image.addEventListener('load', finish, { once: true });
            image.addEventListener('error', finish, { once: true });
        });
    });
    const resourcesReady = Promise.all(imageTasks);
    const fontsReady = document.fonts && document.fonts.ready
        ? document.fonts.ready.catch(() => {})
        : Promise.resolve();
    await Promise.race([
        Promise.all([resourcesReady, fontsReady]),
        pause(2800)
    ]);

    window.scrollTo(originalX, originalY);
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return { imageCount: imageTasks.length, documentHeight: documentHeight };
    """#

    static func capture(_ mode: WebPageCaptureMode, from webView: WKWebView?) async throws -> WebPageCaptureResult {
        guard let webView else { throw WebPageCaptureError.unavailable }
        let bounds = webView.bounds
        guard bounds.width > 1, bounds.height > 1 else { throw WebPageCaptureError.emptyPage }

        switch mode {
        case .viewport:
            let configuration = snapshotConfiguration(for: bounds)
            let image = try await snapshot(webView, configuration: configuration)
            return WebPageCaptureResult(image: image, mode: mode, wasHeightLimited: false)
        case .fullPage:
            await prepareResourcesForFullPageCapture(in: webView)
            let contentHeight = max(webView.scrollView.contentSize.height, bounds.height)
            let captureHeight = fullPageCaptureHeight(contentHeight: contentHeight, viewportHeight: bounds.height)
            let image = try await captureFullPage(
                webView,
                bounds: bounds,
                captureHeight: captureHeight
            )
            return WebPageCaptureResult(
                image: image,
                mode: mode,
                wasHeightLimited: contentHeight > captureHeight + 1
            )
        }
    }

    private static func snapshot(
        _ webView: WKWebView,
        configuration: WKSnapshotConfiguration
    ) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? WebPageCaptureError.captureFailed)
                }
            }
        }
    }

    private static func captureFullPage(
        _ webView: WKWebView,
        bounds: CGRect,
        captureHeight: CGFloat
    ) async throws -> UIImage {
        let originalOffset = webView.scrollView.contentOffset
        let maximumOffsetY = max(0, webView.scrollView.contentSize.height - bounds.height)
        let outputWidth = fullPageOutputWidth(viewportWidth: bounds.width)
        let pageBackground = await pageBackgroundColor(in: webView)
        let captureScale = fullPageCaptureScale(
            width: outputWidth,
            height: captureHeight,
            displayScale: UIScreen.main.scale
        )
        let pixelWidth = max(Int(ceil(outputWidth * captureScale)), 1)
        let pixelHeight = max(Int(ceil(captureHeight * captureScale)), 1)
        guard let canvas = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw WebPageCaptureError.captureFailed
        }

        // Make the bitmap context use UIKit's point-based, top-left coordinate
        // system so each tile can be drawn immediately and then released.
        canvas.translateBy(x: 0, y: CGFloat(pixelHeight))
        canvas.scaleBy(x: captureScale, y: -captureScale)
        canvas.setFillColor(pageBackground.cgColor)
        canvas.fill(CGRect(x: 0, y: 0, width: outputWidth, height: captureHeight))
        canvas.interpolationQuality = .high

        var destinationY: CGFloat = 0
        var renderedTileCount = 0

        do {
            while destinationY < captureHeight - 0.5 {
                let offsetY = min(destinationY, maximumOffsetY)
                webView.scrollView.setContentOffset(
                    CGPoint(x: originalOffset.x, y: offsetY),
                    animated: false
                )
                webView.layoutIfNeeded()
                try? await Task.sleep(nanoseconds: 130_000_000)

                let configuration = snapshotConfiguration(for: bounds)
                let image = try await snapshot(webView, configuration: configuration)

                let sourceStartY = max(0, destinationY - offsetY)
                let visibleHeight = min(
                    bounds.height - sourceStartY,
                    captureHeight - destinationY
                )
                guard visibleHeight > 0.5 else { break }

                let destinationRect = CGRect(
                    x: fullPageHorizontalInset,
                    y: destinationY,
                    width: bounds.width,
                    height: visibleHeight
                )
                canvas.saveGState()
                canvas.clip(to: destinationRect)
                UIGraphicsPushContext(canvas)
                image.draw(
                    in: CGRect(
                        x: fullPageHorizontalInset,
                        y: destinationY - sourceStartY,
                        width: bounds.width,
                        height: bounds.height
                    )
                )
                UIGraphicsPopContext()
                canvas.restoreGState()

                renderedTileCount += 1
                destinationY += visibleHeight
            }
        } catch {
            webView.scrollView.setContentOffset(originalOffset, animated: false)
            throw error
        }

        webView.scrollView.setContentOffset(originalOffset, animated: false)
        webView.layoutIfNeeded()
        guard renderedTileCount > 0, let cgImage = canvas.makeImage() else {
            throw WebPageCaptureError.captureFailed
        }
        return UIImage(cgImage: cgImage, scale: captureScale, orientation: .up)
    }

    static func fullPageCaptureHeight(contentHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        min(max(contentHeight, viewportHeight), maximumFullPageHeight)
    }

    static func fullPageOutputWidth(viewportWidth: CGFloat) -> CGFloat {
        max(viewportWidth, 0) + fullPageHorizontalInset * 2
    }

    static func fullPageCaptureScale(
        width: CGFloat,
        height: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let pixelBudgetScale = sqrt(maximumFullPagePixelCount / (width * height))
        return max(1, min(max(displayScale, 1), 3, pixelBudgetScale))
    }

    /// Keep WebKit's capture rectangle in view coordinates. `snapshotWidth` is
    /// expressed in points, not pixels; multiplying it by the display scale
    /// changes the logical output size and can make a viewport capture appear
    /// cropped or alter a page's horizontal margins. WebKit already returns a
    /// Retina UIImage, while the long-image canvas controls final pixel density.
    static func snapshotConfiguration(for bounds: CGRect) -> WKSnapshotConfiguration {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = bounds
        configuration.snapshotWidth = nil
        configuration.afterScreenUpdates = true
        return configuration
    }

    static func colorFromComputedCSS(_ value: String?) -> UIColor? {
        guard let value else { return nil }
        let components = value
            .components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
            .filter { !$0.isEmpty }
            .compactMap(Double.init)
        guard components.count >= 3 else { return nil }
        let alpha = components.count >= 4 ? components[3] : 1
        return UIColor(
            red: min(max(components[0] / 255, 0), 1),
            green: min(max(components[1] / 255, 0), 1),
            blue: min(max(components[2] / 255, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }

    private static func pageBackgroundColor(in webView: WKWebView) async -> UIColor {
        let value = try? await webView.evaluateJavaScript(pageBackgroundColorScript)
        return colorFromComputedCSS(value as? String) ?? .white
    }

    private static func prepareResourcesForFullPageCapture(in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            resourcePreparationScript,
            arguments: ["maximumHeight": Double(maximumFullPageHeight)],
            in: nil,
            contentWorld: .page
        )
    }

    static func saveToPhotoLibrary(_ image: UIImage) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(
                domain: "Soulo.WebPageCapture",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: LanguageManager.shared.localizedString("web_capture_photo_permission")]
            )
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}

struct WebPageCapturePreview: View {
    let result: WebPageCaptureResult

    @Environment(\.dismiss) private var dismiss
    @State private var showShareSheet = false
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveSucceeded = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(uiColor: .secondarySystemBackground).ignoresSafeArea()
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 12) {
                        if result.wasHeightLimited {
                            Label(
                                LanguageManager.shared.localizedString("web_capture_height_limited"),
                                systemImage: "scissors"
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        Label(
                            LanguageManager.shared.localizedString("web_capture_live_text_hint"),
                            systemImage: "text.viewfinder"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        LiveTextCaptureImage(image: result.image)
                            .frame(width: previewSize.width, height: previewSize.height)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    }
                    .padding(16)
                }
            }
            .navigationTitle(LanguageManager.shared.localizedString(result.mode.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        saveImage()
                    } label: {
                        Label(
                            LanguageManager.shared.localizedString("web_capture_save"),
                            systemImage: saveSucceeded ? "checkmark.circle.fill" : "square.and.arrow.down"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving || saveSucceeded)

                    Button {
                        showShareSheet = true
                    } label: {
                        Label(LanguageManager.shared.localizedString("share"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
            .overlay {
                if isSaving {
                    ProgressView()
                        .padding(22)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .alert(
                LanguageManager.shared.localizedString(saveSucceeded ? "web_capture_saved" : "save_failed"),
                isPresented: Binding(
                    get: { saveMessage != nil },
                    set: { if !$0 { saveMessage = nil } }
                )
            ) {
                Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
            } message: {
                Text(saveMessage ?? "")
            }
            .sheet(isPresented: $showShareSheet) {
                CaptureShareSheet(items: [result.image])
            }
        }
    }

    private var previewSize: CGSize {
        let maximumWidth = max(UIScreen.main.bounds.width - 32, 240)
        let aspectRatio = result.image.size.height / max(result.image.size.width, 1)
        let width: CGFloat
        if result.mode == .viewport {
            // A viewport screenshot should be visible in full on first open;
            // reserve room for the title, Live Text hint, and bottom actions.
            let maximumHeight = max(UIScreen.main.bounds.height - 270, 300)
            width = min(result.image.size.width, maximumWidth, maximumHeight / max(aspectRatio, 0.01))
        } else {
            // Full-page captures intentionally use the available width and
            // remain vertically scrollable so their details stay readable.
            width = min(result.image.size.width, maximumWidth)
        }
        return CGSize(width: width, height: width * aspectRatio)
    }

    private func saveImage() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            do {
                try await WebPageCaptureService.saveToPhotoLibrary(result.image)
                saveSucceeded = true
                saveMessage = LanguageManager.shared.localizedString("web_capture_saved_desc")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                saveSucceeded = false
                saveMessage = error.localizedDescription
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            isSaving = false
        }
    }
}

private struct LiveTextCaptureImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.isUserInteractionEnabled = true

        let interaction = ImageAnalysisInteraction()
        interaction.preferredInteractionTypes = .automatic
        imageView.addInteraction(interaction)
        context.coordinator.interaction = interaction
        context.coordinator.analyze(image)
        return imageView
    }

    func updateUIView(_ imageView: UIImageView, context: Context) {
        guard imageView.image !== image else { return }
        imageView.image = image
        context.coordinator.analyze(image)
    }

    final class Coordinator {
        weak var interaction: ImageAnalysisInteraction?
        private var analysisTask: Task<Void, Never>?

        deinit {
            analysisTask?.cancel()
        }

        func analyze(_ image: UIImage) {
            analysisTask?.cancel()
            analysisTask = Task { @MainActor [weak self] in
                guard ImageAnalyzer.isSupported else { return }
                let configuration = ImageAnalyzer.Configuration([.text])
                guard let analysis = try? await ImageAnalyzer().analyze(
                    image,
                    orientation: image.imageOrientation,
                    configuration: configuration
                ), !Task.isCancelled else { return }
                self?.interaction?.analysis = analysis
            }
        }
    }
}

private struct CaptureShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
