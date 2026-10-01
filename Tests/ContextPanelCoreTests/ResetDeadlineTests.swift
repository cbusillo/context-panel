import Foundation
import Testing
@testable import ContextPanelCore

@Test func resetDeadlinesIncludeLocalDateAndMinuteInBothDensities() throws {
    let date = try #require(ContextPanelDateFormatting.date(from: "2026-10-01T00:03:59Z"))
    let pacific = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let utc = try #require(TimeZone(secondsFromGMT: 0))
    for compact in [false, true] {
        let local = ContextPanelDateFormatting.resetDeadline(date, compact: compact, locale: Locale(identifier: "en_US"), timeZone: pacific)
        let universal = ContextPanelDateFormatting.resetDeadline(date, compact: compact, locale: Locale(identifier: "en_US"), timeZone: utc)
        #expect(local.contains("Sep 30"))
        #expect(local.contains("5:03"))
        #expect(universal.contains("Oct 1"))
        #expect(universal.contains("12:03"))
        #expect(!local.contains(":59"))
    }
}

@Test func nextResetDeadlineIncludesOtherProvidersWithoutOpenAIAdvice() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let deadlines = [now.addingTimeInterval(60), now.addingTimeInterval(120)]
    let summary = ProviderResetCreditSummary(availableCount: 2, observedAt: now, coverage: .complete, knownExpiries: deadlines)
    let report = StoredProviderReport(provider: .anthropic, accountID: "local", accountName: "Local Claude",
        generatedAt: now, resetCredits: summary, status: .healthy, errorMessage: nil)
    let surface = try #require(ResetCreditSurfaceAdvisor.widgetSummary(reports: [report], limits: [], now: now))
    #expect(surface.primaryActionableGuidance == nil)
    #expect(surface.primaryDeadlineGuidance?.provider == .anthropic)
    #expect(surface.primaryDeadlineGuidance?.resetCredits.earliestKnownExpiry == deadlines.first)
    let transitions = ResetCreditSurfaceAdvisor.glanceTransitionDates(reports: [report], limits: [], now: now)
    #expect(deadlines.allSatisfy(transitions.contains))
    #expect(ResetCreditSurfaceAdvisor.widgetSummary(reports: [report], limits: [], now: deadlines.last!) == nil)
}

@Test func expiredResetOffersStopCountingExactlyAtTheirDeadlines() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiry = now.addingTimeInterval(60)
    let summary = ProviderResetCreditSummary(availableCount: 3, observedAt: now.addingTimeInterval(-30),
        coverage: .complete, knownExpiries: [now, now, expiry])
    let current = summary.presented(at: now)
    #expect(current.availableCount == 1)
    #expect(current.knownExpiries == [expiry])
    #expect(current.earliestKnownExpiry == expiry)
    #expect(current.coverage == .complete)
    #expect(current.observedAt == summary.observedAt)
    let expired = summary.presented(at: expiry)
    #expect(expired.availableCount == 0)
    #expect(expired.knownExpiries.isEmpty)
    #expect(expired.earliestKnownExpiry == nil)
    #expect(summary.availableCount == 3)
}

@Test func expiredKnownResetDoesNotInventDeadlinesForUnknownOffers() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let legacy = ProviderResetCreditSummary(availableCount: 3, observedAt: now,
        coverage: .partial, earliestKnownExpiry: now)
    let current = legacy.presented(at: now)
    #expect(current.availableCount == 2)
    #expect(current.coverage == .countOnly)
    #expect(current.knownExpiries.isEmpty)
    #expect(current.earliestKnownExpiry == nil)
}
