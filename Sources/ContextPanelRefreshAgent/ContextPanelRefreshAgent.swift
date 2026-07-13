import ContextPanelCore
import ContextPanelCloudKitSync
@preconcurrency import AppKit
import Darwin
import Foundation
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        var lastWidgetTimelineReloadAt: Date?
        let arguments = ProcessInfo.processInfo.arguments
        let utilityArguments = Array(arguments.dropFirst())
        let recognizedUtilityArguments = utilityArguments.filter {
            [
                "--clear-provider-credentials",
                "--clear-webhook-credentials",
                "--provider-credentials-present",
                "--webhook-credentials-present",
                "--ingest-antigravity-status-line",
            ].contains($0)
        }
        if !recognizedUtilityArguments.isEmpty {
            guard utilityArguments.count == 1, let utilityArgument = recognizedUtilityArguments.first else {
                fputs("ContextPanelRefreshAgent: invalid utility arguments\n", stderr)
                Foundation.exit(64)
            }
            switch utilityArgument {
            case "--clear-provider-credentials":
                clearProviderCredentials()
            case "--clear-webhook-credentials":
                clearWebhookCredentials()
            case "--provider-credentials-present":
                checkProviderCredentials()
            case "--webhook-credentials-present":
                checkWebhookCredentials()
            case "--ingest-antigravity-status-line":
                ingestAntigravityStatusLine()
            default:
                Foundation.exit(64)
            }
        }

        let runner = SnapshotRefreshRunner(service: .appDefault(
            companionRemoteStore: CompanionCloudKitSyncStoreFactory.make()
        ))
        let warningService = LimitWarningNotificationService.appDefault()
        let diagnosticsStore = RefreshDiagnosticsStateStore(
            stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
        )
        let settingsStore = BackgroundRefreshSettingsStore(
            settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        )
        if arguments.contains("--refresh-once") {
            let startedAt = Date()
            let runID = recordRefreshStarted(diagnosticsStore, source: .refreshAgent, startedAt: startedAt)
            do {
                let decision = try await runner.refresh()
                recordRefreshFinished(diagnosticsStore, runID: runID, decision: decision, finishedAt: Date())
                reloadContextPanelWidgetTimeline(
                    force: decision.wasRefreshed,
                    lastReloadAt: &lastWidgetTimelineReloadAt
                )
                if decision.wasRefreshed {
                    notifyContextPanelWidgetSnapshotUpdated()
                    await warningService.notifyIfNeeded(decision: decision)
                }
            } catch {
                recordRefreshFailed(diagnosticsStore, runID: runID, finishedAt: Date(), error: error)
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }
            Foundation.exit(0)
        }

        while !Task.isCancelled {
            let wallStartedAt = Date()
            let settings = settingsStore.load()
            guard settings.isEnabled else { return }
            let runID = recordRefreshStarted(
                diagnosticsStore,
                source: .refreshAgent,
                startedAt: wallStartedAt,
                intervalSeconds: settings.intervalSeconds
            )

            do {
                let decision = try await runner.refreshIfNeeded()
                recordRefreshFinished(diagnosticsStore, runID: runID, decision: decision, finishedAt: Date())
                reloadContextPanelWidgetTimeline(
                    force: decision.wasRefreshed,
                    lastReloadAt: &lastWidgetTimelineReloadAt
                )
                if decision.wasRefreshed {
                    notifyContextPanelWidgetSnapshotUpdated()
                    await warningService.notifyIfNeeded(decision: decision)
                }
            } catch {
                recordRefreshFailed(diagnosticsStore, runID: runID, finishedAt: Date(), error: error)
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }

            do {
                let sleepInterval = SnapshotRefreshRunner.nextRefreshCheckInterval(
                    normalInterval: TimeInterval(settings.intervalSeconds),
                    nextCheckDate: runner.nextRefreshCheckDate(now: Date()),
                    startedAt: wallStartedAt,
                    finishedAt: Date()
                )
                try await Task.sleep(for: .seconds(sleepInterval))
            } catch {
                return
            }
        }
    }

    private static func recordRefreshStarted(
        _ store: RefreshDiagnosticsStateStore,
        source: RefreshDiagnosticsSource,
        startedAt: Date,
        intervalSeconds: Int? = nil
    ) -> String {
        let runID = UUID().uuidString
        try? store.update { state in
            state.recordRunStarted(id: runID, source: source, at: startedAt, intervalSeconds: intervalSeconds)
        }
        return runID
    }

    private static func ingestAntigravityStatusLine() -> Never {
        guard let snapshotURL = ContextPanelLocations.googleAntigravityStatusLineSnapshotURL() else {
            print(GoogleAntigravityStatusLineBridge.failureStatusLineText)
            Foundation.exit(0)
        }

        do {
            let data = try boundedStandardInput(maximumBytes: GoogleAntigravityStatusLineBridge.maximumInputBytes)
            let result = try GoogleAntigravityStatusLineBridge.ingest(
                data: data,
                store: GoogleAntigravityStatusLineSnapshotStore(snapshotURL: snapshotURL)
            )
            print(GoogleAntigravityStatusLineBridge.statusLineText(for: result))
        } catch {
            print(GoogleAntigravityStatusLineBridge.failureStatusLineText)
        }
        Foundation.exit(0)
    }

    private static func boundedStandardInput(
        maximumBytes: Int,
        timeout: TimeInterval = 2
    ) throws -> Data {
        let descriptor = STDIN_FILENO
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0,
              fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0
        else {
            throw POSIXError(.EIO)
        }
        defer { _ = fcntl(descriptor, F_SETFL, originalFlags) }

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let remainingMilliseconds = max(Int(deadline.timeIntervalSinceNow * 1_000), 0)
            guard remainingMilliseconds > 0 else {
                throw POSIXError(.ETIMEDOUT)
            }
            let pollResult = Darwin.poll(&pollDescriptor, 1, Int32(min(remainingMilliseconds, Int(Int32.max))))
            if pollResult == 0 {
                throw POSIXError(.ETIMEDOUT)
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }

            var buffer = [UInt8](repeating: 0, count: min(8_192, remaining))
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 {
                return data
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        throw GoogleAntigravityStatusLineBridgeError.oversizedInput
    }

    private static func reloadContextPanelWidgetTimeline(
        force: Bool,
        lastReloadAt: inout Date?,
        now: Date = Date()
    ) {
        if !force,
           let lastReloadAt,
           now.timeIntervalSince(lastReloadAt) < SnapshotFreshness.widgetTimelineInterval {
            return
        }
        lastReloadAt = now
        WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelWidgetIdentity.kind)
    }

    private static func notifyContextPanelWidgetSnapshotUpdated() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(ContextPanelWidgetRefreshWakeup.distributedNotificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private static func recordRefreshFinished(
        _ store: RefreshDiagnosticsStateStore,
        runID: String,
        decision: SnapshotRefreshRunDecision,
        finishedAt: Date
    ) {
        try? store.update { state in
            state.recordRunFinished(
                id: runID,
                decision: decision.diagnosticsDecision,
                finishedAt: finishedAt,
                reportCount: decision.diagnosticsReportCount,
                failureCount: decision.diagnosticsFailureCount,
                limitCount: decision.diagnosticsLimitCount,
                savedSnapshotAt: decision.diagnosticsSavedSnapshotAt
            )
        }
    }

    private static func recordRefreshFailed(
        _ store: RefreshDiagnosticsStateStore,
        runID: String,
        finishedAt: Date,
        error: Error
    ) {
        try? store.update { state in
            state.recordRunFinished(
                id: runID,
                decision: .failed,
                finishedAt: finishedAt,
                errorMessage: error.localizedDescription
            )
        }
    }

    private static func clearProviderCredentials() -> Never {
        do {
            try ProviderCredentialStore().deleteAll()
            print("Context Panel provider credentials cleared")
            Foundation.exit(0)
        } catch {
            fputs("ContextPanelRefreshAgent: provider credential cleanup failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func checkProviderCredentials() -> Never {
        do {
            if try ProviderCredentialStore().containsAny() {
                print("Context Panel provider credentials are present")
                Foundation.exit(10)
            }
            print("Context Panel provider credentials are absent")
            Foundation.exit(0)
        } catch {
            fputs("ContextPanelRefreshAgent: provider credential check failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func clearWebhookCredentials() -> Never {
        do {
            try LimitWarningWebhookSecretStore().deleteWebhookURL()
            print("Context Panel webhook credentials cleared")
            Foundation.exit(0)
        } catch {
            fputs("ContextPanelRefreshAgent: webhook credential cleanup failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func checkWebhookCredentials() -> Never {
        do {
            if try LimitWarningWebhookSecretStore().loadWebhookURL() != nil {
                print("Context Panel webhook credentials are present")
                Foundation.exit(10)
            }
            print("Context Panel webhook credentials are absent")
            Foundation.exit(0)
        } catch {
            fputs("ContextPanelRefreshAgent: webhook credential check failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct LimitWarningNotificationService {
    let settingsStore: LimitWarningSettingsStore
    let stateStore: LimitWarningStateStore
    let pendingNotificationStore: LimitWarningPendingNotificationStore
    let webhookService: LimitWarningWebhookDeliveryService
    let diagnosticsStore: RefreshDiagnosticsStateStore

    static func appDefault() -> LimitWarningNotificationService {
        LimitWarningNotificationService(
            settingsStore: LimitWarningSettingsStore(
                settingsURL: ContextPanelLocations.limitWarningSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            stateStore: LimitWarningStateStore(
                stateURL: ContextPanelLocations.limitWarningStateURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            pendingNotificationStore: LimitWarningPendingNotificationStore(
                queueURL: ContextPanelLocations.limitWarningPendingNotificationsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            webhookService: .appDefault(),
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
            )
        )
    }

    func notifyIfNeeded(decision: SnapshotRefreshRunDecision) async {
        let webhookResults = await webhookService.deliverIfNeeded(decision: decision)
        recordWebhookDiagnostics(webhookResults, attemptedAt: Date())
        guard case let .refreshed(outcome) = decision else { return }
        let settings = settingsStore.load()
        let state = stateStore.load()
        let warningSnapshot = LimitWarningSnapshotResolver.effectiveSnapshot(
            transientSnapshot: outcome.refreshResult.snapshot,
            persistedSnapshot: loadPersistedSnapshot()
        )
        let result = LimitWarningEvaluator.evaluate(
            settings: settings,
            state: state,
            snapshot: warningSnapshot,
            now: outcome.savedAt
        )
        recordAlertEvaluation(at: outcome.savedAt, eventCount: result.events.count)
        let commitPlan = LimitWarningNotificationCommitPlan(
            currentState: state,
            targetState: result.state,
            snapshot: warningSnapshot,
            settings: settings
        )
        guard commitPlan.hasPendingChanges else {
            return
        }
        if commitPlan.hasPersistedStateChanges {
            do {
                try stateStore.save(commitPlan.persistedState)
            } catch {
                fputs("ContextPanelRefreshAgent: limit warning state save failed: \(error.localizedDescription)\n", stderr)
            }
        }
        if result.events.isEmpty {
            return
        }

        do {
            let notifications = result.events.map { event in
                LimitWarningPendingNotification(event: event, queuedAt: outcome.savedAt, playsSound: settings.playsSound)
            }
            try pendingNotificationStore.append(notifications)
            recordLocalNotificationDiagnostics(
                attemptedAt: outcome.savedAt,
                succeededAt: nil,
                eventCount: notifications.count,
                errorMessage: nil
            )
            await wakeMainAppForPendingNotifications()
        } catch {
            recordLocalNotificationDiagnostics(
                attemptedAt: outcome.savedAt,
                succeededAt: nil,
                eventCount: result.events.count,
                errorMessage: error.localizedDescription
            )
            fputs("ContextPanelRefreshAgent: limit warning queue failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func recordAlertEvaluation(at evaluatedAt: Date, eventCount: Int) {
        try? diagnosticsStore.update { state in
            state.recordAlertEvaluation(at: evaluatedAt, eventCount: eventCount)
        }
    }

    private func recordWebhookDiagnostics(_ results: [LimitWarningWebhookDeliveryResult], attemptedAt: Date) {
        guard !results.isEmpty else { return }
        let succeeded = results.contains(where: \.succeeded)
        let latestStatus = results.reversed().compactMap(\.statusCode).first
        let latestError = results.reversed().compactMap(\.errorMessage).first
        try? diagnosticsStore.update { state in
            state.recordAlert(RefreshDiagnosticsAlertRecord(
                channel: .webhook,
                attemptedAt: attemptedAt,
                succeededAt: succeeded ? attemptedAt : nil,
                eventCount: results.count,
                lastHTTPStatus: latestStatus,
                errorMessage: latestError
            ))
        }
    }

    private func recordLocalNotificationDiagnostics(
        attemptedAt: Date,
        succeededAt: Date?,
        eventCount: Int,
        errorMessage: String?
    ) {
        try? diagnosticsStore.update { state in
            state.recordAlert(RefreshDiagnosticsAlertRecord(
                channel: .localNotification,
                attemptedAt: attemptedAt,
                succeededAt: succeededAt,
                eventCount: eventCount,
                errorMessage: errorMessage
            ))
        }
    }

    private func wakeMainAppForPendingNotifications() async {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(LimitWarningNotificationWakeup.distributedNotificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        await launchMainAppForPendingNotifications()
    }

    private func launchMainAppForPendingNotifications() async {
        guard let appURL = mainAppURLForPendingNotifications() else {
            fputs("ContextPanelRefreshAgent: Context Panel app could not be located for pending limit warnings\n", stderr)
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    fputs("ContextPanelRefreshAgent: Context Panel app launch failed for pending limit warnings: \(error.localizedDescription)\n", stderr)
                }
                continuation.resume()
            }
        }
    }

    private func mainAppURLForPendingNotifications() -> URL? {
        containingMainAppURL() ?? canonicalInstalledMainAppURL()
    }

    private func containingMainAppURL() -> URL? {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return isContextPanelApp(at: appURL) ? appURL : nil
    }

    private func canonicalInstalledMainAppURL() -> URL? {
        let appURL = URL(fileURLWithPath: "/Applications/Context Panel.app", isDirectory: true)
        return isContextPanelApp(at: appURL) ? appURL : nil
    }

    private func isContextPanelApp(at url: URL) -> Bool {
        guard url.lastPathComponent == "Context Panel.app" else { return false }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return Bundle(url: url)?.bundleIdentifier == ContextPanelLocations.appBundleID
    }

    private func loadPersistedSnapshot() -> StoredUsageSnapshot? {
        JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        ).loadCurrent().snapshot
    }
}

private extension SnapshotRefreshRunDecision {
    var wasRefreshed: Bool {
        if case .refreshed = self { return true }
        return false
    }
}
