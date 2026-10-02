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
            unit: .percent, used: used, limit: 100, resetsAt: resetHours.isFinite ? totalsNow.addingTimeInterval(resetHours * 3_600) : nil,
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

@Test func providerTotalAveragesRoomBurnAndPace() throws {
    // Two OpenAI accounts: 20% and 60% weekly left, burning 1%/h and 0.5%/h, resets in 100h and 50h.
    let overview = totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 40, 50, 0.5, 0), ("c", .anthropic, 10, 100, 0.1, 0)])
    let totals = overview.providerTotals(now: totalsNow)
    #expect(totals.map(\.provider) == [.openAI, .anthropic])
    let openAI = try #require(totals.first)
    #expect(openAI.isCombined && !(totals.last?.isCombined ?? true))
    #expect(abs((openAI.longRemaining ?? 0) - 0.4) < 0.0001)
    #expect(abs((openAI.shortRemaining ?? 0) - 0.8) < 0.0001)
    #expect(abs((openAI.burnPerHour ?? 0) - 0.0075) < 0.000001)
    let even = 0.2 / 100 + 0.6 / 50
    #expect(abs((openAI.paceRatio ?? 0) - 0.015 / even) < 0.0001)
    // a runs out at 20h (before its 100h reset); b lasts 120h, past its 50h reset.
    #expect(openAI.runningOutCount == 1 && openAI.allOutBy == nil)
    #expect(AccountTerms.combinedOutlook(openAI, now: totalsNow) == "1 of 2 run out")
}

@Test func providerOutlookDoesNotDependOnPlanSize() throws {
    // Neither account runs out before its own reset at its own burn: true whatever each plan's size.
    let lasting = try #require(totalsOverview([("a", .openAI, 50, 40, 1.0, 0), ("b", .openAI, 10, 40, 0.1, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(lasting.runningOutCount == 0 && lasting.allOutBy == nil)
    #expect(AccountTerms.combinedOutlook(lasting, now: totalsNow) == "Week lasts to reset")

    // Both run out before their resets: the outlook names when the last one does, not a pooled guess.
    let out = try #require(totalsOverview([("a", .openAI, 90, 100, 2.0, 0), ("b", .openAI, 80, 120, 1.0, 0)])
        .providerTotals(now: totalsNow).first)
    let last = try #require(out.allOutBy)
    #expect(abs(last.timeIntervalSince(totalsNow) - 20 * 3_600) < 1)
    #expect(AccountTerms.combinedOutlook(out, now: totalsNow).hasPrefix("all out by "))
}

@Test func providerTotalNeedsEveryCurrentAccountsBurnAndSkipsSavedOnes() throws {
    // b has no observed burn: a partial set would understate the combined burn, so no pace;
    // a's own run-out is still known and counted.
    let measuring = try #require(totalsOverview([("a", .openAI, 50, 100, 1.0, 0), ("b", .openAI, 50, 100, nil, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(measuring.paceRatio == nil && measuring.runningOutCount == 1)
    #expect(AccountTerms.combinedOutlook(measuring, now: totalsNow) == "1 of 2 run out")
    let calm = try #require(totalsOverview([("a", .openAI, 10, 100, 0.1, 0), ("b", .openAI, 50, 100, nil, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(AccountTerms.combinedOutlook(calm, now: totalsNow) == AccountTerms.measuring)

    // b is saved (observed long ago): listed, not added, and compact surfaces say so.
    let saved = try #require(totalsOverview([("a", .openAI, 50, 100, 1.0, 0), ("b", .openAI, 0, 100, 1.0, 48)])
        .providerTotals(now: totalsNow).first)
    #expect(saved.accountCount == 2 && saved.countedCount == 1)
    #expect(abs((saved.longRemaining ?? 0) - 0.5) < 0.0001)
    #expect(AccountTerms.accountCount(saved) == "1 of 2 current")
    #expect(AccountTerms.countedSuffix(saved) == "1 of 2")
}

@Test func providerTotalPoolsTheAccountWideWindowNotAModelLimit() throws {
    // A model-only weekly limit is tighter than the account-wide one; the pool uses the account-wide one.
    let overall = UsageLimit(provider: .anthropic, accountID: "a", accountName: "a", label: "Weekly", windowLabel: "Weekly",
        unit: .percent, used: 40, limit: 100, resetsAt: totalsNow.addingTimeInterval(100 * 3_600), lastUpdatedAt: totalsNow, confidence: .observed)
    let model = UsageLimit(provider: .anthropic, accountID: "a", accountName: "a", label: "Weekly", windowLabel: "Weekly", modelLabel: "Opus",
        unit: .percent, used: 90, limit: 100, resetsAt: totalsNow.addingTimeInterval(100 * 3_600), lastUpdatedAt: totalsNow, confidence: .observed)
    let report = StoredProviderReport(provider: .anthropic, accountID: "a", accountName: "a", generatedAt: totalsNow,
        resetCredits: nil, status: .healthy, errorMessage: nil)
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: totalsNow, limits: [overall, model]), reports: [report], now: totalsNow)
    let account = try #require(overview.accounts.first)
    #expect(account.longWindow?.modelLabel == "Opus")
    #expect(account.poolWindow?.modelLabel == nil)
    #expect(abs((overview.providerTotals(now: totalsNow).first?.longRemaining ?? 0) - 0.6) < 0.0001)
}

