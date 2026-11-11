import Foundation

/// Normalized, account-scoped quantities shared with the strategy's other readers.
public struct UsageCreditCapacity: Codable, Equatable, Sendable {
    public let balance: Double
    public let expiresAt: Date?
    public let burnPerHour: Double?
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
            var burn: Double?
            var previousBalance: Double?
            var previousDate: Date?
            var spent = 0.0
            var hours = 0.0
            for reading in readings + [stored] {
                guard let own = reading.reports.first(where: {
                    $0.provider == report.provider && UnusedCapacityHistory.reportID($0, in: reading, resolve: resolve) == id
                }), own.status != .failure, let amount = own.usageCredits?.balance else { continue }
                if let before = previousBalance, amount > before {
                    spent = 0; hours = 0
                } else if let before = previousBalance, let date = previousDate, own.generatedAt > date {
                    spent += before - amount
                    hours += own.generatedAt.timeIntervalSince(date) / 3_600
                }
                previousBalance = amount; previousDate = own.generatedAt
            }
            if hours > 0 && spent > 0 { burn = spent / hours }
            result[id] = Self(balance: balance, expiresAt: UsageCreditExpiry.of(credits, entered: entered[report.provider]),
                burnPerHour: burn, observedAt: report.generatedAt)
        }
        return result
    }
}
