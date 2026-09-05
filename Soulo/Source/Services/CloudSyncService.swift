import Foundation

struct CloudSettingsPayload: Codable {
    let version: Int
    let modifiedAt: Date
    let propertyList: Data
    let missingKeys: [String]
}

enum CloudSettingsPayloadCodec {
    static func encode(
        defaults: UserDefaults,
        keys: [String],
        date: Date = Date()
    ) throws -> Data {
        var values: [String: Any] = [:]
        var missingKeys: [String] = []

        for key in keys {
            if let value = defaults.object(forKey: key) {
                values[key] = value
            } else {
                missingKeys.append(key)
            }
        }

        let propertyList = try PropertyListSerialization.data(
            fromPropertyList: values,
            format: .binary,
            options: 0
        )
        return try JSONEncoder().encode(
            CloudSettingsPayload(
                version: 2,
                modifiedAt: date,
                propertyList: propertyList,
                missingKeys: missingKeys
            )
        )
    }

    @discardableResult
    static func apply(
        _ data: Data,
        defaults: UserDefaults,
        allowedKeys: Set<String>
    ) throws -> CloudSettingsPayload {
        let payload = try JSONDecoder().decode(CloudSettingsPayload.self, from: data)
        guard payload.version == 2 else {
            throw CocoaError(.coderReadCorrupt)
        }

        guard let values = try PropertyListSerialization.propertyList(
            from: payload.propertyList,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }

        for (key, value) in values where allowedKeys.contains(key) {
            defaults.set(value, forKey: key)
        }
        for key in payload.missingKeys where allowedKeys.contains(key) {
            defaults.removeObject(forKey: key)
        }
        return payload
    }
}

@MainActor
final class CloudSyncService: NSObject {
    static let shared = CloudSyncService()

    private lazy var kvStore = NSUbiquitousKeyValueStore.default
    private let defaults: UserDefaults
    private let payloadKey = "soulo_settings_payload_v2"
    private var defaultsObserver: NSObjectProtocol?
    private var pendingUpload: DispatchWorkItem?
    private var isApplyingRemote = false
    private var isObservingRemote = false
    private(set) var isStarted = false

