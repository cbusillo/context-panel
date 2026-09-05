import ContextPanelCore
import Foundation

@main
struct PromptCacheTelemetryMirror {
    static func main() throws {
        let destination = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID)
        let result = try PromptCacheTelemetryMirrorService.mirror(
            sourceDirectories: ContextPanelLocations.codexTelemetryDirectories()
                + ContextPanelLocations.everyCodeUsageDirectories(),
            destination: destination
        )

        print("mirrored prompt-cache usage files: \(result.copied)")
        print("removed stale prompt-cache mirrors: \(result.removed)")
        print("destination: \(ConnectorRedactor.redactedPath(destination.path))")
    }
}
