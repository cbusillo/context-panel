import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelSettingsUI

// Acceptance scenarios from #791: the revised spec with Chris's final amendments.

private let rankNow = Date(timeIntervalSince1970: 1_800_000_000)
private let hour: TimeInterval = 3_600

private struct Fixture {
    var name: String
    var provider: Provider = .openAI
    var weeklyUsed: Int? = 0
    /// Hours to the weekly reset; nil marks an unstarted OpenAI clock (reset a week after the reading).
    var resetHours: Double? = 100
    var burn: Double? = nil
    var useLast = false
    var isEnabled = true
    var showInWidgets = true
    var sourceConfigured = true
    var readState: AccountCapacityState? = nil
    var fiveHourUsed: Int? = nil
    var fiveHourResetHours: Double = 3
    var fiveHourBurn: Double? = nil
    var modelWindow: (label: String, used: Int)? = nil
    var bankedExpiryHours: [Double] = []
    var bankedCountOnly = false
    var unrecognizedResets = 0
    var observedAgo: TimeInterval = 0

    var family: String { provider == .openAI ? "Codex" : provider == .anthropic ? "Claude" : "Gemini" }
    var id: String { AccountDisplayMetadata.safeID(provider, name) }

    func limits(now: Date) -> [UsageLimit] {
        let observed = now.addingTimeInterval(-observedAgo)
        var limits = [UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
            label: "\(family) Weekly", windowLabel: "Weekly", modelLabel: family, unit: .percent, used: weeklyUsed, limit: 100,
            resetsAt: resetHours.map { now.addingTimeInterval($0 * hour) } ?? observed.addingTimeInterval(168 * hour),
            lastUpdatedAt: observed, confidence: .observed)]
        if let fiveHourUsed {
            limits.append(UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                label: "\(family) 5-hour", windowLabel: "5-hour", modelLabel: family, unit: .percent, used: fiveHourUsed,
                limit: 100, resetsAt: now.addingTimeInterval(fiveHourResetHours * hour), lastUpdatedAt: observed, confidence: .observed))
        }
        if let modelWindow {
            limits.append(UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                label: "\(modelWindow.label) Weekly", windowLabel: "Weekly", modelLabel: modelWindow.label, unit: .percent,
                used: modelWindow.used, limit: 100, resetsAt: now.addingTimeInterval(120 * hour), lastUpdatedAt: observed,
                confidence: .observed))
        }
        return limits
    }

    func report(now: Date) -> StoredProviderReport {
        let observed = now.addingTimeInterval(-observedAgo)
        let banked = bankedExpiryHours.isEmpty ? nil : ProviderResetCreditSummary(
            availableCount: bankedExpiryHours.count, observedAt: observed, coverage: bankedCountOnly ? .countOnly : .complete,
            knownExpiries: bankedExpiryHours.map { now.addingTimeInterval($0 * hour) }, unrecognizedKindCount: unrecognizedResets)
        return StoredProviderReport(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                                    generatedAt: observed, resetCredits: banked, status: .healthy, errorMessage: nil)
    }

    func rates(now: Date) -> [String: ObservedBurnRate] {
        var rates: [String: ObservedBurnRate] = [:]
        let limits = limits(now: now)
        if let burn { rates[limits[0].id] = ObservedBurnRate(limitID: limits[0].id, unitsPerHour: burn, observedDurationHours: 6, sampleCount: 20) }
        if let fiveHourBurn, fiveHourUsed != nil {
            rates[limits[1].id] = ObservedBurnRate(limitID: limits[1].id, unitsPerHour: fiveHourBurn, observedDurationHours: 2, sampleCount: 10)
        }
        return rates
    }
}

private func overview(_ fixtures: [Fixture], now: Date = rankNow, widgetsOnly: Bool = false) -> AccountOverview {
    AccountOverview(snapshot: UsageSnapshot(generatedAt: now, limits: fixtures.flatMap { $0.limits(now: now) }),
        reports: fixtures.map { $0.report(now: now) },
        metadata: fixtures.map { AccountDisplayMetadata(id: $0.id, configurationID: $0.id, provider: $0.provider,
                                                        label: $0.name, isEnabled: $0.isEnabled, showInWidgets: $0.showInWidgets,
                                                        useLast: $0.useLast, sourceConfigured: $0.sourceConfigured, readState: $0.readState) },
        now: now, widgetsOnly: widgetsOnly, accountBurnRates: Dictionary(uniqueKeysWithValues: fixtures.map { ($0.name, $0.rates(now: now)) }))
}

private func ranking(_ fixtures: [Fixture], provider: Provider = .openAI, evidence: UseNextEvidence = UseNextEvidence(),
                     now: Date = rankNow) -> UseNextRanking {
    overview(fixtures, now: now).useNextRanking(provider: provider, evidence: evidence)
}

private extension UseNextRanking {
    func entry(_ fixture: Fixture) -> Entry? { entries.first { $0.accountID == fixture.id } }
    func exclusion(_ fixture: Fixture) -> Exclusion? { excluded.first { $0.accountID == fixture.id } }
}

private let claudeICloud = Fixture(name: "claude-icloud", provider: .anthropic, weeklyUsed: 65, resetHours: 75, burn: 1.05,
                                   useLast: true, fiveHourUsed: 6, fiveHourResetHours: 4, fiveHourBurn: 5)
