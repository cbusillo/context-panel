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
/// Percentages and status describe the account's main capacity; model rows remain available.
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
        /// 5-hour, weekly or daily, inferred from the provider's labels; nil when unknown.
        public var period: MainLimitWindow? = nil
        public var isAccountCapacityLimit: Bool = true
        public var isCurrent: Bool {
            [.healthy, .close, .limited].contains(status) && confidence != .unknown && assumption == nil
        }
    }

    public struct Account: Equatable, Sendable, Identifiable {
        public let metadata: AccountDisplayMetadata
        public let state: AccountCapacityState
        public let windows: [Window]
        public let bankedResets: ProviderResetCreditSummary?
        public let bankedState: AccountCapacityState
        public let observedAt: Date?
        public var providerPlan: String? = nil
        /// The banked-reset advice (#1079); the value and reasoning for the detail view.
        public var resetAssessment: ResetAssessment? = nil
        public var bankedAdvice: BankedAdvice? { resetAssessment.map { BankedAdvice(title: $0.title, detail: $0.detail) } }
        public var isCodexSignInExpired: Bool = false
        /// OpenAI says the plan quota is used up but usage credits keep the account working.
        public var spendsUsageCredits: Bool = false
        public var id: String { metadata.id }
        var capacityWindows: [Window] { windows.filter(\.isAccountCapacityLimit) }
        var hasKnownCapacity: Bool {
            !capacityWindows.isEmpty && capacityWindows.allSatisfy {
                $0.remainingFraction != nil && $0.confidence != .unknown && $0.assumption == nil && $0.observedAt != nil
            }
        }
        public var limitingWindow: Window? {
            guard !capacityWindows.isEmpty, capacityWindows.allSatisfy({ $0.remainingFraction != nil }) else { return nil }
            return capacityWindows.min { ($0.remainingFraction ?? 1) < ($1.remainingFraction ?? 1) }
        }
        public var remainingFraction: Double? { state == .unknown || state == .notConnected || state == .off
            ? nil : limitingWindow?.remainingFraction }
        public var isReliable: Bool {
            [.available, .closeToLimit, .limited].contains(state)
                && limitingWindow != nil && capacityWindows.allSatisfy(\.isCurrent)
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
    /// The moment the readings were judged; Use next measures time left from here.
    public let rankedAt: Date
    public let launchEvidence: UseNextEvidence
    let rankings: [Provider: UseNextRanking]
    let allRankings: [Provider: UseNextRanking]
    private init(accounts: [Account], deadlines: [Deadline], rankedAt: Date, launchEvidence: UseNextEvidence,
                 rankings: [Provider: UseNextRanking], allRankings: [Provider: UseNextRanking]? = nil) {
        self.accounts = accounts
        self.deadlines = deadlines
        self.rankedAt = rankedAt
        self.launchEvidence = launchEvidence
        self.rankings = rankings
        self.allRankings = allRankings ?? rankings
    }

    /// Will this provider run out before it refills at the measured pace, and how much refills unused (#1079)?
    /// Judged over every account, including ones hidden from widgets; nil without a current weekly reading.
    public func paceForecast(provider: Provider) -> ProviderPaceForecast? { allRankings[provider]?.forecast }

    /// Accounts holding banked resets, for a provider's tag.
    public struct BankedResetHolders: Equatable, Sendable {
        public let provider: Provider
        public let accountCount: Int
        public let includesMultipleProviders: Bool
        /// No holder has a current count; the tag shows the last one seen.
        public let isLastSeenOnly: Bool

        public var accountCountText: String {
            accountCount == 1 ? "1 account" : "\(accountCount) accounts"
        }

        public var providerAccountCountText: String {
            if includesMultipleProviders { return accountCountText }
            return accountCount == 1 ? "1 \(provider.displayName) account" : "\(accountCount) \(provider.displayName) accounts"
        }
    }

    public func bankedResetHolders(provider: Provider? = nil) -> BankedResetHolders? {
        Self.bankedResetHolders(accounts.filter { provider == nil || $0.metadata.provider == provider })
    }

    static func bankedResetHolders(_ accounts: [Account]) -> BankedResetHolders? {
        let holders = accounts.filter { $0.metadata.isEnabled && ($0.bankedResets?.availableCount ?? 0) > 0 }
        guard let first = holders.first else { return nil }
        return BankedResetHolders(provider: first.metadata.provider, accountCount: holders.count,
                                  includesMultipleProviders: Set(holders.map(\.metadata.provider)).count > 1,
                                  isLastSeenOnly: !holders.contains { $0.bankedState == .available })
    }

    /// Present shared-provider advice under the local report IDs used by provider diagnostics.
    /// One account's limits and reports, from the presentation that built this overview.
    /// Both join on the account's own ID, so usage and banked resets land in one row (#1077).
    public struct Diagnostics: Equatable, Sendable {
        public let snapshot: UsageSnapshot
        public let reports: [StoredProviderReport]
        /// Keyed by report account ID, for `BankedResetDeadlinesView`.
        public let bankedAdvice: [String: BankedAdvice]
        public let bankedResetHolders: BankedResetHolders?

        public init(account: Account, snapshot: UsageSnapshot, reports: [StoredProviderReport]) {
            func isOwned(_ provider: Provider, _ id: String) -> Bool {
                provider == account.metadata.provider && AccountDisplayMetadata.safeID(provider, id) == account.id
            }
            self.snapshot = UsageSnapshot(generatedAt: snapshot.generatedAt,
                limits: snapshot.limits.filter { isOwned($0.provider, $0.accountID) })
            let owned = reports.filter { isOwned($0.provider, $0.accountID) }
            self.reports = owned
            bankedAdvice = account.bankedAdvice.map { advice in
                Dictionary(owned.map { ($0.accountID, advice) }, uniquingKeysWith: { first, _ in first })
            } ?? [:]
            bankedResetHolders = AccountOverview.bankedResetHolders([account])
        }
    }

    /// A provider page uses the same observations, forecasts and expiry ordering as All Accounts.
    public func filtered(to provider: Provider) -> AccountOverview {
        AccountOverview(accounts: accounts.filter { $0.metadata.provider == provider },
                        deadlines: deadlines.filter { $0.provider == provider }, rankedAt: rankedAt, launchEvidence: launchEvidence,
                        rankings: rankings.filter { $0.key == provider },
                        allRankings: allRankings.filter { $0.key == provider })
    }

    public var closest: Account? {
        accounts.filter(\.isReliable).reduce(nil) { best, row in
            guard let best else { return row }
            return (row.remainingFraction ?? 1) < (best.remainingFraction ?? 1) ? row : best
        }
    }
    /// The first entry of the provider's Use next ranking (#791), without launch receipts.
    public func useNext(provider: Provider) -> Account? {
        useNextRanking(provider: provider).useNextAccountID.flatMap { id in accounts.first { $0.id == id } }
    }

    /// Replay selection at the last observation when a glance surface needs its last-good account.
    /// This is selection evidence only: render the original accounts with their actual freshness.
    public func lastObservedSelection() -> AccountOverview {
        let observed = accounts.compactMap(\.observedAt).max() ?? rankedAt
        let replay = accounts.map { account -> Account in
            guard [.stale, .unavailable].contains(account.state) else { return account }
            let known = account.hasKnownCapacity
            let windows = account.windows.map { window -> Window in
                var replay = window
                if known, [.stale, .failure].contains(replay.status) { replay.status = .healthy }
                return replay
            }
            return Account(metadata: account.metadata, state: known ? .available : .unknown,
                windows: windows, bankedResets: account.bankedResets,
                bankedState: account.bankedState, observedAt: account.observedAt,
                providerPlan: account.providerPlan, resetAssessment: account.resetAssessment)
        }
        return AccountOverview(accounts: replay, deadlines: deadlines, rankedAt: observed, launchEvidence: launchEvidence,
                               rankings: Self.makeRankings(accounts: replay, evidence: launchEvidence, now: observed))
    }
    public var nextDeadline: Deadline? { deadlines.first { $0.state == .available } }

    public init(snapshot: UsageSnapshot, reports: [StoredProviderReport], metadata: [AccountDisplayMetadata]? = nil,
                now: Date, maximumAge: TimeInterval = SnapshotFreshness.appMaximumAge,
                widgetsOnly: Bool = false, isSavedSnapshot: Bool = false,
                accountBurnRates: [String: [String: ObservedBurnRate]] = [:], launchEvidence: UseNextEvidence = UseNextEvidence()) {
        rankedAt = now
        self.launchEvidence = launchEvidence
        let presented = snapshot.presented(at: now)
        let entries = metadata ?? Self.inferredMetadata(snapshot: snapshot, reports: reports)
        let allAccounts = entries.map { entry in
            let limits = entry.sourceConfigured ? presented.limits.filter {
                $0.provider == entry.provider && AccountDisplayMetadata.safeID($0.provider, $0.accountID) == entry.id
            } : []
            let main = limits.filter(\.isAccountCapacityLimit)
            // AccountCapacity already classifies whole-source failures in readState.
            // A failed sibling must not replace this member's report or banked data.
            let report = reports.filter {
                $0.provider == entry.provider && AccountDisplayMetadata.safeID($0.provider, $0.accountID) == entry.id
            }.max { $0.generatedAt < $1.generatedAt }
            func windowStatus(_ limit: UsageLimit) -> UsageStatus {
                if limit.lastUpdatedAt == nil, report?.status == .failure { return .unknown }
                return limit.presentationStatus(at: now, maximumAge: maximumAge,
                    fallbackObservedAt: report?.generatedAt ?? snapshot.generatedAt)
            }
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
                       periodLabel: limit.windowLabel.map { ConnectorRedactor.safeErrorDescription($0) },
                       status: isSavedSnapshot ? .stale : windowStatus(limit),
                       period: MainLimitWindow.infer(from: limit), isAccountCapacityLimit: limit.isAccountCapacityLimit)
            }
            let observed = main.compactMap(\.lastUpdatedAt).min() ?? (report?.status == .failure ? nil : report?.generatedAt)
            let fresh = limits.filter { windowStatus($0) != .stale }
            let freshMain = fresh.filter(\.isAccountCapacityLimit)
            let state: AccountCapacityState
            if !entry.isEnabled { state = .off }
            else if entry.readState == .notConnected || (entry.provider == .anthropic && (report?.requiresCredentialReconnect == true || (report == nil && limits.isEmpty))) { state = .notConnected }
            else if entry.readState == .unavailable || report?.status == .failure { state = .unavailable }
            else if !main.isEmpty && (isSavedSnapshot || freshMain.isEmpty) { state = .stale }
            else if entry.readState == .stale && freshMain.isEmpty { state = .stale }
            else if entry.readState == .unknown || main.isEmpty || main.contains(where: { $0.remainingCapacityRatio == nil }) { state = .unknown }
            else {
                let reportStatus = report?.status == .stale && !freshMain.isEmpty ? .healthy : report?.status ?? .healthy
                state = switch AccountCapacity.usageStatus(limits: fresh, reportStatus: reportStatus) {
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
                // Claude plan labels come from a closed vocabulary and may carry a company name.
                return value.isEmpty ? nil : entry.provider == .anthropic ? value : value.capitalized
            }.first
            let plan = switch entry.provider {
            case .openAI: (namedPlan ?? notedPlan).map { ConnectorRedactor.safeErrorDescription($0) }
            case .anthropic: notedPlan.map { ConnectorRedactor.safeErrorDescription($0) }
            default: nil as String?
            }
            var account = Account(metadata: entry, state: state, windows: windows, bankedResets: banked,
                                  bankedState: bankedState, observedAt: observed, providerPlan: plan)
            account.isCodexSignInExpired = entry.provider == .openAI && report?.accessState.kind == .signInExpired
            account.spendsUsageCredits = entry.provider == .openAI && report?.accessState.kind == .paidFallbackActive
            return account
        }
        allRankings = Self.makeRankings(accounts: allAccounts, evidence: launchEvidence, now: now)
        let assessments = ResetAssessment.assessments(for: allAccounts, rankings: allRankings, now: now)
        accounts = allAccounts.filter { !widgetsOnly || $0.metadata.showInWidgets }.map { row in
            var account = row
            account.resetAssessment = assessments[account.id]
            return account
        }
        rankings = widgetsOnly && allAccounts.contains { !$0.metadata.showInWidgets }
            ? Self.makeRankings(accounts: accounts, evidence: launchEvidence, now: now) : allRankings
        deadlines = accounts.flatMap { account -> [Deadline] in
            guard account.metadata.isEnabled, let summary = account.bankedResets else { return [] }
            let dates = account.bankedExpiries(after: now, includeLastObserved: true)
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

    private static func makeRankings(accounts: [Account], evidence: UseNextEvidence, now: Date) -> [Provider: UseNextRanking] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            (provider, UseNextRanking.make(provider: provider, rows: accounts.filter { $0.metadata.provider == provider },
                evidence: evidence, now: now))
        })
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
