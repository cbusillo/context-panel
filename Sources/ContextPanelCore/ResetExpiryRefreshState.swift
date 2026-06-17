import Foundation

public struct ResetExpiryRefreshKey: Codable, Equatable, Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let limitID: String
    public let resetsAt: Date

    public init(
        provider: Provider,
        accountID: String,
        configuredAccountID: String?,
        limitID: String,
        resetsAt: Date
    ) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.limitID = limitID
        self.resetsAt = resetsAt
    }

    public init?(limit: UsageLimit) {
        guard let resetsAt = limit.resetsAt else { return nil }
        self.init(
            provider: limit.provider,
            accountID: limit.accountID,
            configuredAccountID: limit.configuredAccountID,
            limitID: limit.id,
            resetsAt: resetsAt
        )
    }
}

public struct ResetExpiryRefreshRecord: Codable, Equatable, Sendable {
    public var key: ResetExpiryRefreshKey
    public var attemptedAt: Date
    public var nextRetryAt: Date?
    public var retryCount: Int

    public init(
        key: ResetExpiryRefreshKey,
        attemptedAt: Date,
        nextRetryAt: Date?,
        retryCount: Int
    ) {
        self.key = key
        self.attemptedAt = attemptedAt
        self.nextRetryAt = nextRetryAt
        self.retryCount = retryCount
    }

    public var identity: String { key.identity }
}

public struct ResetExpiryRefreshState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var records: [ResetExpiryRefreshRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(records: [ResetExpiryRefreshRecord] = []) {
        schemaVersion = 1
        self.records = records
    }

    public static var empty: ResetExpiryRefreshState { ResetExpiryRefreshState() }

    public func record(for key: ResetExpiryRefreshKey) -> ResetExpiryRefreshRecord? {
        records.first { $0.key == key }
    }

    public func nextRetryDate(for snapshot: UsageSnapshot, now: Date = Date()) -> Date? {
        let dueIdentities = Set(snapshot.resetRefreshDueKeys(now: now).map(\.identity))
        return records
            .filter { dueIdentities.contains($0.identity) }
            .compactMap(\.nextRetryAt)
            .min()
    }

    public func nextRefreshCheckDate(for snapshot: UsageSnapshot, now: Date = Date()) -> Date? {
        snapshot.limits.compactMap { limit -> Date? in
            guard let resetRefreshDate = limit.nextResetRefreshDate(now: now) else { return nil }
            guard resetRefreshDate <= now else { return resetRefreshDate }
            guard let key = ResetExpiryRefreshKey(limit: limit) else { return nil }
            guard let record = record(for: key) else { return now }
            guard let nextRetryAt = record.nextRetryAt else { return nil }
            return max(nextRetryAt, now)
        }.min()
    }

    public mutating func recordAttempt(
        previousSnapshot: UsageSnapshot?,
        refreshedSnapshot: UsageSnapshot,
        attemptedAccounts: Set<ResetExpiryRefreshAccountKey>? = nil,
        attemptedAt: Date,
        retryDelay: TimeInterval = SnapshotFreshness.resetExpiryRetryDelay
    ) {
        guard let previousSnapshot else {
            prune(for: refreshedSnapshot)
            return
        }

        let previousDueKeys = Set(previousSnapshot.resetRefreshDueKeys(now: attemptedAt))
        let refreshedDueKeys = Set(refreshedSnapshot.resetRefreshDueKeys(now: attemptedAt))
        let attemptedPreviousIdentities = Set(previousDueKeys.filter { key in
            guard let attemptedAccounts else { return true }
            return attemptedAccounts.contains { $0.matches(key) }
        }.map(\.identity))
        let liveIdentities = Set(refreshedSnapshot.limits.compactMap { ResetExpiryRefreshKey(limit: $0)?.identity })
        let stuckKeys = previousDueKeys.intersection(refreshedDueKeys).filter { key in
            attemptedPreviousIdentities.contains(key.identity)
        }
        let existingByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })

        let preservedRecords = records.filter { record in
            !attemptedPreviousIdentities.contains(record.identity) && liveIdentities.contains(record.identity)
        }
        records = preservedRecords + stuckKeys.sortedByIdentity.map { key in
            let existing = existingByIdentity[key.identity]
            let retryCount = (existing?.retryCount ?? 0) + 1
            return ResetExpiryRefreshRecord(
                key: key,
                attemptedAt: attemptedAt,
                nextRetryAt: retryCount == 1 ? attemptedAt.addingTimeInterval(retryDelay) : nil,
                retryCount: retryCount
            )
        }
    }

    public mutating func recordAttemptWithoutSnapshot(
        previousSnapshot: UsageSnapshot?,
        attemptedAt: Date,
        retryDelay: TimeInterval = SnapshotFreshness.resetExpiryRetryDelay
    ) {
        guard let previousSnapshot else { return }
        let stuckKeys = previousSnapshot.resetRefreshDueKeys(now: attemptedAt)
        guard !stuckKeys.isEmpty else {
            records.removeAll()
            return
        }
        let existingByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })
        records = stuckKeys.sortedByIdentity.map { key in
            let existing = existingByIdentity[key.identity]
            let retryCount = (existing?.retryCount ?? 0) + 1
            return ResetExpiryRefreshRecord(
                key: key,
                attemptedAt: attemptedAt,
                nextRetryAt: retryCount == 1 ? attemptedAt.addingTimeInterval(retryDelay) : nil,
                retryCount: retryCount
            )
        }
    }

    public mutating func deferDueResets(
        previousSnapshot: UsageSnapshot?,
        attemptedAt: Date,
        retryDelay: TimeInterval = SnapshotFreshness.resetExpiryRetryDelay
    ) {
        guard let previousSnapshot else { return }
        let dueKeys = previousSnapshot.resetRefreshDueKeys(now: attemptedAt)
        guard !dueKeys.isEmpty else { return }
        let existingByIdentity = Dictionary(uniqueKeysWithValues: records.map { ($0.identity, $0) })
        let deferredRecords = dueKeys.sortedByIdentity.map { key in
            let existing = existingByIdentity[key.identity]
            return ResetExpiryRefreshRecord(
                key: key,
                attemptedAt: existing?.attemptedAt ?? attemptedAt,
                nextRetryAt: attemptedAt.addingTimeInterval(retryDelay),
                retryCount: existing?.retryCount ?? 0
            )
        }
        let deferredIdentities = Set(deferredRecords.map(\.identity))
        records.removeAll { deferredIdentities.contains($0.identity) }
        records.append(contentsOf: deferredRecords)
    }

    public mutating func prune(for snapshot: UsageSnapshot) {
        let liveIdentities = Set(snapshot.limits.compactMap { ResetExpiryRefreshKey(limit: $0)?.identity })
        records.removeAll { !liveIdentities.contains($0.identity) }
    }
}

