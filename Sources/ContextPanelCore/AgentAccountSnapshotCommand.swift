import Foundation

/// Shared by the installed app's headless mode and the SwiftPM developer tool.
public enum AgentAccountSnapshotCommand {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    public static func run(arguments: [String], now: Date = Date()) -> Result {
        if arguments == ["--help"] {
            return Result(exitCode: 0, standardOutput: Data(
                """
                usage: ContextPanelAccountSnapshot [--storage-root <Context Panel storage directory>]
                installed app: "/Applications/Context Panel.app/Contents/MacOS/Context Panel" --account-snapshot [--storage-root <Context Panel storage directory>]

                """.utf8
            ), standardError: Data())
        }

        let root: URL
        if arguments.isEmpty {
            root = ContextPanelLocations.realUserHomeDirectory()
                .appending(path: "Library/Group Containers")
                .appending(path: ContextPanelLocations.appGroupID)
                .appending(path: "Context Panel")
        } else if arguments.count == 2, arguments[0] == "--storage-root" {
            root = URL(fileURLWithPath: NSString(string: arguments[1]).expandingTildeInPath)
        } else {
            return Result(exitCode: 64, standardOutput: Data(),
                standardError: Data("Invalid arguments; use --help.\n".utf8))
        }

        do {
            let projection = try AgentAccountSnapshot.read(rootDirectory: root, now: now)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(projection)
            data.append(0x0A)
            return Result(exitCode: 0, standardOutput: data, standardError: Data())
        } catch {
            // Decoder and filesystem errors may contain private paths or values.
            return Result(exitCode: 1, standardOutput: Data(), standardError: Data(
                "Account snapshot unavailable or unsupported; check the publisher's storage and refresh.\n".utf8
            ))
        }
    }
}
