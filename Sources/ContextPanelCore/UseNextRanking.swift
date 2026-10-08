import Foundation

// Use next (#791): spend the capacity that would otherwise go unused, soonest first.
// Every number here is in points: percent of the account's main window.

/// One count-only record a launcher writes for each agent session it starts.
/// It names the provider, the snapshot's opaque account ID and the launch time; nothing else.
public struct LaunchReceipt: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let provider: Provider
    public let accountID: String
    public let launchedAt: Date

    public init(provider: Provider, accountID: String, launchedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.provider = provider
        self.accountID = accountID
        self.launchedAt = launchedAt
    }
}

/// Launchers write receipts under `<storage root>/Launch Receipts/`, one JSON file each.
/// Context Panel only reads them; the writer removes its own files after a day.
public enum LaunchReceiptStore {
    public static let directoryName = "Launch Receipts"
    /// Receipts older than this no longer change the ranking.
    public static let lookback: TimeInterval = 24 * 3_600
    static let maximumFileCount = 5_000
    static let maximumFileBytes = 1_024

    public static func load(rootDirectory: URL, now: Date) -> [LaunchReceipt] {
        let directory = rootDirectory.appending(path: directoryName)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder.contextPanelISO8601
        return names.filter { $0.hasSuffix(".json") }.sorted().suffix(maximumFileCount).compactMap { name in
            let url = directory.appending(path: name)
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
                .flatMap({ $0.isRegularFile == true ? $0.fileSize : nil }), size <= maximumFileBytes,
                  let data = try? Data(contentsOf: url),
                  let receipt = try? decoder.decode(LaunchReceipt.self, from: data) else { return nil }
            return isUsable(receipt, now: now) ? receipt : nil
        }
    }

    static func isUsable(_ receipt: LaunchReceipt, now: Date) -> Bool {
        receipt.schemaVersion == LaunchReceipt.currentSchemaVersion
            && receipt.accountID.range(of: "^\(receipt.provider.rawValue)-[0-9a-f]{1,64}$", options: .regularExpression) != nil
            && receipt.launchedAt <= now.addingTimeInterval(60) && receipt.launchedAt >= now.addingTimeInterval(-lookback)
    }
}

/// What the ranking knows beyond the readings themselves. Every field is optional evidence.
public struct UseNextEvidence: Equatable, Sendable {
    public var receipts: [LaunchReceipt]
    /// When each reading was saved (history and current); a receipt counts as reflected after two later readings.
    public var readingTimes: [Date]
    /// For an unstarted OpenAI account, the first reading in the current unstarted run.
    public var unstartedSince: [String: Date]

    public init(receipts: [LaunchReceipt] = [], readingTimes: [Date] = [], unstartedSince: [String: Date] = [:]) {
        self.receipts = receipts
        self.readingTimes = readingTimes
        self.unstartedSince = unstartedSince
    }
}

public struct UseNextRanking: Encodable, Equatable, Sendable {
    public enum Tier: Int, Codable, Sendable {
        /// Capacity that lapses unless more work is sent: unstarted OpenAI clocks and positive need.
        case needsUse = 1
        /// The provider's use-last account, above its personal cushion.
        case useLast = 2
        /// On pace or ahead; used only when no account has positive need.
        case onPace = 3
    }

    public struct Entry: Encodable, Equatable, Sendable {
        public let accountID: String
        public let label: String
        public let tier: Tier
        /// Extra points per hour needed so nothing lapses at the deadline; negative when ahead of pace.
        public let need: Double
        /// The D'Hondt weight a batch splits by; zero takes no launches.
        public let weight: Double
        public let reason: String
        public let deadline: Date
        public let unstarted: Bool
        /// Gets one launch before the batch is split, to start its clock.
        public let starter: Bool
        public let remaining: Double
        public let burn: Double
        public let burnEstimated: Bool
        /// Points held for the Director's own use on the use-last account.
        public let reserve: Double?
        /// Launches from receipts that the readings don't show yet.
        public let pendingLaunches: Int
        public let notes: [String]
    }

    public struct Exclusion: Encodable, Equatable, Sendable {
        public let accountID: String
        public let label: String
        public let reason: String
        /// When the account can take work again, when known.
        public let until: Date?
    }

    public let provider: Provider
    public let entries: [Entry]
    public let excluded: [Exclusion]
    public let useNextAccountID: String?
    /// With nothing rankable, the earliest time capacity returns.
    public let nextCapacityAt: Date?
    /// More than one use-last account on this provider: a configuration error; use-last is ignored.
    public let multipleUseLast: Bool
    /// Every reading is stale; this is the last list, published with its age.
    public let basedOnStaleReadings: Bool
    public let readingsObservedAt: Date?
    /// Account IDs for the next launches in order, by D'Hondt over the weights.
    public let launchOrder: [String]

