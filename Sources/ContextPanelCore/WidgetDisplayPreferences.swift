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

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mainLimits
    }

    public init(mainLimits: [WidgetMainLimitPreference]) {
        schemaVersion = 1
        self.mainLimits = Self.normalized(mainLimits)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        mainLimits = Self.normalized(try container.decode([WidgetMainLimitPreference].self, forKey: .mainLimits))
    }

    public static var defaultPreferences: WidgetDisplayPreferences {
        WidgetDisplayPreferences(mainLimits: defaultMainLimits)
    }

    public static func companionEffectivePreferences(
        localOverride: WidgetDisplayPreferences?,
        synced: WidgetDisplayPreferences?
    ) -> WidgetDisplayPreferences {
        localOverride ?? synced ?? .defaultPreferences
    }

    public func preference(for summary: MainLimitSummary) -> WidgetMainLimitPreference? {
        mainLimits.first { $0.provider == summary.provider && $0.window == summary.window }
    }

    public func visibleMainLimitSummaries(from summaries: [MainLimitSummary], maximumCount: Int = 4) -> [MainLimitSummary] {
        let visible = summaries.filter { preference(for: $0)?.isVisible ?? false }

        return Array(visible.sorted { lhs, rhs in
            let lhsOrder = preference(for: lhs)?.sortOrder ?? Int.max
            let rhsOrder = preference(for: rhs)?.sortOrder ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return lhs.defaultWidgetSortRank > rhs.defaultWidgetSortRank
        }.prefix(maximumCount))
    }

    public func visibleMainLimitLanes(from summaries: [MainLimitSummary], maximumCount: Int = 4) -> [WidgetMainLimitLane] {
        guard maximumCount > 0 else { return [] }

        let summaryByID = Dictionary(uniqueKeysWithValues: summaries.map { ($0.id, $0) })
        let visiblePreferences = mainLimits.filter(\.isVisible)

        if visiblePreferences.isEmpty {
            return []
        }

        let selectedPreferences: [WidgetMainLimitPreference]
        if visiblePreferences.count <= maximumCount {
            selectedPreferences = visiblePreferences
        } else {
            var selectedIDs = Set<String>()
            for preference in visiblePreferences where summaryByID[preference.id] != nil {
                guard selectedIDs.count < maximumCount else { break }
                selectedIDs.insert(preference.id)
            }
            for preference in visiblePreferences where !selectedIDs.contains(preference.id) {
                guard selectedIDs.count < maximumCount else { break }
                selectedIDs.insert(preference.id)
            }
            selectedPreferences = visiblePreferences.filter { selectedIDs.contains($0.id) }
        }

        return selectedPreferences.map { preference in
            WidgetMainLimitLane(preference: preference, summary: summaryByID[preference.id])
        }
    }

    public func mainLimitAnswerSelection(
        from summaries: [MainLimitSummary],
        provider: Provider? = nil
    ) -> MainLimitAnswerSelection {
        let scopedSummaries = summaries.filter { summary in
            provider == nil || summary.provider == provider
        }
        let maximumCount = max(mainLimits.count, scopedSummaries.count)
        let savedLanes = visibleMainLimitLanes(
            from: scopedSummaries,
            maximumCount: maximumCount
        )
        .filter { lane in
            provider == nil || lane.provider == provider
        }
        let primary = savedLanes.first
        let closestSummary = savedLanes.isEmpty
            ? nil
            : scopedSummaries
                .filter { summary in
                    summary.id != primary?.id
                        && summary.remainingCapacityRatio != nil
                        && summary.status.isCurrentCapacityStatus
                }
                .sorted { lhs, rhs in
                    let lhsRemaining = lhs.remainingCapacityRatio ?? 1
                    let rhsRemaining = rhs.remainingCapacityRatio ?? 1
                    if lhsRemaining != rhsRemaining {
                        return lhsRemaining < rhsRemaining
                    }
                    return lhs.defaultWidgetSortRank > rhs.defaultWidgetSortRank
                }
                .first
        let closest = closestSummary.flatMap { summary -> WidgetMainLimitLane? in
            guard Self.shouldShowClosestLimit(primary: primary, candidate: summary) else { return nil }
            let preference = preference(for: summary) ?? WidgetMainLimitPreference(
                provider: summary.provider,
                window: summary.window,
                isVisible: true,
                sortOrder: Int.max
            )
            return WidgetMainLimitLane(preference: preference, summary: summary)
        }

        return MainLimitAnswerSelection(
            primary: primary,
            closest: closest,
            saved: savedLanes
        )
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
        if matchesLegacyHiddenOpenAIFiveHourDefaults(preferences) {
            return renumbered(defaultMainLimits)
        }

        var merged: [WidgetMainLimitPreference] = []
        var seen = Set<String>()

        for preference in preferences where seen.insert(preference.id).inserted {
            merged.append(preference)
        }

        var nextSortOrder = (merged.map(\.sortOrder).max() ?? -1) + 1
        for defaultPreference in defaultMainLimits where seen.insert(defaultPreference.id).inserted {
            merged.append(WidgetMainLimitPreference(
                provider: defaultPreference.provider,
                window: defaultPreference.window,
                isVisible: defaultPreference.isVisible,
                sortOrder: nextSortOrder
            ))
            nextSortOrder += 1
        }

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

    private static func matchesLegacyHiddenOpenAIFiveHourDefaults(_ preferences: [WidgetMainLimitPreference]) -> Bool {
        let legacyDefaults = [
            WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
            WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 1),
            WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 2),
            WidgetMainLimitPreference(provider: .google, window: .availability, isVisible: true, sortOrder: 3),
            WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 4),
            WidgetMainLimitPreference(provider: .google, window: .fiveHour, isVisible: true, sortOrder: 5),
            WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 6),
            WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: false, sortOrder: 7),
        ]

        return preferences == legacyDefaults
    }

    private static func shouldShowClosestLimit(
        primary: WidgetMainLimitLane?,
        candidate: MainLimitSummary
    ) -> Bool {
        guard let candidateRemaining = candidate.remainingCapacityRatio else { return false }
        if let primaryRemaining = primary?.summary?.remainingCapacityRatio {
            guard candidateRemaining < primaryRemaining else { return false }
            if candidate.status == .close || candidate.status == .limited {
                return true
            }
            let primaryDecimal = Decimal(string: String(primaryRemaining)) ?? Decimal(primaryRemaining)
            let candidateDecimal = Decimal(string: String(candidateRemaining)) ?? Decimal(candidateRemaining)
            let materialDifference = Decimal(MainLimitAnswerSelection.materialDifferencePoints) / 100
            return primaryDecimal - candidateDecimal >= materialDifference
        }
        if candidate.status == .close || candidate.status == .limited {
            return true
        }
        return false
    }

    private static var defaultMainLimits: [WidgetMainLimitPreference] {
        [
            WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
            WidgetMainLimitPreference(provider: .openAI, window: .fiveHour, isVisible: true, sortOrder: 1),
            WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 2),
            WidgetMainLimitPreference(provider: .anthropic, window: .fiveHour, isVisible: true, sortOrder: 3),
            WidgetMainLimitPreference(provider: .google, window: .availability, isVisible: true, sortOrder: 4),
            WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 5),
            WidgetMainLimitPreference(provider: .google, window: .fiveHour, isVisible: true, sortOrder: 6),
            WidgetMainLimitPreference(provider: .google, window: .daily, isVisible: true, sortOrder: 7),
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

