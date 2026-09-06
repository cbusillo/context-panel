import Foundation
import Testing

@testable import ContextPanelCore

private let keepWorkingNow = Date(timeIntervalSinceReferenceDate: 900_000_000)

@Test func keepWorkingForecastPoolsOpenAIAccountsAndTracksRecentUsage() throws {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [
            limit(provider: .openAI, accountID: "personal", used: 42, window: "Weekly", resetInHours: 105),
            limit(provider: .openAI, accountID: "work", used: 42, window: "Weekly", resetInHours: 105),
            limit(provider: .openAI, accountID: "overflow", used: 42, window: "Weekly", resetInHours: 105),
            limit(provider: .openAI, accountID: "personal", used: 0, window: "5-hour", resetInHours: 2),
            limit(provider: .anthropic, accountID: "claude", used: 6, window: "5-hour", resetInHours: 3),
            limit(provider: .anthropic, accountID: "claude", used: 11, window: "Weekly", resetInHours: 120),
            limit(provider: .google, accountID: "gemini", used: 1, window: "5-hour", resetInHours: 5),
            limit(provider: .google, accountID: "gemini", used: 9, window: "Weekly", resetInHours: 72),
        ]
    )
    let weekly = try #require(snapshot.mainLimitSummaries.first {
        $0.provider == .openAI && $0.window == .weekly
    })

    let forecast = KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [
            weekly.id: ObservedBurnRate(
                limitID: weekly.id,
                unitsPerHour: 2.4,
                observedDurationHours: 6.25,
                sampleCount: 2
            ),
        ],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.remainingPercent == 58)
    #expect(forecast.activeWindow == .weekly)
    #expect(!forecast.isLimited)
    #expect(forecast.accountCount == 3)
    #expect(forecast.recentUsedPercent == nil)
    #expect(forecast.paceBand == .over)
    #expect(forecast.projectedRunLowAt != nil)
    #expect(forecast.outcomeCopy(density: .full)?.hasPrefix("May run low") == true)
    #expect(forecast.rows.count == 6)
    #expect(forecast.rows.map(\.provider) == [.openAI, .openAI, .anthropic, .anthropic, .google, .google])
}

@Test func keepWorkingForecastSurfacesExhaustedFiveHourGuardrail() throws {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [
            limit(provider: .openAI, accountID: "personal", used: 20, window: "Weekly", resetInHours: 96),
            limit(provider: .openAI, accountID: "personal", used: 100, window: "5-hour", resetInHours: 2),
        ]
    )
    let forecast = KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [:],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.activeWindow == .fiveHour)
    #expect(forecast.isLimited)
    #expect(forecast.remainingPercent == 0)
    #expect(forecast.outcomeCopy(density: .full) == "5-hour limit reached")
    #expect(forecast.paceCopy(density: .full) == nil)
}

@Test func keepWorkingForecastUsesRelativeTimeForFiveHourRunLowWarning() throws {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [
            limit(provider: .openAI, accountID: "personal", used: 20, window: "Weekly", resetInHours: 96),
            limit(provider: .openAI, accountID: "personal", used: 80, window: "5-hour", resetInHours: 5),
        ]
    )
    let summaries = snapshot.mainLimitSummaries
    let weekly = try #require(summaries.first { $0.window == .weekly })
    let fiveHour = try #require(summaries.first { $0.window == .fiveHour })
    let forecast = KeepWorkingForecast(
        summaries: summaries,
        observedBurnRates: [
            weekly.id: ObservedBurnRate(
                limitID: weekly.id,
                unitsPerHour: 0.5,
                observedDurationHours: 8,
                sampleCount: 3
            ),
            fiveHour.id: ObservedBurnRate(
                limitID: fiveHour.id,
                unitsPerHour: 10,
                observedDurationHours: 2,
                sampleCount: 3
            ),
        ],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.activeWindow == .fiveHour)
    #expect(!forecast.isLimited)
    #expect(forecast.outcomeCopy(density: .full) == "May run low in ~2h")
}

@Test func keepWorkingForecastUsesFullAndCompactWeekdayCopy() throws {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [limit(provider: .openAI, accountID: "personal", used: 42, window: "Weekly", resetInHours: 105)]
    )
    let weekly = try #require(snapshot.mainLimitSummaries.first)
    let forecast = KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [
            weekly.id: ObservedBurnRate(limitID: weekly.id, unitsPerHour: 0.8, observedDurationHours: 24, sampleCount: 2),
        ],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.resetCopy(density: .full)?.hasPrefix("Resets ") == true)
    #expect(forecast.resetCopy(density: .compact)?.hasPrefix("Resets ") == true)
}

@Test func keepWorkingForecastUsesTodayForSameDayRunLowInBothDensities() throws {
    let calendar = forecastCalendar(timeZone: "America/New_York")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12)))
    let forecast = weeklyForecast(now: now, used: 90, unitsPerHour: 10, resetInHours: 48)

    #expect(forecast.outcomeCopy(density: .full, calendar: calendar) == "May run low today")
    #expect(forecast.outcomeCopy(density: .compact, calendar: calendar) == "May run low today")
}

