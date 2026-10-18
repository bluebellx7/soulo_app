import Foundation
import UIKit

/// Data-only migration for the retired local model prototype; no inference dependency.
@MainActor
enum RetiredStorageCleanup {
    private static var completed = false
    private static var running = false

    static func schedule() {
        guard !completed, !running, UIApplication.shared.isProtectedDataAvailable,
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        running = true
        let defaults = UserDefaults.standard
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("soulo.localAI.") }
        let hasPreferences = !keys.isEmpty
        let sessionID = (Bundle.main.bundleIdentifier ?? "com.dkluge.Soulo") + ".local-ai.models"
        Task {
            let succeeded = await Task.detached(priority: .utility) {
                do {
                    try removeLegacyFiles(in: support, hasPreferences: hasPreferences) {
                        let configuration = URLSessionConfiguration.background(withIdentifier: sessionID)
                        let session = URLSession(configuration: configuration, delegate: RetiredSessionDelegate(), delegateQueue: nil)
                        session.invalidateAndCancel()
                    }
                    return true
                } catch { return false }
            }.value
            if succeeded {
                keys.forEach { defaults.removeObject(forKey: $0) }
                completed = true
            }
            running = false
        }
    }

    nonisolated static func removeLegacyFiles(in applicationSupport: URL, hasPreferences: Bool, cancelDownloads: () -> Void) throws {
        let directory = applicationSupport.appendingPathComponent("SouloLocalAI", isDirectory: true)
        let exists = FileManager.default.fileExists(atPath: directory.path)
        guard exists || hasPreferences else { return }
        cancelDownloads()
        if exists { try FileManager.default.removeItem(at: directory) }
    }
}

private final class RetiredSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}
