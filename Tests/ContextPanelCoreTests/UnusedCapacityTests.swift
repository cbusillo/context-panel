import Foundation
import Testing
@testable import ContextPanelCore

// #1080: capacity that went unused, read from saved history.

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()
private let wasteNow = ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z")!
private let lastWeekDay = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!
private let minute: TimeInterval = 60
private let day: TimeInterval = 86_400

private struct WasteAccount {
    var used: Int
    var reset: Date
    var banked: ProviderResetCreditSummary?
    var credits: ProviderUsageCreditSummary?
}

private func wasteReading(_ at: Date, _ accounts: [String: WasteAccount]) -> StoredUsageSnapshot {
    let names = accounts.keys.sorted()
    let limits = names.map { name in
        UsageLimit(provider: .openAI, accountID: name, configuredAccountID: name, accountName: name, label: "Codex Weekly",
                   windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: accounts[name]!.used, limit: 100,
                   resetsAt: accounts[name]!.reset, lastUpdatedAt: at, confidence: .observed)
    }
    let reports = names.map { StoredProviderReport(provider: .openAI, accountID: $0, configuredAccountID: $0, accountName: $0,
        generatedAt: at, resetCredits: accounts[$0]!.banked, usageCredits: accounts[$0]!.credits, status: .healthy, errorMessage: nil) }
    return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: limits), reports: reports)
}

private func lastWeek(_ readings: [StoredUsageSnapshot]) throws -> (UnusedCapacityWeek, ProviderUnusedCapacity) {
    let summary = try #require(UnusedCapacityHistory.summaries(readings: readings, now: wasteNow, calendar: utc).first)
    return (summary.lastWeek, summary)
}

private func banked(_ count: Int, expiries: [Date], at: Date) -> ProviderResetCreditSummary {
    ProviderResetCreditSummary(availableCount: count, observedAt: at, coverage: .complete, knownExpiries: expiries)
}

@Test func quotaLeftAtANaturalOrProviderWideRefillCountsAsUnused() throws {
    let before = lastWeekDay.addingTimeInterval(-5 * minute)
    let after = lastWeekDay.addingTimeInterval(5 * minute)
    let nextWeek = lastWeekDay.addingTimeInterval(7 * day)

    // A natural refill with 40% used lets 60 points refill unused.
    let (natural, summary) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 40, reset: lastWeekDay)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(natural.quotaPointsRefilledUnused == 60)
    #expect(natural.refills == 1)
    #expect(summary.lastWeekLine == "Last week: OpenAI let 60 points refill unused.")
    #expect(summary.thisWeek.quotaPointsRefilledUnused == 0)

    // At 0% left the refill wastes nothing.
    let (empty, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: lastWeekDay)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(empty.quotaPointsRefilledUnused == 0)
    #expect(empty.refills == 1)

    // A provider-wide refill ahead of the reset counts what each account had left.
    let farReset = lastWeekDay.addingTimeInterval(3 * day)
    let (surprise, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 30, reset: farReset), "y": WasteAccount(used: 50, reset: farReset)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek), "y": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(surprise.quotaPointsRefilledUnused == 120)

    // Applying a banked reset early is not a refill.
    let (applied, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 30, reset: farReset, banked: banked(2, expiries: [nextWeek, nextWeek], at: before))]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek, banked: banked(1, expiries: [nextWeek], at: after))]),
    ])
    #expect(applied.quotaPointsRefilledUnused == 0)
    #expect(applied.refills == 0)
}

