#if DEBUG
import ContextPanelCore
import Foundation

enum TVPreviewFixtures {
    static var usesFixture: Bool {
        ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_FIXTURE"] != nil
    }

    static var forcesRemoteFailure: Bool {
        ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_FORCE_REMOTE_FAILURE"] == "1"
    }

    static var requestedProviderRawValue: String? {
        ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_INITIAL_PROVIDER"]
    }

    static var requestedFocusProviderRawValue: String? {
        ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_INITIAL_FOCUS_PROVIDER"]
    }

    static var opensValidationGallery: Bool {
        ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_OPEN_VALIDATION_GALLERY"] == "1"
    }

    static func requestedResult(now: Date) -> CompanionSyncLoadResult? {
        guard let fixture = ProcessInfo.processInfo.environment["CONTEXT_PANEL_TV_FIXTURE"] else {
            return nil
        }

        if fixture == "empty" {
            return CompanionSyncLoadResult(document: nil, status: .unknown)
        }

        let generatedAt = fixture == "stale" ? now.addingTimeInterval(-18 * 60 * 60) : now.addingTimeInterval(-95)
        let document = makeDocument(
            generatedAt: generatedAt,
            publishedAt: now.addingTimeInterval(-35),
            includesPartialFailure: fixture == "partial",
            showsDistinctClosest: fixture == "closest",
            omitsOpenAIFiveHour: fixture == "missing-five-hour"
        )
        let status: UsageStatus = switch fixture {
        case "failure":
            .failure
        case "stale":
            .stale
        default:
            document.companionStatus
        }

        return CompanionSyncLoadResult(
            document: document,
            status: status,
            errorMessage: fixture == "failure" ? "The preview CloudKit connection is unavailable." : nil,
            transportMetadata: CompanionSyncTransportMetadata(
                source: .cloudKit,
                receivedAt: now.addingTimeInterval(-35),
                mirroredAt: now.addingTimeInterval(-34),
                deliveryStatus: fixture == "failure" ? .failed : .healthy
            )
        )
    }

    private static func makeDocument(
        generatedAt: Date,
        publishedAt: Date,
        includesPartialFailure: Bool,
        showsDistinctClosest: Bool,
        omitsOpenAIFiveHour: Bool
    ) -> CompanionSyncDocument {
        let limits = [
            UsageLimit(
                provider: .openAI,
                accountID: "sample-openai-personal",
                configuredAccountID: "sample-openai-personal",
                accountName: "Sample OpenAI Personal",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 66,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(3.4 * 24 * 60 * 60),
                confidence: .official
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "sample-openai-work",
                configuredAccountID: "sample-openai-work",
                accountName: "Sample OpenAI Work",
                label: "OpenAI weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 31,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(5.1 * 24 * 60 * 60),
                confidence: .official
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "sample-openai-personal",
                configuredAccountID: "sample-openai-personal",
                accountName: "Sample OpenAI Personal",
                label: "OpenAI 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: showsDistinctClosest ? 92 : 18,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(2.2 * 60 * 60),
                confidence: .official
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "sample-claude-main",
                configuredAccountID: "sample-claude-main",
                accountName: "Sample Claude Main",
                label: "Claude 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 47,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(3.8 * 60 * 60),
                confidence: .official
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "sample-claude-main",
                configuredAccountID: "sample-claude-main",
                accountName: "Sample Claude Main",
                label: "Claude weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 81,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(1.7 * 24 * 60 * 60),
                confidence: .official
            ),
            UsageLimit(
                provider: .google,
                accountID: "sample-google-antigravity",
                configuredAccountID: "sample-google-antigravity",
                accountName: "Sample Antigravity",
                label: "Gemini daily",
                windowLabel: "Daily",
                unit: .percent,
                used: 12,
                limit: 100,
                resetsAt: generatedAt.addingTimeInterval(11.5 * 60 * 60),
                confidence: .official
            ),
        ].filter { limit in
            !omitsOpenAIFiveHour
                || limit.provider != .openAI
                || limit.windowLabel != "5-hour"
        }
        var reports = Dictionary(grouping: limits, by: { "\($0.provider.rawValue):\($0.accountID)" })
            .compactMap { _, accountLimits -> StoredProviderReport? in
                guard let limit = accountLimits.first else { return nil }
                return StoredProviderReport(
                    provider: limit.provider,
                    accountID: limit.accountID,
                    configuredAccountID: limit.configuredAccountID,
                    accountName: limit.accountName,
                    generatedAt: generatedAt,
                    status: accountLimits.map(\.status).contextPanelWorstStatus,
                    errorMessage: nil
                )
            }
        if includesPartialFailure {
            reports.append(
                StoredProviderReport(
                    provider: .openAI,
                    accountID: "sample-openai-team",
                    configuredAccountID: "sample-openai-team",
                    accountName: "Sample OpenAI Team",
                    generatedAt: generatedAt,
                    status: .failure,
                    errorMessage: "Reconnect required"
                )
            )
        }
        let stored = StoredUsageSnapshot(
            savedAt: publishedAt,
            snapshot: UsageSnapshot(generatedAt: generatedAt, limits: limits),
            reports: reports
        )
        let widgetDisplayPreferences = omitsOpenAIFiveHour
            ? WidgetDisplayPreferences(mainLimits: WidgetDisplayPreferences.defaultPreferences.mainLimits.map { preference in
                guard preference.provider == .openAI else { return preference }
                return WidgetMainLimitPreference(
                    provider: preference.provider,
                    window: preference.window,
                    isVisible: preference.isVisible,
                    sortOrder: preference.window == .fiveHour ? 0 : 1
                )
            })
            : .defaultPreferences
        return CompanionSyncDocument(
            storedSnapshot: stored,
            publishedAt: publishedAt,
            widgetDisplayPreferences: widgetDisplayPreferences
        )
    }
}
#endif
