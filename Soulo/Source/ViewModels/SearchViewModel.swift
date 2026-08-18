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
    @Published var currentKeyword: String = ""
    @Published var selectedRegion: PlatformRegion = .international
    @Published var selectedPlatform: SearchPlatform?
    @Published var clipboardContent: String? = nil
    @Published var showClipboardPrompt: Bool = false
    @Published var recentSearches: [String] = []

    // Live autocomplete suggestions
    @Published var suggestions: [String] = []
    @Published var isLoadingSuggestions: Bool = false
    private var suggestionTask: Task<Void, Never>?
    private var suggestCancellables = Set<AnyCancellable>()

    init() {
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

    // MARK: - F3: Spell Correction
    @Published var spellSuggestion: String? = nil

    // MARK: - F7: Enhanced Clipboard
    @Published var clipboardContentType: ClipboardContentType = .generalText
    @Published var suggestedClipboardPlatforms: [SearchPlatform] = []

    @AppStorage("is_incognito") var isIncognito: Bool = false
    @AppStorage("last_clipboard_hash") private var lastClipboardHash: String = ""
    @AppStorage("last_clipboard_change_count") private var lastClipboardChangeCount: Int = 0

    // MARK: - Search

    func performSearch(context: ModelContext? = nil) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        currentKeyword = trimmed
        isSearching = true
        searchID = UUID()
        clearSuggestions()

        // Clear previous suggestions
        spellSuggestion = nil

        if trimmed.isValidURL {
            // URL detected — caller handles direct load
        } else {
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

        // F3: Spell correction (async-safe, UITextChecker is fast)
        spellSuggestion = SpellCorrectionService.suggest(for: trimmed)

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
        // Detect pasteboard content without reading it, avoiding the system paste prompt.
        let changeCount = UIPasteboard.general.changeCount
        guard changeCount != lastClipboardChangeCount else { return }
        Task { @MainActor in
            guard let patterns = try? await UIPasteboard.general.detectedPatterns(for: [\.probableWebURL, \.number, \.probableWebSearch]),
                  !patterns.isEmpty else { return }
            self.clipboardContent = nil
            self.suggestedClipboardPlatforms = []
            self.showClipboardPrompt = true
        }
    }

    func dismissClipboard() {
        showClipboardPrompt = false
        lastClipboardChangeCount = UIPasteboard.general.changeCount
        if let content = clipboardContent {
            lastClipboardHash = Self.stableHash(for: content)
        }
    }

    func searchFromClipboard(context: ModelContext? = nil) {
        guard let content = readClipboardForUserAction() else {
            dismissClipboard()
            return
        }
        searchText = content
        performSearch(context: context)
        dismissClipboard()
    }

    private func readClipboardForUserAction() -> String? {
        guard let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let hash = Self.stableHash(for: text)
        guard hash != lastClipboardHash else { return nil }

        clipboardContent = text

        let analysis = ClipboardAnalyzer.analyze(text)
        clipboardContentType = analysis.type

        let allPlatforms = PlatformDataStore.shared.allPlatforms()
        suggestedClipboardPlatforms = analysis.suggestedPlatforms.compactMap { name in
            allPlatforms.first { $0.name == name && $0.isVisible }
        }

        return text
    }

    // MARK: - Clear

    func clearSearch() {
        searchText = ""
        isSearching = false
        currentKeyword = ""
        spellSuggestion = nil
        // F6: End Live Activity
        LiveActivityService.shared.end()
    }

    // MARK: - History

    func loadRecentSearches(context: ModelContext) {
        let descriptor = FetchDescriptor<SearchHistoryItem>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        do {
            let items = try context.fetch(descriptor)
            var seen = Set<String>()
            var unique: [String] = []
            for item in items {
                guard !item.isWebVisit else { continue }
                if !seen.contains(item.keyword) {
                    seen.insert(item.keyword)
                    unique.append(item.keyword)
                    if unique.count >= 20 { break }
                }
            }
            recentSearches = unique
        } catch {
            recentSearches = []
        }
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
