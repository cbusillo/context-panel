import Foundation

/// Planning quantities only. Numeric credit balances and raw credit rates stay on the Mac.
public struct UsageCreditCapacity: Codable, Equatable, Sendable {
    public let available: Bool
    public let runwayHours: Double?
    public let expiresAt: Date?
    public let observedAt: Date

    static func make(stored: StoredUsageSnapshot, history: [StoredUsageSnapshot],
                     resolve: ProviderRefillDetector.AccountResolver, entered: [Provider: Date]) -> [String: Self] {
        let readings = history.filter { $0.savedAt < stored.savedAt && stored.savedAt.timeIntervalSince($0.savedAt) <= LaunchReceiptStore.lookback }
            .sorted { $0.savedAt < $1.savedAt }
        var result: [String: Self] = [:]
        for report in stored.reports {
            guard report.status != .failure, let credits = report.usageCredits,
                  !credits.unlimited, let balance = credits.balance else { continue }
            let id = UnusedCapacityHistory.reportID(report, in: stored, resolve: resolve)
            var previous: (balance: Double, date: Date, spending: Bool)?
            var spent = 0.0
            var hours = 0.0
            for reading in readings + [stored] {
                guard let own = reading.reports.first(where: {
                    $0.provider == report.provider && UnusedCapacityHistory.reportID($0, in: reading, resolve: resolve) == id
                }), own.status != .failure, let amount = own.usageCredits?.balance else { continue }
                let spending = own.accessState.kind == .paidFallbackActive
                    || ProviderRefillDetector.mainLimits(provider: own.provider, reading: reading)[own.accountID]?.remainingCapacityRatio == 0
                if let before = previous, amount > before.balance {
                    spent = 0; hours = 0
                } else if let before = previous, before.spending, spending, own.generatedAt > before.date {
                    spent += max(0, before.balance - amount)
                    hours += own.generatedAt.timeIntervalSince(before.date) / 3_600
                }
                previous = (amount, own.generatedAt, spending)
            }
            let runway = hours > 0 && spent > 0 ? balance * hours / spent : nil
            result[id] = Self(available: credits.hasCredits && balance > 0, runwayHours: runway,
                expiresAt: UsageCreditExpiry.of(credits, entered: entered[report.provider]), observedAt: report.generatedAt)
        }
        return result
    }
}
