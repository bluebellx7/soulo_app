import Photos
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
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

struct WebPagePDFResult: Identifiable {
    let id = UUID()
    let data: Data
    let fileName: String
    let pageCount: Int
    let wasPageLimited: Bool
}

struct WebPagePDFDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw WebPageCaptureError.captureFailed
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
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
    /// Avoid pathological pages creating a bitmap wider than Core Graphics can
    /// safely allocate. Ordinary mobile and desktop layouts remain uncapped.
    static let maximumFullPageWidth: CGFloat = 4_096
    /// Keeps the finished bitmap near 80 MB while retaining Retina detail for
    /// ordinary pages. Very long pages scale down gradually instead of always
    /// being flattened to a blurry 1× canvas.
    static let maximumFullPagePixelCount: CGFloat = 20_000_000
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
    await new Promise(resolve => {
        // A page can stop producing animation frames while timers still run.
        // Keep capture responsive instead of waiting indefinitely for a frame.
        const timer = setTimeout(resolve, 250);
        requestAnimationFrame(() => requestAnimationFrame(() => {
            clearTimeout(timer);
            resolve();
        }));
    });
    return { imageCount: imageTasks.length, documentHeight: documentHeight };
    """#

    static func capture(_ mode: WebPageCaptureMode, from webView: WKWebView?) async throws -> WebPageCaptureResult {
        guard let webView else { throw WebPageCaptureError.unavailable }
        let bounds = captureBounds(for: webView.bounds)
        guard bounds.width > 1, bounds.height > 1 else { throw WebPageCaptureError.emptyPage }
        webView.layoutIfNeeded()
        await waitForRenderingCycle(in: webView)

        switch mode {
        case .viewport:
            let configuration = snapshotConfiguration(for: bounds)
            let image = try await snapshot(webView, configuration: configuration)
            return WebPageCaptureResult(image: image, mode: mode, wasHeightLimited: false)
        case .fullPage:
            await prepareResourcesForCapture(
                in: webView,
                maximumHeight: maximumFullPageHeight
            )
            let contentSize = webView.scrollView.contentSize
            let contentWidth = max(contentSize.width, bounds.width)
            let contentHeight = max(contentSize.height, bounds.height)
            let captureWidth = fullPageCaptureWidth(
                contentWidth: contentWidth,
                viewportWidth: bounds.width
            )
            let captureHeight = fullPageCaptureHeight(contentHeight: contentHeight, viewportHeight: bounds.height)
            let image = try await captureFullPage(
                webView,
                bounds: bounds,
                contentSize: contentSize,
                captureSize: CGSize(width: captureWidth, height: captureHeight)
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
        contentSize: CGSize,
        captureSize: CGSize
    ) async throws -> UIImage {
        let originalOffset = webView.scrollView.contentOffset
        let maximumOffsetX = max(0, contentSize.width - bounds.width)
        let maximumOffsetY = max(0, contentSize.height - bounds.height)
        let pageBackground = await pageBackgroundColor(in: webView)
        let captureScale = fullPageCaptureScale(
            width: captureSize.width,
            height: captureSize.height,
            displayScale: UIScreen.main.scale
        )
        let pixelWidth = max(Int(ceil(captureSize.width * captureScale)), 1)
        let pixelHeight = max(Int(ceil(captureSize.height * captureScale)), 1)
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
        canvas.fill(CGRect(origin: .zero, size: captureSize))
        canvas.interpolationQuality = .high

        let horizontalTiles = tileSpans(
            totalLength: captureSize.width,
            viewportLength: bounds.width,
            maximumContentOffset: maximumOffsetX
        )
        let verticalTiles = tileSpans(
            totalLength: captureSize.height,
            viewportLength: bounds.height,
            maximumContentOffset: maximumOffsetY
        )
        var renderedTileCount = 0

        do {
            for horizontalTile in horizontalTiles {
                for verticalTile in verticalTiles {
                    webView.scrollView.setContentOffset(
                        CGPoint(
                            x: horizontalTile.contentOffset,
                            y: verticalTile.contentOffset
                        ),
                        animated: false
                    )
                    webView.layoutIfNeeded()
                    try? await Task.sleep(nanoseconds: 130_000_000)

                    let configuration = snapshotConfiguration(for: bounds)
                    let image = try await snapshot(webView, configuration: configuration)
                    let destinationRect = CGRect(
                        x: horizontalTile.destinationOrigin,
                        y: verticalTile.destinationOrigin,
                        width: horizontalTile.length,
                        height: verticalTile.length
                    )

                    canvas.saveGState()
                    canvas.clip(to: destinationRect)
                    UIGraphicsPushContext(canvas)
                    image.draw(
                        in: CGRect(
                            x: horizontalTile.destinationOrigin - horizontalTile.sourceOrigin,
                            y: verticalTile.destinationOrigin - verticalTile.sourceOrigin,
                            width: bounds.width,
                            height: bounds.height
                        )
                    )
                    UIGraphicsPopContext()
                    canvas.restoreGState()
                    renderedTileCount += 1
                }
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

    static func fullPageCaptureWidth(contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(contentWidth, viewportWidth), maximumFullPageWidth)
    }

    static func fullPageCaptureScale(
        width: CGFloat,
        height: CGFloat,
        displayScale: CGFloat
    ) -> CGFloat {
        guard width > 0, height > 0 else { return 1 }
        let pixelBudgetScale = sqrt(maximumFullPagePixelCount / (width * height))
        return max(0.5, min(max(displayScale, 1), 3, pixelBudgetScale))
    }

    static func captureBounds(for bounds: CGRect) -> CGRect {
        CGRect(
            origin: .zero,
            size: CGSize(width: max(bounds.width, 0), height: max(bounds.height, 0))
        )
    }

    /// `snapshotWidth` is measured in points. Setting it to the WebView width
    /// makes WebKit return the complete viewport deterministically without
    /// accidentally multiplying the logical width by the display scale.
    static func snapshotConfiguration(for bounds: CGRect) -> WKSnapshotConfiguration {
        let rect = captureBounds(for: bounds)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(rect.width))
        configuration.afterScreenUpdates = true
        return configuration
    }

    struct TileSpan: Equatable {
        let destinationOrigin: CGFloat
        let contentOffset: CGFloat
        let sourceOrigin: CGFloat
        let length: CGFloat
    }

    static func tileSpans(
        totalLength: CGFloat,
        viewportLength: CGFloat,
        maximumContentOffset: CGFloat
    ) -> [TileSpan] {
        guard totalLength > 0, viewportLength > 0 else { return [] }
        var result: [TileSpan] = []
        var destination: CGFloat = 0
        let maximumOffset = max(maximumContentOffset, 0)

        while destination < totalLength - 0.5 {
            let offset = min(destination, maximumOffset)
            let source = max(destination - offset, 0)
            let length = min(viewportLength - source, totalLength - destination)
            guard length > 0.5 else { break }
            result.append(
                TileSpan(
                    destinationOrigin: destination,
                    contentOffset: offset,
                    sourceOrigin: source,
                    length: length
                )
            )
            destination += length
        }
        return result
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

    static func prepareResourcesForCapture(
        in webView: WKWebView,
        maximumHeight: CGFloat
    ) async {
        _ = try? await webView.callAsyncJavaScript(
            resourcePreparationScript,
            arguments: ["maximumHeight": Double(max(maximumHeight, 1))],
            in: nil,
            contentWorld: .page
        )
    }

    private static func waitForRenderingCycle(in webView: WKWebView) async {
        let script = #"""
        await new Promise(resolve => {
            // A page can stop producing animation frames while timers still run.
            // Keep capture responsive instead of waiting indefinitely for a frame.
            const timer = setTimeout(resolve, 250);
            requestAnimationFrame(() => requestAnimationFrame(() => {
                clearTimeout(timer);
                resolve();
            }));
        });
        return true;
        """#
        _ = try? await webView.callAsyncJavaScript(
            script,
            arguments: [:],
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

@MainActor
enum WebPagePDFService {
    static let pageAspectRatio: CGFloat = 297 / 210
    static let maximumPageCount = 200
    static let maximumPageWidth = WebPageCaptureService.maximumFullPageWidth

    static func export(
        from webView: WKWebView?,
        title: String
    ) async throws -> WebPagePDFResult {
        guard let webView else { throw WebPageCaptureError.unavailable }
        let bounds = WebPageCaptureService.captureBounds(for: webView.bounds)
        guard bounds.width > 1, bounds.height > 1 else { throw WebPageCaptureError.emptyPage }

        webView.layoutIfNeeded()
        let initialContentWidth = max(webView.scrollView.contentSize.width, bounds.width)
        await WebPageCaptureService.prepareResourcesForCapture(
            in: webView,
            maximumHeight: maximumPreparedContentHeight(pageWidth: initialContentWidth)
        )

        let contentSize = webView.scrollView.contentSize
        let layout = pageLayout(
            contentSize: contentSize,
            viewportSize: bounds.size
        )
        guard !layout.rects.isEmpty else { throw WebPageCaptureError.emptyPage }

        let output = PDFDocument()
        output.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: title,
            PDFDocumentAttribute.creatorAttribute: "Soulo",
            PDFDocumentAttribute.producerAttribute: "Soulo WebKit PDF"
        ]

        for rect in layout.rects {
            try Task.checkCancellation()
            let configuration = WKPDFConfiguration()
            configuration.rect = rect
            if #available(iOS 17.0, *) {
                configuration.allowTransparentBackground = false
            }
            let data = try await webView.pdf(configuration: configuration)
            guard let pageDocument = PDFDocument(data: data),
                  let page = pageDocument.page(at: 0),
                  let copiedPage = page.copy() as? PDFPage else {
                throw WebPageCaptureError.captureFailed
            }
            output.insert(copiedPage, at: output.pageCount)
        }

        guard output.pageCount == layout.rects.count,
              let data = output.dataRepresentation(),
              !data.isEmpty else {
            throw WebPageCaptureError.captureFailed
        }

        let fallbackTitle = webView.url?.host ?? "Web Page"
        let fileName = DownloadFilenameSanitizer.sanitize(
            title,
            fallbackBaseName: fallbackTitle,
            preferredExtension: "pdf"
        )
        return WebPagePDFResult(
            data: data,
            fileName: fileName,
            pageCount: output.pageCount,
            wasPageLimited: layout.wasLimited
        )
    }

    struct PageLayout: Equatable {
        let rects: [CGRect]
        let wasLimited: Bool
    }

    static func pageLayout(
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> PageLayout {
        let pageWidth = min(max(max(contentSize.width, viewportSize.width), 1), maximumPageWidth)
        let pageHeight = max(pageWidth * pageAspectRatio, 1)
        let contentHeight = max(max(contentSize.height, viewportSize.height), 1)
        let requiredPageCount = max(Int(ceil(contentHeight / pageHeight)), 1)
        let pageCount = min(requiredPageCount, maximumPageCount)
        let rects = (0..<pageCount).map { index in
            CGRect(
                x: 0,
                y: CGFloat(index) * pageHeight,
                width: pageWidth,
                height: pageHeight
            )
        }
        return PageLayout(rects: rects, wasLimited: requiredPageCount > pageCount)
    }

    private static func maximumPreparedContentHeight(pageWidth: CGFloat) -> CGFloat {
        let width = min(max(pageWidth, 1), maximumPageWidth)
        return width * pageAspectRatio * CGFloat(maximumPageCount)
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
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    ScrollView(.vertical) {
                        let size = previewSize(in: proxy.size)
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
                                .frame(width: size.width, height: size.height)
                                .background(Color.white)
                                .overlay {
                                    Rectangle()
                                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                                }
                                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                                .frame(maxWidth: .infinity)
                        }
                        .padding(16)
                    }
                }
                .frame(maxHeight: .infinity)

                captureActions
            }
            .background(Color(uiColor: .secondarySystemBackground).ignoresSafeArea())
            .navigationTitle(LanguageManager.shared.localizedString(result.mode.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
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

    private var captureActions: some View {
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
                    .padding(.vertical, 12)
                    .foregroundStyle(Color.primary)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func previewSize(in availableSize: CGSize) -> CGSize {
        let maximumWidth = max(availableSize.width - 32, 1)
        let aspectRatio = result.image.size.height / max(result.image.size.width, 1)
        let width: CGFloat
        if result.mode == .viewport {
            // Fit against the sheet's actual content area rather than the
            // device screen. This keeps every edge visible in compact sheets,
            // split view, landscape, and devices with horizontal safe areas.
            let maximumHeight = max(availableSize.height - 96, 220)
            width = min(result.image.size.width, maximumWidth, maximumHeight / max(aspectRatio, 0.01))
        } else {
            // Long captures remain vertically scrollable and always scale the
            // complete bitmap width into the actual presentation container.
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

struct WebPagePDFPreview: View {
    let result: WebPagePDFResult

    @Environment(\.dismiss) private var dismiss
    @State private var showExporter = false
    @State private var showShareSheet = false
    @State private var shareURL: URL?
    @State private var shareDirectory: URL?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if result.wasPageLimited {
                    Label(
                        LanguageManager.shared.localizedString("web_capture_pdf_limited"),
                        systemImage: "doc.badge.ellipsis"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
                }

                PDFDocumentView(data: result.data)
                    .background(Color(uiColor: .secondarySystemBackground))

                pdfActions
            }
            .navigationTitle(LanguageManager.shared.localizedString("web_capture_pdf"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(LanguageManager.shared.localizedString("done")) { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: WebPagePDFDocument(data: result.data),
                contentType: .pdf,
                defaultFilename: result.fileName
            ) { exportResult in
                if case let .failure(error) = exportResult {
                    errorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let shareURL {
                    CaptureShareSheet(items: [shareURL])
                }
            }
            .alert(
                LanguageManager.shared.localizedString("save_failed"),
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button(LanguageManager.shared.localizedString("confirm"), role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear(perform: removeTemporaryShareFile)
        }
    }

    private var pdfActions: some View {
        HStack(spacing: 12) {
            Button {
                showExporter = true
            } label: {
                Label(LanguageManager.shared.localizedString("save"), systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button(action: sharePDF) {
                Label(LanguageManager.shared.localizedString("share"), systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(Color.primary)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: Capsule(style: .continuous)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    private func sharePDF() {
        do {
            removeTemporaryShareFile()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Soulo-PDF-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(result.fileName)
            try result.data.write(to: url, options: .atomic)
            shareDirectory = directory
            shareURL = url
            showShareSheet = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeTemporaryShareFile() {
        if let shareDirectory {
            try? FileManager.default.removeItem(at: shareDirectory)
        }
        shareDirectory = nil
        shareURL = nil
    }
}

private struct PDFDocumentView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(data: data)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        // The preview data is immutable for the lifetime of this sheet. Avoid
        // reserializing a potentially large PDF during unrelated SwiftUI updates.
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
