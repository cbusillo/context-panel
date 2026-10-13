import Foundation
import Testing

@testable import ContextPanelCore

@Test func refreshAgentWakeSurvivesManualRefreshAndConcurrentCompletion() {
    let start = Date(timeIntervalSince1970: 1_000)
    var state = RefreshDiagnosticsState.empty
    state.recordRunStarted(id: "agent", source: .refreshAgent, at: start, intervalSeconds: 300)
    state.recordRunStarted(id: "manual", source: .app, at: start.addingTimeInterval(2))
    state.recordRunFinished(id: "manual", decision: .refreshed, finishedAt: start.addingTimeInterval(3))
    state.recordRunFinished(id: "agent", decision: .skippedFresh, finishedAt: start.addingTimeInterval(5))

    #expect(state.lastRun?.id == "manual")
    #expect(state.lastSuccessfulRun?.id == "manual")
    #expect(state.lastAgentRun?.decision == .skippedFresh)
    #expect(state.lastAgentRun?.finishedAt == start.addingTimeInterval(5))
    #expect(RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: start.addingTimeInterval(310)))
    #expect(!RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: start.addingTimeInterval(400)))
}

@Test func refreshAgentHealthRequiresAgentEvidenceAndRejectsFutureOrOldWake() {
    let now = Date(timeIntervalSince1970: 2_000)
    var state = RefreshDiagnosticsState.empty
    state.recordRunStarted(id: "manual", source: .app, at: now)
    state.recordRunFinished(id: "manual", decision: .refreshed, finishedAt: now)
    #expect(!RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: now))

    state.recordRunStarted(id: "agent", source: .refreshAgent, at: now, intervalSeconds: 300)
    #expect(RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: now))
    #expect(!RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: now.addingTimeInterval(-1)))
    #expect(!RefreshAgentHealth.hasRecentWake(
        state: state, intervalSeconds: 300,
        now: now.addingTimeInterval(300 + RefreshAgentHealth.schedulingAllowance + 1)
    ))
}

@Test func refreshAgentHealthHonorsTheSleepingAgentsPreviousInterval() {
    let now = Date(timeIntervalSince1970: 3_000)
    var state = RefreshDiagnosticsState.empty
    state.recordRunStarted(id: "agent", source: .refreshAgent, at: now, intervalSeconds: 900)
    #expect(RefreshAgentHealth.hasRecentWake(state: state, intervalSeconds: 300, now: now.addingTimeInterval(600)))
    #expect(!RefreshAgentHealth.hasRecentWake(
        state: state, intervalSeconds: 300,
        now: now.addingTimeInterval(900 + RefreshAgentHealth.schedulingAllowance + 1)
    ))
}

@Test func refreshAgentWakeRoundTripsAndOlderDiagnosticsStillLoad() throws {
    let now = Date(timeIntervalSince1970: 4_000)
    var state = RefreshDiagnosticsState.empty
    state.recordRunStarted(id: "agent", source: .refreshAgent, at: now, intervalSeconds: 300)
    state.recordRunStarted(id: "manual", source: .app, at: now.addingTimeInterval(1))
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(state)
    #expect(try decoder.decode(RefreshDiagnosticsState.self, from: data) == state)

    // Existing installations have a shared run but no separate agent record.
    var legacy = RefreshDiagnosticsState.empty
    legacy.recordRunStarted(id: "agent", source: .refreshAgent, at: now, intervalSeconds: 300)
    var payload = try #require(JSONSerialization.jsonObject(with: encoder.encode(legacy)) as? [String: Any])
    payload.removeValue(forKey: "lastAgentRun")
    let loaded = try decoder.decode(RefreshDiagnosticsState.self, from: JSONSerialization.data(withJSONObject: payload))
    #expect(loaded.lastAgentRun == nil)
    #expect(RefreshAgentHealth.hasRecentWake(state: loaded, intervalSeconds: 300, now: now))
}
