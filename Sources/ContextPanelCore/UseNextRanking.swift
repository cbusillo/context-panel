import Foundation

// Use next (#791): spend the capacity that would otherwise go unused, soonest first.
// Every number here is in points: percent of the account's main window.

/// One count-only record a launcher writes for each agent session it starts.
/// It names the provider, the snapshot's opaque account ID and the launch time; nothing else.
public struct LaunchReceipt: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let provider: Provider
    public let accountID: String
    public let launchedAt: Date
    public var receiptID: String?

    public init(provider: Provider, accountID: String, launchedAt: Date, receiptID: String? = nil) {
        schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.accountID = accountID
        self.launchedAt = launchedAt
        self.receiptID = receiptID
    }
}

/// Launchers write receipts under `<storage root>/Launch Receipts/`, one JSON file each.
/// Context Panel only reads them; the writer removes its own files after a day.
public enum LaunchReceiptStore {
    public static let directoryName = "Launch Receipts"
    /// Receipts older than this no longer change the ranking.
    public static let lookback: TimeInterval = 24 * 3_600
    static let maximumFileCount = 5_000
    public static let maximumFileBytes = 1_024

    public static func load(rootDirectory: URL, now: Date) -> [LaunchReceipt] {
        let directory = rootDirectory.appending(path: directoryName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder.contextPanelISO8601
        return names.filter { $0.hasSuffix(".json") }.sorted().suffix(maximumFileCount).compactMap { name in
            let url = directory.appending(path: name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
                .flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }), size <= maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  var receipt = try? decoder.decode(LaunchReceipt.self, from: data) else { return nil }
            receipt.receiptID = ConnectorRedactor.localAccountID(provider: receipt.provider, stableID: name)
            return isUsable(receipt, now: now) ? receipt : nil
        }
    }

    public static func isUsable(_ receipt: LaunchReceipt, now: Date) -> Bool {
        receipt.schemaVersion == LaunchReceipt.currentSchemaVersion
            && receipt.accountID.range(of: "^\(receipt.provider.rawValue)-[0-9a-f]{1,64}$", options: .regularExpression) != nil
            && receipt.launchedAt <= now.addingTimeInterval(60) && receipt.launchedAt >= now.addingTimeInterval(-lookback)
    }
}

/// What the ranking knows beyond the readings themselves. Every field is optional evidence.
public struct UseNextEvidence: Codable, Equatable, Sendable {
    public var receipts: [LaunchReceipt]
    /// When each reading was saved (history and current); a receipt counts as reflected after two later readings.
    public var readingTimes: [Date]
    public var accountReadingTimes: [String: [Date]]?
    public var credits: [String: UsageCreditCapacity]?

    public init(receipts: [LaunchReceipt] = [], readingTimes: [Date] = [],
                accountReadingTimes: [String: [Date]]? = nil, credits: [String: UsageCreditCapacity]? = nil) {
        self.receipts = receipts
        self.readingTimes = readingTimes
        self.accountReadingTimes = accountReadingTimes
        self.credits = credits?.isEmpty == true ? nil : credits
    }

    public static func make(stored: StoredUsageSnapshot, history: [StoredUsageSnapshot],
        configuration: [LocalProviderAccountConfiguration], publisherID: String?,
        receipts: [LaunchReceipt], shared: Bool, enteredCreditExpiries: [Provider: Date] = [:]) -> Self {
        let readings = history + [stored]
        let companionResolve = accountResolver(readings: readings, configuration: configuration, publisherID: publisherID, shared: true)
        let resolve = shared ? companionResolve : accountResolver(readings: readings, configuration: configuration, publisherID: publisherID, shared: false)
        var aliases = Dictionary(readings.flatMap { $0.snapshot.limits }.flatMap { limit in
            return [(AccountDisplayMetadata.safeID(limit.provider, limit.accountID), resolve(limit)),
                    (companionResolve(limit), resolve(limit))]
        }, uniquingKeysWith: { _, current in current })
        for reading in readings {
            for alias in CompanionAccountIdentityAlias.verifiedAliases(stored: reading, configuration: configuration,
                publisherID: publisherID) where alias.reusableIdentity != nil {
                if let id = aliases[AccountDisplayMetadata.safeID(alias.provider, alias.replacementAccountID)] {
                    aliases[AccountDisplayMetadata.safeID(alias.provider, alias.legacyAccountID)] = id
                }
            }
        }
        let receipts = receipts.map { LaunchReceipt(provider: $0.provider, accountID: aliases[$0.accountID] ?? $0.accountID,
            launchedAt: $0.launchedAt, receiptID: $0.receiptID) }
        var accountTimes: [String: [Date]] = [:]
        for reading in readings {
            for id in Set(reading.snapshot.limits.map(resolve)) { accountTimes[id, default: []].append(reading.savedAt) }
        }
        accountTimes = accountTimes.mapValues { Array(Set($0).sorted().suffix(2)) }
        return Self(receipts: receipts, readingTimes: Array(Set(readings.map(\.savedAt)).sorted().suffix(2)),
            accountReadingTimes: accountTimes,
            credits: UsageCreditCapacity.make(stored: stored, history: history, resolve: resolve, entered: enteredCreditExpiries))
    }

