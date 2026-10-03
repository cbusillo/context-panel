import Foundation

/// Display metadata only. Credentials, paths and provider-derived names never enter this payload.
public struct AccountDisplayMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let configurationID: String
    public let provider: Provider
    public let label: String
    public let isEnabled: Bool
    public let showInWidgets: Bool
    public let useLast: Bool
    public let sourceConfigured: Bool
    public let readState: AccountCapacityState?

    public init(id: String, configurationID: String, provider: Provider, label: String,
                isEnabled: Bool = true, showInWidgets: Bool = true, useLast: Bool = false,
                sourceConfigured: Bool = true, readState: AccountCapacityState? = nil) {
        self.id = id
        self.configurationID = configurationID
        self.provider = provider
        self.label = ConnectorRedactor.safeErrorDescription(label, preservingTypedEmail: true)
        self.isEnabled = isEnabled
        self.showInWidgets = showInWidgets
        self.useLast = useLast
        self.sourceConfigured = sourceConfigured
        self.readState = readState
    }

    public static func local(configuration: [LocalProviderAccountConfiguration], stored: StoredUsageSnapshot,
                             now: Date) -> [Self] {
        AccountCapacity.rows(configuration: configuration, snapshot: stored.snapshot.presented(at: now),
                             reports: stored.reports, now: now).compactMap { row in
            guard let setup = configuration.first(where: { $0.id == row.configuredAccountID }) else { return nil }
            return Self(id: safeID(row.provider, row.id), configurationID: safeID(row.provider, row.configuredAccountID),
                        provider: row.provider, label: row.name, isEnabled: row.isEnabled,
                        showInWidgets: setup.showInWidgets ?? setup.isEnabled, useLast: setup.useLast ?? false,
                        sourceConfigured: setup.connectorKind != .codexRateLimits
                            || setup.codexQuotaPath != nil || setup.effectiveAuthPath != nil,
                        readState: row.state)
        }
    }

    public static func safeID(_ provider: Provider, _ value: String) -> String {
        ConnectorRedactor.localAccountID(provider: provider, stableID: value)
    }
}

