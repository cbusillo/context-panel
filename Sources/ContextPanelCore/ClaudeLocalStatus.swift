import Foundation

public struct ClaudeStatsCacheSummary: Codable, Equatable, Sendable {
    public let version: Int?
    public let lastComputedDate: Date?
    public let totalSessions: Int?
    public let totalMessages: Int?
    public let firstSessionDate: Date?
    public let modelUsageCount: Int
    public let dailyActivityCount: Int
    public let rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot?

    public init(
        version: Int?,
        lastComputedDate: Date?,
        totalSessions: Int?,
        totalMessages: Int?,
        firstSessionDate: Date?,
        modelUsageCount: Int,
        dailyActivityCount: Int,
        rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot? = nil
    ) {
        self.version = version
        self.lastComputedDate = lastComputedDate
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.firstSessionDate = firstSessionDate
        self.modelUsageCount = modelUsageCount
        self.dailyActivityCount = dailyActivityCount
        self.rateLimitSnapshot = rateLimitSnapshot
    }
}

public struct ClaudeUsageBlock: Codable, Equatable, Sendable {
    public let isActive: Bool
    public let totalTokens: Int?
    public let endTime: Date?
    public let projectedTotalTokens: Int?
    public let remainingMinutes: Int?
    public let modelCount: Int

    public init(
        isActive: Bool,
        totalTokens: Int?,
        endTime: Date?,
        projectedTotalTokens: Int?,
        remainingMinutes: Int?,
        modelCount: Int
    ) {
        self.isActive = isActive
        self.totalTokens = totalTokens
        self.endTime = endTime
        self.projectedTotalTokens = projectedTotalTokens
        self.remainingMinutes = remainingMinutes
        self.modelCount = modelCount
    }
}

public struct ClaudeUsageBlocksSummary: Codable, Equatable, Sendable {
    public let activeBlock: ClaudeUsageBlock?
    public let completedBlockTokenLimitEstimate: Int?

    public init(activeBlock: ClaudeUsageBlock?, completedBlockTokenLimitEstimate: Int?) {
        self.activeBlock = activeBlock
        self.completedBlockTokenLimitEstimate = completedBlockTokenLimitEstimate
    }
}

public enum ClaudeUsageBlocksParser {
    public static func summary(from data: Data) throws -> ClaudeUsageBlocksSummary {
        let payload = try JSONDecoder.contextPanelFlexibleDates.decode(ClaudeUsageBlocksPayload.self, from: data)
        let active = payload.blocks.first { $0.isActive }?.usageBlock
        let completedTokens = payload.blocks
            .filter { !$0.isActive }
            .compactMap(\.totalTokens)
            .filter { $0 > 0 }
            .sorted()
        let estimate = completedTokens.isEmpty ? nil : completedTokens[Int(Double(completedTokens.count - 1) * 0.95)]
        return ClaudeUsageBlocksSummary(activeBlock: active, completedBlockTokenLimitEstimate: estimate)
    }
}

public struct ClaudeSubscriptionRateLimitWindow: Codable, Equatable, Sendable {
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(label: String, usedPercent: Double, resetsAt: Date?) {
        self.label = label
        self.usedPercent = max(0, min(usedPercent, 100))
        self.resetsAt = resetsAt
    }
}

public struct ClaudeSubscriptionRateLimitSnapshot: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let windows: [ClaudeSubscriptionRateLimitWindow]

    public init(observedAt: Date, windows: [ClaudeSubscriptionRateLimitWindow]) {
        self.observedAt = observedAt
        self.windows = windows
    }
}

public enum ClaudeStatsCacheParser {
    public static func summary(from data: Data) throws -> ClaudeStatsCacheSummary {
        let payload = try JSONDecoder.contextPanelFlexibleDates.decode(ClaudeStatsCachePayload.self, from: data)
        return ClaudeStatsCacheSummary(
            version: payload.version,
            lastComputedDate: payload.lastComputedDate,
            totalSessions: payload.totalSessions,
            totalMessages: payload.totalMessages,
            firstSessionDate: payload.firstSessionDate,
            modelUsageCount: payload.modelUsage?.count ?? 0,
            dailyActivityCount: payload.dailyActivity?.count ?? 0,
            rateLimitSnapshot: payload.rateLimits?.snapshot(
                observedAt: payload.lastComputedDate ?? Date(timeIntervalSince1970: 0)
            )
        )
    }
}

