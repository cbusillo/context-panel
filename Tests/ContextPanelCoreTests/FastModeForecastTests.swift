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
    #expect(forecast.detailCopy == "6% left · 2%/h active")
    #expect(forecast.burnRateCopy == "2%/h active")
    #expect(forecast.runwayCopy == "normal lasts ~1m")
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
    #expect(forecast.detailCopy == "55% left · 2%/h active")
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
    #expect(forecast.detailCopy == "49% left · 2%/h active")
    #expect(forecast.burnRateCopy == "2%/h active")
    #expect(forecast.runwayCopy == "normal lasts ~1d 22h")
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
    #expect(forecast.runwayCopy == "fast lasts ~2.5h")
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
    #expect(portfolio.detailCopy.contains("5h:"))
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

@Test func backgroundRefreshSettingsClampsIntervalsAndRoundTrips() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackgroundRefreshSettingsStore(
        settingsURL: directory.appending(path: "background-refresh-settings.json")
    )
    var settings = BackgroundRefreshSettings(isEnabled: false, intervalMinutes: 1)

    #expect(settings.intervalMinutes == 5)
    #expect(settings.intervalSeconds == 300)
    settings.setIntervalMinutes(90)
    #expect(settings.intervalMinutes == 60)

    try store.save(settings)

    #expect(store.exists)
    #expect(store.load() == settings)
}

@Test func backgroundRefreshSettingsClampsPersistedIntervalsOnLoad() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsURL = directory.appending(path: "background-refresh-settings.json")
    let store = BackgroundRefreshSettingsStore(settingsURL: settingsURL)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("""
    {
      "schemaVersion": 1,
      "isEnabled": true,
      "intervalMinutes": 1
    }
    """.utf8).write(to: settingsURL)

    let settings = store.load()

    #expect(settings.intervalMinutes == 5)
    #expect(settings.intervalSeconds == 300)
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
    #expect(forecast.burnRateCopy == "pace unknown")
    #expect(forecast.burnPaceCopy == "pace unknown")
}

@Test func capacityForecastMeasuresBurnWhenPaceCannotBeComputedAtResetBoundary() {
    let forecast = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [
            openAILimit(accountName: "Personal", used: 30, limit: 100, resetsInHours: 0, windowLabel: "Weekly")
        ],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 4),
        reserveUnits: 6
    )

    #expect(forecast.burnPaceRatio == nil)
    #expect(forecast.burnPaceCopy == "pace unknown")
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

@Test func observedBurnRateUsesCurrentWindowPaceWhenItExceedsRecentAverage() throws {
    let reset = now.addingTimeInterval((7 * 24 - 2) * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 1, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 2, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 7, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 3.5) < 0.0001)
    #expect(estimate.sampleCount == 1)
}

@Test func observedBurnRateUsesAverageInsteadOfRoundedFastestTick() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-60 * 60), used: 0, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-50 * 60), used: 0, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-40 * 60), used: 1, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-30 * 60), used: 1, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 2, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 2) < 0.0001)
    #expect(estimate.sampleCount == 5)
}

@Test func observedBurnRateUsesRecentDrainWhenLongerAverageIsTooOptimistic() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-12 * 3_600), used: 20, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-8 * 3_600), used: 20, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-4 * 3_600), used: 20, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 28, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 36, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 4) < 0.0001)
    #expect(abs(estimate.observedDurationHours - 4) < 0.0001)
    #expect(estimate.sampleCount == 3)
}

@Test func observedBurnRatePreservesZeroBurnForIdleWindows() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-3 * 3_600), used: 12, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 12, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 12, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 12, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(estimate.unitsPerHour == 0)
    #expect(estimate.sampleCount == 4)
}

@Test func observedBurnRateUsesActiveAccountAverageForPooledLimits() throws {
    let activeReset = now.addingTimeInterval(7 * 24 * 3_600)
    let fullReset = now.addingTimeInterval(36 * 3_600)
    let history = [
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-3 * 3_600), activeUsed: 1, fullUsed: 100, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-2 * 3_600), activeUsed: 3, fullUsed: 100, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-1 * 3_600), activeUsed: 5, fullUsed: 100, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now, activeUsed: 5, fullUsed: 100, activeReset: activeReset, fullReset: fullReset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 4.0 / 3.0) < 0.0001)
    #expect(estimate.sampleCount == 8)
}

@Test func observedBurnRateAggregatesActivePooledAccountAverages() throws {
    let activeReset = now.addingTimeInterval(7 * 24 * 3_600)
    let fullReset = now.addingTimeInterval(36 * 3_600)
    let history = [
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-3 * 3_600), activeUsed: 1, fullUsed: 90, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-2 * 3_600), activeUsed: 3, fullUsed: 91, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now.addingTimeInterval(-1 * 3_600), activeUsed: 5, fullUsed: 92, activeReset: activeReset, fullReset: fullReset),
        storedOpenAIWeeklyAccounts(savedAt: now, activeUsed: 5, fullUsed: 93, activeReset: activeReset, fullReset: fullReset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - (7.0 / 3.0)) < 0.0001)
    #expect(estimate.sampleCount == 8)
}

