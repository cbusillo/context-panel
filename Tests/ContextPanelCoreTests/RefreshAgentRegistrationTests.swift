import Foundation
import Testing

@testable import ContextPanelApp
@testable import ContextPanelCore

private enum RefreshAgentRegistrationTestError: Error {
    case failed
}

@MainActor
private final class ScriptedRefreshAgentRegistrationService: RefreshAgentRegistrationService {
    enum RegistrationStep {
        case fail
        case succeed(RefreshAgentRegistrationStatus)
    }

    var status: RefreshAgentRegistrationStatus
    var registrationSteps: [RegistrationStep]
    var statusAfterUnregister: RefreshAgentRegistrationStatus = .notRegistered
    var unregisterError: Error?
    var suspendsUnregister = false
    var isUserEnabled = true
    var latestRunID: String?
    var isRunning = false {
        didSet {
            if isRunning, !oldValue { latestRunID = UUID().uuidString }
        }
    }
    var startsAgentOnRegister = true
    var onRegister: (() -> Void)?
    var onUnregister: (() -> Void)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private var unregisterContinuation: CheckedContinuation<Void, any Error>?

    init(
        status: RefreshAgentRegistrationStatus,
        registrationSteps: [RegistrationStep] = []
    ) {
        self.status = status
        self.registrationSteps = registrationSteps
    }

    func register() throws {
        registerCount += 1
        onRegister?()
        let step = registrationSteps.isEmpty ? .fail : registrationSteps.removeFirst()
        switch step {
        case .fail:
            throw RefreshAgentRegistrationTestError.failed
        case let .succeed(status):
            self.status = status
            if status == .enabled, startsAgentOnRegister {
                isRunning = true
            }
        }
    }

    func unregisterImmediately() throws {
        try performUnregister()
    }

    func unregisterAndWait() async throws {
        guard suspendsUnregister else {
            try performUnregister()
            return
        }

        unregisterCount += 1
        onUnregister?()
        try await withCheckedThrowingContinuation { continuation in
            unregisterContinuation = continuation
        }
        try finishUnregister()
    }

    func resumeUnregister() {
        unregisterContinuation?.resume()
        unregisterContinuation = nil
    }

    private func finishUnregister() throws {
        if let unregisterError {
            throw unregisterError
        }
        status = statusAfterUnregister
        isRunning = false
    }

    private func performUnregister() throws {
        unregisterCount += 1
        onUnregister?()
        try finishUnregister()
    }

}

@MainActor
private final class ScriptedRefreshAgentRegistrationSleep {
    private(set) var durations: [Duration] = []
    var suspendsNextCall = false
    private var continuation: CheckedContinuation<Void, any Error>?

    var isSuspended: Bool {
        continuation != nil
    }

    func sleep(for duration: Duration) async throws {
        durations.append(duration)
        guard suspendsNextCall else { return }
        suspendsNextCall = false
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancelSuspendedSleep() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }

    func resumeSuspendedSleep() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func makeRegistrationStateStore() -> RefreshAgentRegistrationStateStore {
    RefreshAgentRegistrationStateStore(defaults: InMemoryUserDefaults())
}

private let immediateRepairPolicy = RefreshAgentRegistrationPolicy(
    launchGrace: .zero,
    retryDelays: [.zero, .zero, .zero],
    verificationDelay: .zero
)

@MainActor
@Test func refreshAgentRepairRestoresAfterTransientRegistrationFailures() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled,
        registrationSteps: [.fail, .fail, .succeed(.enabled)]
    )
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 3))
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 3)
    #expect(stateStore.reconciledBuild == "build-1")
    #expect(stateStore.repairedBuild == "build-1")
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test func refreshAgentRepairExhaustionLeavesMarkersUnsetAndVisible() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled,
        registrationSteps: [.fail, .fail, .fail, .fail]
    )
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .failed(attempts: 4))
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 4)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic?.kind == .failed)
}

@MainActor
@Test func refreshAgentRepairStopsWhenDisabledAfterUnregister() async {
    var isEnabled = true
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    service.onUnregister = { isEnabled = false }
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { isEnabled })

    #expect(outcome == .stoppedDisabled)
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 0)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
}

@MainActor
@Test func refreshAgentRepairDoesNotMarkSuccessfulCallsUntilStatusIsEnabled() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [
            .succeed(.notRegistered),
            .succeed(.notRegistered),
            .succeed(.notRegistered),
            .succeed(.notRegistered),
        ]
    )
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .failed(attempts: 4))
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
}

