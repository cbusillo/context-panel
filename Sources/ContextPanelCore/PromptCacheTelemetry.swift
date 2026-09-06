import Foundation

public struct PromptCacheTokenSet: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let cachedInputTokens: Int?

    public init(inputTokens: Int, cachedInputTokens: Int?) {
        self.inputTokens = max(inputTokens, 0)
        self.cachedInputTokens = cachedInputTokens.map { max($0, 0) }
    }

    public var uncachedInputTokens: Int? {
        cachedInputTokens.map { max(inputTokens - $0, 0) }
    }

    public var hitRate: Double? {
        guard inputTokens > 0, let cachedInputTokens else { return nil }
        return min(max(Double(cachedInputTokens) / Double(inputTokens), 0), 1)
    }
}

public enum PromptCacheMeasurement: String, Codable, Equatable, Sendable {
    case increment
}

public struct PromptCacheObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let provider: Provider
    public let accountID: String
    public let accountName: String
    public let observedAt: Date
    public let windowLabel: String
    public let tokens: PromptCacheTokenSet
    public let measurement: PromptCacheMeasurement?

    public init(
        id: String? = nil,
        provider: Provider,
        accountID: String,
        accountName: String,
        observedAt: Date,
        windowLabel: String,
        tokens: PromptCacheTokenSet,
        measurement: PromptCacheMeasurement? = nil
    ) {
        self.id = id ?? "\(provider.rawValue):\(accountID):\(windowLabel):\(observedAt.timeIntervalSince1970)"
        self.provider = provider
        self.accountID = accountID
        self.accountName = accountName
        self.observedAt = observedAt
        self.windowLabel = windowLabel
        self.tokens = tokens
        self.measurement = measurement
    }

    public var hitRate: Double? { tokens.hitRate }
}

public enum PromptCacheRateComparison: Equatable, Sendable {
    case above(points: Int)
    case below(points: Int)
    case matching
    case unavailable
}

public struct PromptCacheSummary: Equatable, Sendable {
    public static let defaultMaximumAge: TimeInterval = 6 * 60 * 60

    public let observations: [PromptCacheObservation]

    public init(observations: [PromptCacheObservation], now: Date? = nil, maximumAge: TimeInterval = defaultMaximumAge) {
        let recentObservations = now.map {
            PromptCacheTelemetryReader.filteredRecentObservations(observations, now: $0, maximumAge: maximumAge)
        } ?? observations
        self.observations = recentObservations.sorted { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
            if lhs.windowLabel != rhs.windowLabel { return lhs.windowLabel < rhs.windowLabel }
            if lhs.provider != rhs.provider { return lhs.provider.rawValue < rhs.provider.rawValue }
            if lhs.accountID != rhs.accountID { return lhs.accountID < rhs.accountID }
            return lhs.id < rhs.id
        }
    }

    public var isAvailable: Bool {
        !availableObservations.isEmpty
    }

    public var latest: PromptCacheObservation? {
        availableObservations.first
    }

    public var tokenWeightedHitRate: Double? {
        let totals = availableObservations.reduce((input: 0, cached: 0)) { partial, observation in
            (partial.input + observation.tokens.inputTokens, partial.cached + (observation.tokens.cachedInputTokens ?? 0))
        }
        guard totals.input > 0 else { return nil }
        return min(max(Double(totals.cached) / Double(totals.input), 0), 1)
    }

    public var latestHitRate: Double? {
        guard latest?.measurement == .increment else { return latest?.hitRate }
        let totals = latestIncrementBucket.reduce((input: 0, cached: 0)) { partial, observation in
            (partial.input + observation.tokens.inputTokens, partial.cached + (observation.tokens.cachedInputTokens ?? 0))
        }
        guard totals.input > 0 else { return nil }
        return min(max(Double(totals.cached) / Double(totals.input), 0), 1)
    }

    public var latestDeltaFromWeightedAverage: Double? {
        // Sparse increments are neutral in both color and comparison language.
        if latest?.measurement == .increment, latestIncrementBucket.count < 3 { return nil }
        guard let latestHitRate, let tokenWeightedHitRate else { return nil }
        return latestHitRate - tokenWeightedHitRate
    }

    public var latestRateComparison: PromptCacheRateComparison {
        guard let delta = latestDeltaFromWeightedAverage else { return .unavailable }
        let points = Int((abs(delta) * 100).rounded())
        guard points > 0 else { return .matching }
        return delta > 0 ? .above(points: points) : .below(points: points)
    }

