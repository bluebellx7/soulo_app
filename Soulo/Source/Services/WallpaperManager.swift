import SwiftUI
import PhotosUI
import Combine
import os

@MainActor
class WallpaperManager: ObservableObject {
    static let shared = WallpaperManager()
    private static let logger = Logger(subsystem: "com.dkluge.Soulo", category: "Wallpaper")

    @Published var source: WallpaperSource {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: "wallpaper_source")
            remoteRequestID = UUID()
            networkLoading = false
            candidateWallpapers = []
            clearRemoteErrorIfNeeded()
            resetPreloadedWallpaper()
            cachedImageLoadTask?.cancel()
            imageLoadRevision = UUID()
            if source == .photo {
                if customImage == nil { loadCustomImage() }
            } else { customImage = nil }
            if source == .gradient || source == .solid {
                currentImage = nil
                currentImageID = ""
                currentImageURLString = nil
            }
            if source.isRemote && currentImage == nil { loadPersistedRemoteWallpaper() }
            if source.isRemote != oldValue.isRemote {
                setupAutoRefreshTimer(startPreloadImmediately: false)
            }
        }
    }
    @Published var selectedGradientId: String {
        didSet { UserDefaults.standard.set(selectedGradientId, forKey: "wallpaper_gradient_id") }
    }
    @Published var solidColor: String {
        didSet { UserDefaults.standard.set(solidColor, forKey: "wallpaper_solid_color") }
    }
    @Published var imageOverlayEnabled: Bool {
        didSet { UserDefaults.standard.set(imageOverlayEnabled, forKey: "wallpaper_image_overlay") }
    }
    @Published var imageOverlayAmount: Double {
        didSet {
            let bounded = Self.boundedOverlayAmount(imageOverlayAmount)
            if bounded != imageOverlayAmount { imageOverlayAmount = bounded }
            UserDefaults.standard.set(bounded, forKey: "wallpaper_image_overlay_amount")
            updateImageContrast()
        }
    }
    var imageOverlayOpacity: Double {
        guard imageOverlayEnabled, source.isRemote || source == .photo else { return 0 }
        return Self.boundedOverlayAmount(imageOverlayAmount)
    }
    private static func boundedOverlayAmount(_ amount: Double) -> Double {
        amount.isFinite ? min(1, max(0, amount)) : WallpaperContrast.defaultImageOverlayAmount
    }
    @Published var imageBlurEnabled: Bool {
        didSet { UserDefaults.standard.set(imageBlurEnabled, forKey: "wallpaper_image_blur") }
    }
    @Published var imageBlurAmount: Double {
        didSet {
            let bounded = Self.boundedBlurAmount(imageBlurAmount)
            if bounded != imageBlurAmount { imageBlurAmount = bounded }
            UserDefaults.standard.set(bounded, forKey: "wallpaper_image_blur_amount")
        }
    }
    var imageBlurRadius: CGFloat {
        guard imageBlurEnabled, source.isRemote || source == .photo else { return 0 }
        return CGFloat(Self.boundedBlurAmount(imageBlurAmount) * 30)
    }
    private static func boundedBlurAmount(_ amount: Double) -> Double {
        amount.isFinite ? min(1, max(0, amount)) : 0.35
    }
    var showsWallpaperOverlay: Bool {
        source == .gradient || imageOverlayOpacity > 0
    }
    @Published private(set) var displayAppearance: WallpaperAppearance = .dark
    @Published private(set) var appearancePresets: [WallpaperAppearance: WallpaperAppearancePreset] = [:]
    @Published private(set) var customPhotoRevision = 0
    private var photoWrites: [WallpaperAppearance: UUID] = [:]

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
            if onlyUseFavoriteWallpapers && favorites.isEmpty { onlyUseFavoriteWallpapers = false }
            UserDefaults.standard.set(onlyUseFavoriteWallpapers, forKey: "wallpaper_only_favorites")
            resetPreloadedWallpaper()
        }
    }

    @Published var currentImage: UIImage? {
        didSet { updateImageContrast() }
    }
    @Published private(set) var unmaskedImagePrefersDarkText = false
    @Published private(set) var imagePrefersDarkText: [WallpaperAppearance: Bool] = [:]
    private var contrastTask: Task<Void, Never>?
    private var contrastRevision = UUID()
    @Published var currentImageID: String = ""
    @Published var candidateWallpapers: [RemoteWallpaper] = []
    @Published var networkLoading: Bool = false
    @Published var customImage: UIImage?
    @Published private(set) var lastRemoteError: String = ""
    @Published private(set) var lastRemoteErrorAt: Date?
    @Published private(set) var sourcePreviewImages: [WallpaperSource: UIImage] = [:]
    private struct SourcePreviewRecord: Codable, Sendable {
        let id: String
        let date: Date
        let data: Data
    }
    private var sourcePreviewRecords: [WallpaperSource: SourcePreviewRecord] = [:]
    private var sourcePreviewLoads: [WallpaperSource: Task<Void, Never>] = [:]
    private var sourcePreviewVersions: [WallpaperSource: UUID] = [:]
    private let sourcePreviewIO = DispatchQueue(label: "com.dkluge.Soulo.wallpaper-source-previews", qos: .utility)
    private let sourcePreviewDirectory: URL

    @Published var favorites: [RemoteWallpaper] = [] {
        didSet {
            saveFavorites()
            favoriteStorageRevision += 1
            let ids = Set(favorites.map(\.id))
            let removed = Set(oldValue.map(\.id)).subtracting(ids)
            let revision = favoriteStorageRevision
            Task { await favoriteImageStorage.reconcile(favoriteIDs: ids, removingIDs: removed, revision: revision) }
            if favorites.isEmpty && onlyUseFavoriteWallpapers { onlyUseFavoriteWallpapers = false }
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
    private var preloadRevision = UUID()
    private var autoRefreshTask: Task<Void, Never>?
    private var autoRefreshRevision = UUID()
    private var preloadedWallpaper: RemoteWallpaper?
    private var preloadedImage: UIImage?
    private var preloadedImageData: Data?
    private var imageLoadRevision = UUID()
    private var cachedImageLoadTask: Task<Void, Never>?
    private var cachedImageLoadID = UUID()
    private var automaticRefreshActive = true
    private var remoteRequestID = UUID()
    private let session: URLSession
    private let photoDirectory: URL
    private let favoriteImageStorage: FavoriteWallpaperImageStore
    private var favoriteStorageRevision: UInt64 = 0
    private let resources: BrowserResourcePolicy
    private var resourceObservers = Set<AnyCancellable>()

    var hasAutomaticRefreshWork: Bool { autoRefreshTimer != nil || preloadTimer != nil || preloadTask != nil || autoRefreshTask != nil }

    init(resources: BrowserResourcePolicy? = nil, session: URLSession = .shared,
         favoriteImageStorage: FavoriteWallpaperImageStore? = nil, photoDirectory: URL? = nil) {
        self.session = session
        self.photoDirectory = photoDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.sourcePreviewDirectory = (photoDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0])
            .appendingPathComponent("WallpaperSourcePreviews", isDirectory: true)
        self.favoriteImageStorage = favoriteImageStorage ?? FavoriteWallpaperImageStore()
        let resources = resources ?? .shared
        self.resources = resources
        self.source = BrowserInitialPreferences.wallpaperSource(in: .standard)
        self.selectedGradientId = UserDefaults.standard.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        self.solidColor = UserDefaults.standard.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        let appearance = UserDefaults.standard.string(forKey: "appearance")
        self.displayAppearance = .appPreference(appearance, systemIsDark: UIScreen.main.traitCollection.userInterfaceStyle == .dark)
        self.appearancePresets = Self.readAppearancePresets()
        let defaults = UserDefaults.standard
        self.imageOverlayEnabled = defaults.object(forKey: "wallpaper_image_overlay") == nil || defaults.bool(forKey: "wallpaper_image_overlay")
        self.imageOverlayAmount = Self.boundedOverlayAmount(defaults.object(forKey: "wallpaper_image_overlay_amount") == nil
            ? WallpaperContrast.defaultImageOverlayAmount : defaults.double(forKey: "wallpaper_image_overlay_amount"))
        self.imageBlurEnabled = defaults.bool(forKey: "wallpaper_image_blur")
        self.imageBlurAmount = Self.boundedBlurAmount(defaults.object(forKey: "wallpaper_image_blur_amount") == nil ? 0.35 : defaults.double(forKey: "wallpaper_image_blur_amount"))
        self.searchTopic = BrowserInitialPreferences.wallpaperTopic(in: .standard)
        self.vibeTags = BrowserInitialPreferences.wallpaperVibeTags(in: .standard)
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
        automaticRefreshActive = UIApplication.shared.applicationState != .background
        setupAutoRefreshTimer(startPreloadImmediately: false)
        resources.$allowsSpeculation.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.setupAutoRefreshTimer(startPreloadImmediately: false)
        }.store(in: &resourceObservers)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.suspendAutomaticRefresh() }.store(in: &resourceObservers)
    }

    func reloadPreferencesFromDefaults() {
        let defaults = UserDefaults.standard
        let nextSource = BrowserInitialPreferences.wallpaperSource(in: defaults)
        let nextGradientID = defaults.string(forKey: "wallpaper_gradient_id") ?? "aurora"
        let nextSolidColor = defaults.string(forKey: "wallpaper_solid_color") ?? "#FFFFFF"
        let nextTopic = BrowserInitialPreferences.wallpaperTopic(in: defaults)
        let nextVibeTags = BrowserInitialPreferences.wallpaperVibeTags(in: defaults)
        let savedInterval = defaults.object(forKey: "wallpaper_refresh_interval") as? Int
        let nextInterval = WallpaperRefreshInterval(rawValue: savedInterval ?? WallpaperRefreshInterval.none.rawValue) ?? .none
        let nextRandomSources = defaults.object(forKey: "wallpaper_auto_random_sources") as? Bool ?? true
        let savedSources = defaults.stringArray(forKey: "wallpaper_auto_sources") ?? []
        let remoteSources = savedSources.compactMap(WallpaperSource.init(rawValue:)).filter(\.isRemote)
        let nextSources = Set(remoteSources.isEmpty ? [.pexels, .pixabay, .bing] : remoteSources)
        let nextRandomTopics = defaults.object(forKey: "wallpaper_auto_random_topics") as? Bool ?? true
        let requestedOnlyFavorites = defaults.object(forKey: "wallpaper_only_favorites") as? Bool ?? false
        let nextOnlyFavorites = requestedOnlyFavorites && !favorites.isEmpty
        if requestedOnlyFavorites && !nextOnlyFavorites { defaults.set(false, forKey: "wallpaper_only_favorites") }

        if source != nextSource { source = nextSource }
        if selectedGradientId != nextGradientID { selectedGradientId = nextGradientID }
        if solidColor != nextSolidColor { solidColor = nextSolidColor }
        let nextOverlay = defaults.object(forKey: "wallpaper_image_overlay") == nil || defaults.bool(forKey: "wallpaper_image_overlay")
        if imageOverlayEnabled != nextOverlay { imageOverlayEnabled = nextOverlay }
        let nextOverlayAmount = Self.boundedOverlayAmount(defaults.object(forKey: "wallpaper_image_overlay_amount") == nil
            ? WallpaperContrast.defaultImageOverlayAmount : defaults.double(forKey: "wallpaper_image_overlay_amount"))
        if imageOverlayAmount != nextOverlayAmount { imageOverlayAmount = nextOverlayAmount }
        let nextBlur = defaults.bool(forKey: "wallpaper_image_blur")
        let nextBlurAmount = Self.boundedBlurAmount(defaults.object(forKey: "wallpaper_image_blur_amount") == nil ? 0.35 : defaults.double(forKey: "wallpaper_image_blur_amount"))
        if imageBlurEnabled != nextBlur { imageBlurEnabled = nextBlur }
        if imageBlurAmount != nextBlurAmount { imageBlurAmount = nextBlurAmount }
        let nextPresets = Self.readAppearancePresets()
        if appearancePresets != nextPresets { appearancePresets = nextPresets }
        if searchTopic != nextTopic { searchTopic = nextTopic }
        if vibeTags != nextVibeTags { vibeTags = nextVibeTags }
        if autoRefreshInterval != nextInterval { autoRefreshInterval = nextInterval }
        if autoRandomizeRemoteSources != nextRandomSources { autoRandomizeRemoteSources = nextRandomSources }
        if autoRemoteSources != nextSources { autoRemoteSources = nextSources }
        if autoRandomizeTopics != nextRandomTopics { autoRandomizeTopics = nextRandomTopics }
        if onlyUseFavoriteWallpapers != nextOnlyFavorites { onlyUseFavoriteWallpapers = nextOnlyFavorites }
    }

    func selectSource(_ selected: WallpaperSource) async {
        let changed = source != selected
        source = selected
        if selected != .bing, searchTopic == "Bing Daily" {
            searchTopic = BrowserInitialPreferences.defaultWallpaperTopic
        }
        guard selected.isRemote, changed || currentImage == nil || candidateWallpapers.isEmpty else { return }
        // Selecting a source browses its gallery. A favorites-only refresh can
        // choose another source and immediately undo the user's selection.
        if onlyUseFavoriteWallpapers {
            await ensureCandidatesLoaded()
        } else {
            await initialFetch()
        }
    }

    func sourcePreviewImage(for selected: WallpaperSource) -> UIImage? {
        if selected == source, candidateWallpapers.contains(where: { $0.id == currentImageID && $0.source == selected.rawValue }),
           let currentImage { return currentImage }
        return sourcePreviewImages[selected]
    }

    /// Preview loading never changes the active source, Home image, gallery,
    /// search topic or remote error. Reuse small on-disk thumbnails for a day.
    func loadSourcePreview(for selected: WallpaperSource) async {
        guard selected.isRemote else { return }
        if let loading = sourcePreviewLoads[selected] { await loading.value; return }
        let loading = Task { @MainActor [weak self] in
            guard let self else { return }
            let version = self.sourcePreviewVersions[selected] ?? UUID()
            self.sourcePreviewVersions[selected] = version
            if self.sourcePreviewImages[selected] == nil {
                let file = self.sourcePreviewDirectory.appendingPathComponent(selected.rawValue + ".json")
                let cached: (SourcePreviewRecord, UIImage)? = await withCheckedContinuation { continuation in
                    self.sourcePreviewIO.async {
                        guard let data = try? Data(contentsOf: file),
                              let record = try? JSONDecoder().decode(SourcePreviewRecord.self, from: data),
                              let cg = WallpaperImageDecoder.decode(record.data, targetPixels: CGSize(width: 240, height: 180)) else {
                            continuation.resume(returning: nil); return
                        }
                        continuation.resume(returning: (record, UIImage(cgImage: cg)))
                    }
                }
                guard self.sourcePreviewVersions[selected] == version else { return }
                if let (record, image) = cached, !self.blockedIDs.contains(record.id) {
                    self.sourcePreviewImages[selected] = image
                    self.sourcePreviewRecords[selected] = record
                }
            }
            if let record = self.sourcePreviewRecords[selected], Date().timeIntervalSince(record.date) < 86_400 { return }
            let query = self.searchTopic == "Bing Daily" ? BrowserInitialPreferences.defaultWallpaperTopic : self.searchTopic
            let candidate: RemoteWallpaper?
            switch selected {
            case .pexels: candidate = await self.fetchPexelsCandidates(query: query, page: 1).first
            case .pixabay: candidate = await self.fetchPixabayCandidates(query: query, page: 1).first
            case .bing: candidate = await self.fetchBingCandidate(random: false)
            default: candidate = nil
            }
            guard !Task.isCancelled, self.sourcePreviewVersions[selected] == version, let candidate,
                  let url = URL(string: candidate.previewURL.isEmpty ? candidate.url : candidate.previewURL) else { return }
            var request = URLRequest(url: url); request.timeoutInterval = 10
            guard let (data, response) = try? await self.session.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) != false else { return }
            await self.rememberSourcePreview(data, wallpaper: candidate, expectedVersion: version)
        }
        sourcePreviewLoads[selected] = loading
        await loading.value
        sourcePreviewLoads[selected] = nil
    }

    private func rememberSourcePreview(_ data: Data, wallpaper: RemoteWallpaper, expectedVersion: UUID? = nil) async {
        guard let selected = WallpaperSource(rawValue: wallpaper.source), selected.isRemote,
              !blockedIDs.contains(wallpaper.id) else { return }
        if let expectedVersion, sourcePreviewVersions[selected] != expectedVersion { return }
        let version = UUID(); sourcePreviewVersions[selected] = version
        let decoded: (UIImage, Data)? = await Task.detached(priority: .utility) {
            guard let cg = WallpaperImageDecoder.decode(data, targetPixels: CGSize(width: 240, height: 180)) else { return nil }
            let image = UIImage(cgImage: cg)
            guard let encoded = image.jpegData(compressionQuality: 0.85) else { return nil }
            return (image, encoded)
        }.value
        guard sourcePreviewVersions[selected] == version, !blockedIDs.contains(wallpaper.id), let (image, encoded) = decoded else { return }
        let record = SourcePreviewRecord(id: wallpaper.id, date: Date(), data: encoded)
        sourcePreviewImages[selected] = image; sourcePreviewRecords[selected] = record
        let directory = sourcePreviewDirectory, file = directory.appendingPathComponent(selected.rawValue + ".json")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sourcePreviewIO.async {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if let saved = try? JSONEncoder().encode(record) { try? saved.write(to: file, options: .atomic) }
                continuation.resume()
            }
        }
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
        guard currentImage == nil else { return }
        Task {
            await cachedImageLoadTask?.value
            guard source == src, !networkLoading, currentImage == nil else { return }
            await initialFetch()
        }
    }

    /// The settings gallery needs candidates even when Home uses only favorites.
    /// Wait for an in-flight wallpaper operation instead of dropping page entry.
    func ensureCandidatesLoaded() async {
        let expectedSource = source
        guard expectedSource.isRemote else { return }
        await cachedImageLoadTask?.value
        while networkLoading {
            guard !Task.isCancelled, source == expectedSource else { return }
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
        }
        guard !Task.isCancelled, source == expectedSource, candidateWallpapers.isEmpty else { return }
        switch expectedSource {
        case .pexels: await searchPexels(query: searchTopic)
        case .pixabay: await searchPixabay(query: searchTopic)
        case .bing: await fetchBingWallpaper()
        default: break
        }
    }

    func refreshRandom() async {
        guard source.isRemote else {
            switch source {
            case .gradient:
                let presets = GradientPreset.presets
                let index = presets.firstIndex { $0.id == gradientID(for: displayAppearance) } ?? 0
                setGradient(presets[(index + 1) % presets.count].id, for: displayAppearance)
            case .solid:
                setSolidColor(String(format: "#%02X%02X%02X", Int.random(in: 0...255), Int.random(in: 0...255), Int.random(in: 0...255)), for: displayAppearance)
            default: break
            }
            return
        }

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
        autoRefreshTask?.cancel(); autoRefreshTask = nil
        autoRefreshRevision = UUID()
        resetPreloadedWallpaper()

        guard source.isRemote, automaticRefreshActive, resources.allowsSpeculation, autoRefreshInterval != .none else { return }

        let interval = TimeInterval(autoRefreshInterval.rawValue)
        let preloadDelay = max(5, interval - 30)

        preloadTimer = Timer.scheduledTimer(withTimeInterval: preloadDelay, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.preloadNextAutoWallpaper() }
        }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.startAutomaticRefresh() }
        }
        preloadTimer?.tolerance = min(30, preloadDelay * 0.1)
        autoRefreshTimer?.tolerance = min(30, interval * 0.1)

        if startPreloadImmediately {
            preloadNextAutoWallpaper()
        }
    }

    func refreshIfNeededAfterForeground() {
        if !automaticRefreshActive {
            automaticRefreshActive = true
            setupAutoRefreshTimer(startPreloadImmediately: false)
        }
        guard resources.allowsSpeculation else { return }
        guard autoRefreshInterval != .none else { return }
        let lastRefresh = UserDefaults.standard.double(forKey: "wallpaper_last_auto_refresh_at")
        guard lastRefresh == 0 || Date().timeIntervalSince1970 - lastRefresh >= TimeInterval(autoRefreshInterval.rawValue) else { return }
        startAutomaticRefresh()
    }

    private func startAutomaticRefresh() {
        guard source.isRemote, automaticRefreshActive, resources.allowsSpeculation, autoRefreshTask == nil else { return }
        let revision = UUID(); autoRefreshRevision = revision
        autoRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.autoRefreshRevision == revision { self.autoRefreshTask = nil } }
            await self.applyAutoRefresh()
        }
    }

    func suspendAutomaticRefresh() {
        automaticRefreshActive = false
        autoRefreshTimer?.invalidate(); autoRefreshTimer = nil
        preloadTimer?.invalidate(); preloadTimer = nil
        autoRefreshTask?.cancel(); autoRefreshTask = nil
        autoRefreshRevision = UUID()
        resetPreloadedWallpaper()
    }

    private func applyAutoRefresh() async {
        guard source.isRemote, automaticRefreshActive, resources.allowsSpeculation, !networkLoading else { return }
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
        guard source.isRemote, automaticRefreshActive, resources.allowsSpeculation, autoRefreshInterval != .none, preloadedWallpaper == nil, preloadTask == nil else { return }
        let revision = UUID(); preloadRevision = revision
        preloadTask = Task { @MainActor in
            defer { if preloadRevision == revision { preloadTask = nil } }
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
                  let image = await decodedBackground(imageData) else { return }
            guard !Task.isCancelled else { return }
            preloadedWallpaper = wall
            preloadedImage = image
            preloadedImageData = imageData
        }
    }

    private func resetPreloadedWallpaper() {
        preloadRevision = UUID()
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
        let expectedSource = source
        let query = searchTopic
        let newCandidates: [RemoteWallpaper]
        if source == .pexels {
            newCandidates = await fetchPexelsCandidates(query: query, page: Int.random(in: 1...10))
        } else if source == .pixabay {
            newCandidates = await fetchPixabayCandidates(query: query, page: Int.random(in: 1...5))
        } else {
            newCandidates = []
        }
        if !Task.isCancelled, source == expectedSource, searchTopic == query, !newCandidates.isEmpty {
            candidateWallpapers = newCandidates
        }
    }

    private func fetchPexelsCandidates(query: String, page: Int) async -> [RemoteWallpaper] {
        let encoded = SearchQueryEncoding.encode(query) ?? "nature"
        guard let url = URL(string: "https://api.pexels.com/v1/search?query=\(encoded)&page=\(page)&per_page=15&orientation=portrait") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(pexelsKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: request),
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
        let encoded = SearchQueryEncoding.encode(query) ?? "nature"
        guard let url = URL(string: "https://pixabay.com/api/?key=\(pixabayKey)&q=\(encoded)&page=\(page)&per_page=15&safesearch=true&image_type=photo&orientation=vertical") else { return [] }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: request),
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
        var request = URLRequest(url: url); request.timeoutInterval = 15
        guard let (data, _) = try? await session.data(for: request),
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
        if let selected = WallpaperSource(rawValue: wallpaper.source), sourcePreviewRecords[selected]?.id == wallpaper.id {
            sourcePreviewVersions[selected] = UUID()
            sourcePreviewImages[selected] = nil; sourcePreviewRecords[selected] = nil
            let file = sourcePreviewDirectory.appendingPathComponent(selected.rawValue + ".json")
            sourcePreviewIO.async { try? FileManager.default.removeItem(at: file) }
        }
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
        guard source == .pexels else { return }
        addVibeTag(query)
        let requestID = beginRemoteRequest()
        defer { finishRemoteRequest(requestID) }
        let encoded = SearchQueryEncoding.encode(query) ?? "nature"
        guard let url = URL(string: "https://api.pexels.com/v1/search?query=\(encoded)&page=\(Int.random(in: 1...10))&per_page=15&orientation=portrait") else { return }
        var request = URLRequest(url: url); request.setValue(pexelsKey, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await session.data(for: request)
            guard isCurrentRemoteRequest(requestID, source: .pexels) else { return }
            try validateRemoteResponse(response)
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
            guard isCurrentRemoteRequest(requestID, source: .pexels) else { return }
            recordRemoteError(source: .pexels, error: error)
        }
    }

    func searchPixabay(query: String) async {
        guard source == .pixabay else { return }
        addVibeTag(query)
        let requestID = beginRemoteRequest()
        defer { finishRemoteRequest(requestID) }
        let encoded = SearchQueryEncoding.encode(query) ?? "nature"
        guard let url = URL(string: "https://pixabay.com/api/?key=\(pixabayKey)&q=\(encoded)&page=\(Int.random(in: 1...5))&per_page=15&safesearch=true&image_type=photo&orientation=vertical") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard isCurrentRemoteRequest(requestID, source: .pixabay) else { return }
            try validateRemoteResponse(response)
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
            guard isCurrentRemoteRequest(requestID, source: .pixabay) else { return }
            recordRemoteError(source: .pixabay, error: error)
        }
    }

    func fetchBingWallpaper(random: Bool = false) async {
        guard source == .bing else { return }
        searchTopic = "Bing Daily"
        let requestID = beginRemoteRequest()
        defer { finishRemoteRequest(requestID) }
        let idx = random ? Int.random(in: 0...7) : 0
        guard let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=\(idx)&n=1&mkt=en-US") else { return }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            let (data, response) = try await session.data(for: request)
            guard isCurrentRemoteRequest(requestID, source: .bing) else { return }
            try validateRemoteResponse(response)
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
            guard isCurrentRemoteRequest(requestID, source: .bing) else { return }
            recordRemoteError(source: .bing, error: error)
        }
    }

    func applyWallpaper(_ wallpaper: RemoteWallpaper) async {
        let revision = UUID(); imageLoadRevision = revision
        let expectedSource = source
        guard let imageData = await imageData(for: wallpaper),
              let image = await decodedBackground(imageData),
              imageLoadRevision == revision, source == expectedSource else { return }

        currentImageURLString = wallpaper.url
        withAnimation(.easeInOut(duration: 0.45)) {
            currentImage = image
            currentImageID = wallpaper.id
        }
        await rememberSourcePreview(imageData, wallpaper: wallpaper)
        await persistRemoteWallpaper(imageData, wallpaper: wallpaper)
    }

    private func beginRemoteRequest() -> UUID {
        let id = UUID()
        remoteRequestID = id
        imageLoadRevision = UUID()
        cachedImageLoadTask?.cancel()
        networkLoading = true
        return id
    }

    private func isCurrentRemoteRequest(_ id: UUID, source expected: WallpaperSource) -> Bool {
        !Task.isCancelled && remoteRequestID == id && source == expected
    }

    private func finishRemoteRequest(_ id: UUID) {
        if remoteRequestID == id { networkLoading = false }
    }

    private func validateRemoteResponse(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }

    private static var backgroundPixels: CGSize { UIScreen.main.nativeBounds.size }

    private func decodedBackground(_ data: Data) async -> UIImage? {
        let pixels = Self.backgroundPixels
        return await Task.detached(priority: .utility) {
            WallpaperImageDecoder.decode(data, targetPixels: pixels).map { UIImage(cgImage: $0) }
        }.value
    }

    private func imageData(for wallpaper: RemoteWallpaper) async -> Data? {
        if favorites.contains(where: { $0.id == wallpaper.id }),
           let cached = await favoriteImageStorage.cachedData(for: wallpaper.id) {
            return cached
        }

        let urlString = wallpaper.url.isEmpty ? wallpaper.previewURL : wallpaper.url
        guard let url = URL(string: urlString) else { return nil }
        return await downloadImageData(from: url)
    }

    private func downloadImageData(from url: URL) async -> Data? {
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else { return nil }
            return data
        } catch { return nil }
    }

    private func recordRemoteError(source: WallpaperSource, error: Error) {
        guard !Task.isCancelled else { return }
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

    var isCurrentWallpaperLight: Bool { prefersDarkForeground(for: displayAppearance) }

    func prefersDarkForeground(for appearance: WallpaperAppearance) -> Bool {
        switch source {
        case .solid: return WallpaperContrast.prefersDarkText(hex: solidColor(for: appearance))
        case .gradient: return gradient(for: appearance).isLight
        default: return imageOverlayOpacity > 0 ? (imagePrefersDarkText[appearance] ?? false) : unmaskedImagePrefersDarkText
        }
    }

    private func updateImageContrast() {
        contrastTask?.cancel()
        let revision = UUID(); contrastRevision = revision
        guard let cgImage = currentImage?.cgImage else { imagePrefersDarkText = [:]; unmaskedImagePrefersDarkText = false; return }
        let overlayAmount = Self.boundedOverlayAmount(imageOverlayAmount)
        contrastTask = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) { () -> (overlays: [WallpaperAppearance: Bool], original: Bool) in
                let lightness = WallpaperContrast.imageLightness(cgImage, overlayAmount: overlayAmount)
                return ([.light: lightness.masked, .dark: lightness.masked], lightness.original)
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.contrastRevision == revision else { return }
            self.unmaskedImagePrefersDarkText = result.original
            self.imagePrefersDarkText = result.overlays
        }
    }

    var currentGradient: GradientPreset { gradient(for: displayAppearance) }

    private static func readAppearancePresets() -> [WallpaperAppearance: WallpaperAppearancePreset] {
        Dictionary(uniqueKeysWithValues: WallpaperAppearance.allCases.map { appearance in
            func saved(_ key: String) -> String? {
                UserDefaults.standard.string(forKey: appearance.key(key)).flatMap { $0.isEmpty ? nil : $0 }
            }
            return (appearance, WallpaperAppearancePreset(gradientID: saved("wallpaper_gradient_id"), solidColor: saved("wallpaper_solid_color")))
        })
    }
    func gradientID(for appearance: WallpaperAppearance) -> String {
        appearancePresets[appearance]?.gradientID ?? selectedGradientId
    }
    func gradient(for appearance: WallpaperAppearance) -> GradientPreset {
        GradientPreset.presets.first { $0.id == gradientID(for: appearance) } ?? GradientPreset.presets[0]
    }
    func solidColor(for appearance: WallpaperAppearance) -> String {
        if let selected = appearancePresets[appearance]?.solidColor { return selected }
        // Preserve a legacy custom color, while splitting the old white default
        // into the new light-white / dark-black defaults.
        let legacy = solidColor.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        if legacy == "FFFFFF" { return appearance == .light ? "#FFFFFF" : "#000000" }
        return solidColor
    }
    func setGradient(_ id: String, for appearance: WallpaperAppearance) {
        guard GradientPreset.presets.contains(where: { $0.id == id }) else { return }
        var preset = appearancePresets[appearance] ?? WallpaperAppearancePreset()
        preset.gradientID = id; appearancePresets[appearance] = preset
        UserDefaults.standard.set(id, forKey: appearance.key("wallpaper_gradient_id"))
    }
    func setSolidColor(_ value: String, for appearance: WallpaperAppearance) {
        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return }
        var preset = appearancePresets[appearance] ?? WallpaperAppearancePreset()
        preset.solidColor = "#" + hex; appearancePresets[appearance] = preset
        UserDefaults.standard.set(preset.solidColor, forKey: appearance.key("wallpaper_solid_color"))
    }
    func setDisplayAppearance(_ appearance: WallpaperAppearance) {
        guard displayAppearance != appearance else { return }
        let oldFile = customPhotoFile(for: displayAppearance)
        displayAppearance = appearance
        guard source == .photo, oldFile != customPhotoFile(for: appearance) else { return }
        imageLoadRevision = UUID(); cachedImageLoadTask?.cancel()
        customImage = nil; currentImage = nil
        loadCustomImage()
    }

    private func customPhotoDestination(for appearance: WallpaperAppearance) -> URL {
        customImageURL.deletingLastPathComponent().appendingPathComponent("custom_wallpaper_" + appearance.rawValue + ".image")
    }
    func customPhotoFile(for appearance: WallpaperAppearance) -> URL {
        let specific = customPhotoDestination(for: appearance)
        return FileManager.default.fileExists(atPath: specific.path) ? specific : customImageURL
    }
    func customPhotoPreview(for appearance: WallpaperAppearance, targetPixels: CGSize = CGSize(width: 900, height: 1200)) async -> UIImage? {
        let file = customPhotoFile(for: appearance)
        let work = Task.detached(priority: .userInitiated) {
            WallpaperImageDecoder.decode(file: file, targetPixels: targetPixels).map { UIImage(cgImage: $0) }
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
    func saveCustomPhoto(_ data: Data, for appearance: WallpaperAppearance) async throws {
        let revision = UUID(); photoWrites[appearance] = revision
        let target = customPhotoDestination(for: appearance)
        let staging = target.deletingLastPathComponent().appendingPathComponent(".wallpaper-" + revision.uuidString)
        let pixels = Self.backgroundPixels
        try FileManager.default.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: WallpaperImageDecoder.previewURL(for: staging))
        }
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let cg = WallpaperImageDecoder.decode(data, targetPixels: pixels) else { throw WebResourceDownloadError.invalidImage }
            try data.write(to: staging, options: .atomic)
            WallpaperImageDecoder.writePreview(for: staging)
            try Task.checkCancellation()
            return UIImage(cgImage: cg)
        }
        let image = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard photoWrites[appearance] == revision else { throw CancellationError() }
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else { try FileManager.default.moveItem(at: staging, to: target) }
        let preview = WallpaperImageDecoder.previewURL(for: target)
        try? FileManager.default.removeItem(at: preview)
        try? FileManager.default.moveItem(at: WallpaperImageDecoder.previewURL(for: staging), to: preview)
        customPhotoRevision &+= 1
        if source == .photo, appearance == displayAppearance {
            imageLoadRevision = UUID(); cachedImageLoadTask?.cancel()
            customImage = image; currentImage = image; currentImageID = "custom_" + revision.uuidString
            currentImageURLString = nil
        }
    }

    private func saveFavorites() { UserDefaults.standard.setCodable(favorites, forKey: "wallpaper_favorites") }
    private func loadFavorites() { favorites = UserDefaults.standard.codable([RemoteWallpaper].self, forKey: "wallpaper_favorites") ?? [] }
    private func saveBlocked() { UserDefaults.standard.set(Array(blockedIDs), forKey: "wallpaper_blocked") }
    private func loadBlocked() { let arr = UserDefaults.standard.stringArray(forKey: "wallpaper_blocked") ?? []; blockedIDs = Set(arr) }
    private func loadCustomImage() {
        guard source == .photo else { return }
        loadCachedImage(at: customPhotoFile(for: displayAppearance), imageID: "custom_" + displayAppearance.rawValue, custom: true)
    }
    private var customImageURL: URL { photoDirectory.appendingPathComponent("custom_wallpaper.jpg") }
    var canPreviewCurrentWallpaper: Bool {
        source == .photo ? customImage != nil : source.isRemote && currentImage != nil
    }

    func exportPreview() -> WallpaperExportPreviewModel? {
        guard canPreviewCurrentWallpaper else { return nil }
        if source == .photo {
            return WallpaperExportPreviewModel(localFiles: [customPhotoFile(for: displayAppearance)],
                image: customImage ?? currentImage)
        }
        return WallpaperExportPreviewModel(localFiles: exportLocalFiles(for: currentImageID),
            remoteURL: currentImageURLString.flatMap(URL.init(string:)), image: currentImage)
    }

    func exportPreview(for wall: RemoteWallpaper) -> WallpaperExportPreviewModel {
        WallpaperExportPreviewModel(localFiles: exportLocalFiles(for: wall.id),
            remoteURL: URL(string: wall.url.isEmpty ? wall.previewURL : wall.url),
            image: currentImageID == wall.id ? currentImage : nil)
    }

    private func exportLocalFiles(for id: String) -> [URL] {
        var files = favoriteImageStorage.imageURLs(for: id)
        let defaults = UserDefaults.standard
        if defaults.string(forKey: Self.currentWallpaperIDKey) == id,
           let name = defaults.string(forKey: Self.currentWallpaperFileKey) {
            files.append(Self.currentWallpaperCacheDirectory.appendingPathComponent(name))
        }
        return files
    }
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

    /// Restore a small first-frame preview before decoding the display image off-main.
    private func loadPersistedRemoteWallpaper() {
        guard source.isRemote else { return }

        let defaults = UserDefaults.standard
        guard let fileName = defaults.string(forKey: Self.currentWallpaperFileKey),
              let imageID = defaults.string(forKey: Self.currentWallpaperIDKey) else {
            return
        }

        let fileURL = Self.currentWallpaperCacheDirectory.appendingPathComponent(fileName)
        loadCachedImage(at: fileURL, imageID: imageID,
                        remoteURL: defaults.string(forKey: Self.currentWallpaperURLKey))
    }

    private func loadCachedImage(at file: URL, imageID: String, custom: Bool = false, remoteURL: String? = nil) {
        cachedImageLoadTask?.cancel()
        let loadID = UUID(); cachedImageLoadID = loadID
        let revision = imageLoadRevision
        let expectedSource = source
        let pixels = Self.backgroundPixels
        if let preview = WallpaperImageDecoder.preview(file: file) {
            let image = UIImage(cgImage: preview)
            if custom { customImage = image }
            currentImage = image; currentImageID = imageID; currentImageURLString = remoteURL
        }
        cachedImageLoadTask = Task { @MainActor [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                BrowserStartupTrace.markThread("wallpaper_cache_decode_start")
                defer { BrowserStartupTrace.mark("wallpaper_cache_decode_end") }
                guard !Task.isCancelled else { return nil as UIImage? }
                let image = WallpaperImageDecoder.decode(file: file, targetPixels: pixels).map { UIImage(cgImage: $0) }
                if !FileManager.default.fileExists(atPath: WallpaperImageDecoder.previewURL(for: file).path) {
                    WallpaperImageDecoder.writePreview(for: file)
                }
                return image
            }
            let image = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self else { return }
            defer { if self.cachedImageLoadID == loadID { self.cachedImageLoadTask = nil } }
            guard !Task.isCancelled, self.imageLoadRevision == revision, self.source == expectedSource else { return }
            guard let image else {
                if !custom { self.removePersistedRemoteWallpaper() }
                return
            }
            if custom { self.customImage = image }
            self.currentImage = image
            self.currentImageID = imageID
            self.currentImageURLString = remoteURL
        }
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
                WallpaperImageDecoder.writePreview(for: fileURL)
                return true
            } catch {
                return false
            }
        }.value

        guard saved else { return }
        guard currentImageID == wallpaper.id else {
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: WallpaperImageDecoder.previewURL(for: fileURL))
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
            try? FileManager.default.removeItem(at: WallpaperImageDecoder.previewURL(for: previousURL))
        }
    }

    /// Keep the visible image and saved originals while clearing regenerable
    /// remote previews. Cancel pending cache reads so an old result cannot win.
    func prepareForImageCacheCleanup() {
        removePersistedRemoteWallpaper()
    }

    private func removePersistedRemoteWallpaper() {
        cachedImageLoadTask?.cancel()
        imageLoadRevision = UUID()
        let defaults = UserDefaults.standard
        if let fileName = defaults.string(forKey: Self.currentWallpaperFileKey) {
            let fileURL = Self.currentWallpaperCacheDirectory.appendingPathComponent(fileName)
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: WallpaperImageDecoder.previewURL(for: fileURL))
        }
        defaults.removeObject(forKey: Self.currentWallpaperFileKey)
        defaults.removeObject(forKey: Self.currentWallpaperIDKey)
        defaults.removeObject(forKey: Self.currentWallpaperURLKey)
    }

    // MARK: - Favorite Originals

    /// Cache HD image to disk when user favorites a wallpaper.
    func cacheHDImage(for wallpaper: RemoteWallpaper) async {
        guard favorites.contains(where: { $0.id == wallpaper.id }) else { return }
        if await favoriteImageStorage.cachedData(for: wallpaper.id) != nil { return }
        let original = wallpaper.url.isEmpty ? wallpaper.previewURL : wallpaper.url
        for candidate in [original, wallpaper.previewURL] {
            guard !Task.isCancelled, favorites.contains(where: { $0.id == wallpaper.id }) else { return }
            guard let url = URL(string: candidate), let data = await downloadImageData(from: url) else { continue }
            guard favorites.contains(where: { $0.id == wallpaper.id }) else { return }
            let ids = Set(favorites.map(\.id)), revision = favoriteStorageRevision
            if await favoriteImageStorage.saveImage(data, for: wallpaper.id, favoriteIDs: ids, revision: revision) { return }
        }
    }

    /// Remove cached HD image when user removes from favorites.
    func removeHDCache(for id: String) {
        guard !favorites.contains(where: { $0.id == id }) else { return }
        let ids = Set(favorites.map(\.id)), revision = favoriteStorageRevision
        Task { await favoriteImageStorage.reconcile(favoriteIDs: ids, removingIDs: [id], revision: revision) }
    }

    /// Get cached HD image for a wallpaper (if available).
    func cachedHDImage(for id: String) -> UIImage? {
        for url in favoriteImageStorage.imageURLs(for: id) {
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { return image }
        }
        return nil
    }
}