@Test func bankedResetSaysWhetherTheWeeklyResetComesFirst() {
    let reset = totalsNow.addingTimeInterval(48 * 3_600)
    let before = AccountTerms.weekResetRelation(expiresAt: totalsNow.addingTimeInterval(24 * 3_600), weekReset: reset, now: totalsNow)
    let after = AccountTerms.weekResetRelation(expiresAt: totalsNow.addingTimeInterval(72 * 3_600), weekReset: reset, now: totalsNow)
    #expect(before?.hasPrefix("Expires before week resets") == true)
    #expect(after?.hasPrefix("Week resets first") == true)
    #expect(AccountTerms.weekResetRelation(expiresAt: reset, weekReset: nil, now: totalsNow) == nil)
    // Only a real weekly window gets a week relation, and a saved one says so.
    let account = totalsOverview([("a", .openAI, 50, 48, 1.0, 0)]).accounts.first
    let week = account?.longWindow
    #expect(AccountTerms.weekResetRelation(expiresAt: totalsNow.addingTimeInterval(24 * 3_600), week: week, current: false, now: totalsNow)?
        .hasSuffix(AccountTerms.lastSeen) == true)
    #expect(AccountTerms.weekResetRelation(expiresAt: totalsNow, week: account?.shortWindow, now: totalsNow) == nil)
}

@Test func providerHuesAreDistinct() {
    #expect(Set(Provider.allCases.map(\.colorToken)).count == Provider.allCases.count)
}

// MARK: Horizon

@Test func horizonProjectsRunOutSpareAndTheEmptyGap() throws {
    // a: 20% left at 1%/h, reset in 100h: empty at 20h, empty 80h. b: 60% left at 0.5%/h, reset in 50h: 35% to spare.
    let overview = totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 40, 50, 0.5, 0), ("c", .anthropic, 10, 100, nil, 0)])
    let a = try #require(overview.accounts.first { $0.metadata.label == "a" }).horizon(now: totalsNow)
    #expect(a.runOutAt == totalsNow.addingTimeInterval(20 * 3_600) && a.spare == 0)
    #expect(abs((a.emptyFor ?? 0) - 80 * 3_600) < 1)
    #expect(AccountPaceText.span(a.emptyFor ?? 0) == "3½ days")
    let b = try #require(overview.accounts.first { $0.metadata.label == "b" }).horizon(now: totalsNow)
    #expect(b.runOutAt == nil && abs((b.spare ?? 0) - 0.35) < 0.0001)
    let c = try #require(overview.accounts.first { $0.metadata.label == "c" })
    #expect(c.horizon(now: totalsNow).spare == nil)
    #expect(AccountTerms.outcome(c, c.horizon(now: totalsNow), now: totalsNow).title == AccountTerms.measuring)
    let headline = overview.headline(now: totalsNow)
    #expect(headline.shortCount == 1 && headline.lastingCount == 1 && headline.measuringCount == 1)
    #expect(AccountTerms.headline(headline).lead == "1 account runs out before it resets.")
    #expect(AccountTerms.headline(headline).rest == "1 lasts to reset, 1 measuring.")
    #expect(overview.runningShort(now: totalsNow).map(\.account.metadata.label) == ["a"])
}

@Test func horizonHeadlineCountsOnlyCurrentAccountsAsFine() {
    let fine = totalsOverview([("a", .openAI, 10, 50, 0.1, 0), ("b", .anthropic, 10, 50, 0.1, 0)])
    #expect(AccountTerms.headline(fine.headline(now: totalsNow)).lead == "All 2 accounts last to their reset.")
    #expect(AccountTerms.compactHeadline(fine.headline(now: totalsNow)).lead == "All 2 last to reset.")
    // A reading 10 hours old is saved, not fine, and gets no projection.
    let saved = totalsOverview([("a", .openAI, 90, 100, 1.0, 0), ("b", .openAI, 10, 50, 0.1, 10)])
    let headline = saved.headline(now: totalsNow)
    #expect(headline.shortCount == 1 && headline.notCurrentCount == 1)
    #expect(AccountTerms.headline(headline).rest == "1 not current.")
    #expect(saved.accounts.last?.horizon(now: totalsNow).runOutAt == nil)
}