/// The same account answers for the app, widgets, companions and local agent reader.
/// Percentages describe the tightest known window; eligibility requires every window.
public struct AccountOverview: Equatable, Sendable {
    public struct Window: Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let used: Int?
        public let limit: Int?
        public let unit: UsageUnit
        public let remainingFraction: Double?
        public let naturalResetAt: Date?
        public let observedAt: Date?
        public let confidence: UsageConfidence
        public let assumption: UsagePresentationAssumption?
        /// Observed spend as a fraction of this window per hour, from this account's own history only.
        public var burnFractionPerHour: Double? = nil
        public var modelLabel: String? = nil
        public var periodLabel: String? = nil
        public var status: UsageStatus = .unknown
    }

    public struct Account: Equatable, Sendable, Identifiable {
        public let metadata: AccountDisplayMetadata
        public let state: AccountCapacityState
        public let windows: [Window]
        public let bankedResets: ProviderResetCreditSummary?
        public let bankedState: AccountCapacityState
        public let observedAt: Date?
        public var providerPlan: String? = nil
        public var bankedAdvice: BankedAdvice? = nil
        public var id: String { metadata.id }
        public var limitingWindow: Window? {
            guard !windows.isEmpty, windows.allSatisfy({ $0.remainingFraction != nil }) else { return nil }
            return windows.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
        }
        public var remainingFraction: Double? { state == .unknown || state == .notConnected || state == .off
            ? nil : limitingWindow?.remainingFraction }
        public var isReliable: Bool {
            [.available, .closeToLimit, .limited].contains(state)
                && limitingWindow != nil && windows.allSatisfy { $0.assumption == nil && $0.confidence != .unknown }
        }
        public var canUseNext: Bool {
            isReliable && state != .limited && !metadata.useLast && windows.allSatisfy { ($0.remainingFraction ?? 0) > 0 }
        }
        public var unknownExpiryCount: Int? {
            bankedResets.map { max(0, $0.availableCount - ($0.knownExpiries.isEmpty
                ? ($0.earliestKnownExpiry == nil ? 0 : 1) : $0.knownExpiries.count)) }
        }
    }

    public struct BankedAdvice: Equatable, Sendable {
        public let title: String
        public let detail: String
    }

    public struct Deadline: Equatable, Sendable, Identifiable {
        public let accountID: String
        public let provider: Provider
        public let label: String
        public let expiresAt: Date
        public let observedAt: Date
        public let state: AccountCapacityState
        public let ordinal: Int
        public var id: String { "\(accountID):\(expiresAt.timeIntervalSince1970):\(ordinal)" }
    }

    public let accounts: [Account]
    public let deadlines: [Deadline]
    private init(accounts: [Account], deadlines: [Deadline]) {
        self.accounts = accounts
        self.deadlines = deadlines
    }

    /// A provider page uses the same observations, forecasts and expiry ordering as All Accounts.
    public func filtered(to provider: Provider) -> AccountOverview {
        AccountOverview(accounts: accounts.filter { $0.metadata.provider == provider },
                        deadlines: deadlines.filter { $0.provider == provider })
    }

    public var closest: Account? {
        accounts.filter(\.isReliable).reduce(nil) { best, row in
            guard let best else { return row }
            return (row.remainingFraction ?? 1) < (best.remainingFraction ?? 1) ? row : best
        }
    }
    public func useNext(provider: Provider) -> Account? {
        accounts.filter { $0.metadata.provider == provider && $0.canUseNext }.reduce(nil) { best, row in
            guard let best else { return row }
            return (row.remainingFraction ?? 0) > (best.remainingFraction ?? 0) ? row : best
        }
    }
    public var nextDeadline: Deadline? { deadlines.first { $0.state == .available } }

    public init(snapshot: UsageSnapshot, reports: [StoredProviderReport], metadata: [AccountDisplayMetadata]? = nil,
                now: Date, maximumAge: TimeInterval = SnapshotFreshness.appMaximumAge,
                widgetsOnly: Bool = false, isSavedSnapshot: Bool = false,
                accountBurnRates: [String: [String: ObservedBurnRate]] = [:]) {
        let presented = snapshot.presented(at: now)
        let entries = metadata ?? Self.inferredMetadata(snapshot: snapshot, reports: reports)
        accounts = entries.filter { !widgetsOnly || $0.showInWidgets }.map { entry in
            let limits = entry.sourceConfigured ? presented.limits.filter {
                $0.provider == entry.provider && AccountDisplayMetadata.safeID($0.provider, $0.accountID) == entry.id
            } : []
            // AccountCapacity already classifies whole-source failures in readState.
            // A failed sibling must not replace this member's report or banked data.
            let report = reports.filter {
                $0.provider == entry.provider && AccountDisplayMetadata.safeID($0.provider, $0.accountID) == entry.id
            }.max { $0.generatedAt < $1.generatedAt }
            let windows = limits.map { limit in
                Window(id: AccountDisplayMetadata.safeID(limit.provider, limit.id),
                       label: ConnectorRedactor.safeErrorDescription([AccountTerms.modelName(limit.modelLabel, provider: limit.provider), limit.windowLabel ?? limit.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")),
                       used: limit.used, limit: limit.limit, unit: limit.unit,
                       remainingFraction: limit.usageRatio.map { min(1, max(0, 1 - $0)) },
                       naturalResetAt: limit.resetsAt, observedAt: limit.lastUpdatedAt,
                       confidence: limit.confidence, assumption: limit.presentationAssumption,
                       // sampleCount 0 is the estimator's window-average fallback, not observed history.
                       burnFractionPerHour: accountBurnRates[limit.accountID]?[limit.id].flatMap { rate in
                           rate.sampleCount > 0 ? limit.limit.flatMap { $0 > 0 ? rate.unitsPerHour / Double($0) : nil } : nil
                       }, modelLabel: AccountTerms.modelName(limit.modelLabel, provider: limit.provider).map { ConnectorRedactor.safeErrorDescription($0) },
                       periodLabel: limit.windowLabel.map { ConnectorRedactor.safeErrorDescription($0) }, status: limit.status)
            }
            let observed = windows.compactMap(\.observedAt).min() ?? report?.generatedAt
            let ageSensitive = limits.isEmpty || limits.contains { !$0.usesEventDrivenFreshness }
            let old = limits.contains { limit in
                limit.lastUpdatedAt.map { $0 > now.addingTimeInterval(60)
                    || !limit.usesEventDrivenFreshness && now.timeIntervalSince($0) > maximumAge } ?? false
            } || report.map { $0.generatedAt > now.addingTimeInterval(60)
                || ageSensitive && now.timeIntervalSince($0.generatedAt) > maximumAge } == true
            let passed = limits.contains { !$0.isAssumedAfterScheduledReset && ($0.resetsAt ?? .distantFuture) <= now }
            let state: AccountCapacityState
            if !entry.isEnabled { state = .off }
            else if entry.readState == .notConnected || (entry.provider == .anthropic && (report?.requiresCredentialReconnect == true || (report == nil && limits.isEmpty))) { state = .notConnected }
            else if entry.readState == .unavailable || report?.status == .failure { state = .unavailable }
            else if old || passed || (isSavedSnapshot && !limits.isEmpty) || limits.contains(where: { $0.status == .stale }) { state = .stale }
            else if entry.readState == .stale { state = .stale }
            else if entry.readState == .unknown || windows.isEmpty || windows.contains(where: { $0.remainingFraction == nil }) { state = .unknown }
            else {
                state = switch ([report?.status ?? .healthy] + limits.map(\.status)).contextPanelWorstStatus {
                case .healthy: .available
                case .close: .closeToLimit
                case .limited: .limited
                case .loading: .refreshing
                case .failure: .unavailable
                case .stale: .stale
                case .unknown: .unknown
                }
            }
            let banked = report?.resetCredits?.presented(at: now)
            let bankedState: AccountCapacityState
            if !entry.isEnabled { bankedState = .off }
            else if let banked {
                bankedState = isSavedSnapshot || state == .unavailable || report?.status == .failure || now.timeIntervalSince(banked.observedAt) > maximumAge
                    || banked.observedAt > now.addingTimeInterval(60)
                    || abs((report?.generatedAt ?? banked.observedAt).timeIntervalSince(banked.observedAt)) > 1 ? .stale : .available
            } else { bankedState = state == .notConnected ? .notConnected : .unknown }
            let namedPlan = [limits.first?.accountName, report?.accountName].compactMap { $0 }
                .lazy.compactMap { name -> String? in
                    let parts = name.split(separator: "·")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : nil
                }.first
            let notedPlan = limits.lazy.compactMap { limit -> String? in
                guard let note = limit.note, note.lowercased().hasPrefix("plan:") else { return nil }
                let value = note.dropFirst("plan:".count).trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value.capitalized
            }.first
            let plan = entry.provider == .openAI
                ? (namedPlan ?? notedPlan)
                    .map { ConnectorRedactor.safeErrorDescription($0) } : nil
            let advice = report.flatMap { ResetCreditGuidanceAdvisor.guidance(report: $0, limits: limits, now: now, maximumAge: maximumAge) }
                .map { BankedAdvice(title: $0.recommendationTitle, detail: $0.recommendationDetail(now: now)) }
            return Account(metadata: entry, state: state, windows: windows, bankedResets: banked,
                           bankedState: bankedState, observedAt: observed, providerPlan: plan, bankedAdvice: advice)
        }
        deadlines = accounts.flatMap { account -> [Deadline] in
            guard account.metadata.isEnabled, let summary = account.bankedResets else { return [] }
            let dates = summary.knownExpiries.isEmpty ? summary.earliestKnownExpiry.map { [$0] } ?? [] : summary.knownExpiries
            var duplicateOrdinals: [Date: Int] = [:]
            return dates.prefix(summary.availableCount).compactMap { date in
                guard date > now else { return nil }
                let index = duplicateOrdinals[date, default: 0]
                duplicateOrdinals[date] = index + 1
                return Deadline(accountID: account.id, provider: account.metadata.provider, label: account.metadata.label,
                                expiresAt: date, observedAt: summary.observedAt, state: account.bankedState, ordinal: index)
            }
        }.sorted { $0.expiresAt == $1.expiresAt ? $0.id < $1.id : $0.expiresAt < $1.expiresAt }
    }

    private static func inferredMetadata(snapshot: UsageSnapshot, reports: [StoredProviderReport]) -> [AccountDisplayMetadata] {
        var seen = Set<String>()
        return (snapshot.limits.map { ($0.provider, $0.accountID, $0.configuredAccountID, $0.accountName) }
            + reports.map { ($0.provider, $0.accountID, $0.configuredAccountID, $0.accountName) }).compactMap { provider, id, configured, name in
                let key = AccountDisplayMetadata.safeID(provider, id)
                guard seen.insert(key).inserted else { return nil }
                return AccountDisplayMetadata(id: key, configurationID: AccountDisplayMetadata.safeID(provider, configured ?? id),
                                              provider: provider, label: ConnectorRedactor.safeErrorDescription(name))
            }
    }
}