@MainActor
@Test func refreshAgentRepairTreatsApprovalAsTerminal() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .requiresApproval)
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .requiresApproval)
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic?.kind == .requiresApproval)
}

@MainActor
@Test(arguments: [RefreshAgentRegistrationStatus.notRegistered, .notFound])
func refreshAgentFreshInstallRegistersBeforeDiagnosingMissingHelper(initialStatus: RefreshAgentRegistrationStatus) throws {
    let service = ScriptedRefreshAgentRegistrationService(
        status: initialStatus, registrationSteps: [.succeed(.enabled)]
    )
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning },
        currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )

    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(service.isRunning)
    #expect(stateStore.reconciledBuild == "build-1")
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test(arguments: [RefreshAgentRegistrationStatus.notRegistered, .notFound])
func refreshAgentRepairRegistersNeverRegisteredHelper(initialStatus: RefreshAgentRegistrationStatus) async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: initialStatus, registrationSteps: [.succeed(.enabled)]
    )
    let stateStore = makeRegistrationStateStore()
    // Persisted state from a previous attempt must not suppress a live registration attempt.
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    stateStore.saveDiagnostic(kind: .notFound, build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning },
        currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )

    #expect(await coordinator.repairIfNeeded(isEnabled: { true }) == .repaired(attempts: 1))
    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(service.isRunning)
    #expect(stateStore.repairedBuild == "build-1")
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test(arguments: [false, true], [RefreshAgentRegistrationStatus.notRegistered, .notFound])
func refreshAgentMissingHelperFailureOffersRecoveryAfterRegistration(
    repair: Bool, initialStatus: RefreshAgentRegistrationStatus
) async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: initialStatus,
        registrationSteps: initialStatus == .notFound ? [.fail] : [.succeed(.notFound)]
    )
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning },
        currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )

    if repair {
        #expect(await coordinator.repairIfNeeded(isEnabled: { true }) == .notFound)
    } else {
        do {
            try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
            Issue.record("expected a failed registration to be reported")
        } catch {}
    }

    #expect(service.registerCount == 1)
    #expect(service.unregisterCount == 0)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic?.kind == .notFound)
    let message = coordinator.currentDiagnostic?.userFacingMessage ?? ""
    #expect(message.contains("Update or reinstall Context Panel"))
    #expect(message.contains("Repair background updates"))
    #expect(message.contains("Refresh now"))
}

@MainActor
@Test func refreshAgentRepairIgnoresCurrentMarkerWhenLiveRegistrationIsMissing() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [.succeed(.enabled)]
    )
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 1))
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 1)
    #expect(stateStore.reconciledBuild == "build-1")
    #expect(stateStore.repairedBuild == "build-1")
}

@MainActor
@Test func refreshAgentRepairObservesDelayedEnabledStatusBeforeDuplicateRegister() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [.succeed(.notRegistered), .fail]
    )
    let stateStore = makeRegistrationStateStore()
    let verificationDelay = Duration.milliseconds(10)
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: RefreshAgentRegistrationPolicy(
            launchGrace: .zero,
            retryDelays: [.milliseconds(20)],
            verificationDelay: verificationDelay
        ),
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { duration in
            if duration == verificationDelay {
                service.status = .enabled
                service.isRunning = true
            }
        }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 1))
    #expect(service.registerCount == 1)
}

@MainActor
@Test func refreshAgentRepairKeepsVerificationInsideRetryCadence() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [
            .succeed(.notRegistered),
            .succeed(.notRegistered),
            .succeed(.notRegistered),
            .succeed(.enabled),
        ]
    )
    let stateStore = makeRegistrationStateStore()
    var elapsed = Duration.zero
    var registrationTimes: [Duration] = []
    service.onRegister = { registrationTimes.append(elapsed) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: .appDefault,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { elapsed += $0 }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 4))
    guard let firstRegistrationTime = registrationTimes.first else {
        Issue.record("expected registration attempts")
        return
    }
    #expect(registrationTimes.map { $0 - firstRegistrationTime } == [
        .zero,
        .milliseconds(250),
        .milliseconds(1_250),
        .milliseconds(4_250),
    ])
}

@MainActor
@Test func refreshAgentRepairMarksRunningCurrentBuildWithoutDestructiveRepair() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { true },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .agentAlreadyRunning)
    #expect(stateStore.repairedBuild == "build-1")
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
}

