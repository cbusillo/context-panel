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
}

public struct ClaudeStatsCacheSummary: Codable, Equatable, Sendable {
    public let version: Int?
    public let lastComputedDate: Date?
    public let totalSessions: Int?
    public let totalMessages: Int?
    public let firstSessionDate: Date?
    public let modelUsageCount: Int
    public let dailyActivityCount: Int

    public init(
        version: Int?,
        lastComputedDate: Date?,
        totalSessions: Int?,
        totalMessages: Int?,
        firstSessionDate: Date?,
        modelUsageCount: Int,
        dailyActivityCount: Int
    ) {
        self.version = version
        self.lastComputedDate = lastComputedDate
        self.totalSessions = totalSessions
        self.totalMessages = totalMessages
        self.firstSessionDate = firstSessionDate
        self.modelUsageCount = modelUsageCount
        self.dailyActivityCount = dailyActivityCount
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
            dailyActivityCount: payload.dailyActivity?.count ?? 0
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
