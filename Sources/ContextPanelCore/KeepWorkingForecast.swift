import Foundation

public enum KeepWorkingPaceBand: String, Codable, Equatable, Sendable {
    case idle
    case under
    case on
    case over
    case unknown

    public init(paceRatio: Double?) {
        guard let paceRatio, paceRatio.isFinite else {
            self = .unknown
            return
        }
        if paceRatio <= 0.05 {
            self = .idle
        } else if paceRatio <= 0.9 {
            self = .under
        } else if paceRatio <= 1.1 {
            self = .on
        } else {
            self = .over
        }
    }

    public var copy: String {
        switch self {
        case .idle:
            "idle"
        case .under:
            "under pace"
        case .on:
            "on pace"
        case .over:
            "over pace"
        case .unknown:
            "measuring"
        }
    }
}

public enum KeepWorkingDateDensity: Sendable {
    case full
    case compact
}

public struct KeepWorkingLimitRow: Identifiable, Equatable, Sendable {
    public let provider: Provider
    public let window: MainLimitWindow
    public let remainingPercent: Int?
    public let resetsAt: Date?
    public let accountCount: Int
    public let status: UsageStatus

    public var id: String {
        "\(provider.rawValue):\(window.rawValue)"
    }

    public init(summary: MainLimitSummary) {
        provider = summary.provider
        window = summary.window
        remainingPercent = summary.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        resetsAt = summary.resetsAt
        accountCount = summary.accountCount
        status = summary.status
    }
}

public struct KeepWorkingForecast: Equatable, Sendable {
    private let presentationDate: Date
    public let activeWindow: MainLimitWindow?
    public let isLimited: Bool
    public let remainingPercent: Int?
    public let accountCount: Int
    public let nextResetAt: Date?
    public let recentPercentPerHour: Double?
    public let requiredPercentPerHour: Double?
    public let recentObservationHours: Double?
    public let recentUsedPercent: Double?
    public let paceBand: KeepWorkingPaceBand
    public let projectedRunLowAt: Date?
    public let projectedRunLowInHours: Double?
    public let rows: [KeepWorkingLimitRow]

    public var accountCopy: String {
        "\(accountCount) \(accountCount == 1 ? "account" : "accounts")"
    }

    public var windowCopy: String? {
        activeWindow?.displayName
    }

    public init(
        summaries: [MainLimitSummary],
        observedBurnRates: [String: ObservedBurnRate],
        settings: FastModeForecastSettings,
        now: Date = Date()
    ) {
        presentationDate = now
        let portfolio = summaries.openAIFastModeCapacityForecast(
            now: now,
            observedBurnRates: observedBurnRates,
            settings: settings
        )
        let weeklyForecast = portfolio.bestForecast
        let fiveHourGuardrail = portfolio.forecasts.first { $0.window == .fiveHour }
        let forecast: FastModeCapacityForecast?
        let fiveHourWillRunOutBeforeReset = fiveHourGuardrail.flatMap { guardrail in
            guard guardrail.standardBurnRateObservedDurationHours != nil,
                  let runway = guardrail.standardModeRunwayHours,
                  let reset = guardrail.hoursUntilReset
            else {
                return false
            }
            return runway < reset
        } ?? false
        if let fiveHourGuardrail,
           fiveHourGuardrail.recommendation == .limited || fiveHourWillRunOutBeforeReset {
            forecast = fiveHourGuardrail
        } else {
            forecast = weeklyForecast
        }
        let forecastSummary = forecast.flatMap { forecast in
            summaries.first { $0.id == forecast.limitID }
        }
        let observedRate = forecast.flatMap { observedBurnRates[$0.limitID] }

        activeWindow = forecast?.window
        isLimited = forecast?.recommendation == .limited
        remainingPercent = forecastSummary?.remainingCapacityRatio.map { Int(($0 * 100).rounded()) }
        accountCount = forecast?.accountCount ?? 0
        nextResetAt = forecast?.nextResetAt
        let recentRate = observedRate == nil ? nil : forecast?.standardBurnRatePercentPerHour
        recentPercentPerHour = recentRate
        requiredPercentPerHour = recentRate == nil ? nil : forecast?.requiredBurnRatePercentPerHour
        recentObservationHours = observedRate?.observedDurationHours
        recentUsedPercent = forecast?.accountCount == 1 ? Self.guardLetPositive(observedRate?.observedDurationHours).flatMap { duration in
            recentRate.map { $0 * duration }
        } : nil
        paceBand = KeepWorkingPaceBand(paceRatio: recentRate == nil ? nil : forecast?.burnPaceRatio)
        if recentRate != nil,
           let runway = forecast?.standardModeRunwayHours,
           let reset = forecast?.hoursUntilReset,
           runway < reset {
            projectedRunLowAt = now.addingTimeInterval(runway * 3_600)
            projectedRunLowInHours = runway
        } else {
            projectedRunLowAt = nil
            projectedRunLowInHours = nil
        }

        rows = Provider.allCases.flatMap { provider in
            [MainLimitWindow.fiveHour, .weekly].compactMap { window in
                summaries.first(where: { $0.provider == provider && $0.window == window })
                    .map(KeepWorkingLimitRow.init)
            }
        }
    }

