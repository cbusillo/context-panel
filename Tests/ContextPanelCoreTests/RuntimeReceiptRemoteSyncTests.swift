import CloudKit
@testable import ContextPanelCloudKitSync
import ContextPanelCore
import Foundation
import Testing

@Test func runtimeReceiptReceiverMirrorsOnlyMatchingActiveSession() async throws {
    let now = Date(timeIntervalSince1970: 200_000)
    let session = relaySession(now: now, surfaces: [.watchOSApp, .watchOSComplication])
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let remoteStore = relayRemoteStore(loadSession: {
        RuntimeValidationSessionRemoteLoadResult(
            session: session,
            stateUpdatedAt: now,
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    })
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.watchOSApp, .watchOSComplication]
        ),
        sessionStore: sessionStore,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )

    let mirrored = await coordinator.synchronizeSession(now: now)

    #expect(mirrored.action == .mirrored)
    #expect(mirrored.isHealthy)
    #expect(sessionStore.activeSession(now: now) == session)
    #expect(sessionStore.latestSession(now: now) == session)

    let rejectedCoordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("9"),
            eligibleSurfaces: [.watchOSApp]
        ),
        sessionStore: sessionStore,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )

    let rejected = await rejectedCoordinator.synchronizeSession(now: now)

    #expect(rejected.action == .rejected)
    #expect(!rejected.isHealthy)
    #expect(sessionStore.activeSession(now: now) == nil)
    #expect(sessionStore.latestSession(now: now) == session)
}

@Test func runtimeReceiptReceiverRetriesRecordingAfterSessionMirror() async throws {
    let now = Date(timeIntervalSince1970: 225_000)
    let session = relaySession(now: now, surfaces: [.tvOSApp])
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    let remoteRecorder = RelayRemoteRecorder()
    let remoteStore = relayRemoteStore(
        loadSession: {
            RuntimeValidationSessionRemoteLoadResult(
                session: session,
                stateUpdatedAt: now,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        saveReceipts: { receipts, _ in
            await remoteRecorder.recordSave(receipts.map(\.id))
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: receipts.map(\.id),
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.tvOSApp, .tvOSTopShelf]
        ),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )
    let recorder = RuntimeReceiptRecorder(
        identity: relayIdentity(surface: .tvOSApp),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!
        )
    )
    let recordReceipt: @Sendable () -> RuntimeReceiptRecordResult = {
        recorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .appOverview,
            selectedSource: .cloudKit,
            presentationDigest: relayHash("8"),
            stateBranch: .ready,
            outcome: .success,
            observedAt: now
        )
    }

    let initialResult = recordReceipt()
    let finalResult = await coordinator.completeReceiptRelay(
        after: initialResult,
        observedAt: now,
        relayAt: now,
        retry: recordReceipt
    )

    #expect(initialResult == .inactiveSession)
    #expect(finalResult == .saved)
    #expect(sessionStore.activeSession(now: now) == session)
    #expect(receiptStore.loadUnexpiredReceipts(now: now).count == 1)
    #expect(await remoteRecorder.saveCallCount == 1)
}

@Test func runtimeReceiptReceiverRetryRemainsRateLimitedAndAcknowledged() async throws {
    let now = Date(timeIntervalSince1970: 235_000)
    let session = relaySession(
        now: now,
        surfaces: [.tvOSApp],
        minimumWriteIntervalSeconds: 30
    )
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let receiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    let remoteRecorder = RelayRemoteRecorder()
    let remoteStore = relayRemoteStore(
        loadSession: {
            RuntimeValidationSessionRemoteLoadResult(
                session: session,
                stateUpdatedAt: now,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        saveReceipts: { receipts, _ in
            await remoteRecorder.recordSave(receipts.map(\.id))
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: receipts.map(\.id),
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.tvOSApp]
        ),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )
    let recorder = RuntimeReceiptRecorder(
        identity: relayIdentity(surface: .tvOSApp),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000011")!
        )
    )
    let recordReceipt: @Sendable () -> RuntimeReceiptRecordResult = {
        recorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .appOverview,
            selectedSource: .cloudKit,
            presentationDigest: relayHash("8"),
            stateBranch: .ready,
            outcome: .success,
            observedAt: now
        )
    }

    let first = await coordinator.completeReceiptRelay(
        after: recordReceipt(),
        observedAt: now,
        relayAt: now,
        retry: recordReceipt
    )
    let second = await coordinator.completeReceiptRelay(
        after: recordReceipt(),
        observedAt: now,
        relayAt: now,
        retry: recordReceipt
    )

    #expect(first == .saved)
    #expect(second == .rateLimited)
    #expect(receiptStore.loadUnexpiredReceipts(now: now).count == 1)
    #expect(await remoteRecorder.saveCallCount == 1)
}

