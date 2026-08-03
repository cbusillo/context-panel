import Foundation

public enum ValidationFixtureID: String, CaseIterable, Codable, Identifiable, Sendable {
    case healthy
    case resetVisible = "reset-visible"
    case cacheVisible = "cache-visible"
    case stale
    case loading
    case missing
    case failed
    case denseAccounts = "dense-accounts"
    case fitFallback = "fit-fallback"

    public var id: String { rawValue }
}

public enum ValidationFixtureSnapshotState: String, Codable, Sendable {
    case ready
    case setupNeeded = "setup-needed"
    case stale
    case failure
}

public enum ValidationFixtureStatus: String, Codable, Sendable {
    case healthy
    case close
    case limited
    case unknown
    case stale
    case loading
    case failure
}

public enum ValidationFixtureProvider: String, Codable, Sendable {
    case openAI = "openai"
    case anthropic
    case google
}

public enum ValidationFixtureConfidence: String, Codable, Sendable {
    case official
    case observed
    case estimated
}

public struct ValidationLimitFixture: Codable, Equatable, Sendable {
    public let provider: ValidationFixtureProvider
    public let accountID: String
    public let accountName: String
    public let label: String
    public let windowLabel: String
    public let modelLabel: String?
    public let usedPercent: Int?
    public let resetOffset: TimeInterval?
    public let confidence: ValidationFixtureConfidence
    public let statusOverride: ValidationFixtureStatus?

    public init(
        provider: ValidationFixtureProvider,
        accountID: String,
        accountName: String,
        label: String,
        windowLabel: String,
        modelLabel: String? = nil,
        usedPercent: Int?,
        resetOffset: TimeInterval?,
        confidence: ValidationFixtureConfidence = .official,
        statusOverride: ValidationFixtureStatus? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.accountName = accountName
        self.label = label
        self.windowLabel = windowLabel
        self.modelLabel = modelLabel
        self.usedPercent = usedPercent
        self.resetOffset = resetOffset
        self.confidence = confidence
        self.statusOverride = statusOverride
    }
}

public struct ValidationPromptCacheFixture: Codable, Equatable, Sendable {
    public let currentInputTokens: Int
    public let currentCachedTokens: Int
    public let previousInputTokens: Int
    public let previousCachedTokens: Int

    public init(
        currentInputTokens: Int,
        currentCachedTokens: Int,
        previousInputTokens: Int,
        previousCachedTokens: Int
    ) {
        self.currentInputTokens = currentInputTokens
        self.currentCachedTokens = currentCachedTokens
        self.previousInputTokens = previousInputTokens
        self.previousCachedTokens = previousCachedTokens
    }
}

public struct ValidationFixture: Codable, Equatable, Identifiable, Sendable {
    public let id: ValidationFixtureID
    public let title: String
    public let purpose: String
    public let snapshotState: ValidationFixtureSnapshotState
    public let generatedAge: TimeInterval
    public let status: ValidationFixtureStatus
    public let message: String
    public let syncErrorMessage: String?
    public let limits: [ValidationLimitFixture]
    public let promptCache: ValidationPromptCacheFixture?

    public init(
        id: ValidationFixtureID,
        title: String,
        purpose: String,
        snapshotState: ValidationFixtureSnapshotState,
        generatedAge: TimeInterval,
        status: ValidationFixtureStatus,
        message: String,
        syncErrorMessage: String? = nil,
        limits: [ValidationLimitFixture],
        promptCache: ValidationPromptCacheFixture? = nil
    ) {
        self.id = id
        self.title = title
        self.purpose = purpose
        self.snapshotState = snapshotState
        self.generatedAge = generatedAge
        self.status = status
        self.message = message
        self.syncErrorMessage = syncErrorMessage
        self.limits = limits
        self.promptCache = promptCache
    }
}

public enum ValidationFixtureCatalog {
    public static let referencePresentationDate = Date(timeIntervalSince1970: 1_785_672_000)