    static func accountResolver(readings: [StoredUsageSnapshot], configuration: [LocalProviderAccountConfiguration],
        publisherID: String?, shared: Bool) -> ProviderRefillDetector.AccountResolver {
        let reports = Dictionary(readings.flatMap(\.reports).map { ($0.provider.rawValue + ":" + $0.accountID, $0) },
            uniquingKeysWith: { older, newer in newer.sharedAccountIdentity == nil ? older : newer })
        return { limit in
            AccountDisplayMetadata.safeID(limit.provider, shared ? MacSharedAccountPresentation.accountKey(limit: limit,
                report: reports[limit.provider.rawValue + ":" + limit.accountID], configuration: configuration,
                publisherID: publisherID) : limit.accountID)
        }
    }

    func retainingAccounts(_ ids: Set<String>) -> Self {
        Self(receipts: receipts.filter { ids.contains($0.accountID) }, readingTimes: readingTimes,
            accountReadingTimes: accountReadingTimes?.filter { ids.contains($0.key) }, credits: credits?.filter { ids.contains($0.key) })
    }

    func excludingAccounts(_ ids: Set<String>) -> Self {
        var result = self
        result.receipts.removeAll { ids.contains($0.accountID) }
        result.accountReadingTimes = accountReadingTimes?.filter { !ids.contains($0.key) }
        result.credits = credits?.filter { !ids.contains($0.key) }
        return result
    }

    func merging(_ other: Self, now: Date) -> Self {
        let grouped = { (values: [LaunchReceipt]) in
            Dictionary(grouping: values) { $0.receiptID.map { "id:\($0)" }
                ?? "legacy:\($0.provider.rawValue):\($0.accountID):\($0.launchedAt.timeIntervalSince1970)" }
        }
        let receipts = grouped(self.receipts).merging(grouped(other.receipts)) { $0.count >= $1.count ? $0 : $1 }
            .sorted { $0.key < $1.key }.flatMap(\.value)
            .filter { LaunchReceiptStore.isUsable($0, now: now) }
        let times = (accountReadingTimes ?? [:]).merging(other.accountReadingTimes ?? [:]) { Array(Set($0 + $1)).sorted() }
            .mapValues { Array($0.sorted().suffix(2)) }
        return Self(receipts: receipts, readingTimes: Array(Set(readingTimes + other.readingTimes).sorted().suffix(2)),
            accountReadingTimes: times.isEmpty ? nil : times, credits: (credits ?? [:]).merging(other.credits ?? [:]) { $0.observedAt > $1.observedAt ? $0 : $1 })
    }

    func reidentifyingAccounts(using aliases: [String: String]) -> Self {
        Self(receipts: receipts.map { LaunchReceipt(provider: $0.provider, accountID: aliases[$0.accountID] ?? $0.accountID,
                launchedAt: $0.launchedAt, receiptID: $0.receiptID) },
            readingTimes: readingTimes,
            accountReadingTimes: accountReadingTimes.map { times in
                Dictionary(times.map { (aliases[$0.key] ?? $0.key, $0.value) },
                    uniquingKeysWith: { Array(Set($0 + $1).sorted().suffix(2)) })
            }, credits: credits.map { values in
                Dictionary(values.map { (aliases[$0.key] ?? $0.key, $0.value) },
                    uniquingKeysWith: { $0.observedAt > $1.observedAt ? $0 : $1 })
            })
    }