@MainActor
@Test func refreshAgentRepairClearsStaleDiagnosticWhenEnabledAgentIsRunning() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    let stateStore = makeRegistrationStateStore()
    stateStore.saveDiagnostic(kind: .failed, build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { true },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .agentAlreadyRunning)
    #expect(coordinator.currentDiagnostic == nil)
    #expect(stateStore.repairedBuild == nil)
}

@MainActor
@Test func refreshAgentReconcileRequiresEnabledStatusBeforeMarkingBuild() {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [.succeed(.notRegistered)]
    )
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    do {
        try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
        Issue.record("expected registration reconciliation to reject a non-enabled status")
    } catch {}

    #expect(stateStore.reconciledBuild == nil)
    #expect(coordinator.currentDiagnostic?.kind == .failed)
}

@MainActor
@Test func refreshAgentReconcileClearsMarkersBeforeDelayedEnabledStatus() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [.succeed(.notRegistered), .succeed(.enabled)]
    )
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    do {
        try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
        Issue.record("expected delayed status to fail synchronous reconciliation")
    } catch {}
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)

    service.status = .enabled
    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 1))
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 2)
}

@MainActor
@Test func refreshAgentRepairSchedulingDoesNotWaitForLaunchGrace() {
    var sleepStarted = false
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in sleepStarted = true }
    )

    coordinator.scheduleRepair(isEnabled: { true })

    #expect(!sleepStarted)
    coordinator.cancelPendingRepair()
}

@MainActor
@Test func refreshAgentCompletedCancellationDoesNotSkipLaterLaunchGrace() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled,
        registrationSteps: [.succeed(.enabled)]
    )
    let scriptedSleep = ScriptedRefreshAgentRegistrationSleep()
    scriptedSleep.suspendsNextCall = true
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: RefreshAgentRegistrationPolicy(
            launchGrace: .seconds(8),
            retryDelays: [],
            verificationDelay: .zero
        ),
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { try await scriptedSleep.sleep(for: $0) }
    )

    coordinator.scheduleRepair(isEnabled: { true })
    for _ in 0..<20 {
        if scriptedSleep.isSuspended { break }
        await Task.yield()
    }
    #expect(scriptedSleep.isSuspended)

    coordinator.cancelPendingRepair()
    scriptedSleep.cancelSuspendedSleep()
    for _ in 0..<20 {
        await Task.yield()
    }

    await withCheckedContinuation { continuation in
        coordinator.scheduleRepair(isEnabled: { true }) { _ in
            continuation.resume()
        }
    }

    #expect(scriptedSleep.durations == [.seconds(8), .seconds(8)])
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
}

@MainActor
@Test func refreshAgentDisableSerializesWithInFlightRestorativeUnregister() async throws {
    var staleCallbackCount = 0
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    service.suspendsUnregister = true
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { _ in }
    )

    coordinator.scheduleRepair(isEnabled: { service.isUserEnabled }) { _ in
        staleCallbackCount += 1
    }
    for _ in 0..<20 {
        if service.unregisterCount == 1 { break }
        await Task.yield()
    }
    #expect(service.unregisterCount == 1)

    service.isUserEnabled = false
    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: false))
    #expect(service.unregisterCount == 1)

    service.resumeUnregister()
    await withCheckedContinuation { continuation in
        coordinator.scheduleRepair(isEnabled: { false }) { _ in
            continuation.resume()
        }
    }

    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 0)
    #expect(staleCallbackCount == 0)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test func refreshAgentReenableRestoresImmediatelyAfterInFlightUnregister() async throws {
    var staleCallbackCount = 0
    var sleepDurations: [Duration] = []
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled,
        registrationSteps: [.succeed(.enabled)]
    )
    service.suspendsUnregister = true
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: RefreshAgentRegistrationPolicy(
            launchGrace: .seconds(8),
            retryDelays: [.zero],
            verificationDelay: .zero
        ),
        currentBuild: { "build-1" },
        isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { sleepDurations.append($0) }
    )

    coordinator.scheduleRepair(isEnabled: { service.isUserEnabled }) { _ in
        staleCallbackCount += 1
    }
    for _ in 0..<20 {
        if service.unregisterCount == 1 { break }
        await Task.yield()
    }
    #expect(service.unregisterCount == 1)

    service.isUserEnabled = false
    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: false))
    service.isUserEnabled = true
    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))

    await withCheckedContinuation { continuation in
        coordinator.scheduleRepair(isEnabled: { service.isUserEnabled }) { _ in
            continuation.resume()
        }
        service.resumeUnregister()
    }

    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
    #expect(staleCallbackCount == 0)
    #expect(sleepDurations == [.seconds(8), .zero])
    #expect(stateStore.reconciledBuild == "build-1")
    #expect(stateStore.repairedBuild == "build-1")
}

