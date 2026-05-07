import ContextPanelCore
import Foundation

struct CodexProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProbeConfiguration {
    let authPath: String
    let endpoint: URL

    static func fromArguments(_ arguments: [String]) throws -> ProbeConfiguration {
        var authPath: String?
        var endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--auth":
                guard let value = iterator.next() else {
                    throw CodexProbeError(message: "--auth requires a path")
                }
                authPath = value
            case "--endpoint":
                guard let value = iterator.next(), let url = URL(string: value) else {
                    throw CodexProbeError(message: "--endpoint requires an absolute URL")
                }
                endpoint = url
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw CodexProbeError(message: "unknown argument: \(argument)")
            }
        }

        return ProbeConfiguration(
            authPath: authPath ?? defaultAuthPath(),
            endpoint: endpoint
        )
    }

    private static func defaultAuthPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let codexHome = environment["CODEX_HOME"] ?? "\(home)/.codex"
        return "\(codexHome)/auth.json"
    }

    private static func printHelp() {
        print("""
        Usage: swift run CodexRateLimitProbe [--auth /path/to/auth.json] [--endpoint URL]

        Calls the live Codex usage endpoint directly and prints only a redacted
        summary of limit buckets, windows, plan type, and credits. Tokens,
        account identifiers, emails, headers, and raw response bodies are never
        printed.
        """)
    }
}

@main
struct CodexRateLimitProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let connector = CodexRateLimitConnector(accounts: [
                CodexAccountConfiguration(authPath: configuration.authPath, endpoint: configuration.endpoint)
            ])
            let result = await connector.refresh(now: Date())
            printSummary(result: result, endpoint: configuration.endpoint, authPath: configuration.authPath)
        } catch {
            fputs("CodexRateLimitProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printSummary(result: ConnectorRefreshResult, endpoint: URL, authPath: String) {
        print("Codex live usage endpoint probe")
        print("endpoint: \(endpoint.absoluteString)")
        print("auth: \(redactedAuthPath(authPath))")
        print("accounts: \(result.reports.count)")
        print("limits: \(result.snapshot.limits.count)")
        print("redacted: tokens, account identifiers, emails, headers, raw response bodies")
        print("")

        for report in result.reports {
            print("- \(report.accountName): \(report.status.rawValue)")
            if let errorMessage = report.errorMessage {
                print("  error: \(errorMessage)")
            }
            for limit in report.limits {
                print("  - \(limit.label): \(format(limit: limit))")
            }
        }
    }

    private static func format(limit: UsageLimit) -> String {
        let used = limit.used.map { "\($0)% used" } ?? "unknown used"
        let reset = limit.resetsAt.map { ContextPanelDateFormatting.string(from: $0) } ?? "unknown reset"
        return "\(used) / resets \(reset)"
    }

    private static func redactedAuthPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return URL(fileURLWithPath: expanded).lastPathComponent
    }
}
