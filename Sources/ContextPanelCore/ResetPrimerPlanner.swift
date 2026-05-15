import Foundation

public enum ResetPrimerRunStatus: String, Codable, Equatable, Sendable {
    case completed
    case failed
    case skipped
}

public struct ResetPrimerRunKey: Codable, Equatable, Hashable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let resetAt: Date

    public init(provider: Provider, accountID: String, windowLabel: String, resetAt: Date) {
        self.provider = provider
        self.accountID = accountID
        self.resetAt = resetAt
    }

    public init(provider: Provider, accountID: String, resetAt: Date) {
        self.provider = provider
        self.accountID = accountID
        self.resetAt = resetAt
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case accountID
        case resetAt
    }
}

public struct ResetPrimerRunRecord: Codable, Equatable, Identifiable, Sendable {
    public let key: ResetPrimerRunKey
    public var accountName: String
    public var scheduledAt: Date
    public var status: ResetPrimerRunStatus
    public var updatedAt: Date
    public var errorMessage: String?

    public var id: String { key.stableID }

    public init(
        key: ResetPrimerRunKey,
        accountName: String,
        scheduledAt: Date,
        status: ResetPrimerRunStatus,
        updatedAt: Date,
        errorMessage: String? = nil
    ) {
        self.key = key
        self.accountName = accountName
        self.scheduledAt = scheduledAt
        self.status = status
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct ResetPrimerRunState: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var records: [ResetPrimerRunRecord]

    public init(records: [ResetPrimerRunRecord] = []) {
        schemaVersion = 1
        self.records = Self.normalized(records)
    }

    public static var empty: ResetPrimerRunState { ResetPrimerRunState() }

    public func record(for key: ResetPrimerRunKey) -> ResetPrimerRunRecord? {
        records.first { $0.key == key }
    }

    public mutating func upsert(_ record: ResetPrimerRunRecord) {
        records.removeAll { $0.key == record.key }
        records.append(record)
        records = Self.normalized(records)
    }

    private static func normalized(_ records: [ResetPrimerRunRecord]) -> [ResetPrimerRunRecord] {
        Dictionary(grouping: records, by: \.key)
            .compactMap { _, duplicateRecords in
                duplicateRecords.max { lhs, rhs in lhs.updatedAt < rhs.updatedAt }
            }
            .sorted { lhs, rhs in
                if lhs.key.resetAt != rhs.key.resetAt {
                    return lhs.key.resetAt < rhs.key.resetAt
                }
                if lhs.key.provider != rhs.key.provider {
                    return lhs.key.provider.displayName < rhs.key.provider.displayName
                }
                if lhs.accountName != rhs.accountName {
                    return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
                }
                return lhs.key.accountID < rhs.key.accountID
            }
    }
}

public struct ResetPrimerCandidate: Equatable, Identifiable, Sendable {
    public let key: ResetPrimerRunKey
    public let accountName: String
    public let windowLabel: String
    public let scheduledAt: Date
    public let sourceLimitIDs: [String]

    public var id: String { key.stableID }
    public var provider: Provider { key.provider }
    public var accountID: String { key.accountID }
    public var resetAt: Date { key.resetAt }

    public init(
        key: ResetPrimerRunKey,
        accountName: String,
        windowLabel: String,
        scheduledAt: Date,
        sourceLimitIDs: [String]
    ) {
        self.key = key
        self.accountName = accountName
        self.windowLabel = windowLabel
        self.scheduledAt = scheduledAt
        self.sourceLimitIDs = sourceLimitIDs.sorted()
    }

    public func isDue(now: Date) -> Bool {
        scheduledAt <= now
    }
}

public struct ResetPrimerPlan: Equatable, Sendable {
    public let due: [ResetPrimerCandidate]
    public let upcoming: [ResetPrimerCandidate]

    public init(due: [ResetPrimerCandidate], upcoming: [ResetPrimerCandidate]) {
        self.due = due
        self.upcoming = upcoming
    }

    public var candidates: [ResetPrimerCandidate] {
        (due + upcoming).sortedBySchedule
    }

