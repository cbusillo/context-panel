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
}

@MainActor
private func makeRegistrationStateStore() -> (RefreshAgentRegistrationStateStore, UserDefaults, String) {
    let suiteName = "RefreshAgentRegistrationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (RefreshAgentRegistrationStateStore(defaults: defaults), defaults, suiteName)
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .failed(attempts: 4))
    #expect(service.unregisterCount == 1)
    #expect(service.registerCount == 4)
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
    #expect(coordinator.currentDiagnostic?.kind == .failed)
    #expect(coordinator.currentDiagnostic?.userFacingMessage.contains("will retry") == true)
}

@MainActor
@Test func refreshAgentRepairStopsWhenDisabledAfterUnregister() async {
    var isEnabled = true
    let service = ScriptedRefreshAgentRegistrationService(status: .enabled)
    service.onUnregister = { isEnabled = false }
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
        sleep: { _ in }
    )

    let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

    #expect(outcome == .failed(attempts: 4))
    #expect(stateStore.reconciledBuild == nil)
    #expect(stateStore.repairedBuild == nil)
}

@MainActor
@Test func refreshAgentRepairTreatsApprovalAndMissingHelperAsTerminal() async {
    for expectedStatus in [RefreshAgentRegistrationStatus.requiresApproval, .notFound] {
        let service = ScriptedRefreshAgentRegistrationService(status: expectedStatus)
        let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        stateStore.markReconciled(build: "build-1")
        stateStore.markRepaired(build: "build-1")
        let coordinator = RefreshAgentRegistrationCoordinator(
            service: service,
            stateStore: stateStore,
            policy: immediateRepairPolicy,
            currentBuild: { "build-1" },
            isAgentRunning: { false },
            sleep: { _ in }
        )

        let outcome = await coordinator.repairIfNeeded(isEnabled: { true })

        #expect(outcome == (expectedStatus == .requiresApproval ? .requiresApproval : .notFound))
        #expect(service.unregisterCount == 0)
        #expect(service.registerCount == 0)
        #expect(stateStore.reconciledBuild == nil)
        #expect(stateStore.repairedBuild == nil)
        #expect(coordinator.currentDiagnostic?.kind == (
            expectedStatus == .requiresApproval ? .requiresApproval : .notFound
        ))
    }
}

@MainActor
@Test func refreshAgentRepairIgnoresCurrentMarkerWhenLiveRegistrationIsMissing() async {
    let service = ScriptedRefreshAgentRegistrationService(
        status: .notRegistered,
        registrationSteps: [.succeed(.enabled)]
    )
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
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
        isAgentRunning: { false },
        sleep: { duration in
            if duration == verificationDelay {
                service.status = .enabled
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    var elapsed = Duration.zero
    var registrationTimes: [Duration] = []
    service.onRegister = { registrationTimes.append(elapsed) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: .appDefault,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { true },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.saveDiagnostic(kind: .failed, build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { true },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "build-1")
    stateStore.markRepaired(build: "build-1")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: RefreshAgentRegistrationPolicy(
            launchGrace: .seconds(8),
            retryDelays: [],
            verificationDelay: .zero
        ),
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    stateStore.markReconciled(build: "old-build")
    stateStore.markRepaired(build: "old-build")
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: immediateRepairPolicy,
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
    let (stateStore, defaults, suiteName) = makeRegistrationStateStore()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let coordinator = RefreshAgentRegistrationCoordinator(
        service: service,
        stateStore: stateStore,
        policy: RefreshAgentRegistrationPolicy(
            launchGrace: .seconds(8),
            retryDelays: [.zero],
            verificationDelay: .zero
        ),
        currentBuild: { "build-1" },
        isAgentRunning: { false },
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