@Test func runtimeReceiptReceiverRunsFreshRelayAfterConcurrentStalePass() async throws {
    let now = Date(timeIntervalSince1970: 245_000)
    let session = relaySession(now: now, surfaces: [.tvOSApp])
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    try sessionStore.save(session, now: now)
    let receiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    let staleReceipt = relayReceipt(
        session: session,
        observedAt: now.addingTimeInterval(-1),
        processSequence: 1,
        surface: .tvOSApp
    )
    #expect(try receiptStore.save(staleReceipt, session: session, now: now) == .saved)
    let remoteRecorder = RelayRemoteRecorder()
    let firstSaveGate = RelayRemoteSaveGate()
    let remoteStore = relayRemoteStore(saveReceipts: { receipts, _ in
        await remoteRecorder.recordSave(receipts.map(\.id))
        await firstSaveGate.waitIfNeeded()
        return RuntimeReceiptRemoteSaveResult(
            acceptedReceiptIDs: receipts.map(\.id),
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    })
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.tvOSApp]
        ),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )
    let staleRelay = Task {
        await coordinator.relayReceipts(now: now)
    }
    #expect(await firstSaveGate.waitUntilStarted())

    let recorder = RuntimeReceiptRecorder(
        identity: relayIdentity(surface: .tvOSApp),
        sessionStore: sessionStore,
        receiptStore: receiptStore,
        processContext: RuntimeReceiptProcessContext(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!
        )
    )
    let recordReceipt: @Sendable () -> RuntimeReceiptRecordResult = {
        recorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .appOverview,
            selectedSource: .cloudKit,
            presentationDigest: relayHash("7"),
            stateBranch: .ready,
            outcome: .success,
            observedAt: now
        )
    }
    let initialResult = recordReceipt()
    let completion = Task {
        await coordinator.completeReceiptRelay(
            after: initialResult,
            observedAt: now,
            relayAt: now,
            retry: recordReceipt
        )
    }

    await firstSaveGate.release()
    _ = await staleRelay.value
    let finalResult = await completion.value
    let localReceiptIDs = Set(receiptStore.loadUnexpiredReceipts(now: now).map(\.id))
    let remoteReceiptIDs = Set(await remoteRecorder.savedReceiptIDs.flatMap { $0 })

    #expect(initialResult == .saved)
    #expect(finalResult == .saved)
    #expect(await remoteRecorder.saveCallCount == 2)
    #expect(localReceiptIDs.count == 2)
    #expect(remoteReceiptIDs == localReceiptIDs)
}

