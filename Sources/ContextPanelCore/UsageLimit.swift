import Foundation

public enum Provider: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case openAI = "openai"
    case anthropic
    case google

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .anthropic:
            "Anthropic"
        case .google:
            "Google"
        }
    }

    public var shortName: String {
        switch self {
        case .openAI:
            "OAI"
        case .anthropic:
            "ANT"
        case .google:
            "GOO"
        }
    }
}

public enum UsageStatus: String, Codable, Equatable, Sendable {
    case healthy
    case close
    case limited
    case stale
    case unknown
    case failure
    case loading
}

public enum UsageConfidence: String, Codable, Equatable, Sendable {
    case official
    case observed
    case manual
    case estimated
    case unknown
}

public enum UsageUnit: String, Codable, Equatable, Sendable {
    case percent
    case tokens
    case requests
    case credits
    case units
    case unknown
}

public struct ProviderAccount: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let name: String
    public let isEnabled: Bool

    public init(id: String, provider: Provider, name: String, isEnabled: Bool = true) {
        self.id = id
        self.provider = provider
        self.name = name
        self.isEnabled = isEnabled
    }
}

public struct UsageLimit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
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
    public let statusOverride: UsageStatus?
    public let note: String?

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case accountID
        case configuredAccountID
        case accountName
        case label
        case windowLabel
        case modelLabel
        case unit
        case used
        case limit
        case resetsAt
        case lastUpdatedAt
        case confidence
        case statusOverride
        case note
    }

    public init(
        id: String? = nil,
        provider: Provider,
        accountID: String,
        configuredAccountID: String? = nil,
        accountName: String,
        label: String,
        windowLabel: String? = nil,
        modelLabel: String? = nil,
        unit: UsageUnit = .units,
        used: Int?,
        limit: Int?,
        resetsAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        confidence: UsageConfidence = .official,
        statusOverride: UsageStatus? = nil,
        note: String? = nil
    ) {
        if let used {
            precondition(used >= 0, "used must not be negative")
        }
        if let limit {
            precondition(limit > 0, "limit must be positive")
        }

        self.id = id ?? "\(provider.rawValue):\(accountID):\(label)"
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.accountName = accountName
        self.label = label
        self.windowLabel = windowLabel
        self.modelLabel = modelLabel
        self.unit = unit
        self.used = used
        self.limit = limit
        self.resetsAt = resetsAt
        self.lastUpdatedAt = lastUpdatedAt
        self.confidence = confidence
        self.statusOverride = statusOverride
        self.note = note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        accountID = try container.decode(String.self, forKey: .accountID)
        configuredAccountID = try container.decodeIfPresent(String.self, forKey: .configuredAccountID)
        accountName = try container.decode(String.self, forKey: .accountName)
        label = try container.decode(String.self, forKey: .label)
        windowLabel = try container.decodeIfPresent(String.self, forKey: .windowLabel)
        modelLabel = try container.decodeIfPresent(String.self, forKey: .modelLabel)
        unit = try container.decode(UsageUnit.self, forKey: .unit)
        used = try container.decodeIfPresent(Int.self, forKey: .used)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        confidence = try container.decode(UsageConfidence.self, forKey: .confidence)
        statusOverride = try container.decodeIfPresent(UsageStatus.self, forKey: .statusOverride)
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public init(provider: Provider, label: String, used: Int, limit: Int, resetsAt: Date? = nil) {
        self.init(
            provider: provider,
            accountID: "default",
            accountName: provider.displayName,
            label: label,
            unit: .units,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            confidence: .official
        )
    }

    public var remaining: Int? {
        guard let used, let limit else { return nil }
        return max(limit - used, 0)
    }

    public var configuredOrResolvedAccountID: String {
        configuredAccountID ?? accountID
    }

    public var usageRatio: Double? {
        guard let used, let limit else { return nil }
        return min(Double(used) / Double(limit), 1)
    }

    public var displayLabel: String {
        windowLabel ?? label
    }

    public var contextLabel: String {
        [modelLabel, accountName]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    public var status: UsageStatus {
        if let statusOverride {
            return statusOverride
        }
        guard let ratio = usageRatio else {
            return .unknown
        }
        if ratio >= 1 {
            return .limited
        }
        if ratio >= 0.8 {
            return .close
        }
        return .healthy
    }
}

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let limits: [UsageLimit]

    public init(generatedAt: Date, limits: [UsageLimit]) {
        self.generatedAt = generatedAt
        self.limits = limits
    }

    public var mostConstrainedLimits: [UsageLimit] {
        limits.sorted { lhs, rhs in
            let lhsScore = lhs.constraintScore
            let rhsScore = rhs.constraintScore
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return (lhs.usageRatio ?? -1) > (rhs.usageRatio ?? -1)
        }
    }

    public var aggregateCapacityRatio: Double {
        let ratios = limits.compactMap(\.usageRatio)
        guard !ratios.isEmpty else { return 0 }
        return max(1 - (ratios.max() ?? 0), 0)
    }

    public var aggregateStatus: UsageStatus {
        mostConstrainedLimits.first?.status ?? .unknown
    }
}

extension UsageStatus {
    fileprivate var sortRank: Double {
        switch self {
        case .limited:
            2
        case .failure:
            1.3
        case .close:
            1
        case .stale:
            0.4
        case .unknown:
            0.3
        case .loading:
            0.2
        case .healthy:
            0
        }
    }
}

extension UsageLimit {
    fileprivate var constraintScore: Double {
        status.sortRank + (usageRatio ?? 0)
    }
}
