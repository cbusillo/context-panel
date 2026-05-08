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

@Test func capacityPortfolioKeepsWeeklyAheadOfShorterOpenAIWindow() {
    let weekly = FastModeCapacityForecast(
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
