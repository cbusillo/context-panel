import Foundation
import Testing

@testable import ContextPanelCore

private let totalsNow = Date(timeIntervalSince1970: 1_790_000_000)

/// Two-window accounts: (id, provider, weekly used %, weekly reset in hours, weekly burn %/h or nil, observed hours ago).
private func totalsOverview(_ rows: [(String, Provider, Int, Double, Double?, Double)]) -> AccountOverview {
    var limits: [UsageLimit] = []
    var reports: [StoredProviderReport] = []
    var rates: [String: [String: ObservedBurnRate]] = [:]
    for (id, provider, used, resetHours, burn, age) in rows {
        let observed = totalsNow.addingTimeInterval(-age * 3_600)
        let weekly = UsageLimit(provider: provider, accountID: id, accountName: id, label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: used, limit: 100, resetsAt: totalsNow.addingTimeInterval(resetHours * 3_600),
            lastUpdatedAt: observed, confidence: .observed)
        let fiveHour = UsageLimit(provider: provider, accountID: id, accountName: id, label: "5-hour", windowLabel: "5-hour",
            unit: .percent, used: 20, limit: 100, resetsAt: totalsNow.addingTimeInterval(3 * 3_600),
            lastUpdatedAt: observed, confidence: .observed)
        limits += [weekly, fiveHour]
        reports.append(StoredProviderReport(provider: provider, accountID: id, accountName: id, generatedAt: observed,
            resetCredits: nil, status: .healthy, errorMessage: nil))
        if let burn {
            rates[id] = [weekly.id: ObservedBurnRate(limitID: weekly.id, unitsPerHour: burn, observedDurationHours: 6, sampleCount: 24)]
        }
    }
    return AccountOverview(snapshot: UsageSnapshot(generatedAt: totalsNow, limits: limits), reports: reports,
        now: totalsNow, accountBurnRates: rates)
}

@Test func glanceSurfacesReadWeekBeforeFiveHour() throws {
    let account = try #require(totalsOverview([("a", .openAI, 40, 100, 0.2, 0)]).accounts.first)
    #expect(account.orderedWindows.map(\.shortLabel) == ["Week", "5h"])
    #expect(account.glanceWindows.map(\.shortLabel) == ["Week", "5h"])
}

@Test func providerTotalAddsAccountsRoomAndBurn() throws {
    // Two OpenAI accounts: 20% and 60% weekly left, burning 1%/h and 0.5%/h, resets in 100h and 50h.
    let overview = totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 40, 50, 0.5, 0), ("c", .anthropic, 10, 100, 0.1, 0)])
    let totals = overview.providerTotals(now: totalsNow)
    #expect(totals.map(\.provider) == [.openAI, .anthropic])
    let openAI = try #require(totals.first)
    #expect(openAI.isCombined && !(totals.last?.isCombined ?? true))
    #expect(abs((openAI.longRemaining ?? 0) - 0.4) < 0.0001)
    #expect(abs((openAI.shortRemaining ?? 0) - 0.8) < 0.0001)
    // Combined burn is a share of the combined room: (0.01 + 0.005) / 2 per hour.
    #expect(abs((openAI.burnPerHour ?? 0) - 0.0075) < 0.000001)
    // Pace: combined burn against the even burn that lands each account on zero at its own reset.
    let even = 0.2 / 100 + 0.6 / 50
    #expect(abs((openAI.paceRatio ?? 0) - 0.015 / even) < 0.0001)
    // Room 0.8 at 0.015/h lasts 53.3h, past the first reset at 50h, so it lasts to the reset.
    #expect(openAI.runOut == nil)
    #expect(AccountTerms.combinedOutlook(openAI, now: totalsNow) == AccountTerms.lastsToReset)
}

@Test func providerTotalRunsOutOnlyBeforeTheFirstReset() throws {
    let overview = totalsOverview([("a", .openAI, 90, 100, 2.0, 0), ("b", .openAI, 90, 120, 2.0, 0)])
    let total = try #require(overview.providerTotals(now: totalsNow).first)
    // Room 0.2 at 0.04/h runs out in 5h, before the first reset at 100h.
    let runOut = try #require(total.runOut)
    #expect(abs(runOut.timeIntervalSince(totalsNow) - 5 * 3_600) < 1)
}

@Test func providerTotalNeedsEveryCurrentAccountsBurnAndSkipsSavedOnes() throws {
    // b has no observed burn: a partial sum would understate the combined burn, so no pace.
    let measuring = try #require(totalsOverview([("a", .openAI, 50, 100, 1.0, 0), ("b", .openAI, 50, 100, nil, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(measuring.paceRatio == nil && measuring.runOut == nil)
    #expect(AccountTerms.combinedOutlook(measuring, now: totalsNow) == AccountTerms.measuring)

    // b is saved (observed long ago): listed, not added.
    let saved = try #require(totalsOverview([("a", .openAI, 50, 100, 1.0, 0), ("b", .openAI, 0, 100, 1.0, 48)])
        .providerTotals(now: totalsNow).first)
    #expect(saved.accountCount == 2 && saved.countedCount == 1)
    #expect(abs((saved.longRemaining ?? 0) - 0.5) < 0.0001)
    #expect(AccountTerms.accountCount(saved) == "1 of 2 current")
}

@Test func bankedResetSaysWhetherTheWeeklyResetComesFirst() {
    let reset = totalsNow.addingTimeInterval(48 * 3_600)
    let before = AccountTerms.weekResetRelation(expiresAt: totalsNow.addingTimeInterval(24 * 3_600), weekReset: reset, now: totalsNow)
    let after = AccountTerms.weekResetRelation(expiresAt: totalsNow.addingTimeInterval(72 * 3_600), weekReset: reset, now: totalsNow)
    #expect(before?.hasPrefix("Expires before week resets") == true)
    #expect(after?.hasPrefix("Week resets first") == true)
    #expect(AccountTerms.weekResetRelation(expiresAt: reset, weekReset: nil, now: totalsNow) == nil)
}

@Test func providerMarksAreDistinctLettersAndColours() {
    #expect(Set(Provider.allCases.map(\.markLetter)).count == Provider.allCases.count)
    #expect(Set(Provider.allCases.map(\.colorToken)).count == Provider.allCases.count)
}
