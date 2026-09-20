import ContextPanelCore
import ContextPanelValidationFixtures
import Foundation

public enum TVValidationState: String, CaseIterable, Identifiable, Sendable {
    case healthy
    case resetVisible
    case stale
    case loading
    case setupNeeded
    case failure
    case partialFailure
    case providerAccess
    case denseAccounts
    case fitFallback

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .healthy: "Healthy"
        case .resetVisible: "Reset visible"
        case .stale: "Saved stale"
        case .loading: "Refreshing"
        case .setupNeeded: "Setup needed"
        case .failure: "Refresh failed"
        case .partialFailure: "Partial provider failure"
        case .providerAccess: "Provider access"
        case .denseAccounts: "Dense accounts"
        case .fitFallback: "Fit fallback"
        }
    }
}

public struct TVValidationFixtureContext: Sendable {
    public let snapshot: WidgetSnapshot
    public let result: CompanionSyncLoadResult
    public let displayPreferences: WidgetDisplayPreferences
    public let presentationDate: Date
    public let receivedAt: Date?

    public init(
        snapshot: WidgetSnapshot,
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences,
        presentationDate: Date,
        receivedAt: Date?
    ) {
        self.snapshot = snapshot
        self.result = result
        self.displayPreferences = displayPreferences
        self.presentationDate = presentationDate
        self.receivedAt = receivedAt
    }
}

public struct TVValidationFixtureAdapter: Sendable {
    private let adapter = ValidationGalleryFixtureAdapter()

    public init() {}

    public func context(
        state: TVValidationState,
        presentationDate: Date = ValidationFixtureCatalog.referencePresentationDate
    ) -> TVValidationFixtureContext {
        let snapshot = switch state {
        case .partialFailure:
            partialFailureSnapshot(presentationDate: presentationDate)
        case .providerAccess:
            adapter.providerAccessSnapshot(presentationDate: presentationDate)
        default:
            adapter.snapshot(
                fixtureID: fixtureID(for: state),
                presentationDate: presentationDate
            )
        }
        let document: CompanionSyncDocument? = switch snapshot.state {
        case .setupNeeded:
            nil
        case .ready, .stale, .failure:
            CompanionSyncDocument(
                storedSnapshot: StoredUsageSnapshot(
                    savedAt: snapshot.generatedAt,
                    snapshot: snapshot.usageSnapshot,
                    reports: snapshot.reports,
                    promptCacheObservations: snapshot.promptCacheObservations
                ),
                publishedAt: presentationDate,
                widgetDisplayPreferences: adapter.displayPreferences,
                observedBurnRates: snapshot.observedBurnRates,
                fastModeForecastSettings: snapshot.fastModeForecastSettings
            )
        }
        return TVValidationFixtureContext(
            snapshot: snapshot,
            result: CompanionSyncLoadResult(
                document: document,
                status: snapshot.status,
                errorMessage: snapshot.syncErrorMessage
            ),
            displayPreferences: adapter.displayPreferences,
            presentationDate: presentationDate,
            receivedAt: document == nil ? nil : presentationDate.addingTimeInterval(-30)
        )
    }

    private func fixtureID(for state: TVValidationState) -> ValidationFixtureID {
        switch state {
        case .healthy: .healthy
        case .resetVisible: .resetVisible
        case .stale: .stale
        case .loading: .loading
        case .setupNeeded: .missing
        case .failure: .failed
        case .partialFailure: .healthy
        case .providerAccess: .healthy
        case .denseAccounts: .denseAccounts
        case .fitFallback: .fitFallback
        }
    }

