import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelWidgetUI

let windowResetNow = Date(timeIntervalSince1970: 1_800_000_000)

func windowResetSnapshot(provider: Provider = .openAI, secondUsed: Int = 20,
                                 firstExpiry: TimeInterval = 3 * 86_400,
                                 secondExpiry: TimeInterval = 2 * 86_400,
                                 secondState: AccountCapacityState? = nil,
                                 refillInterval: TimeInterval = 4 * 86_400) -> WidgetSnapshot {
    let now = windowResetNow
    let ids = ["empty", "use-last"]
    return WidgetSnapshot(state: .ready, generatedAt: now,
        limits: zip(ids, [100, secondUsed]).map { id, used in
            UsageLimit(provider: provider, accountID: id, accountName: id, label: "Weekly",
                       windowLabel: "weekly", unit: .percent, used: used, limit: 100,
                       resetsAt: now.addingTimeInterval(refillInterval), lastUpdatedAt: now, confidence: .observed)
        }, reports: zip(ids, [firstExpiry, secondExpiry]).map { id, expiry in
            StoredProviderReport(provider: provider, accountID: id, accountName: id, generatedAt: now,
                resetCredits: ProviderResetCreditSummary(availableCount: 1, observedAt: now, coverage: .complete,
                                                        earliestKnownExpiry: now.addingTimeInterval(expiry)),
                status: .healthy, errorMessage: nil)
        }, status: .limited, message: "Current", accountDisplayMetadata: ids.map { id in
            AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(provider, id), configurationID: id,
                                   provider: provider, label: id, showInWidgets: id == "empty",
                                   useLast: id == "use-last", readState: id == "use-last" ? secondState : nil)
        })
}

@Test(arguments: [Provider.openAI, .anthropic])
func windowWidgetHoldsWhenHiddenUseLastAccountHasQuota(provider: Provider) throws {
    let snapshot = windowResetSnapshot(provider: provider)
    let summary = try #require(snapshot.resetCreditSurfaceSummary(now: windowResetNow))
    #expect(summary.accountCount == 2)
    #expect(summary.primaryActionableGuidance == nil)
    let deadline = try #require(summary.primaryDeadlineGuidance)
    #expect(!deadline.state.isActionable)
    #expect(deadline.resetCredits.earliestKnownExpiry == windowResetNow.addingTimeInterval(2 * 86_400))
    let assessment = try #require(snapshot.accountOverview(now: windowResetNow).accounts.first {
        $0.id == AccountDisplayMetadata.safeID(provider, deadline.accountID)
    }?.resetAssessment)
    #expect(deadline.recommendationTitle == assessment.title)
    #expect(deadline.recommendationDetail(now: windowResetNow) == assessment.detail)
}

@Test(arguments: [Provider.openAI, .anthropic])
func windowWidgetSelectsSharedSoonestResetWhenProviderEmpty(provider: Provider) throws {
    let snapshot = windowResetSnapshot(provider: provider, secondUsed: 100)
    let guidance = try #require(snapshot.primaryActionableResetCreditGuidance(now: windowResetNow))
    let recommended = snapshot.accountOverview(now: windowResetNow).accounts.compactMap(\.resetAssessment).filter(\.recommended)
    #expect(recommended.count == 1)
    #expect(AccountDisplayMetadata.safeID(provider, guidance.accountID) == recommended.first?.accountID)
    #expect(guidance.accountID == "use-last")
    #expect(guidance.recommendationDetail(now: windowResetNow) == recommended.first?.detail)
    #expect(URLComponents(url: guidance.widgetDeepLinkURL, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "account" }?.value == guidance.accountID)
}

@Test(arguments: [Provider.openAI, .anthropic])
func windowWidgetPreservesIndependentWorthwhileExpiryPrompt(provider: Provider) throws {
    let snapshot = windowResetSnapshot(provider: provider, firstExpiry: 12 * 3_600)
    let guidance = try #require(snapshot.primaryActionableResetCreditGuidance(now: windowResetNow))
    #expect(guidance.accountID == "empty")
    #expect(snapshot.accountOverview(now: windowResetNow).accounts.first?.resetAssessment?.trigger == .expiring)
}

@Test(arguments: [AccountCapacityState.unknown, .stale, .unavailable])
func windowWidgetCannotProveProviderEmptyFromDegradedSibling(state: AccountCapacityState) throws {
    let snapshot = windowResetSnapshot(secondUsed: 100, secondState: state)
    #expect(snapshot.primaryActionableResetCreditGuidance(now: windowResetNow) == nil)
    let deadline = try #require(snapshot.resetCreditSurfaceSummary(now: windowResetNow)?.primaryDeadlineGuidance)
    #expect(deadline.state == .refresh(.assessmentUnavailable))
    #expect(deadline.recommendationDetail(now: windowResetNow).contains("current reading"))
}

@Test func windowWidgetSchedulesTheIndependentExpiryPromptBoundary() {
    let snapshot = windowResetSnapshot(firstExpiry: 30 * 3_600)
    let boundary = windowResetNow.addingTimeInterval(30 * 3_600 - ResetAssessment.expiringWithin)
    #expect(snapshot.resetCreditSurfaceTransitionDates(now: windowResetNow).contains(boundary))
}

@Test func windowWidgetDoesNotRecommendLowValueOpenAIReset() throws {
    let snapshot = windowResetSnapshot(secondUsed: 100, refillInterval: 2 * 3_600)
    let summary = try #require(snapshot.resetCreditSurfaceSummary(now: windowResetNow))
    #expect(summary.accountCount == 2)
    #expect(summary.primaryActionableGuidance == nil)
    let deadline = try #require(summary.primaryDeadlineGuidance)
    #expect(deadline.recommendationTitle == snapshot.accountOverview(now: windowResetNow).accounts
        .first { $0.id == AccountDisplayMetadata.safeID(.openAI, deadline.accountID) }?.resetAssessment?.title)
}

@Test(arguments: [Provider.openAI, .anthropic])
func windowWidgetSchedulesLossOfResetValueWithinFreshReading(provider: Provider) throws {
    let thresholdHours = provider == .openAI
        ? ResetAssessment.outOfQuotaThreshold * 7 * 24 / 100
        : ResetAssessment.outOfQuotaThreshold / ResetAssessment.claudeDefaultRate
    let snapshot = windowResetSnapshot(provider: provider, secondUsed: 100,
                                       refillInterval: thresholdHours * 3_600 + 60)
    #expect(snapshot.primaryActionableResetCreditGuidance(now: windowResetNow) != nil)
    let afterCrossing = windowResetNow.addingTimeInterval(120)
    #expect(snapshot.primaryActionableResetCreditGuidance(now: afterCrossing) == nil)
    #expect(snapshot.resetCreditSurfaceTransitionDates(now: windowResetNow).contains {
        $0 > windowResetNow && $0 < afterCrossing
    })
}
