import ActivityKit
import Foundation

@MainActor
class LiveActivityService {
    static let shared = LiveActivityService()
    private var currentActivity: Activity<SouloLiveActivityAttributes>?

    func startOrUpdate(keyword: String, platformName: String, platformIcon: String = "magnifyingglass") {
        let state = SouloLiveActivityAttributes.ContentState(
            keyword: keyword,
            platformName: platformName,
            platformIcon: platformIcon
        )

        // Stale after 30 seconds
        let staleDate = Date.now.addingTimeInterval(30)

        if let activity = currentActivity {
            Task {
                await activity.update(ActivityContent(state: state, staleDate: staleDate))
            }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = SouloLiveActivityAttributes(searchSessionID: UUID().uuidString)
            let content = ActivityContent(state: state, staleDate: staleDate)
            do {
                currentActivity = try Activity.request(attributes: attributes, content: content)
            } catch {
                // Failed to start activity
            }
        }
    }

    func end() {
        endAllActivities()
    }

    /// End any leftover activities from a previous app session
    func cleanupStaleActivities() {
        endAllActivities()
    }

    private func endAllActivities() {
        // End tracked activity
        if let activity = currentActivity {
            Task {
                await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            }
            currentActivity = nil
        }
        // Also end any orphaned activities
        for activity in Activity<SouloLiveActivityAttributes>.activities {
            Task {
                await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }
}
