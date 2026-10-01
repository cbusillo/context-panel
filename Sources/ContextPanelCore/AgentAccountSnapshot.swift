import Foundation

/// A credential-free, read-only projection of the same rows shown in All Accounts.
/// Raw diagnostics, source paths, credential IDs and cache telemetry are deliberately absent.
public struct AgentAccountSnapshot: Encodable, Sendable {
    public let schemaVersion = 1
    public let readAt: Date
    public let savedAt: Date
    public let accounts: [Account]
    public let answers: Answers
    public let deadlines: [Deadline]

    public struct Answers: Encodable, Sendable {
        public let closestAccountID: String?
        public let useNext: [Recommendation]
        enum CodingKeys: CodingKey { case closestAccountID, useNext }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(closestAccountID, forKey: .closestAccountID)
            try container.encode(useNext, forKey: .useNext)
        }
    }
    public struct Recommendation: Encodable, Sendable {
        public let provider: Provider
        public let accountID: String
    }
    public struct Deadline: Encodable, Sendable {
        public let id: String
        public let accountID: String
        public let provider: Provider
        public let label: String
        public let expiresAt: Date
        public let observedAt: Date
        public let state: AccountCapacityState
    }

    public struct Account: Encodable, Sendable {
        public let id: String
        public let configurationID: String
        public let provider: Provider
        public let label: String
        public let state: AccountCapacityState
        public let showInWidgets: Bool
        public let useLast: Bool
        public let remainingFraction: Double?
        public let limitingWindowID: String?
        public let observedAt: Date?
        public let windows: [Window]
        public let usageCredits: ProviderUsageCreditSummary?
        public let bankedResets: BankedResets

        enum CodingKeys: String, CodingKey {
            case id, configurationID, provider, label, state, showInWidgets, useLast, remainingFraction, limitingWindowID, observedAt, windows, usageCredits, bankedResets
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(configurationID, forKey: .configurationID)
            try container.encode(provider, forKey: .provider)
            try container.encode(label, forKey: .label)
            try container.encode(state, forKey: .state)
            try container.encode(showInWidgets, forKey: .showInWidgets)
            try container.encode(useLast, forKey: .useLast)
            try container.encode(remainingFraction, forKey: .remainingFraction)
            try container.encode(limitingWindowID, forKey: .limitingWindowID)
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
        public let confidence: UsageConfidence
        public let presentationAssumption: UsagePresentationAssumption?

        enum CodingKeys: String, CodingKey {
            case id, label, unit, used, limit, naturalResetAt, observedAt, burn, confidence, presentationAssumption
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
            try container.encode(confidence, forKey: .confidence)
            try container.encode(presentationAssumption, forKey: .presentationAssumption)
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
        let presented = stored.snapshot.presented(at: now)
        let overview = AccountOverview(snapshot: stored.snapshot, reports: stored.reports,
            metadata: AccountDisplayMetadata.local(configuration: configuration.accounts, stored: stored, now: now), now: now)
        answers = Answers(closestAccountID: overview.closest?.id, useNext: Provider.allCases.compactMap { provider in
            overview.useNext(provider: provider).map { Recommendation(provider: provider, accountID: $0.id) }
        })
        deadlines = overview.deadlines.map {
            Deadline(id: $0.id, accountID: $0.accountID, provider: $0.provider, label: $0.label,
                     expiresAt: $0.expiresAt, observedAt: $0.observedAt, state: $0.state)
        }
        let rates = AccountBurnRateEstimator.observedBurnRates(
            current: presented, history: history, now: now
        )
        accounts = AccountCapacity.rows(configuration: configuration.accounts,
            snapshot: presented, reports: stored.reports, now: now).map { row in
            let shared = overview.accounts.first { $0.id == AccountDisplayMetadata.safeID(row.provider, row.id) }
            let current = [.available, .closeToLimit, .limited].contains(shared?.state ?? row.state)
            let summary = row.report?.resetCredits?.presented(at: now)
            let resetState: AccountCapacityState
            if !row.isEnabled { resetState = .off }
            else if row.isNotConnected { resetState = .notConnected }
            else if row.state == .unavailable { resetState = .unavailable }
            else if let summary {
                let age = now.timeIntervalSince(summary.observedAt)
                let expired = summary.availableCount > 0 && summary.earliestKnownExpiry.map { $0 <= now } == true
                resetState = age < -60 || age > SnapshotFreshness.appMaximumAge || expired
                    || abs((row.report?.generatedAt ?? summary.observedAt).timeIntervalSince(summary.observedAt)) > 1 ? .stale : .available
            } else { resetState = .unknown }
            return Account(
                id: ConnectorRedactor.localAccountID(provider: row.provider, stableID: row.id),
                configurationID: ConnectorRedactor.localAccountID(provider: row.provider, stableID: row.configuredAccountID),
                provider: row.provider,
                // AccountCapacity names come only from configured local names/aliases.
                // Provider-derived identity and diagnostic labels keep ordinary redaction.
                label: ConnectorRedactor.safeErrorDescription(row.name, preservingTypedEmail: true),
                state: shared?.state ?? row.state,
                showInWidgets: shared?.metadata.showInWidgets ?? row.isEnabled,
                useLast: shared?.metadata.useLast ?? false,
                remainingFraction: shared?.remainingFraction,
                limitingWindowID: shared?.limitingWindow?.id,
                observedAt: row.limits.compactMap(\.lastUpdatedAt).min() ?? row.report?.generatedAt,
                windows: row.limits.map { limit in
                    let burn = current ? rates[row.id]?[limit.id] : nil
                    return Window(
                        id: ConnectorRedactor.localAccountID(provider: row.provider, stableID: limit.id),
                        label: ConnectorRedactor.safeErrorDescription(limit.label),
                        unit: limit.unit, used: limit.used, limit: limit.limit,
                        naturalResetAt: limit.resetsAt, observedAt: limit.lastUpdatedAt,
                        burn: burn.map { Burn(unitsPerHour: $0.unitsPerHour,
                            observedDurationHours: $0.observedDurationHours, sampleCount: $0.sampleCount) },
                        confidence: limit.confidence, presentationAssumption: limit.presentationAssumption
                    )
                },
                usageCredits: row.report?.usageCredits,
                bankedResets: BankedResets(state: shared?.bankedState ?? resetState, summary: summary)
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
