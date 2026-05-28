import Foundation

public struct StoredUsageSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let savedAt: Date
    public let snapshot: UsageSnapshot
    public let reports: [StoredProviderReport]

    public init(savedAt: Date, snapshot: UsageSnapshot, reports: [StoredProviderReport] = []) {
        self.schemaVersion = 1
        self.savedAt = savedAt
        self.snapshot = snapshot
        self.reports = reports
    }

    public init(savedAt: Date, refreshResult: ConnectorRefreshResult) {
        self.init(
            savedAt: savedAt,
            snapshot: refreshResult.snapshot,
            reports: refreshResult.reports.map(StoredProviderReport.init(report:))
        )
    }
}

public struct StoredProviderReport: Codable, Equatable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let generatedAt: Date
    public let status: UsageStatus
    public let errorMessage: String?

    public init(
        provider: Provider,
        accountID: String,
        configuredAccountID: String? = nil,
        accountName: String,
        generatedAt: Date,
        status: UsageStatus,
        errorMessage: String?
    ) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.accountName = accountName
        self.generatedAt = generatedAt
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }

    public init(report: ProviderConnectorReport) {
        self.init(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID,
            accountName: report.accountName,
            generatedAt: report.generatedAt,
            status: report.status,
            errorMessage: report.errorMessage
        )
    }
}

public enum SnapshotStoreError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema(version: Int)
    case corruptStore(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "Unsupported snapshot schema version \(version)"
        case let .corruptStore(message):
            message
        }
    }
}

public struct SnapshotStoreLoadResult: Equatable, Sendable {
    public let snapshot: StoredUsageSnapshot?
    public let status: UsageStatus
    public let errorMessage: String?