    private enum CodingKeys: String, CodingKey { case launches, receipts, readingTimes, accountReadingTimes, credits }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let groups = try container.decodeIfPresent([String: [String: [String: Date]]].self, forKey: .launches) {
            receipts = try groups.sorted { $0.key < $1.key }.flatMap { provider, accounts -> [LaunchReceipt] in
                guard let provider = Provider(rawValue: provider) else {
                    throw DecodingError.dataCorruptedError(forKey: .launches, in: container, debugDescription: "Unknown launch provider")
                }
                return accounts.sorted { $0.key < $1.key }.flatMap { id, events in
                    events.sorted { $0.key < $1.key }.map { LaunchReceipt(provider: provider, accountID: id,
                        launchedAt: $0.value, receiptID: $0.key) }
                }
            }
        } else { receipts = try container.decodeIfPresent([LaunchReceipt].self, forKey: .receipts) ?? [] }
        readingTimes = try container.decodeIfPresent([Date].self, forKey: .readingTimes) ?? []
        accountReadingTimes = try container.decodeIfPresent([String: [Date]].self, forKey: .accountReadingTimes)
        let credits = try container.decodeIfPresent([String: UsageCreditCapacity].self, forKey: .credits)
        self.credits = credits?.isEmpty == true ? nil : credits
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let ids = receipts.compactMap(\.receiptID)
        if ids.count == receipts.count && Set(ids).count == ids.count {
            var groups: [String: [String: [String: Date]]] = [:]
            for receipt in receipts {
                if let id = receipt.receiptID {
                    groups[receipt.provider.rawValue, default: [:]][receipt.accountID, default: [:]][id] = receipt.launchedAt
                }
            }
            try container.encode(groups, forKey: .launches)
        } else { try container.encode(receipts, forKey: .receipts) }
        try container.encode(readingTimes, forKey: .readingTimes)
        try container.encodeIfPresent(accountReadingTimes, forKey: .accountReadingTimes)
        try container.encodeIfPresent(credits?.isEmpty == true ? nil : credits, forKey: .credits)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        let counts = { (receipts: [LaunchReceipt]) in Dictionary(grouping: receipts, by: { $0 }).mapValues { $0.count } }
        return counts(lhs.receipts) == counts(rhs.receipts) && lhs.readingTimes == rhs.readingTimes
            && lhs.accountReadingTimes == rhs.accountReadingTimes
            && (lhs.credits ?? [:]) == (rhs.credits ?? [:])
    }
}

public struct UseNextRanking: Encodable, Equatable, Sendable {
    public struct Entry: Encodable, Equatable, Sendable {
        public let accountID: String
        public let label: String
        public let reason: String
        public let deadline: Date
        public let unstarted: Bool
        public let remaining: Double
        public let burn: Double
        public let burnEstimated: Bool
        public let reserve: Double?
        public let pendingLaunches: Int
        public var notes: [String]
        /// Target for new work on this account, in weekly percentage points per hour.
        public var targetPointsPerHour: Double?
        public let canLaunch: Bool
        /// Zero is a plan, never an instruction to redeem a reset.
        public var depleteBy: Date?
        public let availablePoints: Double
        public let pointsPerLaunch: Double?
        public let bankedResetExpiresAt: Date?
        public let spendsCreditsBeforeReset: Bool
        /// Relative to this account's measured credit-spending workload, not weekly quota points.
        public let creditWorkloadMultiplier: Double?
    }

    public struct Exclusion: Encodable, Equatable, Sendable {
        public let accountID: String
        public let label: String
        public let reason: String
        public let until: Date?
    }

    public let provider: Provider
    public let entries: [Entry]
    public let excluded: [Exclusion]
    public let useNextAccountID: String?
    public let nextCapacityAt: Date?
    public let multipleUseLast: Bool
    public let basedOnStaleReadings: Bool
    public let readingsObservedAt: Date?
    public let launchOrder: [String]
    public let targetPointsPerHour: Double?
    public let forecast: ProviderPaceForecast?

    public static let useLastFloor: Double = 3
    public static let staleListMaximumAge: TimeInterval = 30 * 60
    static let minimumHours = 0.25
    static let weekHours = 7.0 * 24
    static let launchOrderLength = 10
    static let fiveHourGatePoints: Double = 5
    static let unstartedTolerance: TimeInterval = 10 * 60
    static let receiptReflectedAfter: TimeInterval = 30 * 60

    static func windowHours(_ period: MainLimitWindow?) -> Double {
        switch period {
        case .fiveHour: 5
        case .daily: 24
        case .weekly, .availability, nil: weekHours
        }
    }

    static func isUnstarted(used: Int?, resetsAt: Date?, observedAt: Date?) -> Bool {
        guard used == 0, let resetsAt, let observedAt else { return false }
        return abs(resetsAt.timeIntervalSince(observedAt) - weekHours * 3_600) <= unstartedTolerance
    }

    /// Deadline order, allowing for launches whose spend has not appeared in a reading yet.
    public static func nextPick(_ entries: [Entry], counts: [String: Int]) -> String? {
        entries.first { entry in
            entry.canLaunch && (entry.pointsPerLaunch.map {
                entry.availablePoints > Double(counts[entry.accountID, default: 0]) * $0
            } ?? (counts[entry.accountID, default: 0] == 0))
        }?.accountID
    }

