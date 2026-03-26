import Foundation

enum PlatformInteractionType: String, Codable {
    case urlSearch       // Standard: load search URL directly
    case aiChat          // AI chat: need to inject text into chat input and send
}

struct SearchPlatform: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var iconName: String
    var searchURLTemplate: String
    var homeURL: String
    var region: PlatformRegion
    var isBuiltIn: Bool
    var isVisible: Bool
    var sortOrder: Int
    var usageCount: Int
    var isCustom: Bool
    var requiresLogin: Bool
    var interactionType: PlatformInteractionType
    var faviconURL: String?

    // Default init for backward compatibility
    init(id: UUID, name: String, iconName: String, searchURLTemplate: String, homeURL: String,
         region: PlatformRegion, isBuiltIn: Bool, isVisible: Bool, sortOrder: Int,
         usageCount: Int, isCustom: Bool,
         requiresLogin: Bool = false,
         interactionType: PlatformInteractionType = .urlSearch,
         faviconURL: String? = nil) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.searchURLTemplate = searchURLTemplate
        self.homeURL = homeURL
        self.region = region
        self.isBuiltIn = isBuiltIn
        self.isVisible = isVisible
        self.sortOrder = sortOrder
        self.usageCount = usageCount
        self.isCustom = isCustom
        self.requiresLogin = requiresLogin
        self.interactionType = interactionType
        self.faviconURL = faviconURL
    }

    // Custom Codable to handle backward compatibility with old cached data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        iconName = try container.decode(String.self, forKey: .iconName)
        searchURLTemplate = try container.decode(String.self, forKey: .searchURLTemplate)
        homeURL = try container.decode(String.self, forKey: .homeURL)
        region = try container.decode(PlatformRegion.self, forKey: .region)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        isVisible = try container.decode(Bool.self, forKey: .isVisible)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        usageCount = try container.decode(Int.self, forKey: .usageCount)
        isCustom = try container.decode(Bool.self, forKey: .isCustom)
        requiresLogin = try container.decodeIfPresent(Bool.self, forKey: .requiresLogin) ?? false
        interactionType = try container.decodeIfPresent(PlatformInteractionType.self, forKey: .interactionType) ?? .urlSearch
        faviconURL = try container.decodeIfPresent(String.self, forKey: .faviconURL)
    }

    /// Character set safe for URL query values — encodes +, #, &, = etc.
    private static let queryValueAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "#+&=@!$'()*,;")
        return cs
    }()

    func searchURL(for keyword: String) -> URL? {
        guard let encoded = keyword.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            return nil
        }
        let urlString = searchURLTemplate.replacingOccurrences(of: "%@", with: encoded)
        return URL(string: urlString)
    }

    var homePageURL: URL? {
        URL(string: homeURL)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: SearchPlatform, rhs: SearchPlatform) -> Bool {
        lhs.id == rhs.id
    }
}
