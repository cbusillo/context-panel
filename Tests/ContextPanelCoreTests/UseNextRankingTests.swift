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
    var signInExpired = false
    var fiveHourUsed: Int? = nil
    var fiveHourResetHours: Double = 3
    var fiveHourBurn: Double? = nil
    var modelWindow: (label: String, used: Int)? = nil
    var modelResetHours: Double = 120
    var bankedExpiryHours: [Double] = []
    var bankedCountOnly = false
    var unrecognizedResets = 0
    var observedAgo: TimeInterval = 0
    /// Readings arrive only when the provider is used, as with AGY's callback.
    var eventDriven = false
    /// OpenAI says usage credits keep the account working past its used-up plan quota.
    var onCredits = false

    var family: String { provider == .openAI ? "Codex" : provider == .anthropic ? "Claude" : "Gemini" }
    var id: String { AccountDisplayMetadata.safeID(provider, name) }

    func limits(now: Date) -> [UsageLimit] {
        let observed = now.addingTimeInterval(-observedAgo)
        var limits = [UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
            label: "\(family) Weekly", windowLabel: "Weekly", modelLabel: family, unit: .percent, used: weeklyUsed, limit: 100,
            resetsAt: resetHours.map { now.addingTimeInterval($0 * hour) } ?? observed.addingTimeInterval(168 * hour),
            lastUpdatedAt: observed, confidence: .observed, freshnessMode: eventDriven ? .eventDriven : nil)]
        if let fiveHourUsed {
            limits.append(UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                label: "\(family) 5-hour", windowLabel: "5-hour", modelLabel: family, unit: .percent, used: fiveHourUsed,
                limit: 100, resetsAt: now.addingTimeInterval(fiveHourResetHours * hour), lastUpdatedAt: observed, confidence: .observed))
        }
        if let modelWindow {
            limits.append(UsageLimit(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                label: "\(modelWindow.label) Weekly", windowLabel: "Weekly", modelLabel: modelWindow.label, unit: .percent,
                used: modelWindow.used, limit: 100, resetsAt: now.addingTimeInterval(modelResetHours * hour), lastUpdatedAt: observed,
                confidence: .observed))
        }
        return limits
    }

    func report(now: Date) -> StoredProviderReport {
        let observed = now.addingTimeInterval(-observedAgo)
        let banked = bankedExpiryHours.isEmpty ? nil : ProviderResetCreditSummary(
            availableCount: bankedExpiryHours.count, observedAt: observed, coverage: bankedCountOnly ? .countOnly : .complete,
            knownExpiries: bankedExpiryHours.map { now.addingTimeInterval($0 * hour) }, unrecognizedKindCount: unrecognizedResets, generalWeeklyOnly: unrecognizedResets == 0)
        return StoredProviderReport(provider: provider, accountID: name, configuredAccountID: name, accountName: name,
                                    generatedAt: observed, resetCredits: banked, status: signInExpired ? .failure : .healthy,
                                    accessState: signInExpired ? ProviderAccessState(kind: .signInExpired)
                                        : onCredits ? ProviderAccessState(kind: .paidFallbackActive) : .unknown, errorMessage: nil)
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

@Test func codexExpiredSignInNeverInventsLaunchCapacity() {
    let rows = [
        Fixture(name: "unknown", weeklyUsed: nil, signInExpired: true),
        Fixture(name: "exhausted", weeklyUsed: 100, signInExpired: true),
        Fixture(name: "paused", isEnabled: false, signInExpired: true),
        Fixture(name: "missing", sourceConfigured: false, signInExpired: true),
        Fixture(name: "short-exhausted", signInExpired: true, fiveHourUsed: 100),
    ]
    #expect(ranking(rows).entries.isEmpty)
    #expect(ranking(rows).launchOrder.isEmpty)
}

@Test func expiredCodexReadingPreservesOnlyRecentOrdinaryStaleSiblings() {
    let expired = Fixture(name: "expired", weeklyUsed: 20, signInExpired: true, observedAgo: 7_200)
    let recent = Fixture(name: "recent", weeklyUsed: 20, resetHours: 1,
                         observedAgo: UseNextRanking.staleListMaximumAge - 60)
    let old = Fixture(name: "old", weeklyUsed: 20, resetHours: 1,
                      observedAgo: UseNextRanking.staleListMaximumAge + 60)
    let result = ranking([expired, recent, old])
    #expect(result.entry(expired) != nil)
    #expect(result.entry(recent) != nil)
    #expect(result.entry(recent)?.notes.contains(AccountCapacityState.stale.displayText) == true)
    #expect(result.entry(old) == nil)
    #expect(!result.basedOnStaleReadings)
    #expect(result.useNextAccountID == result.launchOrder.first)
    #expect(result.useNextAccountID == recent.id)
}

@Test(arguments: [-1.0, 1.0])
func expiredCodexModelWaitNoteEndsAtItsOwnReset(resetHours: Double) throws {
    let model = (label: "Sample model", used: 100)
    let saved = Fixture(name: "saved", weeklyUsed: 20, resetHours: -1, signInExpired: true,
                        modelWindow: model, modelResetHours: resetHours, observedAgo: 7_200)
    let entry = try #require(ranking([saved]).entry(saved))
    #expect(entry.notes.contains { $0.contains(model.label) } == (resetHours > 0))
}

@Test func savedBurnDoesNotSizePersonalReserveOrProviderReceiptEstimates() throws {
    let healthy = Fixture(name: "healthy", weeklyUsed: 50, resetHours: 20, burn: 0.2)
    let saved = Fixture(name: "saved", weeklyUsed: 20, resetHours: 100, burn: 50,
                        signInExpired: true, observedAgo: 7_200)
    let evidence = UseNextEvidence(receipts: [healthy, saved].map {
        LaunchReceipt(provider: .openAI, accountID: $0.id, launchedAt: rankNow.addingTimeInterval(-60))
    })
    let baseline = AccountOverview.pointsPerLaunch(rows: overview([healthy]).accounts, evidence: evidence,
        now: rankNow, multipleUseLast: false)
    #expect(AccountOverview.pointsPerLaunch(rows: overview([healthy, saved]).accounts, evidence: evidence,
        now: rankNow, multipleUseLast: false) == baseline)
    var personal = saved
    personal.useLast = true
    let entry = try #require(ranking([healthy, personal]).entry(personal))
    #expect(entry.reserve == UseNextRanking.useLastFloor)
}

