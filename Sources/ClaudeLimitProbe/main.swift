import ContextPanelCore
import Foundation

struct ClaudeProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProbeConfiguration {
    let claudeBinary: String
    let statsPath: String

    static func fromArguments(_ arguments: [String]) throws -> ProbeConfiguration {
        var claudeBinary = "claude"
        var statsPath: String?
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--claude-bin":
                guard let value = iterator.next() else {
                    throw ClaudeProbeError(message: "--claude-bin requires a path or executable name")
                }
                claudeBinary = value
            case "--stats":
                guard let value = iterator.next() else {
                    throw ClaudeProbeError(message: "--stats requires a path")
                }
                statsPath = value
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw ClaudeProbeError(message: "unknown argument: \(argument)")
            }
        }

        return ProbeConfiguration(
            claudeBinary: claudeBinary,
            statsPath: statsPath ?? defaultStatsPath()
        )
    }

    private static func defaultStatsPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude/stats-cache.json"
    }

    private static func printHelp() {
        print("""
        Usage: swift run ClaudeLimitProbe [--claude-bin claude] [--stats ~/.claude/stats-cache.json]

        Prints a redacted Claude local status summary. This probe intentionally
        does not read Keychain secrets, token files, raw transcripts, emails,
        account IDs, org IDs, or provider response bodies.
        """)
    }
}

@main
struct ClaudeLimitProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let connector = ClaudeLocalStatusConnector(accounts: [
                ClaudeAccountConfiguration(
                    claudeBinary: configuration.claudeBinary,
                    statsPath: configuration.statsPath
                )
            ])
            let result = await connector.refresh(now: Date())
            printSummary(result: result, statsPath: configuration.statsPath)
        } catch {
            fputs("ClaudeLimitProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printSummary(result: ConnectorRefreshResult, statsPath: String) {
        print("Claude local status probe")
        print("stats cache: \(ConnectorRedactor.redactedPath(statsPath))")
        print("accounts: \(result.reports.count)")
        print("limits: \(result.snapshot.limits.count)")
        print("redacted: tokens, Keychain secrets, account identifiers, org identifiers, emails, raw transcripts, raw provider responses")
        print("")

        for report in result.reports {
            print("- \(report.accountName): \(report.status.rawValue)")
            if let errorMessage = report.errorMessage {
                print("  error: \(errorMessage)")
            }
            for limit in report.limits {
                print("  - \(limit.label): \(limit.status.rawValue)")
                if let note = limit.note {
                    print("    \(note)")
                }
            }
        }
        print("official non-interactive subscription percentage: not exposed by Claude Code")
        print("Every Code estimate: shown when ccusage aggregate block data is available")
    }
}
