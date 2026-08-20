import UIKit
import VisionKit

struct ImageTextRecognitionResult: Identifiable {
    let id = UUID()
    let image: UIImage
    let text: String
    let sourceURL: URL
}

enum ImageTextRecognitionError: LocalizedError {
    case unavailable
    case noText

    var errorDescription: String? {
        switch self {
        case .unavailable: return AppLocalization.string("image_text_unavailable")
        case .noText: return AppLocalization.string("image_text_none")
        }
    }
}

enum ImageTextRecognitionService {
    static func recognize(_ image: UIImage, sourceURL: URL) async throws -> ImageTextRecognitionResult {
        guard ImageAnalyzer.isSupported else { throw ImageTextRecognitionError.unavailable }
        let analyzer = ImageAnalyzer()
        var configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
        configuration.locales = Array(Locale.preferredLanguages.prefix(4))
        let analysis = try await analyzer.analyze(image, configuration: configuration)
        let text = analysis.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImageTextRecognitionError.noText }
        return ImageTextRecognitionResult(image: image, text: text, sourceURL: sourceURL)
    }
}

extension Notification.Name {
    static let imageTextRecognitionCompleted = Notification.Name("soulo.imageTextRecognitionCompleted")
    static let imageTextRecognitionFailed = Notification.Name("soulo.imageTextRecognitionFailed")
}