public enum ClaudeSubscriptionRateLimitCacheParser {
    public static func snapshot(from data: Data) throws -> ClaudeSubscriptionRateLimitSnapshot {
        let payload = try JSONDecoder().decode(ClaudeStatuslineRateLimitPayload.self, from: data)
        var windows: [ClaudeSubscriptionRateLimitWindow] = []
        if let fiveHour = payload.rateLimits.fiveHour {
            windows.append(fiveHour.window(label: "5-hour"))
        }
        if let sevenDay = payload.rateLimits.sevenDay {
            windows.append(sevenDay.window(label: "Weekly"))
        }
        return ClaudeSubscriptionRateLimitSnapshot(
            observedAt: Date(timeIntervalSince1970: TimeInterval(payload.observedAt)),
            windows: windows
        )
    }
}

public struct ClaudeAccountConfiguration: Equatable, Sendable {
    public let accountName: String
    public let statsPath: String?
    public let rateLimitSnapshotPath: String
    public let fallbackRateLimitSnapshotPaths: [String]
    public let rateLimitSnapshotMaximumAge: TimeInterval
    public let usageBlocksPath: String?
    public let fallbackUsageBlocksPaths: [String]

    public init(
        accountName: String = "Claude",
        statsPath: String? = nil,
        rateLimitSnapshotPath: String? = nil,
        fallbackRateLimitSnapshotPaths: [String]? = nil,
        rateLimitSnapshotMaximumAge: TimeInterval = 30 * 60,
        usageBlocksPath: String? = nil,
        fallbackUsageBlocksPaths: [String]? = nil
    ) {
        self.accountName = accountName
        self.statsPath = statsPath
        let rateLimitPaths = ContextPanelLocations.claudeStatuslineCacheURLs().map(\.path)
        let resolvedRateLimitPath = rateLimitSnapshotPath ?? rateLimitPaths.first ?? ContextPanelLocations.claudeStatuslineCacheURL().path
        self.rateLimitSnapshotPath = resolvedRateLimitPath
        self.fallbackRateLimitSnapshotPaths = fallbackRateLimitSnapshotPaths
            ?? rateLimitPaths.filter { $0 != resolvedRateLimitPath }
        self.rateLimitSnapshotMaximumAge = rateLimitSnapshotMaximumAge
        let usageBlocksPaths = ContextPanelLocations.claudeCCUsageBlocksCacheURLs().map(\.path)
        let resolvedUsageBlocksPath = usageBlocksPath ?? usageBlocksPaths.first ?? ContextPanelLocations.claudeCCUsageBlocksCacheURL().path
        self.usageBlocksPath = resolvedUsageBlocksPath
        self.fallbackUsageBlocksPaths = fallbackUsageBlocksPaths
            ?? usageBlocksPaths.filter { $0 != resolvedUsageBlocksPath }
    }
}

public struct ClaudeLocalStatusConnector: ProviderConnector {
    public let provider: Provider = .anthropic

    private let accounts: [ClaudeAccountConfiguration]
    private let fileLoader: @Sendable (String) throws -> Data
    private let fileExists: @Sendable (String) -> Bool