private extension UseNextRanking {
    func entry(_ fixture: Fixture) -> Entry? { entries.first { $0.accountID == fixture.id } }
    func exclusion(_ fixture: Fixture) -> Exclusion? { excluded.first { $0.accountID == fixture.id } }
}

@Test func quotaThatResetsFirstDrainsAboveTheDirectorsCushionBeforeALaterBankedReset() throws {
    let later = Fixture(name: "later", provider: .anthropic, weeklyUsed: 14, resetHours: 160,
                        burn: 2, bankedExpiryHours: [700])
    let personal = Fixture(name: "personal", provider: .anthropic, weeklyUsed: 36, resetHours: 80,
                           burn: 0.1, useLast: true)
    let result = ranking([later, personal], provider: .anthropic)
    #expect(result.useNextAccountID == personal.id)
    #expect(result.entry(personal)?.reserve != nil)
    #expect(result.launchOrder.first == result.useNextAccountID)
}

@Test func lastPlanQuotaPrecedesCreditsEvenInsideTheDirectorsCushion() {
    let personal = Fixture(name: "personal", weeklyUsed: 81, resetHours: 4, burn: 5, useLast: true)
    let credits = ["one", "two"].map { Fixture(name: $0, weeklyUsed: 100, resetHours: 4, onCredits: true) }
    let result = ranking([personal] + credits)
    #expect(result.useNextAccountID == personal.id)
    #expect(Set(result.launchOrder) == [personal.id])
}

@Test func accountStrategyCapsHeavyDemandUntilTheNextProviderRefill() throws {
    let first = Fixture(name: "first", weeklyUsed: 50, resetHours: 100, burn: 2.15)
    let later = Fixture(name: "later", weeklyUsed: 50, resetHours: 140, burn: 2.15)
    let result = ranking([first, later])
    #expect(result.useNextAccountID == first.id)
    #expect(result.targetPointsPerHour == 1)
    let zero = try #require(result.entry(first)?.depleteBy)
    #expect(zero == rankNow.addingTimeInterval(50 * hour))
    let forecast = try #require(result.forecast)
    #expect(forecast.runsOutBeforeRefill)
    #expect(forecast.pacePerHour == 4.3)
    #expect(forecast.capacityUntilRefillPoints == 100)
}

@Test func accountStrategyCountsRealResetsAsConditionalCapacity() throws {
    let first = Fixture(name: "first", weeklyUsed: 50, resetHours: 100, burn: 1, bankedExpiryHours: [200])
    let later = Fixture(name: "later", weeklyUsed: 50, resetHours: 140, burn: 1)
    let forecast = try #require(ranking([first, later]).forecast)
    #expect(forecast.capacityUntilRefillPoints == 200)
    #expect(forecast.sustainablePointsPerHour == 2)
    #expect(forecast.requiresBankedReset)
    #expect(!forecast.runsOutBeforeRefill)
}

@Test func accountStrategyPlansZeroBeforeAResetExpiresWithoutSkippingEarlierQuota() throws {
    let reset = Fixture(name: "reset", weeklyUsed: 50, resetHours: 100, burn: 0.1, bankedExpiryHours: [10, 10])
    let earlier = Fixture(name: "earlier", weeklyUsed: 80, resetHours: 5, burn: 0.1)
    let result = ranking([reset, earlier])
    #expect(result.useNextAccountID == earlier.id)
    let next = ranking([reset])
    #expect(try #require(next.targetPointsPerHour) > 15)
    #expect(try #require(next.entry(reset)?.depleteBy) < rankNow.addingTimeInterval(10 * hour))
    #expect(try #require(next.entry(reset)?.deadline) < rankNow.addingTimeInterval(10 * hour))
}