    public static let all: [ValidationFixture] = [
        healthy,
        resetVisible,
        cacheVisible,
        stale,
        loading,
        missing,
        failed,
        denseAccounts,
        fitFallback,
    ]

    public static func fixture(id: ValidationFixtureID) -> ValidationFixture {
        all.first { $0.id == id } ?? healthy
    }

    private static let healthy = ValidationFixture(
        id: .healthy,
        title: "Healthy portfolio",
        purpose: "Balanced multi-provider capacity with clear reset timing.",
        snapshotState: .ready,
        generatedAge: 75,
        status: .healthy,
        message: "All sample providers are available.",
        limits: standardLimits
    )

    private static let resetVisible = ValidationFixture(
        id: .resetVisible,
        title: "Reset pressure",
        purpose: "Near-limit lanes with short and rolling reset windows.",
        snapshotState: .ready,
        generatedAge: 50,
        status: .close,
        message: "A sample limit is close to reset.",
        limits: [
            limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI weekly", "Weekly", 87, 2.2 * day),
            limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI 5-hour", "5-hour", 94, 38 * minute),
            limit(.anthropic, "sample-claude-a", "Sample Claude A", "Claude weekly", "Weekly", 62, 3.1 * day),
            limit(.google, "sample-gemini-a", "Sample Gemini A", "Gemini daily", "Daily", 31, 8.5 * hour),
        ]
    )

    private static let cacheVisible = ValidationFixture(
        id: .cacheVisible,
        title: "Cache telemetry",
        purpose: "Prompt-cache telemetry remains visible beside limit pressure.",
        snapshotState: .ready,
        generatedAge: 40,
        status: .healthy,
        message: "Sample cache telemetry is available.",
        limits: standardLimits,
        promptCache: ValidationPromptCacheFixture(
            currentInputTokens: 48_000,
            currentCachedTokens: 39_000,
            previousInputTokens: 62_000,
            previousCachedTokens: 44_000
        )
    )

    private static let stale = ValidationFixture(
        id: .stale,
        title: "Saved stale data",
        purpose: "Last-good values remain visible with an honest stale state.",
        snapshotState: .stale,
        generatedAge: 18 * hour,
        status: .stale,
        message: "Showing saved sample usage.",
        limits: standardLimits
    )

    private static let loading = ValidationFixture(
        id: .loading,
        title: "Refreshing",
        purpose: "Last-good values remain stable during a sample refresh.",
        snapshotState: .ready,
        generatedAge: 90,
        status: .loading,
        message: "Refreshing sample usage.",
        limits: standardLimits.map { limit in
            ValidationLimitFixture(
                provider: limit.provider,
                accountID: limit.accountID,
                accountName: limit.accountName,
                label: limit.label,
                windowLabel: limit.windowLabel,
                modelLabel: limit.modelLabel,
                usedPercent: limit.usedPercent,
                resetOffset: limit.resetOffset,
                confidence: limit.confidence,
                statusOverride: .loading
            )
        }
    )

    private static let missing = ValidationFixture(
        id: .missing,
        title: "No configured limits",
        purpose: "Setup guidance without invented capacity or account identity.",
        snapshotState: .setupNeeded,
        generatedAge: 0,
        status: .unknown,
        message: "Set up Context Panel to track sample limits.",
        limits: []
    )

    private static let failed = ValidationFixture(
        id: .failed,
        title: "Refresh failed",
        purpose: "Last-good sample values with a clear failure treatment.",
        snapshotState: .failure,
        generatedAge: 22 * minute,
        status: .failure,
        message: "Sample provider refresh failed.",
        syncErrorMessage: "Sample refresh failed.",
        limits: standardLimits.map { limit in
            ValidationLimitFixture(
                provider: limit.provider,
                accountID: limit.accountID,
                accountName: limit.accountName,
                label: limit.label,
                windowLabel: limit.windowLabel,
                modelLabel: limit.modelLabel,
                usedPercent: limit.usedPercent,
                resetOffset: limit.resetOffset,
                confidence: limit.confidence,
                statusOverride: .failure
            )
        }
    )

