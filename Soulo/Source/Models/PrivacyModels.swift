import Foundation

enum TrackerCategory: String, Codable, CaseIterable, Identifiable {
    case advertising
    case analytics
    case social
    case content
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .advertising: return "Advertising"
        case .analytics: return "Analytics"
        case .social: return "Social"
        case .content: return "Content"
        case .unknown: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .advertising: return "megaphone.fill"
        case .analytics: return "chart.line.uptrend.xyaxis"
        case .social: return "person.2.fill"
        case .content: return "rectangle.stack.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
}

struct TrackerClassification: Codable, Equatable, Hashable {
    let host: String
    let company: String
    let category: TrackerCategory
}

enum TrackerRequestState: String, Codable, Equatable, Hashable {
    case blocked
    case allowedProtectionDisabled
    case allowedOwnedByFirstParty
    case allowedOtherThirdPartyRequest
}

struct TrackerRequest: Codable, Identifiable {
    var urlString: String
    var host: String
    var eTLDplus1: String
    var pageURLString: String
    var ownerName: String
    var entityName: String
    var category: TrackerCategory
    var prevalence: Double?
    var state: TrackerRequestState

    var id: String {
        "\(entityName)|\(host)|\(state.rawValue)"
    }

    var isBlocked: Bool {
        state == .blocked
    }

    var networkNameForDisplay: String {
        entityName.isEmpty ? eTLDplus1 : entityName
    }
}

extension TrackerRequest: Equatable, Hashable {
    static func == (lhs: TrackerRequest, rhs: TrackerRequest) -> Bool {
        lhs.entityName == rhs.entityName
            && lhs.host == rhs.host
            && lhs.state == rhs.state
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entityName)
        hasher.combine(host)
        hasher.combine(state)
    }
}

struct ResourceObservation: Codable, Equatable {
    var urlString: String
    var resourceType: String
    var pageURLString: String
    var potentiallyBlocked: Bool
}

struct SitePrivacySummary: Codable, Equatable {
    var host: String
    var trackerHostsByCategory: [TrackerCategory: Set<String>] = [:]
    var trackerCompanies: Set<String> = []
    var trackerRequests: Set<TrackerRequest> = []
    var hiddenElementCount: Int = 0
    var httpsUpgradeCount: Int = 0
    var strippedTrackingParameterCount: Int = 0
    var cookieBannerActionCount: Int = 0

    var trackerHostCount: Int {
        let legacyCount = trackerHostsByCategory.values.reduce(0) { $0 + $1.count }
        guard legacyCount == 0 else { return legacyCount }
        return Set(trackerRequests.filter { $0.state != .allowedOtherThirdPartyRequest }.map(\.host)).count
    }

    var detectedTrackerCount: Int {
        trackerRequests.filter { !$0.isBlocked && $0.state != .allowedOtherThirdPartyRequest }.count
    }

    var thirdPartyRequestCount: Int {
        trackerRequests.filter { $0.state == .allowedOtherThirdPartyRequest }.count
    }

    var blockedTrackerCount: Int {
        trackerRequests.filter(\.isBlocked).count
    }

    var protectionCount: Int {
        trackerHostCount + hiddenElementCount + httpsUpgradeCount + strippedTrackingParameterCount + cookieBannerActionCount
    }

    static func empty(host: String) -> SitePrivacySummary {
        SitePrivacySummary(host: host)
    }

    enum CodingKeys: String, CodingKey {
        case host
        case trackerHostsByCategory
        case trackerCompanies
        case trackerRequests
        case hiddenElementCount
        case httpsUpgradeCount
        case strippedTrackingParameterCount
        case cookieBannerActionCount
    }

    init(host: String) {
        self.host = host
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        trackerHostsByCategory = try container.decodeIfPresent([TrackerCategory: Set<String>].self, forKey: .trackerHostsByCategory) ?? [:]
        trackerCompanies = try container.decodeIfPresent(Set<String>.self, forKey: .trackerCompanies) ?? []
        trackerRequests = try container.decodeIfPresent(Set<TrackerRequest>.self, forKey: .trackerRequests) ?? []
        hiddenElementCount = try container.decodeIfPresent(Int.self, forKey: .hiddenElementCount) ?? 0
        httpsUpgradeCount = try container.decodeIfPresent(Int.self, forKey: .httpsUpgradeCount) ?? 0
        strippedTrackingParameterCount = try container.decodeIfPresent(Int.self, forKey: .strippedTrackingParameterCount) ?? 0
        cookieBannerActionCount = try container.decodeIfPresent(Int.self, forKey: .cookieBannerActionCount) ?? 0
    }
}

enum BrowserDownloadStatus: String, Codable {
    case inProgress
    case finished
    case failed
    case canceled
}

struct BrowserDownloadItem: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var sourceURLString: String
    var localPath: String
    var startedAt: Date
    var completedAt: Date?
    var status: BrowserDownloadStatus
    var errorMessage: String

    var localURL: URL {
        URL(fileURLWithPath: localPath)
    }
}