    static func main<T>(of items: [T], provider: Provider, period: (T) -> MainLimitWindow?, model: (T) -> String?,
                        remaining: (T) -> Double?) -> T? {
        let weekly = items.filter { period($0) == .weekly }
        let pool = weekly.isEmpty ? items.filter { period($0) == .daily } : weekly
        guard !pool.isEmpty else { return items.count == 1 ? items.first : nil }
        let family = provider.generalModelFamily
        return pool.first { model($0)?.lowercased() == family }
            ?? pool.first { model($0) == nil }
            ?? pool.min { (remaining($0) ?? 1) < (remaining($1) ?? 1) }
    }

    public static func allocate(_ entries: [Entry], launches: Int, counts: [String: Int] = [:]) -> [String] {
        var counts = counts
        var picks: [String] = []
        for _ in 0..<max(0, launches) {
            guard let pick = nextPick(entries, counts: counts) else { break }
            picks.append(pick)
            counts[pick, default: 0] += 1
        }
        return picks
    }

    static func make(provider: Provider, rows: [AccountOverview.Account], evidence: UseNextEvidence, now: Date) -> Self {
        var evidence = evidence
        evidence.receipts = evidence.receipts.filter { LaunchReceiptStore.isUsable($0, now: now) }
        let multipleUseLast = rows.filter(\.metadata.useLast).count > 1
        let current = rows.filter { [.available, .closeToLimit, .limited].contains($0.state) }
        let savedCodex = rows.filter { $0.isCodexSignInExpired && $0.state == .unavailable && $0.hasKnownCapacity }
        let recentStale = current.isEmpty && !savedCodex.isEmpty ? rows.filter { row in
            row.state == .stale && row.observedAt.map {
                (0..<staleListMaximumAge).contains(now.timeIntervalSince($0))
            } == true
        } : []
        let launchable = current + savedCodex + recentStale
        let staleOnly = launchable.isEmpty && rows.contains { $0.state == .stale }
        let rankable = staleOnly ? rows.filter { $0.state == .stale } : launchable
        let pending = AccountOverview.pendingLaunches(evidence: evidence, rows: rows, now: now)
        let measured = current.compactMap { $0.mainWindow.flatMap { $0.isCurrent ? $0.burnPoints : nil } }
        let pace = measured.reduce(0, +)
        let averageBurn = measured.isEmpty ? 0 : pace / Double(measured.count)
        let pointsPerLaunch = AccountOverview.pointsPerLaunch(rows: rankable, evidence: evidence, now: now, multipleUseLast: multipleUseLast)
        var excluded: [Exclusion] = []
        var plans: [SpendPlan] = []
        for row in rows {
            let exclude = { (reason: String, until: Date?) in
                excluded.append(.init(accountID: row.id, label: row.metadata.label, reason: reason, until: until))
            }
            if row.state == .off { exclude("Off", nil); continue }
            guard rankable.contains(where: { $0.id == row.id }) else {
                exclude(row.state == .stale ? "Reading is not current" : "No current reading", nil); continue
            }
            guard let main = row.mainWindow, let fraction = main.remainingFraction,
                  main.confidence != .unknown else { exclude("No weekly reading", nil); continue }
            let assumesCodexReset = row.isCodexSignInExpired && main.naturalResetAt.map { reset in
                main.observedAt.map { $0 < reset && reset <= now } == true
            } == true
            let assumedFull = main.assumption != nil || assumesCodexReset
            let remaining = assumesCodexReset ? 100 : fraction * 100
            let unstarted = !assumesCodexReset && provider == .openAI && row.isUnstarted(main)
            let fresh = assumedFull || unstarted ? now.addingTimeInterval(windowHours(main.period) * 3_600) : nil
            guard let refill = fresh ?? main.naturalResetAt, refill > now else { exclude("Reset time unknown", nil); continue }
            var gatedUntil: Date?
            if let gate = row.fiveHourGate, gate.isCurrent || (gate.naturalResetAt ?? .distantPast) > now,
               let gateFraction = gate.remainingFraction {
                let hours = gate.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 3_600) } ?? 0
                if gateFraction * 100 < fiveHourGatePoints || (gate.isCurrent && (gate.burnPoints ?? 0) * hours >= gateFraction * 100) {
                    if !row.spendsUsageCredits {
                        exclude("5-hour limit nearly used; free again at its 5-hour reset", gate.naturalResetAt)
                        gatedUntil = gate.naturalResetAt ?? refill
                    }
                }
            }
            if remaining <= 0 && !row.spendsUsageCredits && gatedUntil == nil {
                exclude("Out of quota until its reset", refill)
            }
            let burn = main.isCurrent ? main.burnPoints : nil
            let personal = row.metadata.useLast && !multipleUseLast ? AccountOverview.personalBurn(row: row, burn: burn,
                evidence: evidence, pointsPerLaunch: pointsPerLaunch, now: now) : nil
            let hours = max(minimumHours, refill.timeIntervalSince(now) / 3_600)
            let reserve = row.metadata.useLast && !multipleUseLast ? min(remaining, max(useLastFloor, (personal ?? 0) * hours)) : nil
            var notes = row.windows.filter { window in
                window.id != main.id && window.id != row.fiveHourGate?.id && (window.remainingFraction ?? 1) <= 0
                    && (window.naturalResetAt ?? .distantFuture) > now
            }.map { "\($0.modelLabel ?? $0.label) is used up; only that model waits for its reset" }
            if assumedFull { notes.append(AccountTerms.assumedResetLaunch) }
            if row.isCodexSignInExpired { notes.append(AccountTerms.codexSignInExpired) }
            if row.state == .stale { notes.append(AccountCapacityState.stale.displayText) }
            plans.append(SpendPlan(row: row, remaining: remaining, refill: refill, burn: burn ?? averageBurn,
                burnEstimated: burn == nil, unstarted: unstarted, reserve: reserve, notes: notes,
                credits: evidence.credits?[row.id], gatedUntil: gatedUntil, now: now))
        }
        let forecast = current.isEmpty ? nil : ProviderPaceForecast(provider: provider, plans: plans, pace: pace, measured: !measured.isEmpty,
            complete: plans.count == current.count && current.count == rows.filter {
                $0.metadata.isEnabled && $0.metadata.sourceConfigured && $0.state != .notConnected
            }.count, now: now)
        let hasOtherQuota = { (plan: SpendPlan) in rows.contains {
            $0.id != plan.row.id && $0.metadata.isEnabled && $0.metadata.sourceConfigured
                && $0.state != .notConnected && ($0.mainWindow?.remainingFraction ?? 1) > 0
        } }
        // Emptying a protected account requires using the other quota first.
        let protectedExpiry = plans.filter {
            ($0.reserve ?? 0) > 0 && $0.deadline < $0.refill && hasOtherQuota($0)
        }.map(\.deadline).min()
        if let protectedExpiry {
            let target = plans.filter { ($0.reserve ?? 0) > 0 && $0.deadline == protectedExpiry }.map(\.targetDeadline).min() ?? protectedExpiry
            for index in plans.indices where plans[index].remaining > 0 {
                plans[index].deadline = min(plans[index].deadline, protectedExpiry)
                plans[index].targetDeadline = min(plans[index].targetDeadline, target)
            }
        }
        plans.sort {
            $0.deadline != $1.deadline ? $0.deadline < $1.deadline
                : max(0, $0.remaining - ($0.reserve ?? 0)) > max(0, $1.remaining - ($1.reserve ?? 0))
        }
        var cumulative = 0.0
        let requiredPace = plans.reduce(forecast?.minimumExpiryPace ?? 0) { required, plan in
            let held = hasOtherQuota(plan) && protectedExpiry == nil ? plan.reserve ?? 0 : 0
            cumulative += max(0, plan.remaining - held) + plan.additionalDuePoints
            let hours = max(minimumHours, plan.targetDeadline.timeIntervalSince(now) / 3_600)
            return max(required, cumulative / hours)
        }
        let wanted = max(requiredPace, min(pace, forecast?.sustainablePointsPerHour ?? requiredPace))
        var unallocated = wanted
        var entries = plans.filter { $0.gatedUntil == nil && ($0.remaining > 0 || $0.row.spendsUsageCredits) }.map { plan in
            let held = hasOtherQuota(plan) ? plan.reserve ?? 0 : 0
            let available = max(0, plan.remaining - held)
            let isHeld = plan.remaining > 0 && available <= 0
            let creditOnly = plan.creditOnly
            let planQuotaElsewhere = creditOnly && plans.contains {
                !$0.creditOnly && $0.gatedUntil == nil && $0.remaining > 0 && $0.deadline <= plan.deadline
            }
            let room = plan.spendingCredits ? Double.greatestFiniteMagnitude : min(available, plan.shortRoomPoints ?? available)
            let count = pending[plan.row.id, default: 0]
            let fitsPending = pointsPerLaunch.map { room > Double(count) * $0 } ?? (count == 0)
            let eligible = !isHeld && !planQuotaElsewhere && fitsPending
            let feasible = plan.feasiblePointsPerHour(now: now)
            let targetUnknown = creditOnly && plan.creditPoints == nil
            let target = eligible && !targetUnknown ? min(unallocated, feasible ?? unallocated) : 0
            unallocated -= target
            let projectedZero = !creditOnly && target > 0 && held == 0 ? now.addingTimeInterval(plan.remaining / target * 3_600) : nil
            let zero = projectedZero.flatMap { $0 <= plan.targetDeadline ? $0 : nil }
            var reason = isHeld ? "Holding about \(Int(held.rounded()))% for your own use while another account has quota."
                : planQuotaElsewhere ? "Plan quota that expires sooner goes first."
                : !fitsPending ? "Waiting for pending launches to appear in a reading; refresh before adding more work."
                : creditOnly && plan.credits?.expiresAt == nil ? "Plan quota used up; credits keep it working after quota with known deadlines."
                : "Spend what expires first, by \(ContextPanelDateFormatting.resetDeadline(plan.deadline))."
            let unreadableQuota = rows.contains { other in other.id != plan.row.id && other.metadata.isEnabled && other.metadata.sourceConfigured
                && other.state != .notConnected && !rankable.contains(where: { $0.id == other.id }) }
            if isHeld && unreadableQuota { reason += " Refresh or sign in to the other account to confirm which quota remains." }
            if held > 0 && !isHeld { reason += " Keep about \(Int(held.rounded()))% for your own use." }
            if plan.bankedDue > 0 {
                reason += plan.spendsCreditsBeforeReset ? " Spend the credits that expire sooner before applying its banked reset."
                    : held > 0 ? " Reaching 0% for its expiring reset waits for the other quota to be used."
                    : " Reach 0% before the banked reset expires; only you can apply it (\(plan.bankedDue) left)."
            }
            if let credits = plan.credits, let expiry = credits.expiresAt, expiry > now {
                reason += (creditOnly ? " Spend credits before " : " Reach 0%, then spend credits before ")
                    + ContextPanelDateFormatting.resetDeadline(expiry) + "."
                if plan.credits?.runwayHours == nil { reason += " Credit spend is not measured yet." }
                if let multiplier = plan.creditWorkloadMultiplier(now: now) {
                    reason += String(format: " Credit work needs %.1f times its recent workload before that deadline.", multiplier)
                }
            }
            var notes = plan.notes
            if feasible != nil && target < wanted { notes.insert("5-hour capacity needs work on other accounts too.", at: 0) }
            if feasible == nil && target > plan.burn { notes.insert("More work needed; achievable pace is unproved.", at: 0) }
            reason += notes.first.map { " " + $0 } ?? ""
            return Entry(accountID: plan.row.id, label: plan.row.metadata.label, reason: reason, deadline: plan.deadline,
                unstarted: plan.unstarted, remaining: plan.remaining, burn: plan.burn, burnEstimated: plan.burnEstimated,
                reserve: plan.reserve.map { _ in held }, pendingLaunches: pending[plan.row.id, default: 0], notes: notes,
                targetPointsPerHour: targetUnknown ? nil : target, canLaunch: eligible,
                depleteBy: zero, availablePoints: room,
                pointsPerLaunch: pointsPerLaunch, bankedResetExpiresAt: plan.bankedDue > 0 ? plan.row.soonestBankedExpiry(after: now) : nil,
                spendsCreditsBeforeReset: plan.spendsCreditsBeforeReset,
                creditWorkloadMultiplier: eligible ? plan.creditWorkloadMultiplier(now: now) : nil)
        }
        if unallocated > 0, let index = entries.firstIndex(where: \.canLaunch) {
            entries[index].notes.insert("Some capacity may expire unused; available pace is too low.", at: 0)
        }
        entries.sort { nextPick([$0], counts: pending) != nil && nextPick([$1], counts: pending) == nil }
        let observed = rankable.compactMap(\.observedAt).min()
        let usable = !staleOnly || observed.map { now.timeIntervalSince($0) <= staleListMaximumAge } == true
        let order = usable ? allocate(entries, launches: launchOrderLength, counts: pending) : []
        let first = staleOnly ? nil : order.first
        for index in entries.indices where entries[index].accountID != first {
            entries[index].depleteBy = nil
            if staleOnly { entries[index].targetPointsPerHour = nil }
        }
        let pendingRetry = evidence.receipts.filter { pending[$0.accountID, default: 0] > 0 }
            .map { $0.launchedAt.addingTimeInterval(receiptReflectedAfter) }.filter { $0 > now }.min()
        return Self(provider: provider, entries: entries, excluded: excluded, useNextAccountID: first,
            nextCapacityAt: first == nil && !staleOnly ? (excluded.compactMap(\.until) + [pendingRetry].compactMap { $0 }).filter { $0 > now }.min() : nil,
            multipleUseLast: multipleUseLast, basedOnStaleReadings: staleOnly, readingsObservedAt: staleOnly ? observed : nil,
            launchOrder: order, targetPointsPerHour: first == nil || entries.first(where: { $0.accountID == first })?.targetPointsPerHour == nil
                ? nil : entries.compactMap(\.targetPointsPerHour).reduce(0, +),
            forecast: forecast)
    }
}

