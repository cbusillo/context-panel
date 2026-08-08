import ContextPanelCore
import ContextPanelValidationFixtures
import Foundation

public struct ValidationGalleryFixtureAdapter: Sendable {
    public init() {}

    public func snapshot(
        fixtureID: ValidationFixtureID,
        presentationDate: Date
    ) -> WidgetSnapshot {
        snapshot(
            fixture: ValidationFixtureCatalog.fixture(id: fixtureID),
            presentationDate: presentationDate
        )
    }

    public func snapshot(
        fixture: ValidationFixture,
        presentationDate: Date
    ) -> WidgetSnapshot {
        let generatedAt = presentationDate.addingTimeInterval(-fixture.generatedAge)
        let limits = fixture.limits.map { limit in
            UsageLimit(
                provider: provider(limit.provider),
                accountID: limit.accountID,
                configuredAccountID: limit.accountID,
                accountName: limit.accountName,
                label: limit.label,
                windowLabel: limit.windowLabel,
                modelLabel: limit.modelLabel,
                unit: .percent,
                used: limit.usedPercent,
                limit: limit.usedPercent == nil ? nil : 100,
                resetsAt: limit.resetOffset.map { presentationDate.addingTimeInterval($0) },
                lastUpdatedAt: generatedAt,
                confidence: confidence(limit.confidence),
                statusOverride: limit.statusOverride.map(status)
            )
        }
        let reports = reports(
            limits: limits,
            generatedAt: generatedAt,
            fixtureStatus: fixture.status
        )
        let promptCacheObservations = promptCacheObservations(
            fixture.promptCache,
            presentationDate: presentationDate
        )
        let usageSnapshot = UsageSnapshot(generatedAt: generatedAt, limits: limits)
        let observedBurnRates = observedBurnRates(for: usageSnapshot)

        return WidgetSnapshot(
            state: snapshotState(fixture.snapshotState),
            generatedAt: generatedAt,
            limits: limits,
            reports: reports,
            promptCacheObservations: promptCacheObservations,
            promptCacheWidgetState: fixture.promptCache == nil ? .unavailable : .available,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: .defaultSettings,
            status: status(fixture.status),
            message: fixture.message,
            syncErrorMessage: fixture.syncErrorMessage
        )
    }

    public var displayPreferences: WidgetDisplayPreferences {
        .defaultPreferences
    }

    public func providerAccessSnapshot(presentationDate: Date) -> WidgetSnapshot {
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

    private func observedBurnRates(for snapshot: UsageSnapshot) -> [String: ObservedBurnRate] {
        Dictionary(uniqueKeysWithValues: snapshot.mainLimitSummaries.compactMap { summary in
            guard summary.provider == .openAI else { return nil }
            let unitsPerHour: Double = switch summary.window {
            case .fiveHour:
                3.2
            case .weekly:
                0.72
            case .daily, .availability:
                0.4
            }
            return (
                summary.id,
                ObservedBurnRate(
                    limitID: summary.id,
                    unitsPerHour: unitsPerHour,
                    observedDurationHours: 12,
                    sampleCount: 4
                )
            )
        })
    }

    private func reports(
        limits: [UsageLimit],
        generatedAt: Date,
        fixtureStatus: ValidationFixtureStatus
    ) -> [StoredProviderReport] {
        Dictionary(grouping: limits, by: { "\($0.provider.rawValue):\($0.accountID)" })
            .compactMap { _, accountLimits in
                guard let first = accountLimits.first else { return nil }
                let limitStatus = accountLimits.map(\.status).contextPanelWorstStatus
                let reportStatus: UsageStatus = switch fixtureStatus {
                case .failure:
                    .failure
                case .loading:
                    .loading
                case .stale:
                    .stale
                case .healthy, .close, .limited, .unknown:
                    limitStatus
                }
                return StoredProviderReport(
                    provider: first.provider,
                    accountID: first.accountID,
                    configuredAccountID: first.configuredAccountID,
                    accountName: first.accountName,
                    generatedAt: generatedAt,
                    status: reportStatus,
                    errorMessage: reportStatus == .failure ? "Sample provider refresh failed." : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider {
                    return lhs.provider.rawValue < rhs.provider.rawValue
                }
                return lhs.accountID < rhs.accountID
            }
    }

    private func promptCacheObservations(
        _ fixture: ValidationPromptCacheFixture?,
        presentationDate: Date
    ) -> [PromptCacheObservation] {
        guard let fixture else { return [] }
        return [
            PromptCacheObservation(
                id: "sample-cache-current",
                provider: .openAI,
                accountID: "sample-openai-a",
                accountName: "Sample OpenAI A",
                observedAt: presentationDate.addingTimeInterval(-12 * 60),
                windowLabel: "Current sample session",
                tokens: PromptCacheTokenSet(
                    inputTokens: fixture.currentInputTokens,
                    cachedInputTokens: fixture.currentCachedTokens
                )
            ),
            PromptCacheObservation(
                id: "sample-cache-previous",
                provider: .openAI,
                accountID: "sample-openai-a",
                accountName: "Sample OpenAI A",
                observedAt: presentationDate.addingTimeInterval(-90 * 60),
                windowLabel: "Previous sample session",
                tokens: PromptCacheTokenSet(
                    inputTokens: fixture.previousInputTokens,
                    cachedInputTokens: fixture.previousCachedTokens
                )
            ),
        ]
    }

    private func provider(_ provider: ValidationFixtureProvider) -> Provider {
        switch provider {
        case .openAI:
            .openAI
        case .anthropic:
            .anthropic
        case .google:
            .google
        }
    }

    private func confidence(_ confidence: ValidationFixtureConfidence) -> UsageConfidence {
        switch confidence {
        case .official:
            .official
        case .observed:
            .observed
        case .estimated:
            .estimated
        }
    }

    private func snapshotState(_ state: ValidationFixtureSnapshotState) -> WidgetSnapshotState {
        switch state {
        case .ready:
            .ready
        case .setupNeeded:
            .setupNeeded
        case .stale:
            .stale
        case .failure:
            .failure
        }
    }

    private func status(_ status: ValidationFixtureStatus) -> UsageStatus {
        switch status {
        case .healthy:
            .healthy
        case .close:
            .close
        case .limited:
            .limited
        case .unknown:
            .unknown
        case .stale:
            .stale
        case .loading:
            .loading
        case .failure:
            .failure
        }
    }
}
