import Foundation
import Testing
@testable import ContextPanelCore

@Test func resetCreditGuidanceOmitsNoObservationAndExplicitZero() {
    let now = resetGuidanceDate()
    let noObservation = resetGuidanceReport(now: now, count: nil)
    let explicitZero = resetGuidanceReport(now: now, count: 0)
    let limits = [resetGuidanceLimit(accountID: "account-a", window: .weekly, used: 20, resetsAt: now.addingTimeInterval(86_400))]

    #expect(ResetCreditGuidanceAdvisor.guidance(report: noObservation, limits: limits, now: now) == nil)
    #expect(ResetCreditGuidanceAdvisor.guidance(report: explicitZero, limits: limits, now: now) == nil)
}

@Test func resetCreditGuidanceKeepsCountOnlyTimingUnknown() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(now: now, count: 2, coverage: .countOnly)
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(3 * 60 * 60)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.resetCredits.availableCount == 2)
    #expect(guidance.state == .refresh(.expiryUnknown))
    #expect(guidance.recommendationTitle == "Timing unknown")
}

@Test func resetCreditGuidanceRejectsStaleAndFailedObservations() throws {
    let now = resetGuidanceDate()
    let staleObservedAt = now.addingTimeInterval(-(SnapshotFreshness.appMaximumAge + 1))
    let stale = resetGuidanceReport(
        now: staleObservedAt,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let failed = resetGuidanceReport(
        now: now,
        generatedAt: now.addingTimeInterval(60),
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400),
        status: .failure
    )
    let weekly = resetGuidanceLimit(
        accountID: stale.accountID,
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(3 * 60 * 60)
    )

    let staleGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: stale, limits: [weekly], now: now))
    let failedGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: failed, limits: [weekly], now: now))

    #expect(staleGuidance.state == .refresh(.staleObservation))
    #expect(failedGuidance.state == .refresh(.staleObservation))
}

@Test func resetCreditGuidanceConsidersWeeklyLimitedAccountNow() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(2 * 86_400)
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(3 * 60 * 60)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.state == .considerUsingNow)
    #expect(guidance.compactActionText == "consider using now")
}

@Test func resetCreditGuidanceHoldsForImminentNaturalResetBoundary() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(ResetCreditGuidanceAdvisor.imminentNaturalResetInterval)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.state == .hold(.naturalResetImminent))
}

@Test func resetCreditGuidanceActsImmediatelyJustBeyondImminentBoundary() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(ResetCreditGuidanceAdvisor.imminentNaturalResetInterval + 1)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.state == .considerUsingNow)
}

@Test func resetCreditGuidanceHoldsForFiveHourOnlyPressure() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 20,
        resetsAt: now.addingTimeInterval(3 * 86_400)
    )
    let fiveHour = resetGuidanceLimit(
        accountID: report.accountID,
        window: .fiveHour,
        used: 100,
        resetsAt: now.addingTimeInterval(2 * 60 * 60)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(
        report: report,
        limits: [weekly, fiveHour],
        now: now
    ))

    #expect(guidance.state == .hold(.fiveHourOnlyPressure))
}

@Test func resetCreditGuidanceConsidersKnownExpiryOnlyUnderWeeklyPressure() throws {
    let now = resetGuidanceDate()
    let expiry = now.addingTimeInterval(2 * 86_400)
    let report = resetGuidanceReport(now: now, count: 2, coverage: .partial, expiry: expiry)
    let closeWeekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 85,
        resetsAt: now.addingTimeInterval(4 * 86_400)
    )
    let healthyWeekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 20,
        resetsAt: now.addingTimeInterval(4 * 86_400)
    )

    let pressured = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [closeWeekly], now: now))
    let healthy = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [healthyWeekly], now: now))

    #expect(pressured.state == .considerBefore(expiry))
    #expect(pressured.compactActionText?.hasPrefix("consider before ") == true)
    #expect(pressured.compactActionText?.contains(pressured.accountName) == false)
    #expect(healthy.state == .hold(.weeklyCapacityHealthy))
}

@Test func resetCreditGuidanceHoldsWhenWeeklyResetPrecedesExpiry() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(4 * 86_400)
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 85,
        resetsAt: now.addingTimeInterval(2 * 86_400)
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.state == .hold(.naturalResetBeforeExpiry))
}

