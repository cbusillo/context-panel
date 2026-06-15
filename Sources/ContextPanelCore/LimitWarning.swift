import Foundation

public struct LimitWarningSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var isEnabled: Bool
    public var thresholdPercentRemaining: Int
    public var playsSound: Bool

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case thresholdPercentRemaining
        case playsSound
    }

    public init(
        isEnabled: Bool = false,
        thresholdPercentRemaining: Int = 10,
        playsSound: Bool = true
    ) {
        schemaVersion = 1
        self.isEnabled = isEnabled
        self.thresholdPercentRemaining = Self.clampedThreshold(percent: thresholdPercentRemaining)
        self.playsSound = playsSound
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        thresholdPercentRemaining = Self.clampedThreshold(
            percent: try container.decode(Int.self, forKey: .thresholdPercentRemaining)
        )
        playsSound = try container.decodeIfPresent(Bool.self, forKey: .playsSound) ?? true
    }

    public static var defaultSettings: LimitWarningSettings {
        LimitWarningSettings()
    }

    public var thresholdCapacityRatio: Double {
        Double(thresholdPercentRemaining) / 100
    }

    public mutating func setThresholdPercentRemaining(_ percent: Int) {
        thresholdPercentRemaining = Self.clampedThreshold(percent: percent)
    }

    private static func clampedThreshold(percent: Int) -> Int {
        min(max(percent, 1), 75)
    }
}

public struct LimitWarningSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public func load() -> LimitWarningSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> LimitWarningSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try Self.makeDecoder().decode(
                LimitWarningSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else { return nil }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: LimitWarningSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public struct LimitWarningRecord: Codable, Equatable, Sendable {
    public let laneID: String
    public var lastThresholdPercentRemaining: Int
    public var lastNotifiedAt: Date
    public var lastCapacityRatio: Double
    public var resetIdentity: String?

    public init(
        laneID: String,
        lastThresholdPercentRemaining: Int,
        lastNotifiedAt: Date,
        lastCapacityRatio: Double,
        resetIdentity: String?
    ) {
        self.laneID = laneID
        self.lastThresholdPercentRemaining = lastThresholdPercentRemaining
        self.lastNotifiedAt = lastNotifiedAt
        self.lastCapacityRatio = lastCapacityRatio
        self.resetIdentity = resetIdentity
    }
}

public struct LimitWarningState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var records: [LimitWarningRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(records: [LimitWarningRecord] = []) {
        schemaVersion = 1
        self.records = Self.normalized(records)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        records = Self.normalized(try container.decode([LimitWarningRecord].self, forKey: .records))
    }

    public static var empty: LimitWarningState { LimitWarningState() }

    public func record(for laneID: String) -> LimitWarningRecord? {
        records.first { $0.laneID == laneID }
    }

    public mutating func upsert(_ record: LimitWarningRecord) {
        if let index = records.firstIndex(where: { $0.laneID == record.laneID }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records = Self.normalized(records)
    }

    public mutating func removeRecord(for laneID: String) {
        records.removeAll { $0.laneID == laneID }
    }

    private static func normalized(_ records: [LimitWarningRecord]) -> [LimitWarningRecord] {
        records
            .reduce(into: [String: LimitWarningRecord]()) { result, record in
                guard !record.laneID.isEmpty else { return }
                if let existing = result[record.laneID], existing.lastNotifiedAt > record.lastNotifiedAt {
                    return
                }
                result[record.laneID] = record
            }
            .values
            .sorted { lhs, rhs in lhs.laneID < rhs.laneID }
    }
}

public struct LimitWarningStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func load() -> LimitWarningState {
        loadIfAvailable() ?? .empty
    }

    public func loadIfAvailable() -> LimitWarningState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        do {
            let state = try Self.makeDecoder().decode(
                LimitWarningState.self,
                from: try Data(contentsOf: stateURL)
            )
            guard state.schemaVersion == 1 else { return nil }
            return state
        } catch {
            return nil
        }
    }

    public func save(_ state: LimitWarningState) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct LimitWarningEvent: Equatable, Identifiable, Sendable {
    public let laneID: String
    public let provider: Provider
    public let window: MainLimitWindow
    public let thresholdPercentRemaining: Int
    public let capacityRatio: Double
    public let remaining: Int?
    public let limit: Int?
    public let resetsAt: Date?
    public let accountCount: Int

    public var id: String { laneID }

    public var title: String {
        "\(provider.displayName) \(window.displayName) is low"
    }

    public var body: String {
        let percent = Int((capacityRatio * 100).rounded())
        let headroom = "\(percent)% left"
        let detail: String
        if let remaining, let limit {
            detail = "\(remaining) of \(limit) remaining"
        } else {
            detail = "capacity is below your warning threshold"
        }
        return "\(headroom) for \(provider.displayName) \(window.displayName); \(detail)."
    }
}

public enum LimitWarningEvaluator {
    public static func evaluate(
        settings: LimitWarningSettings,
        state: LimitWarningState,
        snapshot: UsageSnapshot,
        now: Date
    ) -> (events: [LimitWarningEvent], state: LimitWarningState) {
        guard settings.isEnabled else {
            return ([], .empty)
        }

        var nextState = state
        var events: [LimitWarningEvent] = []
        let currentLaneIDs = Set(snapshot.mainLimitSummaries.map(\.id))
        let staleLaneIDs = nextState.records
            .map(\.laneID)
            .filter { !currentLaneIDs.contains($0) }
        for laneID in staleLaneIDs {
            nextState.removeRecord(for: laneID)
        }

        for summary in snapshot.mainLimitSummaries {
            guard let usageRatio = summary.usageRatio else {
                nextState.removeRecord(for: summary.id)
                continue
            }

            let capacityRatio = max(1 - usageRatio, 0)
            let resetIdentity = summary.resetsAt.map { String(Int($0.timeIntervalSince1970)) }
            let existing = nextState.record(for: summary.id)
            if capacityRatio > recoveryCapacityRatio(for: settings) {
                nextState.removeRecord(for: summary.id)
                continue
            }

            guard capacityRatio <= settings.thresholdCapacityRatio else { continue }
            if shouldNotify(existing: existing, settings: settings, resetIdentity: resetIdentity) {
                let event = LimitWarningEvent(
                    laneID: summary.id,
                    provider: summary.provider,
                    window: summary.window,
                    thresholdPercentRemaining: settings.thresholdPercentRemaining,
                    capacityRatio: capacityRatio,
                    remaining: summary.remaining,
                    limit: summary.limit,
                    resetsAt: summary.resetsAt,
                    accountCount: summary.accountCount
                )
                events.append(event)
                nextState.upsert(LimitWarningRecord(
                    laneID: summary.id,
                    lastThresholdPercentRemaining: settings.thresholdPercentRemaining,
                    lastNotifiedAt: now,
                    lastCapacityRatio: capacityRatio,
                    resetIdentity: resetIdentity
                ))
            }
        }

        return (events.sorted { $0.capacityRatio < $1.capacityRatio }, nextState)
    }

    private static func recoveryCapacityRatio(for settings: LimitWarningSettings) -> Double {
        min(settings.thresholdCapacityRatio + 0.05, 1)
    }

    private static func shouldNotify(
        existing: LimitWarningRecord?,
        settings: LimitWarningSettings,
        resetIdentity: String?
    ) -> Bool {
        guard let existing else { return true }
        if existing.lastThresholdPercentRemaining != settings.thresholdPercentRemaining {
            return true
        }
        if existing.resetIdentity != resetIdentity {
            return true
        }
        return false
    }
}