@Test func bankedResetsCountOnlyWhenTheyExpireUnused() throws {
    let before = lastWeekDay.addingTimeInterval(-5 * minute)
    let after = lastWeekDay.addingTimeInterval(5 * minute)
    let reset = lastWeekDay.addingTimeInterval(3 * day)
    let later = lastWeekDay.addingTimeInterval(10 * day)

    // One reset expired between the readings.
    let (expired, summary) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 20, reset: reset, banked: banked(2, expiries: [lastWeekDay, later], at: before))]),
        wasteReading(after, ["x": WasteAccount(used: 20, reset: reset, banked: banked(1, expiries: [later], at: after))]),
    ])
    #expect(expired.bankedResetsExpiredUnused == 1)
    #expect(summary.lastWeekLine == "Last week: OpenAI let nothing refill unused; 1 banked reset expired unused.")

    // One applied before its expiry was used, not wasted.
    let (applied, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 20, reset: reset, banked: banked(2, expiries: [later, later], at: before))]),
        wasteReading(after, ["x": WasteAccount(used: 20, reset: reset, banked: banked(1, expiries: [later], at: after))]),
    ])
    #expect(applied.bankedResetsExpiredUnused == 0)
}

@Test func usageCreditSpendingIsNeverUnused() throws {
    let before = lastWeekDay.addingTimeInterval(-5 * minute)
    let after = lastWeekDay.addingTimeInterval(5 * minute)
    let reset = lastWeekDay.addingTimeInterval(3 * day)
    func credits(_ balance: Double, expiresAt: Date? = nil) -> ProviderUsageCreditSummary {
        ProviderUsageCreditSummary(hasCredits: true, unlimited: false, balance: balance, expiresAt: expiresAt)
    }

    // Spending with no known expiry: nothing expired, and the balance left is reported with no expiry claim.
    let (spent, summary) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: reset, credits: credits(60_000)),
                              "y": WasteAccount(used: 10, reset: reset, credits: credits(50_000))]),
        wasteReading(after, ["x": WasteAccount(used: 100, reset: reset, credits: credits(57_000)),
                             "y": WasteAccount(used: 10, reset: reset, credits: credits(50_000))]),
    ])
    #expect(spent.usageCreditsExpiredUnused == nil)
    #expect(summary.usageCreditsLeft == 107_000)

    // With a known expiry, spending before it still wastes nothing; the balance gone at the expiry does.
    let (spentBeforeExpiry, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: reset, credits: credits(60_000, expiresAt: reset))]),
        wasteReading(after, ["x": WasteAccount(used: 100, reset: reset, credits: credits(57_000, expiresAt: reset))]),
    ])
    #expect(spentBeforeExpiry.usageCreditsExpiredUnused == 0)
    let (atExpiry, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: reset, credits: credits(57_000, expiresAt: lastWeekDay))]),
        wasteReading(after, ["x": WasteAccount(used: 100, reset: reset, credits: credits(0))]),
    ])
    #expect(atExpiry.usageCreditsExpiredUnused == 57_000)
}

@Test func agentSnapshotReadsLastWeeksUnusedCapacityFromSavedHistory() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let now = Date()
    let refill = UnusedCapacityHistory.weeks(now: now, calendar: .current).last.start.addingTimeInterval(2 * day)
    try AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")).save(AccountConfigurationDocument(
        updatedAt: now, accounts: [LocalProviderAccountConfiguration(id: "x", provider: .openAI, connectorKind: .codexRateLimits,
                                                                     displayName: "x", authPath: "/not/read/x")]))
    let store = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
    for reading in [
        wasteReading(refill.addingTimeInterval(-5 * minute), ["x": WasteAccount(used: 75, reset: refill)]),
        wasteReading(refill.addingTimeInterval(5 * minute), ["x": WasteAccount(used: 0, reset: refill.addingTimeInterval(7 * day))]),
        wasteReading(now, ["x": WasteAccount(used: 10, reset: refill.addingTimeInterval(7 * day))]),
    ] { try store.save(reading) }

    let snapshot = try AgentAccountSnapshot.read(rootDirectory: root, now: now)
    let unused = try #require(snapshot.providers.first { $0.provider == .openAI }?.unusedCapacity)
    #expect(unused.lastWeek.quotaPointsRefilledUnused == 25)
}
