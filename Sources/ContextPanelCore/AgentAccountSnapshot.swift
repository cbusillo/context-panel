import Foundation

/// A credential-free, read-only projection of the same rows shown in All Accounts.
/// Raw diagnostics, source paths, credential IDs and cache telemetry are deliberately absent.
public struct AgentAccountSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let readAt: Date
    public let savedAt: Date
    public let accounts: [Account]

    public struct Account: Encodable, Sendable {
        public let id: String
        public let provider: Provider
        public let label: String
        public let state: AccountCapacityState
        public let observedAt: Date?
        public let windows: [Window]
        public let usageCredits: ProviderUsageCreditSummary?
        public let bankedResets: BankedResets

        enum CodingKeys: String, CodingKey {
            case id, provider, label, state, observedAt, windows, usageCredits, bankedResets
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(provider, forKey: .provider)
            try container.encode(label, forKey: .label)
            try container.encode(state, forKey: .state)
            try container.encode(observedAt, forKey: .observedAt)
            try container.encode(windows, forKey: .windows)
            try container.encode(usageCredits, forKey: .usageCredits)
            try container.encode(bankedResets, forKey: .bankedResets)
        }
    }

    public struct Window: Encodable, Sendable {
        public let id: String
        public let label: String
        public let unit: UsageUnit
        public let used: Int?
        public let limit: Int?
        public let naturalResetAt: Date?
        public let observedAt: Date?
        public let burn: Burn?

        enum CodingKeys: String, CodingKey {
            case id, label, unit, used, limit, naturalResetAt, observedAt, burn
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(label, forKey: .label)
            try container.encode(unit, forKey: .unit)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
            try container.encode(naturalResetAt, forKey: .naturalResetAt)
            try container.encode(observedAt, forKey: .observedAt)
            try container.encode(burn, forKey: .burn)
        }
    }

    public struct Burn: Encodable, Sendable {
        public let unitsPerHour: Double
        public let observedDurationHours: Double
        public let sampleCount: Int
    }

    public struct BankedResets: Encodable, Sendable {
        public let state: AccountCapacityState
        public let summary: ProviderResetCreditSummary?
        public let unknownExpiryCount: Int?

        enum CodingKeys: String, CodingKey { case state, summary, unknownExpiryCount }

        init(state: AccountCapacityState, summary: ProviderResetCreditSummary?) {
            self.state = state
            self.summary = summary
            // Older publishers stored only the earliest expiry even with complete
            // coverage. Expose the missing date count rather than promising a schedule.
            let datedCount = summary.map { $0.knownExpiries.isEmpty
                ? ($0.earliestKnownExpiry == nil ? 0 : 1) : $0.knownExpiries.count }
            unknownExpiryCount = summary.map { max(0, $0.availableCount - (datedCount ?? 0)) }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(summary, forKey: .summary)
            try container.encode(unknownExpiryCount, forKey: .unknownExpiryCount)
        }
    }

    public init(
        configuration: AccountConfigurationDocument,
        stored: StoredUsageSnapshot,
        history: [StoredUsageSnapshot],
        now: Date
    ) {
        readAt = now
        savedAt = stored.savedAt
        let rates = AccountBurnRateEstimator.observedBurnRates(
            current: stored.snapshot, history: history, now: now
        )
        accounts = AccountCapacity.rows(configuration: configuration.accounts,
            snapshot: stored.snapshot, reports: stored.reports, now: now).map { row in
            let current = [.available, .closeToLimit, .limited].contains(row.state)
            let summary = row.report?.resetCredits
            let resetState: AccountCapacityState
            if !row.isEnabled { resetState = .off }
            else if row.isNotConnected { resetState = .notConnected }
            else if row.state == .unavailable { resetState = .unavailable }
            else if let summary {
                let age = now.timeIntervalSince(summary.observedAt)
                let expired = summary.availableCount > 0 && summary.earliestKnownExpiry.map { $0 <= now } == true
                resetState = age < -60 || age > SnapshotFreshness.appMaximumAge || expired ? .stale : .available
            } else { resetState = .unknown }
            return Account(
                id: ConnectorRedactor.localAccountID(provider: row.provider, stableID: row.id),
                provider: row.provider,
                label: ConnectorRedactor.safeErrorDescription(row.name),
                state: row.state,
                observedAt: row.report?.generatedAt ?? row.limits.compactMap(\.lastUpdatedAt).min(),
                windows: row.limits.map { limit in
                    let burn = current ? rates[row.id]?[limit.id] : nil
                    return Window(
                        id: ConnectorRedactor.localAccountID(provider: row.provider, stableID: limit.id),
                        label: ConnectorRedactor.safeErrorDescription(limit.label),
                        unit: limit.unit, used: limit.used, limit: limit.limit,
                        naturalResetAt: limit.resetsAt, observedAt: limit.lastUpdatedAt,
                        burn: burn.map { Burn(unitsPerHour: $0.unitsPerHour,
                            observedDurationHours: $0.observedDurationHours, sampleCount: $0.sampleCount) }
                    )
                },
                usageCredits: row.report?.usageCredits,
                bankedResets: BankedResets(state: resetState, summary: summary)
            )
        }
    }
}

public enum AgentAccountSnapshotReadError: Error {
    case unavailable, unsupportedSchema
}

public extension AgentAccountSnapshot {
    /// Decode configuration directly: AccountConfigurationStore.load may persist migrations.
    /// This reader must never alter the publisher's configuration or invent fallback accounts.
    static func read(rootDirectory: URL, now: Date = Date()) throws -> Self {
        do {
            let decoder = JSONDecoder.contextPanelISO8601
            let configuration = try decoder.decode(AccountConfigurationDocument.self,
                from: Data(contentsOf: rootDirectory.appending(path: "accounts.json")))
            let snapshotDirectory = rootDirectory.appending(path: "Snapshots")
            let stored = try decoder.decode(StoredUsageSnapshot.self,
                from: Data(contentsOf: snapshotDirectory.appending(path: "current-snapshot.json")))
            guard configuration.schemaVersion == 1, stored.schemaVersion == 1 else {
                throw AgentAccountSnapshotReadError.unsupportedSchema
            }
            let history = JSONSnapshotStore(rootDirectory: snapshotDirectory).loadHistory(
                query: SnapshotStoreQuery(since: now.addingTimeInterval(-24 * 3_600), limit: 2_000)
            )
            return Self(configuration: configuration, stored: stored, history: history, now: now)
        } catch let error as AgentAccountSnapshotReadError {
            throw error
        } catch {
            throw AgentAccountSnapshotReadError.unavailable
        }
    }
}
