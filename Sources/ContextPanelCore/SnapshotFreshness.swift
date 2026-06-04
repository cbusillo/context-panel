import Foundation

public enum SnapshotFreshness {
    public static let appMaximumAge: TimeInterval = 15 * 60
    public static let widgetMaximumAge: TimeInterval = appMaximumAge
    public static let refreshNeededAge: TimeInterval = 5 * 60
    public static let widgetTimelineInterval: TimeInterval = 5 * 60
}