private let claudeInfo = Fixture(name: "claude-info", provider: .anthropic, weeklyUsed: 0, resetHours: 152, burn: 0, fiveHourUsed: 0)

// 1. Claude today: claude-info first; claude-icloud in Tier 2 only when its glide-path need is positive.
@Test func claudeTodayRanksTheUnusedAccountFirstAndHoldsUseLastToItsCushion() throws {
    let today = ranking([claudeICloud, claudeInfo], provider: .anthropic)
    #expect(today.useNextAccountID == claudeInfo.id)
    #expect(today.entry(claudeInfo)?.tier == .needsUse)
    // Its own burn projects past what is left, so the cushion takes it all.
    let held = try #require(today.entry(claudeICloud))
    #expect(held.tier == .onPace && held.weight == 0)

    var quiet = claudeICloud
    quiet.burn = 0.1
    let spare = ranking([quiet, claudeInfo], provider: .anthropic)
    #expect(spare.entry(quiet)?.tier == .useLast)
    #expect((spare.entry(quiet)?.need ?? 0) > 0)
    #expect(spare.useNextAccountID == claudeInfo.id)
}

// 2. Claude with claude-icloud not use-last: order follows need, not percent left.
@Test func rankingFollowsNeedRatherThanPercentLeft() {
    let soon = Fixture(name: "soon", provider: .anthropic, weeklyUsed: 60, resetHours: 10, burn: 0)
    let later = Fixture(name: "later", provider: .anthropic, weeklyUsed: 0, resetHours: 150, burn: 0)
    let result = ranking([later, soon], provider: .anthropic)
    #expect(result.entries.map(\.accountID) == [soon.id, later.id])
    #expect(result.useNextAccountID == soon.id)
}

// 3. OpenAI three accounts at today's numbers: ranked by need, with codex-info in Tier 2 per its glide path.
@Test func openAITodaySpendsUseLastAboveItsCushionWhileTheOthersAreOnPace() throws {
    let info = Fixture(name: "codex-info", weeklyUsed: 1, resetHours: 161, burn: 0.17, useLast: true)
    let icloud = Fixture(name: "codex-icloud", weeklyUsed: 8, resetHours: 148, burn: 0.83)
    let chris = Fixture(name: "codex-chris", weeklyUsed: 8, resetHours: 148, burn: 1.0)
    let result = ranking([chris, icloud, info])
    let infoEntry = try #require(result.entry(info))
    #expect(infoEntry.tier == .useLast)
    // The cushion is its own measured use until the window ends.
    #expect(abs((infoEntry.reserve ?? 0) - 0.17 * 161) < 0.5)
    #expect(result.entry(icloud)?.tier == .onPace)
    #expect(result.entry(chris)?.tier == .onPace)
    #expect(result.useNextAccountID == info.id)
}

// 4. An unstarted OpenAI account is first in Tier 1.
@Test func unstartedOpenAIAccountIsFirstWithADeadlineOfNow() throws {
    let started = Fixture(name: "started", weeklyUsed: 20, resetHours: 30, burn: 0.5)
    let idle = Fixture(name: "idle", weeklyUsed: 0, resetHours: nil, burn: 0)
    let result = ranking([started, idle])
    let first = try #require(result.entries.first)
    #expect(first.accountID == idle.id)
    #expect(first.unstarted && first.starter && first.tier == .needsUse)
    #expect(first.deadline == rankNow)
    #expect(result.useNextAccountID == idle.id)
    // The starter is one launch; after it the account shares by its need over a full week.
    #expect(Array(result.launchOrder.prefix(2)) == [idle.id, started.id])
}

// 5. An unstarted use-last account 1 hour after a refill gets one starter launch.
@Test func unstartedUseLastGetsOneStarterLaunchOnlyAfterAnHour() throws {
    let other = Fixture(name: "other", weeklyUsed: 30, resetHours: 50, burn: 0.2)
    let personal = Fixture(name: "personal", weeklyUsed: 0, resetHours: nil, burn: nil, useLast: true)
    let afterHour = ranking([other, personal], evidence: UseNextEvidence(unstartedSince: [personal.id: rankNow.addingTimeInterval(-hour)]))
    let starter = try #require(afterHour.entry(personal))
    #expect(starter.starter && starter.tier == .useLast)
    #expect(afterHour.launchOrder.filter { $0 == personal.id }.count >= 1)
    #expect(afterHour.launchOrder.first == personal.id)

    let early = ranking([other, personal], evidence: UseNextEvidence(unstartedSince: [personal.id: rankNow.addingTimeInterval(-hour / 2)]))
    #expect(early.entry(personal)?.starter == false)
    #expect(!early.launchOrder.contains(personal.id))
}

