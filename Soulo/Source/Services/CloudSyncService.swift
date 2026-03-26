import Foundation

@MainActor
class CloudSyncService {
    static let shared = CloudSyncService()

    private let kvStore = NSUbiquitousKeyValueStore.default
    private let platformKey = "icloud_platform_config"
    private let recentKeywordsKey = "icloud_recent_keywords"

    private init() {
        registerForChanges()
    }

    // MARK: - Platform Config Sync

    func syncPlatformConfig() {
        guard UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled) else { return }

        let store = PlatformDataStore.shared
        let platforms = store.allPlatforms()

        if let data = try? JSONEncoder().encode(platforms) {
            kvStore.set(data, forKey: platformKey)
            kvStore.synchronize()
        }
    }

    func fetchRemotePlatformConfig() -> [SearchPlatform]? {
        guard let data = kvStore.data(forKey: platformKey) else { return nil }
        return try? JSONDecoder().decode([SearchPlatform].self, from: data)
    }

    // MARK: - Recent Keywords Sync

    func syncRecentKeywords(_ keywords: [String]) {
        guard UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled) else { return }

        let limited = Array(keywords.prefix(50))
        kvStore.set(limited, forKey: recentKeywordsKey)
        kvStore.synchronize()
    }

    func fetchRemoteKeywords() -> [String] {
        kvStore.array(forKey: recentKeywordsKey) as? [String] ?? []
    }

    // MARK: - Change Notification

    private func registerForChanges() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoteChange),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        kvStore.synchronize()
    }

    @objc private func handleRemoteChange(_ notification: Notification) {
        guard UserDefaults.standard.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled) else { return }

        // Merge remote platform config
        if let remotePlatforms = fetchRemotePlatformConfig() {
            let store = PlatformDataStore.shared
            let localPlatforms = store.allPlatforms()

            // Simple strategy: if remote has custom platforms we don't have, add them
            var merged = localPlatforms
            for remote in remotePlatforms where remote.isCustom {
                if !merged.contains(where: { $0.id == remote.id }) {
                    merged.append(remote)
                }
            }
            store.platforms = merged
            store.savePlatforms()
        }
    }
}
