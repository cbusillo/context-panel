@testable import ContextPanelCore
import Foundation
import Testing

@Test
func defaultAnswerKeepsOpenAIWeeklyPrimaryAndSeparatesClosestLimit() throws {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 7),
            limit(provider: .anthropic, window: .weekly, used: 77)
        )
    )

    #expect(selection.primary?.id == "openai:weekly")
    #expect(selection.closest?.id == "anthropic:weekly")
    #expect(selection.supportingSaved.first?.id == "openai:fiveHour")
    #expect(selection.compactSupportingLanes(maximumCount: 2).map(\.id) == [
        "anthropic:weekly",
        "openai:fiveHour",
    ])
}

@Test
func savedOrderCanChooseAnotherPrimary() throws {
    var preferences = WidgetDisplayPreferences.defaultPreferences
    let anthropicWeeklyIndex = try #require(preferences.mainLimits.firstIndex {
        $0.provider == .anthropic && $0.window == .weekly
    })
    preferences.moveMainLimits(fromOffsets: IndexSet(integer: anthropicWeeklyIndex), toOffset: 0)

    let selection = preferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 92),
            limit(provider: .anthropic, window: .weekly, used: 25)
        )
    )

    #expect(selection.primary?.id == "anthropic:weekly")
    #expect(selection.closest?.id == "openai:weekly")
}

@Test
func missingSavedPrimaryStaysUnknownInsteadOfJumping() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(limit(provider: .anthropic, window: .weekly, used: 40))
    )

    #expect(selection.primary?.id == "openai:weekly")
    #expect(selection.primary?.summary == nil)
    #expect(selection.closest == nil)
}

@Test
func healthyClosestRequiresTwentyPointDifference() {
    let nineteenPointDifference = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 30),
            limit(provider: .anthropic, window: .weekly, used: 49)
        )
    )
    let twentyPointDifference = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 30),
            limit(provider: .anthropic, window: .weekly, used: 50)
        )
    )

    #expect(nineteenPointDifference.closest == nil)
    #expect(twentyPointDifference.closest?.id == "anthropic:weekly")
}

@Test
func materialDifferenceDoesNotAdmitAValueJustBelowTwentyPoints() {
    let justBelow = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 0, limit: 2_000_000_000),
            limit(provider: .anthropic, window: .weekly, used: 399_999_999, limit: 2_000_000_000)
        )
    )
    let exact = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 0, limit: 2_000_000_000),
            limit(provider: .anthropic, window: .weekly, used: 400_000_000, limit: 2_000_000_000)
        )
    )

    #expect(justBelow.closest == nil)
    #expect(exact.closest?.id == "anthropic:weekly")
}

@Test
func closestDifferenceUsesUnroundedCapacity() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 305, limit: 1_000),
            limit(provider: .anthropic, window: .weekly, used: 500, limit: 1_000)
        )
    )

    #expect(selection.primary?.summary?.remainingCapacityRatio == 0.695)
    #expect(selection.closest == nil)
}

@Test
func closeCandidateWithMoreCapacityDoesNotReplaceWorsePrimary() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 95),
            limit(provider: .anthropic, window: .weekly, used: 85)
        )
    )

    #expect(selection.primary?.id == "openai:weekly")
    #expect(selection.closest == nil)
}

@Test
func closeCandidateCanAccompanyMissingStablePrimary() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(limit(provider: .anthropic, window: .weekly, used: 85))
    )

    #expect(selection.primary?.id == "openai:weekly")
    #expect(selection.primary?.summary == nil)
    #expect(selection.closest?.id == "anthropic:weekly")
}

@Test
func hiddenLimitCanStillSurfaceAsClosestWarning() {
    var preferences = WidgetDisplayPreferences.defaultPreferences
    preferences.setMainLimit(provider: .anthropic, window: .weekly, isVisible: false)

    let selection = preferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 10),
            limit(provider: .anthropic, window: .weekly, used: 85)
        )
    )

    #expect(!selection.saved.contains { $0.id == "anthropic:weekly" })
    #expect(selection.closest?.id == "anthropic:weekly")
}

@Test
func hidingEverySavedLimitDoesNotRestoreHiddenAnswers() {
    var preferences = WidgetDisplayPreferences.defaultPreferences
    for index in preferences.mainLimits.indices {
        preferences.mainLimits[index].isVisible = false
    }
    let availableSummaries = summaries(
        limit(provider: .openAI, window: .weekly, used: 20),
        limit(provider: .anthropic, window: .weekly, used: 90)
    )
    let selection = preferences.mainLimitAnswerSelection(from: availableSummaries)

    #expect(preferences.visibleMainLimitSummaries(from: availableSummaries).isEmpty)
    #expect(preferences.visibleMainLimitLanes(from: availableSummaries).isEmpty)
    #expect(selection.primary == nil)
    #expect(selection.saved.isEmpty)
    #expect(selection.closest == nil)
}

@Test
func providerScopedSelectionKeepsCouchModeWithinProvider() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 20),
            limit(provider: .openAI, window: .fiveHour, used: 82),
            limit(provider: .anthropic, window: .weekly, used: 95)
        ),
        provider: .openAI
    )

    #expect(selection.primary?.id == "openai:weekly")
    #expect(selection.closest?.id == "openai:fiveHour")
    #expect(selection.saved.allSatisfy { $0.provider == .openAI })
}

@Test
func providerScopedSelectionUsesExactTwentyPointBoundary() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 30),
            limit(provider: .openAI, window: .fiveHour, used: 50)
        ),
        provider: .openAI
    )

    #expect(selection.closest?.id == "openai:fiveHour")
}

@Test
func staleLimitDoesNotBecomeClosestCapacityWarning() {
    let selection = WidgetDisplayPreferences.defaultPreferences.mainLimitAnswerSelection(
        from: summaries(
            limit(provider: .openAI, window: .weekly, used: 20),
            limit(provider: .anthropic, window: .weekly, used: 95, status: .stale)
        )
    )

    #expect(selection.closest == nil)
}

private func summaries(_ limits: UsageLimit...) -> [MainLimitSummary] {
    UsageSnapshot(generatedAt: Date(timeIntervalSince1970: 1_700_000_000), limits: limits)
        .mainLimitSummaries
}

private func limit(
    provider: Provider,
    window: MainLimitWindow,
    used: Int,
    limit: Int = 100,
    status: UsageStatus? = nil
) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: "\(provider.rawValue)-account",
        accountName: provider.displayName,
        label: "\(provider.displayName) \(window.displayName)",
        windowLabel: window.displayName,
        unit: .percent,
        used: used,
        limit: limit,
        statusOverride: status
    )
}
