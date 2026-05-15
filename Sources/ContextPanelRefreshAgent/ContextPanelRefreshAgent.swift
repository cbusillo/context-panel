import ContextPanelCore
import Foundation
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        let runner = SnapshotRefreshRunner.appDefault()
        let settingsStore = BackgroundRefreshSettingsStore(
            settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        )
        if ProcessInfo.processInfo.arguments.contains("--refresh-once") {
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
}

private extension SnapshotRefreshRunDecision {
    var wasRefreshed: Bool {
        if case .refreshed = self { return true }
        return false
    }
}