// 6. Batch of 7 with weights 0.6/0.3: D'Hondt splits 5/2, and a second batch continues with n carried over.
@Test func batchesSplitByDHondtAndReceiptsCarryOver() throws {
    let a = Fixture(name: "a", weeklyUsed: 40, resetHours: 100, burn: 0)
    let b = Fixture(name: "b", weeklyUsed: 70, resetHours: 100, burn: 0)
    let first = ranking([a, b])
    #expect(abs((first.entry(a)?.weight ?? 0) - 0.6) < 1e-9)
    #expect(abs((first.entry(b)?.weight ?? 0) - 0.3) < 1e-9)
    let batch = UseNextRanking.allocate(first.entries, launches: 7)
    #expect(batch.filter { $0 == a.id }.count == 5)
    #expect(batch.filter { $0 == b.id }.count == 2)

    // Ten minutes later the readings don't show those launches yet; their receipts carry the count.
    let launchedAt = rankNow.addingTimeInterval(-10 * 60)
    let receipts = batch.map { LaunchReceipt(provider: .openAI, accountID: $0, launchedAt: launchedAt) }
    let second = ranking([a, b], evidence: UseNextEvidence(receipts: receipts))
    #expect(second.entry(a)?.pendingLaunches == 5)
    let continued = UseNextRanking.allocate(first.entries, launches: 10)
    #expect(Array(second.launchOrder.prefix(3)) == Array(continued.suffix(3)))
}

@Test func receiptsStopCountingOnceTwoLaterReadingsOrHalfAnHourPass() {
    let a = Fixture(name: "a", weeklyUsed: 40, resetHours: 100, burn: 0)
    let receipt = LaunchReceipt(provider: .openAI, accountID: a.id, launchedAt: rankNow.addingTimeInterval(-10 * 60))
    let readings = [rankNow.addingTimeInterval(-6 * 60), rankNow.addingTimeInterval(-1 * 60)]
    #expect(ranking([a], evidence: UseNextEvidence(receipts: [receipt], readingTimes: readings)).entry(a)?.pendingLaunches == 0)
    let old = LaunchReceipt(provider: .openAI, accountID: a.id, launchedAt: rankNow.addingTimeInterval(-31 * 60))
    #expect(ranking([a], evidence: UseNextEvidence(receipts: [old])).entry(a)?.pendingLaunches == 0)
}

@Test func oneSavedReadingNeverRetiresAReceiptEvenWhenItsObservationTimeDiffers() {
    let a = Fixture(name: "a", weeklyUsed: 40, resetHours: 100, burn: 0)
    let receipt = LaunchReceipt(provider: .openAI, accountID: a.id, launchedAt: rankNow.addingTimeInterval(-10 * 60))
    // One refresh: the provider observation (now) and the save a little earlier are the same reading.
    let evidence = UseNextEvidence(receipts: [receipt], readingTimes: [rankNow.addingTimeInterval(-9 * 60)])
    #expect(ranking([a], evidence: evidence).entry(a)?.pendingLaunches == 1)
}

@Test func useNextIsAlwaysTheFirstLaunchOfABatch() {
    let ordinary = Fixture(name: "ordinary", weeklyUsed: 80, resetHours: 100, burn: 0)
    let personal = Fixture(name: "personal", weeklyUsed: 10, resetHours: 100, burn: 0, useLast: true)
    let result = ranking([ordinary, personal])
    // Use last's 87 spare points outweigh the other's 20, so it leads both a single launch and a batch.
    #expect(result.useNextAccountID == personal.id)
    #expect(result.launchOrder.first == result.useNextAccountID)
    #expect(result.entries.first?.accountID == result.useNextAccountID)
    #expect(result.launchOrder.contains(ordinary.id))
}

@Test func soleUnstartedUseLastWaitsOutItsGraceHour() {
    let personal = Fixture(name: "personal", weeklyUsed: 0, resetHours: nil, burn: nil, useLast: true)
    let result = ranking([personal], evidence: UseNextEvidence(unstartedSince: [personal.id: rankNow.addingTimeInterval(-5 * 60)]))
    #expect(result.useNextAccountID == nil)
    #expect(result.launchOrder.isEmpty)
}

// 7. Two accounts marked use-last: configuration error; use-last is ignored.
@Test func twoUseLastAccountsAreAConfigurationErrorAndUseLastIsIgnored() {
    let first = Fixture(name: "first", weeklyUsed: 10, resetHours: 100, burn: 0, useLast: true)
    let second = Fixture(name: "second", weeklyUsed: 20, resetHours: 100, burn: 0, useLast: true)
    let accounts = overview([first, second])
    #expect(accounts.configurationErrors == ["multipleUseLast:openai"])
    let result = accounts.useNextRanking(provider: .openAI)
    #expect(result.multipleUseLast)
    #expect(result.entries.allSatisfy { $0.tier == .needsUse && $0.reserve == nil })
}

// 8. Marking a second use-last account moves the mark, with a notice.
@Test func markingASecondUseLastAccountMovesTheMark() {
    var accounts = [
        LocalProviderAccountConfiguration(id: "a", provider: .openAI, connectorKind: .codexRateLimits, displayName: "A", useLast: true),
        LocalProviderAccountConfiguration(id: "b", provider: .openAI, connectorKind: .codexRateLimits, displayName: "B"),
        LocalProviderAccountConfiguration(id: "c", provider: .anthropic, connectorKind: .claudeOAuthUsage, displayName: "C", useLast: true),
    ]
    let notice = accounts.setUseLast("b", true)
    #expect(accounts.map { $0.useLast == true } == [false, true, true])
    #expect(notice?.contains("A") == true && notice?.contains("B") == true)
    #expect(accounts.setUseLast("b", false) == nil)
    #expect(accounts.map { $0.useLast == true } == [false, false, true])
}

