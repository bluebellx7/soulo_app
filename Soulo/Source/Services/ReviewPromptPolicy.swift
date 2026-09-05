import Foundation

/// Persist the request before invoking StoreKit: the system may choose not to display it.
enum ReviewPromptPolicy {
    static let firstUseKey = "review.firstUse"
    static let requestedKey = "review.requestedOnce"
    static let delay: TimeInterval = 7 * 24 * 60 * 60

    static func recordUse(defaults: UserDefaults = .standard, now: Date = .now) {
        if defaults.object(forKey: firstUseKey) == nil { defaults.set(now, forKey: firstUseKey) }
    }
    static func consumeIfEligible(defaults: UserDefaults = .standard, now: Date = .now) -> Bool {
        guard !defaults.bool(forKey: requestedKey), let first = defaults.object(forKey: firstUseKey) as? Date,
              now.timeIntervalSince(first) >= delay else { return false }
        defaults.set(true, forKey: requestedKey)
        return true
    }
}
