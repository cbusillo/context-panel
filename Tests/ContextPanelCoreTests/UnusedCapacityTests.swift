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

    // A normal refill with 40% used lets 60 points refill unused at the reset.
    let (natural, summary) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 40, reset: lastWeekDay)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(natural.quotaPointsLeftAtReset == 60)
    #expect(natural.resetRefills == 1)
    #expect(natural.surpriseRefills == 0)
    #expect(summary.lastWeekLine == "Last week: OpenAI let 60 points refill unused at its normal reset.")
    #expect(summary.thisWeek.quotaPointsLeftAtReset == 0)

    // At 0% left the refill wastes nothing.
    let (empty, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: lastWeekDay)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(empty.quotaPointsLeftAtReset == 0)
    #expect(empty.resetRefills == 1)

    // A provider-wide refill ahead of the reset is counted on its own, as context rather than a missed reset.
    let farReset = lastWeekDay.addingTimeInterval(3 * day)
    let (surprise, surpriseSummary) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 30, reset: farReset), "y": WasteAccount(used: 50, reset: farReset)]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek), "y": WasteAccount(used: 0, reset: nextWeek)]),
    ])
    #expect(surprise.quotaPointsLeftAtSurpriseRefill == 120)
    #expect(surprise.surpriseRefills == 1)
    #expect(surprise.quotaPointsLeftAtReset == 0)
    #expect(surpriseSummary.lastWeekLine
        == "Last week: OpenAI let nothing refill unused at its normal reset; a surprise refill came with 120 points still left.")

    // Applying a banked reset early is not a refill.
    let (applied, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 30, reset: farReset, banked: banked(2, expiries: [nextWeek, nextWeek], at: before))]),
        wasteReading(after, ["x": WasteAccount(used: 0, reset: nextWeek, banked: banked(1, expiries: [nextWeek], at: after))]),
    ])
    #expect(applied.quotaPointsLeftAtReset == 0 && applied.quotaPointsLeftAtSurpriseRefill == 0)
    #expect(applied.resetRefills == 0 && applied.surpriseRefills == 0)
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
    #expect(summary.lastWeekLine == "Last week: OpenAI let nothing refill unused at its normal reset; 1 banked reset expired unused.")

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

    // Spending with no known expiry: nothing expired.
    let (spent, _) = try lastWeek([
        wasteReading(before, ["x": WasteAccount(used: 100, reset: reset, credits: credits(60_000)),
                              "y": WasteAccount(used: 10, reset: reset, credits: credits(50_000))]),
        wasteReading(after, ["x": WasteAccount(used: 100, reset: reset, credits: credits(57_000)),
                             "y": WasteAccount(used: 10, reset: reset, credits: credits(50_000))]),
    ])
    #expect(spent.usageCreditsExpiredUnused == nil)

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

