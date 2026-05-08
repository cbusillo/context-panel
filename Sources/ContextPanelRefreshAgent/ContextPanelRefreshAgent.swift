import ContextPanelCore
import Foundation
import WidgetKit

@main
struct ContextPanelRefreshAgent {
    static func main() async {
        let runner = SnapshotRefreshRunner.appDefault()

        while !Task.isCancelled {
            do {
                let decision = try await runner.refreshIfNeeded()
                if case .refreshed = decision {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            } catch {
                fputs("ContextPanelRefreshAgent: \(ConnectorRedactor.redact(error.localizedDescription))\n", stderr)
            }

            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                return
            }
        }
    }
}
