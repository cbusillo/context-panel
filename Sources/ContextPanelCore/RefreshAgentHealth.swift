import Foundation

/// Background-only login items are not represented by AppKit's running-app list.
/// The helper's own wake record also catches a process that stopped doing work.
public enum RefreshAgentHealth {
    public static let schedulingAllowance: TimeInterval = 60

    public static func hasRecentWake(
        state: RefreshDiagnosticsState,
        intervalSeconds: Int,
        now: Date
    ) -> Bool {
        guard let run = latestRun(state: state) else {
            return false
        }
        let age = now.timeIntervalSince(run.finishedAt ?? run.startedAt)
        let expectedInterval = max(intervalSeconds, run.intervalSeconds ?? intervalSeconds)
        return age >= 0 && age <= TimeInterval(expectedInterval) + schedulingAllowance
    }

    public static func latestRun(state: RefreshDiagnosticsState) -> RefreshDiagnosticsRun? {
        [state.lastAgentRun, state.lastRun, state.lastSuccessfulRun]
            .compactMap { $0 }
            .filter { $0.source == .refreshAgent }
            .max(by: { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) })
    }

    /// An app update does not stop a running login item, so the helper can outlive
    /// the bundle it was launched from. A run recorded before helpers reported a
    /// version counts as a different build.
    public static func latestRunIsFromDifferentBuild(
        state: RefreshDiagnosticsState,
        appBundleVersion: String?
    ) -> Bool {
        guard let appBundleVersion, let run = latestRun(state: state) else { return false }
        return run.agentBundleVersion != appBundleVersion
    }
}