@Test func resetCreditGuidanceHoldsWhenWeeklyResetEqualsExpiry() throws {
    let now = resetGuidanceDate()
    let resetAndExpiry = now.addingTimeInterval(2 * 86_400)
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: resetAndExpiry
    )
    let weekly = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 85,
        resetsAt: resetAndExpiry
    )

    let guidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [weekly], now: now))

    #expect(guidance.state == .hold(.naturalResetBeforeExpiry))
}

@Test func resetCreditGuidanceRefreshesUnknownWeeklyTiming() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let missingReset = resetGuidanceLimit(
        accountID: report.accountID,
        window: .weekly,
        used: 100,
        resetsAt: nil
    )

    let missingLimitGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(report: report, limits: [], now: now))
    let missingResetGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(
        report: report,
        limits: [missingReset],
        now: now
    ))

    #expect(missingLimitGuidance.state == .refresh(.weeklyLimitUnknown))
    #expect(missingResetGuidance.state == .refresh(.naturalResetUnknown))
}

@Test func resetCreditGuidanceRefreshesInconsistentAndElapsedObservations() throws {
    let now = resetGuidanceDate()
    let inconsistent = resetGuidanceReport(
        now: now,
        generatedAt: now.addingTimeInterval(2),
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let elapsed = resetGuidanceReport(
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now
    )
    let weekly = resetGuidanceLimit(
        accountID: "account-a",
        window: .weekly,
        used: 100,
        resetsAt: now.addingTimeInterval(3 * 60 * 60)
    )

    let inconsistentGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(
        report: inconsistent,
        limits: [weekly],
        now: now
    ))
    let elapsedGuidance = try #require(ResetCreditGuidanceAdvisor.guidance(
        report: elapsed,
        limits: [weekly],
        now: now
    ))

    #expect(inconsistentGuidance.state == .refresh(.inconsistentObservation))
    #expect(elapsedGuidance.state == .refresh(.expiryElapsed))
}

@Test func resetCreditGuidanceCopyRemainsAdvisoryAndReadOnly() throws {
    let now = resetGuidanceDate()
    let report = resetGuidanceReport(
        now: now,
        count: 2,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let states: [ResetCreditGuidanceState] = [
        .hold(.weeklyCapacityHealthy),
        .hold(.fiveHourOnlyPressure),
        .hold(.naturalResetImminent),
        .hold(.naturalResetBeforeExpiry),
        .considerUsingNow,
        .considerBefore(now.addingTimeInterval(86_400)),
        .refresh(.staleObservation),
        .refresh(.inconsistentObservation),
        .refresh(.expiryUnknown),
        .refresh(.expiryElapsed),
        .refresh(.weeklyLimitUnknown),
        .refresh(.naturalResetUnknown),
    ]
    let forbidden = ["redeem", "consume", "guarantee", "payment", "purchase", "will reset"]

    for state in states {
        let guidance = ProviderResetCreditGuidance(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID,
            accountName: report.accountName,
            resetCredits: try #require(report.resetCredits),
            weeklyResetsAt: now.addingTimeInterval(4 * 60 * 60),
            state: state
        )
        let copy = [
            guidance.recommendationTitle,
            guidance.recommendationDetail(now: now),
            guidance.compactActionText ?? "",
        ].joined(separator: " ").lowercased()

        for phrase in forbidden {
            #expect(!copy.contains(phrase), "Reset-credit guidance must remain advisory: \(phrase)")
        }
    }
}

@Test func resetCreditGuidanceRanksAccountsDeterministically() throws {
    let now = resetGuidanceDate()
    let beforeSooner = resetGuidanceReport(
        accountID: "account-a",
        accountName: "Alpha",
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let beforeLater = resetGuidanceReport(
        accountID: "account-b",
        accountName: "Beta",
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(2 * 86_400)
    )
    let useNow = resetGuidanceReport(
        accountID: "account-c",
        accountName: "Gamma",
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(3 * 86_400)
    )
    let limits = [
        resetGuidanceLimit(accountID: "account-a", window: .weekly, used: 85, resetsAt: now.addingTimeInterval(4 * 86_400)),
        resetGuidanceLimit(accountID: "account-b", window: .weekly, used: 85, resetsAt: now.addingTimeInterval(4 * 86_400)),
        resetGuidanceLimit(accountID: "account-c", window: .weekly, used: 100, resetsAt: now.addingTimeInterval(4 * 60 * 60)),
    ]

    let primary = try #require(ResetCreditGuidanceAdvisor.primaryActionableGuidance(
        reports: [beforeLater, useNow, beforeSooner],
        limits: limits,
        now: now
    ))
    let expiryPrimary = try #require(ResetCreditGuidanceAdvisor.primaryActionableGuidance(
        reports: [beforeLater, beforeSooner],
        limits: limits,
        now: now
    ))

    #expect(primary.accountID == "account-c")
    #expect(expiryPrimary.accountID == "account-a")
}