struct SpendPlan {
    let row: AccountOverview.Account
    let remaining: Double
    let refill: Date
    let burn: Double
    let burnEstimated: Bool
    let unstarted: Bool
    let reserve: Double?
    let notes: [String]
    let credits: UsageCreditCapacity?
    let gatedUntil: Date?
    var deadline: Date
    var targetDeadline: Date
    let bankedDue: Int
    let additionalDuePoints: Double
    let bankedPoints: Double
    let creditPoints: Double?
    let bankedResetExpiry: Date?

    init(row: AccountOverview.Account, remaining: Double, refill: Date, burn: Double, burnEstimated: Bool,
         unstarted: Bool, reserve: Double?, notes: [String], credits: UsageCreditCapacity?, gatedUntil: Date?, now: Date) {
        self.row = row; self.remaining = remaining; self.refill = refill; self.burn = burn
        self.burnEstimated = burnEstimated; self.unstarted = unstarted; self.reserve = reserve; self.notes = notes
        self.gatedUntil = gatedUntil
        self.credits = credits.flatMap {
            !$0.available || $0.observedAt > now.addingTimeInterval(60)
                || $0.expiresAt.map { $0 <= now } == true ? nil : $0
        }
        let banked = row.bankedState == .available ? row.bankedResets : nil
        let recognized = banked.map { row.metadata.provider != .anthropic || $0.generalWeeklyOnly } == true
        let expiries = row.bankedExpiries(after: now)
        bankedResetExpiry = expiries.min()
        let due = expiries.filter { $0 > now && $0 < refill }
        bankedDue = due.filter { $0 == due.min() }.count
        bankedPoints = recognized ? Double(banked?.availableCount ?? 0) * 100 : 0
        creditPoints = self.credits.flatMap { credit in credit.runwayHours.flatMap { burn > 0 ? $0 * burn : nil } }
        let creditDeadline = self.credits?.expiresAt
        let applyBy = due.min().map { max(now, $0.addingTimeInterval(-ResetAssessment.expiringWithin)) }
        deadline = remaining <= 0 ? creditDeadline ?? .distantFuture : min(refill, due.min() ?? refill, creditDeadline ?? refill)
        targetDeadline = min(deadline, applyBy ?? deadline)
        additionalDuePoints = Double(max(0, bankedDue - 1)) * 100
            + (remaining <= 0 || creditDeadline.map { $0 <= refill && $0 <= (due.min() ?? refill) } == true ? creditPoints ?? 0 : 0)
    }

