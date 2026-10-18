import Foundation

/// A model profile describes files and engine capabilities, never user phrases.
public enum LocalAIModelProfile: String, CaseIterable, Identifiable, Sendable {
    case light, enhanced
    public var id: String { rawValue }
    public var title: String { self == .light ? "MiniCPM-V 4.7 · 1B" : "MiniCPM-V 4.7 · 35B-A3B" }
    public var languageAssets: [LocalAIModelAsset] {
        self == .light ? [.language] : LocalAIModelAsset.enhancedAssets.filter { !$0.filename.hasSuffix("mmproj-model-f16.gguf") }
    }
    public var visionAsset: LocalAIModelAsset? {
        self == .light ? .vision : LocalAIModelAsset.enhancedAssets.first { $0.filename.hasSuffix("mmproj-model-f16.gguf") }
    }
    public var mainAsset: LocalAIModelAsset? { languageAssets.first { $0.kind == .gguf } }
    public var downloadBytes: Int64 { languageAssets.reduce(0) { $0 + $1.bytes } }
    public var minimumDeviceMemory: UInt64 { self == .light ? 4_000_000_000 : 8_000_000_000 }
    public var isSupportedDevice: Bool { self == .light || ProcessInfo.processInfo.physicalMemory >= minimumDeviceMemory }
    public var isMultiStepAgent: Bool { self == .enhanced }
}

@MainActor extension LocalAIModelStore {
    public var selectedModelURL: URL? { modelURL(for: selectedProfile) }
    public var selectedVisionURL: URL? { selectedProfile.visionAsset.flatMap { installedURL(for: $0) } }
    public func modelURL(for profile: LocalAIModelProfile) -> URL? {
        guard let main = profile.mainAsset, !profile.languageAssets.isEmpty,
              profile.languageAssets.allSatisfy({ installedURL(for: $0) != nil }) else { return nil }
        return installedURL(for: main)
    }
    public func select(_ profile: LocalAIModelProfile) {
        guard selectedProfile != profile else { return }
        LocalAIRuntime.shared.release()
        selectedProfile = profile
        UserDefaults.standard.set(profile.rawValue, forKey: "soulo.localAI.model")
    }
    public func status(for profile: LocalAIModelProfile) -> LocalAIAssetStatus {
        let required = profile.languageAssets
        guard !required.isEmpty else { return .failed(LocalAIError.modelInvalid.localizedDescription) }
        if modelURL(for: profile) != nil { return .installed }
        if required.contains(where: { if case .downloading = statuses[$0.id] { return true }; return false }) {
            let bytes: Int64 = required.reduce(0) { result, asset in
                if statuses[asset.id] == .installed { return result + asset.bytes }
                if case let .downloading(received, _) = statuses[asset.id] { return result + received }
                return result
            }
            return .downloading(received: bytes, total: profile.downloadBytes)
        }
        if required.contains(where: { statuses[$0.id] == .verifying }) { return .verifying }
        if let failure = required.compactMap({ asset -> String? in if case let .failed(message) = statuses[asset.id] { return message }; return nil }).first { return .failed(failure) }
        if required.contains(where: { statuses[$0.id] == .paused || hasLocalData(for: $0) }) { return .paused }
        return .missing
    }
    public func download(_ profile: LocalAIModelProfile, source: LocalAIModelSource, allowsCellular: Bool = false) {
        guard profile.isSupportedDevice, !profile.languageAssets.isEmpty else {
            error = LocalAIError.insufficientMemory.localizedDescription; return
        }
        let missing = profile.languageAssets.filter { statuses[$0.id] != .installed }
        do {
            let free = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
            let needed = missing.reduce(Int64(150_000_000)) { $0 + $1.bytes }
            if let free, free < needed { throw CocoaError(.fileWriteOutOfSpace) }
            for asset in missing { download(asset, source: source, allowsCellular: allowsCellular) }
        } catch { self.error = error.localizedDescription }
    }
    public func pause(_ profile: LocalAIModelProfile) { for asset in profile.languageAssets { pause(asset) } }
    public func delete(_ profile: LocalAIModelProfile) async {
        for asset in profile.languageAssets { await delete(asset) }
    }
}