@Test func accountStrategyUsesCreditExpiryAndMeasuredSpendToPlanQuotaDepletion() throws {
    let credits = Fixture(name: "credits", weeklyUsed: 50, resetHours: 100, burn: 1)
    let other = Fixture(name: "other", weeklyUsed: 50, resetHours: 20, burn: 1)
    let capacity = UsageCreditCapacity(balance: 100, expiresAt: rankNow.addingTimeInterval(10 * hour),
        burnPerHour: 2, observedAt: rankNow)
    let result = ranking([other, credits], evidence: UseNextEvidence(credits: [credits.id: capacity]))
    let entry = try #require(result.entry(credits))
    #expect(result.useNextAccountID == credits.id)
    #expect(entry.targetPointsPerHour == 10)
    #expect(entry.targetCreditsPerHour == 20)
    #expect(entry.depleteBy == rankNow.addingTimeInterval(5 * hour))
    #expect(result.forecast?.creditRunwayUnknown == false)
}

@Test func accountStrategyDoesNotInventCreditRunwayWhenSpendIsUnknown() throws {
    let account = Fixture(name: "account", weeklyUsed: 50, burn: 1)
    let capacity = UsageCreditCapacity(balance: 100, expiresAt: rankNow.addingTimeInterval(10 * hour),
        burnPerHour: nil, observedAt: rankNow)
    let result = ranking([account], evidence: UseNextEvidence(credits: [account.id: capacity]))
    #expect(result.forecast?.creditRunwayUnknown == true)
    #expect(result.forecast?.capacityUntilRefillPoints == 50)
    var expired = capacity
    expired = UsageCreditCapacity(balance: expired.balance, expiresAt: rankNow.addingTimeInterval(-1),
        burnPerHour: 2, observedAt: rankNow)
    #expect(ranking([account], evidence: UseNextEvidence(credits: [account.id: expired])).forecast?.creditRunwayUnknown == false)
}

@Test func accountStrategyHoldsOnlyTheCushionAndSpendsItWhenItIsTheLastQuota() throws {
    let personal = Fixture(name: "personal", weeklyUsed: 98, resetHours: 5, burn: 0, useLast: true)
    let other = Fixture(name: "other", weeklyUsed: 80, resetHours: 100, burn: 0)
    let together = ranking([personal, other])
    #expect(together.useNextAccountID == other.id)
    #expect(together.entry(personal)?.targetPointsPerHour == 0)
    #expect(together.entry(personal)?.depleteBy == nil)
    let alone = ranking([personal])
    #expect(alone.useNextAccountID == personal.id)
    #expect(alone.entry(personal)?.reserve == 0)
    #expect(alone.entry(personal)?.depleteBy == rankNow.addingTimeInterval(5 * hour))
}

@Test func accountStrategyIncludesOtherQuotaNeededBeforeProtectedCreditsCanBeSpent() throws {
    let personal = Fixture(name: "personal", weeklyUsed: 98, resetHours: 100, burn: 1, useLast: true)
    let other = Fixture(name: "other", weeklyUsed: 50, resetHours: 100, burn: 1)
    let expiry = rankNow.addingTimeInterval(10 * hour)
    let capacity = UsageCreditCapacity(balance: 20, expiresAt: expiry, burnPerHour: 1, observedAt: rankNow)
    let result = ranking([personal, other], evidence: UseNextEvidence(credits: [personal.id: capacity]))
    #expect(result.useNextAccountID == other.id)
    #expect(result.targetPointsPerHour == 7.2)
    #expect(result.entry(personal)?.depleteBy == nil)
    #expect(result.entry(other)?.deadline == expiry)
}

@Test func accountStrategyDoesNotDrainTheDirectorsCushionWhileOtherQuotaWaitsOnAShortGate() throws {
    let personal = Fixture(name: "personal", weeklyUsed: 98, burn: 0, useLast: true)
    let gated = Fixture(name: "gated", weeklyUsed: 50, resetHours: 100, burn: 0, fiveHourUsed: 100)
    let result = ranking([personal, gated])
    #expect(result.useNextAccountID == nil)
    #expect(abs((result.entry(personal)?.reserve ?? 0) - 2) < 0.001)
    #expect(result.nextCapacityAt == rankNow.addingTimeInterval(gated.fiveHourResetHours * hour))
}

@Test func rankingFollowsNeedRatherThanPercentLeft() {
    let soon = Fixture(name: "soon", provider: .anthropic, weeklyUsed: 60, resetHours: 10, burn: 0)
    let later = Fixture(name: "later", provider: .anthropic, weeklyUsed: 0, resetHours: 150, burn: 0)
    let result = ranking([later, soon], provider: .anthropic)
    #expect(result.entries.map(\.accountID) == [soon.id, later.id])
    #expect(result.useNextAccountID == soon.id)
}

// #848: an event-driven reading whose reset passed with no use since is assumed full and still ranks,
// over a whole window from now, behind an account that would lose measured capacity sooner.
@Test func assumedResetRanksAsAFreshWindowBehindMeasuredNeed() throws {
    let quiet = Fixture(name: "gemini-quiet", provider: .google, weeklyUsed: 40, resetHours: -2, burn: 0.1,
                        observedAgo: 22 * hour, eventDriven: true)
    let alone = ranking([quiet], provider: .google)
    let entry = try #require(alone.entry(quiet))
    #expect(alone.exclusion(quiet) == nil)
    #expect(alone.useNextAccountID == quiet.id)
    #expect(alone.launchOrder.first == quiet.id)
    #expect(entry.remaining == 100)
    #expect(entry.deadline == rankNow.addingTimeInterval(168 * hour))
    #expect(!entry.unstarted)
    #expect(entry.notes.contains(AccountTerms.assumedResetLaunch))

    let measured = Fixture(name: "gemini-measured", provider: .google, weeklyUsed: 50, resetHours: 20, burn: 0.5)
    let both = ranking([quiet, measured], provider: .google)
    #expect(both.entries.map(\.accountID) == [measured.id, quiet.id])
}