@Test func runtimeReceiptPublisherClearsOnlyItsArchivedSession() async throws {
    let now = Date(timeIntervalSince1970: 250_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let recorder = RelayRemoteRecorder()
    let remoteStore = RuntimeReceiptRemoteStore(
        publishCurrentSession: { mutation in
            await recorder.recordSessionMutation(mutation)
            return RuntimeReceiptRemoteOutcome(succeeded: true)
        },
        loadCurrentSession: { _ in
            RuntimeValidationSessionRemoteLoadResult(
                session: nil,
                missingRecord: true,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        saveReceiptBatch: { receipts, _ in
            RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: receipts.map(\.id),
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        loadReceiptBatch: { _, _ in
            RuntimeReceiptRemoteLoadResult(
                envelopes: [],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        pruneExpiredReceiptBatch: { _ in
            RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: 0,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .publisher,
        sessionStore: sessionStore,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: RuntimeReceiptInboxStore(directoryURL: root.appending(path: "inbox")),
        remoteStore: remoteStore
    )

    let unchanged = await coordinator.synchronizeSession(now: now)
    #expect(unchanged.action == .unchanged)
    #expect(await recorder.sessionMutations.isEmpty)

    let session = relaySession(now: now, surfaces: [.macOSApp])
    try sessionStore.save(session)
    try sessionStore.removeActiveSession()
    let cleared = await coordinator.synchronizeSession(now: now)

    #expect(cleared.action == .cleared)
    #expect(await recorder.sessionMutations == [.clear(session)])
}

@Test func runtimeReceiptSessionJournalRetainsConsecutiveSessions() throws {
    let now = Date(timeIntervalSince1970: 275_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let first = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        now: now,
        surfaces: [.macOSApp]
    )
    let secondNow = now.addingTimeInterval(120)
    let second = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        now: secondNow,
        surfaces: [.macOSWidget]
    )

    try store.save(first, now: now)
    try store.removeActiveSession(now: now)
    try store.save(second, now: secondNow)

    #expect(store.activeSession(now: secondNow) == second)
    #expect(store.retainedSessions(now: secondNow).map(\.id) == [first.id, second.id])
}

@Test func runtimeReceiptPublisherClearsRetainedSessionsBeforePublishingTheNext() async throws {
    let now = Date(timeIntervalSince1970: 290_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    let first = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
        now: now,
        surfaces: [.macOSApp]
    )
    let secondNow = now.addingTimeInterval(120)
    let second = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        now: secondNow,
        surfaces: [.macOSWidget]
    )
    try store.save(first, now: now)
    try store.removeActiveSession(now: now)
    try store.save(second, now: secondNow)
    let recorder = RelayRemoteRecorder()
    let remoteStore = relayRemoteStore(publishSession: { mutation in
        await recorder.recordSessionMutation(mutation)
        return RuntimeReceiptRemoteOutcome(succeeded: true)
    })
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .publisher,
        sessionStore: store,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: RuntimeReceiptInboxStore(directoryURL: root.appending(path: "inbox")),
        remoteStore: remoteStore
    )

    let result = await coordinator.synchronizeSession(now: secondNow)

    #expect(result.action == .published)
    #expect(await recorder.sessionMutations == [.clear(first), .publish(second)])
}

@Test func runtimeReceiptReceiverDoesNotClearForAnUnversionedMissingRecord() async throws {
    let now = Date(timeIntervalSince1970: 295_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: now, surfaces: [.watchOSApp])
    let store = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    try store.save(session, now: now)
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.watchOSApp]
        ),
        sessionStore: store,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: relayRemoteStore()
    )

    let result = await coordinator.synchronizeSession(now: now)

    #expect(result.action == .unchanged)
    #expect(store.activeSession(now: now) == session)
}

@Test func runtimeReceiptRemoteMirrorRejectsStaleSessionState() throws {
    let now = Date(timeIntervalSince1970: 297_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: now, surfaces: [.watchOSApp])
    let store = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )

    #expect(try store.applyRemoteState(
        .active,
        session: session,
        stateUpdatedAt: now.addingTimeInterval(10.001),
        now: now.addingTimeInterval(20)
    ))
    #expect(!(try store.applyRemoteState(
        .cleared,
        session: nil,
        stateUpdatedAt: now.addingTimeInterval(10),
        now: now.addingTimeInterval(20)
    )))
    #expect(store.activeSession(now: now.addingTimeInterval(20)) == session)
    #expect(try store.applyRemoteState(
        .cleared,
        session: nil,
        stateUpdatedAt: now.addingTimeInterval(10.002),
        now: now.addingTimeInterval(20)
    ))
    #expect(!(try store.applyRemoteState(
        .active,
        session: session,
        stateUpdatedAt: now.addingTimeInterval(10.001),
        now: now.addingTimeInterval(20)
    )))
    #expect(store.activeSession(now: now.addingTimeInterval(20)) == nil)
}

