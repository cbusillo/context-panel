import Foundation
import Testing

@testable import ContextPanelCore

private let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

@Test func forecastReportsSafeThroughResetWhenFastBurnFitsWithReserve() {
    let forecast = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(used: 20, limit: 100, resetsInHours: 4),
            now: now,
            standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 4),
            fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 10),
            reserveUnits: 10
        )
    )

    #expect(forecast.recommendation == .safeThroughReset)
    #expect(forecast.fastModeRunwayHours == 7)
    #expect(forecast.copy == "Fast mode looks safe through reset.")
}

@Test func forecastReportsLimitedFastModeRunwayWhenFastBurnDoesNotReachReset() {
    let forecast = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(used: 60, limit: 100, resetsInHours: 8),
            now: now,
            standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
            fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 15),
            reserveUnits: 10
        )
    )

    #expect(forecast.recommendation == .safeForLimitedTime)
    #expect(forecast.copy == "Fast mode safe for about 2h.")
}

@Test func forecastSavesFastModeWhenRunwayIsBelowMinimumWindow() {
    let forecast = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(used: 88, limit: 100, resetsInHours: 6),
            now: now,
            standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 1),
            fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 10),
            reserveUnits: 5,
            minimumSafeHours: 1
        )
    )

    #expect(forecast.recommendation == .saveFastMode)
    #expect(forecast.copy == "Fast mode will not last.")
}

@Test func forecastNeedsCalibrationWithoutResetOrFastBurnRate() {
    let forecast = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(used: 10, limit: 100, resetsInHours: nil),
            now: now,
            standardBurnRate: nil,
            fastBurnRate: nil
        )
    )

    #expect(forecast.recommendation == .needsCalibration)
    #expect(forecast.copy == "Needs calibration before fast mode.")
}

@Test func portfolioChoosesBestOpenAIAccountForFastMode() {
    let personal = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(accountName: "Personal", used: 80, limit: 100, resetsInHours: 12),
            now: now,
            standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
            fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 12),
            reserveUnits: 5
        )
    )
    let work = FastModeForecast(
        input: FastModeForecastInput(
            limit: openAILimit(accountName: "Work", used: 20, limit: 100, resetsInHours: 4),
            now: now,
            standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
            fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 12),
            reserveUnits: 5
        )
    )

    let portfolio = FastModePortfolioForecast(forecasts: [personal, work])

    #expect(portfolio.bestForecast?.accountName == "Work")
    #expect(portfolio.copy == "Fast mode looks safe through reset.")
}

@Test func capacityForecastSavesFastModeWhenWeeklyPoolCannotReachReset() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 94, limit: 100, resetsInHours: 96, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    #expect(forecast.recommendation == .saveFastMode)
    #expect(forecast.fastModeRunwayHours == 0)
    #expect(forecast.copy == "Use normal mode")
    #expect(forecast.detailCopy == "6% left · 2%/h observed")
    #expect(forecast.burnRateCopy == "2%/h observed")
    #expect(forecast.runwayCopy == "out 1m")
}

@Test func capacityForecastUsesPooledRemainingAcrossAccounts() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 90, limit: 100, resetsInHours: 24, windowLabel: "Weekly"),
            openAILimit(accountName: "Work", used: 1, limit: 100, resetsInHours: 24, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    #expect(forecast.remainingUnits == 109)
    #expect(forecast.totalUnits == 200)
    #expect(forecast.recommendation == .safeThroughReset)
    #expect(forecast.copy == "Use fast mode")
    #expect(forecast.detailCopy == "55% left · 1%/h observed")
}

@Test func capacityForecastDoesNotTreatOneLimitedAccountAsProviderLimited() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 100, limit: 100, resetsInHours: 72, windowLabel: "Weekly"),
            openAILimit(accountName: "Work", used: 2, limit: 100, resetsInHours: 168, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    #expect(forecast.remainingUnits == 98)
    #expect(forecast.recommendation == .saveFastMode)
    #expect(forecast.copy == "Use normal mode")
    #expect(forecast.detailCopy == "49% left · 1%/h observed")
    #expect(forecast.burnRateCopy == "1%/h observed")
    #expect(forecast.runwayCopy == "out 1d 22h")
}

@Test func capacityForecastUsesStaggeredResetBucketsBeforeSavingFastMode() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 100, limit: 100, resetsInHours: 2, windowLabel: "Weekly"),
            openAILimit(accountName: "Work", used: 50, limit: 100, resetsInHours: 168, windowLabel: "Weekly"),
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 8),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 20),
        reserveUnits: 6
    )

    #expect(forecast.remainingUnits == 50)
    #expect(forecast.recommendation == .safeThroughReset)
    #expect(forecast.runwayCopy == "lasts past reset in 2h")
}

@Test func capacityForecastStopsBeforeNextResetWhenBucketsCannotBridgeGap() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 100, limit: 100, resetsInHours: 24, windowLabel: "Weekly"),
            openAILimit(accountName: "Work", used: 95, limit: 100, resetsInHours: 168, windowLabel: "Weekly"),
        ],
        now: now,
        standardBurnRate: nil,
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 2),
        reserveUnits: 0
    )

    #expect(forecast.remainingUnits == 5)
    #expect(forecast.recommendation == .safeForLimitedTime)
    #expect(forecast.fastModeRunwayHours == 2.5)
    #expect(forecast.runwayCopy == "fast out 2.5h")
}