    var shortRoomPoints: Double? {
        guard !spendingCredits else { return nil }
        guard let gate = row.fiveHourGate, let fraction = gate.remainingFraction, let ratio = weeklyToShortBurn else { return nil }
        return max(0, fraction * 100 * ratio)
    }

    var creditOnly: Bool {
        remaining <= 0 && row.spendsUsageCredits
    }

    var spendingCredits: Bool { Self.usesCredits(row: row, remaining: remaining) }

    var spendsCreditsBeforeReset: Bool {
        guard creditOnly, row.bankedState == .available, (row.bankedResets?.availableCount ?? 0) > 0,
              let expiry = credits?.expiresAt,
              let reset = bankedResetExpiry else { return false }
        return expiry < reset
    }

    func creditWorkloadMultiplier(now: Date) -> Double? {
        guard let runway = credits?.runwayHours, let expiry = credits?.expiresAt else { return nil }
        let deadline = spendsCreditsBeforeReset ? min(expiry, (bankedResetExpiry ?? expiry).addingTimeInterval(-ResetAssessment.expiringWithin)) : expiry
        return runway / max(UseNextRanking.minimumHours, deadline.timeIntervalSince(now) / 3_600)
    }

    private static func usesCredits(row: AccountOverview.Account, remaining: Double) -> Bool {
        row.spendsUsageCredits && (remaining <= 0 || (row.fiveHourGate?.remainingFraction ?? 1) * 100 < UseNextRanking.fiveHourGatePoints)
    }