@Test func receiptsStopCountingOnceTwoLaterReadingsOrHalfAnHourPass() {
    let a = Fixture(name: "a", weeklyUsed: 40, resetHours: 100, burn: 0)
    let receipt = LaunchReceipt(provider: .openAI, accountID: a.id, launchedAt: rankNow.addingTimeInterval(-10 * 60))
    let readings = [rankNow.addingTimeInterval(-6 * 60), rankNow.addingTimeInterval(-1 * 60)]
    #expect(ranking([a], evidence: UseNextEvidence(receipts: [receipt], readingTimes: readings)).entry(a)?.pendingLaunches == 0)
    #expect(ranking([a], evidence: UseNextEvidence(receipts: [receipt], readingTimes: readings,
        accountReadingTimes: [a.id: []])).entry(a)?.pendingLaunches == 1)
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

// 7. Two accounts marked use-last: configuration error; use-last is ignored.
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

// #1078: plan quota that would refill unused first, then accounts spending usage credits, then the use-last cushion.
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

// #1078: a refill shows only on accounts that had used quota, whatever state the others are in.
@Test func providerRefillIsDetectedAcrossAsymmetricAccountStates() {
    struct State { var used: Int; var reset: Date; var banked: ProviderResetCreditSummary? }
    func reading(_ at: Date, _ accounts: [String: State]) -> StoredUsageSnapshot {
        let names = accounts.keys.sorted()
        let limits = names.map { name in
            UsageLimit(provider: .openAI, accountID: name, configuredAccountID: name, accountName: name, label: "Codex Weekly",
                       windowLabel: "Weekly", modelLabel: "Codex", unit: .percent, used: accounts[name]!.used, limit: 100,
                       resetsAt: accounts[name]!.reset, lastUpdatedAt: at, confidence: .observed)
        }
        let reports = names.map { StoredProviderReport(provider: .openAI, accountID: $0, configuredAccountID: $0, accountName: $0,
            generatedAt: at, resetCredits: accounts[$0]!.banked, status: .healthy, errorMessage: nil) }
        return StoredUsageSnapshot(savedAt: at, snapshot: UsageSnapshot(generatedAt: at, limits: limits), reports: reports)
    }
    func banked(_ count: Int, expiries: [Date] = [], at: Date) -> ProviderResetCreditSummary {
        ProviderResetCreditSummary(availableCount: count, observedAt: at, coverage: expiries.isEmpty ? .countOnly : .complete,
                                   knownExpiries: expiries)
    }
    let before = rankNow.addingTimeInterval(-hour)
    let oldReset = rankNow.addingTimeInterval(72 * hour)
    let newReset = rankNow.addingTimeInterval(167 * hour)
    let unstartedBefore = State(used: 0, reset: before.addingTimeInterval(168 * hour), banked: banked(1, at: before))
    let unstartedAfter = State(used: 0, reset: rankNow.addingTimeInterval(168 * hour), banked: banked(1, at: rankNow))
    func ids(_ events: [ProviderRefillEvent]) -> [[String]] { events.map(\.accountIDs) }
    let x = AccountDisplayMetadata.safeID(.openAI, "x")
    let y = AccountDisplayMetadata.safeID(.openAI, "y")

    // One account used, one never started: the used one alone shows the refill. Also when it was at 0%.
    for used in [40, 100] {
        let events = ProviderRefillDetector.events(readings: [
            reading(before, ["x": State(used: used, reset: oldReset, banked: banked(2, at: before)), "y": unstartedBefore]),
            reading(rankNow, ["x": State(used: 0, reset: newReset, banked: banked(2, at: rankNow)), "y": unstartedAfter]),
        ])
        #expect(ids(events) == [[x]])
    }

    // A lone jump while another used account carries on, or with no banked count to rule out a spent reset, is not one.
    #expect(ProviderRefillDetector.events(readings: [
        reading(before, ["x": State(used: 40, reset: oldReset, banked: banked(2, at: before)),
                         "y": State(used: 20, reset: oldReset, banked: banked(2, at: before))]),
        reading(rankNow, ["x": State(used: 0, reset: newReset, banked: banked(2, at: rankNow)),
                          "y": State(used: 21, reset: oldReset, banked: banked(2, at: rankNow))]),
    ]).isEmpty)
    #expect(ProviderRefillDetector.events(readings: [
        reading(before, ["x": State(used: 40, reset: oldReset, banked: nil), "y": State(used: 0, reset: oldReset, banked: nil)]),
        reading(rankNow, ["x": State(used: 0, reset: newReset, banked: nil), "y": State(used: 0, reset: oldReset, banked: nil)]),
    ]).isEmpty)

    // Readings hours apart still place the refill between them.
    let overnight = rankNow.addingTimeInterval(-8 * hour)
    #expect(ids(ProviderRefillDetector.events(readings: [
        reading(overnight, ["x": State(used: 40, reset: oldReset, banked: banked(2, at: overnight)),
                            "y": State(used: 60, reset: oldReset, banked: banked(2, at: overnight))]),
        reading(rankNow, ["x": State(used: 0, reset: newReset, banked: banked(2, at: rankNow)),
                          "y": State(used: 0, reset: newReset, banked: banked(2, at: rankNow))]),
    ])) == [[x, y].sorted()])

    // A banked reset granted, or one that expired between the readings, is not a spent reset.
    let expiry = rankNow.addingTimeInterval(-0.5 * hour)
    #expect(ids(ProviderRefillDetector.events(readings: [
        reading(before, ["x": State(used: 40, reset: oldReset, banked: banked(1, at: before)),
                         "y": State(used: 60, reset: oldReset, banked: banked(2, expiries: [expiry, newReset], at: before))]),
        reading(rankNow, ["x": State(used: 0, reset: newReset, banked: banked(2, at: rankNow)),
                          "y": State(used: 0, reset: newReset, banked: banked(1, expiries: [newReset], at: rankNow))]),
    ])) == [[x, y].sorted()])
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
    #expect(expiring.prompt != nil && !expiring.notYetApplicable)

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
    #expect(ClaudeResetCreditParser.summary(from: grants(""), observedAt: observed)?.unrecognizedKindCount == 1)
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

