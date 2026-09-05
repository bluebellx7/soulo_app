import SwiftUI
import PhotosUI
import os

@MainActor
class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    private static let logger = Logger(subsystem: "com.dkluge.Soulo", category: "Wallpaper")

    @Published var source: WallpaperSource {
        didSet {
            UserDefaults.standard.set(source.rawValue, forKey: "wallpaper_source")
            resetPreloadedWallpaper()
        }
    }
    @Published var selectedGradientId: String {
        didSet { UserDefaults.standard.set(selectedGradientId, forKey: "wallpaper_gradient_id") }
    }
    @Published var solidColor: String {
        didSet { UserDefaults.standard.set(solidColor, forKey: "wallpaper_solid_color") }
    }
    @Published var searchTopic: String {
        didSet { UserDefaults.standard.set(searchTopic, forKey: "wallpaper_topic") }
    }
    @Published var vibeTags: [String] = [] {
        didSet { UserDefaults.standard.set(vibeTags, forKey: "wallpaper_vibe_tags") }
    }
    @Published var autoRefreshInterval: WallpaperRefreshInterval {
        didSet {
            UserDefaults.standard.set(autoRefreshInterval.rawValue, forKey: "wallpaper_refresh_interval")
            setupAutoRefreshTimer()
        }
    }
    @Published var autoRandomizeRemoteSources: Bool {
        didSet {
            UserDefaults.standard.set(autoRandomizeRemoteSources, forKey: "wallpaper_auto_random_sources")
            resetPreloadedWallpaper()
        }
    }
    @Published var autoRemoteSources: Set<WallpaperSource> {
        didSet {
            UserDefaults.standard.set(autoRemoteSources.map(\.rawValue), forKey: "wallpaper_auto_sources")
            resetPreloadedWallpaper()
        }
    }
    @Published var autoRandomizeTopics: Bool {
        didSet {
            UserDefaults.standard.set(autoRandomizeTopics, forKey: "wallpaper_auto_random_topics")
            resetPreloadedWallpaper()
        }
    }
    @Published var onlyUseFavoriteWallpapers: Bool {
        didSet {
            UserDefaults.standard.set(onlyUseFavoriteWallpapers, forKey: "wallpaper_only_favorites")
            resetPreloadedWallpaper()
        }
    }

    @Published var currentImage: UIImage?
    @Published var currentImageID: String = ""
    @Published var candidateWallpapers: [RemoteWallpaper] = []
    @Published var networkLoading: Bool = false
    @Published var customImage: UIImage?
    @Published private(set) var lastRemoteError: String = ""
    @Published private(set) var lastRemoteErrorAt: Date?

    @Published var favorites: [RemoteWallpaper] = [] {
        didSet {
            saveFavorites()
            if onlyUseFavoriteWallpapers {
                resetPreloadedWallpaper()
            }
        }
    }
    @Published var blockedIDs: Set<String> = [] { didSet { saveBlocked() } }

    private let pexelsKey = "asyKYAHBDxGhP1t9z6VnvZ8OmscCPbWtTVn5yz5SBnOuoD6xwxhTFctL"
    private let pixabayKey = "52441079-a4f901937fc9737df19dd73c6"
    private let favoritePickProbability = 0.4

    private var autoRefreshTimer: Timer?
    private var preloadTimer: Timer?
    private var preloadTask: Task<Void, Never>?
    private var preloadedWallpaper: RemoteWallpaper?
    private var preloadedImage: UIImage?
    private var preloadedImageData: Data?

    private init() {
        self.source = BrowserInitialPreferences.wallpaperSource(in: .standard)
        self.selectedGradientId = UserDefaults.standard.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        self.solidColor = UserDefaults.standard.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        self.searchTopic = BrowserInitialPreferences.wallpaperTopic(in: .standard)
        self.vibeTags = UserDefaults.standard.stringArray(forKey: "wallpaper_vibe_tags") ?? ["Nature", "Ocean", "Forest", "Night Sky", "Mountains", "Minimal", "Cyberpunk"]
        let savedInterval = UserDefaults.standard.object(forKey: "wallpaper_refresh_interval") as? Int
        self.autoRefreshInterval = WallpaperRefreshInterval(rawValue: savedInterval ?? WallpaperRefreshInterval.none.rawValue) ?? .none
        self.autoRandomizeRemoteSources = UserDefaults.standard.object(forKey: "wallpaper_auto_random_sources") as? Bool ?? true
        let savedSources = UserDefaults.standard.stringArray(forKey: "wallpaper_auto_sources") ?? []
        let remoteSources = savedSources.compactMap(WallpaperSource.init(rawValue:)).filter(\.isRemote)
        self.autoRemoteSources = Set(remoteSources.isEmpty ? [.pexels, .pixabay, .bing] : remoteSources)
        self.autoRandomizeTopics = UserDefaults.standard.object(forKey: "wallpaper_auto_random_topics") as? Bool ?? true
        self.onlyUseFavoriteWallpapers = UserDefaults.standard.object(forKey: "wallpaper_only_favorites") as? Bool ?? false
        
        loadFavorites()
        loadBlocked()
        loadCustomImage()
        loadPersistedRemoteWallpaper()
        setupAutoRefreshTimer(startPreloadImmediately: false)
    }

    func reloadPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        let nextSource = BrowserInitialPreferences.wallpaperSource(in: defaults)
        let nextGradientID = defaults.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        let nextSolidColor = defaults.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        let nextTopic = BrowserInitialPreferences.wallpaperTopic(in: defaults)
        let nextVibeTags = defaults.stringArray(forKey: "wallpaper_vibe_tags") ?? ["Nature", "Ocean", "Forest", "Night Sky", "Mountains", "Minimal", "Cyberpunk"]
        let savedInterval = defaults.object(forKey: "wallpaper_refresh_interval") as? Int
        let nextInterval = WallpaperRefreshInterval(rawValue: savedInterval ?? WallpaperRefreshInterval.none.rawValue) ?? .none
        let nextRandomSources = defaults.object(forKey: "wallpaper_auto_random_sources") as? Bool ?? true
        let savedSources = defaults.stringArray(forKey: "wallpaper_auto_sources") ?? []
        let remoteSources = savedSources.compactMap(WallpaperSource.init(rawValue:)).filter(\.isRemote)
        let nextSources = Set(remoteSources.isEmpty ? [.pexels, .pixabay, .bing] : remoteSources)
        let nextRandomTopics = defaults.object(forKey: "wallpaper_auto_random_topics") as? Bool ?? true
        let nextOnlyFavorites = defaults.object(forKey: "wallpaper_only_favorites") as? Bool ?? false

        if source != nextSource { source = nextSource }
        if selectedGradientId != nextGradientID { selectedGradientId = nextGradientID }
        if solidColor != nextSolidColor { solidColor = nextSolidColor }
        if searchTopic != nextTopic { searchTopic = nextTopic }
        if vibeTags != nextVibeTags { vibeTags = nextVibeTags }
        if autoRefreshInterval != nextInterval { autoRefreshInterval = nextInterval }
        if autoRandomizeRemoteSources != nextRandomSources { autoRandomizeRemoteSources = nextRandomSources }
        if autoRemoteSources != nextSources { autoRemoteSources = nextSources }
        if autoRandomizeTopics != nextRandomTopics { autoRandomizeTopics = nextRandomTopics }
        if onlyUseFavoriteWallpapers != nextOnlyFavorites { onlyUseFavoriteWallpapers = nextOnlyFavorites }
    }

    private func initialFetch() async {
        if onlyUseFavoriteWallpapers {
            await refreshRandom()
            return
        }
        switch source {
        case .bing:    await fetchBingWallpaper()
        case .pexels:  await searchPexels(query: searchTopic)
        case .pixabay: await searchPixabay(query: searchTopic)
        default: break
        }
    }

    /// Call from onAppear to ensure wallpapers are loaded (handles init Task race)
    func ensureLoaded() {
        guard !networkLoading else { return }
        let src = source
        guard src == .pexels || src == .pixabay || src == .bing else { return }
        guard candidateWallpapers.isEmpty || currentImage == nil else { return }
        Task { await initialFetch() }
    }

    func refreshRandom() async {
        guard !networkLoading else { return }

        // Manual and automatic refreshes stay entirely within favorites when
        // requested. An empty list intentionally leaves the current image in place.
        if onlyUseFavoriteWallpapers {
            guard let picked = favoriteWallpaperForRefresh() else { return }
            if let newSource = WallpaperSource(rawValue: picked.source) {
                source = newSource
            }
            await applyWallpaper(picked)
            return
        }

        // 1. 40% chance to pick from favorites (any source)
        if !favorites.isEmpty && Double.random(in: 0...1) < favoritePickProbability {
            if let picked = favorites.randomElement() {
                if let newSource = WallpaperSource(rawValue: picked.source) {
                    self.source = newSource
                }
                await applyWallpaper(picked)
                return
            }
        }

        // 2. Refresh based on current or randomized remote source/topic.
        if let randomRemote = autoRandomRemoteSelection() {
            source = randomRemote.source
            switch randomRemote.source {
            case .pexels:
                await searchPexels(query: randomRemote.topic)
            case .pixabay:
                await searchPixabay(query: randomRemote.topic)
            case .bing:
                await fetchBingWallpaper(random: true)
            default:
                break
            }
            return
        }

        // 3. Fast switch among already loaded remote candidates.
        if source.isRemote && candidateWallpapers.count > 1 {
            let nextOptions = candidateWallpapers.filter { $0.id != currentImageID }
            if let picked = nextOptions.randomElement() {
                await applyWallpaper(picked)
                if nextOptions.count < 5 {
                    Task { await fetchNewCandidatesInBackground() }
                }
                return
            }
        }

        switch source {
        case .pexels:
            await searchPexels(query: searchTopic)
        case .pixabay:
            await searchPixabay(query: searchTopic)
        case .bing:
            await fetchBingWallpaper(random: true)
        case .gradient:
            let presets = GradientPreset.presets
            if let current = presets.firstIndex(where: { $0.id == selectedGradientId }) {
                let next = (current + 1) % presets.count
                selectedGradientId = presets[next].id
            } else {
                selectedGradientId = presets.randomElement()?.id ?? selectedGradientId
            }
        case .solid:
            let r = Int.random(in: 0...255), g = Int.random(in: 0...255), b = Int.random(in: 0...255)
            solidColor = String(format: "%02X%02X%02X", r, g, b)
        case .photo:
            break
        }
    }

    func setupAutoRefreshTimer(startPreloadImmediately: Bool = true) {
        autoRefreshTimer?.invalidate()
        preloadTimer?.invalidate()
        autoRefreshTimer = nil
        preloadTimer = nil
        preloadTask?.cancel()
        preloadTask = nil

        guard autoRefreshInterval != .none else { return }

        let interval = TimeInterval(autoRefreshInterval.rawValue)
        let preloadDelay = max(5, interval - 30)

        preloadTimer = Timer.scheduledTimer(withTimeInterval: preloadDelay, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.preloadNextAutoWallpaper() }
        }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.applyAutoRefresh() }
        }

        if startPreloadImmediately {
            preloadNextAutoWallpaper()
        }
    }

    func refreshIfNeededAfterForeground() {
        guard autoRefreshInterval != .none else { return }
        let lastRefresh = UserDefaults.standard.double(forKey: "wallpaper_last_auto_refresh_at")
        guard lastRefresh == 0 || Date().timeIntervalSince1970 - lastRefresh >= TimeInterval(autoRefreshInterval.rawValue) else { return }
        Task { await applyAutoRefresh() }
    }

    private func applyAutoRefresh() async {
        guard !networkLoading else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaper_last_auto_refresh_at")

        if let wall = preloadedWallpaper,
           let image = preloadedImage,
           let imageData = preloadedImageData {
            if let newSource = WallpaperSource(rawValue: wall.source) {
                source = newSource
            }
            searchTopic = wall.topic
            currentImageURLString = wall.url
            withAnimation(.easeInOut(duration: 0.45)) {
                currentImage = image
                currentImageID = wall.id
            }
            await persistRemoteWallpaper(imageData, wallpaper: wall)
            resetPreloadedWallpaper()
            preloadNextAutoWallpaper()
            return
        }

        resetPreloadedWallpaper()
        await refreshRandom()
        preloadNextAutoWallpaper()
    }

    private func preloadNextAutoWallpaper() {
        guard autoRefreshInterval != .none, preloadedWallpaper == nil, preloadTask == nil else { return }
        preloadTask = Task { @MainActor in
            defer { preloadTask = nil }
            let wall: RemoteWallpaper
            if onlyUseFavoriteWallpapers {
                guard let favorite = favoriteWallpaperForRefresh() else { return }
                wall = favorite
            } else {
                guard let selection = autoRandomRemoteSelection(),
                      let remote = await fetchRandomRemoteWallpaper(
                        source: selection.source,
                        query: selection.topic
                      ) else { return }
                wall = remote
            }
            guard !Task.isCancelled else { return }
            guard let imageData = await imageData(for: wall),
                  let image = UIImage(data: imageData) else { return }
            guard !Task.isCancelled else { return }
            preloadedWallpaper = wall
            preloadedImage = image
            preloadedImageData = imageData
        }
    }

    private func resetPreloadedWallpaper() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedWallpaper = nil
        preloadedImage = nil
        preloadedImageData = nil
    }

    private func favoriteWallpaperForRefresh() -> RemoteWallpaper? {
        Self.favoriteWallpaperForRefresh(in: favorites, currentImageID: currentImageID)
    }

    static func favoriteWallpaperForRefresh(
        in favorites: [RemoteWallpaper],
        currentImageID: String
    ) -> RemoteWallpaper? {
        let alternatives = favorites.filter { $0.id != currentImageID }
        return alternatives.randomElement() ?? favorites.first
    }

    private func autoRandomRemoteSelection() -> (source: WallpaperSource, topic: String)? {
        guard source.isRemote || autoRandomizeRemoteSources else { return nil }
        let sources = autoRandomizeRemoteSources ? Array(autoRemoteSources.filter(\.isRemote)) : [source].filter(\.isRemote)
        guard let pickedSource = sources.randomElement() else { return nil }
        let topics = vibeTags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let pickedTopic = autoRandomizeTopics ? (topics.randomElement() ?? searchTopic) : searchTopic
        return (pickedSource, pickedTopic)
    }

    private func fetchRandomRemoteWallpaper(source: WallpaperSource, query: String) async -> RemoteWallpaper? {
        switch source {
        case .pexels:
            return await fetchPexelsCandidates(query: query, page: Int.random(in: 1...10)).randomElement()
        case .pixabay:
            return await fetchPixabayCandidates(query: query, page: Int.random(in: 1...5)).randomElement()
        case .bing:
            return await fetchBingCandidate(random: true)
        default:
            return nil
        }
    }

    private func fetchNewCandidatesInBackground() async {
        let query = searchTopic
        let newCandidates: [RemoteWallpaper]
        if source == .pexels {
            newCandidates = await fetchPexelsCandidates(query: query, page: Int.random(in: 1...10))
        } else if source == .pixabay {
            newCandidates = await fetchPixabayCandidates(query: query, page: Int.random(in: 1...5))
        } else {
            newCandidates = []
        }
        if !newCandidates.isEmpty {
            candidateWallpapers = newCandidates
        }
    }

    private func fetchPexelsCandidates(query: String, page: Int) async -> [RemoteWallpaper] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nature"
        guard let url = URL(string: "https://api.pexels.com/v1/search?query=\(encoded)&page=\(page)&per_page=15&orientation=portrait") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(pexelsKey, forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let res = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let photos = res["photos"] as? [[String: Any]] else { return [] }

        return photos.compactMap { p in
            let id = "\(p["id"] ?? UUID().uuidString)"
            if blockedIDs.contains(id) { return nil }
            let src = p["src"] as? [String: Any]
            return RemoteWallpaper(id: id, url: src?["original"] as? String ?? "", previewURL: src?["medium"] as? String ?? "", source: "pexels", topic: query, isFavorite: favorites.contains(where: { $0.id == id }))
        }
    }

    private func fetchPixabayCandidates(query: String, page: Int) async -> [RemoteWallpaper] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nature"
        guard let url = URL(string: "https://pixabay.com/api/?key=\(pixabayKey)&q=\(encoded)&page=\(page)&per_page=15&safesearch=true&image_type=photo&orientation=vertical") else { return [] }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = res["hits"] as? [[String: Any]] else { return [] }

        return hits.compactMap { h in
            let id = "\(h["id"] ?? UUID().uuidString)"
            if blockedIDs.contains(id) { return nil }
            return RemoteWallpaper(id: id, url: h["largeImageURL"] as? String ?? "", previewURL: h["previewURL"] as? String ?? "", source: "pixabay", topic: query, isFavorite: favorites.contains(where: { $0.id == id }))
        }
    }

    private func fetchBingCandidate(random: Bool) async -> RemoteWallpaper? {
        let idx = random ? Int.random(in: 0...7) : 0
        guard let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=1&mkt=en-US") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let res = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = res["images"] as? [[String: Any]],
              let first = images.first,
              let urlBase = first["url"] as? String else { return nil }

        let id = first["startdate"] as? String ?? UUID().uuidString
        if blockedIDs.contains(id) { return nil }
        return RemoteWallpaper(id: id, url: "https://www.bing.com" + urlBase, previewURL: "https://www.bing.com" + urlBase, source: "bing", topic: "Bing Daily", isFavorite: favorites.contains(where: { $0.id == id }))
    }

    func setAutoRemoteSource(_ source: WallpaperSource, enabled: Bool) {
        guard source.isRemote else { return }
        if enabled {
            autoRemoteSources.insert(source)
        } else if autoRemoteSources.count > 1 {
            autoRemoteSources.remove(source)
        }
    }

    // MARK: - API Actions
    func toggleFavorite(_ wallpaper: RemoteWallpaper) {
        if let index = favorites.firstIndex(where: { $0.id == wallpaper.id }) {
            favorites.remove(at: index)
            removeHDCache(for: wallpaper.id)
            HapticsManager.medium()
        } else {
            var newFav = wallpaper; newFav.isFavorite = true; favorites.append(newFav)
            // Cache HD image in background
            Task { await cacheHDImage(for: newFav) }
            HapticsManager.success()
        }
    }

    func blockWallpaper(_ wallpaper: RemoteWallpaper) {
        blockedIDs.insert(wallpaper.id)
        withAnimation(.easeOut(duration: 0.25)) {
            candidateWallpapers.removeAll { $0.id == wallpaper.id }
        }
        if currentImageURLString == wallpaper.url {
            removePersistedRemoteWallpaper()
            currentImage = nil
            Task { await refreshRandom() }
        }
        HapticsManager.medium()
    }

    func addVibeTag(_ tag: String) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !vibeTags.contains(where: { $0.lowercased() == trimmed.lowercased() }) {
            vibeTags.insert(trimmed, at: 0)
            if vibeTags.count > 15 { vibeTags.removeLast() }
        }
        searchTopic = trimmed
    }

    func removeVibeTag(_ tag: String) { vibeTags.removeAll { $0 == tag } }

    // MARK: - Search Logic
    func searchPexels(query: String) async {
        addVibeTag(query)
        networkLoading = true
        defer { networkLoading = false }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nature"
        guard let url = URL(string: "https://api.pexels.com/v1/search?query=\(encoded)&page=\(Int.random(in: 1...10))&per_page=15&orientation=portrait") else { return }
        var request = URLRequest(url: url); request.setValue(pexelsKey, forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let res = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let photos = res?["photos"] as? [[String: Any]] ?? []
            self.candidateWallpapers = photos.compactMap { p in
                let id = "\(p["id"] ?? UUID().uuidString)"
                if blockedIDs.contains(id) { return nil }
                let src = p["src"] as? [String: Any]
                return RemoteWallpaper(id: id, url: src?["original"] as? String ?? "", previewURL: src?["medium"] as? String ?? "", source: "pexels", topic: query, isFavorite: favorites.contains(where: { $0.id == id }))
            }
            clearRemoteErrorIfNeeded()
            if !onlyUseFavoriteWallpapers,
               let first = candidateWallpapers.first {
                await applyWallpaper(first)
            }
        } catch {
            recordRemoteError(source: .pexels, error: error)
        }
    }

    func searchPixabay(query: String) async {
        addVibeTag(query)
        networkLoading = true
        defer { networkLoading = false }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nature"
        guard let url = URL(string: "https://pixabay.com/api/?key=\(pixabayKey)&q=\(encoded)&page=\(Int.random(in: 1...5))&per_page=15&safesearch=true&image_type=photo&orientation=vertical") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let res = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let hits = res?["hits"] as? [[String: Any]] ?? []
            self.candidateWallpapers = hits.compactMap { h in
                let id = "\(h["id"] ?? UUID().uuidString)"
                if blockedIDs.contains(id) { return nil }
                return RemoteWallpaper(id: id, url: h["largeImageURL"] as? String ?? "", previewURL: h["previewURL"] as? String ?? "", source: "pixabay", topic: query, isFavorite: favorites.contains(where: { $0.id == id }))
            }
            clearRemoteErrorIfNeeded()
            if !onlyUseFavoriteWallpapers,
               let first = candidateWallpapers.first {
                await applyWallpaper(first)
            }
        } catch {
            recordRemoteError(source: .pixabay, error: error)
        }
    }

    func fetchBingWallpaper(random: Bool = false) async {
        searchTopic = "Bing Daily"
        networkLoading = true
        defer { networkLoading = false }
        let idx = random ? Int.random(in: 0...7) : 0
        guard let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=1&mkt=en-US") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let res = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let images = res?["images"] as? [[String: Any]] ?? []
            if let first = images.first, let urlBase = first["url"] as? String {
                let id = first["startdate"] as? String ?? UUID().uuidString
                if blockedIDs.contains(id) { return }
                let wall = RemoteWallpaper(id: id, url: "https://www.bing.com" + urlBase, previewURL: "https://www.bing.com" + urlBase, source: "bing", topic: "Bing Daily", isFavorite: favorites.contains(where: { $0.id == id }))
                self.candidateWallpapers = [wall]
                clearRemoteErrorIfNeeded()
                if !onlyUseFavoriteWallpapers {
                    await applyWallpaper(wall)
                }
            }
        } catch {
            recordRemoteError(source: .bing, error: error)
        }
    }

    func applyWallpaper(_ wallpaper: RemoteWallpaper) async {
        guard let imageData = await imageData(for: wallpaper),
              let image = UIImage(data: imageData) else { return }

        currentImageURLString = wallpaper.url
        withAnimation(.easeInOut(duration: 0.45)) {
            currentImage = image
            currentImageID = wallpaper.id
        }
        await persistRemoteWallpaper(imageData, wallpaper: wallpaper)
    }

    private func imageData(for wallpaper: RemoteWallpaper) async -> Data? {
        let cacheURL = hdCacheURL(for: wallpaper.id)
        if favorites.contains(where: { $0.id == wallpaper.id }),
           let cached = await Task.detached(priority: .utility, operation: {
               try? Data(contentsOf: cacheURL)
           }).value {
            return cached
        }

        let urlString = wallpaper.url.isEmpty ? wallpaper.previewURL : wallpaper.url
        guard let url = URL(string: urlString) else { return nil }
        return await downloadImageData(from: url)
    }

    private func downloadImageData(from url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    private func recordRemoteError(source: WallpaperSource, error: Error) {
        Self.logger.error("Wallpaper source \(source.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        lastRemoteError = LanguageManager.shared.localizedString("wallpaper_remote_error")
        lastRemoteErrorAt = Date()
    }

    private func clearRemoteErrorIfNeeded() {
        if !lastRemoteError.isEmpty {
            lastRemoteError = ""
            lastRemoteErrorAt = nil
        }
    }

    var isCurrentWallpaperLight: Bool {
        switch source {
        case .solid:
            return isHexColorLight(solidColor)
        case .gradient:
            return currentGradient.isLight
        default:
            return false
        }
    }

    private func isHexColorLight(_ hex: String) -> Bool {
        var cleanHex = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleanHex.hasPrefix("#") {
            cleanHex.remove(at: cleanHex.startIndex)
        }
        guard cleanHex.count == 6 else { return false }
        var rgbValue: UInt64 = 0
        Scanner(string: cleanHex).scanHexInt64(&rgbValue)
        let r = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = Double(rgbValue & 0x0000FF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luminance > 0.6
    }

    var currentGradient: GradientPreset { GradientPreset.presets.first { $0.id == selectedGradientId } ?? GradientPreset.presets[0] }
    private func saveFavorites() { UserDefaults.standard.setCodable(favorites, forKey: "wallpaper_favorites") }
    private func loadFavorites() { favorites = UserDefaults.standard.codable([RemoteWallpaper].self, forKey: "wallpaper_favorites") ?? [] }
    private func saveBlocked() { UserDefaults.standard.set(Array(blockedIDs), forKey: "wallpaper_blocked") }
    private func loadBlocked() { let arr = UserDefaults.standard.stringArray(forKey: "wallpaper_blocked") ?? []; blockedIDs = Set(arr) }
    func saveCustomImage(_ image: UIImage) {
        customImage = image
        currentImage = image
        currentImageID = "custom_\(Date().timeIntervalSince1970)"
        if let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: Self.customImageURL)
        }
    }
    private func loadCustomImage() {
        if let data = try? Data(contentsOf: Self.customImageURL), let image = UIImage(data: data) {
            customImage = image
            if source == .photo {
                currentImage = image
                currentImageID = "custom_local"
            }
        }
    }
    private static var customImageURL: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("custom_wallpaper.jpg") }
    func saveToAlbum(image: UIImage) { UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil) }
    private var currentImageURLString: String? = nil

    // MARK: - Current Wallpaper Cache

    private static let currentWallpaperFileKey = "wallpaper_current_cache_file"
    private static let currentWallpaperIDKey = "wallpaper_current_cache_id"
    private static let currentWallpaperURLKey = "wallpaper_current_cache_url"

    private static var currentWallpaperCacheDirectory: URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CurrentWallpaper", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    /// Loads the last successfully displayed remote wallpaper synchronously so
    /// the first rendered frame never has to wait for the network.
    private func loadPersistedRemoteWallpaper() {
        guard source.isRemote else { return }

        let defaults = UserDefaults.standard
        guard let fileName = defaults.string(forKey: Self.currentWallpaperFileKey),
              let imageID = defaults.string(forKey: Self.currentWallpaperIDKey) else {
            return
        }

        let fileURL = Self.currentWallpaperCacheDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            removePersistedRemoteWallpaper()
            return
        }

        currentImage = image.preparingForDisplay() ?? image
        currentImageID = imageID
        currentImageURLString = defaults.string(forKey: Self.currentWallpaperURLKey)
    }

    /// Uses a unique file for each write so overlapping downloads cannot
    /// replace the cache for a newer wallpaper that has already won the race.
    private func persistRemoteWallpaper(
        _ imageData: Data,
        wallpaper: RemoteWallpaper
    ) async {
        let fileName = "\(UUID().uuidString).image"
        let fileURL = Self.currentWallpaperCacheDirectory.appendingPathComponent(fileName)
        let saved = await Task.detached(priority: .utility) {
            do {
                try imageData.write(to: fileURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value

        guard saved else { return }
        guard currentImageID == wallpaper.id else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let defaults = UserDefaults.standard
        let previousFileName = defaults.string(forKey: Self.currentWallpaperFileKey)
        defaults.set(fileName, forKey: Self.currentWallpaperFileKey)
        defaults.set(wallpaper.id, forKey: Self.currentWallpaperIDKey)
        defaults.set(wallpaper.url, forKey: Self.currentWallpaperURLKey)

        if let previousFileName, previousFileName != fileName {
            let previousURL = Self.currentWallpaperCacheDirectory
                .appendingPathComponent(previousFileName)
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    private func removePersistedRemoteWallpaper() {
        let defaults = UserDefaults.standard
        if let fileName = defaults.string(forKey: Self.currentWallpaperFileKey) {
            let fileURL = Self.currentWallpaperCacheDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
        }
        defaults.removeObject(forKey: Self.currentWallpaperFileKey)
        defaults.removeObject(forKey: Self.currentWallpaperIDKey)
        defaults.removeObject(forKey: Self.currentWallpaperURLKey)
    }

    // MARK: - HD Image Cache

    private static var hdCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wallpaper_hd", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func hdCacheURL(for id: String) -> URL {
        Self.hdCacheDir.appendingPathComponent("\(id).jpg")
    }

    /// Cache HD image to disk when user favorites a wallpaper.
    func cacheHDImage(for wallpaper: RemoteWallpaper) async {
        let cacheURL = hdCacheURL(for: wallpaper.id)
        guard !FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        // Try original URL first, fallback to preview
        let urlString = wallpaper.url.isEmpty ? wallpaper.previewURL : wallpaper.url
        guard let url = URL(string: urlString) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            try data.write(to: cacheURL)
        } catch {
            // Fallback: cache preview if HD fails
            if let previewURL = URL(string: wallpaper.previewURL) {
                if let (data, _) = try? await URLSession.shared.data(from: previewURL) {
                    try? data.write(to: cacheURL)
                }
            }
        }
    }

    /// Remove cached HD image when user removes from favorites.
    func removeHDCache(for id: String) {
        let url = hdCacheURL(for: id)
        try? FileManager.default.removeItem(at: url)
    }

    /// Get cached HD image for a wallpaper (if available).
    func cachedHDImage(for id: String) -> UIImage? {
        let url = hdCacheURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }
}