@MainActor
@Test func refreshAgentRepairDoesNotTrustOldSuccessWhenTheEnabledAgentIsGone() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled,
        registrationSteps: [.succeed(.enabled)])
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(service: service, stateStore: stateStore,
        policy: immediateRepairPolicy, currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID }, sleep: { _ in })
    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })
    #expect(outcome == .repaired(attempts: 1))
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
}

@MainActor
@Test func refreshAgentEnabledRegistrationWithoutAProcessIsNotRepaired() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled, registrationSteps: [.succeed(.enabled)]
    )
    service.startsAgentOnRegister = false
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .failed(attempts: 1))
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic != nil)
    #expect(service.registerCount == 1)
}

@MainActor
@Test func refreshAgentReconcilePreservesFailureUntilTheProcessReturns() throws {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    let stateStore = makeRegistrationStateStore()
    stateStore.markReconciled(build: "build-1")
    stateStore.saveDiagnostic(kind: .failed, build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )

    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
    #expect(coordinator.currentDiagnostic != nil)

    service.isRunning = true
    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test func refreshAgentRepairWaitsForTheRegisteredHelperToLaunch() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered, registrationSteps: [.succeed(.enabled)]
    )
    service.startsAgentOnRegister = false
    let stateStore = makeRegistrationStateStore()
    let policy = RefreshAgentRegistrationPolicy(
        launchGrace: .seconds(8), retryDelays: [], verificationDelay: .zero
    )
    var waits: [Duration] = []
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: policy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { duration in
            waits.append(duration)
            if service.status == .enabled { service.isRunning = true }
        }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .repaired(attempts: 1))
    #expect(waits == [policy.launchGrace, policy.launchGrace])
    #expect(coordinator.currentDiagnostic == nil)
}

@MainActor
@Test func refreshAgentHealthCheckDetectsALaterExitAndThenRecovery() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled, registrationSteps: [.succeed(.enabled)]
    )
    service.isRunning = true
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID }, sleep: { _ in }
    )
    #expect(await coordinator.repairIfNeeded(isEnabled: { true }) == .agentAlreadyRunning)

    service.isRunning = false
    service.startsAgentOnRegister = false
    let failure = await withCheckedContinuation { continuation in
        coordinator.scheduleHealthCheck(isEnabled: { true }) { continuation.resume(returning: $0) }
    }
    #expect(failure?.kind == .notUpdating)
    #expect(stateStore.repairedBuild == nil)

    service.isRunning = true
    let recovery = await withCheckedContinuation { continuation in
        coordinator.scheduleHealthCheck(isEnabled: { true }) { continuation.resume(returning: $0) }
    }
    #expect(recovery == nil)
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 1)
}

@MainActor
@Test func refreshAgentHealthCheckDoesNotInterruptAnActiveRepair() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    service.isRunning = true
    let sleep = ScriptedRefreshAgentRegistrationSleep()
    sleep.suspendsNextCall = true
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: makeRegistrationStateStore(), policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning }, currentAgentRunID: { service.latestRunID },
        sleep: { try await sleep.sleep(for: $0) }
    )
    var repairCallbackCount = 0
    coordinator.scheduleRepair(isEnabled: { true }) { _ in repairCallbackCount += 1 }
    for _ in 0..<20 {
        if sleep.isSuspended { break }
        await Task.yield()
    }
    #expect(sleep.isSuspended)
    coordinator.scheduleHealthCheck(isEnabled: { true }) { _ in Issue.record("duplicate health check") }
    sleep.resumeSuspendedSleep()
    for _ in 0..<20 { await Task.yield() }

    #expect(repairCallbackCount == 1)
    #expect(service.registerCount == 0)
    #expect(service.unregisterCount == 0)
    coordinator.cancelPendingRepair()
}

