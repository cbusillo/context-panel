import ContextPanelCore
import ContextPanelValidationFixtures
import Foundation

public enum WatchValidationAppState: String, CaseIterable, Identifiable, Sendable {
    case healthy
    case setupNeeded
    case stale
    case loading
    case failure
    case providerAccess
    case denseAccounts
    case fitFallback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .setupNeeded: "Setup needed"
        case .stale: "Saved stale"
        case .loading: "Refreshing"
        case .failure: "Refresh failed"
        case .providerAccess: "Provider access"
        case .denseAccounts: "Dense accounts"
        case .fitFallback: "Fit fallback"
        }
    }
}

public enum WatchValidationComplicationState: String, CaseIterable, Identifiable, Sendable {
    case available
    case close
    case unknown
    case providerAccess

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .available: "Available"
        case .close: "Close to limit"
        case .unknown: "Unknown"
        case .providerAccess: "Provider access"
        }
    }
}

public enum WatchValidationComplicationFamily: String, CaseIterable, Identifiable, Sendable {
    case circular
    case rectangular
    case inline
    case corner

    public var id: String { rawValue }
}

public enum WatchValidationSurface: String, Sendable {
    case app = "watchos.app"
    case complication = "watchos.complication"
}

public enum WatchValidationLaunchRequest: Equatable, Sendable {
    case normal
    case galleryIndex
    case app(state: WatchValidationAppState)
    case complication(
        state: WatchValidationComplicationState,
        family: WatchValidationComplicationFamily
    )
    case invalid

    public static let galleryArgument = "--context-panel-validation-gallery"
    public static let surfaceArgument = "--context-panel-validation-surface"
    public static let stateArgument = "--context-panel-validation-state"
    public static let familyArgument = "--context-panel-validation-family"

    public init(arguments: [String]) {
        self = Self.parse(arguments: arguments)
    }

    public static func parse(arguments: [String]) -> Self {
        var tokens = arguments
        if tokens.first.map({ !$0.hasPrefix("-") }) == true {
            tokens.removeFirst()
        }

        let hasValidationArgument = tokens.contains {
            $0 == galleryArgument || $0.hasPrefix("--context-panel-validation-")
        }
        guard hasValidationArgument else { return .normal }
        guard tokens.count(where: { $0 == galleryArgument }) == 1 else { return .invalid }

        var values: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == galleryArgument {
                index += 1
                continue
            }

            guard token == surfaceArgument || token == stateArgument || token == familyArgument,
                  index + 1 < tokens.count
            else {
                return .invalid
            }

            let value = tokens[index + 1]
            guard !value.isEmpty,
                  !value.hasPrefix("-"),
                  values[token] == nil
            else {
                return .invalid
            }
            values[token] = value
            index += 2
        }

        guard let rawSurface = values[surfaceArgument] else {
            return values.isEmpty ? .galleryIndex : .invalid
        }
        guard let surface = WatchValidationSurface(rawValue: rawSurface),
              let rawState = values[stateArgument]
        else {
            return .invalid
        }

        switch surface {
        case .app:
            guard values[familyArgument] == nil,
                  let state = WatchValidationAppState(rawValue: rawState)
            else {
                return .invalid
            }
            return .app(state: state)

        case .complication:
            guard let rawFamily = values[familyArgument],
                  let state = WatchValidationComplicationState(rawValue: rawState),
                  let family = WatchValidationComplicationFamily(rawValue: rawFamily)
            else {
                return .invalid
            }
            return .complication(state: state, family: family)
        }
    }
}

public struct WatchValidationFixtureContext: Sendable {
    public let snapshot: WidgetSnapshot
    public let result: CompanionSyncLoadResult
    public let displayPreferences: WidgetDisplayPreferences
    public let presentationDate: Date

    public init(
        snapshot: WidgetSnapshot,
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences,
        presentationDate: Date
    ) {
        self.snapshot = snapshot
        self.result = result
        self.displayPreferences = displayPreferences
        self.presentationDate = presentationDate
    }
}

public struct WatchValidationFixtureAdapter: Sendable {
    private let adapter = ValidationGalleryFixtureAdapter()

    public init() {}

    public func appContext(
        state: WatchValidationAppState,
        presentationDate: Date = ValidationFixtureCatalog.referencePresentationDate
    ) -> WatchValidationFixtureContext {
        let snapshot = switch state {
        case .providerAccess:
            adapter.providerAccessSnapshot(presentationDate: presentationDate)
        default:
            adapter.snapshot(
                fixtureID: fixtureID(for: state),
                presentationDate: presentationDate
            )
        }
        return context(snapshot: snapshot, presentationDate: presentationDate)
    }

    public func complicationContext(
        state: WatchValidationComplicationState,
        presentationDate: Date = ValidationFixtureCatalog.referencePresentationDate
    ) -> WatchValidationFixtureContext {
        let snapshot = switch state {
        case .available:
            adapter.snapshot(fixtureID: .healthy, presentationDate: presentationDate)
        case .close:
            adapter.snapshot(fixtureID: .resetVisible, presentationDate: presentationDate)
        case .unknown:
            adapter.snapshot(fixtureID: .missing, presentationDate: presentationDate)
        case .providerAccess:
            adapter.providerAccessSnapshot(presentationDate: presentationDate)
        }
        return context(snapshot: snapshot, presentationDate: presentationDate)
    }

    private func context(
        snapshot: WidgetSnapshot,
        presentationDate: Date
    ) -> WatchValidationFixtureContext {
        let storedSnapshot = StoredUsageSnapshot(
            savedAt: snapshot.generatedAt,
            snapshot: snapshot.usageSnapshot,
            reports: snapshot.reports,
            promptCacheObservations: snapshot.promptCacheObservations
        )
        let document: CompanionSyncDocument? = switch snapshot.state {
        case .setupNeeded:
            nil
        case .ready, .stale, .failure:
            CompanionSyncDocument(
                storedSnapshot: storedSnapshot,
                publishedAt: presentationDate,
                widgetDisplayPreferences: adapter.displayPreferences,
                observedBurnRates: snapshot.observedBurnRates,
                fastModeForecastSettings: snapshot.fastModeForecastSettings
            )
        }
        return WatchValidationFixtureContext(
            snapshot: snapshot,
            result: CompanionSyncLoadResult(
                document: document,
                status: snapshot.status,
                errorMessage: snapshot.syncErrorMessage
            ),
            displayPreferences: adapter.displayPreferences,
            presentationDate: presentationDate
        )
    }

    private func fixtureID(for state: WatchValidationAppState) -> ValidationFixtureID {
        switch state {
        case .healthy: .healthy
        case .setupNeeded: .missing
        case .stale: .stale
        case .loading: .loading
        case .failure: .failed
        case .providerAccess: .healthy
        case .denseAccounts: .denseAccounts
        case .fitFallback: .fitFallback
        }
    }

}
