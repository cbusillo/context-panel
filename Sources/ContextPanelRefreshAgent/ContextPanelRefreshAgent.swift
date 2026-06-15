import ContextPanelCore
import Foundation
@preconcurrency import UserNotifications
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--clear-provider-credentials") {
            clearProviderCredentials()
        }
        if arguments.contains("--clear-webhook-credentials") {
            clearWebhookCredentials()
        }
        if arguments.contains("--provider-credentials-present") {
            checkProviderCredentials()
        }
        if arguments.contains("--webhook-credentials-present") {
            checkWebhookCredentials()
        }

        let runner = SnapshotRefreshRunner.appDefault()
        let warningService = LimitWarningNotificationService.appDefault()
        let settingsStore = BackgroundRefreshSettingsStore(
            settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        )
        if arguments.contains("--refresh-once") {
            do {
                let decision = try await runner.refresh()
                if decision.wasRefreshed {
                    await warningService.notifyIfNeeded(decision: decision)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }
            Foundation.exit(0)
        }

        while !Task.isCancelled {
            let startedAt = ContinuousClock.now
            let settings = settingsStore.load()
            guard settings.isEnabled else { return }

            do {
                let decision = try await runner.refreshIfNeeded()
                if decision.wasRefreshed {
                    await warningService.notifyIfNeeded(decision: decision)
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }

            do {
                let elapsed = startedAt.duration(to: ContinuousClock.now)
                let interval = Duration.seconds(settings.intervalSeconds)
                try await Task.sleep(for: max(.zero, interval - elapsed))
            } catch {
                return
            }
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
    let notificationCenter: UNUserNotificationCenter
    let webhookService: LimitWarningWebhookDeliveryService

    static func appDefault() -> LimitWarningNotificationService {
        LimitWarningNotificationService(
            settingsStore: LimitWarningSettingsStore(
                settingsURL: ContextPanelLocations.limitWarningSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            stateStore: LimitWarningStateStore(
                stateURL: ContextPanelLocations.limitWarningStateURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            notificationCenter: .current(),
            webhookService: .appDefault()
        )
    }

    func notifyIfNeeded(decision: SnapshotRefreshRunDecision) async {
        _ = await webhookService.deliverIfNeeded(decision: decision)
        guard case let .refreshed(outcome) = decision else { return }
        let settings = settingsStore.load()
        let state = stateStore.load()
        let result = LimitWarningEvaluator.evaluate(
            settings: settings,
            state: state,
            snapshot: outcome.refreshResult.snapshot,
            now: outcome.savedAt
        )
        guard result.state != state else {
            return
        }
        if !result.events.isEmpty {
            guard await notificationsAreAuthorized() else { return }
        }
        do {
            try stateStore.save(result.state)
        } catch {
            fputs("ContextPanelRefreshAgent: limit warning state save failed: \(error.localizedDescription)\n", stderr)
        }
        guard !result.events.isEmpty else { return }
        for event in result.events {
            await deliver(event: event, playsSound: settings.playsSound)
        }
    }

    private func notificationsAreAuthorized() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func deliver(event: LimitWarningEvent, playsSound: Bool) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        if playsSound {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: "context-panel-limit-warning-\(event.laneID)",
            content: content,
            trigger: nil
        )
        do {
            try await notificationCenter.add(request)
        } catch {
            fputs("ContextPanelRefreshAgent: limit warning notification failed: \(error.localizedDescription)\n", stderr)
        }
    }
}

private extension SnapshotRefreshRunDecision {
    var wasRefreshed: Bool {
        if case .refreshed = self { return true }
        return false
    }
}
