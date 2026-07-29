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
        if let codeHome = environment["CODE_HOME"], !codeHome.isEmpty {
            return "\(codeHome)/auth_accounts.json"
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return "\(codexHome)/auth.json"
        }
        return "\(home)/.code/auth_accounts.json"
    }

    private static func printHelp() {
        print("""
        Usage: swift run CodexRateLimitProbe [--auth /path/to/auth.json] [--endpoint URL]

        Calls the GET-only Codex usage endpoint and, for a positive count, its
        sibling reset-credit details endpoint. Output is limited to account
        index, count, detail coverage, and earliest known expiry. Account
        identities and raw provider metadata are never printed.
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
            printSummary(result: result)
        } catch {
            fputs("CodexRateLimitProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printSummary(result: ConnectorRefreshResult) {
        for (index, report) in result.reports.enumerated() {
            let count = report.resetCredits.map { String($0.availableCount) } ?? "unknown"
            let coverage = report.resetCredits?.coverage.rawValue ?? "unknown"
            let expiry = report.resetCredits?.earliestKnownExpiry
                .map(ContextPanelDateFormatting.string(from:)) ?? "unknown"
            print("account \(index + 1): count=\(count) coverage=\(coverage) earliest_expiry=\(expiry)")
        }
    }
}
