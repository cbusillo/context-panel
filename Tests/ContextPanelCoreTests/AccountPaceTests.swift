import Foundation
import Testing

@testable import ContextPanelCore

private let paceNow = Date(timeIntervalSince1970: 1_790_000_000)

private func paceOverview(weeklyUsed: Int = 85, weeklyResetHours: Double = 120, sampleCount: Int = 24,
                          unitsPerHour: Double = 0.45, label: String = "Weekly",
                          observedAt: Date = paceNow) -> AccountOverview {
    let weekly = UsageLimit(provider: .openAI, accountID: "a", accountName: "n", label: label, windowLabel: label,
        unit: .percent, used: weeklyUsed, limit: 100, resetsAt: paceNow.addingTimeInterval(weeklyResetHours * 3_600),
        lastUpdatedAt: observedAt, confidence: .observed)
    let fiveHour = UsageLimit(provider: .openAI, accountID: "a", accountName: "n", label: "5-hour", windowLabel: "5-hour",
        unit: .percent, used: 10, limit: 100, resetsAt: paceNow.addingTimeInterval(4 * 3_600),
        lastUpdatedAt: observedAt, confidence: .observed)
    let report = StoredProviderReport(provider: .openAI, accountID: "a", accountName: "n", generatedAt: observedAt,
        resetCredits: nil, status: .healthy, errorMessage: nil)
    return AccountOverview(snapshot: UsageSnapshot(generatedAt: observedAt, limits: [weekly, fiveHour]), reports: [report],
        now: paceNow, accountBurnRates: ["a": [weekly.id: ObservedBurnRate(limitID: weekly.id, unitsPerHour: unitsPerHour,
            observedDurationHours: 6, sampleCount: sampleCount)]])
}

@Test func evenPaceMarkIsRemainingTimeOverWindowLength() throws {
    let account = try #require(paceOverview().accounts.first)
    let weekly = try #require(account.longWindow)
    #expect(abs((weekly.evenPaceRemaining(now: paceNow) ?? 0) - 120.0 / 168.0) < 0.0001)
    #expect(account.shortWindow?.label == "5-hour")
}

@Test func runOutAppearsOnlyBeforeTheReset() throws {
    let tight = try #require(paceOverview().accounts.first)
    let runOut = try #require(tight.earliestRunOut(now: paceNow))
    #expect(abs(runOut.date.timeIntervalSince(paceNow) - 15 / 0.45 * 3_600) < 1)
    #expect(abs((tight.paceRatio(now: paceNow) ?? 0) - 0.45 / (15.0 / 120.0)) < 0.0001)

    let slow = try #require(paceOverview(unitsPerHour: 0.1).accounts.first)
    #expect(slow.earliestRunOut(now: paceNow) == nil)
}

@Test func windowAverageFallbackIsNotPresentedAsObservedBurn() throws {
    let account = try #require(paceOverview(sampleCount: 0).accounts.first)
    #expect(account.longWindow?.burnFractionPerHour == nil)
    #expect(account.earliestRunOut(now: paceNow) == nil)
}

@Test func savedDataGetsNoPaceOrRunOut() throws {
    let account = try #require(paceOverview(observedAt: paceNow.addingTimeInterval(-6 * 3_600)).accounts.first)
    #expect(!account.isReliable)
    #expect(account.paceRatio(now: paceNow) == nil)
    #expect(account.earliestRunOut(now: paceNow) == nil)
}

@Test func unnamedWindowLengthGetsNoEvenPaceMark() throws {
    let account = try #require(paceOverview(label: "Model capacity").accounts.first)
    #expect(account.longWindow?.duration == nil)
    #expect(account.longWindow?.evenPaceRemaining(now: paceNow) == nil)
}

@Test func shortLabelsKeepSiblingsDistinct() {
    let metadata = ["Claude primary", "Claude backup", "work@example.invalid"].enumerated().map { index, label in
        AccountDisplayMetadata(id: "id\(index)", configurationID: "id\(index)", provider: .anthropic, label: label)
    }
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: paceNow, limits: []), reports: [],
        metadata: metadata, now: paceNow)
    #expect(overview.shortLabels == ["id0": "primary", "id1": "backup", "id2": "work"])
}

@Test func nextWeeksSameWeekdayHasAnUnambiguousLocalCalendarDate() {
    let zone = TimeZone(secondsFromGMT: 0)!
    let calendar = Calendar(identifier: .gregorian)
    let now = ContextPanelDateFormatting.date(from: "2026-10-07T10:00:00Z")!
    let reset = ContextPanelDateFormatting.date(from: "2026-10-14T08:30:00Z")!
    let result = AccountPaceText.when(reset, now: now, calendar: calendar, locale: Locale(identifier: "en_US_POSIX"), timeZone: zone)
    #expect(result.contains("Oct 14"))
    #expect(result.contains("8:30"))
    #expect(!result.contains("Wed"))
}
@Test func compactEmailNamesRetainTheDomainWhenLocalPartsCollide() {
    let metadata = ["chris@work.invalid", "chris@home.invalid"].enumerated().map {
        AccountDisplayMetadata(id: "id\($0.offset)", configurationID: "id\($0.offset)", provider: .openAI, label: $0.element)
    }
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: paceNow, limits: []), reports: [], metadata: metadata, now: paceNow)
    #expect(Set(overview.shortLabels.values).count == 2)
}

@Test func savedBankedDeadlinesKeepTheirLastSeenQualifier() {
    let deadline = AccountOverview.Deadline(accountID: "a", provider: .openAI, label: "Synthetic", expiresAt: paceNow.addingTimeInterval(60), observedAt: paceNow, state: .stale, ordinal: 0)
    #expect(AccountTerms.deadlineLabel(deadline) == deadline.label + " · " + AccountTerms.lastSeen)
}