// 9. Claude at 4 points left on its 5-hour window: excluded until its 5-hour reset.
@Test func claudeFiveHourGateExcludesUntilTheFiveHourReset() throws {
    let blocked = Fixture(name: "blocked", provider: .anthropic, weeklyUsed: 10, resetHours: 100, burn: 1,
                          fiveHourUsed: 96, fiveHourResetHours: 2)
    let result = ranking([blocked], provider: .anthropic)
    let exclusion = try #require(result.exclusion(blocked))
    #expect(exclusion.until == rankNow.addingTimeInterval(2 * hour))
    #expect(result.useNextAccountID == nil)
    #expect(result.nextCapacityAt == rankNow.addingTimeInterval(2 * hour))

    // Also gated when its 5-hour burn would use the rest before that window resets.
    let pressed = Fixture(name: "pressed", provider: .anthropic, weeklyUsed: 10, resetHours: 100, burn: 1,
                          fiveHourUsed: 50, fiveHourResetHours: 3, fiveHourBurn: 20)
    #expect(ranking([pressed], provider: .anthropic).exclusion(pressed) != nil)
}

// 10. All accounts stale: last list with its age; the launcher uses or refuses under the 30-minute rule.
@Test func staleListIsPublishedWithItsAgeAndSteersLaunchesOnlyWhileYoung() throws {
    let young = Fixture(name: "young", weeklyUsed: 30, resetHours: 50, burn: 0.1, observedAgo: 20 * 60)
    let fresh = ranking([young])
    #expect(fresh.basedOnStaleReadings)
    #expect(fresh.readingsObservedAt == rankNow.addingTimeInterval(-20 * 60))
    #expect(fresh.useNextAccountID == nil)
    #expect(fresh.launchOrder.first == young.id)

    var old = young
    old.observedAgo = 40 * 60
    let aged = ranking([old])
    #expect(aged.basedOnStaleReadings && !aged.entries.isEmpty)
    #expect(aged.launchOrder.isEmpty)
}

// 11. Provider-wide refill: recorded and excluded from burn.
@Test func providerWideRefillIsDetectedAndNeverCountsAsBurn() throws {
    func reading(_ at: Date, used: [Int], reset: Date, banked: Int = 2) -> StoredUsageSnapshot {
        let names = ["x", "y"]
        let limits = zip(names, used).map { name, used in
            UsageLimit(provider: .openAI, accountID: name, configuredAccountID: name, accountName: name, label: "Codex Weekly",
                       windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: used, limit: 100, resetsAt: reset,
                       lastUpdatedAt: at, confidence: .observed)
        }
        let reports = names.map { StoredProviderReport(provider: .openAI, accountID: $0, configuredAccountID: $0, accountName: $0,
            generatedAt: at, resetCredits: ProviderResetCreditSummary(availableCount: banked, observedAt: at, coverage: .countOnly),
            status: .healthy, errorMessage: nil) }
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: limits), reports: reports)
    }
    let oldReset = rankNow.addingTimeInterval(72 * hour)
    let newReset = rankNow.addingTimeInterval(167 * hour)
    let readings = [
        reading(rankNow.addingTimeInterval(-2 * hour), used: [40, 50], reset: oldReset),
        reading(rankNow.addingTimeInterval(-1 * hour), used: [45, 55], reset: oldReset),
        reading(rankNow.addingTimeInterval(-0.5 * hour), used: [0, 0], reset: newReset),
        reading(rankNow, used: [2, 2], reset: newReset),
    ]
    let events = ProviderRefillDetector.events(readings: readings)
    #expect(events.count == 1)
    #expect(events.first?.detectedAt == rankNow.addingTimeInterval(-0.5 * hour))
    #expect(Set(events.first?.accountIDs ?? []) == Set(["x", "y"].map { AccountDisplayMetadata.safeID(.openAI, $0) }))

    // A banked reset spent on the accounts is not a provider-wide refill.
    var spent = readings
    spent[2] = reading(rankNow.addingTimeInterval(-0.5 * hour), used: [0, 0], reset: newReset, banked: 1)
    #expect(ProviderRefillDetector.events(readings: spent).isEmpty)

    // A third account that carries on as usual doesn't hide the other two refilling.
    var mixed = readings
    for index in [1, 2] {
        var limits = mixed[index].snapshot.limits
        limits.append(UsageLimit(provider: .openAI, accountID: "z", configuredAccountID: "z", accountName: "z", label: "Codex Weekly",
                                 windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: 20 + index, limit: 100,
                                 resetsAt: oldReset, lastUpdatedAt: mixed[index].savedAt, confidence: .observed))
        mixed[index] = StoredUsageSnapshot(savedAt: mixed[index].savedAt,
            snapshot: UsageSnapshot(generatedAt: mixed[index].savedAt, limits: limits), reports: mixed[index].reports)
    }
    #expect(ProviderRefillDetector.events(readings: mixed).first?.accountIDs.count == 2)

    // Two logins that publish as one account are one account, not a provider-wide refill.
    #expect(ProviderRefillDetector.events(readings: readings, resolve: { _ in "openai-0" }).isEmpty)

    // Burn across the refill counts only real use: 5 points an hour before, 4 an hour after.
    let rates = MainLimitBurnRateEstimator.observedBurnRates(current: readings[3].snapshot, history: readings, now: rankNow,
                                                             minimumObservation: 0, minimumUsableIntervals: 1)
    let weekly = try #require(rates.values.first)
    #expect(weekly.unitsPerHour < 20)
}