@Test func runtimeReceiptRelayRetriesOfflineAndAcknowledgesAcceptedReceipts() async throws {
    let now = Date(timeIntervalSince1970: 300_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let receipt = relayReceipt(session: session, observedAt: now, processSequence: 1)
    let receiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    #expect(try receiptStore.save(receipt, session: session, now: now) == .saved)
    let recorder = RelayRemoteRecorder()
    let remoteStore = relayRemoteStore(saveReceipts: { receipts, _ in
        await recorder.recordSave(receipts.map(\.id))
        if await recorder.saveCallCount == 1 {
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: [],
                outcome: RuntimeReceiptRemoteOutcome(
                    succeeded: false,
                    errorMessage: "CloudKit runtime receipt publish failed."
                )
            )
        }
        return RuntimeReceiptRemoteSaveResult(
            acceptedReceiptIDs: receipts.map(\.id),
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    })
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.macOSWidget]
        ),
        sessionStore: RuntimeValidationSessionStore(
            sessionURL: root.appending(path: "runtime-session.json")
        ),
        receiptStore: receiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: remoteStore
    )

    let offline = await coordinator.relayReceipts(now: now)
    let deferred = await coordinator.relayReceipts(now: now.addingTimeInterval(1))
    let retried = await coordinator.relayReceipts(now: now.addingTimeInterval(61))
    let acknowledged = await coordinator.relayReceipts(now: now.addingTimeInterval(62))

    #expect(!offline.isHealthy)
    #expect(offline.uploadedReceiptCount == 0)
    #expect(deferred.isHealthy)
    #expect(deferred.uploadedReceiptCount == 0)
    #expect(retried.isHealthy)
    #expect(retried.uploadedReceiptCount == 1)
    #expect(acknowledged.isHealthy)
    #expect(acknowledged.uploadedReceiptCount == 0)
    #expect(await recorder.saveCallCount == 2)
}