    private func partialFailureSnapshot(presentationDate: Date) -> WidgetSnapshot {
        let base = adapter.snapshot(fixtureID: .healthy, presentationDate: presentationDate)
        let report = StoredProviderReport(
            provider: .google,
            accountID: "sample-google-partial",
            configuredAccountID: "sample-google-partial",
            accountName: "Sample Google Partial",
            generatedAt: base.generatedAt,
            status: .failure,
            errorMessage: "Sample provider refresh failed."
        )
        return WidgetSnapshot(
            state: .ready,
            generatedAt: base.generatedAt,
            limits: base.limits,
            reports: base.reports + [report],
            promptCacheObservations: base.promptCacheObservations,
            promptCacheWidgetState: base.promptCacheWidgetState,
            observedBurnRates: base.observedBurnRates,
            fastModeForecastSettings: base.fastModeForecastSettings,
            status: .failure,
            message: "Sample usage is available with one provider refresh failure.",
            syncErrorMessage: "Sample provider refresh failed."
        )
    }

}

public enum TVValidationLaunchFamily: String, CaseIterable, Sendable {
    case runway
    case provider
    case topShelf
}

public enum TVValidationLaunchPresentation: String, CaseIterable, Sendable {
    case fullDetail
    case projectOnly
    case countsOnly
}

public struct TVValidationLaunchSample: Equatable, Sendable {
    public let state: TVValidationState
    public let family: TVValidationLaunchFamily
    public let presentation: TVValidationLaunchPresentation
}

/// Operator-only launch arguments that open one Validation Gallery sample for
/// host-side capture. Anything outside the bounded vocabulary is `.invalid`, and
/// the app then shows its normal UI.
public enum TVValidationLaunchRequest: Equatable, Sendable {
    case normal
    case galleryIndex
    case sample(TVValidationLaunchSample)
    case invalid

    public static let galleryArgument = "--context-panel-validation-gallery"
    public static let surfaceArgument = "--context-panel-validation-surface"
    public static let fixtureArgument = "--context-panel-validation-fixture"
    public static let familyArgument = "--context-panel-validation-family"
    public static let presentationArgument = "--context-panel-validation-presentation"

    public static let appSurface = "tvos.app"
    public static let topShelfSurface = "tvos.top-shelf"

    public init(arguments: [String]) {
        self = Self.parse(arguments: arguments)
    }

    public static func parse(arguments: [String]) -> Self {
        let tokens = Array(arguments.dropFirst(arguments.first.map { !$0.hasPrefix("-") } == true ? 1 : 0))
        guard tokens.contains(where: { $0.hasPrefix("--context-panel-validation-") }) else { return .normal }
        guard tokens.filter({ $0 == galleryArgument }).count == 1 else { return .invalid }

        let valueArguments = [surfaceArgument, fixtureArgument, familyArgument, presentationArgument]
        var values: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token != galleryArgument, token.hasPrefix("--context-panel-validation-") else {
                index += 1
                continue
            }
            guard valueArguments.contains(token), index + 1 < tokens.count else { return .invalid }
            let value = tokens[index + 1]
            guard !value.isEmpty, !value.hasPrefix("-"), values[token] == nil else { return .invalid }
            values[token] = value
            index += 2
        }

        guard !values.isEmpty else { return .galleryIndex }
        guard let surface = values[surfaceArgument],
              let fixture = values[fixtureArgument].flatMap(ValidationFixtureID.init(rawValue:)),
              let state = validationState(for: fixture),
              let family = values[familyArgument].flatMap(TVValidationLaunchFamily.init(rawValue:)),
              let presentation = values[presentationArgument].flatMap(TVValidationLaunchPresentation.init(rawValue:))
        else {
            return .invalid
        }

        switch (surface, family) {
        case (appSurface, .runway), (appSurface, .provider), (topShelfSurface, .topShelf):
            return .sample(TVValidationLaunchSample(state: state, family: family, presentation: presentation))
        default:
            return .invalid
        }
    }

    private static func validationState(for fixture: ValidationFixtureID) -> TVValidationState? {
        switch fixture {
        case .healthy: .healthy
        case .resetVisible: .resetVisible
        case .stale: .stale
        case .loading: .loading
        case .missing: .setupNeeded
        case .failed: .failure
        case .denseAccounts: .denseAccounts
        case .fitFallback: .fitFallback
        case .cacheVisible: nil
        }
    }
}
