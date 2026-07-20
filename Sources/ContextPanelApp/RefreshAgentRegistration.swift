import AppKit
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
    }

    let kind: Kind

    var userFacingMessage: String {
        switch kind {
        case .requiresApproval:
            "Background refresh needs approval in System Settings."
        case .notFound:
            "Background refresh is unavailable because the helper is missing from this app."
        case .failed:
            "Background refresh could not be restored. Context Panel will retry when the app launches or background refresh is re-enabled."
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

    private let service: any RefreshAgentRegistrationService
    private let stateStore: RefreshAgentRegistrationStateStore
    private let policy: RefreshAgentRegistrationPolicy
    private let currentBuild: @MainActor () -> String
    private let isAgentRunning: @MainActor () -> Bool
    private let sleep: Sleep

    private var pendingRepairTask: Task<Void, Never>?
    private var pendingRepairToken: UUID?
    private var repairGeneration = 0
    private var isRestorativeUnregisterInFlight = false

    init(
        service: any RefreshAgentRegistrationService,
        stateStore: RefreshAgentRegistrationStateStore,
        policy: RefreshAgentRegistrationPolicy = .appDefault,
        currentBuild: @escaping @MainActor () -> String,
        isAgentRunning: @escaping @MainActor () -> Bool,
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.service = service
        self.stateStore = stateStore
        self.policy = policy
        self.currentBuild = currentBuild
        self.isAgentRunning = isAgentRunning
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
                guard service.status == .notRegistered else { throw error }
            }
        }
        stateStore.clearAll()
        refreshAgentRegistrationLogger.notice(
            "refresh agent registration disabled status=\(self.service.status.rawValue, privacy: .public)"
        )
    }

    func scheduleRepair(
        isEnabled: @escaping @MainActor () -> Bool,
        onDiagnosticChange: @escaping @MainActor (RefreshAgentRegistrationDiagnostic?) -> Void = { _ in }
    ) {
        repairGeneration &+= 1
        let generation = repairGeneration
        let predecessor = pendingRepairTask
        predecessor?.cancel()
        let launchGrace = predecessor == nil ? policy.launchGrace : .zero
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
        if stateStore.repairedBuild == build, initialStatus == .enabled {
            stateStore.clearDiagnostic()
            return .verifiedEnabled
        }
        if let terminalOutcome = terminalOutcome(for: initialStatus, build: build) {
            return terminalOutcome
        }

        if initialStatus == .enabled {
            if isAgentRunning() {
                stateStore.clearDiagnostic()
                if stateStore.reconciledBuild == build {
                    stateStore.markRepaired(build: build)
                }
                return .agentAlreadyRunning
            }

            isRestorativeUnregisterInFlight = true
            do {
                try await service.unregisterAndWait()
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
        } else if initialStatus == .notRegistered {
            stateStore.clearMarkers()
        }

        return await restoreRegistration(build: build, isEnabled: isEnabled)
    }

    private func reconcileEnabledRegistration() throws {
        let build = currentBuild()
        let initialStatus = service.status
        if let terminalOutcome = terminalOutcome(for: initialStatus, build: build) {
            throw RefreshAgentRegistrationError.statusNotEnabled(status(for: terminalOutcome))
        }

        if initialStatus == .enabled {
            guard stateStore.reconciledBuild != build else {
                stateStore.clearDiagnostic()
                return
            }
            do {
                try service.register()
                guard service.status == .enabled else {
                    throw RefreshAgentRegistrationError.statusNotEnabled(service.status)
                }
                stateStore.markReconciled(build: build)
                stateStore.clearDiagnostic()
            } catch {
                refreshAgentRegistrationLogger.error(
                    "refresh agent non-destructive registration refresh failed error=\(ConnectorRedactor.safeErrorDescription(error), privacy: .private)"
                )
            }
        } else {
            stateStore.clearMarkers()
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
            stateStore.clearDiagnostic()
        }

        refreshAgentRegistrationLogger.notice(
            "refresh agent registration status=\(self.service.status.rawValue, privacy: .public) build=\(build, privacy: .public)"
        )
    }

    private func restoreRegistration(
        build: String,
        isEnabled: @escaping @MainActor () -> Bool
    ) async -> RefreshAgentRegistrationOutcome {
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
                    return finishSuccessfulRepair(build: build, attempts: attemptIndex, isEnabled: isEnabled)
                }
                if let terminalOutcome = terminalOutcome(for: service.status, build: build) {
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
                return finishSuccessfulRepair(build: build, attempts: attempts, isEnabled: isEnabled)
            }
            if let terminalOutcome = terminalOutcome(for: service.status, build: build) {
                return terminalOutcome
            }
        }

        saveDiagnostic(.failed, build: build)
        return .failed(attempts: attemptCount)
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

        stateStore.markReconciled(build: build)
        stateStore.markRepaired(build: build)
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
        isAgentRunning: isRefreshAgentRunning
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

    private static func isRefreshAgentRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: ContextPanelLocations.refreshAgentBundleID).isEmpty
    }
}