public struct MainLimitAnswerSelection: Equatable, Sendable {
    public static let materialDifferencePoints = 20

    public let primary: WidgetMainLimitLane?
    public let closest: WidgetMainLimitLane?
    public let saved: [WidgetMainLimitLane]

    public var supportingSaved: [WidgetMainLimitLane] {
        saved.filter { $0.id != primary?.id }
    }

    public func compactSupportingLanes(maximumCount: Int) -> [WidgetMainLimitLane] {
        guard maximumCount > 0 else { return [] }

        var lanes: [WidgetMainLimitLane] = []
        var representedIDs = Set<String>()
        for lane in [closest].compactMap({ $0 }) + supportingSaved {
            guard representedIDs.insert(lane.id).inserted else { continue }
            lanes.append(lane)
            guard lanes.count < maximumCount else { break }
        }
        return lanes
    }

    public init(
        primary: WidgetMainLimitLane?,
        closest: WidgetMainLimitLane?,
        saved: [WidgetMainLimitLane]
    ) {
        self.primary = primary
        self.closest = closest
        self.saved = saved
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
        if provider == .google, window == .weekly {
            return 58
        }
        if provider == .google, window == .availability {
            return 57
        }
        if provider == .google, window == .fiveHour {
            return 55
        }
        if provider == .google, window == .daily {
            return 50
        }
        return 0
    }
}

private extension UsageStatus {
    var isCurrentCapacityStatus: Bool {
        switch self {
        case .healthy, .close, .limited:
            true
        case .stale, .unknown, .failure, .loading:
            false
        }
    }
}