// 12–15. OpenAI reset prompts: one plain line only when clearly worth it; value and reasoning in the detail view.
@Test func openAIResetPromptsAppearOnlyWhenClearlyWorthIt() throws {
    func assessment(_ fixture: Fixture) throws -> ResetAssessment {
        try #require(overview([fixture]).accounts.first?.resetAssessment)
    }
    let emptyEarly = try assessment(Fixture(name: "empty", weeklyUsed: 100, resetHours: 4.7 * 24, bankedExpiryHours: [200]))
    #expect(emptyEarly.trigger == .outOfQuota)
    #expect(abs((emptyEarly.value ?? 0) - 67.1) < 0.2)
    #expect(emptyEarly.prompt?.contains("empty") == true)

    let emptyLate = try assessment(Fixture(name: "late", weeklyUsed: 100, resetHours: 0.3 * 24, bankedExpiryHours: [200]))
    #expect(abs((emptyLate.value ?? 0) - 4.3) < 0.2)
    #expect(emptyLate.prompt == nil && !emptyLate.detail.isEmpty)

    let expiring = try assessment(Fixture(name: "expiring", weeklyUsed: 30, resetHours: 5.7 * 24, bankedExpiryHours: [20, 200]))
    #expect(expiring.trigger == .expiring)
    #expect(abs((expiring.value ?? 0) - 11.4) < 0.2)
    #expect(expiring.prompt != nil && expiring.eligibilityNote != nil)

    let lapsing = try assessment(Fixture(name: "lapsing", weeklyUsed: 30, resetHours: 0.6 * 24, bankedExpiryHours: [20]))
    #expect(abs((lapsing.value ?? 0) + 61.4) < 0.2)
    #expect(lapsing.prompt == nil)
}

// 16 (amended by Q64). Claude resets are full weekly refills; a grant of another kind is flagged, not valued.
@Test func claudeGrantOfAnotherKindIsFlaggedInsteadOfValued() throws {
    func grants(_ clears: String) -> Data {
        Data("""
        {"cedar_ember":{"eligible":true,"grants":[{"id":"g1","resets_total":1,"resets_left":1,
        "ends_at":"2026-10-22T16:00:00Z","clears":[\(clears)]}]}}
        """.utf8)
    }
    let observed = ISO8601DateFormatter().date(from: "2026-10-08T00:00:00Z")!
    #expect(ClaudeResetCreditParser.summary(from: grants("\"seven_day\",\"five_hour\""), observedAt: observed)?.unrecognizedKindCount == 0)
    #expect(ClaudeResetCreditParser.summary(from: grants(""), observedAt: observed)?.unrecognizedKindCount == 0)
    #expect(ClaudeResetCreditParser.summary(from: grants("\"five_hour\""), observedAt: observed)?.unrecognizedKindCount == 1)
    // A model's weekly window alone is not the general weekly refill.
    #expect(ClaudeResetCreditParser.summary(from: grants("\"seven_day_opus\""), observedAt: observed)?.unrecognizedKindCount == 1)

    let flagged = Fixture(name: "flagged", provider: .anthropic, weeklyUsed: 100, resetHours: 100, bankedExpiryHours: [200],
                          unrecognizedResets: 1)
    let assessment = try #require(overview([flagged]).accounts.first?.resetAssessment)
    #expect(assessment.unrecognizedKind && assessment.value == nil && assessment.prompt == nil)
}

// Claude reset value: what the account can still spend before its fixed refill.
@Test func claudeExpiringResetIsValuedByWhatCanStillBeSpent() throws {
    let hours = 93 / ResetAssessment.claudeDefaultRate
    let account = Fixture(name: "claude", provider: .anthropic, weeklyUsed: 30, resetHours: hours, bankedExpiryHours: [10])
    let assessment = try #require(overview([account]).accounts.first?.resetAssessment)
    #expect(assessment.trigger == .expiring)
    #expect(abs((assessment.value ?? 0) - 23) < 0.2)
    #expect(assessment.prompt != nil)
}

// 17. gpt-reserve at 0 while the Codex window is at 50%: the account stays ranked, gated only for that model.
@Test func emptyModelWindowLeavesTheAccountRanked() throws {
    let account = Fixture(name: "reserve", weeklyUsed: 50, resetHours: 100, burn: 0.1, modelWindow: ("gpt-reserve", 100))
    let result = ranking([account])
    let entry = try #require(result.entry(account))
    #expect(entry.remaining == 50)
    #expect(entry.notes.count == 1 && entry.notes[0].contains("gpt-reserve"))
    #expect(result.useNextAccountID == account.id)
}

// 18. Unknown expiry: no trigger B.
@Test func unknownExpiryNeverTriggersTheExpiringPrompt() throws {
    let account = Fixture(name: "unknown", weeklyUsed: 30, resetHours: 100, bankedExpiryHours: [10], bankedCountOnly: true)
    let assessment = try #require(overview([account]).accounts.first?.resetAssessment)
    #expect(assessment.trigger == .notNeeded && assessment.prompt == nil)
}

// 19. Nothing rankable: Use next "none", with the next capacity time.
@Test func nothingRankablePublishesTheNextCapacityTime() {
    let first = Fixture(name: "first", weeklyUsed: 100, resetHours: 30)
    let second = Fixture(name: "second", weeklyUsed: 100, resetHours: 10)
    let result = ranking([first, second])
    #expect(result.useNextAccountID == nil && result.entries.isEmpty)
    #expect(result.nextCapacityAt == rankNow.addingTimeInterval(10 * hour))
}