public struct ResetExpiryRefreshAccountKey: Equatable, Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?

    public init(provider: Provider, accountID: String, configuredAccountID: String?) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
    }

    public init(key: ResetExpiryRefreshKey) {
        self.init(
            provider: key.provider,
            accountID: key.accountID,
            configuredAccountID: key.configuredAccountID
        )
    }

    public init(report: ProviderConnectorReport) {
        self.init(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID
        )
    }

    public func matches(_ key: ResetExpiryRefreshKey) -> Bool {
        guard provider == key.provider else { return false }
        if let configuredAccountID {
            return configuredAccountID == key.configuredAccountID || accountID == key.accountID
        }
        return accountID == key.accountID
    }
}

public struct ResetExpiryRefreshStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public static func appDefault() -> ResetExpiryRefreshStateStore {
        ResetExpiryRefreshStateStore(
            stateURL: ContextPanelLocations.resetExpiryRefreshStateURL(appGroupID: ContextPanelLocations.appGroupID)
        )
    }

    public func load() -> ResetExpiryRefreshState {
        loadIfAvailable() ?? .empty
    }

    public func loadIfAvailable() -> ResetExpiryRefreshState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        do {
            let state = try Self.makeDecoder().decode(
                ResetExpiryRefreshState.self,
                from: try Data(contentsOf: stateURL)
            )
            guard state.schemaVersion == 1 else { return nil }
            return state
        } catch {
            return nil
        }
    }

    public func save(_ state: ResetExpiryRefreshState) throws {
        try withExclusiveLock {
            try saveUnlocked(state)
        }
    }

    public func update(_ body: (inout ResetExpiryRefreshState) -> Void) throws {
        try withExclusiveLock {
            var state = loadIfAvailable() ?? .empty
            body(&state)
            try saveUnlocked(state)
        }
    }

    private func saveUnlocked(_ state: ResetExpiryRefreshState) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        var coordinationError: NSError?
        var operationError: Error?
        var result: Result<T, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: stateURL,
            options: .forReplacing,
            error: &coordinationError
        ) { _ in
            do {
                result = .success(try body())
            } catch {
                operationError = error
                result = .failure(error)
            }
        }
        if let operationError { throw operationError }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
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

public extension UsageSnapshot {
    func resetRefreshDueKeys(now: Date = Date()) -> [ResetExpiryRefreshKey] {
        limits.compactMap { limit in
            guard limit.isResetRefreshDue(now: now) else { return nil }
            return ResetExpiryRefreshKey(limit: limit)
        }
    }

    func nextResetRefreshDate(now: Date = Date()) -> Date? {
        limits.compactMap { $0.nextResetRefreshDate(now: now) }.min()
    }
}

public extension UsageLimit {
    func isResetRefreshDue(now: Date = Date()) -> Bool {
        guard let resetRefreshDate = nextResetRefreshDate(now: now) else { return false }
        return resetRefreshDate <= now
    }

    func nextResetRefreshDate(now: Date = Date()) -> Date? {
        guard let resetsAt else { return nil }
        guard status != .failure, status != .unknown, status != .stale else { return nil }
        guard used != nil || limit != nil else { return nil }
        guard resetsAt > (lastUpdatedAt ?? .distantPast) else { return nil }
        return resetsAt.addingTimeInterval(SnapshotFreshness.resetExpiryRefreshGrace)
    }
}

private extension ResetExpiryRefreshKey {
    var identity: String {
        let resetIdentity = String(Int(resetsAt.timeIntervalSince1970))
        return [provider.rawValue, configuredAccountID ?? accountID, limitID, resetIdentity]
            .joined(separator: "|")
    }
}

private extension Sequence where Element == ResetExpiryRefreshKey {
    var sortedByIdentity: [ResetExpiryRefreshKey] {
        sorted { lhs, rhs in lhs.identity < rhs.identity }
    }
}