// #1003: the cushion is planned personal use before the reset, so it tapers toward the floor instead of being held.
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
    #expect(loaded.map(\.accountID) == [id])
    #expect(loaded.map(\.launchedAt) == [rankNow.addingTimeInterval(-60)])
    #expect(loaded.first?.receiptID != nil)
    #expect(LaunchReceiptStore.load(rootDirectory: root, now: rankNow).map(\.receiptID) == loaded.map(\.receiptID))
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

// #794, #1079: in a slow week an empty account alone is not a reason to apply its reset.
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
        let panel = AccountOverview(snapshot: stored.snapshot, reports: stored.reports,
            metadata: AccountDisplayMetadata.local(configuration: configuration.accounts, stored: stored, now: rankNow), now: rankNow)
        let panelPrompts = panel.accounts.compactMap(\.resetAssessment).filter(\.recommended)
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
        let stored = StoredUsageSnapshot(savedAt: rankNow,
            snapshot: UsageSnapshot(generatedAt: rankNow, limits: fixtures.flatMap { $0.limits(now: rankNow) }),
            reports: fixtures.map { $0.report(now: rankNow) })
        for fixture in fixtures {
            let report = fixture.report(now: rankNow)
            let account = try #require(panel.accounts.first { $0.id == fixture.id })
            let diagnostics = AccountOverview.Diagnostics(account: account, snapshot: stored.snapshot, reports: stored.reports)
            let deadlines = BankedResetDeadlinesView(reports: [report],
                presentationDate: rankNow, adviceByAccountID: diagnostics.bankedAdvice)
            #expect(deadlines.advice(for: report) == account.bankedAdvice)
        }
    }
}

@Test(arguments: [Provider.openAI, .anthropic])
@MainActor func sharedResetAdviceSurvivesUnverifiedIDsAndMatchesAgentSnapshot(_ provider: Provider) throws {
    let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, bankedExpiryHours: [200])
    for personalUsed in [50, 100] {
        let personal = Fixture(name: "personal", provider: provider, weeklyUsed: personalUsed, useLast: true,
            showInWidgets: false)
        let fixtures = [empty, personal]
        let configuration = AccountConfigurationDocument(updatedAt: rankNow, accounts: fixtures.map {
            LocalProviderAccountConfiguration(id: $0.name, provider: provider,
                connectorKind: provider == .openAI ? .codexRateLimits : .claudeOAuthUsage, displayName: $0.name,
                authPath: "/not/read/\($0.name)", showInWidgets: $0.showInWidgets, useLast: $0.useLast)
        }, publisherID: "test-publisher")
        let stored = StoredUsageSnapshot(savedAt: rankNow,
            snapshot: UsageSnapshot(generatedAt: rankNow, limits: fixtures.flatMap { $0.limits(now: rankNow) }),
            reports: fixtures.map { $0.report(now: rankNow) })
        let remote = CompanionSyncDocument(storedSnapshot: StoredUsageSnapshot(savedAt: rankNow,
            snapshot: UsageSnapshot(generatedAt: rankNow, limits: [])), publishedAt: rankNow)
        let shared = MacSharedAccountPresentation.make(stored: stored, configuration: configuration.accounts,
            publisherID: configuration.publisherID, remote: remote, accountIntentDocument: configuration, now: rankNow)
        let panel = shared.accountOverview(now: rankNow, maximumAge: SnapshotFreshness.appMaximumAge)
        let selected = try #require(panel.accounts.first { $0.metadata.label == empty.name })
        #expect(selected.id != empty.id) // This fixture exercises the companion identity mapping.
        let diagnostics = AccountOverview.Diagnostics(account: selected, snapshot: shared.usageSnapshot, reports: shared.reports)
        let report = try #require(diagnostics.reports.first)
        #expect(diagnostics.bankedAdvice[report.accountID] == selected.bankedAdvice)
        #expect(selected.bankedAdvice != nil)
        let deadlines = BankedResetDeadlinesView(reports: diagnostics.reports,
            presentationDate: rankNow, adviceByAccountID: diagnostics.bankedAdvice)
        #expect(deadlines.advice(for: report) == selected.bankedAdvice)
        let snapshot = AgentAccountSnapshot(configuration: configuration, stored: stored, history: [], now: rankNow,
            sharedDocument: remote)
        let prompts = panel.accounts.compactMap(\.resetAssessment).filter(\.recommended)
        #expect(snapshot.resetPrompts.map(\.accountID) == prompts.map(\.accountID))
        #expect(snapshot.resetPrompts.count == (personalUsed == 100 ? 1 : 0))
    }
}

