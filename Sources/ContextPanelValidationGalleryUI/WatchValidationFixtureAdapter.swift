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
            providerAccessSnapshot(presentationDate: presentationDate)
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
            providerAccessSnapshot(presentationDate: presentationDate)
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

    private func providerAccessSnapshot(presentationDate: Date) -> WidgetSnapshot {
        let generatedAt = presentationDate.addingTimeInterval(-45)
        let report = StoredProviderReport(
            provider: .anthropic,
            accountID: "sample-claude-access",
            configuredAccountID: "sample-claude-access",
            accountName: "Sample Claude Access",
            generatedAt: generatedAt,
            status: .limited,
            accessState: ProviderAccessState(
                kind: .blockedUntilReset,
                resetsAt: presentationDate.addingTimeInterval(3 * 3_600)
            ),
            errorMessage: nil
        )
        return WidgetSnapshot(
            state: .ready,
            generatedAt: generatedAt,
            limits: [],
            reports: [report],
            status: .limited,
            message: "Sample plan access is unavailable until reset."
        )
    }
}
