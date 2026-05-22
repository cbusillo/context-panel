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
        recentLookback: TimeInterval = 6 * 3_600,
        minimumObservation: TimeInterval = 30 * 60,
        minimumUsableIntervals: Int = 2
    ) -> [String: ObservedBurnRate] {
        var estimates: [String: ObservedBurnRate] = [:]
        let summaries = current.mainLimitSummaries.filter { $0.used != nil && $0.limit != nil }

        for summary in summaries {
            if let estimate = observedBurnRate(
                summary: summary,
                history: history,
                now: now,
                lookback: lookback,
                recentLookback: recentLookback,
                minimumObservation: minimumObservation,
                minimumUsableIntervals: minimumUsableIntervals
            ) {
                estimates[summary.id] = estimate
            }
        }

        return estimates
    }

    private static func observedBurnRate(
        summary: MainLimitSummary,
        history: [StoredUsageSnapshot],
        now: Date,
        lookback: TimeInterval,
        recentLookback: TimeInterval,
        minimumObservation: TimeInterval,
        minimumUsableIntervals: Int
    ) -> ObservedBurnRate? {
        let summaryID = summary.id
        let cutoff = now.addingTimeInterval(-lookback)
        let samplesByBucket = history
            .filter { $0.savedAt >= cutoff && $0.savedAt <= now.addingTimeInterval(60) }
            .flatMap { stored -> [BurnSample] in
                guard
                    let summary = stored.snapshot.mainLimitSummaries.first(where: { $0.id == summaryID })
                else {
                    return []
                }

                return summary.liveLimits.compactMap { limit -> BurnSample? in
                    guard let used = limit.used, let total = limit.limit else { return nil }
                    return BurnSample(
                        bucketID: limit.id,
                        date: stored.savedAt,
                        used: Double(used),
                        limit: Double(total),
                        resetsAt: limit.resetsAt
                    )
                }
            }
            .reduce(into: [String: [BurnSample]]()) { result, sample in
                result[sample.bucketID, default: []].append(sample)
            }

        var bestEstimate = aggregate(estimates: bucketEstimates(
            samplesByBucket: samplesByBucket,
            minimumObservation: minimumObservation,
            minimumUsableIntervals: minimumUsableIntervals
        ))

        if recentLookback < lookback,
           let recentEstimate = aggregate(estimates: bucketEstimates(
            samplesByBucket: samplesByBucket.mapValues { samples in
                samples.filter { $0.date >= now.addingTimeInterval(-recentLookback) }
            },
            minimumObservation: minimumObservation,
            minimumUsableIntervals: minimumUsableIntervals
           )) {
            if let historicalEstimate = bestEstimate {
                bestEstimate = recentEstimate.rate > historicalEstimate.rate
                    ? recentEstimate
                    : historicalEstimate
            } else {
                bestEstimate = recentEstimate
            }
        }

        if let currentWindowEstimate = currentWindowBurnEstimate(
            summary: summary,
            now: now,
            minimumObservation: minimumObservation
        ) {
            if let historicalEstimate = bestEstimate {
                bestEstimate = currentWindowEstimate.rate > historicalEstimate.rate
                    ? currentWindowEstimate
                    : historicalEstimate
            } else {
                bestEstimate = currentWindowEstimate
            }
        }

        guard let bestEstimate else { return nil }

        return ObservedBurnRate(
            limitID: summaryID,
            unitsPerHour: bestEstimate.rate,
            observedDurationHours: bestEstimate.observedSeconds / 3_600,
            sampleCount: bestEstimate.sampleCount
        )
    }

    private static func bucketEstimates(
        samplesByBucket: [String: [BurnSample]],
        minimumObservation: TimeInterval,
        minimumUsableIntervals: Int
    ) -> [BucketBurnEstimate] {
        var estimates: [BucketBurnEstimate] = []

        for (_, bucketSamples) in samplesByBucket {
            let samples = bucketSamples.sorted { $0.date < $1.date }
            guard samples.count >= 2 else { continue }

            var observedSeconds: TimeInterval = 0
            var usedDelta: Double = 0
            var intervalCount = 0

            for pair in zip(samples, samples.dropFirst()) {
                let previous = pair.0
                let current = pair.1
                let interval = current.date.timeIntervalSince(previous.date)
                guard interval > 0 else { continue }
                guard previous.limit == current.limit else { continue }
                switch (previous.resetsAt, current.resetsAt) {
                case let (previousReset?, currentReset?):
                    guard previousReset == currentReset else { continue }
                    guard !(previousReset > previous.date && previousReset <= current.date) else { continue }
                case (nil, nil):
                    break
                default:
                    continue
                }
                let delta = current.used - previous.used
                guard delta >= 0 else { continue }

                observedSeconds += interval
                usedDelta += delta
                intervalCount += 1
            }

            guard
                observedSeconds >= minimumObservation,
                intervalCount >= minimumUsableIntervals
            else { continue }
            let rate = usedDelta / (observedSeconds / 3_600)
            estimates.append(BucketBurnEstimate(
                rate: rate,
                observedSeconds: observedSeconds,
                sampleCount: intervalCount + 1
            ))
        }

        return estimates
    }

    private static func currentWindowBurnEstimate(
        summary: MainLimitSummary,
        now: Date,
        minimumObservation: TimeInterval
    ) -> BucketBurnEstimate? {
        let windowDuration = summary.window.duration
        let candidates = summary.limits.compactMap { limit -> BucketBurnEstimate? in
            guard
                let used = limit.used,
                used > 0,
                let limitTotal = limit.limit,
                limitTotal > 0,
                let resetsAt = limit.resetsAt
            else { return nil }
            if let lastUpdatedAt = limit.lastUpdatedAt,
               now.timeIntervalSince(lastUpdatedAt) > 10 * 60 {
                return nil
            }

            let windowStart = resetsAt.addingTimeInterval(-windowDuration)
            let observedSeconds = now.timeIntervalSince(windowStart)
            guard
                observedSeconds >= minimumObservation,
                observedSeconds <= windowDuration,
                observedSeconds <= 24 * 3_600
            else { return nil }

            return BucketBurnEstimate(
                rate: Double(used) / (observedSeconds / 3_600),
                observedSeconds: observedSeconds,
                sampleCount: 1
            )
        }

        return aggregate(estimates: candidates)
    }

    private static func aggregate(estimates: [BucketBurnEstimate]) -> BucketBurnEstimate? {
        guard !estimates.isEmpty else { return nil }
        return BucketBurnEstimate(
            rate: estimates.reduce(0) { $0 + $1.rate },
            observedSeconds: estimates.map(\.observedSeconds).max() ?? 0,
            sampleCount: estimates.reduce(0) { $0 + $1.sampleCount }
        )
    }
}

private extension MainLimitWindow {
    var duration: TimeInterval {
        switch self {
        case .fiveHour:
            5 * 3_600
        case .weekly:
            7 * 24 * 3_600
        case .daily:
            24 * 3_600
        }
    }
}

private struct BurnSample {
    let bucketID: String
    let date: Date
    let used: Double
    let limit: Double
    let resetsAt: Date?
}

private struct BucketBurnEstimate {
    let rate: Double
    let observedSeconds: TimeInterval
    let sampleCount: Int
}