    public init(snapshot: StoredUsageSnapshot?, status: UsageStatus, errorMessage: String? = nil) {
        self.snapshot = snapshot
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct SnapshotStoreQuery: Equatable, Sendable {
    public let provider: Provider?
    public let accountID: String?
    public let since: Date?
    public let limit: Int?

    public init(provider: Provider? = nil, accountID: String? = nil, since: Date? = nil, limit: Int? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.since = since
        self.limit = limit
    }
}

public struct SnapshotStoreStalenessPolicy: Equatable, Sendable {
    public let maximumAge: TimeInterval

    public init(maximumAge: TimeInterval = 15 * 60) {
        precondition(maximumAge >= 0, "maximumAge must not be negative")
        self.maximumAge = maximumAge
    }

    public func status(for storedSnapshot: StoredUsageSnapshot?, now: Date) -> UsageStatus {
        guard let storedSnapshot else { return .unknown }
        if now.timeIntervalSince(storedSnapshot.savedAt) > maximumAge {
            return .stale
        }
        return storedSnapshot.snapshot.aggregateStatus
    }
}

public struct JSONSnapshotStore: Sendable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    public var currentSnapshotURL: URL {
        rootDirectory.appending(path: "current-snapshot.json")
    }

    public var historyDirectoryURL: URL {
        rootDirectory.appending(path: "history", directoryHint: .isDirectory)
    }

    public func save(_ storedSnapshot: StoredUsageSnapshot) throws {
        try ensureDirectories()
        let data = try Self.makeEncoder().encode(storedSnapshot)
        try data.write(to: currentSnapshotURL, options: [.atomic])
        let historyURL = historyURL(for: storedSnapshot.savedAt)
        try data.write(to: historyURL, options: [.atomic])
    }

    public func saveMerged(refreshResult: ConnectorRefreshResult, savedAt: Date) throws {
        try saveMerged(refreshResult: refreshResult, savedAt: savedAt, preservesUnreportedAccounts: true)
    }

    public func saveMerged(
        refreshResult: ConnectorRefreshResult,
        savedAt: Date,
        preservesUnreportedAccounts: Bool
    ) throws {
        let reportedAccounts = Set(
            refreshResult.reports.map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) }
        )
        let replacementAccounts = Set(
            refreshResult.reports
                .filter { !$0.limits.isEmpty }
                .map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) }
        )
        let current = loadCurrent().snapshot
        let preservedLimits: [UsageLimit]
        let preservedReports: [StoredProviderReport]
        if preservesUnreportedAccounts {
            preservedLimits = current?.snapshot.limits.filter { limit in
                !replacementAccounts.contains(ProviderAccountKey(provider: limit.provider, accountID: limit.accountID))
            } ?? []
            preservedReports = current?.reports.filter { report in
                !reportedAccounts.contains(ProviderAccountKey(provider: report.provider, accountID: report.accountID))
            } ?? []
        } else {
            preservedLimits = current?.snapshot.limits.filter { limit in
                reportedAccounts.contains(ProviderAccountKey(provider: limit.provider, accountID: limit.accountID))
                    && !replacementAccounts.contains(ProviderAccountKey(provider: limit.provider, accountID: limit.accountID))
            } ?? []
            preservedReports = []
        }

        let currentAccountKeys = Set(
            current?.snapshot.limits.map { ProviderAccountKey(provider: $0.provider, accountID: $0.accountID) } ?? []
        )
        let successfulProviders = Set(refreshResult.reports.filter { !$0.limits.isEmpty }.map(\.provider))
        let preservedFailureLimits = current?.snapshot.limits.filter { limit in
            refreshResult.reports.contains { report in
                guard report.status == .failure, report.limits.isEmpty, report.provider == limit.provider else {
                    return false
                }
                let reportKey = ProviderAccountKey(provider: report.provider, accountID: report.accountID)
                if currentAccountKeys.contains(reportKey) {
                    return report.accountID == limit.accountID
                }
                return !successfulProviders.contains(report.provider)
            }
        } ?? []

        let mergedSnapshot = UsageSnapshot(
            generatedAt: refreshResult.generatedAt,
            limits: (preservedLimits + preservedFailureLimits + refreshResult.snapshot.limits).deduplicatedByID()
        )
        let mergedReports = preservedReports + refreshResult.reports.map(StoredProviderReport.init(report:))

        try save(StoredUsageSnapshot(savedAt: savedAt, snapshot: mergedSnapshot, reports: mergedReports))
    }

    public func loadCurrent() -> SnapshotStoreLoadResult {
        guard FileManager.default.fileExists(atPath: currentSnapshotURL.path) else {
            return SnapshotStoreLoadResult(snapshot: nil, status: .unknown)
        }

        do {
            let snapshot = try loadSnapshot(from: currentSnapshotURL)
            return SnapshotStoreLoadResult(snapshot: snapshot, status: snapshot.snapshot.aggregateStatus)
        } catch {
            return SnapshotStoreLoadResult(
                snapshot: nil,
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    public func loadCurrent(policy: SnapshotStoreStalenessPolicy, now: Date = Date()) -> SnapshotStoreLoadResult {
        let result = loadCurrent()
        guard result.status != .failure else { return result }
        return SnapshotStoreLoadResult(
            snapshot: result.snapshot,
            status: policy.status(for: result.snapshot, now: now),
            errorMessage: result.errorMessage
        )
    }

    public func loadHistory(query: SnapshotStoreQuery = SnapshotStoreQuery()) -> [StoredUsageSnapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: historyDirectoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let snapshots = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? loadSnapshot(from: $0) }
            .filter { snapshot in
                if let since = query.since, snapshot.savedAt < since { return false }
                if let provider = query.provider, !snapshot.snapshot.limits.contains(where: { $0.provider == provider }) {
                    return false
                }
                if let accountID = query.accountID, !snapshot.snapshot.limits.contains(where: { $0.accountID == accountID }) {
                    return false
                }
                return true
            }
            .sorted { $0.savedAt > $1.savedAt }

        if let limit = query.limit {
            return Array(snapshots.prefix(max(limit, 0)))
        }
        return snapshots
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyDirectoryURL, withIntermediateDirectories: true)
    }

    private func loadSnapshot(from url: URL) throws -> StoredUsageSnapshot {
        let data = try Data(contentsOf: url)
        let snapshot = try Self.makeDecoder().decode(StoredUsageSnapshot.self, from: data)
        guard snapshot.schemaVersion == 1 else {
            throw SnapshotStoreError.unsupportedSchema(version: snapshot.schemaVersion)
        }
        return snapshot
    }

    private func historyURL(for date: Date) -> URL {
        let timestamp = ContextPanelDateFormatting.historyFileTimestamp(from: date)
        return historyDirectoryURL.appending(path: "\(timestamp).json")
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

private struct ProviderAccountKey: Hashable {
    let provider: Provider
    let accountID: String
}

private extension Array where Element == UsageLimit {
    func deduplicatedByID() -> [UsageLimit] {
        var seen = Set<String>()
        return filter { limit in
            seen.insert(limit.id).inserted
        }
    }
}

extension ContextPanelDateFormatting {
    static func historyFileTimestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
    }
}
