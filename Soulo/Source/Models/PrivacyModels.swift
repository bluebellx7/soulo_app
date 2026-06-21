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

struct SitePrivacySummary: Codable, Equatable {
    var host: String
    var trackerHostsByCategory: [TrackerCategory: Set<String>] = [:]
    var trackerCompanies: Set<String> = []
    var hiddenElementCount: Int = 0
    var httpsUpgradeCount: Int = 0
    var strippedTrackingParameterCount: Int = 0
    var cookieBannerActionCount: Int = 0

    var trackerHostCount: Int {
        trackerHostsByCategory.values.reduce(0) { $0 + $1.count }
    }

    var protectionCount: Int {
        trackerHostCount + hiddenElementCount + httpsUpgradeCount + strippedTrackingParameterCount + cookieBannerActionCount
    }

    static func empty(host: String) -> SitePrivacySummary {
        SitePrivacySummary(host: host)
    }
}

struct ReaderContent: Identifiable, Equatable {
    let title: String
    let byline: String
    let text: String
    let urlString: String

    var id: String {
        "\(urlString)|\(title)"
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum BrowserDownloadStatus: String, Codable {
    case inProgress
    case finished
    case failed
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
