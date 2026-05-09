import Foundation

public struct CapacityBucket: Codable, Equatable, Sendable {
    public let id: String
    public let remainingUnits: Double
    public let totalUnits: Double
    public let resetsAt: Date?

    public init(id: String, remainingUnits: Double, totalUnits: Double, resetsAt: Date?) {
        precondition(remainingUnits >= 0, "remainingUnits must not be negative")
        precondition(totalUnits > 0, "totalUnits must be positive")

        self.id = id
        self.remainingUnits = min(remainingUnits, totalUnits)
        self.totalUnits = totalUnits
        self.resetsAt = resetsAt
    }
}

public struct CapacityPoolRunway: Codable, Equatable, Sendable {
    public let lastsThroughHorizon: Bool
    public let exhaustedAt: Date?
    public let runwayHours: Double?
    public let projectedUseUntilHorizon: Double
    public let horizonResetAt: Date?
}

public struct CapacityPool: Codable, Equatable, Sendable {
    public let buckets: [CapacityBucket]

    public init(buckets: [CapacityBucket]) {
        self.buckets = buckets
    }

    public init(limits: [UsageLimit]) {
        buckets = limits.compactMap { limit in
            guard
                let remaining = limit.remaining,
                let total = limit.limit
            else {
                return nil
            }
            return CapacityBucket(
                id: limit.id,
                remainingUnits: Double(remaining),
                totalUnits: Double(total),
                resetsAt: limit.resetsAt
            )
        }
    }

    public var totalRemainingUnits: Double? {
        guard !buckets.isEmpty else { return nil }
        return buckets.reduce(0) { $0 + $1.remainingUnits }
    }

    public var totalUnits: Double? {
        guard !buckets.isEmpty else { return nil }
        return buckets.reduce(0) { $0 + $1.totalUnits }
    }

    public func nextReset(after date: Date) -> Date? {
        buckets.compactMap(\.resetsAt).filter { $0 > date }.sorted().first
    }

    public func runway(
        burnRateUnitsPerHour: Double,
        now: Date,
        reserveUnits: Double = 0,
        horizonResetCount: Int = 1
    ) -> CapacityPoolRunway? {
        precondition(burnRateUnitsPerHour >= 0, "burnRateUnitsPerHour must not be negative")
        precondition(reserveUnits >= 0, "reserveUnits must not be negative")
        precondition(horizonResetCount > 0, "horizonResetCount must be positive")

        guard !buckets.isEmpty, burnRateUnitsPerHour > 0 else { return nil }

        let futureResets = Array(Set(buckets.compactMap(\.resetsAt).filter { $0 > now })).sorted()
        guard let horizonResetAt = futureResets.dropFirst(horizonResetCount - 1).first else { return nil }

        var states = buckets.map { BucketState(bucket: $0, available: $0.remainingUnits) }
        var cursor = now
        var projectedUse = 0.0

        for reset in futureResets.filter({ $0 <= horizonResetAt }) {
            let hours = reset.timeIntervalSince(cursor) / 3_600
            if hours > 0 {
                let demand = burnRateUnitsPerHour * hours
                let spendable = max(states.reduce(0) { $0 + $1.available } - reserveUnits, 0)
                if spendable + 0.000001 < demand {
                    projectedUse += spendable
                    let exhaustedAt = cursor.addingTimeInterval((spendable / burnRateUnitsPerHour) * 3_600)
                    return CapacityPoolRunway(
                        lastsThroughHorizon: false,
                        exhaustedAt: exhaustedAt,
                        runwayHours: max(exhaustedAt.timeIntervalSince(now) / 3_600, 0),
                        projectedUseUntilHorizon: projectedUse,
                        horizonResetAt: horizonResetAt
                    )
                }

                let spent = Self.spend(demand, from: &states)
                projectedUse += spent
            }

            for index in states.indices where states[index].bucket.resetsAt == reset {
                states[index].available = states[index].bucket.totalUnits
            }
            cursor = reset
        }

        return CapacityPoolRunway(
            lastsThroughHorizon: true,
            exhaustedAt: nil,
            runwayHours: horizonResetAt.timeIntervalSince(now) / 3_600,
            projectedUseUntilHorizon: projectedUse,
            horizonResetAt: horizonResetAt
        )
    }

    private static func spend(_ demand: Double, from states: inout [BucketState]) -> Double {
        var remainingDemand = demand
        var spent = 0.0
        let order = states.indices.sorted { lhs, rhs in
            let lhsReset = states[lhs].bucket.resetsAt ?? .distantFuture
            let rhsReset = states[rhs].bucket.resetsAt ?? .distantFuture
            if lhsReset != rhsReset { return lhsReset < rhsReset }
            return states[lhs].available < states[rhs].available
        }

        for index in order where remainingDemand > 0 {
            let amount = min(states[index].available, remainingDemand)
            states[index].available -= amount
            remainingDemand -= amount
            spent += amount
        }

        return spent
    }
}

private struct BucketState {
    let bucket: CapacityBucket
    var available: Double
}
