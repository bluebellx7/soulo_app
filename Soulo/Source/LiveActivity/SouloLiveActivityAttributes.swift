import ActivityKit
import Foundation

struct SouloLiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var keyword: String
        var platformName: String
        var platformIcon: String
    }

    var searchSessionID: String
}