// Demand at or above capacity: last longest first, use-last only after the rest.
@Test func whenEveryAccountIsShortUseLastComesLast() throws {
    let fast = Fixture(name: "fast", weeklyUsed: 50, resetHours: 100, burn: 2)
    let slow = Fixture(name: "slow", weeklyUsed: 50, resetHours: 100, burn: 1)
    // Its own burn is unmeasured, so the cushion is the floor and the provider average stands in for burn.
    let personal = Fixture(name: "personal", weeklyUsed: 20, resetHours: 100, burn: nil, useLast: true)
    let result = ranking([fast, personal, slow])
    #expect(result.entries.allSatisfy { $0.tier == .onPace })
    #expect(result.entries.map(\.accountID) == [slow.id, fast.id, personal.id])
    #expect(result.useNextAccountID == slow.id)
    #expect(!result.launchOrder.contains(personal.id))
}

// Amendment Q61: the use-last cushion is the Director's own measured use, with a 3-point floor.
@Test func useLastCushionIsMeasuredPersonalUseWithAFloor() throws {
    let agentOnly = Fixture(name: "agents", weeklyUsed: 10, resetHours: 100, burn: 1)
    let personal = Fixture(name: "personal", weeklyUsed: 10, resetHours: 100, burn: 0.6, useLast: true)
    // No receipts: all of its burn is personal.
    #expect(abs((ranking([agentOnly, personal]).entry(personal)?.reserve ?? 0) - 60) < 0.01)

    // Receipts: the other account measures 24 points per launch, which explains all of this account's burn.
    let receipts = [agentOnly, personal].map { LaunchReceipt(provider: .openAI, accountID: $0.id, launchedAt: rankNow.addingTimeInterval(-hour)) }
    let attributed = ranking([agentOnly, personal], evidence: UseNextEvidence(receipts: receipts, readingTimes: [rankNow]))
    // 0.6 observed − 1 launch × 24 points ÷ 24 hours = 0 personal: the floor applies.
    #expect(attributed.entry(personal)?.reserve == UseNextRanking.useLastFloor)

    // Near the end of the window the cushion shrinks to the floor, so it lands near zero.
    let ending = Fixture(name: "ending", weeklyUsed: 80, resetHours: 2, burn: 0.6, useLast: true)
    #expect(ranking([agentOnly, ending]).entry(ending)?.reserve == UseNextRanking.useLastFloor)
}

@Test func launchReceiptStoreReadsOnlyWellFormedRecentReceipts() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let id = AccountDisplayMetadata.safeID(.openAI, "a")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(LaunchReceipt(provider: .openAI, accountID: id, launchedAt: rankNow.addingTimeInterval(-60)))
        .write(to: directory.appending(path: "recent.json"))
    try encoder.encode(LaunchReceipt(provider: .openAI, accountID: id, launchedAt: rankNow.addingTimeInterval(-2 * LaunchReceiptStore.lookback)))
        .write(to: directory.appending(path: "old.json"))
    try encoder.encode(LaunchReceipt(provider: .anthropic, accountID: id, launchedAt: rankNow))
        .write(to: directory.appending(path: "wrong-provider.json"))
    try Data("not json".utf8).write(to: directory.appending(path: "broken.json"))
    let loaded = LaunchReceiptStore.load(rootDirectory: root, now: rankNow)
    #expect(loaded == [LaunchReceipt(provider: .openAI, accountID: id, launchedAt: rankNow.addingTimeInterval(-60))])
    #expect(LaunchReceiptStore.load(rootDirectory: root.appending(path: "missing"), now: rankNow).isEmpty)
}

@Test func agentSnapshotPublishesTheRankingAndAnswersWithItsFirstEntry() throws {
    let a = Fixture(name: "a", weeklyUsed: 40, resetHours: 100, burn: 0)
    let b = Fixture(name: "b", weeklyUsed: 100, resetHours: 100, bankedExpiryHours: [200])
    let configuration = AccountConfigurationDocument(updatedAt: rankNow, accounts: [a, b].map {
        LocalProviderAccountConfiguration(id: $0.name, provider: .openAI, connectorKind: .codexRateLimits, displayName: $0.name,
                                          authPath: "/not/read/\($0.name)")
    })
    let stored = StoredUsageSnapshot(savedAt: rankNow,
        snapshot: UsageSnapshot(generatedAt: rankNow, limits: [a, b].flatMap { $0.limits(now: rankNow) }),
        reports: [a, b].map { $0.report(now: rankNow) })
    let receipt = LaunchReceipt(provider: .openAI, accountID: a.id, launchedAt: rankNow.addingTimeInterval(-60))
    let snapshot = AgentAccountSnapshot(configuration: configuration, stored: stored, history: [], now: rankNow, receipts: [receipt])
    let openAI = try #require(snapshot.ranking.first { $0.provider == .openAI })
    #expect(snapshot.answers.useNext.first?.accountID == openAI.useNextAccountID)
    #expect(openAI.entries.first?.pendingLaunches == 1)
    #expect(snapshot.resetPrompts.isEmpty)
    #expect(snapshot.configurationErrors.isEmpty)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let json = try #require(try JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
    #expect(json["ranking"] is [Any] && json["resetPrompts"] is [Any] && json["providerRefills"] is [Any])
}

