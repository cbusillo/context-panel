import Foundation

public struct WidgetMainLimitPreference: Codable, Equatable, Identifiable, Sendable {
    public var provider: Provider
    public var window: MainLimitWindow
    public var isVisible: Bool
    public var sortOrder: Int

    public var id: String {
        Self.id(provider: provider, window: window)
    }

    public var displayName: String {
        "\(provider.displayName) \(window.displayName)"
    }

    public init(provider: Provider, window: MainLimitWindow, isVisible: Bool, sortOrder: Int) {
        self.provider = provider
        self.window = window
        self.isVisible = isVisible
        self.sortOrder = sortOrder
    }

    public static func id(provider: Provider, window: MainLimitWindow) -> String {
        "\(provider.rawValue):\(window.rawValue)"
    }
}

public struct WidgetDisplayPreferences: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var mainLimits: [WidgetMainLimitPreference]

    public init(mainLimits: [WidgetMainLimitPreference]) {
        schemaVersion = 1
        self.mainLimits = Self.normalized(mainLimits)
    }

    public static var defaultPreferences: WidgetDisplayPreferences {
        WidgetDisplayPreferences(mainLimits: defaultMainLimits)
    }

    public func preference(for summary: MainLimitSummary) -> WidgetMainLimitPreference? {
        mainLimits.first { $0.provider == summary.provider && $0.window == summary.window }
    }

    public func visibleMainLimitSummaries(from summaries: [MainLimitSummary], maximumCount: Int = 4) -> [MainLimitSummary] {
        let visible = summaries.filter { preference(for: $0)?.isVisible ?? false }
        let selected = visible.isEmpty ? summaries : visible

        return Array(selected.sorted { lhs, rhs in
            let lhsOrder = preference(for: lhs)?.sortOrder ?? Int.max
            let rhsOrder = preference(for: rhs)?.sortOrder ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.defaultWidgetSortRank > rhs.defaultWidgetSortRank
        }.prefix(maximumCount))
    }

    public func visibleMainLimitLanes(from summaries: [MainLimitSummary], maximumCount: Int = 4) -> [WidgetMainLimitLane] {
        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let visiblePreferences = mainLimits.filter(\.isVisible)

        if visiblePreferences.isEmpty {
            return visibleMainLimitSummaries(from: summaries, maximumCount: maximumCount).enumerated().map { index, summary in
                WidgetMainLimitLane(
                    preference: WidgetMainLimitPreference(
                        provider: summary.provider,
                        window: summary.window,
                        isVisible: true,
                        sortOrder: index
                    ),
                    summary: summary
                )
            }
        }

        return Array(visiblePreferences.prefix(maximumCount)).map { preference in
            WidgetMainLimitLane(preference: preference, summary: summaryByID[preference.id])
        }
    }

    public mutating func setMainLimit(provider: Provider, window: MainLimitWindow, isVisible: Bool) {
        let id = WidgetMainLimitPreference.id(provider: provider, window: window)
        if let index = mainLimits.firstIndex(where: { $0.id == id }) {
            mainLimits[index].isVisible = isVisible
        } else {
            mainLimits.append(WidgetMainLimitPreference(
                provider: provider,
                window: window,
                isVisible: isVisible,
                sortOrder: (mainLimits.map(\.sortOrder).max() ?? -1) + 1
            ))
        }
        mainLimits = Self.normalized(mainLimits)
    }

    public mutating func moveMainLimits(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = mainLimits
        let moving = source.sorted().map { reordered[$0] }
        for index in source.sorted(by: >) {
            reordered.remove(at: index)
        }
        let removedBeforeDestination = source.filter { $0 < destination }.count
        let adjustedDestination = max(0, min(destination - removedBeforeDestination, reordered.count))
        reordered.insert(contentsOf: moving, at: adjustedDestination)
        mainLimits = Self.renumbered(reordered)
    }

    private static func normalized(_ preferences: [WidgetMainLimitPreference]) -> [WidgetMainLimitPreference] {
        let merged = Dictionary(grouping: preferences + defaultMainLimits) { $0.id }
            .compactMap { _, values in values.first }

        return renumbered(merged.sorted {
            if $0.sortOrder != $1.sortOrder {
                return $0.sortOrder < $1.sortOrder
            }
            return $0.id < $1.id
        })
    }

    private static func renumbered(_ preferences: [WidgetMainLimitPreference]) -> [WidgetMainLimitPreference] {
        preferences.enumerated().map { index, preference in
            WidgetMainLimitPreference(
                provider: preference.provider,
                window: preference.window,
                isVisible: preference.isVisible,
                sortOrder: index
            )
        }
    }

    private static var defaultMainLimits: [WidgetMainLimitPreference] {
        [
            WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
            WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 1),
            WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 2),
            WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 3),
            WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: false, sortOrder: 4),
        ]
    }
}

public struct WidgetDisplayPreferencesStore: Sendable {
    public let preferencesURL: URL

    public init(preferencesURL: URL) {
        self.preferencesURL = preferencesURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: preferencesURL.path)
    }

    public func load() -> WidgetDisplayPreferences {
        loadIfAvailable() ?? .defaultPreferences
    }

    public func loadIfAvailable() -> WidgetDisplayPreferences? {
        guard FileManager.default.fileExists(atPath: preferencesURL.path) else {
            return nil
        }

        do {
            let preferences = try Self.makeDecoder().decode(
                WidgetDisplayPreferences.self,
                from: try Data(contentsOf: preferencesURL)
            )
            guard preferences.schemaVersion == 1 else {
                return nil
            }
            return preferences
        } catch {
            return nil
        }
    }

    public func save(_ preferences: WidgetDisplayPreferences) throws {
        let directory = preferencesURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(preferences)
        try data.write(to: preferencesURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public struct WidgetDisplayPreferencesStoreSet: Sendable {
    public let stores: [WidgetDisplayPreferencesStore]

    public init(stores: [WidgetDisplayPreferencesStore]) {
        self.stores = stores
    }

    public func load() -> WidgetDisplayPreferences {
        stores.compactMap { $0.loadIfAvailable() }.first ?? .defaultPreferences
    }

    public func save(_ preferences: WidgetDisplayPreferences) throws {
        var firstError: Error?
        var successfulWriteCount = 0

        for store in stores {
            do {
                try store.save(preferences)
                successfulWriteCount += 1
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        if successfulWriteCount == 0, let firstError {
            throw firstError
        }
    }
}

public struct WidgetMainLimitLane: Equatable, Identifiable, Sendable {
    public let preference: WidgetMainLimitPreference
    public let summary: MainLimitSummary?

    public var id: String { preference.id }
    public var provider: Provider { preference.provider }
    public var window: MainLimitWindow { preference.window }

    public init(preference: WidgetMainLimitPreference, summary: MainLimitSummary?) {
        self.preference = preference
        self.summary = summary
    }
}

public extension MainLimitSummary {
    var defaultWidgetSortRank: Int {
        if provider == .openAI, window == .weekly {
            return 100
        }
        if provider == .openAI, window == .fiveHour {
            return 80
        }
        if provider == .anthropic, window == .weekly {
            return 70
        }
        if provider == .anthropic, window == .fiveHour {
            return 60
        }
        if provider == .google, window == .daily {
            return 50
        }
        return 0
    }
}