@Test func capacityPortfolioKeepsWeeklyAheadOfShorterOpenAIWindow() {
    let weekly = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 94, limit: 100, resetsInHours: 96, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 3),
        reserveUnits: 6
    )
    let fiveHour = FastModeCapacityForecast(
        limitID: "openai:fiveHour",
        accountName: "OpenAI 5-hour pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 20, limit: 100, resetsInHours: 4, windowLabel: "5-hour")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    let portfolio = FastModeCapacityPortfolioForecast(forecasts: [weekly, fiveHour])

    #expect(portfolio.bestForecast?.limitID == "openai:weekly")
    #expect(portfolio.copy == "Use normal mode")
}

@Test func openAIFastModeForecastHelperPrefersWeeklyAndLabelsGuardrail() throws {
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            openAILimit(accountName: "Personal", used: 35, limit: 100, resetsInHours: 120, windowLabel: "Weekly"),
            openAILimit(accountName: "Personal", used: 94, limit: 100, resetsInHours: 5, windowLabel: "5-hour"),
        ]
    )

    let portfolio = snapshot.mainLimitSummaries.openAIFastModeCapacityForecast(
        now: now,
        defaultStandardBurnRateUnitsPerHour: 2,
        fastModeMultiplier: 2,
        reserveUnits: 6
    )

    let best = try #require(portfolio.bestForecast)
    #expect(best.limitID == "openai:weekly")
    #expect(best.roleCopy == "weekly pool")
    #expect(portfolio.forecasts.map(\.roleCopy) == ["weekly pool", "5-hour guardrail"])
    #expect(portfolio.detailCopy.contains("weekly pool:") == false)
    #expect(portfolio.detailCopy.contains("5h guardrail:"))
}

@Test func openAIFastModeForecastHelperUsesSharedSettings() throws {
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [
            openAILimit(accountName: "Personal", used: 50, limit: 100, resetsInHours: 24, windowLabel: "Weekly"),
        ]
    )
    let settings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 1,
        fastModeMultiplier: 3,
        reserveUnits: 8,
        minimumSafeHours: 2
    )

    let forecast = try #require(snapshot.mainLimitSummaries.openAIFastModeCapacityForecast(
        now: now,
        settings: settings
    ).bestForecast)

    #expect(forecast.standardBurnRateUnitsPerHour == 1)
    #expect(forecast.fastBurnRateUnitsPerHour == 3)
    #expect(forecast.reserveUnits == 8)
}

@Test func fastModeForecastSettingsStoreRoundTripsSettings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FastModeForecastSettingsStore(
        settingsURL: directory.appending(path: "fast-mode-forecast-settings.json")
    )
    let settings = FastModeForecastSettings(
        defaultStandardBurnRateUnitsPerHour: 1.5,
        fastModeMultiplier: 2.5,
        reserveUnits: 7,
        minimumSafeHours: 1.25
    )

    try store.save(settings)

    #expect(store.exists)
    #expect(store.load() == settings)
}

@Test func resetPrimerSettingsSyncsConfiguredAccountsAndPreservesEnabledChoices() {
    var settings = ResetPrimerSettings(accountPreferences: [
        ResetPrimerAccountPreference(
            accountID: "openai-old",
            provider: .openAI,
            accountName: "Old OpenAI",
            isEnabled: true
        ),
        ResetPrimerAccountPreference(
            accountID: "openai-a",
            provider: .openAI,
            accountName: "Old Name",
            isEnabled: true
        ),
    ])
    let accounts = [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI A"
        ),
        LocalProviderAccountConfiguration(
            id: "claude-disabled",
            provider: .anthropic,
            connectorKind: .claudeLocalStatus,
            displayName: "Claude",
            isEnabled: false
        ),
    ]

    settings.syncAccounts(accounts)

    #expect(settings.accountPreferences.map(\.accountID) == ["claude-disabled", "openai-a"])
    #expect(settings.preference(for: "openai-a", provider: .openAI)?.accountName == "OpenAI A")
    #expect(settings.preference(for: "openai-a", provider: .openAI)?.isEnabled == true)
    #expect(settings.preference(for: "claude-disabled", provider: .anthropic)?.isEnabled == false)
}

@Test func resetPrimerSettingsSyncHandlesDuplicatePersistedAccountIDs() {
    var settings = ResetPrimerSettings(accountPreferences: [
        ResetPrimerAccountPreference(
            accountID: "openai-a",
            provider: .openAI,
            accountName: "OpenAI A",
            isEnabled: true
        ),
        ResetPrimerAccountPreference(
            accountID: "openai-a",
            provider: .openAI,
            accountName: "Duplicate OpenAI A",
            isEnabled: false
        ),
    ])
    settings.accountPreferences.append(ResetPrimerAccountPreference(
        accountID: "openai-a",
        provider: .openAI,
        accountName: "Manually Corrupted Duplicate",
        isEnabled: false
    ))
    let accounts = [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI A"
        ),
    ]

    settings.syncAccounts(accounts)

    #expect(settings.accountPreferences.count == 1)
    #expect(settings.preference(for: "openai-a", provider: .openAI)?.isEnabled == true)
    #expect(settings.preference(for: "openai-a", provider: .openAI)?.accountName == "OpenAI A")
}

