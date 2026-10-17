import SwiftUI
import SwiftData
import UIKit
import CoreSpotlight
import Combine

@MainActor
class SearchViewModel: ObservableObject {

    // MARK: - Core Published Properties

    @Published var searchText: String = ""
    @Published var isSearching: Bool = false
    /// Unique ID that changes each time a new search is performed. Used to detect new vs. returning.
    @Published var searchID: UUID = UUID()
    @Published var externalSearchRequestID: UUID?
    @Published var currentKeyword: String = ""
    var isSelectionSearch = false
    @Published var selectedRegion: PlatformRegion = .international
    @Published var selectedPlatform: SearchPlatform?
    @Published var clipboardContent: String? = nil
    @Published var showClipboardPrompt: Bool = false {
        didSet {
            if !showClipboardPrompt {
                clipboardSearchID = UUID()
                isReadingClipboard = false
            }
        }
    }
    @Published private(set) var isReadingClipboard = false
    private var clipboardSearchID = UUID()
    @Published var recentSearches: [String] = []

    // Live autocomplete suggestions
    @Published var suggestions: [String] = []
    @Published var isLoadingSuggestions: Bool = false
    private var suggestionTask: Task<Void, Never>?
    private var suggestCancellables = Set<AnyCancellable>()
    private let clipboardReader: any ClipboardReading

    init(clipboardReader: (any ClipboardReading)? = nil) {
        self.clipboardReader = clipboardReader ?? SystemClipboardReader()
        selectedRegion = Self.detectDefaultRegion()
        selectedPlatform = PlatformDataStore.shared.firstVisiblePlatform(for: selectedRegion)
        setupSuggestionDebouncer()
    }

    // MARK: - Autocomplete Suggestions

