import ContextPanelCore
import Foundation
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--clear-provider-credentials") {
            clearProviderCredentials()
        }
        if arguments.contains("--provider-credentials-present") {
            checkProviderCredentials()
        }

        let runner = SnapshotRefreshRunner.appDefault()
        let settingsStore = BackgroundRefreshSettingsStore(
            settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        )
        if arguments.contains("--refresh-once") {
            do {
                let decision = try await runner.refresh()
                if decision.wasRefreshed {
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
}

private extension SnapshotRefreshRunDecision {
    var wasRefreshed: Bool {
        if case .refreshed = self { return true }
        return false
    }
}
