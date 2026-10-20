import ContextPanelCore
import Foundation

// Compiled into disposable capture targets only. No stores, credentials, or network.
enum ScreenshotFixture {
    static let date = ContextPanelDateFormatting.date(from: "2026-10-01T14:07:00Z")!
    static let snapshot: WidgetSnapshot = makeSnapshot()
    static let result = CompanionSyncLoadResult(
        document: CompanionSyncDocument(storedSnapshot: stored, publishedAt: date,
            accountDisplayMetadata: snapshot.accountDisplayMetadata,
            accountBurnRates: snapshot.accountBurnRates), status: .healthy)
    static let stored = StoredUsageSnapshot(savedAt: date, snapshot: snapshot.usageSnapshot, reports: snapshot.reports)

    private static func makeSnapshot() -> WidgetSnapshot {
        typealias Row = (String, Provider, Int, Double, Int, Double, Double?, Double?, [Double])
        let rows: [Row] = [
            ("Studio", .openAI, 85, 120, 40, 2.2, 0.45, 6, [24.3, 288.9]),
            ("Work", .openAI, 28, 55, 12, 4, 0.4, 3, [627, 1056.5]),
            ("Personal", .openAI, 11, 147, 0, 5, 0.03, nil, []),
            ("Claude primary", .anthropic, 63, 138, 78, 1.2, 0.35, 15, []),
            ("Claude backup", .anthropic, 43, 74, 5, 4.7, 0.2, 1, []),
            ("Antigravity", .google, 9, 164, 0, 5, 0.05, nil, []),
        ]
        var limits: [UsageLimit] = []
        var reports: [StoredProviderReport] = []
        var metadata: [AccountDisplayMetadata] = []
        var rates: [String: [String: ObservedBurnRate]] = [:]
        for (index, row) in rows.enumerated() {
            let id = "screenshot-\(index)"
            for (window, used, hours, burn) in [("Weekly", row.2, row.3, row.6), ("5-hour", row.4, row.5, row.7)] {
                let limit = UsageLimit(provider: row.1, accountID: id, accountName: row.0,
                    label: window, windowLabel: window, unit: .percent, used: used, limit: 100,
                    resetsAt: date.addingTimeInterval(hours * 3600), lastUpdatedAt: date, confidence: .observed)
                limits.append(limit)
                if let burn {
                    rates[id, default: [:]][limit.id] = ObservedBurnRate(limitID: limit.id,
                        unitsPerHour: burn, observedDurationHours: 6, sampleCount: 24)
                }
            }
            let credits = row.8.isEmpty ? nil : ProviderResetCreditSummary(availableCount: row.8.count,
                observedAt: date, coverage: .complete, knownExpiries: row.8.map { date.addingTimeInterval($0 * 3600) })
            reports.append(StoredProviderReport(provider: row.1, accountID: id, accountName: row.0,
                generatedAt: date, resetCredits: credits, status: .healthy, errorMessage: nil))
            metadata.append(AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(row.1, id),
                configurationID: AccountDisplayMetadata.safeID(row.1, id), provider: row.1, label: row.0,
                useLast: index == 2))
        }
        return WidgetSnapshot(state: .ready, generatedAt: date, limits: limits, reports: reports,
            status: .healthy, message: "", accountDisplayMetadata: metadata, accountBurnRates: rates)
    }
}
