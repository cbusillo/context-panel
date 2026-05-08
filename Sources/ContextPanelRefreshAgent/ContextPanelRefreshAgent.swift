import ContextPanelCore
import Foundation
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        let runner = SnapshotRefreshRunner.appDefault()
        let interval = Duration.seconds(5 * 60)

        while !Task.isCancelled {
            let startedAt = ContinuousClock.now
            do {
                let decision = try await runner.refreshIfNeeded()
                if case .refreshed = decision {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }

            do {
                let elapsed = startedAt.duration(to: ContinuousClock.now)
                try await Task.sleep(for: max(.zero, interval - elapsed))
            } catch {
                return
            }
        }
    }
}
