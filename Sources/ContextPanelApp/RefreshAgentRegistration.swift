import ContextPanelCore
import Foundation
import os
import ServiceManagement

private let refreshAgentRegistrationLogger = Logger(
    subsystem: "com.shinycomputers.contextpanel",
    category: "refresh-agent-registration"
)

extension Notification.Name {
    static let contextPanelRefreshAgentRegistrationDiagnosticDidChange = Notification.Name(
        "ContextPanelRefreshAgentRegistrationDiagnosticDidChange"
    )
}

enum RefreshAgentRegistrationStatus: String, Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown

    init(_ status: SMAppService.Status) {
        self = switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
}

struct RefreshAgentRegistrationDiagnostic: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case requiresApproval
        case notFound
        case failed
        case notUpdating
    }

    let kind: Kind

    var userFacingMessage: String {
        switch kind {
        case .requiresApproval:
            "Background refresh needs approval in System Settings."
        case .notFound:
            "Background refresh could not register its helper. Update or reinstall Context Panel, then use Repair background updates. Use Refresh now in the meantime."
        case .failed:
            "Background refresh could not be restored. Use Refresh now while Context Panel retries."
        case .notUpdating:
            "Background refresh is not updating. Use Refresh now while Context Panel retries."
        }
    }
}

enum RefreshAgentRegistrationOutcome: Equatable, Sendable {
    case disabled
    case verifiedEnabled
    case agentAlreadyRunning
    case repaired(attempts: Int)
    case stoppedDisabled
    case requiresApproval
    case notFound
    case failed(attempts: Int)
    case cancelled
}

struct RefreshAgentRegistrationPolicy: Equatable, Sendable {
    let launchGrace: Duration
    let retryDelays: [Duration]
    let verificationDelay: Duration
    /// Waits between attempts to find the helper between refreshes before replacing it.
    var refreshIdleRetryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(15)]

    static let appDefault = RefreshAgentRegistrationPolicy(
        launchGrace: .seconds(8),
        retryDelays: [.milliseconds(250), .seconds(1), .seconds(3)],
        verificationDelay: .milliseconds(250)
    )
}

@MainActor
protocol RefreshAgentRegistrationService: AnyObject {
    var status: RefreshAgentRegistrationStatus { get }

    func register() throws
    func unregisterImmediately() throws
    func unregisterAndWait() async throws
}

@MainActor
final class SystemRefreshAgentRegistrationService: RefreshAgentRegistrationService {
    private let service: SMAppService

    init(identifier: String) {
        service = .loginItem(identifier: identifier)
    }