// #794: an empty account alone is not a reason to apply a provider's reset.
@Test(arguments: [Provider.openAI, .anthropic])
func resetWaitsForEveryProviderAccountIncludingUseLast(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let personal = Fixture(name: "personal", provider: provider, weeklyUsed: 99, useLast: true)
    let result = overview([empty, personal])
    let assessment = try #require(result.accounts.first { $0.id == empty.id }?.resetAssessment)
    #expect(assessment.trigger == .notNeeded)
    #expect(assessment.prompt == nil)
}

@Test(arguments: [Provider.openAI, .anthropic])
func emptyProviderPromptsForOneSoonestExpiringWorthwhileReset(_ provider: Provider) throws {
    let later = Fixture(name: "later", provider: provider, weeklyUsed: 100, bankedExpiryHours: [300])
    let soon = Fixture(name: "soon", provider: provider, weeklyUsed: 100, useLast: true, bankedExpiryHours: [200, 400])
    let noReset = Fixture(name: "no-reset", provider: provider, weeklyUsed: 100)
    let otherProvider = Fixture(name: "other", provider: provider == .openAI ? .anthropic : .openAI)
    for fixtures in [[later, soon, noReset, otherProvider], [soon, later, noReset, otherProvider]] {
        let result = overview(fixtures)
        let prompts = result.accounts.compactMap(\.resetAssessment).filter(\.recommended)
        #expect(prompts.map(\.accountID) == [soon.id])
        #expect(prompts.first?.trigger == .outOfQuota)
        #expect(prompts.first?.expiresAt == rankNow.addingTimeInterval(200 * hour))
        #expect(result.accounts.first { $0.id == soon.id }?.bankedAdvice?.title == prompts.first?.title)
    }
}

@Test(arguments: [Provider.openAI, .anthropic])
func expiringResetStillPromptsWhileAnotherAccountHasQuota(_ provider: Provider) throws {
    let expiryBoundary = ResetAssessment.expiringWithin / hour
    for hoursLeft in [expiryBoundary - 4, expiryBoundary, expiryBoundary + 0.01] {
        let expiring = Fixture(name: "expiring", provider: provider, weeklyUsed: 60, bankedExpiryHours: [hoursLeft])
        let usable = Fixture(name: "usable", provider: provider, weeklyUsed: 0)
        let result = overview([expiring, usable])
        let assessment = try #require(result.accounts.first { $0.id == expiring.id }?.resetAssessment)
        #expect(assessment.trigger == (hoursLeft <= expiryBoundary ? .expiring : .notNeeded))
        #expect(assessment.recommended == (hoursLeft <= expiryBoundary))
    }
    // The expiry prompt also remains when the expiring account itself is empty.
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [20])
    let usable = Fixture(name: "usable", provider: provider, weeklyUsed: 0)
    let assessment = try #require(overview([empty, usable]).accounts.first?.resetAssessment)
    #expect(assessment.trigger == .expiring && assessment.recommended)
}

@Test(arguments: [Provider.openAI, .anthropic])
func hiddenAccountQuotaStillHoldsWidgetResetPrompt(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let hidden = Fixture(name: "hidden", provider: provider, weeklyUsed: 50, useLast: true, showInWidgets: false)
    let result = overview([empty, hidden], widgetsOnly: true)
    #expect(result.accounts.map(\.id) == [empty.id])
    #expect(result.accounts.first?.resetAssessment?.prompt == nil)
}

@Test(arguments: [Provider.openAI, .anthropic])
func disabledAndUnconfiguredAccountsDoNotHoldResetPrompt(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let disabled = Fixture(name: "disabled", provider: provider, isEnabled: false)
    let unconfigured = Fixture(name: "unconfigured", provider: provider, sourceConfigured: false)
    let assessment = try #require(overview([empty, disabled, unconfigured]).accounts.first?.resetAssessment)
    #expect(assessment.trigger == .outOfQuota && assessment.recommended)
}

@Test(arguments: [Provider.openAI, .anthropic])
func unknownOrStaleQuotaDoesNotProveProviderEmpty(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let unknown = Fixture(name: "unknown", provider: provider, weeklyUsed: nil)
    let stale = Fixture(name: "stale", provider: provider, weeklyUsed: 100, observedAgo: 3_600)
    for sibling in [unknown, stale] {
        let assessment = try #require(overview([empty, sibling]).accounts.first?.resetAssessment)
        #expect(assessment.trigger == .notNeeded && assessment.prompt == nil)
    }
}