    private static let denseAccounts = ValidationFixture(
        id: .denseAccounts,
        title: "Dense accounts",
        purpose: "Several sample accounts and windows compete for limited space.",
        snapshotState: .ready,
        generatedAge: 65,
        status: .close,
        message: "Several sample limits need attention.",
        limits: [
            limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI weekly", "Weekly", 78, 2.8 * day),
            limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI 5-hour", "5-hour", 42, 2.1 * hour),
            limit(.openAI, "sample-openai-b", "Sample OpenAI B", "OpenAI weekly", "Weekly", 29, 5.2 * day),
            limit(.openAI, "sample-openai-b", "Sample OpenAI B", "OpenAI 5-hour", "5-hour", 91, 54 * minute),
            limit(.anthropic, "sample-claude-a", "Sample Claude A", "Claude weekly", "Weekly", 83, 1.4 * day),
            limit(.anthropic, "sample-claude-a", "Sample Claude A", "Claude 5-hour", "5-hour", 48, 3.4 * hour),
            limit(.google, "sample-gemini-a", "Sample Gemini A", "Gemini daily", "Daily", 23, 11 * hour),
            limit(.google, "sample-gemini-b", "Sample Gemini B", "Gemini daily", "Daily", 67, 6.2 * hour),
        ]
    )

    private static let fitFallback = ValidationFixture(
        id: .fitFallback,
        title: "Fit fallback",
        purpose: "Long synthetic labels exercise truncation and compact fallbacks.",
        snapshotState: .ready,
        generatedAge: 55,
        status: .close,
        message: "Sample labels are intentionally long.",
        limits: [
            ValidationLimitFixture(
                provider: .openAI,
                accountID: "sample-openai-long",
                accountName: "Sample Organization Workspace Alpha",
                label: "OpenAI rolling weekly workspace allocation",
                windowLabel: "Weekly",
                modelLabel: "Sample High-Capability Model",
                usedPercent: 86,
                resetOffset: 1.6 * day,
                confidence: .estimated
            ),
            ValidationLimitFixture(
                provider: .anthropic,
                accountID: "sample-claude-long",
                accountName: "Sample Research Workspace Beta",
                label: "Claude extended rolling session allocation",
                windowLabel: "5-hour",
                modelLabel: "Sample Reasoning Model",
                usedPercent: 57,
                resetOffset: 3.6 * hour,
                confidence: .observed
            ),
            ValidationLimitFixture(
                provider: .google,
                accountID: "sample-gemini-long",
                accountName: "Sample Studio Workspace Gamma",
                label: "Gemini daily availability allocation",
                windowLabel: "Daily",
                modelLabel: "Sample Multimodal Model",
                usedPercent: 34,
                resetOffset: 9.4 * hour,
                confidence: .official
            ),
        ]
    )

    private static let standardLimits = [
        limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI weekly", "Weekly", 44, 4.2 * day),
        limit(.openAI, "sample-openai-a", "Sample OpenAI A", "OpenAI 5-hour", "5-hour", 21, 2.6 * hour),
        limit(.anthropic, "sample-claude-a", "Sample Claude A", "Claude weekly", "Weekly", 68, 2.3 * day),
        limit(.anthropic, "sample-claude-a", "Sample Claude A", "Claude 5-hour", "5-hour", 36, 3.8 * hour),
        limit(.google, "sample-gemini-a", "Sample Gemini A", "Gemini daily", "Daily", 18, 10.5 * hour),
    ]

    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 60 * minute
    private static let day: TimeInterval = 24 * hour

    private static func limit(
        _ provider: ValidationFixtureProvider,
        _ accountID: String,
        _ accountName: String,
        _ label: String,
        _ windowLabel: String,
        _ usedPercent: Int,
        _ resetOffset: TimeInterval
    ) -> ValidationLimitFixture {
        ValidationLimitFixture(
            provider: provider,
            accountID: accountID,
            accountName: accountName,
            label: label,
            windowLabel: windowLabel,
            usedPercent: usedPercent,
            resetOffset: resetOffset
        )
    }
}