@MainActor
@Test(arguments: [RefreshAgentRegistrationDiagnostic.Kind.notUpdating, .notFound])
func refreshAgentDiagnosticAppearsInTheAppAndClearsAfterRecovery(kind: RefreshAgentRegistrationDiagnostic.Kind) {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let service = SnapshotRefreshService(
        accountStore: AccountConfigurationStore(configurationURL: root.appending(path: "accounts.json")),
        stores: SnapshotRefreshStores(primary: JSONSnapshotStore(rootDirectory: root)),
        promptCacheTelemetryMirror: { _, _ in }, promptCacheTelemetryReader: { _ in [] }
    )
    let model = ContextPanelAppModel(
        refreshService: service, runtimeReceiptRecorder: .disabled(), enablesRuntimeReceiptRelay: false
    )
    let diagnostic = RefreshAgentRegistrationDiagnostic(kind: kind)
    model.updateBackgroundRefreshDiagnostic(diagnostic)
    #expect(model.errorMessage == diagnostic.userFacingMessage)
    #expect(model.primaryErrorStatusText == diagnostic.userFacingMessage)
    model.updateBackgroundRefreshDiagnostic(nil)
    #expect(model.errorMessage == nil)

    model.setError("A provider could not refresh.")
    let providerError = model.errorMessage
    model.updateBackgroundRefreshDiagnostic(diagnostic)
    model.updateBackgroundRefreshDiagnostic(nil)
    #expect(model.errorMessage == providerError)
}

@MainActor
@Test func refreshAgentPersistentFailureDoesNotReregisterEveryHealthTick() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .enabled, registrationSteps: [.succeed(.enabled)]
    )
    service.startsAgentOnRegister = false
    let start = Date(timeIntervalSince1970: 10_000)
    var now = start
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: makeRegistrationStateStore(), policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { service.isRunning },
        currentAgentRunID: { service.latestRunID }, now: { now },
        awakeTime: { .seconds(now.timeIntervalSince(start)) }, sleep: { _ in }
    )
    #expect(await coordinator.repairIfNeeded(isEnabled: { true }) == .failed(attempts: 1))
    let registrations = service.registerCount
    for _ in 0..<3 {
        now = now.addingTimeInterval(30)
        let diagnostic = await withCheckedContinuation { continuation in
            coordinator.scheduleHealthCheck(isEnabled: { true }) { continuation.resume(returning: $0) }
        }
        #expect(diagnostic?.kind == .notUpdating)
    }
    #expect(service.registerCount == registrations)
    #expect(service.unregisterCount == 1)

    now = start.addingTimeInterval(RefreshAgentRegistrationCoordinator.automaticRepairCooldown)
    await withCheckedContinuation { continuation in
        coordinator.scheduleHealthCheck(isEnabled: { true }) { _ in continuation.resume() }
    }
    #expect(service.registerCount > registrations)
}

@MainActor
@Test func refreshAgentHealthCheckAllowsTheExistingHelperToResumeAfterSleep() async {
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    let start = Date(timeIntervalSince1970: 20_000)
    var now = start
    var awake = Duration.zero
    var isHealthy = false
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: makeRegistrationStateStore(), policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { isHealthy },
        now: { now }, awakeTime: { awake }, sleep: { _ in }
    )
    now = now.addingTimeInterval(3_600)
    let afterWake = await withCheckedContinuation { continuation in
        coordinator.scheduleHealthCheck(isEnabled: { true }, wakeRecoveryInterval: 300) {
            continuation.resume(returning: $0)
        }
    }
    #expect(afterWake == nil)
    #expect(service.unregisterCount == 0)

    now = now.addingTimeInterval(30)
    awake += .seconds(30)
    isHealthy = true
    await withCheckedContinuation { continuation in
        coordinator.scheduleHealthCheck(isEnabled: { true }) { _ in continuation.resume() }
    }
    #expect(service.unregisterCount == 0)
    #expect(service.registerCount == 0)
}

@MainActor
@Test func refreshAgentReregistrationRejectsThePreviousHelpersRecentWake() async throws {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered, registrationSteps: [.succeed(.enabled)]
    )
    service.startsAgentOnRegister = false
    let previousRun = UUID().uuidString
    let stateStore = makeRegistrationStateStore()
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service, stateStore: stateStore, policy: immediateRepairPolicy,
        currentBuild: { "build-1" }, isAgentHealthy: { true },
        currentAgentRunID: { previousRun }, sleep: { _ in }
    )
    try coordinator.reconcile(settings: BackgroundRefreshSettings(isEnabled: true))
    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })
    #expect(outcome == .failed(attempts: 4))
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic != nil)
}
