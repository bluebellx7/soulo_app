import SwiftUI

@MainActor
class PlatformManagerViewModel: ObservableObject {
    @Published var platforms: [SearchPlatform] = []
    @AppStorage("auto_sort_frequency") var autoSortByFrequency = false

    private let store = PlatformDataStore.shared

    init() {
        loadPlatforms()
    }

    func loadPlatforms() {
        platforms = store.allPlatforms()
    }

    func platforms(for region: PlatformRegion) -> [SearchPlatform] {
        platforms.filter { $0.region == region }.sorted { $0.sortOrder < $1.sortOrder }
    }

    func movePlatform(from source: IndexSet, to destination: Int, region: PlatformRegion) {
        var regionPlatforms = platforms(for: region)
        regionPlatforms.move(fromOffsets: source, toOffset: destination)

        // Update sort orders
        for (index, platform) in regionPlatforms.enumerated() {
            if let globalIndex = platforms.firstIndex(where: { $0.id == platform.id }) {
                platforms[globalIndex].sortOrder = index
            }
        }

        store.platforms = platforms
        store.savePlatforms()
        loadPlatforms()
    }

    func toggleVisibility(_ platform: SearchPlatform) {
        if let index = platforms.firstIndex(where: { $0.id == platform.id }) {
            platforms[index].isVisible.toggle()
            store.platforms = platforms
        store.savePlatforms()
        }
    }

    func addCustomPlatform(name: String, searchURL: String, homeURL: String, region: PlatformRegion) {
        store.addCustomPlatform(name: name, searchURL: searchURL, homeURL: homeURL, region: region)
        loadPlatforms()
    }

    func deleteCustomPlatform(id: UUID) {
        store.deleteCustomPlatform(id: id)
        loadPlatforms()
    }

    func resetToDefaults() {
        store.resetToDefaults()
        loadPlatforms()
    }

    func sortByFrequency() {
        store.sortByFrequency()
        loadPlatforms()
    }
}
