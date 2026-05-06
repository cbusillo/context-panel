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
    static func main() {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let authStatus = try loadAuthStatus(claudeBinary: configuration.claudeBinary)
            let statsSummary = try loadStatsSummary(path: configuration.statsPath)
            printSummary(authStatus: authStatus, statsSummary: statsSummary, statsPath: configuration.statsPath)
        } catch {
            fputs("ClaudeLimitProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func loadAuthStatus(claudeBinary: String) throws -> ClaudeAuthStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [claudeBinary, "auth", "status", "--json"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            throw ClaudeProbeError(message: "claude auth status failed; stderr redacted")
        }
        return try ClaudeAuthStatusParser.status(from: data)
    }

    private static func loadStatsSummary(path: String) throws -> ClaudeStatsCacheSummary? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: expanded))
        return try ClaudeStatsCacheParser.summary(from: data)
    }

    private static func printSummary(
        authStatus: ClaudeAuthStatus,
        statsSummary: ClaudeStatsCacheSummary?,
        statsPath: String
    ) {
        print("Claude local status probe")
        print("auth logged in: \(authStatus.loggedIn)")
        print("auth method: \(authStatus.authMethod)")
        print("api provider: \(authStatus.apiProvider ?? "unknown")")
        print("subscription type: \(authStatus.subscriptionType ?? "unknown")")
        print("stats cache: \(redactedPath(statsPath))")
        print("redacted: tokens, Keychain secrets, account identifiers, org identifiers, emails, raw transcripts, raw provider responses")
        print("")

        guard let statsSummary else {
            print("local stats cache: absent")
            print("live subscription allowance: not exposed by this probe")
            return
        }

        print("local stats cache: present")
        print("version: \(statsSummary.version.map(String.init) ?? "unknown")")
        print("last computed: \(format(date: statsSummary.lastComputedDate))")
        print("first session: \(format(date: statsSummary.firstSessionDate))")
        print("total sessions: \(statsSummary.totalSessions.map(String.init) ?? "unknown")")
        print("total messages: \(statsSummary.totalMessages.map(String.init) ?? "unknown")")
        print("model usage buckets: \(statsSummary.modelUsageCount)")
        print("daily activity buckets: \(statsSummary.dailyActivityCount)")
        print("live subscription allowance: not exposed by this probe")
    }

    private static func format(date: Date?) -> String {
        date.map { ContextPanelDateFormatting.string(from: $0) } ?? "unknown"
    }

    private static func redactedPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return URL(fileURLWithPath: expanded).lastPathComponent
    }
}