@Test func theRefreshPassKeepsUnusedCapacityWithTheCurrentSnapshotForTheAgentSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    // Whole seconds, as saved JSON keeps them.
    let now = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    let refill = UnusedCapacityHistory.weeks(now: now, calendar: .current).last.start.addingTimeInterval(2 * day)
    let nextReset = refill.addingTimeInterval(7 * day)
    let accounts = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try accounts.save(AccountConfigurationDocument(updatedAt: now, accounts: [LocalProviderAccountConfiguration(
        id: "x", provider: .openAI, connectorKind: .codexRateLimits, displayName: "x", authPath: "/not/read/x")]))
    let store = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
    try store.save(wasteReading(refill.addingTimeInterval(-5 * minute), ["x": WasteAccount(used: 75, reset: refill)]))
    try store.save(wasteReading(refill.addingTimeInterval(5 * minute), ["x": WasteAccount(used: 0, reset: nextReset)]))
    let service = SnapshotRefreshService(accountStore: accounts, stores: SnapshotRefreshStores(primary: store),
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] })
    func refresh(at: Date) throws -> StoredUsageSnapshot? {
        let limit = UsageLimit(provider: .openAI, accountID: "x", configuredAccountID: "x", accountName: "x", label: "Codex Weekly",
            windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: 10, limit: 100, resetsAt: nextReset,
            lastUpdatedAt: at, confidence: .observed)
        return try service.saveMerged(refreshResult: ConnectorRefreshResult(generatedAt: at, reports: [ProviderConnectorReport(
            provider: .openAI, accountID: "x", configuredAccountID: "x", accountName: "x", generatedAt: at, limits: [limit])]),
            savedAt: at).storedSnapshot
    }

    // The refresh pass computes it and keeps it only with the current snapshot, not as a history reading.
    let first = try #require(try refresh(at: now)?.unusedCapacity)
    #expect(first.providers.first { $0.provider == .openAI }?.lastWeek.quotaPointsLeftAtReset == 25)
    #expect(store.loadCurrent().snapshot?.unusedCapacity == first)

    // A save within 30 minutes carries the same pass forward instead of reading history again; history files never keep it.
    #expect(try refresh(at: now.addingTimeInterval(5 * minute))?.unusedCapacity == first)
    #expect(store.loadHistory().allSatisfy { $0.unusedCapacity == nil })
    let later = now.addingTimeInterval(StoredUnusedCapacity.maximumAge + minute)
    #expect(try refresh(at: later)?.unusedCapacity?.computedAt == later)

    // The agent snapshot reads the kept value, and omits it once its week is over.
    let read = try AgentAccountSnapshot.read(rootDirectory: root, now: later)
    #expect(read.providers.first { $0.provider == .openAI }?.unusedCapacity?.lastWeek.quotaPointsLeftAtReset == 25)
    let nextWeek = try AgentAccountSnapshot.read(rootDirectory: root, now: later.addingTimeInterval(8 * day))
    #expect(nextWeek.providers.allSatisfy { $0.unusedCapacity == nil })
}

// Part 2: what will refill unused at the current pace, worded from the one pace forecast.

private func paceOverview(burn: Double?, used: [String: Int], credits: [String: Double] = [:],
                          observed: Date = wasteNow) -> (AccountOverview, StoredUsageSnapshot) {
    let names = used.keys.sorted()
    let limits = names.map { name in
        UsageLimit(provider: .openAI, accountID: name, configuredAccountID: name, accountName: name, label: "Codex Weekly",
                   windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: used[name]!, limit: 100,
                   resetsAt: wasteNow.addingTimeInterval(100 * 3_600), lastUpdatedAt: observed, confidence: .observed)
    }
    let reports = names.map { name in
        StoredProviderReport(provider: .openAI, accountID: name, configuredAccountID: name, accountName: name,
            generatedAt: observed, usageCredits: credits[name].map { ProviderUsageCreditSummary(hasCredits: true, unlimited: false, balance: $0) },
            status: .healthy, errorMessage: nil)
    }
    let stored = StoredUsageSnapshot(savedAt: observed, snapshot: UsageSnapshot(generatedAt: observed, limits: limits), reports: reports)
    let rates = Dictionary(uniqueKeysWithValues: zip(names, limits).map { name, limit in
        (name, burn.map { [limit.id: ObservedBurnRate(limitID: limit.id, unitsPerHour: $0, observedDurationHours: 6, sampleCount: 20)] } ?? [:])
    })
    let overview = AccountOverview(snapshot: stored.snapshot, reports: reports,
        metadata: names.map { AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, $0), configurationID: $0,
                                                     provider: .openAI, label: $0) },
        now: wasteNow, accountBurnRates: rates)
    return (overview, stored)
}