@Test func keepWorkingForecastUsesTomorrowAcrossMidnightInBothDensities() throws {
    let calendar = forecastCalendar(timeZone: "America/New_York")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 23, minute: 45)))
    let forecast = weeklyForecast(now: now, used: 90, unitsPerHour: 10, resetInHours: 48)

    #expect(forecast.outcomeCopy(density: .full, calendar: calendar) == "May run low tomorrow")
    #expect(forecast.outcomeCopy(density: .compact, calendar: calendar) == "May run low tomorrow")
}

@Test func keepWorkingForecastKeepsLocalizedWeekdayForLaterRunLow() throws {
    let calendar = forecastCalendar(timeZone: "Asia/Kolkata")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 0, minute: 30)))
    let forecast = weeklyForecast(now: now, used: 28, unitsPerHour: 1, resetInHours: 120)
    let projected = try #require(forecast.projectedRunLowAt)
    let style = Date.FormatStyle(
        locale: calendar.locale ?? .autoupdatingCurrent,
        calendar: calendar,
        timeZone: calendar.timeZone
    )
    let fullWeekday = projected.formatted(style.weekday(.wide))
    let compactWeekday = projected.formatted(style.weekday(.abbreviated))

    #expect(calendar.component(.hour, from: projected) == 0)
    #expect(fullWeekday == "Monday")
    #expect(compactWeekday == "Mon")
    #expect(forecast.outcomeCopy(density: .full, calendar: calendar) == "May run low \(fullWeekday)")
    #expect(forecast.outcomeCopy(density: .compact, calendar: calendar) == "May run low \(compactWeekday)")
}

@Test func keepWorkingForecastUsesCalendarDayAcrossDSTTransition() throws {
    let calendar = forecastCalendar(timeZone: "America/New_York")
    let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 30)))
    let forecast = weeklyForecast(now: now, used: 90, unitsPerHour: 20, resetInHours: 48)

    #expect(forecast.projectedRunLowAt.map { calendar.component(.hour, from: $0) } == 3)
    #expect(forecast.outcomeCopy(density: .full, calendar: calendar) == "May run low today")
    #expect(forecast.outcomeCopy(density: .compact, calendar: calendar) == "May run low today")

    // A fixed 24-hour addition would skip the next calendar day at this boundary.
    let lateSaturday = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 23, minute: 30)))
    let tomorrow = weeklyForecast(now: lateSaturday, used: 80, unitsPerHour: 10, resetInHours: 48)
    #expect(tomorrow.outcomeCopy(density: .full, calendar: calendar) == "May run low tomorrow")
    #expect(tomorrow.outcomeCopy(density: .compact, calendar: calendar) == "May run low tomorrow")
}

@Test func keepWorkingForecastDoesNotPresentPlanningDefaultAsRecentPace() throws {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [limit(provider: .openAI, accountID: "personal", used: 42, window: "Weekly", resetInHours: 105)]
    )
    let forecast = KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [:],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.remainingPercent == 58)
    #expect(forecast.recentPercentPerHour == nil)
    #expect(forecast.requiredPercentPerHour == nil)
    #expect(forecast.projectedRunLowAt == nil)
    #expect(forecast.paceBand == .unknown)
}

@Test func keepWorkingForecastLeavesNonOpenAIForecastUnavailableButKeepsScanRows() {
    let snapshot = UsageSnapshot(
        generatedAt: keepWorkingNow,
        limits: [
            limit(provider: .anthropic, accountID: "claude", used: 10, window: "Weekly", resetInHours: 48),
            limit(provider: .google, accountID: "gemini", used: 5, window: "5-hour", resetInHours: 4),
        ]
    )
    let forecast = KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [:],
        settings: .defaultSettings,
        now: keepWorkingNow
    )

    #expect(forecast.remainingPercent == nil)
    #expect(forecast.accountCount == 0)
    #expect(forecast.paceBand == .unknown)
    #expect(forecast.rows.count == 2)
}

private func limit(
    provider: Provider,
    accountID: String,
    used: Int,
    window: String,
    resetInHours: Double,
    now: Date = keepWorkingNow
) -> UsageLimit {
    UsageLimit(
        provider: provider,
        accountID: accountID,
        accountName: accountID,
        label: "\(provider.displayName) \(window)",
        windowLabel: window,
        unit: .percent,
        used: used,
        limit: 100,
        resetsAt: now.addingTimeInterval(resetInHours * 3_600),
        confidence: .observed
    )
}

private func weeklyForecast(
    now: Date,
    used: Int,
    unitsPerHour: Double,
    resetInHours: Double
) -> KeepWorkingForecast {
    let snapshot = UsageSnapshot(
        generatedAt: now,
        limits: [limit(
            provider: .openAI,
            accountID: "personal",
            used: used,
            window: "Weekly",
            resetInHours: resetInHours,
            now: now
        )]
    )
    let weekly = snapshot.mainLimitSummaries[0]
    return KeepWorkingForecast(
        summaries: snapshot.mainLimitSummaries,
        observedBurnRates: [weekly.id: ObservedBurnRate(
            limitID: weekly.id,
            unitsPerHour: unitsPerHour,
            observedDurationHours: 2,
            sampleCount: 2
        )],
        settings: FastModeForecastSettings(reserveUnits: 0),
        now: now
    )
}

private func forecastCalendar(timeZone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    if let timeZone = TimeZone(identifier: timeZone) {
        calendar.timeZone = timeZone
    }
    return calendar
}