    /// The personal cushion never goes below this many points.
    public static let useLastFloor: Double = 3
    /// A stale list may still steer launches while its readings are this young.
    public static let staleListMaximumAge: TimeInterval = 30 * 60
    static let minimumHours = 0.25
    static let weekHours = 7.0 * 24
    static let launchOrderLength = 10
    static let fiveHourGatePoints: Double = 5
    static let unstartedTolerance: TimeInterval = 10 * 60
    static let starterDelay: TimeInterval = 3_600
    static let receiptReflectedAfter: TimeInterval = 30 * 60

    static func isUnstarted(used: Int?, resetsAt: Date?, observedAt: Date?) -> Bool {
        guard used == 0, let resetsAt, let observedAt else { return false }
        return abs(resetsAt.timeIntervalSince(observedAt) - weekHours * 3_600) <= unstartedTolerance
    }

    /// D'Hondt: starters first, then the highest weight ÷ (1 + launches already given).
    public static func nextPick(_ entries: [Entry], counts: [String: Int]) -> String? {
        if let starter = entries.first(where: { $0.starter && counts[$0.accountID, default: 0] == 0 }) {
            return starter.accountID
        }
        var best: (entry: Entry, quotient: Double)?
        for entry in entries where entry.weight > 0 {
            let given = counts[entry.accountID, default: 0] - (entry.starter ? 1 : 0)
            let quotient = entry.weight / Double(1 + max(0, given))
            if let current = best {
                if quotient > current.quotient + 1e-12
                    || abs(quotient - current.quotient) <= 1e-12
                        && (entry.tier.rawValue, -entry.weight) < (current.entry.tier.rawValue, -current.entry.weight) {
                    best = (entry, quotient)
                }
            } else {
                best = (entry, quotient)
            }
        }
        return best?.entry.accountID
    }

    /// The general weekly window (daily when there is none), not a model-only window such as gpt-reserve.
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

    /// Splits a batch of launches, continuing from the launches already counted.
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
}

public extension AccountOverview {
    /// `multipleUseLast:<provider>` for each provider with more than one use-last account.
    var configurationErrors: [String] {
        Provider.allCases.compactMap { provider in
            accounts.filter { $0.metadata.provider == provider && $0.metadata.useLast }.count > 1
                ? "multipleUseLast:\(provider.rawValue)" : nil
        }
    }

