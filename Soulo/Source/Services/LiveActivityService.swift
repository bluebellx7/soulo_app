import ActivityKit
import Foundation

@MainActor
class LiveActivityService {
    static let shared = LiveActivityService()
    static let enabledKey = "live_activity_enabled"

    private var activityStorage: Any?
    @available(iOS 16.1, *)
    private var currentActivity: Activity<SouloLiveActivityAttributes>? {
        get { activityStorage as? Activity<SouloLiveActivityAttributes> }
        set { activityStorage = newValue }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func startOrUpdate(keyword: String, platformName: String, platformIcon: String = "magnifyingglass") {
        guard isEnabled else {
            endAllActivities()
            return
        }
        guard #available(iOS 16.1, *) else { return }

        let state = SouloLiveActivityAttributes.ContentState(
            keyword: keyword,
            platformName: platformName,
            platformIcon: platformIcon
        )

        // Stale after 30 seconds
        let staleDate = Date.now.addingTimeInterval(30)

        if let activity = currentActivity {
            Task {
                if #available(iOS 16.2, *) {
                    await activity.update(ActivityContent(state: state, staleDate: staleDate))
                } else {
                    await activity.update(using: state)
                }
            }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let attributes = SouloLiveActivityAttributes(searchSessionID: UUID().uuidString)
            do {
                if #available(iOS 16.2, *) {
                    let content = ActivityContent(state: state, staleDate: staleDate)
                    currentActivity = try Activity.request(attributes: attributes, content: content)
                } else {
                    currentActivity = try Activity.request(attributes: attributes, contentState: state)
                }
            } catch {
                // Failed to start activity
            }
        }
    }

    func end() {
        endAllActivities()
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if !enabled {
            endAllActivities()
        }
    }

    /// End any leftover activities from a previous app session
    func cleanupStaleActivities() {
        guard isEnabled else {
            endAllActivities()
            return
        }
        endAllActivities()
    }

    private func endAllActivities() {
        guard #available(iOS 16.1, *) else { return }
        // End tracked activity
        if let activity = currentActivity {
            Task {
                await dismiss(activity)
            }
            currentActivity = nil
        }
        // Also end any orphaned activities
        for activity in Activity<SouloLiveActivityAttributes>.activities {
            Task {
                await dismiss(activity)
            }
        }
    }

    @available(iOS 16.1, *)
    private func dismiss(_ activity: Activity<SouloLiveActivityAttributes>) async {
        if #available(iOS 16.2, *) {
            await activity.end(ActivityContent(state: activity.content.state, staleDate: nil), dismissalPolicy: .immediate)
        } else {
            await activity.end(using: activity.contentState, dismissalPolicy: .immediate)
        }
    }
}