    public var isEmpty: Bool {
        due.isEmpty && upcoming.isEmpty
    }
}

public enum ResetPrimerPlanner {
    public static func plan(
        settings: ResetPrimerSettings,
        snapshot: UsageSnapshot,
        state: ResetPrimerRunState = .empty,
        now: Date
    ) -> ResetPrimerPlan {
        guard settings.isEnabled else {
            return ResetPrimerPlan(due: [], upcoming: [])
        }

        let enabledPreferences = settings.accountPreferences.filter(\.isEnabled)
        guard !enabledPreferences.isEmpty else {
            return ResetPrimerPlan(due: [], upcoming: [])
        }

        let enabledAccounts = Set(enabledPreferences.map(\.id))
        let candidates = groupedLimits(snapshot.limits.filter { limit in
            guard enabledAccounts.contains(ResetPrimerAccountPreference.id(provider: limit.provider, accountID: limit.accountID)), limit.resetsAt != nil else { return false }
            guard settings.preference(for: limit.accountID, provider: limit.provider) != nil else { return false }
            return limit.status != .failure && limit.status != .unknown && limit.status != .stale
        })

        let scheduled = applySchedule(
            candidates: candidates,
            delayMinutesAfterReset: settings.delayMinutesAfterReset,
            accountStaggerMinutes: settings.accountStaggerMinutes
        )
        .filter { candidate in
            guard let record = state.record(for: candidate.key) else { return true }
            return record.status == .failed
        }
        .sortedBySchedule

        return ResetPrimerPlan(
            due: scheduled.filter { $0.isDue(now: now) },
            upcoming: scheduled.filter { !$0.isDue(now: now) }
        )
    }

    private static func groupedLimits(_ limits: [UsageLimit]) -> [UnscheduledResetPrimerCandidate] {
        let grouped = Dictionary(grouping: limits) { limit in
            ResetPrimerRunKey(
                provider: limit.provider,
                accountID: limit.accountID,
                resetAt: limit.resetsAt ?? Date.distantFuture
            )
        }

        return grouped.compactMap { key, limits in
            guard key.resetAt != Date.distantFuture, let first = limits.sortedByLimitID.first else { return nil }
            return UnscheduledResetPrimerCandidate(
                key: key,
                accountName: first.accountName,
                windowLabel: normalizedWindowLabel(for: first),
                sourceLimitIDs: limits.map(\.id)
            )
        }
    }

    private static func applySchedule(
        candidates: [UnscheduledResetPrimerCandidate],
        delayMinutesAfterReset: Int,
        accountStaggerMinutes: Int
    ) -> [ResetPrimerCandidate] {
        Dictionary(grouping: candidates, by: \.key.resetAt)
            .flatMap { resetAt, resetCandidates in
                let accountOrder = Dictionary(
                    uniqueKeysWithValues: Array(Set(resetCandidates.map(\.key.accountStaggerKey))).sorted().enumerated().map { index, accountKey in
                        (accountKey, index)
                    }
                )

                return resetCandidates.map { candidate in
                    let staggerIndex = accountOrder[candidate.key.accountStaggerKey] ?? 0
                    let scheduledAt = resetAt
                        .addingTimeInterval(TimeInterval(max(delayMinutesAfterReset, 0) * 60))
                        .addingTimeInterval(TimeInterval(max(accountStaggerMinutes, 0) * 60 * staggerIndex))
                    return ResetPrimerCandidate(
                        key: candidate.key,
                        accountName: candidate.accountName,
                        windowLabel: candidate.windowLabel,
                        scheduledAt: scheduledAt,
                        sourceLimitIDs: candidate.sourceLimitIDs
                    )
                }
            }
    }

