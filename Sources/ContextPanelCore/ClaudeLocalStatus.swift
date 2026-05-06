import Foundation

public struct ClaudeAuthStatus: Codable, Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String
    public let apiProvider: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String, apiProvider: String?, subscriptionType: String?) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.subscriptionType = subscriptionType
    }

    public var subscriptionDisplayName: String {
        guard let subscriptionType, !subscriptionType.isEmpty else { return "Claude" }
        return "Claude \(subscriptionType.capitalized)"
    }
}

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

public enum ClaudeAuthStatusParser {
    public static func status(from data: Data) throws -> ClaudeAuthStatus {
        let payload = try JSONDecoder().decode(ClaudeAuthStatusPayload.self, from: data)
        return ClaudeAuthStatus(
            loggedIn: payload.loggedIn,
            authMethod: payload.authMethod,
            apiProvider: payload.apiProvider,
            subscriptionType: payload.subscriptionType
        )
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
    public let claudeBinary: String
    public let statsPath: String
    public let rateLimitSnapshotPath: String

    public init(
        accountName: String = "Claude",
        claudeBinary: String = "claude",
        statsPath: String? = nil,
        rateLimitSnapshotPath: String? = nil
    ) {
        self.accountName = accountName
        self.claudeBinary = claudeBinary
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.statsPath = statsPath ?? "\(home)/.claude/stats-cache.json"
        self.rateLimitSnapshotPath = rateLimitSnapshotPath
            ?? "\(home)/Library/Application Support/Context Panel/ClaudeRateLimits/statusline-cache.json"
    }
}

public struct ClaudeLocalStatusConnector: ProviderConnector {
    public let provider: Provider = .anthropic

    private let accounts: [ClaudeAccountConfiguration]
    private let processClient: any ConnectorProcessClient
    private let fileLoader: @Sendable (String) throws -> Data
    private let fileExists: @Sendable (String) -> Bool

    public init(
        accounts: [ClaudeAccountConfiguration],
        processClient: any ConnectorProcessClient = DefaultConnectorProcessClient(),
        fileLoader: @escaping @Sendable (String) throws -> Data = { path in
            try Data(contentsOf: URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        },
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: NSString(string: path).expandingTildeInPath)
        }
    ) {
        self.accounts = accounts
        self.processClient = processClient
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
            let authStatus = try loadAuthStatus(claudeBinary: account.claudeBinary)
            let statsSummary = try loadStatsSummary(path: account.statsPath)
            let rateLimitSnapshot = try loadRateLimitSnapshot(path: account.rateLimitSnapshotPath)
                ?? statsSummary?.rateLimitSnapshot
            let limits = claudeLocalStatusLimits(
                authStatus: authStatus,
                statsSummary: statsSummary,
                rateLimitSnapshot: rateLimitSnapshot,
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
                status: authStatus.loggedIn ? .unknown : .failure,
                errorMessage: authStatus.loggedIn ? nil : "Claude CLI is not logged in"
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

    private func loadAuthStatus(claudeBinary: String) throws -> ClaudeAuthStatus {
        let result = try processClient.run(executable: claudeBinary, arguments: ["auth", "status", "--json"])
        guard result.exitCode == 0 else {
            throw ConnectorError.processFailure(operation: "claude auth status", exitCode: result.exitCode)
        }
        return try ClaudeAuthStatusParser.status(from: result.stdout)
    }

    private func loadStatsSummary(path: String) throws -> ClaudeStatsCacheSummary? {
        guard fileExists(path) else { return nil }
        return try ClaudeStatsCacheParser.summary(from: try fileLoader(path))
    }

    private func loadRateLimitSnapshot(path: String) throws -> ClaudeSubscriptionRateLimitSnapshot? {
        guard fileExists(path) else { return nil }
        return try ClaudeSubscriptionRateLimitCacheParser.snapshot(from: try fileLoader(path))
    }
}

public func claudeLocalStatusLimits(
    authStatus: ClaudeAuthStatus,
    statsSummary: ClaudeStatsCacheSummary?,
    rateLimitSnapshot: ClaudeSubscriptionRateLimitSnapshot? = nil,
    accountID: String,
    accountName: String,
    observedAt: Date
) -> [UsageLimit] {
    if authStatus.loggedIn, let rateLimitSnapshot, !rateLimitSnapshot.windows.isEmpty {
        return rateLimitSnapshot.windows.map { window in
            UsageLimit(
                provider: .anthropic,
                accountID: accountID,
                accountName: accountName,
                label: "Claude \(window.label)",
                windowLabel: window.label,
                modelLabel: authStatus.subscriptionDisplayName,
                unit: .percent,
                used: Int(window.usedPercent.rounded()),
                limit: 100,
                resetsAt: window.resetsAt,
                lastUpdatedAt: rateLimitSnapshot.observedAt,
                confidence: .observed,
                note: "source: Claude Code statusline; subscription: \(authStatus.subscriptionType ?? "unknown")"
            )
        }
    }

    var noteParts = [
        "auth: \(authStatus.authMethod)",
        "provider: \(authStatus.apiProvider ?? "unknown")",
        "subscription: \(authStatus.subscriptionType ?? "unknown")",
        "allowance: not exposed by Claude Code",
    ]
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
        label: "\(authStatus.subscriptionDisplayName) status",
        modelLabel: "Claude Code",
        unit: .unknown,
        used: nil,
        limit: nil,
        resetsAt: nil,
        lastUpdatedAt: statsSummary?.lastComputedDate ?? observedAt,
        confidence: .observed,
        statusOverride: authStatus.loggedIn ? .unknown : .failure,
        note: noteParts.joined(separator: "; ")
    )]
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

private struct ClaudeAuthStatusPayload: Decodable {
    let loggedIn: Bool
    let authMethod: String
    let apiProvider: String?
    let subscriptionType: String?
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
