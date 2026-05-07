import Foundation

public enum UsageMode: String, Codable, Equatable, Sendable {
    case standard
    case fast
}

public struct BurnRate: Codable, Equatable, Sendable {
    public let mode: UsageMode
    public let unitsPerHour: Double

    public init(mode: UsageMode, unitsPerHour: Double) {
        precondition(unitsPerHour >= 0, "unitsPerHour must not be negative")

        self.mode = mode
        self.unitsPerHour = unitsPerHour
    }
}

public struct FastModeForecastInput: Codable, Equatable, Sendable {
    public let limit: UsageLimit
    public let now: Date
    public let standardBurnRate: BurnRate?
    public let fastBurnRate: BurnRate?
    public let reserveUnits: Double
    public let minimumSafeHours: Double

    public init(
        limit: UsageLimit,
        now: Date,
        standardBurnRate: BurnRate?,
        fastBurnRate: BurnRate?,
        reserveUnits: Double = 5,
        minimumSafeHours: Double = 1
    ) {
        precondition(reserveUnits >= 0, "reserveUnits must not be negative")
        precondition(minimumSafeHours >= 0, "minimumSafeHours must not be negative")

        self.limit = limit
        self.now = now
        self.standardBurnRate = standardBurnRate
        self.fastBurnRate = fastBurnRate
        self.reserveUnits = reserveUnits
        self.minimumSafeHours = minimumSafeHours
    }
}

public enum FastModeRecommendation: String, Codable, Equatable, Sendable {
    case safeThroughReset
    case safeForLimitedTime
    case saveFastMode
    case needsCalibration
    case limited
}

public struct FastModeForecast: Codable, Equatable, Sendable {
    public let limitID: UsageLimit.ID
    public let accountName: String
    public let recommendation: FastModeRecommendation
    public let confidence: UsageConfidence
    public let remainingUnits: Double?
    public let hoursUntilReset: Double?
    public let fastModeRunwayHours: Double?
    public let projectedFastUseUntilReset: Double?
    public let reserveUnits: Double

    public var copy: String {
        switch recommendation {
        case .safeThroughReset:
            "Fast mode looks safe through reset."
        case .safeForLimitedTime:
            if let fastModeRunwayHours {
                "Fast mode safe for about \(Self.format(hours: fastModeRunwayHours))."
            } else {
                "Fast mode safe for a limited time."
            }
        case .saveFastMode:
            "Save fast mode before reset."
        case .needsCalibration:
            "Needs calibration before fast mode."
        case .limited:
            "Limited until reset."
        }
    }

    public init(input: FastModeForecastInput) {
        limitID = input.limit.id
        accountName = input.limit.accountName
        confidence = input.limit.confidence
        reserveUnits = input.reserveUnits

        let remaining = input.limit.remaining.map(Double.init)
        remainingUnits = remaining
        if let resetsAt = input.limit.resetsAt {
            hoursUntilReset = max(resetsAt.timeIntervalSince(input.now) / 3_600, 0)
        } else {
            hoursUntilReset = nil
        }

        guard input.limit.status != .limited else {
            recommendation = .limited
            fastModeRunwayHours = 0
            projectedFastUseUntilReset = 0
            return
        }

        guard
            let remaining,
            let fastRate = input.fastBurnRate?.unitsPerHour,
            fastRate > 0,
            let hoursUntilReset
        else {
            recommendation = .needsCalibration
            fastModeRunwayHours = nil
            projectedFastUseUntilReset = nil
            return
        }

        let usableRemaining = max(remaining - input.reserveUnits, 0)
        let runway = usableRemaining / fastRate
        let projected = fastRate * hoursUntilReset

        fastModeRunwayHours = runway
        projectedFastUseUntilReset = projected

        if usableRemaining <= 0 {
            recommendation = .saveFastMode
        } else if projected <= usableRemaining {
            recommendation = .safeThroughReset
        } else if runway >= input.minimumSafeHours {
            recommendation = .safeForLimitedTime
        } else {
            recommendation = .saveFastMode
        }
    }

    private static func format(hours: Double) -> String {
        if hours < 1 {
            let minutes = max(Int((hours * 60).rounded()), 1)
            return "\(minutes)m"
        }
        if hours < 10 {
            let rounded = (hours * 2).rounded() / 2
            if rounded.rounded() == rounded {
                return "\(Int(rounded))h"
            }
            return "\(rounded)h"
        }
        return "\(Int(hours.rounded()))h"
    }
}

public struct FastModePortfolioForecast: Codable, Equatable, Sendable {
    public let forecasts: [FastModeForecast]

    public init(forecasts: [FastModeForecast]) {
        self.forecasts = forecasts
    }

    public var bestForecast: FastModeForecast? {
        forecasts.sorted { lhs, rhs in
            lhs.rank > rhs.rank
        }.first
    }

    public var copy: String {
        bestForecast?.copy ?? "Add an OpenAI account to forecast fast mode."
    }
}

extension FastModeForecast {
    fileprivate var rank: Double {
        let runway = fastModeRunwayHours ?? -1
        switch recommendation {
        case .safeThroughReset:
            return 1_000 + runway
        case .safeForLimitedTime:
            return 500 + runway
        case .saveFastMode:
            return 100 + runway
        case .needsCalibration:
            return 10
        case .limited:
            return 0
        }
    }
}
