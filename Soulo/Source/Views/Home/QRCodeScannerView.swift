import AVFoundation
import CoreImage
import PhotosUI
import SwiftUI
import Vision
import VisionKit
import WebKit

struct ScannedContent: Identifiable, Hashable {
    let id = UUID()
    let text: String
    static let codeTypes: [VNBarcodeSymbology] = [.qr, .aztec, .dataMatrix, .pdf417, .code128, .code39, .code93, .ean8, .ean13, .upce, .itf14]

    var webURL: URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(where: \.isWhitespace) else { return nil }
        if let explicit = URLComponents(string: value),
           ["https", "http"].contains(explicit.scheme?.lowercased() ?? ""),
           let host = explicit.host, !host.isEmpty { return explicit.url }
        guard !value.contains("://"),
              let address = URLComponents(string: "https://" + value),
              address.user == nil, address.password == nil,
              let host = address.host, host.contains(".") || host == "localhost" || host.contains(":"),
              let url = address.url else { return nil }
        return url
    }

    static func decodeImage(_ data: Data) throws -> String {
        try Task.checkCancellation()
        // Core Image supplies a CPU QR path on devices where Vision's inference
        // context is unavailable, including the simulator and older hardware.
        if let image = CIImage(data: data),
           let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
           let message = detector.features(in: image).compactMap({ ($0 as? CIQRCodeFeature)?.messageString }).first,
           !message.isEmpty { return message }
        #if targetEnvironment(simulator)
        // The simulator's revision 3/4 detector returns no observations for
        // valid linear codes; revision 2 retains its working CPU detector.
        let revisions = [2]
        #else
        let revisions = [VNDetectBarcodesRequestRevision4, VNDetectBarcodesRequestRevision3]
        #endif
        for revision in revisions {
            try Task.checkCancellation()
            let request = VNDetectBarcodesRequest()
            request.revision = revision
            request.symbologies = codeTypes
            #if targetEnvironment(simulator)
            request.usesCPUOnly = true
            #endif
            try? VNImageRequestHandler(data: data).perform([request])
            if let result = request.results?.compactMap(\.payloadStringValue).first, !result.isEmpty { return result }
        }

        try Task.checkCancellation()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.automaticallyDetectsLanguage = true
        textRequest.usesLanguageCorrection = true
        #if targetEnvironment(simulator)
        textRequest.usesCPUOnly = true
        #endif
        try VNImageRequestHandler(data: data).perform([textRequest])
        try Task.checkCancellation()
        let text = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ScannerError.noCode }
        return text
    }

    var html: String {
        func escaped(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline';">
        <style>
        :root{color-scheme:light dark;--bg:#f5f5f2;--card:#fff;--ink:#232c29;--muted:#818b85;--accent:#34806b;--line:#e8ece7}
        @media(prefers-color-scheme:dark){:root{--bg:#141715;--card:#1e2320;--ink:#e3e9e5;--muted:#a0afa5;--accent:#8bbda9;--line:#303b33}}
        *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:17px/1.8 -apple-system,BlinkMacSystemFont,sans-serif}
        main{max-width:720px;margin:0 auto;padding:36px 22px 64px}.mark{color:var(--accent);letter-spacing:.2em;font-size:11px;font-weight:700}
        h1{font-size:28px;line-height:1.25;letter-spacing:-.04em;margin:14px 0 28px;font-weight:600}
        article{padding:25px;background:var(--card);border:1px solid var(--line);border-radius:18px;white-space:pre-wrap;overflow-wrap:anywhere;user-select:text}
        footer{font-size:12px;color:var(--muted);padding-top:22px;letter-spacing:.04em}
        </style></head><body><main><div class="mark">SOULO · SCAN</div><h1>\(escaped(ToolText.text("scan_result")))</h1><article>\(escaped(text))</article><footer>\(escaped(ToolText.text("scan_local")))</footer></main></body></html>
        """
    }
}

private enum ScannerError: LocalizedError {
    case noCode
    var errorDescription: String? { ToolText.text("scan_no_code") }
}

struct QRCodeScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var authorized = false
    @State private var permissionChecked = false
    @State private var photo: PhotosPickerItem?
    @State private var error: String?
    @State private var processing = false
    @State private var didFinish = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if authorized && DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    CameraCodeScanner(onResult: finish, onError: { error = $0 })
                        .ignoresSafeArea()
                    VStack {
                        Spacer()
                        RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [32, 12]))
                            .frame(width: 240, height: 240)
                            .accessibilityHidden(true)
                        Text(ToolText.text("scan_hint")).font(.subheadline).foregroundStyle(.white.opacity(0.8)).padding(.top, 24)
                        Spacer()
                        photoButton.padding(.bottom, 24)
                    }
                    .allowsHitTesting(true)
                } else if permissionChecked {
                    VStack(spacing: 22) {
                        Image(systemName: "qrcode.viewfinder").font(.system(size: 52, weight: .light)).foregroundStyle(.white.opacity(0.7))
                        Text(ToolText.text("scan_camera_unavailable")).font(.body).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.8))
                        photoButton
                        if !authorized {
                            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                                Text(LanguageManager.shared.localizedString("settings"))
                            }
                        }
                    }.padding(32)
                } else { ProgressView().tint(.white) }
                if processing { ProgressView().tint(.white).padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18)) }
            }
            .navigationTitle(ToolText.text("scan_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(ToolText.text("close")) { dismiss() } }
            }
            .task {
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: authorized = true
                case .notDetermined:
                    if DataScannerViewController.isSupported { authorized = await AVCaptureDevice.requestAccess(for: .video) }
                default: authorized = false
                }
                permissionChecked = true
            }
            .task(id: photo) {
                guard let selected = photo else { return }
                processing = true
                defer { processing = false; photo = nil }
                do {
                    guard let data = try await selected.loadTransferable(type: Data.self) else { throw ScannerError.noCode }
                    try Task.checkCancellation()
                    let recognition = Task.detached(priority: .userInitiated) {
                        try autoreleasepool { try ScannedContent.decodeImage(data) }
                    }
                    let text = try await withTaskCancellationHandler {
                        try await recognition.value
                    } onCancel: { recognition.cancel() }
                    try Task.checkCancellation()
                    finish(text)
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            }
            .alert(ToolText.text("scan_qr"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(ToolText.text("done")) { error = nil }
            } message: { Text(error ?? "") }
        }
    }
    private var photoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Label(LanguageManager.shared.localizedString("photo_library"), systemImage: "photo")
                .font(.subheadline.weight(.medium)).padding(.horizontal, 22).padding(.vertical, 13)
                .foregroundStyle(.white).background(.white.opacity(0.15), in: Capsule())
        }.disabled(processing).accessibilityIdentifier("scanner.photos")
    }
    private func finish(_ value: String) {
        guard !didFinish else { return }
        didFinish = true
        HapticsManager.success()
        onResult(value)
    }
}

private struct CameraCodeScanner: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onError: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult, onError: onError) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: ScannedContent.codeTypes)], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        DispatchQueue.main.async {
            do { try controller.startScanning() }
            catch { onError(error.localizedDescription) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String) -> Void
        let onError: (String) -> Void
        init(onResult: @escaping (String) -> Void, onError: @escaping (String) -> Void) { self.onResult = onResult; self.onError = onError }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in addedItems {
                if let value = code.payloadStringValue, !value.isEmpty { scanner.stopScanning(); onResult(value); return }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) { onError(error.localizedDescription) }
    }
}

struct LocalScanResultView: View {
    let content: ScannedContent
    @State private var copied = false
    var body: some View {
        LocalScanPage(content: content)
            .navigationTitle(ToolText.text("scan_result"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { UIPasteboard.general.string = content.text; copied = true; HapticsManager.light() } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }.accessibilityLabel(ToolText.text(copied ? "copied" : "copy"))
                    ShareLink(item: content.text) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel(ToolText.text("share"))
                }
            }
    }
}
private struct LocalScanPage: UIViewRepresentable {
    let content: ScannedContent
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.loadHTMLString(content.html, baseURL: nil)
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
