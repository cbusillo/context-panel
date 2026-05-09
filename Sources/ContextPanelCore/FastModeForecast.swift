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

public struct FastModeForecastSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var defaultStandardBurnRateUnitsPerHour: Double?
    public var fastModeMultiplier: Double
    public var reserveUnits: Double
    public var minimumSafeHours: Double

    public init(
        defaultStandardBurnRateUnitsPerHour: Double? = 2,
        fastModeMultiplier: Double = 2,
        reserveUnits: Double = 6,
        minimumSafeHours: Double = 1
    ) {
        precondition(defaultStandardBurnRateUnitsPerHour.map { $0 >= 0 } ?? true, "defaultStandardBurnRateUnitsPerHour must not be negative")
        precondition(fastModeMultiplier >= 0, "fastModeMultiplier must not be negative")
        precondition(reserveUnits >= 0, "reserveUnits must not be negative")
        precondition(minimumSafeHours >= 0, "minimumSafeHours must not be negative")

        schemaVersion = 1
        self.defaultStandardBurnRateUnitsPerHour = defaultStandardBurnRateUnitsPerHour
        self.fastModeMultiplier = fastModeMultiplier
        self.reserveUnits = reserveUnits
        self.minimumSafeHours = minimumSafeHours
    }

    public static var defaultSettings: FastModeForecastSettings {
        FastModeForecastSettings()
    }
}

public struct FastModeForecastSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: settingsURL.path)
    }

    public func load() -> FastModeForecastSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> FastModeForecastSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                FastModeForecastSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else {
                return nil
            }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: FastModeForecastSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
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
            "Fast mode will not last."
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
        if hours < 24 {
            return "\(Int(hours.rounded()))h"
        }
        let roundedHours = Int(hours.rounded())
        let days = roundedHours / 24
        let remainingHours = roundedHours % 24
        if remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
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

public struct FastModeCapacityForecast: Codable, Equatable, Sendable {
    public let limitID: String
    public let accountName: String
    public let recommendation: FastModeRecommendation
    public let confidence: UsageConfidence
    public let remainingUnits: Double?
    public let totalUnits: Double?
    public let nextResetAt: Date?
    public let hoursUntilReset: Double?
    public let standardBurnRateUnitsPerHour: Double?
    public let fastBurnRateUnitsPerHour: Double?
    public let standardModeRunwayHours: Double?
    public let fastModeRunwayHours: Double?
    public let projectedStandardUseUntilReset: Double?
    public let projectedFastUseUntilReset: Double?
    public let reserveUnits: Double

    public var window: MainLimitWindow? {
        limitID.split(separator: ":").last.flatMap { MainLimitWindow(rawValue: String($0)) }
    }

    public var roleCopy: String {
        switch window {
        case .weekly:
            "weekly pool"
        case .fiveHour:
            "5-hour guardrail"
        case .daily:
            "daily pool"
        case nil:
            "capacity pool"
        }
    }

    public var copy: String {
        switch recommendation {
        case .safeThroughReset:
            "Use fast mode"
        case .safeForLimitedTime:
            "Use fast mode briefly"
        case .saveFastMode, .limited:
            "Use normal mode"
        case .needsCalibration:
            "Measuring burn"
        }
    }

    public var detailCopy: String {
        if let percent = remainingPercent {
            let remaining = "\(Int(percent.rounded()))% left"
            if let standardBurnRatePercentPerHour {
                return "\(remaining) · \(Self.format(percentPerHour: standardBurnRatePercentPerHour))/h observed"
            }
            return remaining
        }

        guard let remainingUnits else {
            return "No capacity data"
        }
        if let standardBurnRateUnitsPerHour {
            return "\(Int(remainingUnits.rounded())) left · \(Self.format(unitsPerHour: standardBurnRateUnitsPerHour))/h observed"
        }
        return "\(Int(remainingUnits.rounded())) left"
    }

    public var burnRateCopy: String {
        if let standardBurnRatePercentPerHour {
            return "\(Self.format(percentPerHour: standardBurnRatePercentPerHour))/h observed"
        }
        if let standardBurnRateUnitsPerHour {
            return "\(Self.format(unitsPerHour: standardBurnRateUnitsPerHour))/h observed"
        }
        return "measuring burn"
    }

    public var runwayCopy: String {
        guard let hoursUntilReset else {
            return "reset unknown"
        }
        switch recommendation {
        case .safeThroughReset:
            return "lasts past reset in \(Self.format(hours: hoursUntilReset))"
        case .safeForLimitedTime:
            if let fastModeRunwayHours {
                return "fast out \(Self.format(hours: fastModeRunwayHours))"
            }
            return "fast runway unknown"
        case .saveFastMode, .limited:
            if let standardModeRunwayHours, standardModeRunwayHours < hoursUntilReset {
                return "out \(Self.format(hours: standardModeRunwayHours))"
            }
            if let fastModeRunwayHours {
                return "fast out \(Self.format(hours: fastModeRunwayHours))"
            }
            return "next reset in \(Self.format(hours: hoursUntilReset))"
        case .needsCalibration:
            return "next reset in \(Self.format(hours: hoursUntilReset))"
        }
    }

