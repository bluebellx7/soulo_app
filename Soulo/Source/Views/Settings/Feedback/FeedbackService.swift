import Foundation
import UIKit

struct FeedbackDiagnosticField: Identifiable, Equatable {
    let id: String
    let titleKey: String
    let value: String
}

struct FeedbackDiagnostics: Equatable {
    let fields: [FeedbackDiagnosticField]
    var values: [String: String] { Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.value) }) }

    @MainActor static func capture() -> FeedbackDiagnostics {
        let device = UIDevice.current
        let process = ProcessInfo.processInfo
        let screen = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.screen ?? UIScreen.main
        var machine = utsname()
        uname(&machine)
        let machineSize = MemoryLayout.size(ofValue: machine.machine)
        let hardware = withUnsafePointer(to: &machine.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: machineSize) {
                String(cString: $0)
            }
        }
        let model = process.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware
        let defaults = UserDefaults.standard
        func flag(_ key: String, fallback: Bool) -> String {
            String(defaults.object(forKey: key) as? Bool ?? fallback)
        }
        let extensions = BrowserExtensionService.shared
        let fields: [FeedbackDiagnosticField] = [
            .init(id: "app", titleKey: "feedback_diag_app", value: "\(SouloFeedbackService.appName) \(SouloFeedbackService.appVersion) (\(SouloFeedbackService.buildNumber))"),
            .init(id: "bundleID", titleKey: "feedback_diag_bundle", value: Bundle.main.bundleIdentifier ?? "unknown"),
            .init(id: "device", titleKey: "feedback_diag_device", value: "\(device.model) · \(model)"),
            .init(id: "system", titleKey: "feedback_diag_system", value: "\(device.systemName) \(device.systemVersion)"),
            .init(id: "screen", titleKey: "feedback_diag_screen", value: "\(Int(screen.bounds.width)) × \(Int(screen.bounds.height)) pt · @\(screen.scale)"),
            .init(id: "memory", titleKey: "feedback_diag_memory", value: ByteCountFormatter.string(fromByteCount: Int64(process.physicalMemory), countStyle: .memory)),
            .init(id: "language", titleKey: "feedback_diag_language", value: LanguageManager.shared.currentLanguage),
            .init(id: "locale", titleKey: "feedback_diag_locale", value: Locale.current.identifier),
            .init(id: "timeZone", titleKey: "feedback_diag_timezone", value: TimeZone.current.identifier),
            .init(id: "appearance", titleKey: "feedback_diag_appearance", value: defaults.string(forKey: "appearance") ?? "system"),
            .init(id: "lowPowerMode", titleKey: "feedback_diag_low_power", value: String(process.isLowPowerModeEnabled)),
            .init(id: "thermalState", titleKey: "feedback_diag_thermal", value: String(describing: process.thermalState)),
            .init(id: "adBlock", titleKey: "feedback_diag_adblock", value: flag("ad_block_enabled", fallback: true)),
            .init(id: "httpsUpgrade", titleKey: "privacy_https_upgrade", value: flag("privacy_https_upgrade_enabled", fallback: PrivacyFeatureDefaults.httpsUpgradeEnabled)),
            .init(id: "stripTracking", titleKey: "privacy_strip_tracking", value: flag("privacy_strip_tracking_parameters", fallback: PrivacyFeatureDefaults.stripTrackingParameters)),
            .init(id: "gpc", titleKey: "feedback_diag_gpc", value: flag("privacy_gpc_enabled", fallback: PrivacyFeatureDefaults.gpcEnabled)),
            .init(id: "topTabBar", titleKey: "show_top_tab_bar", value: flag("show_top_tab_bar", fallback: true)),
            .init(id: "readerTool", titleKey: "reader_mode", value: flag("builtin_reader_enabled", fallback: false)),
            .init(id: "userScripts", titleKey: "feedback_diag_scripts", value: "\(extensions.userScripts.filter(\.isEnabled).count) / \(extensions.userScripts.count)"),
            .init(id: "webExtensions", titleKey: "feedback_diag_extensions", value: "\(extensions.webExtensions.filter(\.isEnabled).count) / \(extensions.webExtensions.count)")
        ]
        return FeedbackDiagnostics(fields: fields)
    }
}

enum SouloFeedbackService {
    enum SubmissionError: LocalizedError {
        case invalidContent
        var errorDescription: String? { ToolText.text("feedback_invalid_content") }
    }
    struct Payload: Codable {
        let type: String
        let content: String
        let contact_info: String?
        let device_info: String
        let page_url: String
    }

    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Soulo"
    }
    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
    static var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    static func makeRequest(type: String, content: String, contactInfo: String?, diagnostics: FeedbackDiagnostics?) throws -> URLRequest {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2000, ["bug", "feature", "question", "other"].contains(type) else {
            throw SubmissionError.invalidContent
        }
        let contact = contactInfo?.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = try JSONEncoder().encode(diagnostics?.values ?? [:])
        let payload = Payload(type: type, content: text, contact_info: contact?.isEmpty == false ? contact : nil,
            device_info: String(decoding: json, as: UTF8.self), page_url: "\(appName) v\(appVersion) (\(buildNumber))")
        var request = URLRequest(url: URL(string: "https://api.dkluge.com/api/feedback")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 15
        return request
    }

    static func submit(type: String, content: String, contactInfo: String?, diagnostics: FeedbackDiagnostics?, session: URLSession = .shared) async throws {
        let request = try makeRequest(type: type, content: content, contactInfo: contactInfo, diagnostics: diagnostics)
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}