@Test(arguments: [Provider.openAI, .anthropic])
func soonestResetThatIsNotWorthApplyingDoesNotHideWorthwhileReset(_ provider: Provider) throws {
    let lowValue = Fixture(name: "low-value", provider: provider, weeklyUsed: 100, resetHours: 1, bankedExpiryHours: [100])
    let worthwhile = Fixture(name: "worthwhile", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let assessments = overview([lowValue, worthwhile]).accounts.compactMap(\.resetAssessment)
    #expect(assessments.filter(\.recommended).map(\.accountID) == [worthwhile.id])
}

@Test(arguments: [Provider.openAI, .anthropic])
func agentSnapshotAndPanelShareProviderResetPrompts(_ provider: Provider) throws {
    let first = Fixture(name: "first", provider: provider, weeklyUsed: 100, bankedExpiryHours: [300])
    let second = Fixture(name: "second", provider: provider, weeklyUsed: 100, useLast: true, bankedExpiryHours: [200])
    for secondUsed in [100, 99] {
        var sibling = second
        sibling.weeklyUsed = secondUsed
        let fixtures = [first, sibling]
        let configuration = AccountConfigurationDocument(updatedAt: rankNow, accounts: fixtures.map {
            LocalProviderAccountConfiguration(id: $0.name, provider: provider,
                connectorKind: provider == .openAI ? .codexRateLimits : .claudeOAuthUsage, displayName: $0.name,
                authPath: "/not/read/\($0.name)", useLast: $0.useLast)
        })
        let stored = StoredUsageSnapshot(savedAt: rankNow,
            snapshot: UsageSnapshot(generatedAt: rankNow, limits: fixtures.flatMap { $0.limits(now: rankNow) }),
            reports: fixtures.map { $0.report(now: rankNow) })
        let snapshot = AgentAccountSnapshot(configuration: configuration, stored: stored, history: [], now: rankNow)
        let panelPrompts = overview(fixtures).accounts.compactMap(\.resetAssessment).filter(\.recommended)
        #expect(snapshot.resetPrompts.map(\.accountID) == panelPrompts.map(\.accountID))
        #expect(snapshot.resetPrompts.map(\.line) == panelPrompts.compactMap(\.prompt))
        #expect(snapshot.resetPrompts.map(\.accountID) == (secondUsed == 100 ? [second.id] : []))
    }
}

@Test(arguments: [Provider.openAI, .anthropic])
func disconnectedAccountCannotHoldProviderResetPrompt(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let disconnected = Fixture(name: "disconnected", provider: provider, readState: .notConnected)
    let result = overview([empty, disconnected])
    #expect(result.accounts.first { $0.id == disconnected.id }?.state == .notConnected)
    let assessment = try #require(result.accounts.first { $0.id == empty.id }?.resetAssessment)
    #expect(assessment.trigger == .outOfQuota && assessment.recommended)
}

@Test(arguments: [Provider.openAI, .anthropic])
func failedReadCannotProveProviderEmpty(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let failed = Fixture(name: "failed", provider: provider, weeklyUsed: 100, readState: .unavailable)
    let assessment = try #require(overview([empty, failed]).accounts.first?.resetAssessment)
    #expect(assessment.trigger == .notNeeded && !assessment.recommended)
}

@Test(arguments: [Provider.openAI, .anthropic])
func emptyProviderWithTwoExpiringResetsStillOffersOne(_ provider: Provider) throws {
    let soon = Fixture(name: "soon", provider: provider, weeklyUsed: 100, bankedExpiryHours: [6])
    let later = Fixture(name: "later", provider: provider, weeklyUsed: 100, bankedExpiryHours: [12])
    let result = overview([later, soon])
    #expect(result.accounts.compactMap(\.resetAssessment).filter(\.recommended).map(\.accountID) == [soon.id])
    let held = try #require(result.accounts.first { $0.id == later.id }?.resetAssessment)
    #expect(held.prompt == nil && held.value != nil)
    #expect(held.detail.contains(soon.name))
    #expect(result.accounts.first { $0.id == later.id }?.bankedAdvice?.title == held.title)
}

@Test(arguments: [Provider.openAI, .anthropic])
func knownResetExpiryPrecedesUnknownExpiry(_ provider: Provider) {
    let known = Fixture(name: "known", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let unknown = Fixture(name: "unknown", provider: provider, weeklyUsed: 100, bankedExpiryHours: [10], bankedCountOnly: true)
    for fixtures in [[unknown, known], [known, unknown]] {
        let assessments = overview(fixtures).accounts.compactMap(\.resetAssessment)
        #expect(assessments.first { $0.accountID == unknown.id }?.expiresAt == nil)
        #expect(assessments.filter(\.recommended).map(\.accountID) == [known.id])
    }
}

@Test(arguments: [Provider.openAI, .anthropic])
@MainActor func resetDeadlineDetailsUseCompleteProviderAdvice(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    let personal = Fixture(name: "personal", provider: provider, weeklyUsed: 50, useLast: true)
    let later = Fixture(name: "later", provider: provider, weeklyUsed: 100, bankedExpiryHours: [300])
    for fixtures in [[empty, personal], [empty, later]] {
        let panel = overview(fixtures)
        let adviceByAccountID = Dictionary(fixtures.compactMap { fixture in
            panel.accounts.first { $0.id == fixture.id }?.bankedAdvice.map { (fixture.name, $0) }
        }, uniquingKeysWith: { first, _ in first })
        for fixture in fixtures {
            let report = fixture.report(now: rankNow)
            let deadlines = BankedResetDeadlinesView(reports: [report], limits: fixture.limits(now: rankNow),
                presentationDate: rankNow, adviceByAccountID: adviceByAccountID)
            let expected = panel.accounts.first { $0.id == fixture.id }?.bankedAdvice
            #expect(deadlines.advice(for: report, now: rankNow)?.title == expected?.title)
            #expect(deadlines.advice(for: report, now: rankNow)?.detail == expected?.detail)
        }
    }
}
