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

    // MARK: - F5: Platform Recommendation
    @Published var recommendedPlatforms: [SearchPlatform] = []

    // MARK: - F3: Spell Correction
    @Published var spellSuggestion: String? = nil

    // MARK: - F7: Enhanced Clipboard
    @Published var clipboardContentType: ClipboardContentType = .generalText
    @Published var suggestedClipboardPlatforms: [SearchPlatform] = []

    // MARK: - F8: Cross-language
    @Published var translatedKeyword: String? = nil
    @Published var translationTargetLanguage: String? = nil

    @AppStorage("is_incognito") var isIncognito: Bool = false
    @AppStorage("last_clipboard_hash") private var lastClipboardHash: String = ""

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
        translatedKeyword = nil
        translationTargetLanguage = nil

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

        if var platform = selectedPlatform {
            platform.usageCount += 1
            selectedPlatform = platform
            PlatformDataStore.shared.incrementUsage(for: platform.id)
        }

        // F5: Platform recommendations
        recommendedPlatforms = PlatformRecommendationService.recommend(for: trimmed)

        // F3: Spell correction (async-safe, UITextChecker is fast)
        spellSuggestion = SpellCorrectionService.suggest(for: trimmed)

        // F8: Cross-language translation
        if let result = TranslationService.translate(trimmed) {
            translatedKeyword = result.translated
            translationTargetLanguage = result.targetLanguageName
        }

        // F6: Live Activity
        if let platform = selectedPlatform {
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

    func selectRegion(_ region: PlatformRegion) {
        selectedRegion = region
        selectedPlatform = PlatformDataStore.shared.firstVisiblePlatform(for: region)
    }

    func selectPlatform(_ platform: SearchPlatform) {
        selectedPlatform = platform
        PlatformDataStore.shared.incrementUsage(for: platform.id)

        // F6: Update Live Activity
        if !currentKeyword.isEmpty {
            LiveActivityService.shared.startOrUpdate(
                keyword: currentKeyword,
                platformName: LanguageManager.shared.localizedString(platform.name)
            )
        }
    }

    // MARK: - Clipboard (F7 Enhanced)

    func detectClipboard() {
        // Use detectPatterns to avoid the "wants to paste" system prompt
        // Only shows our custom prompt if clipboard has string content
        UIPasteboard.general.detectPatterns(for: [.probableWebURL, .number, .probableWebSearch]) { result in
            guard case .success(let patterns) = result, !patterns.isEmpty else { return }
            Task { @MainActor in
                // Now safe to read — user already interacted with the app
                guard let text = UIPasteboard.general.string,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                let hash = String(text.hashValue)
                guard hash != self.lastClipboardHash else { return }

                self.clipboardContent = text

                // F7: Analyze clipboard content
                let analysis = ClipboardAnalyzer.analyze(text)
                self.clipboardContentType = analysis.type

                let allPlatforms = PlatformDataStore.shared.allPlatforms()
                self.suggestedClipboardPlatforms = analysis.suggestedPlatforms.compactMap { name in
                    allPlatforms.first { $0.name == name && $0.isVisible }
                }

                self.showClipboardPrompt = true
            }
        }
    }

    func dismissClipboard() {
        showClipboardPrompt = false
        if let content = clipboardContent {
            lastClipboardHash = String(content.hashValue)
        }
    }

    func searchFromClipboard(context: ModelContext? = nil) {
        guard let content = clipboardContent else { return }
        searchText = content
        performSearch(context: context)
        dismissClipboard()
    }

    // MARK: - Clear

    func clearSearch() {
        searchText = ""
        isSearching = false
        currentKeyword = ""
        recommendedPlatforms = []
        spellSuggestion = nil
        translatedKeyword = nil
        translationTargetLanguage = nil

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
        let predicate = #Predicate<SearchHistoryItem> { $0.keyword == keyword }
        let descriptor = FetchDescriptor<SearchHistoryItem>(predicate: predicate)
        do {
            let items = try context.fetch(descriptor)
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
}
