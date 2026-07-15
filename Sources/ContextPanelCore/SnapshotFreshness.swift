import Foundation

public enum SnapshotFreshness {
    public static let appMaximumAge: TimeInterval = 15 * 60
    public static let widgetMaximumAge: TimeInterval = appMaximumAge
    public static let companionProviderMaximumAge: TimeInterval = 15 * 60
    public static let companionMirrorMaximumAge: TimeInterval = 60 * 60
    public static let refreshNeededAge: TimeInterval = 5 * 60
    public static let widgetTimelineInterval: TimeInterval = 5 * 60
    public static let resetExpiryRefreshGrace: TimeInterval = 10
    public static let resetExpiryRetryDelay: TimeInterval = 30

    public static func compactAgeText(since date: Date, now: Date = Date()) -> String {
        let elapsedSeconds = max(Int(now.timeIntervalSince(date)), 0)
        if elapsedSeconds < 60 { return "now" }

        let minutes = elapsedSeconds / 60
        if minutes < 60 { return "\(minutes)m ago" }

        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }

        return "\(hours / 24)d ago"
    }
}