@Test func observedBurnRateIgnoresAccountsExhaustedByLongerWindow() throws {
    let activeReset = now.addingTimeInterval(5 * 3_600)
    let weeklyReset = now.addingTimeInterval(7 * 24 * 3_600)
    let history = [
        storedOpenAIFiveHourWithWeeklyGate(savedAt: now.addingTimeInterval(-2 * 3_600), activeUsed: 1, fullUsed: 10, activeWeeklyUsed: 20, fullWeeklyUsed: 100, activeReset: activeReset, weeklyReset: weeklyReset),
        storedOpenAIFiveHourWithWeeklyGate(savedAt: now.addingTimeInterval(-1 * 3_600), activeUsed: 3, fullUsed: 30, activeWeeklyUsed: 21, fullWeeklyUsed: 100, activeReset: activeReset, weeklyReset: weeklyReset),
        storedOpenAIFiveHourWithWeeklyGate(savedAt: now, activeUsed: 5, fullUsed: 60, activeWeeklyUsed: 22, fullWeeklyUsed: 100, activeReset: activeReset, weeklyReset: weeklyReset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:fiveHour"])

    #expect(abs(estimate.unitsPerHour - 2) < 0.0001)
    #expect(estimate.sampleCount == 3)
}

@Test func capacityPortfolioDetailKeepsBurnRateWhenFiveHourGuardrailConstrainWeekly() throws {
    let weekly = FastModeCapacityForecast(
        limitID: "openai:weekly",
        accountName: "OpenAI Weekly pool",
        providerLimits: [openAILimit(accountName: "Personal", used: 94, limit: 100, resetsInHours: 96, windowLabel: "Weekly")],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 3),
        reserveUnits: 6
    )
    let fiveHour = FastModeCapacityForecast(
        limitID: "openai:fiveHour",
        accountName: "OpenAI 5-hour pool",
        providerLimits: [openAILimit(accountName: "Personal", used: 98, limit: 100, resetsInHours: 4, windowLabel: "5-hour")],
        now: now,
        standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
        fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 3),
        reserveUnits: 6
    )
    let portfolio = FastModeCapacityPortfolioForecast(forecasts: [weekly, fiveHour])

    #expect(portfolio.detailCopy.contains("2%/h active"))
    #expect(portfolio.detailCopy.contains("5h:"))
}

@Test func openAIFastModeForecastIgnoresFiveHourBucketsBlockedByWeeklyLimit() throws {
    let activeReset = now.addingTimeInterval(5 * 3_600)
    let weeklyReset = now.addingTimeInterval(7 * 24 * 3_600)
    let current = storedOpenAIFiveHourWithWeeklyGate(
        savedAt: now,
        activeUsed: 100,
        fullUsed: 10,
        activeWeeklyUsed: 20,
        fullWeeklyUsed: 100,
        activeReset: activeReset,
        weeklyReset: weeklyReset
    ).snapshot

    let portfolio = current.mainLimitSummaries.openAIFastModeCapacityForecast(
        now: now,
        observedBurnRates: [
            "openai:fiveHour": ObservedBurnRate(
                limitID: "openai:fiveHour",
                unitsPerHour: 2,
                observedDurationHours: 2,
                sampleCount: 3
            ),
            "openai:weekly": ObservedBurnRate(
                limitID: "openai:weekly",
                unitsPerHour: 2,
                observedDurationHours: 2,
                sampleCount: 3
            ),
        ],
        defaultStandardBurnRateUnitsPerHour: 2,
        fastModeMultiplier: 1,
        reserveUnits: 6,
        minimumSafeHours: 1
    )
    let fiveHour = try #require(portfolio.forecasts.first { $0.window == .fiveHour })

    #expect(fiveHour.remainingUnits == 0)
    #expect(fiveHour.recommendation == .limited)
    #expect(portfolio.detailCopy.contains("5h:"))
}

@Test func observedBurnRateAllowsConsistentlyUnknownResets() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 10, reset: reset, includeReset: false),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 11, reset: reset, includeReset: false),
        storedOpenAIWeekly(savedAt: now, used: 12, reset: reset, includeReset: false),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 1) < 0.0001)
}

