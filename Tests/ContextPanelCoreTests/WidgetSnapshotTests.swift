import Foundation
import Testing

@testable import ContextPanelCore

@Test func widgetSnapshotUsesSetupNeededForMissingStore() {
    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: nil, status: .unknown),
        now: Date(timeIntervalSince1970: 0)
    )

    #expect(widget.state == .setupNeeded)
    #expect(widget.status == .unknown)
    #expect(widget.limits.isEmpty)
    #expect(widget.message.contains("Set up"))
}

@Test func widgetSnapshotPreservesStaleCachedLimits() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [UsageLimit(provider: .openAI, label: "Codex", used: 20, limit: 100)]
    ))

    let widget = WidgetSnapshot.fromStore(
        SnapshotStoreLoadResult(snapshot: stored, status: .stale),
        now: Date(timeIntervalSince1970: 1_000)
    )

    #expect(widget.state == .stale)
    #expect(widget.limits.count == 1)
    #expect(widget.message == "Last snapshot is stale.")
}

@Test func widgetSnapshotBuildsProviderSummaries() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Codex", used: 85, limit: 100),
            UsageLimit(provider: .google, label: "Gemini", used: 10, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy))
    let summaries = Dictionary(uniqueKeysWithValues: widget.providerSummaries.map { ($0.provider, $0) })

    #expect(widget.state == .ready)
    #expect(summaries[.openAI]?.status == .close)
    #expect(summaries[.openAI]?.limitCount == 1)
    #expect(summaries[.openAI]?.tightestLimit?.label == "Codex")
    #expect(summaries[.google]?.status == .healthy)
    #expect(summaries[.anthropic]?.limitCount == 0)
}

@Test func providerSummariesUseTheTightestWindowInsteadOfAverageCapacity() {
    let savedAt = Date(timeIntervalSince1970: 100)
    let stored = StoredUsageSnapshot(savedAt: savedAt, snapshot: UsageSnapshot(
        generatedAt: savedAt,
        limits: [
            UsageLimit(provider: .openAI, label: "Weekly", used: 95, limit: 100),
            UsageLimit(provider: .openAI, label: "5-hour", used: 5, limit: 100),
        ]
    ))

    let widget = WidgetSnapshot.fromStore(SnapshotStoreLoadResult(snapshot: stored, status: .healthy))
    let openAI = widget.providerSummaries.first { $0.provider == .openAI }

    #expect(abs((openAI?.capacityRatio ?? 0) - 0.05) < 0.0001)
    #expect(openAI?.tightestLimit?.label == "Weekly")
}