    public init(
        accounts: [ClaudeAccountConfiguration],
        fileLoader: @escaping @Sendable (String) throws -> Data = { path in
            try Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        },
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
        }
    ) {
        self.accounts = accounts
        self.fileLoader = fileLoader
        self.fileExists = fileExists
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        reports.reserveCapacity(accounts.count)
        for account in accounts {
            reports.append(refresh(account: account, now: now))
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }

    private func refresh(account: ClaudeAccountConfiguration, now: Date) -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, path: account.rateLimitSnapshotPath)

        do {
            let statsSummary = try loadStatsSummary(path: account.statsPath)
            let rateLimitSnapshot = try loadRateLimitSnapshot(paths: [account.rateLimitSnapshotPath] + account.fallbackRateLimitSnapshotPaths)
                ?? statsSummary?.rateLimitSnapshot
            let usageBlocksSummary = try loadUsageBlocksSummary(paths: [account.usageBlocksPath].compactMap { $0 } + account.fallbackUsageBlocksPaths)

            // Infer login state from local evidence. A stale cache still proves
            // a configured Claude statusline and should render as stale rather
            // than collapsing the weekly window to unknown.
            let hasSessions = (statsSummary?.totalSessions ?? 0) > 0
            let hasRateLimitCache = rateLimitSnapshot?.windows.isEmpty == false
            let hasUsageBlocks = usageBlocksSummary?.activeBlock != nil
            let loggedIn = hasSessions || hasRateLimitCache || hasUsageBlocks

            let limits = claudeLocalStatusLimits(
                loggedIn: loggedIn,
                statsSummary: statsSummary,
                rateLimitSnapshot: rateLimitSnapshot,
                rateLimitSnapshotMaximumAge: account.rateLimitSnapshotMaximumAge,
                usageBlocksSummary: usageBlocksSummary,
                accountID: localAccountID,
                accountName: account.accountName,
                observedAt: now
            )
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: limits,
                status: loggedIn ? limits.map(\.status).contextPanelWorstStatus : .unknown
            )
        } catch {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: [],
                status: .failure,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func loadStatsSummary(path: String?) throws -> ClaudeStatsCacheSummary? {
        guard let path, fileExists(path) else { return nil }
        return try ClaudeStatsCacheParser.summary(from: try fileLoader(path))
    }

    private func loadRateLimitSnapshot(paths: [String]) throws -> ClaudeSubscriptionRateLimitSnapshot? {
        var firstError: Error?
        var snapshots: [ClaudeSubscriptionRateLimitSnapshot] = []

        for path in paths {
            guard fileExists(path) else { continue }
            do {
                snapshots.append(try ClaudeSubscriptionRateLimitCacheParser.snapshot(from: try fileLoader(path)))
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if snapshots.isEmpty, let firstError {
            throw firstError
        }
        return snapshots.sorted { $0.observedAt > $1.observedAt }.first
    }

    private func loadUsageBlocksSummary(paths: [String]) throws -> ClaudeUsageBlocksSummary? {
        var firstError: Error?

        for path in paths where fileExists(path) {
            do {
                return try ClaudeUsageBlocksParser.summary(from: try fileLoader(path))
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError {
            throw firstError
        }
        return nil
    }
}

public func claudeLocalStatusLimits(
    loggedIn: Bool,
    statsSummary: ClaudeStatsCacheSummary?,
    rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot? = nil,
    rateLimitSnapshotMaximumAge: TimeInterval = 30 * 60,
    usageBlocksSummary: ClaudeUsageBlocksSummary? = nil,
    accountID: String,
    accountName: String,
    observedAt: Date
) -> [UsageLimit] {
    if loggedIn, let rateLimitSnapshot, !rateLimitSnapshot.windows.isEmpty {
        let isStale = observedAt.timeIntervalSince(rateLimitSnapshot.observedAt) > rateLimitSnapshotMaximumAge
        if isStale, let estimatedLimit = claudeUsageBlockEstimate(
            usageBlocksSummary: usageBlocksSummary,
            loggedIn: loggedIn,
            accountID: accountID,
            accountName: accountName,
            observedAt: observedAt
        ) {
            return [estimatedLimit]
        }

        let sourceNote = isStale ? "source: stale Claude Code statusline" : "source: Claude Code statusline"
        return rateLimitSnapshot.windows.map { window in
            UsageLimit(
                provider: .anthropic,
                accountID: accountID,
                accountName: accountName,
                label: "Claude \(window.label)",
                windowLabel: window.label,
                modelLabel: "Claude",
                unit: .percent,
                used: Int(window.usedPercent.rounded()),
                limit: 100,
                resetsAt: window.resetsAt,
                lastUpdatedAt: rateLimitSnapshot.observedAt,
                confidence: .observed,
                statusOverride: isStale ? .stale : nil,
                note: sourceNote
            )
        }
    }

    if let estimatedLimit = claudeUsageBlockEstimate(
        usageBlocksSummary: usageBlocksSummary,
        loggedIn: loggedIn,
        accountID: accountID,
        accountName: accountName,
        observedAt: observedAt
    ) {
        return [estimatedLimit]
    }

    var noteParts = ["allowance: not exposed by Claude Code"]
    if let statsSummary {
        noteParts.append("sessions: \(statsSummary.totalSessions.map(String.init) ?? "unknown")")
        noteParts.append("messages: \(statsSummary.totalMessages.map(String.init) ?? "unknown")")
    } else {
        noteParts.append("stats cache: absent")
    }

    return [UsageLimit(
        provider: .anthropic,
        accountID: accountID,
        accountName: accountName,
        label: "Claude status",
        modelLabel: "Claude Code",
        unit: .unknown,
        used: nil,
        limit: nil,
        resetsAt: nil,
        lastUpdatedAt: statsSummary?.lastComputedDate ?? observedAt,
        confidence: .observed,
        statusOverride: loggedIn ? .unknown : .unknown,
        note: noteParts.joined(separator: "; ")
    )]
}

private func claudeUsageBlockEstimate(
    usageBlocksSummary: ClaudeUsageBlocksSummary?,
    loggedIn: Bool,
    accountID: String,
    accountName: String,
    observedAt: Date
) -> UsageLimit? {
    guard
        loggedIn,
        let activeBlock = usageBlocksSummary?.activeBlock,
        activeBlock.isActive,
        let totalTokens = activeBlock.totalTokens,
        totalTokens > 0
    else { return nil }

    let estimatedLimit = usageBlocksSummary?.completedBlockTokenLimitEstimate
        ?? activeBlock.projectedTotalTokens
    let used: Int?
    let limit: Int?
    if let estimatedLimit, estimatedLimit > 0 {
        used = min(totalTokens, estimatedLimit)
        limit = estimatedLimit
    } else {
        used = nil
        limit = nil
    }

    let resetsAt = activeBlock.remainingMinutes.map {
        observedAt.addingTimeInterval(TimeInterval($0 * 60))
    } ?? activeBlock.endTime
    let modelMode = activeBlock.modelCount > 1 ? "mixed models" : "single model"

    return UsageLimit(
        provider: .anthropic,
        accountID: accountID,
        accountName: accountName,
        label: "Claude 5-hour estimate",
        windowLabel: "5-hour estimated",
        modelLabel: "Claude",
        unit: .tokens,
        used: used,
        limit: limit,
        resetsAt: resetsAt,
        lastUpdatedAt: observedAt,
        confidence: .estimated,
        statusOverride: limit == nil ? .unknown : nil,
        note: "source: ccusage local block estimate from Every Code/Claude sessions; \(modelMode); official subscription percentage unavailable in claude -p"
    )
}

private struct ClaudeStatuslineRateLimitPayload: Decodable {
    let observedAt: Int
    let rateLimits: ClaudeStatuslineRateLimits

    enum CodingKeys: String, CodingKey {
        case observedAt = "observed_at"
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeStatuslineRateLimits: Decodable {
    let fiveHour: ClaudeStatuslineRateLimitWindow?
    let sevenDay: ClaudeStatuslineRateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }

    func snapshot(observedAt: Date) -> ClaudeSubscriptionRateLimitSnapshot? {
        var windows: [ClaudeSubscriptionRateLimitWindow] = []
        if let fiveHour {
            windows.append(fiveHour.window(label: "5-hour"))
        }
        if let sevenDay {
            windows.append(sevenDay.window(label: "Weekly"))
        }
        guard !windows.isEmpty else { return nil }
        return ClaudeSubscriptionRateLimitSnapshot(observedAt: observedAt, windows: windows)
    }
}

private struct ClaudeStatuslineRateLimitWindow: Decodable {
    let usedPercentage: Double
    let resetsAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercentage = "used_percentage"
        case resetsAt = "resets_at"
    }

    func window(label: String) -> ClaudeSubscriptionRateLimitWindow {
        ClaudeSubscriptionRateLimitWindow(
            label: label,
            usedPercent: usedPercentage,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

private struct ClaudeStatsCachePayload: Decodable {
    let version: Int?
    let lastComputedDate: Date?
    let dailyActivity: ClaudeCountedCollection?
    let modelUsage: [String: ClaudeDiscardedValue]?
    let totalSessions: Int?
    let totalMessages: Int?
    let firstSessionDate: Date?
    let rateLimits: ClaudeStatuslineRateLimits?

    enum CodingKeys: String, CodingKey {
        case version
        case lastComputedDate
        case dailyActivity
        case modelUsage
        case totalSessions
        case totalMessages
        case firstSessionDate
        case rateLimits = "rate_limits"
    }
}

private struct ClaudeUsageBlocksPayload: Decodable {
    let blocks: [ClaudeUsageBlockPayload]
}

private struct ClaudeUsageBlockPayload: Decodable {
    let isActive: Bool
    let totalTokens: Int?
    let endTime: Date?
    let projection: ClaudeUsageBlockProjection?
    let models: [String]?

    var usageBlock: ClaudeUsageBlock {
        ClaudeUsageBlock(
            isActive: isActive,
            totalTokens: totalTokens,
            endTime: endTime,
            projectedTotalTokens: projection?.totalTokens,
            remainingMinutes: projection?.remainingMinutes,
            modelCount: models?.filter { $0 != "<synthetic>" }.count ?? 0
        )
    }
}

private struct ClaudeUsageBlockProjection: Decodable {
    let totalTokens: Int?
    let remainingMinutes: Int?
}

private enum ClaudeCountedCollection: Decodable {
    case dictionary([String: ClaudeDiscardedValue])
    case array([ClaudeDiscardedValue])

    var count: Int {
        switch self {
        case let .dictionary(values):
            values.count
        case let .array(values):
            values.count
        }
    }

    init(from decoder: Decoder) throws {
        if let dictionary = try? [String: ClaudeDiscardedValue](from: decoder) {
            self = .dictionary(dictionary)
            return
        }
        self = .array(try [ClaudeDiscardedValue](from: decoder))
    }
}

private struct ClaudeDiscardedValue: Decodable {}

extension JSONDecoder {
    static var contextPanelFlexibleDates: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            if let date = ContextPanelDateFormatting.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO 8601 date string"
            )
        }
        return decoder
    }
}
