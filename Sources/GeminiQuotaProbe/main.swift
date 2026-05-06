import ContextPanelCore
import Foundation

struct GeminiProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
struct ProbeConfiguration {
    let account: GeminiAccountConfiguration

    static func fromArguments(_ arguments: [String]) throws -> ProbeConfiguration {
        var authPath: String?
        var tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
        var codeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!
        var metadata = GeminiOAuthClientMetadataDiscovery.discover()
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--auth":
                guard let value = iterator.next() else {
                    throw GeminiProbeError(message: "--auth requires a path")
                }
                authPath = value
            case "--token-endpoint":
                guard let value = iterator.next(), let url = URL(string: value) else {
                    throw GeminiProbeError(message: "--token-endpoint requires an absolute URL")
                }
                tokenEndpoint = url
            case "--code-assist-endpoint":
                guard let value = iterator.next(), let url = URL(string: value) else {
                    throw GeminiProbeError(message: "--code-assist-endpoint requires an absolute URL")
                }
                codeAssistEndpoint = url
            case "--client-id":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw GeminiProbeError(message: "--client-id requires a value")
                }
                metadata = GeminiOAuthClientMetadata(
                    clientID: value,
                    clientSecret: metadata?.clientSecret ?? ""
                )
            case "--client-secret":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw GeminiProbeError(message: "--client-secret requires a value")
                }
                metadata = GeminiOAuthClientMetadata(
                    clientID: metadata?.clientID ?? "",
                    clientSecret: value
                )
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw GeminiProbeError(message: "unknown argument: \(argument)")
            }
        }

        guard let metadata, !metadata.clientID.isEmpty, !metadata.clientSecret.isEmpty else {
            throw GeminiProbeError(message: "install Gemini CLI, set GEMINI_OAUTH_CLIENT_ID/SECRET, or pass --client-id/--client-secret")
        }

        return ProbeConfiguration(account: GeminiAccountConfiguration(
            authPath: authPath ?? defaultAuthPath(),
            tokenEndpoint: tokenEndpoint,
            codeAssistEndpoint: codeAssistEndpoint,
            clientID: metadata.clientID,
            clientSecret: metadata.clientSecret
        ))
    }

    private static func defaultAuthPath() -> String {
        let environment = ProcessInfo.processInfo.environment
        let home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let geminiHome = environment["GEMINI_CLI_HOME"] ?? "\(home)/.gemini"
        return "\(geminiHome)/oauth_creds.json"
    }

    private static func printHelp() {
        print("""
        Usage: swift run GeminiQuotaProbe [--auth /path/to/oauth_creds.json]

        Uses the locally installed Gemini CLI OAuth client metadata when
        available. You can also set GEMINI_OAUTH_CLIENT_ID and
        GEMINI_OAUTH_CLIENT_SECRET, or pass --client-id and --client-secret.
        Do not commit OAuth client values to this repository.

        Uses the production Gemini Code Assist connector and prints only a
        redacted quota summary. Tokens, account identifiers, project IDs,
        emails, headers, and raw response bodies are never printed.
        """)
    }
}

@main
struct GeminiQuotaProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let connector = GeminiCodeAssistConnector(accounts: [configuration.account])
            let result = await connector.refresh(now: Date())
            printSummary(result: result, account: configuration.account)
        } catch {
            fputs("GeminiQuotaProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func printSummary(result: ConnectorRefreshResult, account: GeminiAccountConfiguration) {
        print("Gemini Code Assist quota probe")
        print("endpoint: \(account.codeAssistEndpoint.absoluteString)")
        print("auth: \(ConnectorRedactor.redactedPath(account.authPath))")
        print("accounts: \(result.reports.count)")
        print("limits: \(result.snapshot.limits.count)")
        print("redacted: tokens, account identifiers, project IDs, emails, headers, raw response bodies")
        print("")

        for report in result.reports {
            print("- \(report.accountName): \(report.status.rawValue)")
            if let errorMessage = report.errorMessage {
                print("  error: \(errorMessage)")
            }
            for limit in report.limits.sorted(by: { $0.label < $1.label }) {
                let used = limit.used.map { "\($0)% used" } ?? "unknown used"
                let remaining = limit.remaining.map { "\($0)% remaining" } ?? "unknown remaining"
                let reset = limit.resetsAt.map { ContextPanelDateFormatting.string(from: $0) } ?? "unknown reset"
                print("  - \(limit.label): \(used), \(remaining), resets \(reset)")
            }
        }
    }
}
