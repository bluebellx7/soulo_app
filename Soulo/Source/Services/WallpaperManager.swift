import SwiftUI
import PhotosUI

@MainActor
class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()

    @Published var source: WallpaperSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: "wallpaper_source") }
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

    @Published var currentImage: UIImage?
    @Published var currentImageID: String = ""
    @Published var candidateWallpapers: [RemoteWallpaper] = []
    @Published var networkLoading: Bool = false
    @Published var customImage: UIImage?

    @Published var favorites: [RemoteWallpaper] = [] { didSet { saveFavorites() } }
    @Published var blockedIDs: Set<String> = [] { didSet { saveBlocked() } }

    private let pexelsKey = "asyKYAHBDxGhP1t9z6VnvZ8OmscCPbWtTVn5yz5SBnOuoD6xwxhTFctL"
    private let pixabayKey = "52441079-a4f901937fc9737df19dd73c6"

    private init() {
        self.source = WallpaperSource(rawValue: UserDefaults.standard.string(forKey: "wallpaper_source") ?? "pexels") ?? .pexels
        self.selectedGradientId = UserDefaults.standard.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        self.solidColor = UserDefaults.standard.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        self.searchTopic = UserDefaults.standard.string(forKey: "wallpaper_topic") ?? "Nature"
        self.vibeTags = UserDefaults.standard.stringArray(forKey: "wallpaper_vibe_tags") ?? ["Nature", "Ocean", "Forest", "Night Sky", "Mountains", "Minimal", "Cyberpunk"]
        
        loadFavorites()
        loadBlocked()
        loadCustomImage()
        Task { await initialFetch() }
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
        if !favorites.isEmpty && Double.random(in: 0...1) < 0.4 {
            if let picked = favorites.randomElement() {
                if let newSource = WallpaperSource(rawValue: picked.source) {
                    self.source = newSource
                }
                await applyWallpaper(picked)
                return
            }
        }

        // 2. Refresh based on current source
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
                return RemoteWallpaper(id: id, url: src?["original"] as? String ?? "", previewURL: src?["medium"] as? String ?? "", source: "pexels", isFavorite: favorites.contains(where: { $0.id == id }))
            }
            if let first = candidateWallpapers.first { await applyWallpaper(first) }
        } catch { print("Pexels error: \(error)") }
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
                return RemoteWallpaper(id: id, url: h["largeImageURL"] as? String ?? "", previewURL: h["previewURL"] as? String ?? "", source: "pixabay", isFavorite: favorites.contains(where: { $0.id == id }))
            }
            if let first = candidateWallpapers.first { await applyWallpaper(first) }
        } catch { print("Pixabay error: \(error)") }
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
                let wall = RemoteWallpaper(id: id, url: "https://www.bing.com" + urlBase, previewURL: "https://www.bing.com" + urlBase, source: "bing", isFavorite: favorites.contains(where: { $0.id == id }))
                self.candidateWallpapers = [wall]
                await applyWallpaper(wall)
            }
        } catch { print("Bing error: \(error)") }
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
        try? await Task.detached { guard let data = try? Data(contentsOf: url) else { return nil }; return UIImage(data: data) }.value
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