    public var comparisonStatus: UsageStatus {
        if latest?.measurement == .increment, latestIncrementBucket.count < 3 { return .unknown }
        guard !hasPossibleCacheBreak else { return .limited }
        guard let latestHitRate else { return .unknown }
        guard let delta = latestDeltaFromWeightedAverage else {
            if latestHitRate >= 0.8 { return .healthy }
            if latestHitRate >= 0.5 { return .close }
            return .limited
        }
        if delta <= -0.25 || latestHitRate <= 0.35 { return .limited }
        if delta <= -0.10 || latestHitRate <= 0.65 { return .close }
        return .healthy
    }

    public var totalInputTokens: Int {
        availableObservations.reduce(0) { $0 + $1.tokens.inputTokens }
    }

    public var totalCachedInputTokens: Int {
        availableObservations.reduce(0) { $0 + ($1.tokens.cachedInputTokens ?? 0) }
    }

    public var totalUncachedInputTokens: Int? {
        guard isAvailable else { return nil }
        return max(totalInputTokens - totalCachedInputTokens, 0)
    }

    public var hasPossibleCacheBreak: Bool {
        // Per-turn startup misses are expected. Incremental sources need a
        // validated sustained-change heuristic before diagnosing cache breaks.
        guard observations.count >= 2, let latest, latest.measurement != .increment,
              let latestHitRate = latest.hitRate else { return false }
        let previous = observations
            .filter {
                $0.id != latest.id && $0.hitRate != nil && $0.accountID == latest.accountID
                    && $0.provider == latest.provider && $0.windowLabel == latest.windowLabel
                    && $0.measurement == latest.measurement
            }
            .prefix(6)
        guard !previous.isEmpty else { return false }
        let previousSummary = PromptCacheSummary(observations: Array(previous))
        guard let previousRate = previousSummary.tokenWeightedHitRate else { return false }
        return previousRate >= 0.8 && latestHitRate <= 0.2 && latest.tokens.inputTokens >= 1_000
    }

    private var availableObservations: [PromptCacheObservation] {
        observations.filter { $0.tokens.inputTokens > 0 && $0.tokens.cachedInputTokens != nil }
    }

    private var latestIncrementBucket: [PromptCacheObservation] {
        guard let latest, latest.measurement == .increment else { return [] }
        let start = latest.observedAt.addingTimeInterval(-15 * 60)
        return availableObservations.filter {
            $0.measurement == .increment && $0.provider == latest.provider
                && $0.accountID == latest.accountID && $0.windowLabel == latest.windowLabel
                && $0.observedAt >= start && $0.observedAt <= latest.observedAt
        }
    }
}

public enum PromptCacheTelemetryReader {
    public static func mirroredObservations(
        rootDirectory: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        now: Date = Date(),
        maximumAge: TimeInterval = PromptCacheSummary.defaultMaximumAge,
        fileManager: FileManager = .default
    ) -> [PromptCacheObservation] {
        everyCodeUsageObservations(rootDirectory: rootDirectory, now: now, maximumAge: maximumAge, fileManager: fileManager)
    }

    // Legacy payload formats remain readable in app-owned telemetry mirrors.
    // This explicit-root reader never discovers or polls retired client homes.
    public static func everyCodeUsageObservations(
        rootDirectory: URL,
        now: Date = Date(),
        maximumAge: TimeInterval = PromptCacheSummary.defaultMaximumAge,
        fileManager: FileManager = .default
    ) -> [PromptCacheObservation] {
        let urls = jsonFileURLs(rootDirectory: rootDirectory, fileManager: fileManager)

        return deduplicated(urls
            .flatMap { url -> [PromptCacheObservation] in
                guard let data = try? Data(contentsOf: url) else { return [] }
                if let mirror = try? JSONDecoder().decode(CodexTelemetryMirror.self, from: data) {
                    return filteredRecentObservations(mirror.observations, now: now, maximumAge: maximumAge)
                }
                return observation(from: data, at: url, now: now, maximumAge: maximumAge).map { [$0] } ?? []
            }
        )
            .sorted { $0.observedAt > $1.observedAt }
    }

    public static func filteredRecentObservations(
        _ observations: [PromptCacheObservation],
        now: Date,
        maximumAge: TimeInterval = PromptCacheSummary.defaultMaximumAge
    ) -> [PromptCacheObservation] {
        observations.filter { observation in
            observation.observedAt <= now && now.timeIntervalSince(observation.observedAt) <= maximumAge
        }
    }