    public var usableRemainingUnits: Double? {
        guard let remainingUnits else { return nil }
        return max(remainingUnits - reserveUnits, 0)
    }

    public var requiredBurnRateUnitsPerHour: Double? {
        guard let usableRemainingUnits, let hoursUntilReset, hoursUntilReset > 0 else { return nil }
        return usableRemainingUnits / hoursUntilReset
    }

    public var standardBurnRatePercentPerHour: Double? {
        guard let standardBurnRateUnitsPerHour, let totalUnits, totalUnits > 0 else { return nil }
        return (standardBurnRateUnitsPerHour / totalUnits) * 100
    }

    public var requiredBurnRatePercentPerHour: Double? {
        guard let requiredBurnRateUnitsPerHour, let totalUnits, totalUnits > 0 else { return nil }
        return (requiredBurnRateUnitsPerHour / totalUnits) * 100
    }

    public var burnPaceRatio: Double? {
        guard let standardBurnRateUnitsPerHour else { return nil }
        guard let requiredBurnRateUnitsPerHour, requiredBurnRateUnitsPerHour > 0 else {
            return standardBurnRateUnitsPerHour == 0 ? 0 : .infinity
        }
        return standardBurnRateUnitsPerHour / requiredBurnRateUnitsPerHour
    }

    public var burnPaceCopy: String {
        guard let burnPaceRatio else { return "measuring burn" }
        if !burnPaceRatio.isFinite { return "over pace" }
        if burnPaceRatio <= 0.05 { return "idle" }
        if burnPaceRatio <= 0.9 { return "under pace" }
        if burnPaceRatio <= 1.1 { return "on pace" }
        return "over pace"
    }

    public init(
        limitID: String,
        accountName: String,
        providerLimits: [UsageLimit],
        now: Date,
        standardBurnRate: BurnRate? = nil,
        fastBurnRate: BurnRate?,
        reserveUnits: Double = 6,
        minimumSafeHours: Double = 1
    ) {
        precondition(reserveUnits >= 0, "reserveUnits must not be negative")
        precondition(minimumSafeHours >= 0, "minimumSafeHours must not be negative")

        self.limitID = limitID
        self.accountName = accountName
        self.reserveUnits = reserveUnits

        let numericLimits = providerLimits.filter { $0.used != nil && $0.limit != nil }
        let capacityPool = CapacityPool(limits: numericLimits)
        let remaining = capacityPool.totalRemainingUnits
        let total = capacityPool.totalUnits
        remainingUnits = remaining
        totalUnits = total
        confidence = Self.worstConfidence(providerLimits.map(\.confidence))
        standardBurnRateUnitsPerHour = standardBurnRate?.unitsPerHour
        fastBurnRateUnitsPerHour = fastBurnRate?.unitsPerHour

        let nextReset = capacityPool.nextReset(after: now)
        nextResetAt = nextReset
        if let nextReset {
            hoursUntilReset = max(nextReset.timeIntervalSince(now) / 3_600, 0)
        } else {
            hoursUntilReset = nil
        }

        guard
            !numericLimits.isEmpty,
            let fastRate = fastBurnRate?.unitsPerHour,
            fastRate > 0,
            let hoursUntilReset
        else {
            recommendation = .needsCalibration
            standardModeRunwayHours = nil
            fastModeRunwayHours = nil
            projectedStandardUseUntilReset = nil
            projectedFastUseUntilReset = nil
            return
        }

        let usableRemaining = max((remaining ?? 0) - reserveUnits, 0)
        let standardRate = standardBurnRate?.unitsPerHour
        let standardPoolRunway = standardRate.flatMap { rate in
            rate > 0 ? capacityPool.runway(burnRateUnitsPerHour: rate, now: now, reserveUnits: reserveUnits) : nil
        }
        let fastPoolRunway = capacityPool.runway(burnRateUnitsPerHour: fastRate, now: now, reserveUnits: reserveUnits)
        let standardRunway = standardPoolRunway?.runwayHours
        let standardProjected = standardPoolRunway?.projectedUseUntilHorizon
        let fastRunway = fastPoolRunway?.runwayHours ?? (usableRemaining / fastRate)
        let fastProjected = fastPoolRunway?.projectedUseUntilHorizon ?? (fastRate * hoursUntilReset)

        standardModeRunwayHours = standardRunway
        fastModeRunwayHours = fastRunway
        projectedStandardUseUntilReset = standardProjected
        projectedFastUseUntilReset = fastProjected

        if (remaining ?? 0) <= 0 {
            recommendation = .limited
        } else if usableRemaining <= 0 {
            recommendation = .saveFastMode
        } else if fastPoolRunway?.lastsThroughHorizon == true {
            recommendation = .safeThroughReset
        } else if fastRunway >= minimumSafeHours, standardPoolRunway == nil || standardPoolRunway?.lastsThroughHorizon == true {
            recommendation = .safeForLimitedTime
        } else {
            recommendation = .saveFastMode
        }
    }