    func useNextRanking(provider: Provider, evidence: UseNextEvidence = UseNextEvidence()) -> UseNextRanking {
        let now = rankedAt
        let rows = accounts.filter { $0.metadata.provider == provider }
        let multipleUseLast = rows.filter(\.metadata.useLast).count > 1
        let current = rows.filter { [.available, .closeToLimit, .limited].contains($0.state) }
        let staleOnly = current.isEmpty && rows.contains { $0.state == .stale }
        let rankable = staleOnly ? rows.filter { $0.state == .stale } : current
        let pending = Self.pendingLaunches(evidence: evidence, rows: rows, now: now)
        let measured = rankable.compactMap { $0.mainWindow?.burnPoints }
        let averageBurn = measured.isEmpty ? 0 : measured.reduce(0, +) / Double(measured.count)
        let pointsPerLaunch = Self.pointsPerLaunch(rows: rankable, evidence: evidence, now: now, multipleUseLast: multipleUseLast)

        var excluded: [UseNextRanking.Exclusion] = []
        var candidates: [Candidate] = []
        for row in rows {
            let exclude = { (reason: String, until: Date?) in
                excluded.append(.init(accountID: row.id, label: row.metadata.label, reason: reason, until: until))
            }
            if row.state == .off { exclude("Off", nil); continue }
            guard rankable.contains(where: { $0.id == row.id }) else {
                exclude(row.state == .stale ? "Reading is not current" : "No current reading", nil); continue
            }
            guard let main = row.mainWindow, let fraction = main.remainingFraction, main.assumption == nil,
                  main.confidence != .unknown else { exclude("No weekly reading", nil); continue }
            let remaining = fraction * 100
            guard remaining > 0 else { exclude("Out of quota until its reset", main.naturalResetAt); continue }
            if let gate = row.fiveHourGate, let gateFraction = gate.remainingFraction {
                let gateLeft = gateFraction * 100
                let hoursToGateReset = gate.naturalResetAt.map { max(0, $0.timeIntervalSince(now) / 3_600) }
                let projected = (gate.burnPoints ?? 0) * (hoursToGateReset ?? 0)
                if gateLeft < UseNextRanking.fiveHourGatePoints || projected > 0 && projected >= gateLeft {
                    exclude("5-hour limit nearly used; free again at its 5-hour reset", gate.naturalResetAt); continue
                }
            }
            let unstarted = provider == .openAI && row.isUnstarted(main)
            guard let deadline = unstarted ? now : main.naturalResetAt else { exclude("Reset time unknown", nil); continue }
            let burn = main.burnPoints ?? averageBurn
            let useLast = row.metadata.useLast && !multipleUseLast
            // An unstarted clock starts with the first launch, so its share is judged over a full week.
            let hours = unstarted ? UseNextRanking.weekHours : max(UseNextRanking.minimumHours, deadline.timeIntervalSince(now) / 3_600)
            var reserve: Double?
            var need = (remaining - burn * hours) / hours
            if useLast {
                // Cushion: the Director's own measured use until the window ends, at least the floor.
                let personal = Self.personalBurn(row: row, burn: main.burnPoints, evidence: evidence,
                                                 pointsPerLaunch: pointsPerLaunch, now: now)
                let cushion = max(UseNextRanking.useLastFloor, (personal ?? 0) * hours)
                reserve = cushion
                need = (remaining - cushion - max(0, burn - (personal ?? 0)) * hours) / hours
            }
            let starter = unstarted && (!useLast || evidence.unstartedSince[row.id].map {
                now.timeIntervalSince($0) >= UseNextRanking.starterDelay } ?? true)
            // Within the hour after a refill the Director may start the use-last clock personally.
            if unstarted && useLast && !starter { need = min(need, 0) }
            let notes = row.windows.filter { window in
                window.id != main.id && window.id != row.fiveHourGate?.id && (window.remainingFraction ?? 1) <= 0
            }.map { window in
                "\(window.modelLabel ?? window.label) is used up; only that model waits for its reset"
            }
            candidates.append(Candidate(row: row, remaining: remaining, burn: burn, burnEstimated: main.burnPoints == nil,
                                        hours: hours, deadline: deadline, unstarted: unstarted, starter: starter,
                                        useLast: useLast, reserve: reserve, need: need, notes: notes))
        }

        let active = candidates.filter { $0.starter || $0.need > 0 }
        var entries: [UseNextRanking.Entry] = []
        if active.isEmpty {
            // Demand is at or above capacity: last longest first, use-last only after the rest.
            let others = candidates.filter { !$0.useLast }
            for candidate in candidates {
                let hoursLeft = candidate.burn > 0 ? candidate.remaining / candidate.burn : candidate.hours
                if candidate.useLast, let reserve = candidate.reserve, candidate.remaining <= reserve {
                    excluded.append(.init(accountID: candidate.row.id, label: candidate.row.metadata.label,
                                          reason: "Use last: holding its cushion for your own use", until: nil))
                    continue
                }
                let inGrace = candidate.unstarted && !candidate.starter
                let weight = candidate.useLast ? (others.isEmpty && !inGrace ? 1 : 0) : hoursLeft
                entries.append(candidate.entry(tier: .onPace, weight: weight, pending: pending[candidate.row.id, default: 0],
                    reason: candidate.useLast ? "Use last: only once the others run out"
                        : "Every account is on pace to run out; this one lasts longest (about \(Int(hoursLeft.rounded())) hours)"))
            }
        } else {
            for candidate in candidates {
                let isActive = candidate.starter || candidate.need > 0
                let tier: UseNextRanking.Tier = !isActive ? .onPace : candidate.useLast ? .useLast : .needsUse
                let spare = max(0, candidate.remaining - (candidate.reserve ?? 0) - candidate.burn * candidate.hours)
                let reason: String
                if candidate.starter {
                    reason = candidate.useLast
                        ? "Use last, but its weekly clock still hasn't started; one launch starts it"
                        : "Its weekly clock hasn't started, and every idle hour is lost; start it now"
                } else if !isActive {
                    reason = candidate.useLast ? "Use last: holding its cushion for your own use"
                        : "On pace to use its allowance before its reset"
                } else if candidate.useLast {
                    reason = "Use last: keeps about \(Int(candidate.reserve?.rounded() ?? 0))% for your own use and spends the rest before its reset"
                } else {
                    reason = "About \(Int(spare.rounded()))% would go unused at its reset at the current pace"
                }
                entries.append(candidate.entry(tier: tier, weight: isActive ? max(0, candidate.need) : 0,
                                               pending: pending[candidate.row.id, default: 0], reason: reason))
            }
        }
        entries = Self.ordered(entries, counts: pending)

        let observed = rankable.compactMap(\.observedAt).min()
        // A stale list is published with its age; it steers launches only while young, and never Use next.
        let usable = !staleOnly || observed.map { now.timeIntervalSince($0) <= UseNextRanking.staleListMaximumAge } == true
        let first = staleOnly ? nil : entries.first.flatMap { entry in
            entry.weight > 0 || entry.starter && pending[entry.accountID, default: 0] == 0 ? entry.accountID : nil
        }
        let nextCapacity = first == nil && !staleOnly ? excluded.compactMap(\.until).filter { $0 > now }.min() : nil
        return UseNextRanking(provider: provider, entries: entries, excluded: excluded, useNextAccountID: first,
                              nextCapacityAt: nextCapacity, multipleUseLast: multipleUseLast,
                              basedOnStaleReadings: staleOnly, readingsObservedAt: staleOnly ? observed : nil,
                              launchOrder: usable ? UseNextRanking.allocate(entries, launches: UseNextRanking.launchOrderLength, counts: pending) : [])
    }
}

