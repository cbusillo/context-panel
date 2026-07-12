import ContextPanelCore
import Foundation

public enum TVPreferenceKeys {
    public static let presentationMode = "tv-presentation-mode"
    public static let providerBadgesEnabled = "tv-provider-badges-enabled"
    public static let cloudKitSubscriptionVersion = "tv-cloudkit-subscription-version"
    public static let cloudKitSubscriptionError = "tv-cloudkit-subscription-error"
}

public enum TVProviderAlertLevel: Int, Codable, Comparable, Equatable, Sendable {
    case none
    case limited
    case failure

    public static func < (lhs: TVProviderAlertLevel, rhs: TVProviderAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct TVProviderAlertRecord: Codable, Equatable, Sendable {
    public let provider: Provider
    public let level: TVProviderAlertLevel

    public init(provider: Provider, level: TVProviderAlertLevel) {
        self.provider = provider
        self.level = level
    }
}

public struct TVProviderAlertState: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let records: [TVProviderAlertRecord]

    public init(records: [TVProviderAlertRecord] = []) {
        schemaVersion = Self.schemaVersion
        self.records = records
            .filter { $0.level != .none }
            .reduce(into: [Provider: TVProviderAlertRecord]()) { result, record in
                result[record.provider] = record
            }
            .values
            .sorted { $0.provider.rawValue < $1.provider.rawValue }
    }

    public static var empty: TVProviderAlertState { TVProviderAlertState() }

    public func level(for provider: Provider) -> TVProviderAlertLevel {
        records.first { $0.provider == provider }?.level ?? .none
    }
}

public struct TVProviderAlertEvent: Equatable, Sendable {
    public let provider: Provider
    public let level: TVProviderAlertLevel
    public let observedAt: Date

    public init(provider: Provider, level: TVProviderAlertLevel, observedAt: Date) {
        self.provider = provider
        self.level = level
        self.observedAt = observedAt
    }
}

public struct TVProviderAlertEvaluation: Equatable, Sendable {
    public let events: [TVProviderAlertEvent]
    public let state: TVProviderAlertState
    public let attentionProviders: [Provider]

    public var badgeCount: Int { attentionProviders.count }

    public init(
        events: [TVProviderAlertEvent],
        state: TVProviderAlertState,
        attentionProviders: [Provider]
    ) {
        self.events = events
        self.state = state
        self.attentionProviders = attentionProviders
    }
}

public enum TVProviderAlertEvaluator {
    public static func evaluate(
        snapshot: WidgetSnapshot,
        previousState: TVProviderAlertState,
        now: Date = Date()
    ) -> TVProviderAlertEvaluation {
        let levels = currentLevels(snapshot: snapshot, now: now)
        let records = Provider.allCases.compactMap { provider -> TVProviderAlertRecord? in
            let level = levels[provider] ?? .none
            guard level != .none else { return nil }
            return TVProviderAlertRecord(provider: provider, level: level)
        }
        let state = TVProviderAlertState(records: records)
        let attentionProviders = Provider.allCases.filter { state.level(for: $0) != .none }
        let events = attentionProviders.compactMap { provider -> TVProviderAlertEvent? in
            let level = state.level(for: provider)
            guard level > previousState.level(for: provider) else { return nil }
            return TVProviderAlertEvent(provider: provider, level: level, observedAt: now)
        }
        return TVProviderAlertEvaluation(
            events: events,
            state: state,
            attentionProviders: attentionProviders
        )
    }

    private static func currentLevels(
        snapshot: WidgetSnapshot,
        now: Date
    ) -> [Provider: TVProviderAlertLevel] {
        guard snapshot.state != .setupNeeded,
              !TVSnapshotFreshnessPolicy.isStale(
                  state: snapshot.state,
                  generatedAt: snapshot.generatedAt,
                  at: now
              )
        else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            let statuses = snapshot.limits
                .filter { $0.provider == provider }
                .map(\.status)
                + snapshot.reports
                .filter { $0.provider == provider }
                .map(\.status)
            let level = statuses.map(alertLevel).max() ?? .none
            return (provider, level)
        })
    }

    private static func alertLevel(status: UsageStatus) -> TVProviderAlertLevel {
        switch status {
        case .failure:
            .failure
        case .limited:
            .limited
        case .healthy, .close, .stale, .unknown, .loading:
            .none
        }
    }
}

public struct TVProviderAlertStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func load() -> TVProviderAlertState {
        guard let data = try? Data(contentsOf: stateURL) else { return .empty }
        guard let state = try? JSONDecoder().decode(TVProviderAlertState.self, from: data) else {
            return .empty
        }
        guard state.schemaVersion == TVProviderAlertState.schemaVersion else { return .empty }
        return state
    }

    public func save(_ state: TVProviderAlertState) throws {
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
    }
}