    public var promptCopy: String {
        "Can I keep working normally?"
    }

    public func resetCopy(density: KeepWorkingDateDensity) -> String? {
        guard let nextResetAt else { return nil }
        return "Resets \(Self.dateText(nextResetAt, density: density))"
    }

    public func outcomeCopy(
        density: KeepWorkingDateDensity,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String? {
        if isLimited {
            return activeWindow == .fiveHour ? "5-hour limit reached" : "Limit reached"
        }
        if activeWindow == .fiveHour, let projectedRunLowInHours {
            return "May run low in ~\(Self.durationText(hours: projectedRunLowInHours))"
        }
        if let projectedRunLowAt {
            if calendar.isDate(projectedRunLowAt, inSameDayAs: presentationDate) {
                return "May run low today"
            }
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: presentationDate),
               calendar.isDate(projectedRunLowAt, inSameDayAs: tomorrow) {
                return "May run low tomorrow"
            }
            return "May run low \(Self.weekdayText(projectedRunLowAt, density: density, calendar: calendar))"
        }
        switch paceBand {
        case .under:
            return "Lasts past reset"
        case .on:
            return "On pace for reset"
        case .idle:
            return "Usage is quiet"
        case .over:
            return "May run low before reset"
        case .unknown:
            return "Measuring recent use"
        }
    }

    public func recentUsedCopy(density: KeepWorkingDateDensity) -> String? {
        guard let recentUsedPercent, let recentObservationHours else { return nil }
        let used = Int(recentUsedPercent.rounded())
        let hours = max(Int(recentObservationHours.rounded()), 1)
        switch density {
        case .full:
            return "~\(used)% across the last \(hours)h"
        case .compact:
            return "~\(used)% in \(hours)h"
        }
    }

    public func paceCopy(density: KeepWorkingDateDensity) -> String? {
        guard let recentPercentPerHour, let requiredPercentPerHour else { return nil }
        let recent = Self.rateText(recentPercentPerHour)
        let required = Self.rateText(requiredPercentPerHour)
        switch density {
        case .full:
            return "Recent \(recent)/h · \(required)/h to last until reset"
        case .compact:
            return "Need \(required)/h\nRecent \(recent)/h"
        }
    }

    private static func guardLetPositive(_ value: Double?) -> Double? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func weekdayText(
        _ date: Date,
        density: KeepWorkingDateDensity,
        calendar: Calendar
    ) -> String {
        let locale = calendar.locale ?? .autoupdatingCurrent
        let style = Date.FormatStyle(
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )
        return switch density {
        case .full:
            date.formatted(style.weekday(.wide))
        case .compact:
            date.formatted(style.weekday(.abbreviated))
        }
    }

    private static func dateText(_ date: Date, density: KeepWorkingDateDensity) -> String {
        switch density {
        case .full:
            date.formatted(.dateTime.weekday(.wide).hour().minute())
        case .compact:
            date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
    }

    private static func durationText(hours: Double) -> String {
        if hours < 1 {
            return "\(max(Int((hours * 60).rounded()), 1))m"
        }
        return "\(max(Int(hours.rounded(.up)), 1))h"
    }

    public static func rateText(_ rate: Double) -> String {
        String(format: rate < 10 ? "%.1f%%" : "%.0f%%", rate)
    }
}

public extension WidgetSnapshot {
    func keepWorkingForecast(presentationDate: Date) -> KeepWorkingForecast {
        KeepWorkingForecast(
            summaries: usageSnapshot.mainLimitSummaries,
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings,
            now: presentationDate
        )
    }
}