    private static func normalizedWindowLabel(for limit: UsageLimit) -> String {
        let label = limit.windowLabel ?? limit.label
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? limit.label : trimmed
    }
}

public struct ResetPrimerRunStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: stateURL.path)
    }

    public func load() -> ResetPrimerRunState {
        loadIfAvailable() ?? .empty
    }

    public func loadIfAvailable() -> ResetPrimerRunState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        do {
            let state = try Self.makeDecoder().decode(
                ResetPrimerRunState.self,
                from: try Data(contentsOf: stateURL)
            )
            guard state.schemaVersion == 1 else {
                return nil
            }
            return state
        } catch {
            return nil
        }
    }

    public func save(_ state: ResetPrimerRunState) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct ResetPrimerPlanService: Sendable {
    private let settingsStore: ResetPrimerSettingsStore
    private let stateStore: ResetPrimerRunStateStore
    private let snapshotStore: JSONSnapshotStore

    public init(
        settingsStore: ResetPrimerSettingsStore,
        stateStore: ResetPrimerRunStateStore,
        snapshotStore: JSONSnapshotStore
    ) {
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.snapshotStore = snapshotStore
    }

    public static func appDefault(appGroupID: String = ContextPanelLocations.appGroupID) -> ResetPrimerPlanService {
        ResetPrimerPlanService(
            settingsStore: ResetPrimerSettingsStore(
                settingsURL: ContextPanelLocations.resetPrimerSettingsURL(appGroupID: appGroupID)
            ),
            stateStore: ResetPrimerRunStateStore(
                stateURL: ContextPanelLocations.resetPrimerRunStateURL(appGroupID: appGroupID)
            ),
            snapshotStore: JSONSnapshotStore(
                rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: appGroupID)
            )
        )
    }

    public func plan(now: Date = Date()) -> ResetPrimerPlan {
        guard let snapshot = snapshotStore.loadCurrent().snapshot?.snapshot else {
            return ResetPrimerPlan(due: [], upcoming: [])
        }

        return ResetPrimerPlanner.plan(
            settings: settingsStore.load(),
            snapshot: snapshot,
            state: stateStore.load(),
            now: now
        )
    }

    public func mark(
        _ candidate: ResetPrimerCandidate,
        status: ResetPrimerRunStatus,
        now: Date = Date(),
        errorMessage: String? = nil
    ) throws {
        var state = stateStore.load()
        state.upsert(ResetPrimerRunRecord(
            key: candidate.key,
            accountName: candidate.accountName,
            scheduledAt: candidate.scheduledAt,
            status: status,
            updatedAt: now,
            errorMessage: errorMessage
        ))
        try stateStore.save(state)
    }
}

public struct ResetPrimerExecutionResult: Equatable, Sendable {
    public let candidate: ResetPrimerCandidate
    public let status: ResetPrimerRunStatus
    public let errorMessage: String?