@Test func runtimeReceiptPublisherKeepsRemoteInboxOutOfTheUploadQueue() async throws {
    let now = Date(timeIntervalSince1970: 400_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: now, surfaces: [.watchOSComplication])
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    try sessionStore.save(session)
    let receipt = relayReceipt(
        session: session,
        observedAt: now,
        processSequence: 1,
        surface: .watchOSComplication
    )
    let envelope = RuntimeReceiptRemoteEnvelope(
        receipt: receipt,
        serverReceivedAt: now.addingTimeInterval(1)
    )
    let recorder = RelayRemoteRecorder()
    let remoteStore = relayRemoteStore(
        saveReceipts: { receipts, _ in
            await recorder.recordSave(receipts.map(\.id))
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: receipts.map(\.id),
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        loadReceipts: { _, _ in
            RuntimeReceiptRemoteLoadResult(
                envelopes: [envelope],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let localReceiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    let inboxStore = RuntimeReceiptInboxStore(directoryURL: root.appending(path: "inbox"))
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .publisher,
        sessionStore: sessionStore,
        receiptStore: localReceiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: inboxStore,
        remoteStore: remoteStore
    )

    let summary = await coordinator.relayReceipts(now: now.addingTimeInterval(2))

    #expect(summary.isHealthy)
    #expect(summary.downloadedReceiptCount == 1)
    #expect(localReceiptStore.loadReceipts().isEmpty)
    #expect(inboxStore.loadEnvelopes(now: now.addingTimeInterval(2)) == [envelope])
    #expect(await recorder.saveCallCount == 0)
}

@Test func runtimeReceiptRemoteEnvelopeOrderingIsAcyclicAndPreservesProcessSequence() {
    let now = Date(timeIntervalSince1970: 500_000)
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let firstProcessID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let secondProcessID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
    let first = RuntimeReceiptRemoteEnvelope(
        receipt: relayReceipt(
            session: session,
            observedAt: now,
            processInstanceID: firstProcessID,
            processSequence: 1
        ),
        serverReceivedAt: now.addingTimeInterval(20)
    )
    let second = RuntimeReceiptRemoteEnvelope(
        receipt: relayReceipt(
            session: session,
            observedAt: now.addingTimeInterval(1),
            processInstanceID: firstProcessID,
            processSequence: 2
        ),
        serverReceivedAt: now.addingTimeInterval(10)
    )
    let otherProcess = RuntimeReceiptRemoteEnvelope(
        receipt: relayReceipt(
            session: session,
            observedAt: now.addingTimeInterval(2),
            processInstanceID: secondProcessID,
            processSequence: 1
        ),
        serverReceivedAt: now.addingTimeInterval(15)
    )

    let expected = [otherProcess, first, second]
    let permutations = [
        [first, second, otherProcess],
        [first, otherProcess, second],
        [second, first, otherProcess],
        [second, otherProcess, first],
        [otherProcess, first, second],
        [otherProcess, second, first],
    ]

    for permutation in permutations {
        #expect(RuntimeReceiptRemoteEnvelope.ordered(permutation) == expected)
    }
}

@Test func runtimeReceiptOrderingPreservesSequenceAcrossClockRollback() {
    let now = Date(timeIntervalSince1970: 525_000)
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let processID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    let first = relayReceipt(
        session: session,
        observedAt: now.addingTimeInterval(20),
        processInstanceID: processID,
        processSequence: 1
    )
    let second = relayReceipt(
        session: session,
        observedAt: now.addingTimeInterval(10),
        processInstanceID: processID,
        processSequence: 2
    )

    #expect(RuntimeReceipt.ordered([second, first]) == [first, second])
}

@Test func runtimeReceiptRelayDoesNotUploadOrRetainExpiredEvidence() async throws {
    let observedAt = Date(timeIntervalSince1970: 550_000)
    let now = observedAt.addingTimeInterval(24 * 60 * 60 + 1)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: observedAt, surfaces: [.macOSWidget])
    let receipt = relayReceipt(session: session, observedAt: observedAt, processSequence: 1)
    let receiptStore = RuntimeReceiptStore(directoryURL: root.appending(path: "receipts"))
    #expect(try receiptStore.save(receipt, session: session, now: observedAt) == .saved)
    let recorder = RelayRemoteRecorder()
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .receiver(
            expectedManifestID: relayHash("a"),
            eligibleSurfaces: [.macOSWidget]
        ),
        sessionStore: RuntimeValidationSessionStore(
            sessionURL: root.appending(path: "runtime-session.json")
        ),
        receiptStore: receiptStore,
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: nil,
        remoteStore: relayRemoteStore(saveReceipts: { receipts, _ in
            await recorder.recordSave(receipts.map(\.id))
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: receipts.map(\.id),
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        })
    )

    let summary = await coordinator.relayReceipts(now: now)

    #expect(summary.isHealthy)
    #expect(summary.uploadedReceiptCount == 0)
    #expect(receiptStore.loadReceipts().isEmpty)
    #expect(await recorder.saveCallCount == 0)
}

@Test func runtimeReceiptInboxPreservesUnknownFutureEnvelopeSchemas() throws {
    let now = Date(timeIntervalSince1970: 575_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let inboxURL = root.appending(path: "inbox")
    try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)
    let futureURL = inboxURL.appending(path: "future.json")
    try Data("{\"schemaVersion\":2}".utf8).write(to: futureURL)
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let receipt = relayReceipt(session: session, observedAt: now, processSequence: 1)
    let store = RuntimeReceiptInboxStore(directoryURL: inboxURL)

    try store.save(
        [
            RuntimeReceiptRemoteEnvelope(
                receipt: receipt,
                serverReceivedAt: now.addingTimeInterval(1)
            ),
        ],
        now: now.addingTimeInterval(2)
    )
    try store.save([], now: receipt.retentionExpiresAt.addingTimeInterval(1))

    #expect(FileManager.default.fileExists(atPath: futureURL.path))
    #expect(store.loadEnvelopes(now: receipt.retentionExpiresAt.addingTimeInterval(1)).isEmpty)
}

@Test func runtimeReceiptRemotePayloadCodecsRejectUnknownFields() throws {
    let now = Date(timeIntervalSince1970: 590_000)
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let receipt = relayReceipt(session: session, observedAt: now, processSequence: 1)
    let sessionPayload = try payloadByAddingField(
        "accountID",
        value: "must-not-leak",
        to: RuntimeValidationSessionPayloadCodec.encode(session)
    )
    let receiptPayload = try payloadByAddingField(
        "privatePath",
        value: "/Users/example/private",
        to: RuntimeReceiptPayloadCodec.encode(receipt)
    )

    #expect(throws: RuntimeReceiptRemoteSyncError.invalidSession) {
        try RuntimeValidationSessionPayloadCodec.decode(
            sessionPayload,
            now: now,
            requiresActive: true
        )
    }
    #expect(throws: RuntimeReceiptRemoteSyncError.invalidReceipt) {
        try RuntimeReceiptPayloadCodec.decode(receiptPayload)
    }
}

