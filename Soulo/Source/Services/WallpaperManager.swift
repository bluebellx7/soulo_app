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

    @Published var currentImage: UIImage?
    @Published var currentImageID: String = ""
    @Published var candidateWallpapers: [RemoteWallpaper] = []
    @Published var networkLoading: Bool = false
    @Published var customImage: UIImage?
    @Published private(set) var lastRemoteError: String = ""
    @Published private(set) var lastRemoteErrorAt: Date?

    @Published var favorites: [RemoteWallpaper] = [] { didSet { saveFavorites() } }
    @Published var blockedIDs: Set<String> = [] { didSet { saveBlocked() } }

    private let pexelsKey = "asyKYAHBDxGhP1t9z6VnvZ8OmscCPbWtTVn5yz5SBnOuoD6xwxhTFctL"
    private let pixabayKey = "52441079-a4f901937fc9737df19dd73c6"
    private let favoritePickProbability = 0.4

    private var autoRefreshTimer: Timer?
    private var preloadTimer: Timer?
    private var preloadTask: Task<Void, Never>?
    private var preloadedWallpaper: RemoteWallpaper?
    private var preloadedImage: UIImage?

    private init() {
        self.source = WallpaperSource(rawValue: UserDefaults.standard.string(forKey: "wallpaper_source") ?? "pexels") ?? .pexels
        self.selectedGradientId = UserDefaults.standard.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        self.solidColor = UserDefaults.standard.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        self.searchTopic = UserDefaults.standard.string(forKey: "wallpaper_topic") ?? "Nature"
        self.vibeTags = UserDefaults.standard.stringArray(forKey: "wallpaper_vibe_tags") ?? ["Nature", "Ocean", "Forest", "Night Sky", "Mountains", "Minimal", "Cyberpunk"]
        let savedInterval = UserDefaults.standard.object(forKey: "wallpaper_refresh_interval") as? Int
        self.autoRefreshInterval = WallpaperRefreshInterval(rawValue: savedInterval ?? WallpaperRefreshInterval.none.rawValue) ?? .none
        self.autoRandomizeRemoteSources = UserDefaults.standard.object(forKey: "wallpaper_auto_random_sources") as? Bool ?? true
        let savedSources = UserDefaults.standard.stringArray(forKey: "wallpaper_auto_sources") ?? []
        let remoteSources = savedSources.compactMap(WallpaperSource.init(rawValue:)).filter(\.isRemote)
        self.autoRemoteSources = Set(remoteSources.isEmpty ? [.pexels, .pixabay, .bing] : remoteSources)
        self.autoRandomizeTopics = UserDefaults.standard.object(forKey: "wallpaper_auto_random_topics") as? Bool ?? true
        
        loadFavorites()
        loadBlocked()
        loadCustomImage()
        setupAutoRefreshTimer(startPreloadImmediately: false)
    }

    private func initialFetch() async {
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

        if let wall = preloadedWallpaper, let image = preloadedImage {
            if let newSource = WallpaperSource(rawValue: wall.source) {
                source = newSource
            }
            searchTopic = wall.topic
            currentImageURLString = wall.url
            currentImage = image
            currentImageID = wall.id
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
            guard let selection = autoRandomRemoteSelection() else { return }
            guard let wall = await fetchRandomRemoteWallpaper(source: selection.source, query: selection.topic) else { return }
            guard !Task.isCancelled else { return }
            let urlString = wall.url.isEmpty ? wall.previewURL : wall.url
            guard let url = URL(string: urlString), let image = await downloadImage(from: url) else { return }
            guard !Task.isCancelled else { return }
            preloadedWallpaper = wall
            preloadedImage = image
        }
    }

    private func resetPreloadedWallpaper() {
        preloadTask?.cancel()
        preloadTask = nil
        preloadedWallpaper = nil
        preloadedImage = nil
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
        if currentImageURLString == wallpaper.url { currentImage = nil; Task { await refreshRandom() } }
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
            if let first = candidateWallpapers.first { await applyWallpaper(first) }
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
            if let first = candidateWallpapers.first { await applyWallpaper(first) }
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
                await applyWallpaper(wall)
            }
        } catch {
            recordRemoteError(source: .bing, error: error)
        }
    }

    func applyWallpaper(_ wallpaper: RemoteWallpaper) async {
        guard let url = URL(string: wallpaper.url) else { return }
        currentImageURLString = wallpaper.url
        if let img = await downloadImage(from: url) {
            self.currentImage = img
            self.currentImageID = wallpaper.id
        }
    }

    private func downloadImage(from url: URL) async -> UIImage? {
        await Task.detached { guard let data = try? Data(contentsOf: url) else { return nil }; return UIImage(data: data) }.value
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