    public init(candidate: ResetPrimerCandidate, status: ResetPrimerRunStatus, errorMessage: String? = nil) {
        self.candidate = candidate
        self.status = status
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct ResetPrimerExecutor: Sendable {
    private let planService: ResetPrimerPlanService
    private let accountStore: AccountConfigurationStore
    private let processRunner: @Sendable (URL, [String], TimeInterval) async throws -> Int32

    public init(
        planService: ResetPrimerPlanService,
        accountStore: AccountConfigurationStore,
        processRunner: @escaping @Sendable (URL, [String], TimeInterval) async throws -> Int32 = ResetPrimerExecutor.defaultProcessRunner
    ) {
        self.planService = planService
        self.accountStore = accountStore
        self.processRunner = processRunner
    }

    public static func appDefault(appGroupID: String = ContextPanelLocations.appGroupID) -> ResetPrimerExecutor {
        ResetPrimerExecutor(
            planService: .appDefault(appGroupID: appGroupID),
            accountStore: AccountConfigurationStore(
                configurationURL: ContextPanelLocations.accountConfigurationURL(),
                fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
            )
        )
    }

    @discardableResult
    public func runDue(now: Date = Date()) async -> [ResetPrimerExecutionResult] {
        let candidates = planService.plan(now: now).due
        guard !candidates.isEmpty else { return [] }

        let accountsByID = Dictionary(
            accountStore.load(now: now).document.accounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var results: [ResetPrimerExecutionResult] = []
        for candidate in candidates {
            let action = primerAction(candidate: candidate, account: accountsByID[candidate.accountID])
            switch action {
            case let .skip(errorMessage):
                let result = ResetPrimerExecutionResult(candidate: candidate, status: .skipped, errorMessage: errorMessage)
                do {
                    try planService.mark(
                        candidate,
                        status: result.status,
                        now: now,
                        errorMessage: result.errorMessage
                    )
                    results.append(result)
                } catch {
                    results.append(stateSaveFailureResult(candidate: candidate, error: error))
                }

            case let .run(commandURL, arguments):
                do {
                    try planService.mark(
                        candidate,
                        status: .skipped,
                        now: now,
                        errorMessage: "Reset primer command started"
                    )
                } catch {
                    results.append(stateSaveFailureResult(candidate: candidate, error: error))
                    continue
                }

                let result = await runCommand(commandURL, arguments, candidate: candidate)
                do {
                    try planService.mark(
                        candidate,
                        status: result.status,
                        now: now,
                        errorMessage: result.errorMessage
                    )
                    results.append(result)
                } catch {
                    results.append(stateSaveFailureResult(candidate: candidate, error: error))
                }
            }
        }
        return results
    }

    private func stateSaveFailureResult(candidate: ResetPrimerCandidate, error: Error) -> ResetPrimerExecutionResult {
        ResetPrimerExecutionResult(
            candidate: candidate,
            status: .failed,
            errorMessage: "Reset primer state could not be saved: \(ConnectorRedactor.redact(error.localizedDescription))"
        )
    }

    private func primerAction(
        candidate: ResetPrimerCandidate,
        account: LocalProviderAccountConfiguration?
    ) -> PrimerAction {
        guard let account, account.isEnabled else {
            return .skip("Account is disabled or missing")
        }
        guard let commandURL = primerCommandURL(for: account) else {
            return .skip("No primer command is configured")
        }
        let arguments = primerArguments(for: account)
        guard !arguments.isEmpty else {
            return .skip("Reset priming is not supported for this provider")
        }

        return .run(commandURL, arguments)
    }

    private func runCommand(
        _ commandURL: URL,
        _ arguments: [String],
        candidate: ResetPrimerCandidate
    ) async -> ResetPrimerExecutionResult {
        do {
            let status = try await processRunner(commandURL, arguments, 60)
            if status == 0 {
                return ResetPrimerExecutionResult(candidate: candidate, status: .completed)
            }
            return ResetPrimerExecutionResult(
                candidate: candidate,
                status: .failed,
                errorMessage: "Primer command exited with status \(status)"
            )
        } catch {
            return ResetPrimerExecutionResult(
                candidate: candidate,
                status: .failed,
                errorMessage: error.localizedDescription
            )
        }
    }

    private enum PrimerAction {
        case skip(String)
        case run(URL, [String])
    }

    private func primerCommandURL(for account: LocalProviderAccountConfiguration) -> URL? {
        let path: String?
        switch account.connectorKind {
        case .codexRateLimits:
            path = account.commandPath ?? defaultCodeCommandPath()
        case .claudeLocalStatus, .claudeOAuthUsage, .geminiCodeAssist:
            path = account.commandPath
        }

        guard let path, !path.isEmpty else { return nil }
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.isExecutableFile(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded)
    }

    public static func primerArguments(for account: LocalProviderAccountConfiguration) -> [String] {
        switch account.connectorKind {
        case .codexRateLimits:
            return []
        case .claudeLocalStatus, .claudeOAuthUsage, .geminiCodeAssist:
            return []
        }
    }

    private func primerArguments(for account: LocalProviderAccountConfiguration) -> [String] {
        Self.primerArguments(for: account)
    }

    public static func defaultProcessRunner(commandURL: URL, arguments: [String], timeout: TimeInterval) async throws -> Int32 {
        let process = Process()
        process.executableURL = commandURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()

        let timeoutTask = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        timeoutTask.cancel()
        return process.terminationStatus
    }

    private func defaultCodeCommandPath() -> String? {
        let candidates = [
            "\(ContextPanelLocations.realUserHomeDirectory().path)/.local/bin/code",
            "/opt/homebrew/bin/code",
            "/usr/local/bin/code",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

private struct UnscheduledResetPrimerCandidate: Equatable {
    let key: ResetPrimerRunKey
    let accountName: String
    let windowLabel: String
    let sourceLimitIDs: [String]
}

private extension ResetPrimerRunKey {
    var stableID: String {
        let reset = ISO8601DateFormatter().string(from: resetAt)
        return "\(provider.rawValue):\(accountID):\(reset)"
    }

    var accountStaggerKey: String {
        "\(provider.rawValue):\(accountID)"
    }
}

private extension Array where Element == UsageLimit {
    var sortedByLimitID: [UsageLimit] {
        sorted { lhs, rhs in lhs.id < rhs.id }
    }
}

private extension Array where Element == ResetPrimerCandidate {
    var sortedBySchedule: [ResetPrimerCandidate] {
        sorted { lhs, rhs in
            if lhs.scheduledAt != rhs.scheduledAt {
                return lhs.scheduledAt < rhs.scheduledAt
            }
            if lhs.provider != rhs.provider {
                return lhs.provider.displayName < rhs.provider.displayName
            }
            if lhs.accountName != rhs.accountName {
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }
            if lhs.windowLabel != rhs.windowLabel {
                return lhs.windowLabel.localizedCaseInsensitiveCompare(rhs.windowLabel) == .orderedAscending
            }
            return lhs.accountID < rhs.accountID
        }
    }
}