    /// Intentionally excludes history, bookmarks, cache, cookies, downloads,
    /// private-browsing state, tab state, wallpaper images, and usage statistics.
    static let syncedKeys: [String] = [
        "appearance",
        "theme_color",
        "app_language",
        "dynamic_theme",
        "home_title",
        "home_subtitle",
        "show_bookmarks_on_home",
        "show_group_picker_on_home",
        "show_recent_searches_on_home",
        "show_top_search_bar",
        "keep_fullscreen_browsing",
        "web_follows_app_color_scheme",
        "web_warm_color_shift",
        "web_force_dark_pages",
        "web_reduce_page_motion",
        "web_underline_links",
        "browser_shake_action",
        "browser_shake_intensity",
        "browser_toolbar_actions",
        "browser_toolbar_address_action",
        "ad_block_enabled",
        LiveActivityService.enabledKey,
        "privacy_https_upgrade_enabled",
        "privacy_strip_tracking_parameters",
        "privacy_gpc_enabled",
        "privacy_cookie_banner_enabled",
        "privacy_https_upgrade_excluded_hosts",
        "soulo_privacy_disabled_hosts",
        "soulo_ad_block_allowlisted_hosts",
        "soulo_ad_block_subscriptions",
        "soulo_external_navigation_blocked_hosts",
        "soulo_external_navigation_suppress_prompts",
        "wallpaper_source",
        "wallpaper_gradient_id",
        "wallpaper_solid_color",
        "wallpaper_topic",
        "wallpaper_vibe_tags",
        "wallpaper_refresh_interval",
        "wallpaper_auto_random_sources",
        "wallpaper_auto_sources",
        "wallpaper_auto_random_topics",
        "wallpaper_only_favorites",
        "last_selected_region",
        "last_selected_group_id",
        "platform_config",
        "custom_groups",
        "region_name_overrides"
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.scheduleUploadIfNeeded()
            }
        }

        // Do not start synchronously from the singleton initializer. Applying a
        // remote appearance can touch ThemeManager, which writes UserDefaults
        // and may re-enter CloudSyncService.shared before dispatch_once finishes.
    }

    func startIfEnabled() {
        guard isEnabled else { return }
        startSyncIfNeeded()
    }

    func setEnabled(_ enabled: Bool) {
        pendingUpload?.cancel()
        pendingUpload = nil
        guard enabled else {
            isStarted = false
            stopObservingRemoteChanges()
            return
        }
        startSyncIfNeeded()
    }

    private var isEnabled: Bool {
        defaults.bool(forKey: AppConstants.StorageKeys.iCloudSyncEnabled)
    }

    private func startSyncIfNeeded() {
        guard isEnabled, !isStarted else { return }
        isStarted = true
        startObservingRemoteChanges()
        kvStore.synchronize()

        if let remoteData = kvStore.data(forKey: payloadKey) {
            applyRemote(remoteData)
        } else {
            uploadLocalSettings()
        }
    }

    private func startObservingRemoteChanges() {
        guard !isObservingRemote else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoteChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        isObservingRemote = true
    }

    private func stopObservingRemoteChanges() {
        guard isObservingRemote else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore
        )
        isObservingRemote = false
    }

    private func scheduleUploadIfNeeded() {
        guard isEnabled, isStarted, !isApplyingRemote else { return }
        pendingUpload?.cancel()

        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.uploadLocalSettings()
            }
        }
        pendingUpload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    private func uploadLocalSettings() {
        guard isEnabled, isStarted, !isApplyingRemote else { return }
        guard let data = try? CloudSettingsPayloadCodec.encode(
            defaults: defaults,
            keys: Self.syncedKeys
        ) else { return }

        kvStore.set(data, forKey: payloadKey)
        kvStore.synchronize()
    }

    @objc private func handleRemoteChange(_ notification: Notification) {
        guard isEnabled else { return }
        if let changedKeys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
           !changedKeys.contains(payloadKey) {
            return
        }
        guard let data = kvStore.data(forKey: payloadKey) else { return }
        applyRemote(data)
    }

    private func applyRemote(_ data: Data) {
        pendingUpload?.cancel()
        pendingUpload = nil
        isApplyingRemote = true
        defer { isApplyingRemote = false }

        guard (try? CloudSettingsPayloadCodec.apply(
            data,
            defaults: defaults,
            allowedKeys: Set(Self.syncedKeys)
        )) != nil else { return }

        reloadRuntimeSettings()
    }

    private func reloadRuntimeSettings() {
        let appearance = defaults.string(forKey: AppConstants.StorageKeys.appearance) ?? "system"
        ThemeManager.shared.setAppearance(appearance)

        if let language = defaults.string(forKey: AppConstants.StorageKeys.selectedLanguage) {
            let canonicalLanguage = AppConstants.canonicalLanguageCode(language)
            if canonicalLanguage != language {
                defaults.set(canonicalLanguage, forKey: AppConstants.StorageKeys.selectedLanguage)
            }
            LanguageManager.shared.setLanguage(canonicalLanguage)
        }

        PlatformDataStore.shared.reloadFromDefaults()
        WallpaperManager.shared.reloadPreferencesFromDefaults()
        AdBlockSettingsService.shared.reloadFromDefaults()
        PrivacyProtectionService.shared.reloadFromDefaults()
        ExternalNavigationService.shared.reloadFromDefaults()
        AdBlockSubscriptionService.shared.reloadFromDefaults()
        BrowserToolbarConfigurationService.shared.reloadFromDefaults()

        let liveActivityEnabled = defaults.object(forKey: LiveActivityService.enabledKey) as? Bool ?? true
        LiveActivityService.shared.setEnabled(liveActivityEnabled)
    }
}