private func storedOpenAIFiveHourWithWeeklyGate(
    savedAt: Date,
    activeUsed: Int,
    fullUsed: Int,
    activeWeeklyUsed: Int,
    fullWeeklyUsed: Int,
    activeReset: Date,
    weeklyReset: Date
) -> StoredUsageSnapshot {
    StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-active",
                    accountName: "Active",
                    label: "OpenAI 5-hour",
                    windowLabel: "5-hour",
                    unit: .percent,
                    used: activeUsed,
                    limit: 100,
                    resetsAt: activeReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-full",
                    accountName: "Full",
                    label: "OpenAI 5-hour",
                    windowLabel: "5-hour",
                    unit: .percent,
                    used: fullUsed,
                    limit: 100,
                    resetsAt: activeReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-active",
                    accountName: "Active",
                    label: "OpenAI Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: activeWeeklyUsed,
                    limit: 100,
                    resetsAt: weeklyReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-full",
                    accountName: "Full",
                    label: "OpenAI Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: fullWeeklyUsed,
                    limit: 100,
                    resetsAt: weeklyReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
            ]
        )
    )
}

@Test func observedBurnRateSkipsIntervalsThatCrossResets() throws {
    let oldReset = now.addingTimeInterval(-90 * 60)
    let nextReset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-3 * 3_600), used: 90, reset: oldReset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 4, reset: nextReset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 6, reset: nextReset),
        storedOpenAIWeekly(savedAt: now, used: 7, reset: nextReset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 1.5) < 0.0001)
    #expect(estimate.sampleCount == 3)
}

@Test func observedBurnRateRequiresMoreThanOneUsableInterval() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 10, reset: reset),
        storedOpenAIWeekly(savedAt: now, used: 12, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)

    #expect(estimates["openai:weekly"] == nil)
}

@Test func observedBurnRateRejectsAmbiguousResetBoundaries() throws {
    let reset = now.addingTimeInterval(96 * 3_600)
    let history = [
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-3 * 3_600), used: 8, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-2 * 3_600), used: 10, reset: reset),
        storedOpenAIWeekly(savedAt: now.addingTimeInterval(-1 * 3_600), used: 12, reset: reset, includeReset: false),
        storedOpenAIWeekly(savedAt: now, used: 14, reset: reset),
    ]
    let current = try #require(history.last?.snapshot)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(current: current, history: history, now: now)

    #expect(estimates["openai:weekly"] == nil)
}

@Test func observedBurnRateUsesSampleRelativeResetWhenResetIsNowInPast() throws {
    let historicalNow = Date(timeIntervalSinceReferenceDate: 700_000_000)
    let reset = historicalNow.addingTimeInterval(90 * 60)
    let history = [
        storedOpenAIWeekly(savedAt: historicalNow, used: 80, reset: reset),
        storedOpenAIWeekly(savedAt: historicalNow.addingTimeInterval(2 * 3_600), used: 6, reset: reset.addingTimeInterval(7 * 24 * 3_600)),
        storedOpenAIWeekly(savedAt: historicalNow.addingTimeInterval(3 * 3_600), used: 8, reset: reset.addingTimeInterval(7 * 24 * 3_600)),
        storedOpenAIWeekly(savedAt: historicalNow.addingTimeInterval(4 * 3_600), used: 9, reset: reset.addingTimeInterval(7 * 24 * 3_600)),
    ]
    let current = UsageSnapshot(generatedAt: historicalNow.addingTimeInterval(3 * 3_600), limits: history[2].snapshot.limits)

    let estimates = MainLimitBurnRateEstimator.observedBurnRates(
        current: current,
        history: history,
        now: historicalNow.addingTimeInterval(4 * 3_600),
        lookback: 5 * 3_600
    )
    let estimate = try #require(estimates["openai:weekly"])

    #expect(abs(estimate.unitsPerHour - 1.5) < 0.0001)
    #expect(estimate.sampleCount == 3)
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

private func storedOpenAIWeekly(savedAt: Date, used: Int, reset: Date, includeReset: Bool = true) -> StoredUsageSnapshot {
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
                    resetsAt: includeReset ? reset : nil,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                )
            ]
        )
    )
}

private func storedOpenAIWeeklyAccounts(
    savedAt: Date,
    activeUsed: Int,
    fullUsed: Int,
    activeReset: Date,
    fullReset: Date
) -> StoredUsageSnapshot {
    StoredUsageSnapshot(
        savedAt: savedAt,
        snapshot: UsageSnapshot(
            generatedAt: savedAt,
            limits: [
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-active",
                    accountName: "Active",
                    label: "OpenAI Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: activeUsed,
                    limit: 100,
                    resetsAt: activeReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .openAI,
                    accountID: "openai-full",
                    accountName: "Full",
                    label: "OpenAI Weekly",
                    windowLabel: "Weekly",
                    unit: .percent,
                    used: fullUsed,
                    limit: 100,
                    resetsAt: fullReset,
                    lastUpdatedAt: savedAt,
                    confidence: .observed
                ),
            ]
        )
    )
}