/// Owns a copy of the original bytes for the lifetime of the preview and share sheet.
final class WallpaperExportFile: @unchecked Sendable {
    let url: URL
    private let directory: URL

    init(copying source: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WallpaperExport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            url = try PhotoImportPreparation.prepare(sourceURL: source, directory: directory, filename: "Wallpaper").url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

@MainActor
final class WallpaperExportPreviewModel: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var image: UIImage?
    @Published private(set) var file: WallpaperExportFile?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var saved = false
    @Published private(set) var loadFailed = false
    @Published var saveError: String?
    private let localFiles: [URL]
    private let remoteURL: URL?
    private let save: (URL) async throws -> Void

    init(localFiles: [URL], remoteURL: URL? = nil, image: UIImage? = nil,
         save: @escaping (URL) async throws -> Void = { try await WebResourceDownloadService.shared.saveImageToPhotos($0) }) {
        self.localFiles = localFiles; self.remoteURL = remoteURL; self.image = image; self.save = save
    }

    func prepare() async {
        guard !isLoading, file == nil else { return }
        isLoading = true; loadFailed = false
        defer { isLoading = false }
        do {
            for url in localFiles where FileManager.default.fileExists(atPath: url.path) {
                do { try await load(url); return }
                catch is CancellationError { throw CancellationError() }
                catch { /* A removed or incomplete cache can fall back to the source image. */ }
            }
            if let remoteURL {
                do {
                    let temporary = try await WebResourceDownloadService.shared.temporaryImageFile(remoteURL)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try await load(temporary)
                    return
                } catch is CancellationError { throw CancellationError() }
                catch { /* Keep export available offline when a displayed image is available. */ }
            }
            if let image {
                let work = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    guard let data = image.pngData() else { throw WebResourceDownloadError.invalidImage }
                    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try data.write(to: temporary)
                    return try WallpaperExportFile(copying: temporary)
                }
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                file = result
            } else { loadFailed = true }
        } catch is CancellationError { }
        catch { loadFailed = true }
    }

    private func load(_ url: URL) async throws {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let copy = try WallpaperExportFile(copying: url)
            guard let cg = WallpaperImageDecoder.decode(file: copy.url, targetPixels: CGSize(width: 2048, height: 2048)) else {
                throw WebResourceDownloadError.invalidImage
            }
            try Task.checkCancellation()
            return (copy, UIImage(cgImage: cg))
        }
        let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        file = result.0; image = result.1
    }

    func saveToPhotos() async {
        guard let file, !isSaving, !saved else { return }
        isSaving = true; saveError = nil
        defer { isSaving = false }
        do {
            try await save(file.url)
            saved = true
            HapticsManager.success()
            AppAccessibility.announce(LText("wallpaper_saved"))
        } catch is CancellationError { }
        catch { saveError = error.localizedDescription }
    }
}
