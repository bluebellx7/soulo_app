import Foundation
import Combine
import Network

@MainActor final class LocalAINetworkMonitor: ObservableObject {
    static let shared = LocalAINetworkMonitor()
    @Published private(set) var requiresDataConfirmation = true
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.usesInterfaceType(.cellular) || path.isExpensive
            Task { @MainActor in self?.requiresDataConfirmation = expensive }
        }
        monitor.start(queue: DispatchQueue(label: "soulo.localAI.network"))
    }
}

/// A download cannot start on a metered path until the user chooses its policy.
/// Consent belongs to this model transfer, rather than an app-wide preference.
@MainActor final class LocalAIDownloadPrompt: ObservableObject {
    struct Pending {
        let id = UUID()
        let asset: LocalAIModelAsset
        var profile: LocalAIModelProfile? = nil
        let source: LocalAIModelSource
        let onStart: () -> Void
    }
    @Published private(set) var pending: Pending?
    let store: LocalAIModelStore
    private let needsConfirmation: () -> Bool
    init(store: LocalAIModelStore? = nil, needsConfirmation: (() -> Bool)? = nil) {
        self.store = store ?? .shared
        self.needsConfirmation = needsConfirmation ?? {
            #if DEBUG
            if ProcessInfo.processInfo.environment["SOULO_LOCAL_AI_QA_METERED"] == "1" { return true }
            #endif
            return LocalAINetworkMonitor.shared.requiresDataConfirmation
        }
        if needsConfirmation == nil { _ = LocalAINetworkMonitor.shared }
    }
    func request(_ asset: LocalAIModelAsset, source: LocalAIModelSource, onStart: @escaping () -> Void = {}) {
        guard store.statuses[asset.id]?.isWorking != true, store.statuses[asset.id] != .installed else { return }
        let choice = Pending(asset: asset, source: source, onStart: onStart)
        if needsConfirmation() { pending = choice }
        else { start(choice, allowsCellular: store.resumeAllowsCellular(for: asset)) }
    }
    func request(_ profile: LocalAIModelProfile, source: LocalAIModelSource, onStart: @escaping () -> Void = {}) {
        guard profile.isSupportedDevice, store.modelURL(for: profile) == nil, let asset = profile.mainAsset else { return }
        let choice = Pending(asset: asset, profile: profile, source: source, onStart: onStart)
        if needsConfirmation() { pending = choice }
        else { start(choice, allowsCellular: false) }
    }
    func confirm(_ presented: Pending? = nil, allowsCellular: Bool) {
        guard let choice = pending, presented == nil || presented?.id == choice.id else { return }
        pending = nil
        start(choice, allowsCellular: allowsCellular)
    }
    func cancel() { pending = nil }
    func dismiss() {
        let id = pending?.id
        // SwiftUI can dismiss the alert before invoking the selected action.
        // Keep this choice alive for that run-loop turn, then discard it.
        DispatchQueue.main.async { [weak self] in if self?.pending?.id == id { self?.cancel() } }
    }
    private func start(_ choice: Pending, allowsCellular: Bool) {
        choice.onStart()
        if let profile = choice.profile { store.download(profile, source: choice.source, allowsCellular: allowsCellular) }
        else { store.download(choice.asset, source: choice.source, allowsCellular: allowsCellular) }
    }
}

#if canImport(UIKit)
import SwiftUI

private struct LocalAIDownloadPromptModifier: ViewModifier {
    @ObservedObject var prompt: LocalAIDownloadPrompt
    func body(content: Content) -> some View {
        content.alert(AIL10n.text("cellular_title"), isPresented: Binding(get: { prompt.pending != nil }, set: { if !$0 { prompt.dismiss() } }), presenting: prompt.pending) { pending in
            Button(AIL10n.text("wifi_only")) { prompt.confirm(pending, allowsCellular: false) }.keyboardShortcut(.defaultAction)
            Button(AIL10n.text("use_cellular")) { prompt.confirm(pending, allowsCellular: true) }
            Button(AIL10n.text("cancel"), role: .cancel) { prompt.cancel() }
        } message: { pending in
            let size = ByteCountFormatter.string(fromByteCount: pending.profile?.downloadBytes ?? pending.asset.bytes, countStyle: .file)
            Text(String(format: AIL10n.text("cellular_message"), size) +
                 ((pending.profile?.languageAssets ?? [pending.asset]).contains(where: { prompt.store.hasResumeData(for: $0) }) ? "\n\n" + AIL10n.text("network_change_restart") : ""))
        }
    }
}
extension View {
    func localAIDownloadPrompt(_ prompt: LocalAIDownloadPrompt) -> some View { modifier(LocalAIDownloadPromptModifier(prompt: prompt)) }
}
#endif
