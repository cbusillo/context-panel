import Foundation

public struct ObservedBurnRate: Codable, Equatable, Sendable {
    public let limitID: String
    public let unitsPerHour: Double
    public let observedDurationHours: Double
    public let sampleCount: Int

    public init(limitID: String, unitsPerHour: Double, observedDurationHours: Double, sampleCount: Int) {
        precondition(unitsPerHour >= 0, "unitsPerHour must not be negative")
        precondition(observedDurationHours >= 0, "observedDurationHours must not be negative")
        precondition(sampleCount >= 0, "sampleCount must not be negative")

        self.limitID = limitID
        self.unitsPerHour = unitsPerHour
        self.observedDurationHours = observedDurationHours
        self.sampleCount = sampleCount
    }
}

public enum MainLimitBurnRateEstimator {
    public static func observedBurnRates(
        current: UsageSnapshot,
        history: [StoredUsageSnapshot],
        now: Date = Date(),
        lookback: TimeInterval = 24 * 3_600,
        minimumObservation: TimeInterval = 30 * 60
    ) -> [String: ObservedBurnRate] {
        var estimates: [String: ObservedBurnRate] = [:]
        let summaries = current.mainLimitSummaries.filter { $0.used != nil && $0.limit != nil }

        for summary in summaries {
            if let estimate = observedBurnRate(
                summaryID: summary.id,
                history: history,
                now: now,
                lookback: lookback,
                minimumObservation: minimumObservation
            ) {
                estimates[summary.id] = estimate
            }
        }

        return estimates
    }

    private static func observedBurnRate(
        summaryID: String,
        history: [StoredUsageSnapshot],
        now: Date,
        lookback: TimeInterval,
        minimumObservation: TimeInterval
    ) -> ObservedBurnRate? {
        let cutoff = now.addingTimeInterval(-lookback)
        let samples = history
            .filter { $0.savedAt >= cutoff && $0.savedAt <= now.addingTimeInterval(60) }
            .compactMap { stored -> BurnSample? in
                guard
                    let summary = stored.snapshot.mainLimitSummaries.first(where: { $0.id == summaryID }),
                    let used = summary.used,
                    let limit = summary.limit
                else {
                    return nil
                }
                return BurnSample(
                    date: stored.savedAt,
                    used: Double(used),
                    limit: Double(limit),
                    resetsAt: summary.nextReset(after: stored.savedAt) ?? summary.firstKnownReset
                )
            }
            .sorted { $0.date < $1.date }

        guard samples.count >= 2 else { return nil }

        var observedSeconds: TimeInterval = 0
        var usedDelta: Double = 0
        var intervalCount = 0

        for pair in zip(samples, samples.dropFirst()) {
            let previous = pair.0
            let current = pair.1
            let interval = current.date.timeIntervalSince(previous.date)
            guard interval > 0 else { continue }
            guard previous.limit == current.limit else { continue }
            if let reset = previous.resetsAt, reset > previous.date, reset <= current.date {
                continue
            }
            let delta = current.used - previous.used
            guard delta >= 0 else { continue }

            observedSeconds += interval
            usedDelta += delta
            intervalCount += 1
        }

        guard observedSeconds >= minimumObservation, intervalCount > 0 else { return nil }

        return ObservedBurnRate(
            limitID: summaryID,
            unitsPerHour: usedDelta / (observedSeconds / 3_600),
            observedDurationHours: observedSeconds / 3_600,
            sampleCount: intervalCount + 1
        )
    }
}

private struct BurnSample {
    let date: Date
    let used: Double
    let limit: Double
    let resetsAt: Date?
}
