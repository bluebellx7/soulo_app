import SwiftUI

enum PlatformRegion: String, Codable, CaseIterable, Identifiable {
    case china = "china"
    case international = "international"
    case japan = "japan"
    case russia = "russia"

    var id: String { rawValue }

    var nameKey: String {
        switch self {
        case .china:         return "region_china"
        case .international: return "region_international"
        case .japan:         return "region_japan"
        case .russia:        return "region_russia"
        }
    }

    var displayIcon: String {
        switch self {
        case .china:         return "globe.asia.australia.fill"
        case .international: return "globe.americas.fill"
        case .japan:         return "globe.asia.australia.fill"
        case .russia:        return "globe.europe.africa.fill"
        }
    }

    var iconName: String {
        switch self {
        case .china:         return "flag.fill"
        case .international: return "globe"
        case .japan:         return "flag.fill"
        case .russia:        return "flag.fill"
        }
    }

    /// Returns all cases sorted with the given region first
    static func sortedCases(preferring preferred: PlatformRegion) -> [PlatformRegion] {
        var cases = Array(allCases)
        if let idx = cases.firstIndex(of: preferred), idx != 0 {
            cases.remove(at: idx)
            cases.insert(preferred, at: 0)
        }
        return cases
    }

    var accentColor: Color {
        switch self {
        case .china:         return .red
        case .international: return .blue
        case .japan:         return .pink
        case .russia:        return .purple
        }
    }
}
