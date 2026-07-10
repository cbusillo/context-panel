public struct MetricProgress: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case remainingCapacity
        case usedPressure
        case neutralRate
    }

    public enum State: Equatable, Sendable {
        case determinate(Double)
        case indeterminate
    }

    public let kind: Kind
    public let state: State

    public static func remainingCapacity(remainingRatio: Double?) -> MetricProgress {
        MetricProgress(kind: .remainingCapacity, ratio: remainingRatio)
    }

    public static func usedPressure(usedRatio: Double?) -> MetricProgress {
        MetricProgress(kind: .usedPressure, ratio: usedRatio)
    }

    public static func neutralRate(ratio: Double?) -> MetricProgress {
        MetricProgress(kind: .neutralRate, ratio: ratio)
    }

    public var ratio: Double? {
        guard case let .determinate(ratio) = state else { return nil }
        return ratio
    }

    public var isIndeterminate: Bool {
        ratio == nil
    }

    public var percentText: String {
        guard let ratio else { return "—" }
        return "\(Int((ratio * 100).rounded()))%"
    }

    public var accessibilityValue: String {
        guard let ratio else {
            switch kind {
            case .remainingCapacity:
                return "Remaining capacity unknown"
            case .usedPressure:
                return "Usage pressure unknown"
            case .neutralRate:
                return "Rate unknown"
            }
        }

        let percent = Int((ratio * 100).rounded())
        switch kind {
        case .remainingCapacity:
            return "\(percent) percent remaining"
        case .usedPressure:
            return "\(percent) percent used"
        case .neutralRate:
            return "\(percent) percent"
        }
    }

    private init(kind: Kind, ratio: Double?) {
        self.kind = kind
        guard let ratio, ratio.isFinite else {
            state = .indeterminate
            return
        }
        state = .determinate(min(max(ratio, 0), 1))
    }
}