    private var weeklyToShortBurn: Double? {
        if let short = row.fiveHourGate?.burnPoints, short > 0, burn > 0 { return burn / short }
        return row.metadata.provider == .anthropic ? ResetAssessment.claudeDefaultRate / 20 : nil
    }

    func feasiblePointsPerHour(now: Date) -> Double? {
        guard let room = shortRoomPoints, let reset = row.fiveHourGate?.naturalResetAt, let ratio = weeklyToShortBurn else { return nil }
        let refills = reset < targetDeadline ? floor(targetDeadline.timeIntervalSince(reset) / (5 * 3_600)) + 1 : 0
        return (room + refills * 100 * ratio) / max(UseNextRanking.minimumHours, targetDeadline.timeIntervalSince(now) / 3_600)
    }
}

public extension AccountOverview {
    var configurationErrors: [String] {
        Provider.allCases.compactMap { provider in
            accounts.filter { $0.metadata.provider == provider && $0.metadata.useLast }.count > 1
                ? "multipleUseLast:\(provider.rawValue)" : nil
        }
    }

    func useNextRanking(provider: Provider, evidence suppliedEvidence: UseNextEvidence? = nil) -> UseNextRanking {
        if suppliedEvidence == nil, let ranking = rankings[provider] { return ranking }
        return UseNextRanking.make(provider: provider, rows: accounts.filter { $0.metadata.provider == provider },
            evidence: suppliedEvidence ?? launchEvidence, now: rankedAt)
    }
}