@Test func runtimeReceiptPublisherIsDormantWithoutRetainedWork() async throws {
    let now = Date(timeIntervalSince1970: 595_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let recorder = RelayRemoteRecorder()
    let remoteStore = RuntimeReceiptRemoteStore(
        publishCurrentSession: { _ in
            await recorder.recordRemoteCall()
            return RuntimeReceiptRemoteOutcome(succeeded: true)
        },
        loadCurrentSession: { _ in
            await recorder.recordRemoteCall()
            return RuntimeValidationSessionRemoteLoadResult(
                session: nil,
                missingRecord: true,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        saveReceiptBatch: { _, _ in
            await recorder.recordRemoteCall()
            return RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: [],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        loadReceiptBatch: { _, _ in
            await recorder.recordRemoteCall()
            return RuntimeReceiptRemoteLoadResult(
                envelopes: [],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        pruneExpiredReceiptBatch: { _ in
            await recorder.recordRemoteCall()
            return RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: 0,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .publisher,
        sessionStore: RuntimeValidationSessionStore(
            sessionURL: root.appending(path: "runtime-session.json")
        ),
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: RuntimeReceiptInboxStore(directoryURL: root.appending(path: "inbox")),
        remoteStore: remoteStore
    )

    let result = await coordinator.synchronize(now: now)

    #expect(result.isHealthy)
    #expect(await recorder.remoteCallCount == 0)
}

@Test func runtimeReceiptPublisherFinishesRemoteCleanupAfterLocalRetentionExpires() async throws {
    let now = Date(timeIntervalSince1970: 597_000)
    let root = try relayTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let session = relaySession(now: now, surfaces: [.macOSApp])
    let sessionStore = RuntimeValidationSessionStore(
        sessionURL: root.appending(path: "runtime-session.json")
    )
    try sessionStore.save(session, now: now)
    let receipt = relayReceipt(
        session: session,
        observedAt: now,
        processSequence: 1,
        surface: .macOSApp
    )
    let inboxStore = RuntimeReceiptInboxStore(directoryURL: root.appending(path: "inbox"))
    try inboxStore.save(
        [RuntimeReceiptRemoteEnvelope(receipt: receipt, serverReceivedAt: now)],
        now: now
    )
    let recorder = RelayRemoteRecorder()
    let remoteStore = RuntimeReceiptRemoteStore(
        publishCurrentSession: { _ in RuntimeReceiptRemoteOutcome(succeeded: true) },
        loadCurrentSession: { _ in
            RuntimeValidationSessionRemoteLoadResult(
                session: nil,
                missingRecord: true,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        saveReceiptBatch: { _, _ in
            RuntimeReceiptRemoteSaveResult(
                acceptedReceiptIDs: [],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        loadReceiptBatch: { _, _ in
            RuntimeReceiptRemoteLoadResult(
                envelopes: [],
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        },
        pruneExpiredReceiptBatch: { _ in
            await recorder.recordPrune()
            return RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: 0,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
    let coordinator = RuntimeReceiptRelayCoordinator(
        role: .publisher,
        sessionStore: sessionStore,
        receiptStore: RuntimeReceiptStore(directoryURL: root.appending(path: "receipts")),
        relayStateStore: RuntimeReceiptRelayStateStore(
            stateURL: root.appending(path: "relay-state.json")
        ),
        inboxStore: inboxStore,
        remoteStore: remoteStore
    )
    #expect((await coordinator.synchronizeSession(now: now)).isHealthy)
    try sessionStore.removeActiveSession(now: now)
    let afterRetention = session.receiptRetentionExpiresAt.addingTimeInterval(1)

    let cleanupStarted = await coordinator.relayReceipts(now: afterRetention)
    let deferred = await coordinator.relayReceipts(now: afterRetention.addingTimeInterval(1))
    let cleanupFinished = await coordinator.relayReceipts(
        now: afterRetention.addingTimeInterval(RuntimeReceiptRemoteSync.maintenanceInterval + 1)
    )
    let dormant = await coordinator.relayReceipts(
        now: afterRetention.addingTimeInterval(RuntimeReceiptRemoteSync.maintenanceInterval + 2)
    )

    #expect(cleanupStarted.isHealthy)
    #expect(deferred.isHealthy)
    #expect(cleanupFinished.isHealthy)
    #expect(dormant.isHealthy)
    #expect(await recorder.pruneCallCount == 2)
    #expect(inboxStore.loadEnvelopes(now: afterRetention).isEmpty)
}

@Test func runtimeReceiptCloudKitRecordsUseDedicatedPrivateContracts() throws {
    let now = Date(timeIntervalSince1970: 600_000)
    let session = relaySession(now: now, surfaces: [.macOSWidget])
    let receipt = relayReceipt(session: session, observedAt: now, processSequence: 1)
    let sessionRecord = try RuntimeValidationSessionCloudKitRecordBuilder().makeRecord(
        session: session,
        publishedAt: now
    )
    let clearedSessionRecord = try RuntimeValidationSessionCloudKitRecordBuilder().makeRecord(
        session: session,
        state: .cleared,
        publishedAt: now,
        stateUpdatedAt: now.addingTimeInterval(1)
    )
    let receiptBuilder = RuntimeReceiptCloudKitRecordBuilder()
    let receiptRecord = try receiptBuilder.makeRecord(receipt)

    #expect(sessionRecord.record.recordType == RuntimeReceiptRemoteSync.cloudKitSessionRecordType)
    #expect(sessionRecord.record.recordID.recordName == RuntimeReceiptRemoteSync.cloudKitSessionRecordName)
    #expect(sessionRecord.record.recordID.recordName != CompanionRemoteSync.cloudKitSubscriptionRecordName)
    #expect(sessionRecord.record.recordID.recordName != CompanionRemoteSync.cloudKitRecordName)
    #expect(
        try RuntimeValidationSessionCloudKitRecordBuilder().decodeDocument(
            from: clearedSessionRecord.record,
            now: now.addingTimeInterval(1)
        ).state == .cleared
    )
    let clearedDocument = try RuntimeValidationSessionCloudKitRecordBuilder().decodeDocument(
        from: clearedSessionRecord.record,
        now: now.addingTimeInterval(1)
    )
    let olderSession = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
        now: now.addingTimeInterval(-60),
        surfaces: [.macOSWidget]
    )
    let newerSession = relaySession(
        id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
        now: now.addingTimeInterval(60),
        surfaces: [.macOSWidget]
    )
    #expect(!clearedDocument.canBeSuperseded(by: olderSession))
    #expect(clearedDocument.canBeSuperseded(by: newerSession))
    #expect(receiptRecord.record.recordType == RuntimeReceiptRemoteSync.cloudKitReceiptRecordType)
    #expect(receiptRecord.record.recordID.recordName == "runtime-receipt-\(receipt.id)")
    #expect(try receiptBuilder.decodeReceipt(from: receiptRecord.record) == receipt)
    #expect(CompanionCloudKitSubscriptionFactory.make().recordType == CompanionRemoteSync.cloudKitRecordType)
    #expect(CompanionCloudKitSubscriptionFactory.make().recordType != receiptRecord.record.recordType)
    let payloadText = try #require(String(data: receiptRecord.payload, encoding: .utf8))
    #expect(!payloadText.contains("account"))
    #expect(!payloadText.contains("/Users/"))
}

private actor RelayRemoteRecorder {
    private(set) var saveCallCount = 0
    private(set) var savedReceiptIDs: [[String]] = []
    private(set) var remoteCallCount = 0
    private(set) var pruneCallCount = 0
    private(set) var sessionMutations: [RuntimeValidationSessionRemoteMutation] = []

    func recordSave(_ receiptIDs: [String]) {
        if !receiptIDs.isEmpty {
            saveCallCount += 1
            savedReceiptIDs.append(receiptIDs)
        }
    }

    func recordSessionMutation(_ mutation: RuntimeValidationSessionRemoteMutation) {
        sessionMutations.append(mutation)
    }

    func recordRemoteCall() {
        remoteCallCount += 1
    }

    func recordPrune() {
        pruneCallCount += 1
    }
}

private actor RelayRemoteSaveGate {
    private var started = false
    private var released = false
    private var hasWaited = false

    func waitIfNeeded() async {
        guard !hasWaited else { return }
        hasWaited = true
        started = true
        while !released {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 {
            if started { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return started
    }

    func release() {
        released = true
    }
}

private func relayRemoteStore(
    publishSession: @escaping @Sendable (RuntimeValidationSessionRemoteMutation) async -> RuntimeReceiptRemoteOutcome = { _ in
        RuntimeReceiptRemoteOutcome(succeeded: true)
    },
    loadSession: @escaping @Sendable () async -> RuntimeValidationSessionRemoteLoadResult = {
        RuntimeValidationSessionRemoteLoadResult(
            session: nil,
            missingRecord: true,
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    },
    saveReceipts: @escaping @Sendable ([RuntimeReceipt], Date) async -> RuntimeReceiptRemoteSaveResult = { receipts, _ in
        RuntimeReceiptRemoteSaveResult(
            acceptedReceiptIDs: receipts.map(\.id),
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    },
    loadReceipts: @escaping @Sendable (UUID, Date) async -> RuntimeReceiptRemoteLoadResult = { _, _ in
        RuntimeReceiptRemoteLoadResult(
            envelopes: [],
            outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
        )
    }
) -> RuntimeReceiptRemoteStore {
    RuntimeReceiptRemoteStore(
        publishCurrentSession: publishSession,
        loadCurrentSession: { _ in await loadSession() },
        saveReceiptBatch: saveReceipts,
        loadReceiptBatch: loadReceipts,
        pruneExpiredReceiptBatch: { _ in
            RuntimeReceiptRemotePruneResult(
                deletedReceiptCount: 0,
                outcome: RuntimeReceiptRemoteOutcome(succeeded: true)
            )
        }
    )
}

private func relaySession(
    id: UUID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
    now: Date,
    surfaces: [RuntimeSurface],
    minimumWriteIntervalSeconds: TimeInterval = 0
) -> RuntimeValidationSession {
    RuntimeValidationSession(
        id: id,
        createdAt: now.addingTimeInterval(-60),
        expiresAt: now.addingTimeInterval(30 * 60),
        expectedManifestID: relayHash("a"),
        enabledSurfaces: surfaces,
        minimumWriteIntervalSeconds: minimumWriteIntervalSeconds
    )
}

private func relayIdentity(surface: RuntimeSurface) -> RuntimeSurfaceBuildIdentity {
    RuntimeSurfaceBuildIdentity(
        surface: surface,
        artifactID: surface.rawValue,
        bundleIdentifier: "com.shinycomputers.contextpanel.test",
        build: RuntimeBuildCoordinate(
            marketingVersion: "1.0.54",
            buildNumber: "2026073101",
            manifestID: relayHash("a"),
            contractFingerprint: relayHash("b")
        ),
        fingerprints: RuntimeSurfaceFingerprints(
            render: relayHash("c"),
            runtime: relayHash("d"),
            placement: relayHash("e"),
            combined: relayHash("f")
        ),
        executableUUIDs: ["11111111-2222-3333-4444-555555555555"]
    )
}

private func relayReceipt(
    session: RuntimeValidationSession,
    observedAt: Date,
    processInstanceID: UUID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
    processSequence: UInt64,
    surface: RuntimeSurface = .macOSWidget
) -> RuntimeReceipt {
    RuntimeReceipt(
        session: session,
        observedAt: observedAt,
        processInstanceID: processInstanceID,
        processSequence: processSequence,
        buildIdentity: relayIdentity(surface: surface),
        trigger: .widgetTimeline,
        presentationMode: .widgetSystemSmall,
        selectedSource: .appGroupSnapshot,
        presentationDigest: relayHash("8"),
        stateBranch: .ready,
        outcome: .success
    )
}

private func relayHash(_ character: Character) -> String {
    String(repeating: String(character), count: 64)
}

private func payloadByAddingField(
    _ key: String,
    value: String,
    to data: Data
) throws -> Data {
    var object = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
    object[key] = value
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
}

private func relayTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "ContextPanelRuntimeReceiptRelayTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
