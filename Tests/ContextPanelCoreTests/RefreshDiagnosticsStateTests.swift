import Foundation
import Testing

@testable import ContextPanelCore

@Test func refreshDiagnosticsStateStoreRoundTripsLatestRunAndAlerts() throws {
    let directory = try temporaryDiagnosticsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RefreshDiagnosticsStateStore(stateURL: directory.appending(path: "refresh-diagnostics-state.json"))
    let startedAt = Date(timeIntervalSince1970: 1_000)
    let finishedAt = Date(timeIntervalSince1970: 1_005)
    let alertedAt = Date(timeIntervalSince1970: 1_006)
    var state = RefreshDiagnosticsState.empty
    state.recordRunStarted(id: "agent-run", source: .refreshAgent, at: startedAt, intervalSeconds: 300)
    state.recordRunFinished(
        id: "agent-run",
        decision: .refreshed,
        finishedAt: finishedAt,
        reportCount: 3,
        failureCount: 1,
        limitCount: 4,
        savedSnapshotAt: finishedAt
    )
    state.recordAlertEvaluation(at: alertedAt, eventCount: 2)
    state.recordAlert(RefreshDiagnosticsAlertRecord(
        channel: .webhook,
        attemptedAt: alertedAt,
        succeededAt: nil,
        eventCount: 2,
        lastHTTPStatus: 500,
        errorMessage: "HTTP 500"
    ))

    try store.save(state)
    let loaded = store.load()

    #expect(loaded.lastRun?.source == .refreshAgent)
    #expect(loaded.lastRun?.decision == .refreshed)
    #expect(loaded.lastRun?.intervalSeconds == 300)
    #expect(loaded.lastRun?.reportCount == 3)
    #expect(loaded.lastRun?.failureCount == 1)
    #expect(loaded.lastSuccessfulRun?.savedSnapshotAt == finishedAt)
    #expect(loaded.lastAlertEvaluationEventCount == 2)
    #expect(loaded.lastWebhook?.lastHTTPStatus == 500)
}

@Test func refreshDiagnosticsStoreTreatsUnsupportedSchemaAsEmpty() throws {
    let directory = try temporaryDiagnosticsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "refresh-diagnostics-state.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"schemaVersion":99}"#.utf8).write(to: url)

    let loaded = RefreshDiagnosticsStateStore(stateURL: url).load()

    #expect(loaded == .empty)
}

@Test func refreshDiagnosticsStateRedactsStoredErrors() throws {
    var state = RefreshDiagnosticsState.empty
    let now = Date(timeIntervalSince1970: 2_000)
    state.recordRunStarted(id: "app-run", source: .app, at: now)
    state.recordRunFinished(
        id: "app-run",
        decision: .failed,
        finishedAt: now,
        errorMessage: "OpenAI failed for user@example.com with bearer sk-secret"
    )
    state.recordAlert(RefreshDiagnosticsAlertRecord(
        channel: .localNotification,
        attemptedAt: now,
        eventCount: 1,
        errorMessage: "delivery failed for user@example.com"
    ))

    #expect(state.lastRun?.errorMessage?.contains("user@example.com") == false)
    #expect(state.lastRun?.errorMessage?.contains("sk-secret") == false)
    #expect(state.lastLocalNotification?.errorMessage?.contains("user@example.com") == false)
}

@Test func refreshDiagnosticsRunFinishIgnoresStaleRunID() throws {
    var state = RefreshDiagnosticsState.empty
    let firstStart = Date(timeIntervalSince1970: 3_000)
    let secondStart = Date(timeIntervalSince1970: 3_005)
    state.recordRunStarted(id: "agent-run", source: .refreshAgent, at: firstStart)
    state.recordRunStarted(id: "app-run", source: .app, at: secondStart)

    state.recordRunFinished(
        id: "agent-run",
        decision: .refreshed,
        finishedAt: Date(timeIntervalSince1970: 3_010),
        reportCount: 2
    )

    #expect(state.lastRun?.id == "app-run")
    #expect(state.lastRun?.decision == nil)
    #expect(state.lastSuccessfulRun == nil)
}

@Test func refreshDiagnosticsStoreUpdatePreservesSequentialFieldChanges() throws {
    let directory = try temporaryDiagnosticsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = RefreshDiagnosticsStateStore(stateURL: directory.appending(path: "refresh-diagnostics-state.json"))
    let now = Date(timeIntervalSince1970: 4_000)

    try store.update { state in
        state.recordAlertEvaluation(at: now, eventCount: 1)
    }
    try store.update { state in
        state.recordAlert(RefreshDiagnosticsAlertRecord(
            channel: .webhook,
            attemptedAt: now,
            succeededAt: now,
            eventCount: 1,
            lastHTTPStatus: 204
        ))
    }

    let loaded = store.load()
    #expect(loaded.lastAlertEvaluationEventCount == 1)
    #expect(loaded.lastWebhook?.lastHTTPStatus == 204)
}

private func temporaryDiagnosticsDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-refresh-diagnostics-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