@Test(arguments: [false, true], [false, true])
func companionRankingMatchesMacExportWithLaunchHistory(verified: Bool, legacyReceipts: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let personal = Fixture(name: "personal", provider: .anthropic, weeklyUsed: 36, resetHours: 100,
                           useLast: true, fiveHourUsed: 9)
    let agents = Fixture(name: "agents", provider: .anthropic, weeklyUsed: 100, resetHours: 100)
    let fixtures = [personal, agents]
    let identityKey = ProviderAccountIdentityKey.generate()
    let materials = try fixtures.map {
        try #require(ProviderAccountIdentityMaterial(provider: .anthropic, kind: .claudeAccountUUID, identifier: $0.name))
    }
    let rawIDs = zip(fixtures, materials).map { $1.localHistoryID(configurationID: $0.name) }
    let identities = zip(materials, rawIDs).map { material, rawID in
        identityKey.identity(for: material).bound(toLocalAccountID: rawID)
    }
    let configuration = AccountConfigurationDocument(updatedAt: rankNow, accounts: fixtures.map {
        LocalProviderAccountConfiguration(id: $0.name, provider: .anthropic, connectorKind: .claudeOAuthUsage,
            displayName: $0.name, useLast: $0.useLast)
    })
    let configStore = AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json"))
    try configStore.save(configuration)
    let history = (0...2).reversed().map { hoursAgo in
        let date = rankNow.addingTimeInterval(-Double(hoursAgo) * hour)
        return StoredUsageSnapshot(savedAt: date,
            snapshot: UsageSnapshot(generatedAt: date, limits: zip(fixtures, rawIDs).flatMap { fixture, rawID in
                var earlier = fixture
                earlier.weeklyUsed = (fixture.weeklyUsed ?? 0) - hoursAgo
                earlier.resetHours = (fixture.resetHours ?? 0) + Double(hoursAgo)
                earlier.fiveHourResetHours += Double(hoursAgo)
                return earlier.limits(now: date).map { $0.reidentified(accountID: rawID, configuredAccountID: fixture.name) }
            }), reports: fixtures.indices.map { index in
                let fixture = fixtures[index]
                return StoredProviderReport(provider: .anthropic, accountID: rawIDs[index], configuredAccountID: fixture.name,
                    accountName: fixture.name, generatedAt: date, status: .healthy, errorMessage: nil,
                    sharedAccountIdentity: verified ? identities[index] : nil)
            })
    }
    let stored = try #require(history.last)
    let snapshotStore = JSONSnapshotStore(rootDirectory: root.appending(path: "Snapshots"))
    for reading in history { try snapshotStore.save(reading) }
    let receiptDirectory = root.appending(path: LaunchReceiptStore.directoryName)
    try FileManager.default.createDirectory(at: receiptDirectory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let receipts = try fixtures.enumerated().map { index, fixture in
        let limit = try #require(stored.snapshot.limits.first { $0.configuredAccountID == fixture.name })
        let id = legacyReceipts ? AccountDisplayMetadata.safeID(.anthropic, CompanionLimit(limit: limit).companionAccountID)
            : verified ? AccountDisplayMetadata.safeID(.anthropic, CompanionLimit(limit: limit,
            identityConfiguredAccountID: nil, sharedIdentity: identities[index]).companionAccountID)
            : AccountDisplayMetadata.safeID(.anthropic, limit.accountID)
        let receipt = LaunchReceipt(provider: .anthropic, accountID: id, launchedAt: rankNow.addingTimeInterval(-hour))
        try encoder.encode(receipt).write(to: receiptDirectory.appending(path: "receipt-\(index).json"))
        return receipt
    }
    let rates = AccountBurnRateEstimator.observedBurnRates(current: stored.snapshot, history: history, now: rankNow)
    let sync = CompanionSyncStore(documentURL: root.appending(path: "sync.json"))
    let publisher = CompanionSyncPublisher(stores: CompanionSyncStoreSet(stores: [sync]),
        widgetPreferencesStore: WidgetDisplayPreferencesStore(preferencesURL: root.appending(path: "widget.json")),
        fastModeForecastSettingsStore: FastModeForecastSettingsStore(settingsURL: root.appending(path: "forecast.json")),
        accountConfigurationURL: configStore.configurationURL)
    #expect(publisher.publish(storedSnapshot: stored, publishedAt: rankNow, accountBurnRates: rates).succeeded)
    let document = try #require(sync.load(policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.companionProviderMaximumAge), now: rankNow).document)
    let decoded = try CompanionSyncPayloadCodec.decode(CompanionSyncPayloadCodec.encode(document))
    let merged = decoded.mergingForRemotePublish(existing: decoded, now: rankNow)
    let widget = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: merged, status: .healthy), now: rankNow)
    let phone = widget
        .accountOverview(now: rankNow, maximumAge: SnapshotFreshness.companionProviderMaximumAge)
    let exported = try AgentAccountSnapshot.read(rootDirectory: root, now: rankNow)
    let published = try #require(exported.ranking.first { $0.provider == .anthropic })
    let preview = publisher.presentationDocument(storedSnapshot: stored, now: rankNow, accountBurnRates: rates)
    #expect(WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: preview, status: .healthy), now: rankNow)
        .accountOverview(now: rankNow).useNext(provider: .anthropic)?.metadata.label == personal.name)
    if verified { #expect(phone.useNextRanking(provider: .anthropic) == published) }
    let selectedID = try #require(exported.answers.useNext.first { $0.provider == .anthropic }?.accountID)
    #expect(phone.useNext(provider: .anthropic)?.metadata.label == exported.accounts.first { $0.id == selectedID }?.label)
    #expect(phone.useNext(provider: .anthropic)?.metadata.label == personal.name)
    #expect(phone.filtered(to: .anthropic).useNext(provider: .anthropic)?.metadata.label == personal.name)
    #expect(phone.launchEvidence.receipts.count == receipts.count)
    let selected = try #require(phone.useNext(provider: .anthropic))
    let removed = CompanionSyncDocument(snapshot: decoded.snapshot, accountDisplayMetadata: decoded.accountDisplayMetadata,
        removedDisplayIDs: [selected.id], launchEvidence: decoded.launchEvidence).applyingGlobalRemovals()
    #expect(removed.launchEvidence?.receipts.contains { $0.accountID == selected.id } == false)
    #expect(removed.launchEvidence?.accountReadingTimes?[selected.id] == nil)
    let withoutReceipts = phone.useNextRanking(provider: .anthropic, evidence: UseNextEvidence())
    #expect(withoutReceipts.useNextAccountID == selected.id)
    #expect(withoutReceipts.entries.first?.reserve == 0)

}