    private static func deduplicated(_ observations: [PromptCacheObservation]) -> [PromptCacheObservation] {
        var seen = Set<String>()
        return observations.sorted { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt > rhs.observedAt }
            // Copied session events share an ID across clients. Choose the same
            // unattributed source label regardless of mirror enumeration order.
            return lhs.accountID < rhs.accountID
        }.filter { observation in
            seen.insert(observation.id).inserted
        }
    }

    private static func jsonFileURLs(rootDirectory: URL, fileManager: FileManager) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "json" else { return nil }
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { return nil }
            return url
        }
    }

    private static func observation(from data: Data, at url: URL, now: Date, maximumAge: TimeInterval) -> PromptCacheObservation? {
        guard
            let payload = try? JSONDecoder().decode(EveryCodeUsagePayload.self, from: data),
            let observedAt = payload.lastUpdatedDate,
            now.timeIntervalSince(observedAt) <= maximumAge,
            let tokens = payload.tokensLastHour ?? payload.hourlyEntries.last?.tokens ?? payload.totals,
            tokens.normalized.inputTokens > 0
        else { return nil }

        let sourceID = Self.sourceID(for: url, payload: payload)
        let plan = payload.plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountName = ["Every Code", plan]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")

        return PromptCacheObservation(
            id: "\(Provider.openAI.rawValue):\(sourceID):\(payload.tokensLastHour == nil ? "Latest" : "Last hour"):\(observedAt.timeIntervalSince1970)",
            provider: .openAI,
            accountID: sourceID,
            accountName: accountName.isEmpty ? "Every Code" : accountName,
            observedAt: observedAt,
            windowLabel: payload.tokensLastHour == nil ? "Latest" : "Last hour",
            tokens: tokens.normalized
        )
    }

    private static func sourceID(for url: URL, payload: EveryCodeUsagePayload) -> String {
        if let sourceID = payload.contextPanelSourceID, !sourceID.isEmpty {
            return sourceID
        }
        if let sourceID = mirroredSourceID(for: url) {
            return sourceID
        }
        return ConnectorRedactor.localAccountID(
            provider: .openAI,
            path: ContextPanelLocations.normalizedPath(url.path)
        )
    }

    private static func mirroredSourceID(for url: URL) -> String? {
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard parent.hasPrefix("openai-") else { return nil }
        return parent
    }
}

private struct EveryCodeUsagePayload: Decodable {
    let lastUpdated: String?
    let plan: String?
    let totals: EveryCodeTokenPayload?
    let tokensLastHour: EveryCodeTokenPayload?
    let hourlyEntries: [EveryCodeHourlyEntry]
    let contextPanelSourceID: String?

    enum CodingKeys: String, CodingKey {
        case lastUpdated = "last_updated"
        case plan
        case totals
        case tokensLastHour = "tokens_last_hour"
        case hourlyEntries = "hourly_entries"
        case contextPanelSourceID = "_context_panel_source_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastUpdated = try container.decodeIfPresent(String.self, forKey: .lastUpdated)
        plan = try container.decodeIfPresent(String.self, forKey: .plan)
        totals = try container.decodeIfPresent(EveryCodeTokenPayload.self, forKey: .totals)
        tokensLastHour = try container.decodeIfPresent(EveryCodeTokenPayload.self, forKey: .tokensLastHour)
        hourlyEntries = try container.decodeIfPresent([EveryCodeHourlyEntry].self, forKey: .hourlyEntries) ?? []
        contextPanelSourceID = try container.decodeIfPresent(String.self, forKey: .contextPanelSourceID)
    }

    var lastUpdatedDate: Date? {
        guard let lastUpdated else { return nil }
        return ContextPanelDateFormatting.date(from: lastUpdated)
    }
}

private struct EveryCodeHourlyEntry: Decodable {
    let tokens: EveryCodeTokenPayload?
}

private struct EveryCodeTokenPayload: Decodable {
    let inputTokens: Int?
    let cachedInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case cachedInputTokens = "cached_input_tokens"
    }

    var normalized: PromptCacheTokenSet {
        PromptCacheTokenSet(inputTokens: inputTokens ?? 0, cachedInputTokens: cachedInputTokens)
    }
}
