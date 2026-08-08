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
