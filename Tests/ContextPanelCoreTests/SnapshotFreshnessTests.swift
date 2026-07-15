import ContextPanelCore
import Foundation
import Testing

@Test func snapshotFreshnessUsesCompactElapsedAgeText() {
    let now = Date(timeIntervalSince1970: 10_000)

    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(30), now: now) == "now")
    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(-59), now: now) == "now")
    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(-60), now: now) == "1m ago")
    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(-3_599), now: now) == "59m ago")
    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(-3_600), now: now) == "1h ago")
    #expect(SnapshotFreshness.compactAgeText(since: now.addingTimeInterval(-86_400), now: now) == "1d ago")
}