extension AccountOverview {
    /// Receipts the readings don't reflect yet: fewer than two later readings and under 30 minutes old.
    static func pendingLaunches(evidence: UseNextEvidence, rows: [Account], now: Date) -> [String: Int] {
        let ids = Set(rows.map(\.id))
        // Saved reading times when known; without history, each account's own observation stands in.
        let readings = evidence.readingTimes.isEmpty ? rows.compactMap(\.observedAt) : evidence.readingTimes
        return evidence.receipts.reduce(into: [:]) { counts, receipt in
            guard ids.contains(receipt.accountID), receipt.launchedAt <= now.addingTimeInterval(60),
                  now.timeIntervalSince(receipt.launchedAt) < UseNextRanking.receiptReflectedAfter,
                  Set((evidence.accountReadingTimes?[receipt.accountID] ?? readings).filter { $0 > receipt.launchedAt }).count < 2 else { return }
            counts[receipt.accountID, default: 0] += 1
        }
    }

    /// Agent use per launch, measured on the provider's other accounts over the receipt lookback.
    static func pointsPerLaunch(rows: [Account], evidence: UseNextEvidence, now: Date, multipleUseLast: Bool) -> Double? {
        let hours = LaunchReceiptStore.lookback / 3_600
        var points = 0.0
        var launches = 0
        for row in rows where !(row.metadata.useLast && !multipleUseLast) {
            guard let main = row.mainWindow, main.isCurrent, let burn = main.burnPoints else { continue }
            let count = evidence.receipts.filter { $0.accountID == row.id
                && now.timeIntervalSince($0.launchedAt) <= LaunchReceiptStore.lookback }.count
            guard count > 0 else { continue }
            points += burn * hours
            launches += count
        }
        return launches > 0 ? points / Double(launches) : nil
    }

    /// The Director's own burn on the use-last account: observed burn minus agent burn from receipts.
    /// Nil when it can't be measured; the cushion floor then applies.
    static func personalBurn(row: Account, burn: Double?, evidence: UseNextEvidence,
                             pointsPerLaunch: Double?, now: Date) -> Double? {
        guard let burn else { return nil }
        let launches = evidence.receipts.filter { $0.accountID == row.id
            && now.timeIntervalSince($0.launchedAt) <= LaunchReceiptStore.lookback }.count
        if launches == 0 { return burn }
        guard let pointsPerLaunch else { return nil }
        return max(0, burn - Double(launches) * pointsPerLaunch / (LaunchReceiptStore.lookback / 3_600))
    }
}

public extension AccountOverview.Window {
    /// Observed burn in points per hour.
    var burnPoints: Double? { burnFractionPerHour.map { $0 * 100 } }
}

public extension AccountOverview.Account {
    /// The window whose capacity lapses: the general weekly window, not a model-only window.
    var mainWindow: AccountOverview.Window? {
        UseNextRanking.main(of: windows, provider: metadata.provider, period: \.period, model: \.modelLabel,
                            remaining: \.remainingFraction)
    }

    /// The 5-hour window that gates new sessions for the main window's models.
    var fiveHourGate: AccountOverview.Window? {
        guard let main = mainWindow else { return nil }
        return windows.first { $0.period == .fiveHour && $0.modelLabel?.lowercased() == main.modelLabel?.lowercased() }
    }

    /// An OpenAI clock that hasn't started: nothing used, and the reset slides to a week after each reading.
    func isUnstarted(_ main: AccountOverview.Window) -> Bool {
        UseNextRanking.isUnstarted(used: main.used, resetsAt: main.naturalResetAt, observedAt: main.observedAt)
    }
}

extension Provider {
    var generalModelFamily: String {
        switch self {
        case .openAI: "codex"
        case .anthropic: "claude"
        case .google: "gemini"
        }
    }
}