@Test(arguments: [false, true], [false, true])
func sharedLaunchMergeKeepsDistinctEventsAndAcknowledgesOnlyTheRetainedObservation(hasRemoval: Bool, hasAlias: Bool) throws {
    let observed = rankNow.addingTimeInterval(-60)
    let account = Fixture(name: "shared", observedAgo: 60)
    let stored = StoredUsageSnapshot(savedAt: observed,
        snapshot: UsageSnapshot(generatedAt: observed, limits: account.limits(now: rankNow)),
        reports: [account.report(now: rankNow)])
    let snapshot = CompanionSnapshot(storedSnapshot: stored, publishedAt: observed)
    let id = AccountDisplayMetadata.safeID(.openAI, try #require(snapshot.limits.first).companionAccountID)
    let receipts = ["publisher-one", "publisher-two"].map {
        LaunchReceipt(provider: .openAI, accountID: id, launchedAt: rankNow.addingTimeInterval(-30), receiptID: $0)
    }
    let existing = CompanionSyncDocument(snapshot: snapshot,
        launchEvidence: UseNextEvidence(receipts: [receipts[0]], accountReadingTimes: [id: [observed]]))
    let failure = StoredProviderReport(provider: .openAI, accountID: account.name, configuredAccountID: account.name,
        accountName: account.name, generatedAt: rankNow, status: .failure, errorMessage: nil)
    let material = try #require(ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID, identifier: "unrelated"))
    let identity = ProviderAccountIdentityKey.generate().identity(for: material)
    let alias = CompanionAccountIdentityAlias(provider: .openAI, legacyAccountID: "unrelated-legacy",
        replacementAccountID: identity.accountID, configurationID: "unrelated-configuration", observedAt: rankNow, reusableIdentity: nil)
    let failed = CompanionSyncDocument(storedSnapshot: StoredUsageSnapshot(savedAt: rankNow,
        snapshot: UsageSnapshot(generatedAt: rankNow, limits: []), reports: [failure]),
        removedDisplayIDs: hasRemoval ? [AccountDisplayMetadata.safeID(.openAI, "unrelated-removed")] : nil,
        accountIdentityAliases: hasAlias ? [alias] : nil,
        launchEvidence: UseNextEvidence(receipts: [receipts[1]],
            accountReadingTimes: [id: [rankNow.addingTimeInterval(-10), rankNow]]))
    let merged = failed.mergingForRemotePublish(existing: existing, now: rankNow)
    let evidence = try #require(merged.launchEvidence)
    #expect(Set(evidence.receipts.compactMap(\.receiptID)) == Set(receipts.compactMap(\.receiptID)))
    #expect(evidence.accountReadingTimes?[id] == [observed])
    let rows = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: existing, status: .healthy), now: rankNow)
        .accountOverview(now: rankNow).accounts
    #expect(AccountOverview.pendingLaunches(evidence: evidence, rows: rows, now: rankNow)[id] == receipts.count)
    #expect(merged.mergingForRemotePublish(existing: merged, now: rankNow).launchEvidence?.receipts.count == receipts.count)
    let expired = evidence.merging(UseNextEvidence(), now: rankNow.addingTimeInterval(LaunchReceiptStore.lookback))
    #expect(expired.receipts.isEmpty)
}