@Test func resetPrimerSettingsStoreRoundTripsSettings() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ResetPrimerSettingsStore(
        settingsURL: directory.appending(path: "reset-primer-settings.json")
    )
    let settings = ResetPrimerSettings(
        isEnabled: true,
        delayMinutesAfterReset: 15,
        accountStaggerMinutes: 20,
        accountPreferences: [
            ResetPrimerAccountPreference(
                accountID: "openai-a",
                provider: .openAI,
                accountName: "OpenAI A",
                isEnabled: true
            )
        ]
    )

    try store.save(settings)

    #expect(store.exists)
    #expect(store.load() == settings)
}

@Test func resetPrimerSettingsStorePersistsSyncedAccountsForPlannerReloads() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ResetPrimerSettingsStore(
        settingsURL: directory.appending(path: "reset-primer-settings.json")
    )
    let accounts = [
        LocalProviderAccountConfiguration(
            id: "openai-a",
            provider: .openAI,
            connectorKind: .codexRateLimits,
            displayName: "OpenAI A"
        ),
    ]

    let synced = try store.loadSynced(accounts: accounts)

    #expect(synced.accountPreferences.map(\.accountID) == ["openai-a"])
    #expect(store.exists)
    #expect(store.load().accountPreferences.map(\.accountID) == ["openai-a"])
}

@Test func capacityForecastMeasuresBurnWhenNoObservedRateExists() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 52, limit: 100, resetsInHours: 96, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: nil,
        fastBurnRate: nil,
        reserveUnits: 6
    )

    #expect(forecast.recommendation == .needsCalibration)
    #expect(forecast.copy == "Measuring burn")
    #expect(forecast.burnRateCopy == "measuring burn")
    #expect(forecast.burnPaceCopy == "measuring burn")
}

@Test func capacityPoolIgnoresUnknownBucketsForNumericRunway() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai-unknown",
                accountName: "Unknown",
                label: "OpenAI Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: nil,
                limit: nil,
                resetsAt: now.addingTimeInterval(2 * 3_600),
                confidence: .unknown
            ),
            openAILimit(accountName: "Work", used: 10, limit: 100, resetsInHours: 24, windowLabel: "Weekly"),
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    #expect(forecast.remainingUnits == 90)
    #expect(forecast.totalUnits == 100)
    #expect(forecast.confidence == .unknown)
    #expect(forecast.recommendation == .safeForLimitedTime)
    #expect(forecast.fastModeRunwayHours == 21)
}

@Test func observedBurnRateUsesRollingHistoryIncludingIdleIntervals() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 10, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 12, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 12, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 1) < 0.0001)
    #expect(estimate.sampleCount == 3)
}

@Test func observedBurnRateSkipsIntervalsThatCrossResets() throws {
    let oldReset = now.addingTimeInterval(-90 * 60)
    let nextReset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 90, reset: oldReset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 4, reset: nextReset),
        storedOpenAIWeekly(savedAt: now, used: 6, reset: nextReset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 2) < 0.0001)
    #expect(estimate.sampleCount == 2)
}

@Test func observedBurnRateUsesSampleRelativeResetWhenResetIsNowInPast() throws {
    let historicalNow = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let reset = historicalNow.addingTimeInterval(90 * 60)
    let history = [
        storedOpenAIWeekly(savedAt: historicalNow, used: 80, reset: reset),
        storedOpenAIWeekly(savedAt: historicalNow.addingTimeInterval(2 * 3_600), used: 6, reset: reset.addingTimeInterval(7 * 24 * 3_600)),
        storedOpenAIWeekly(savedAt: historicalNow.addingTimeInterval(3 * 3_600), used: 8, reset: reset.addingTimeInterval(7 * 24 * 3_600)),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(
        current: current,
        history: history,
        now: historicalNow.addingTimeInterval(3 * 3_600),
        lookback: 4 * 3_600
    )
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 2) < 0.0001)
    #expect(estimate.sampleCount == 2)
}

private func openAILimit(
    accountName: String = "Personal",
    used: Int,
    limit: Int,
    resetsInHours: Double?,
    windowLabel: String? = nil
) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: "openai-\(accountName.lowercased())",
        accountName: accountName,
        label: "GPT-5 Thinking",
        windowLabel: windowLabel,
        unit: .percent,
        used: used,
        limit: limit,
        resetsAt: resetsInHours.map { now.addingTimeInterval($0 * 3_600) },
        confidence: .estimated
    )
}

private func storedOpenAIWeekly(savedAt: Date, used: Int, reset: Date) -> StoredUsageSnapshot {
    StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-personal",
                    accountName: "Personal",
                    label: "OpenAI Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: used,
                    limit: 100,
                    resetsAt: reset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                )
            ]
        )
    )
}