@Test func horizonGeometryDrawsTheSameShapeEverywhere() throws {
    let account = try #require(totalsOverview([("a", .openAI, 80, 100, 1.0, 0)]).accounts.first)
    let geometry = account.horizon(now: totalsNow).geometry(now: totalsNow)
    #expect(abs(geometry.startLevel - 0.2) < 0.0001 && geometry.fillEndLevel == 0)
    #expect(abs(geometry.fillEndX - 20.0 / 168) < 0.0001)
    #expect(abs((geometry.emptyRange?.upperBound ?? 0) - 100.0 / 168) < 0.0001)
    #expect(geometry.resetX == geometry.emptyRange?.upperBound)
}

@Test func horizonNeverReassuresPastWhatIsMeasured() {
    // One account lasts, one is still measuring: the lead must not say nothing runs out.
    let overview = totalsOverview([("a", .openAI, 10, 50, 0.1, 0), ("b", .openAI, 10, 50, nil, 0)])
    let sentence = AccountTerms.headline(overview.headline(now: totalsNow))
    #expect(sentence.lead == "1 of 2 accounts last to their reset.")
    #expect(sentence.rest == "1 measuring.")
    #expect(AccountTerms.compactHeadline(overview.headline(now: totalsNow)).lead == "1 of 2 last to reset.")
}

@Test func horizonCountsAnEmptyWeekAsRunningOutNow() throws {
    // 0% left with no burn after exhaustion: already out, not "fine".
    let account = try #require(totalsOverview([("a", .openAI, 100, 50, 0.0, 0)]).accounts.first)
    let horizon = account.horizon(now: totalsNow)
    #expect(horizon.runOutAt == totalsNow && horizon.runsOutBeforeReset)
}

@Test func providerLineKeepsAKnownRunOutWhileASiblingMeasures() throws {
    let total = try #require(totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 10, 50, nil, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(total.runningOutCount == 1)
    #expect(AccountTerms.providerSummary(total, now: totalsNow).isShort)
}

@Test func horizonWithoutAResetTimeIsNotKnownToLast() throws {
    // Burn is observed but the provider gave no reset time (reported on #722, 5943582956).
    let overview = totalsOverview([("a", .openAI, 20, .infinity, 0.4, 0)])
    let account = try #require(overview.accounts.first)
    let headline = overview.headline(now: totalsNow)
    #expect(headline.lastingCount == 0 && headline.measuringCount == 1)
    #expect(AccountTerms.headline(headline).lead != "Your account lasts to its reset.")
    #expect(AccountTerms.outcome(account, account.horizon(now: totalsNow), now: totalsNow).title == AccountTerms.resetUnknown)
}

// Horizon polish (#722 owner decision 2026-10-02): one alarm, provider-scoped widget warning, plain words.

@Test func horizonKeepsRowsAndProviderLinesCalmSoTheCalloutIsTheOneAlarm() throws {
    let overview = totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 40, 50, 0.1, 0)])
    let short = try #require(overview.runningShort(now: totalsNow).first)
    #expect(AccountAlarm.outcomeToken(short.account, short.horizon) == .primary)
    #expect(AccountAlarm.providerOutlookToken != AccountAlarm.token)
    for account in overview.accounts {
        #expect(AccountAlarm.outcomeToken(account, account.horizon(now: totalsNow)) != AccountAlarm.token)
    }
    // On the account's page the window fact is red only when the week's outcome is not already the alarm.
    #expect(!AccountAlarm.windowRunOutIsAlarm(short.horizon))
    let lasting = try #require(overview.accounts.first { !$0.horizon(now: totalsNow).runsOutBeforeReset })
    #expect(AccountAlarm.windowRunOutIsAlarm(lasting.horizon(now: totalsNow)))
}

@Test func widgetCardSaysOtherRunOutsApartFromTheShownAccount() throws {
    let total = try #require(totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 40, 50, 0.1, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(AccountTerms.othersRunOut(total, shownRunsOut: false) == "1 other runs out")
    #expect(AccountTerms.othersRunOut(total, shownRunsOut: true) == nil)
    let two = try #require(totalsOverview([("a", .openAI, 80, 100, 1.0, 0), ("b", .openAI, 85, 100, 1.0, 0), ("c", .openAI, 10, 50, 0.1, 0)])
        .providerTotals(now: totalsNow).first)
    #expect(AccountTerms.othersRunOut(two, shownRunsOut: false) == "2 others run out")
}

@Test func burnIsSaidInPlainWordsPerDay() throws {
    #expect(AccountTerms.burn(0.003) == "~7% a day")
    #expect(AccountTerms.burn(0.0001) == "<1% a day")
    #expect(AccountTerms.burn(0.06, windowDuration: 5 * 3_600) == "~6% an hour")
    let total = try #require(totalsOverview([("a", .openAI, 20, 100, 0.5, 0), ("b", .openAI, 40, 100, 0.5, 0)])
        .providerTotals(now: totalsNow).first)
    let facts = AccountTerms.providerSummary(total, now: totalsNow).facts
    #expect(!facts.contains("%/h") && facts.contains("a day"))
}