@Test func launchEvidenceFitsTheCloudKitRecordAtTheSupportedReceiptStoreCapacity() throws {
    let id = AccountDisplayMetadata.safeID(.anthropic, "synthetic")
    let receipts = (0..<(2 * LaunchReceiptStore.maximumFileCount)).map {
        LaunchReceipt(provider: .anthropic, accountID: id, launchedAt: rankNow.addingTimeInterval(-Double($0)),
            receiptID: AccountDisplayMetadata.safeID(.anthropic, "event-\($0)"))
    }
    let document = CompanionSyncDocument(snapshot: CompanionSnapshot(generatedAt: rankNow, publishedAt: rankNow,
        limits: [], providerStatuses: [], promptCacheSummaries: []),
        launchEvidence: UseNextEvidence(receipts: receipts, readingTimes: [rankNow], accountReadingTimes: [id: [rankNow]]))
    let encoded = try CompanionSyncPayloadCodec.encode(document)
    let decoded = try CompanionSyncPayloadCodec.decode(encoded)
    #expect(decoded.launchEvidence == document.launchEvidence)
    let roundTrip = try #require(decoded.launchEvidence).receipts
    #expect(roundTrip.sorted { ($0.receiptID ?? "") < ($1.receiptID ?? "") }
        == receipts.sorted { ($0.receiptID ?? "") < ($1.receiptID ?? "") })
    // Apple's CKRecord limit excludes assets, but this payload is an inline bytes field.
    #expect(encoded.count < 1_000_000)
    print("Companion payload with \(receipts.count) launch receipts: \(encoded.count) bytes")
}

@Test func openAIResetIsNotApplicableAtEightyPercentLeftAndWarnsEarlyEnough() throws {
    // 85% left at one point an hour needs about 6 hours to get under 80%, so the warning starts 30 hours out.
    let gated = Fixture(name: "gated", weeklyUsed: 15, burn: 1, bankedExpiryHours: [29])
    let warning = try #require(overview([gated]).accounts.first?.resetAssessment)
    #expect(warning.notYetApplicable && warning.trigger == .expiring)
    #expect(!warning.recommended && warning.prompt == nil && warning.useFirstPrompt != nil)
    var early = gated
    early.bankedExpiryHours = [31]
    let before = try #require(overview([early]).accounts.first?.resetAssessment)
    #expect(before.notYetApplicable && before.trigger == .notNeeded)
    var under = gated
    under.weeklyUsed = 21
    #expect(overview([under]).accounts.first?.resetAssessment?.notYetApplicable == false)
    var claude = gated
    claude.provider = .anthropic
    #expect(overview([claude]).accounts.first?.resetAssessment?.notYetApplicable == false)
    // At a tenth of a point an hour, 90% left needs about 110 hours, so a reset 120 hours out already warns.
    let slow = Fixture(name: "slow", weeklyUsed: 10, resetHours: 160, burn: 0.1, bankedExpiryHours: [120])
    #expect(overview([slow]).accounts.first?.resetAssessment?.trigger == .expiring)
}

@Test func claudeRefillIsValuedAtAMeasuredIdlePace() throws {
    let idle = Fixture(name: "idle", provider: .anthropic, weeklyUsed: 80, resetHours: 48, burn: 0, bankedExpiryHours: [20])
    #expect(overview([idle]).accounts.first?.resetAssessment?.recommended == false)
    var unmeasured = idle
    unmeasured.burn = nil
    #expect(overview([unmeasured]).accounts.first?.resetAssessment?.recommended == true)
}

@Test func openAIResetStartsAFreshWeekWhileClaudeNeedsTimeToUseItsRefill() throws {
    // Each account is empty, so its provider runs out; the reset's value differs by provider.
    for provider in [Provider.openAI, .anthropic] {
        let empty = Fixture(name: "empty", provider: provider, weeklyUsed: 100, resetHours: 48, burn: 0.2, bankedExpiryHours: [100])
        let advice = try #require(overview([empty]).accounts.first?.resetAssessment)
        #expect(advice.trigger == .outOfQuota)
        // OpenAI gains the two days its next refill moves earlier; Claude can use only what its pace spends by the same end date.
        #expect(advice.recommended == (provider == .openAI))
        var faster = empty
        faster.burn = 1
        #expect(overview([faster]).accounts.first?.resetAssessment?.recommended == true)
    }
}

@Test func resetAdviceNotifiesOnceThroughLimitWarnings() throws {
    let empty = Fixture(name: "empty", weeklyUsed: 100, bankedExpiryHours: [100])
    let notice = try #require(overview([empty]).accounts.first?.resetAssessment)
    let settings = LimitWarningSettings(isEnabled: true)
    let snapshot = UsageSnapshot(generatedAt: rankNow, limits: [])
    let first = LimitWarningEvaluator.evaluate(settings: settings, state: .empty, snapshot: snapshot, now: rankNow, resetNotices: [notice])
    #expect(first.events.map(\.title) == [notice.prompt])
    let again = LimitWarningEvaluator.evaluate(settings: settings, state: first.state, snapshot: snapshot, now: rankNow, resetNotices: [notice])
    #expect(again.events.isEmpty)
    let plan = LimitWarningNotificationCommitPlan(currentState: first.state, targetState: again.state, snapshot: snapshot,
                                                  settings: settings, resetNotices: [notice])
    #expect(plan.persistedState == first.state)
    let ended = LimitWarningEvaluator.evaluate(settings: settings, state: first.state, snapshot: snapshot, now: rankNow)
    #expect(ended.state.records.isEmpty)
}