private struct Candidate {
    let row: AccountOverview.Account
    let remaining: Double
    let burn: Double
    let burnEstimated: Bool
    let hours: Double
    let deadline: Date
    let unstarted: Bool
    let starter: Bool
    let useLast: Bool
    let reserve: Double?
    let need: Double
    let notes: [String]

    func entry(tier: UseNextRanking.Tier, weight: Double, pending: Int, reason: String) -> UseNextRanking.Entry {
        UseNextRanking.Entry(accountID: row.id, label: row.metadata.label, tier: tier, need: need, weight: weight,
                             reason: reason, deadline: deadline, unstarted: unstarted, starter: starter,
                             remaining: remaining, burn: burn, burnEstimated: burnEstimated, reserve: reserve,
                             pendingLaunches: pending, notes: notes)
    }
}

extension AccountOverview {
    /// Published order is the D'Hondt order of the next launch: starters, then need ÷ (1 + pending launches)
    /// across tiers 1–2 with ties to the lower tier, then accounts taking none. Use next is the first entry,
    /// so a single launch and `launchOrder` always agree.
    static func ordered(_ entries: [UseNextRanking.Entry], counts: [String: Int]) -> [UseNextRanking.Entry] {
        func priority(_ entry: UseNextRanking.Entry) -> (Int, Double, Int, Double) {
            let given = counts[entry.accountID, default: 0]
            if entry.starter && given == 0 { return (0, 0, entry.tier.rawValue, 0) }
            guard entry.weight > 0 else { return (2, -entry.remaining, entry.tier.rawValue, 0) }
            return (1, -entry.weight / Double(1 + max(0, given - (entry.starter ? 1 : 0))), entry.tier.rawValue, -entry.weight)
        }
        return entries.enumerated().sorted { lhs, rhs in
            let (a, b) = (priority(lhs.element), priority(rhs.element))
            return a != b ? a < b : lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Receipts the readings don't reflect yet: fewer than two later readings and under 30 minutes old.
    static func pendingLaunches(evidence: UseNextEvidence, rows: [Account], now: Date) -> [String: Int] {
        let ids = Set(rows.map(\.id))
        // Saved reading times when known; without history, each account's own observation stands in.
        let readings = evidence.readingTimes.isEmpty ? rows.compactMap(\.observedAt) : evidence.readingTimes
        return evidence.receipts.reduce(into: [:]) { counts, receipt in
            guard ids.contains(receipt.accountID), receipt.launchedAt <= now.addingTimeInterval(60),
                  now.timeIntervalSince(receipt.launchedAt) < UseNextRanking.receiptReflectedAfter,
                  Set(readings.filter { $0 > receipt.launchedAt }).count < 2 else { return }
            counts[receipt.accountID, default: 0] += 1
        }
    }

    /// Agent use per launch, measured on the provider's other accounts over the receipt lookback.
    static func pointsPerLaunch(rows: [Account], evidence: UseNextEvidence, now: Date, multipleUseLast: Bool) -> Double? {
        let hours = LaunchReceiptStore.lookback / 3_600
        var points = 0.0
        var launches = 0
        for row in rows where !(row.metadata.useLast && !multipleUseLast) {
            guard let burn = row.mainWindow?.burnPoints else { continue }
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
