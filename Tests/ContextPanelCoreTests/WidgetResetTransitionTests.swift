import Foundation
import Testing
@testable import ContextPanelCore

let resetTransitionNow = Date(timeIntervalSince1970: 1_800_000_000)

func resetTransitionSnapshot(provider: Provider = .openAI, secondUsed: Int = 20,
                                 firstExpiry: TimeInterval = 3 * 86_400,
                                 secondExpiry: TimeInterval = 2 * 86_400,
                                 secondState: AccountCapacityState? = nil,
                                 refillInterval: TimeInterval = 4 * 86_400) -> WidgetSnapshot {
    let now = resetTransitionNow
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

@Test func widgetSchedulesTheIndependentExpiryPromptBoundary() {
    let snapshot = resetTransitionSnapshot(firstExpiry: 30 * 3_600)
    let boundary = resetTransitionNow.addingTimeInterval(30 * 3_600 - ResetAssessment.expiringWithin)
    #expect(snapshot.resetCreditSurfaceTransitionDates(now: resetTransitionNow).contains(boundary))
}

@Test(arguments: [Provider.openAI, .anthropic])
func widgetSchedulesLossOfResetValueWithinFreshReading(provider: Provider) {
    let thresholdHours = provider == .openAI
        ? ResetAssessment.outOfQuotaThreshold * 7 * 24 / 100
        : ResetAssessment.outOfQuotaThreshold / ResetAssessment.claudeDefaultRate
    let snapshot = resetTransitionSnapshot(provider: provider, secondUsed: 100,
                                           refillInterval: thresholdHours * 3_600 + 60)
    let afterCrossing = resetTransitionNow.addingTimeInterval(120)
    #expect(snapshot.resetCreditSurfaceTransitionDates(now: resetTransitionNow).contains {
        $0 > resetTransitionNow && $0 < afterCrossing
    })
}