private func atPace(burn: Double?, used: [String: Int], credits: [String: Double] = [:]) throws -> ProviderUnusedAtPace {
    let (overview, stored) = paceOverview(burn: burn, used: used, credits: credits)
    return ProviderUnusedAtPace(forecast: try #require(overview.paceForecast(provider: .openAI)), stored: stored)
}

@Test func unusedAtPaceTellsTheSupervisorWhatWillRefillUnused() throws {
    // Heavy pace: 4 points an hour over 100 hours uses all 100 points left, so nothing is at risk.
    let heavy = try atPace(burn: 2, used: ["x": 50, "y": 50])
    #expect(heavy.runsOutBeforeRefill)
    #expect(heavy.refillsUnusedPoints < 0.5)
    #expect(heavy.line == "OpenAI: every point gets used before it refills at this pace.")

    // Slow pace: 0.2 points an hour uses 20 of 100, so the forecast's 80 points refill unused.
    let (overview, stored) = paceOverview(burn: 0.1, used: ["x": 50, "y": 50])
    let forecast = try #require(overview.paceForecast(provider: .openAI))
    let slow = ProviderUnusedAtPace(forecast: forecast, stored: stored)
    #expect(!slow.runsOutBeforeRefill)
    #expect(slow.refillsUnusedPoints == forecast.refillsUnused)
    #expect(abs(slow.refillsUnusedPoints - 80) < 0.001)
    #expect(slow.line == "OpenAI: about 80 points will refill unused at this pace. Add work.")

    // No measured pace: the points assume nothing more runs, and the line says the pace is unknown.
    let unmeasured = try atPace(burn: nil, used: ["x": 50, "y": 50])
    #expect(!unmeasured.paceMeasured)
    #expect(unmeasured.line == "OpenAI: pace isn't measured yet; about 100 points will refill unused if nothing more runs. Add work.")
}

@Test func unusedAtPaceSaysCreditsAreSpentOnlyAtZeroPercent() throws {
    let idle = try atPace(burn: 0.1, used: ["x": 50, "y": 60], credits: ["x": 60_000, "y": 50_000])
    #expect(idle.usageCreditsLeft == 110_000)
    #expect(idle.accountsSpendingUsageCredits == 0)
    #expect(idle.usageCreditsLine == "OpenAI has 110,000 usage credits left. They are not being spent: "
        + "credits are used only once an account's weekly quota reaches 0%.")

    let spending = try atPace(burn: 0.1, used: ["x": 100, "y": 60], credits: ["x": 57_000, "y": 50_000])
    #expect(spending.accountsSpendingUsageCredits == 1)
    #expect(spending.usageCreditsLine == "OpenAI has 107,000 usage credits left, being spent on 1 account at 0% of its weekly quota.")

    #expect(try atPace(burn: 0.1, used: ["x": 50]).usageCreditsLine == nil)
}

@Test func agentSnapshotCarriesUnusedAtPaceOnlyWithAForecast() throws {
    let configuration = AccountConfigurationDocument(updatedAt: wasteNow, accounts: [LocalProviderAccountConfiguration(
        id: "x", provider: .openAI, connectorKind: .codexRateLimits, displayName: "x", authPath: "/not/read/x")])
    let (_, current) = paceOverview(burn: nil, used: ["x": 40])
    let snapshot = AgentAccountSnapshot(configuration: configuration, stored: current, history: [], now: wasteNow)
    let provider = try #require(snapshot.providers.first { $0.provider == .openAI })
    #expect(provider.unusedAtPace?.refillsUnusedPoints == 60)
    let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
    #expect((json["unusedAtPace"] as? [String: Any])?["line"] is String)

    // A reading too old to be current gives no forecast, so the field is omitted.
    let (_, old) = paceOverview(burn: nil, used: ["x": 40], observed: wasteNow.addingTimeInterval(-3 * day))
    let stale = AgentAccountSnapshot(configuration: configuration, stored: old, history: [], now: wasteNow)
    #expect(stale.providers.contains { $0.provider == .openAI })
    #expect(stale.providers.allSatisfy { $0.unusedAtPace == nil })
}
