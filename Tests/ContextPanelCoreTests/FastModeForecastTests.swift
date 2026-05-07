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
    #expect(forecast.copy == "Save fast mode before reset.")
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

private func openAILimit(
    accountName: String = "Personal",
    used: Int,
    limit: Int,
    resetsInHours: Double?
) -> UsageLimit {
    UsageLimit(
        provider: .openAI,
        accountID: "openai-\(accountName.lowercased())",
        accountName: accountName,
        label: "GPT-5 Thinking",
        unit: .percent,
        used: used,
        limit: limit,
        resetsAt: resetsInHours.map { now.addingTimeInterval($0 * 3_600) },
        confidence: .estimated
    )
}