@Test func resetCreditGuidanceKeepsMultiAccountLanesIndependent() {
    let now = resetGuidanceDate()
    let first = resetGuidanceReport(
        accountID: "account-a",
        accountName: "Alpha",
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let second = resetGuidanceReport(
        accountID: "account-b",
        accountName: "Beta",
        now: now,
        count: 2,
        coverage: .complete,
        expiry: now.addingTimeInterval(2 * 86_400)
    )
    let guidance = ResetCreditGuidanceAdvisor.guidance(
        reports: [second, first],
        limits: [
            resetGuidanceLimit(accountID: "account-a", window: .weekly, used: 100, resetsAt: now.addingTimeInterval(3 * 60 * 60)),
            resetGuidanceLimit(accountID: "account-b", window: .weekly, used: 20, resetsAt: now.addingTimeInterval(3 * 86_400)),
        ],
        now: now
    )

    #expect(guidance.map(\.accountID) == ["account-a", "account-b"])
    #expect(guidance.map(\.resetCredits.availableCount) == [1, 2])
    #expect(guidance.map(\.state) == [.considerUsingNow, .hold(.weeklyCapacityHealthy)])
}

@Test func resetCreditGuidanceKeepsResolvedAccountsUnderSharedConfigurationDistinct() throws {
    let now = resetGuidanceDate()
    let firstReport = resetGuidanceReport(
        accountID: "resolved-a",
        configuredAccountID: "configured-openai",
        accountName: "Account A",
        now: now,
        count: 1,
        coverage: .complete,
        expiry: now.addingTimeInterval(86_400)
    )
    let secondReport = resetGuidanceReport(
        accountID: "resolved-b",
        configuredAccountID: "configured-openai",
        accountName: "Account B",
        now: now,
        count: 2,
        coverage: .complete,
        expiry: now.addingTimeInterval(2 * 86_400)
    )

    let guidance = ResetCreditGuidanceAdvisor.guidance(
        reports: [secondReport, firstReport],
        limits: [
            resetGuidanceLimit(
                accountID: "resolved-a",
                configuredAccountID: "configured-openai",
                window: .weekly,
                used: 100,
                resetsAt: now.addingTimeInterval(3 * 60 * 60)
            ),
            resetGuidanceLimit(
                accountID: "resolved-b",
                configuredAccountID: "configured-openai",
                window: .weekly,
                used: 20,
                resetsAt: now.addingTimeInterval(3 * 86_400)
            ),
        ],
        now: now
    )

    #expect(guidance.map(\.accountID) == ["resolved-a", "resolved-b"])
    #expect(guidance.map(\.resetCredits.availableCount) == [1, 2])
    #expect(guidance.map(\.state) == [.considerUsingNow, .hold(.weeklyCapacityHealthy)])
}

private func resetGuidanceDate() -> Date {
    Date(timeIntervalSince1970: 1_800_000_000)
}

private func resetGuidanceReport(
    accountID: String = "account-a",
    configuredAccountID: String? = nil,
    accountName: String = "Account A",
    now: Date,
    generatedAt: Date? = nil,
    count: Int?,
    coverage: ProviderResetCreditCoverage = .countOnly,
    expiry: Date? = nil,
    status: UsageStatus = .healthy
) -> StoredProviderReport {
    StoredProviderReport(
        provider: .openAI,
        accountID: accountID,
        configuredAccountID: configuredAccountID,
        accountName: accountName,
        generatedAt: generatedAt ?? now,
        resetCredits: count.map {
            ProviderResetCreditSummary(
                availableCount: $0,
                observedAt: now,
                coverage: coverage,
                earliestKnownExpiry: expiry
            )
        },
        status: status,
        errorMessage: status == .failure ? "refresh failed" : nil
    )
}

private func resetGuidanceLimit(
    accountID: String,
    configuredAccountID: String? = nil,
    window: MainLimitWindow,
    used: Int,
    resetsAt: Date?
) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: accountID,
        configuredAccountID: configuredAccountID,
        accountName: accountID,
        label: window.displayName,
        windowLabel: window.displayName,
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: resetsAt,
        lastUpdatedAt: resetGuidanceDate(),
        confidence: .observed
    )
}