    private var remainingPercent: Double? {
        guard let remainingUnits, let totalUnits, totalUnits > 0 else { return nil }
        return max(min(remainingUnits / totalUnits, 1), 0) * 100
    }

    private static func worstConfidence(_ confidences: [UsageConfidence]) -> UsageConfidence {
        if confidences.contains(.unknown) { return .unknown }
        if confidences.contains(.estimated) { return .estimated }
        if confidences.contains(.manual) { return .manual }
        if confidences.contains(.observed) { return .observed }
        return confidences.first ?? .unknown
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
        if hours < 24 {
            return "\(Int(hours.rounded()))h"
        }
        let roundedHours = Int(hours.rounded())
        let days = roundedHours / 24
        let remainingHours = roundedHours % 24
        if remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
    }

    private static func format(percentPerHour: Double) -> String {
        if percentPerHour < 10 {
            let rounded = (percentPerHour * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded))%"
            }
            return "\(rounded)%"
        }
        return "\(Int(percentPerHour.rounded()))%"
    }

    private static func format(unitsPerHour: Double) -> String {
        if unitsPerHour < 10 {
            let rounded = (unitsPerHour * 10).rounded() / 10
            if rounded == rounded.rounded() {
                return "\(Int(rounded))"
            }
            return "\(rounded)"
        }
        return "\(Int(unitsPerHour.rounded()))"
    }
}

public struct FastModeCapacityPortfolioForecast: Codable, Equatable, Sendable {
    public let forecasts: [FastModeCapacityForecast]

    public init(forecasts: [FastModeCapacityForecast]) {
        self.forecasts = forecasts
    }

    public var bestForecast: FastModeCapacityForecast? {
        forecasts.first
    }

    public var copy: String {
        bestForecast?.copy ?? "Add OpenAI weekly limits to forecast fast mode."
    }

    public var detailCopy: String {
        guard let bestForecast else { return "OpenAI account needed for fast-mode forecast" }
        let guardrail = forecasts.first { $0.window == .fiveHour }
        if bestForecast.window == .weekly, let guardrail, guardrail.recommendation == .saveFastMode || guardrail.recommendation == .limited {
            return "\(bestForecast.roleCopy): \(bestForecast.runwayCopy) · 5h guardrail: \(guardrail.runwayCopy)"
        }
        return "\(bestForecast.roleCopy): \(bestForecast.burnRateCopy) · \(bestForecast.runwayCopy)"
    }
}

public extension Sequence where Element == MainLimitSummary {
    func openAIFastModeCapacityForecast(
        now: Date = Date(),
        observedBurnRates: [String: ObservedBurnRate] = [:],
        settings: FastModeForecastSettings
    ) -> FastModeCapacityPortfolioForecast {
        openAIFastModeCapacityForecast(
            now: now,
            observedBurnRates: observedBurnRates,
            defaultStandardBurnRateUnitsPerHour: settings.defaultStandardBurnRateUnitsPerHour,
            fastModeMultiplier: settings.fastModeMultiplier,
            reserveUnits: settings.reserveUnits,
            minimumSafeHours: settings.minimumSafeHours
        )
    }

    func openAIFastModeCapacityForecast(
        now: Date = Date(),
        observedBurnRates: [String: ObservedBurnRate] = [:],
        defaultStandardBurnRateUnitsPerHour: Double? = nil,
        fastModeMultiplier: Double = 2,
        reserveUnits: Double = 6,
        minimumSafeHours: Double = 1
    ) -> FastModeCapacityPortfolioForecast {
        let forecasts = self.sorted { lhs, rhs in
            let lhsRank = lhs.openAIFastModeForecastRank
            let rhsRank = rhs.openAIFastModeForecastRank
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return (lhs.usageRatio ?? 0) > (rhs.usageRatio ?? 0)
        }
        .filter { $0.provider == .openAI && $0.unit == .percent }
        .map { summary in
            let observedRate = observedBurnRates[summary.id].map(\.unitsPerHour)
            let standardRate = observedRate ?? defaultStandardBurnRateUnitsPerHour
            return FastModeCapacityForecast(
                limitID: summary.id,
                accountName: "\(summary.provider.displayName) \(summary.window.displayName) pool",
                providerLimits: summary.limits,
                now: now,
                standardBurnRate: standardRate.map { BurnRate(mode: .standard, unitsPerHour: $0) },
                fastBurnRate: standardRate.map { BurnRate(mode: .fast, unitsPerHour: $0 * fastModeMultiplier) },
                reserveUnits: reserveUnits,
                minimumSafeHours: minimumSafeHours
            )
        }
        return FastModeCapacityPortfolioForecast(forecasts: forecasts)
    }
}

private extension MainLimitSummary {
    var openAIFastModeForecastRank: Int {
        switch window {
        case .weekly:
            0
        case .fiveHour:
            1
        case .daily:
            2
        }
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