    var status: RefreshAgentRegistrationStatus {
        RefreshAgentRegistrationStatus(service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregisterImmediately() throws {
        try service.unregister()
    }

    func unregisterAndWait() async throws {
        try await service.unregister()
    }
}

@MainActor
final class RefreshAgentRegistrationStateStore {
    private static let reconciledBuildKey = "ContextPanelRefreshAgentReconciledBuild"
    private static let repairedBuildKey = "ContextPanelRefreshAgentRepairedBuild"
    private static let diagnosticBuildKey = "ContextPanelRefreshAgentDiagnosticBuild"
    private static let diagnosticKindKey = "ContextPanelRefreshAgentDiagnosticKind"
    private static let staleAgentReplacementBuildKey = "ContextPanelRefreshAgentStaleReplacementBuild"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var reconciledBuild: String? {
        defaults.string(forKey: Self.reconciledBuildKey)
    }

    var repairedBuild: String? {
        defaults.string(forKey: Self.repairedBuildKey)
    }

    func markReconciled(build: String) {
        defaults.set(build, forKey: Self.reconciledBuildKey)
    }

    func markRepaired(build: String) {
        defaults.set(build, forKey: Self.repairedBuildKey)
    }

    /// Replacing a helper left running by an earlier build happens at most once per build.
    var staleAgentReplacementBuild: String? {
        defaults.string(forKey: Self.staleAgentReplacementBuildKey)
    }

    func markStaleAgentReplacement(build: String) {
        defaults.set(build, forKey: Self.staleAgentReplacementBuildKey)
    }

    func clearMarkers() {
        defaults.removeObject(forKey: Self.reconciledBuildKey)
        defaults.removeObject(forKey: Self.repairedBuildKey)
    }

    func diagnostic(for build: String) -> RefreshAgentRegistrationDiagnostic? {
        guard defaults.string(forKey: Self.diagnosticBuildKey) == build,
              let rawKind = defaults.string(forKey: Self.diagnosticKindKey),
              let kind = RefreshAgentRegistrationDiagnostic.Kind(rawValue: rawKind)
        else {
            return nil
        }
        return RefreshAgentRegistrationDiagnostic(kind: kind)
    }

    func saveDiagnostic(kind: RefreshAgentRegistrationDiagnostic.Kind, build: String) {
        defaults.set(build, forKey: Self.diagnosticBuildKey)
        defaults.set(kind.rawValue, forKey: Self.diagnosticKindKey)
    }

    func clearDiagnostic() {
        defaults.removeObject(forKey: Self.diagnosticBuildKey)
        defaults.removeObject(forKey: Self.diagnosticKindKey)
    }

    func clearAll() {
        clearMarkers()
        clearDiagnostic()
        defaults.removeObject(forKey: Self.staleAgentReplacementBuildKey)
    }
}

enum RefreshAgentRegistrationError: LocalizedError {
    case statusNotEnabled(RefreshAgentRegistrationStatus)

    var errorDescription: String? {
        switch self {
        case let .statusNotEnabled(status):
            "Background refresh registration did not become enabled (status: \(status.rawValue))."
        }
    }
}

@MainActor
final class RefreshAgentRegistrationCoordinator {
    typealias Sleep = @MainActor (Duration) async throws -> Void
    /// Runs the operation while no refresh can write the shared snapshot, or
    /// returns false without running it when a refresh is in progress.
    typealias WhileRefreshIdle = @MainActor (@MainActor () async throws -> Void) async throws -> Bool
    static let automaticRepairCooldown: TimeInterval = 300

    private let service: any RefreshAgentRegistrationService
    private let stateStore: RefreshAgentRegistrationStateStore
    private let policy: RefreshAgentRegistrationPolicy
    private let currentBuild: @MainActor () -> String
    private let isAgentHealthy: @MainActor () -> Bool
    private let currentAgentRunID: @MainActor () -> String?
    private let isAgentFromDifferentBuild: @MainActor () -> Bool
    private let whileRefreshIdle: WhileRefreshIdle
    private let now: @MainActor () -> Date
    private let awakeTime: @MainActor () -> Duration
    private let sleep: Sleep

    private var pendingRepairTask: Task<Void, Never>?
    private var pendingRepairToken: UUID?
    private var repairGeneration = 0
    private var isRestorativeUnregisterInFlight = false
    private var agentRunBeforeRegistration: String?
    private var requiresNewAgentRun = false
    private var nextAutomaticRepairAt = Date.distantPast
    private var lastHealthCheckTime: Date
    private var lastHealthCheckAwakeTime: Duration

    init(
        service: any RefreshAgentRegistrationService,
        stateStore: RefreshAgentRegistrationStateStore,
        policy: RefreshAgentRegistrationPolicy = .appDefault,
        currentBuild: @escaping @MainActor () -> String,
        isAgentHealthy: @escaping @MainActor () -> Bool,
        currentAgentRunID: @escaping @MainActor () -> String? = { nil },
        isAgentFromDifferentBuild: @escaping @MainActor () -> Bool = { false },
        whileRefreshIdle: WhileRefreshIdle? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        awakeTime: (@MainActor () -> Duration)? = nil,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.service = service
        self.stateStore = stateStore
        self.policy = policy
        self.currentBuild = currentBuild
        self.isAgentHealthy = isAgentHealthy
        self.currentAgentRunID = currentAgentRunID
        self.isAgentFromDifferentBuild = isAgentFromDifferentBuild
        self.whileRefreshIdle = whileRefreshIdle ?? { operation in
            try await operation()
            return true
        }
        self.now = now
        let clock = SuspendingClock()
        let start = clock.now
        let resolvedAwakeTime = awakeTime ?? { start.duration(to: clock.now) }
        self.awakeTime = resolvedAwakeTime
        lastHealthCheckTime = now()
        lastHealthCheckAwakeTime = resolvedAwakeTime()
        self.sleep = sleep
    }

    func reconcile(settings: BackgroundRefreshSettings) throws {
        if settings.isEnabled {
            guard !isRestorativeUnregisterInFlight else { return }
            try reconcileEnabledRegistration()
            return
        }

        cancelPendingRepair()
        if isRestorativeUnregisterInFlight {
            stateStore.clearAll()
            refreshAgentRegistrationLogger.notice(
                "refresh agent registration disable waiting for restorative unregister"
            )
            return
        }
        if service.status != .notRegistered {
            do {
                try service.unregisterImmediately()
            } catch {
                guard service.status == .notRegistered || service.status == .notFound else { throw error }
            }
        }
        stateStore.clearAll()
        refreshAgentRegistrationLogger.notice(
            "refresh agent registration disabled status=\(self.service.status.rawValue, privacy: .public)"
        )
    }

    func scheduleRepair(
        isEnabled: @escaping @MainActor () -> Bool,
        launchGrace: Duration? = nil,
        onDiagnosticChange: @escaping @MainActor (RefreshAgentRegistrationDiagnostic?) -> Void = { _ in }
    ) {
        repairGeneration &+= 1
        let generation = repairGeneration
        let predecessor = pendingRepairTask
        predecessor?.cancel()
        let launchGrace = launchGrace ?? (predecessor == nil ? policy.launchGrace : .zero)
        let taskToken = UUID()

        let task = Task { @MainActor [weak self] in
            if let predecessor {
                await predecessor.value
            }
            guard let self else { return }
            guard self.repairGeneration == generation else {
                self.clearPendingRepair(ifCurrent: taskToken)
                return
            }
            _ = await self.repairIfNeeded(isEnabled: isEnabled, launchGrace: launchGrace)
            guard self.repairGeneration == generation else {
                self.clearPendingRepair(ifCurrent: taskToken)
                return
            }
            self.clearPendingRepair(ifCurrent: taskToken)
            onDiagnosticChange(self.currentDiagnostic)
        }
        pendingRepairTask = task
        pendingRepairToken = taskToken
    }

    /// A health check must not cancel a repair already waiting for ServiceManagement.
    func scheduleHealthCheck(
        isEnabled: @escaping @MainActor () -> Bool,
        wakeRecoveryInterval: TimeInterval = automaticRepairCooldown,
        onDiagnosticChange: @escaping @MainActor (RefreshAgentRegistrationDiagnostic?) -> Void = { _ in }
    ) {
        let checkedAt = now()
        let checkedAwakeTime = awakeTime()
        let wallElapsed = Duration.seconds(checkedAt.timeIntervalSince(lastHealthCheckTime))
        let awakeElapsed = checkedAwakeTime - lastHealthCheckAwakeTime
        lastHealthCheckTime = checkedAt
        lastHealthCheckAwakeTime = checkedAwakeTime
        if wallElapsed > awakeElapsed + .seconds(RefreshAgentHealth.schedulingAllowance) {
            nextAutomaticRepairAt = checkedAt.addingTimeInterval(wakeRecoveryInterval + RefreshAgentHealth.schedulingAllowance)
        }
        guard pendingRepairTask == nil else { return }
        if !isEnabled() {
            onDiagnosticChange(nil)
            return
        }
        if !hasVerifiedAgentActivity(), checkedAt < nextAutomaticRepairAt {
            onDiagnosticChange(currentDiagnostic)
            return
        }
        scheduleRepair(isEnabled: isEnabled, launchGrace: .zero, onDiagnosticChange: onDiagnosticChange)
    }

    private func hasVerifiedAgentActivity() -> Bool {
        guard isAgentHealthy() else { return false }
        guard requiresNewAgentRun else { return true }
        guard let runID = currentAgentRunID() else { return false }
        return runID != agentRunBeforeRegistration
    }

    private func expectNewAgentRun() {
        agentRunBeforeRegistration = currentAgentRunID()
        requiresNewAgentRun = true
    }

    func cancelPendingRepair() {
        repairGeneration &+= 1
        pendingRepairTask?.cancel()
    }

    var currentDiagnostic: RefreshAgentRegistrationDiagnostic? {
        stateStore.diagnostic(for: currentBuild())
    }

    func clearPersistedState() {
        stateStore.clearAll()
    }

    private func clearPendingRepair(ifCurrent taskToken: UUID) {
        guard pendingRepairToken == taskToken else { return }
        pendingRepairTask = nil
        pendingRepairToken = nil
    }

    func repairIfNeeded(
        isEnabled: @escaping @MainActor () -> Bool,
        launchGrace: Duration? = nil
    ) async -> RefreshAgentRegistrationOutcome {
        let effectiveLaunchGrace = launchGrace ?? policy.launchGrace
        do {
            try await sleep(effectiveLaunchGrace)
        } catch {
            return .cancelled
        }

        guard !Task.isCancelled else { return .cancelled }
        guard isEnabled() else { return .disabled }

        let build = currentBuild()
        let initialStatus = service.status
        let replacesStaleAgent = initialStatus == .enabled
            && hasVerifiedAgentActivity()
            && isAgentFromDifferentBuild()
            && stateStore.staleAgentReplacementBuild != build
        if !replacesStaleAgent, stateStore.repairedBuild == build, initialStatus == .enabled, hasVerifiedAgentActivity() {
            nextAutomaticRepairAt = .distantPast
            stateStore.clearDiagnostic()
            return .verifiedEnabled
        }
        // A lookup failure before registration does not establish that the bundled helper is missing.
        if initialStatus != .notFound, let terminalOutcome = terminalOutcome(for: initialStatus, build: build) {
            return terminalOutcome
        }

        if initialStatus == .enabled {
            if !replacesStaleAgent, hasVerifiedAgentActivity() {
                nextAutomaticRepairAt = .distantPast
                stateStore.clearDiagnostic()
                if stateStore.reconciledBuild == build {
                    stateStore.markRepaired(build: build)
                }
                return .agentAlreadyRunning
            }

            nextAutomaticRepairAt = now().addingTimeInterval(Self.automaticRepairCooldown)
            isRestorativeUnregisterInFlight = true
            do {
                if replacesStaleAgent {
                    guard try await unregisterBetweenRefreshes(build: build, isEnabled: isEnabled) else {
                        isRestorativeUnregisterInFlight = false
                        guard isEnabled() else { return stopDisabled() }
                        guard !Task.isCancelled else { return .cancelled }
                        // Leave the working helper for now; the next app launch tries again.
                        refreshAgentRegistrationLogger.notice(
                            "refresh agent replacement deferred because a refresh stayed in progress build=\(build, privacy: .public)"
                        )
                        return .agentAlreadyRunning
                    }
                } else {
                    expectNewAgentRun()
                    try await service.unregisterAndWait()
                }
            } catch {
                isRestorativeUnregisterInFlight = false
                guard isEnabled() else { return stopDisabledEnsuringUnregistered() }
                guard !Task.isCancelled else { return .cancelled }
                guard service.status == .notRegistered else {
                    saveDiagnostic(.failed, build: build)
                    refreshAgentRegistrationLogger.error(
                        "refresh agent unregister repair failed error=\(ConnectorRedactor.safeErrorDescription(error), privacy: .private)"
                    )
                    return .failed(attempts: 0)
                }
            }
            isRestorativeUnregisterInFlight = false
            stateStore.clearMarkers()
            guard isEnabled() else { return stopDisabled() }
            guard !Task.isCancelled else { return .cancelled }
        } else if initialStatus == .notRegistered || initialStatus == .notFound {
            stateStore.clearMarkers()
        }

        return await restoreRegistration(build: build, isEnabled: isEnabled)
    }

    /// Stops the helper only while the refresh lock is held, so it is never
    /// stopped in the middle of writing the shared snapshot.
    private func unregisterBetweenRefreshes(
        build: String,
        isEnabled: @MainActor () -> Bool
    ) async throws -> Bool {
        for attemptIndex in 0...policy.refreshIdleRetryDelays.count {
            if attemptIndex > 0 {
                try await sleep(policy.refreshIdleRetryDelays[attemptIndex - 1])
            }
            guard isEnabled(), !Task.isCancelled else { return false }
            let unregistered = try await whileRefreshIdle { [self] in
                // Mark before stopping so a helper that keeps reporting another
                // build cannot cause repeated restarts.
                stateStore.markStaleAgentReplacement(build: build)
                refreshAgentRegistrationLogger.notice(
                    "refresh agent is running an earlier build; replacing it build=\(build, privacy: .public)"
                )
                expectNewAgentRun()
                try await service.unregisterAndWait()
            }
            if unregistered { return true }
        }
        return false
    }

    private func reconcileEnabledRegistration() throws {
        let build = currentBuild()
        let initialStatus = service.status
        if initialStatus != .notFound, let terminalOutcome = terminalOutcome(for: initialStatus, build: build) {
            throw RefreshAgentRegistrationError.statusNotEnabled(status(for: terminalOutcome))
        }

        if initialStatus == .enabled {
            guard stateStore.reconciledBuild != build else {
                if hasVerifiedAgentActivity() { stateStore.clearDiagnostic() }
                return
            }
            do {
                try service.register()
                guard service.status == .enabled else {
                    throw RefreshAgentRegistrationError.statusNotEnabled(service.status)
                }
                stateStore.markReconciled(build: build)
                if hasVerifiedAgentActivity() { stateStore.clearDiagnostic() }
            } catch {
                refreshAgentRegistrationLogger.error(
                    "refresh agent non-destructive registration refresh failed error=\(ConnectorRedactor.safeErrorDescription(error), privacy: .private)"
                )
            }
        } else {
            stateStore.clearMarkers()
            expectNewAgentRun()
            do {
                try service.register()
            } catch {
                guard service.status == .enabled else {
                    saveDiagnostic(kind(for: service.status), build: build)
                    throw error
                }
            }
            guard service.status == .enabled else {
                saveDiagnostic(kind(for: service.status), build: build)
                throw RefreshAgentRegistrationError.statusNotEnabled(service.status)
            }
            stateStore.markReconciled(build: build)
            if hasVerifiedAgentActivity() { stateStore.clearDiagnostic() }
        }

        refreshAgentRegistrationLogger.notice(
            "refresh agent registration status=\(self.service.status.rawValue, privacy: .public) build=\(build, privacy: .public)"
        )
    }

    private func restoreRegistration(
        build: String,
        isEnabled: @escaping @MainActor () -> Bool
    ) async -> RefreshAgentRegistrationOutcome {
        if !requiresNewAgentRun { expectNewAgentRun() }
        nextAutomaticRepairAt = now().addingTimeInterval(Self.automaticRepairCooldown)
        let attemptCount = policy.retryDelays.count + 1
        var elapsedSincePreviousAttempt = Duration.zero

        for attemptIndex in 0..<attemptCount {
            if attemptIndex > 0 {
                guard !Task.isCancelled else { return .cancelled }
                guard isEnabled() else { return stopDisabled() }
                let retryDelay = policy.retryDelays[attemptIndex - 1]
                let remainingDelay = retryDelay > elapsedSincePreviousAttempt
                    ? retryDelay - elapsedSincePreviousAttempt
                    : .zero
                if remainingDelay > .zero {
                    do {
                        try await sleep(remainingDelay)
                    } catch {
                        return .cancelled
                    }
                }
                guard !Task.isCancelled else { return .cancelled }
                guard isEnabled() else { return stopDisabled() }
                if service.status == .enabled {
                    return await verifyAgentLaunch(build: build, attempts: attemptIndex, isEnabled: isEnabled)
                }
                if service.status != .notFound, let terminalOutcome = terminalOutcome(for: service.status, build: build) {
                    return terminalOutcome
                }
            }

            guard !Task.isCancelled else { return .cancelled }
            guard isEnabled() else { return stopDisabled() }
            let attempts = attemptIndex + 1
            elapsedSincePreviousAttempt = .zero
            do {
                try service.register()
                if policy.verificationDelay > .zero {
                    try await sleep(policy.verificationDelay)
                    elapsedSincePreviousAttempt = policy.verificationDelay
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                refreshAgentRegistrationLogger.error(
                    "refresh agent registration repair attempt failed attempt=\(attempts, privacy: .public) error=\(ConnectorRedactor.safeErrorDescription(error), privacy: .private)"
                )
            }

            guard !Task.isCancelled else { return .cancelled }
            guard isEnabled() else { return stopDisabled() }
            if service.status == .enabled {
                return await verifyAgentLaunch(build: build, attempts: attempts, isEnabled: isEnabled)
            }
            if service.status != .notFound, let terminalOutcome = terminalOutcome(for: service.status, build: build) {
                return terminalOutcome
            }
        }

        if let terminalOutcome = terminalOutcome(for: service.status, build: build) {
            return terminalOutcome
        }
        saveDiagnostic(.failed, build: build)
        return .failed(attempts: attemptCount)
    }

    private func verifyAgentLaunch(
        build: String,
        attempts: Int,
        isEnabled: @MainActor () -> Bool
    ) async -> RefreshAgentRegistrationOutcome {
        if !hasVerifiedAgentActivity(), policy.launchGrace > .zero {
            do { try await sleep(policy.launchGrace) }
            catch { return .cancelled }
        }
        return finishSuccessfulRepair(build: build, attempts: attempts, isEnabled: isEnabled)
    }

    private func finishSuccessfulRepair(
        build: String,
        attempts: Int,
        isEnabled: @MainActor () -> Bool
    ) -> RefreshAgentRegistrationOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard isEnabled() else { return stopDisabled() }
        guard service.status == .enabled else {
            saveDiagnostic(.failed, build: build)
            return .failed(attempts: attempts)
        }
        guard hasVerifiedAgentActivity() else {
            stateStore.clearMarkers()
            saveDiagnostic(.notUpdating, build: build)
            refreshAgentRegistrationLogger.error("refresh agent is enabled but did not start")
            return .failed(attempts: attempts)
        }

        stateStore.markReconciled(build: build)
        stateStore.markRepaired(build: build)
        requiresNewAgentRun = false
        nextAutomaticRepairAt = .distantPast
        stateStore.clearDiagnostic()
        refreshAgentRegistrationLogger.notice(
            "refresh agent registration repair succeeded attempts=\(attempts, privacy: .public) build=\(build, privacy: .public)"
        )
        return .repaired(attempts: attempts)
    }

    private func terminalOutcome(
        for status: RefreshAgentRegistrationStatus,
        build: String
    ) -> RefreshAgentRegistrationOutcome? {
        switch status {
        case .requiresApproval:
            stateStore.clearMarkers()
            saveDiagnostic(.requiresApproval, build: build)
            return .requiresApproval
        case .notFound:
            stateStore.clearMarkers()
            saveDiagnostic(.notFound, build: build)
            return .notFound
        case .notRegistered, .enabled, .unknown:
            return nil
        }
    }

    private func stopDisabled() -> RefreshAgentRegistrationOutcome {
        requiresNewAgentRun = false
        nextAutomaticRepairAt = .distantPast
        stateStore.clearAll()
        return .stoppedDisabled
    }

    private func stopDisabledEnsuringUnregistered() -> RefreshAgentRegistrationOutcome {
        if service.status != .notRegistered {
            do {
                try service.unregisterImmediately()
            } catch {
                refreshAgentRegistrationLogger.error(
                    "refresh agent disable cleanup failed error=\(ConnectorRedactor.safeErrorDescription(error), privacy: .private)"
                )
            }
        }
        return stopDisabled()
    }

    private func saveDiagnostic(
        _ kind: RefreshAgentRegistrationDiagnostic.Kind,
        build: String
    ) {
        stateStore.saveDiagnostic(kind: kind, build: build)
    }

    private func kind(
        for status: RefreshAgentRegistrationStatus
    ) -> RefreshAgentRegistrationDiagnostic.Kind {
        switch status {
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered, .enabled, .unknown: .failed
        }
    }

    private func status(
        for outcome: RefreshAgentRegistrationOutcome
    ) -> RefreshAgentRegistrationStatus {
        switch outcome {
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .disabled, .verifiedEnabled, .agentAlreadyRunning, .repaired, .stoppedDisabled, .failed, .cancelled:
            .unknown
        }
    }
}

@MainActor
enum RefreshAgentRegistration {
    private static let stateStore = RefreshAgentRegistrationStateStore()
    private static let coordinator = RefreshAgentRegistrationCoordinator(
        service: SystemRefreshAgentRegistrationService(identifier: ContextPanelLocations.refreshAgentBundleID),
        stateStore: stateStore,
        currentBuild: currentBuild,
        isAgentHealthy: isRefreshAgentHealthy,
        currentAgentRunID: { RefreshAgentHealth.latestRun(state: agentDiagnosticsState()).map(\.id) },
        isAgentFromDifferentBuild: isAgentFromDifferentBuild,
        whileRefreshIdle: whileRefreshIdle
    )

    static func reconcile(settings: BackgroundRefreshSettings) throws {
        defer { publishDiagnosticChange() }
        try coordinator.reconcile(settings: settings)
    }

    static func repairIfEnabledAgentDoesNotLaunch(
        settingsStore: BackgroundRefreshSettingsStore,
        onDiagnosticChange: @escaping @MainActor (RefreshAgentRegistrationDiagnostic?) -> Void = { _ in }
    ) {
        coordinator.scheduleRepair(
            isEnabled: { settingsStore.load().isEnabled },
            onDiagnosticChange: { diagnostic in
                publishDiagnosticChange()
                onDiagnosticChange(diagnostic)
            }
        )
    }

    static func cancelPendingRepair() {
        coordinator.cancelPendingRepair()
    }

    static func checkHealth(
        settingsStore: BackgroundRefreshSettingsStore,
        onDiagnosticChange: @escaping @MainActor (RefreshAgentRegistrationDiagnostic?) -> Void = { _ in }
    ) {
        coordinator.scheduleHealthCheck(
            isEnabled: { settingsStore.load().isEnabled },
            wakeRecoveryInterval: TimeInterval(settingsStore.load().intervalSeconds),
            onDiagnosticChange: { diagnostic in
                publishDiagnosticChange()
                onDiagnosticChange(diagnostic)
            }
        )
    }

    static var currentDiagnostic: RefreshAgentRegistrationDiagnostic? {
        coordinator.currentDiagnostic
    }

    static func clearPersistedState() {
        coordinator.clearPersistedState()
        publishDiagnosticChange()
    }

    private static func publishDiagnosticChange() {
        NotificationCenter.default.post(
            name: .contextPanelRefreshAgentRegistrationDiagnosticDidChange,
            object: nil
        )
    }

    private static func currentBuild() -> String {
        if let fingerprintURL = Bundle.main.url(
            forResource: "ContextPanelBuildFingerprint",
            withExtension: "txt"
        ),
           let fingerprint = try? String(contentsOf: fingerprintURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fingerprint.isEmpty {
            return fingerprint
        }

        return Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "unknown"
    }

    private static func isAgentFromDifferentBuild() -> Bool {
        RefreshAgentHealth.latestRunIsFromDifferentBuild(
            state: agentDiagnosticsState(),
            appBundleVersion: Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        )
    }

    private static func whileRefreshIdle(_ operation: @MainActor () async throws -> Void) async throws -> Bool {
        guard let hold = try SnapshotRefreshLock.appDefault().tryHold() else { return false }
        defer { hold.release() }
        try await operation()
        return true
    }

    private static func isRefreshAgentHealthy() -> Bool {
        let settings = BackgroundRefreshSettingsStore(
            settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        ).load()
        return RefreshAgentHealth.hasRecentWake(state: agentDiagnosticsState(), intervalSeconds: settings.intervalSeconds, now: Date())
    }

    private static func agentDiagnosticsState() -> RefreshDiagnosticsState {
        RefreshDiagnosticsStateStore(
            stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
        ).load()
    }
}
