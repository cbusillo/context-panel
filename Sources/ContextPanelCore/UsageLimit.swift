import Foundation

public enum Provider: String, CaseIterable, Codable, Equatable, Sendable {
    case openAI = "openai"
    case anthropic
    case google
}

public struct UsageLimit: Codable, Equatable, Sendable {
    public let provider: Provider
    public let label: String
    public let used: Int
    public let limit: Int
    public let resetsAt: Date?

    public init(provider: Provider, label: String, used: Int, limit: Int, resetsAt: Date? = nil) {
        precondition(used >= 0, "used must not be negative")
        precondition(limit > 0, "limit must be positive")

        self.provider = provider
        self.label = label
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
    }

    public var remaining: Int {
        max(limit - used, 0)
    }

    public var usageRatio: Double {
        min(Double(used) / Double(limit), 1)
    }
}
