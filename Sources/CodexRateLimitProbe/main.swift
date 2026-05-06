import ContextPanelCore
import Foundation

struct CodexProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct AuthFile: Decodable {
    let tokens: TokenData?
}

struct TokenData: Decodable {
    let accessToken: String
    let accountID: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountID = "account_id"
        case idToken = "id_token"
    }
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
            let auth = try loadAuth(path: configuration.authPath)
            let data = try await fetchUsage(endpoint: configuration.endpoint, auth: auth)
            let snapshots = try CodexUsagePayloadParser.snapshots(from: data)
            printSummary(snapshots: snapshots, endpoint: configuration.endpoint, authPath: configuration.authPath)
        } catch {
            fputs("CodexRateLimitProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func loadAuth(path: String) throws -> TokenData {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let auth = try JSONDecoder().decode(AuthFile.self, from: data)
        guard let tokens = auth.tokens, !tokens.accessToken.isEmpty else {
            throw CodexProbeError(message: "auth file does not contain ChatGPT token auth")
        }
        return tokens
    }

    private static func fetchUsage(endpoint: URL, auth: TokenData) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountID = auth.accountID ?? accountID(fromIDToken: auth.idToken) {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexProbeError(message: "usage endpoint returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CodexProbeError(message: "usage endpoint returned HTTP \(http.statusCode); raw body redacted")
        }
        return data
    }

    private static func accountID(fromIDToken token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard
            let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = object["https://api.openai.com/auth"] as? [String: Any]
        else {
            return nil
        }
        return auth["chatgpt_account_id"] as? String
    }

    private static func printSummary(snapshots: [CodexRateLimitSnapshot], endpoint: URL, authPath: String) {
        print("Codex live usage endpoint probe")
        print("endpoint: \(endpoint.absoluteString)")
        print("auth: \(redactedAuthPath(authPath))")
        print("snapshots: \(snapshots.count)")
        print("redacted: tokens, account identifiers, emails, headers, raw response bodies")
        print("")

        for snapshot in snapshots {
            print("- \(snapshot.displayName) [\(snapshot.id)]")
            print("  plan: \(snapshot.planType)")
            print("  primary: \(format(window: snapshot.primary))")
            print("  secondary: \(format(window: snapshot.secondary))")
            if let credits = snapshot.credits {
                print("  credits: has=\(credits.hasCredits) unlimited=\(credits.unlimited) balance=\(credits.balance ?? "nil")")
            }
            if let reached = snapshot.rateLimitReachedType {
                print("  reached: \(reached.rawValue)")
            }
        }
    }

    private static func format(window: CodexRateLimitWindow?) -> String {
        guard let window else { return "none" }
        let percent = String(format: "%.0f%%", window.usedPercent)
        let duration = window.windowMinutes.map { "\($0)m" } ?? "unknown window"
        let reset = window.resetsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown reset"
        return "\(percent) used / \(duration) / resets \(reset)"
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

