import Foundation

public struct GeminiQuotaBucket: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let modelID: String
    public let remainingFraction: Double?
    public let remainingAmount: Int?
    public let resetsAt: Date?

    public init(modelID: String, remainingFraction: Double?, remainingAmount: Int?, resetsAt: Date?) {
        self.id = modelID
        self.modelID = modelID
        self.remainingFraction = remainingFraction.map { max(0, min($0, 1)) }
        self.remainingAmount = remainingAmount
        self.resetsAt = resetsAt
    }

    public var usedPercent: Double? {
        remainingFraction.map { max(0, min((1 - $0) * 100, 100)) }
    }

    public func usageLimit(accountID: String, accountName: String, observedAt: Date) -> UsageLimit {
        UsageLimit(
            provider: .google,
            accountID: accountID,
            accountName: accountName,
            label: modelID,
            unit: .percent,
            used: usedPercent.map { Int($0.rounded()) },
            limit: usedPercent == nil ? nil : 100,
            resetsAt: resetsAt,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            note: remainingAmount.map { "remaining amount: \($0)" }
        )
    }
}

public enum GeminiQuotaPayloadParser {
    public static func buckets(from data: Data) throws -> [GeminiQuotaBucket] {
        let payload = try JSONDecoder.contextPanelISO8601.decode(GeminiQuotaPayload.self, from: data)
        return payload.buckets.map(\.normalizedBucket)
    }
}

private struct GeminiQuotaPayload: Decodable {
    let buckets: [GeminiQuotaBucketPayload]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        buckets = try container.decodeIfPresent([GeminiQuotaBucketPayload].self, forKey: .buckets) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case buckets
    }
}

private struct GeminiQuotaBucketPayload: Decodable {
    let modelID: String
    let remainingFraction: Double?
    let remainingAmount: Int?
    let resetTime: Date?

    enum CodingKeys: String, CodingKey {
        case modelID = "modelId"
        case remainingFraction
        case remainingAmount
        case resetTime
    }

    var normalizedBucket: GeminiQuotaBucket {
        GeminiQuotaBucket(
            modelID: modelID,
            remainingFraction: remainingFraction,
            remainingAmount: remainingAmount,
            resetsAt: resetTime
        )
    }
}

extension JSONDecoder {
    static var contextPanelISO8601: JSONDecoder {
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

public enum ContextPanelDateFormatting {
    public static func string(from date: Date) -> String {
        internetDateFormatter().string(from: date)
    }

    public static func date(from value: String) -> Date? {
        internetDateFormatterWithFractionalSeconds().date(from: value)
            ?? internetDateFormatter().date(from: value)
            ?? dateOnlyFormatter().date(from: value)
    }

    private static func internetDateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func internetDateFormatterWithFractionalSeconds() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func dateOnlyFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }
}