    private func setupSuggestionDebouncer() {
        $searchText
            .removeDuplicates()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] text in
                self?.fetchSuggestions(for: text)
            }
            .store(in: &suggestCancellables)
    }

    private func fetchSuggestions(for query: String) {
        // Cancel any in-flight request
        suggestionTask?.cancel()

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Don't fetch if:
        // - empty
        // - URL (user is pasting a link)
        // - text matches the last submitted search (user just arrived at results page)
        guard !trimmed.isEmpty,
              !trimmed.isValidURL,
              trimmed != currentKeyword
        else {
            suggestions = []
            isLoadingSuggestions = false
            return
        }

        isLoadingSuggestions = true
        let region = selectedRegion
        suggestionTask = Task { @MainActor [weak self] in
            let results = await SearchSuggestionService.fetch(query: trimmed, region: region)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Re-check conditions on completion (user may have submitted in flight)
            let current = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard current == trimmed, current != self.currentKeyword else {
                self.suggestions = []
                self.isLoadingSuggestions = false
                return
            }
            self.suggestions = results
            self.isLoadingSuggestions = false
        }
    }

    func clearSuggestions() {
        suggestionTask?.cancel()
        suggestions = []
        isLoadingSuggestions = false
    }

    /// Detect if user is likely in China based on locale/timezone
    private static func detectDefaultRegion() -> PlatformRegion {
        let locale = Locale.current
        let regionCode = locale.region?.identifier ?? ""
        let langCode = locale.language.languageCode?.identifier ?? ""
        let timezone = TimeZone.current.identifier

        // China: region CN, language zh, or timezone Asia/Shanghai etc.
        if regionCode == "CN" || langCode == "zh" || timezone.hasPrefix("Asia/Shanghai") || timezone.hasPrefix("Asia/Chongqing") {
            return .china
        }
        // Japan
        if regionCode == "JP" || langCode == "ja" || timezone.hasPrefix("Asia/Tokyo") {
            return .japan
        }
        // Russia
        if regionCode == "RU" || langCode == "ru" || timezone.hasPrefix("Europe/Moscow") {
            return .russia
        }
        return .international
    }

    // MARK: - F7: Enhanced Clipboard
    @Published var clipboardContentType: ClipboardContentType = .generalText
    @Published var suggestedClipboardPlatforms: [SearchPlatform] = []

    @AppStorage("is_incognito") var isIncognito: Bool = false
    @AppStorage("last_clipboard_hash") private var lastClipboardHash: String = ""
    @AppStorage("last_clipboard_change_count") private var lastClipboardChangeCount: Int = 0

    @discardableResult
    func setPrivateBrowsing(_ enabled: Bool, tabManager: TabManager) -> Bool {
        isIncognito = enabled
        guard tabManager.synchronizePrivacyMode() else { return false }
        clearSearch()
        clearSuggestions()
        showClipboardPrompt = false
        return true
    }

    // MARK: - Search

    @discardableResult
    func performHomeSearch(
        tabManager: TabManager,
        preferredRegion: PlatformRegion?,
        customGroup: CustomGroup?,
        context: ModelContext? = nil
    ) -> Bool {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = tabManager.prepareTabForHomeSearch() else { return false }

        prepareForHomeSearch(preferredRegion: preferredRegion, customGroup: customGroup)
        performSearch(context: context)
        // Reserve the tab before SwiftUI starts loading, so another submission
        // cannot mistake a pending search for an unused blank tab.
        if let index = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) {
            tabManager.tabs[index].keyword = currentKeyword
            tabManager.tabs[index].platform = selectedPlatform
        }
        return true
    }

    func performSearch(context: ModelContext? = nil) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        BrowserStartupTrace.mark("search_submit")
        currentKeyword = trimmed
        isSelectionSearch = false
        isSearching = true
        searchID = UUID()
        clearSuggestions()

        if case .search? = BrowserNavigationResolver.classify(trimmed) {
            if !isIncognito, let context {
                recordHistory(keyword: trimmed, context: context)
            }
        }

        if selectedPlatform == nil || selectedPlatform?.region != selectedRegion {
            selectedPlatform = PlatformDataStore.shared.firstVisiblePlatform(for: selectedRegion)
        }

        if !isIncognito, var platform = selectedPlatform {
            platform.usageCount += 1
            selectedPlatform = platform
            PlatformDataStore.shared.incrementUsage(for: platform.id)
        }

        // F6: Live Activity
        if !isIncognito, let platform = selectedPlatform {
            LiveActivityService.shared.startOrUpdate(
                keyword: trimmed,
                platformName: LanguageManager.shared.localizedString(platform.name)
            )
        }
    }

    // MARK: - F1: Siri Intent Search

    func performIntentSearch(query: String, platformName: String?, context: ModelContext? = nil) {
        searchText = query

        // Try to find platform by localized name
        if let name = platformName {
            let all = PlatformDataStore.shared.allPlatforms()
            if let match = all.first(where: { LanguageManager.shared.localizedString($0.name) == name }) {
                selectedRegion = match.region
                selectedPlatform = match
            }
        }

        performSearch(context: context)
    }

    // MARK: - Region & Platform Selection

    /// A search submitted from Home starts with the first platform in the user's
    /// current ordering. `SearchViewModel` can outlive platform-management edits,
    /// so its cached selection must be refreshed before entering results.
    func prepareForHomeSearch(preferredRegion: PlatformRegion?, customGroup: CustomGroup?) {
        if let customGroup,
           let firstPlatform = PlatformDataStore.shared.platformsForGroup(customGroup).first {
            selectedRegion = firstPlatform.region
            selectedPlatform = firstPlatform
            return
        }

        selectRegion(preferredRegion ?? selectedRegion)
    }

    func selectRegion(_ region: PlatformRegion) {
        selectedRegion = region
        selectedPlatform = PlatformDataStore.shared.firstVisiblePlatform(for: region)
    }

    func selectPlatform(_ platform: SearchPlatform) {
        selectedPlatform = platform
        if !isIncognito {
            PlatformDataStore.shared.incrementUsage(for: platform.id)
        }

        // F6: Update Live Activity
        if !isIncognito, !currentKeyword.isEmpty {
            LiveActivityService.shared.startOrUpdate(
                keyword: currentKeyword,
                platformName: LanguageManager.shared.localizedString(platform.name)
            )
        }
    }

    // MARK: - Clipboard (F7 Enhanced)

    func detectClipboard() {
        let changeCount = clipboardReader.changeCount
        guard changeCount != lastClipboardChangeCount else { return }
        Task { @MainActor [weak self, clipboardReader] in
            guard await clipboardReader.hasSearchableContent(), let self,
                  clipboardReader.changeCount == changeCount,
                  self.lastClipboardChangeCount != changeCount else { return }
            self.lastClipboardChangeCount = changeCount
            // Show the existing generic prompt. Read copied text only after
            // the user presses Search, so activation cannot interrupt browsing
            // with a paste-permission dialog or expose a stale preview.
            self.clipboardContent = nil
            self.clipboardContentType = .generalText
            self.suggestedClipboardPlatforms = []
            self.showClipboardPrompt = true
        }
    }

    func dismissClipboard() {
        showClipboardPrompt = false
        lastClipboardChangeCount = clipboardReader.changeCount
        if let content = clipboardContent {
            lastClipboardHash = Self.stableHash(for: content)
        }
    }

    func searchFromClipboard(onSearch: @escaping () -> Void) {
        guard !isReadingClipboard else { return }
        let requestID = UUID()
        clipboardSearchID = requestID
        isReadingClipboard = true
        Task { @MainActor [weak self, clipboardReader] in
            let text = await clipboardReader.readText()
            guard let self, self.clipboardSearchID == requestID else { return }
            guard let content = text, !content.isEmpty else {
                self.dismissClipboard()
                return
            }
            self.updateClipboardAnalysis(content)
            self.searchText = content
            onSearch()
            self.dismissClipboard()
        }
    }

    private func updateClipboardAnalysis(_ text: String) {
        clipboardContent = text

        let analysis = ClipboardAnalyzer.analyze(text)
        clipboardContentType = analysis.type

        let allPlatforms = PlatformDataStore.shared.allPlatforms()
        suggestedClipboardPlatforms = analysis.suggestedPlatforms.compactMap { name in
            allPlatforms.first { $0.name == name && $0.isVisible }
        }
    }

    // MARK: - Clear

    func clearSearch() {
        searchText = ""
        isSearching = false
        currentKeyword = ""
        isSelectionSearch = false
        // F6: End Live Activity
        LiveActivityService.shared.end()
    }

    // MARK: - History

    func loadRecentSearches(context: ModelContext) {
        recentSearches = SearchHistoryService.recentSearchKeywords(context: context)
    }

    func deleteHistoryItem(keyword: String, context: ModelContext) {
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        do {
            let items = try context.fetch(descriptor).filter {
                !$0.isWebVisit && $0.keyword == keyword
            }
            for item in items {
                context.delete(item)
                // F2: Deindex from Spotlight
                SpotlightIndexingService.deindexItem(id: "search-history-\(item.id.uuidString)")
            }
            try context.save()
            loadRecentSearches(context: context)
        } catch {}
    }

    func clearAllHistory(context: ModelContext) {
        let descriptor = FetchDescriptor<SearchHistoryItem>()
        do {
            let items = try context.fetch(descriptor)
            for item in items { context.delete(item) }
            try context.save()
            recentSearches = []
            // F2: Deindex all history from Spotlight
            SpotlightIndexingService.deindexAll(domain: "soulo.history")
        } catch {}
    }

    // MARK: - Private Helpers

    private func recordHistory(keyword: String, context: ModelContext) {
        let item = SearchHistoryItem(keyword: keyword)
        context.insert(item)
        do {
            try context.save()
            // F2: Index in Spotlight
            SpotlightIndexingService.indexHistoryItem(keyword: keyword, id: item.id)
        } catch {}
    }

    private static func stableHash(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
