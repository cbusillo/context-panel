import Foundation

public struct CompanionSnapshot: Codable, Equatable, Sendable {
    /// Stored on the wire so older readers can detect newer companion payloads.
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date
    public let publishedAt: Date
    public let limits: [CompanionLimit]
    public let providerStatuses: [CompanionProviderStatus]
    public let promptCacheSummaries: [CompanionPromptCacheSummary]

    public init(
        generatedAt: Date,
        publishedAt: Date,
        limits: [CompanionLimit],
        providerStatuses: [CompanionProviderStatus],
        promptCacheSummaries: [CompanionPromptCacheSummary]
    ) {
        self.schemaVersion = Self.schemaVersion
        self.generatedAt = generatedAt
        self.publishedAt = publishedAt
        self.limits = limits
        self.providerStatuses = providerStatuses
        self.promptCacheSummaries = promptCacheSummaries
    }

    public init(storedSnapshot: StoredUsageSnapshot, publishedAt: Date = Date()) {
        self.init(
            generatedAt: storedSnapshot.snapshot.generatedAt,
            publishedAt: publishedAt,
            limits: storedSnapshot.snapshot.limits.map(CompanionLimit.init(limit:)),
            providerStatuses: storedSnapshot.reports.map(CompanionProviderStatus.init(report:)),
            promptCacheSummaries: CompanionPromptCacheSummary.summaries(
                observations: storedSnapshot.promptCacheObservations
            )
        )
    }
}

public struct CompanionLimit: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let label: String
    public let windowLabel: String?
    public let modelLabel: String?
    public let unit: UsageUnit
    public let used: Int?
    public let limit: Int?
    public let resetsAt: Date?
    public let lastUpdatedAt: Date?
    public let confidence: UsageConfidence
    public let status: UsageStatus

    public init(limit: UsageLimit) {
        provider = limit.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: limit.provider,
            accountID: limit.accountID,
            configuredAccountID: limit.configuredAccountID
        )
        accountName = CompanionAccountIdentity.displayName(limit.accountName)
        label = limit.label
        windowLabel = limit.windowLabel
        modelLabel = limit.modelLabel
        unit = limit.unit
        used = limit.used
        self.limit = limit.limit
        resetsAt = limit.resetsAt
        lastUpdatedAt = limit.lastUpdatedAt
        confidence = limit.confidence
        status = limit.status
    }
}

public struct CompanionProviderStatus: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let generatedAt: Date
    public let status: UsageStatus

    public init(report: StoredProviderReport) {
        provider = report.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: report.provider,
            accountID: report.accountID,
            configuredAccountID: report.configuredAccountID
        )
        accountName = CompanionAccountIdentity.displayName(report.accountName)
        generatedAt = report.generatedAt
        status = report.status
    }
}

public struct CompanionPromptCacheSummary: Codable, Equatable, Sendable {
    public let provider: Provider
    public let companionAccountID: String
    public let accountName: String
    public let latestObservedAt: Date
    public let latestHitRate: Double?
    public let tokenWeightedHitRate: Double?
    public let totalInputTokens: Int
    public let totalCachedInputTokens: Int

    public static func summaries(observations: [PromptCacheObservation]) -> [CompanionPromptCacheSummary] {
        Dictionary(grouping: observations, by: CompanionPromptCacheGroup.init(observation:))
            .map { group, observations in
                CompanionPromptCacheSummary(group: group, observations: observations)
            }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
    }

    private init(group: CompanionPromptCacheGroup, observations: [PromptCacheObservation]) {
        let summary = PromptCacheSummary(observations: observations)
        provider = group.provider
        companionAccountID = group.companionAccountID
        accountName = group.accountName
        latestObservedAt = summary.latest?.observedAt ?? observations.map(\.observedAt).max() ?? Date(timeIntervalSince1970: 0)
        latestHitRate = summary.latestHitRate
        tokenWeightedHitRate = summary.tokenWeightedHitRate
        totalInputTokens = summary.totalInputTokens
        totalCachedInputTokens = summary.totalCachedInputTokens
    }
}

private struct CompanionPromptCacheGroup: Hashable {
    let provider: Provider
    let companionAccountID: String
    let accountName: String

    init(observation: PromptCacheObservation) {
        provider = observation.provider
        companionAccountID = CompanionAccountIdentity.id(
            provider: observation.provider,
            accountID: observation.accountID,
            configuredAccountID: nil
        )
        accountName = CompanionAccountIdentity.displayName(observation.accountName)
    }
}

private enum CompanionAccountIdentity {
    static func id(provider: Provider, accountID: String, configuredAccountID: String?) -> String {
        ConnectorRedactor.localAccountID(
            provider: provider,
            stableID: "companion:\(configuredAccountID ?? accountID)"
        )
    }

    static func displayName(_ value: String) -> String {
        let redacted = ConnectorRedactor.redact(value)
        let pathRedacted = ConnectorRedactor.redactedPath(redacted)
        return pathRedacted.isEmpty ? "Account" : pathRedacted
    }
}
