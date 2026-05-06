import ContextPanelCore
import Foundation

struct GeminiProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct GeminiOAuthCredentials: Codable {
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

struct GeminiRefreshResponse: Decodable {
    let accessToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

struct GeminiLoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
    let currentTier: RedactedTier?
    let paidTier: RedactedTier?
}

struct RedactedTier: Decodable {
    let name: String?
}

struct ProbeConfiguration {
    let authPath: String
    let tokenEndpoint: URL
    let codeAssistEndpoint: URL
    let clientID: String
    let clientSecret: String

    static func fromArguments(_ arguments: [String]) throws -> ProbeConfiguration {
        var authPath: String?
        var tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
        var codeAssistEndpoint = URL(string: "https://cloudcode-pa.googleapis.com/v1internal")!
        var clientID = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"]
        var clientSecret = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"]
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
                clientID = value
            case "--client-secret":
                guard let value = iterator.next(), !value.isEmpty else {
                    throw GeminiProbeError(message: "--client-secret requires a value")
                }
                clientSecret = value
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw GeminiProbeError(message: "unknown argument: \(argument)")
            }
        }

        guard let clientID, !clientID.isEmpty else {
            throw GeminiProbeError(message: "set GEMINI_OAUTH_CLIENT_ID or pass --client-id")
        }
        guard let clientSecret, !clientSecret.isEmpty else {
            throw GeminiProbeError(message: "set GEMINI_OAUTH_CLIENT_SECRET or pass --client-secret")
        }

        return ProbeConfiguration(
            authPath: authPath ?? defaultAuthPath(),
            tokenEndpoint: tokenEndpoint,
            codeAssistEndpoint: codeAssistEndpoint,
            clientID: clientID,
            clientSecret: clientSecret
        )
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

        Requires GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET, or the
        equivalent --client-id and --client-secret flags. Use values from the
        locally installed Gemini CLI; do not commit them to this repository.

        Uses Gemini CLI OAuth credentials to refresh an access token, asks the
        Gemini Code Assist backend for the active project, then prints a redacted
        quota summary. Tokens, account identifiers, project IDs, emails,
        headers, and raw response bodies are never printed.
        """)
    }
}

@main
struct GeminiQuotaProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let credentials = try loadCredentials(path: configuration.authPath)
            let accessToken = try await refreshedAccessToken(
                credentials: credentials,
                endpoint: configuration.tokenEndpoint,
                clientID: configuration.clientID,
                clientSecret: configuration.clientSecret
            )
            let loadResponse = try await loadCodeAssist(
                accessToken: accessToken,
                endpoint: configuration.codeAssistEndpoint
            )
            guard let project = loadResponse.cloudaicompanionProject, !project.isEmpty else {
                throw GeminiProbeError(message: "Code Assist did not return an active project; raw body redacted")
            }
            let quotaData = try await retrieveUserQuota(
                accessToken: accessToken,
                project: project,
                endpoint: configuration.codeAssistEndpoint
            )
            let buckets = try GeminiQuotaPayloadParser.buckets(from: quotaData)
            printSummary(
                buckets: buckets,
                authPath: configuration.authPath,
                endpoint: configuration.codeAssistEndpoint,
                tierName: loadResponse.currentTier?.name ?? loadResponse.paidTier?.name
            )
        } catch {
            fputs("GeminiQuotaProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func loadCredentials(path: String) throws -> GeminiOAuthCredentials {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        let credentials = try JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
        guard credentials.refreshToken?.isEmpty == false else {
            throw GeminiProbeError(message: "Gemini OAuth file does not contain a refresh token")
        }
        return credentials
    }

    private static func refreshedAccessToken(
        credentials: GeminiOAuthCredentials,
        endpoint: URL,
        clientID: String,
        clientSecret: String
    ) async throws -> String {
        guard let refreshToken = credentials.refreshToken else {
            throw GeminiProbeError(message: "Gemini OAuth file does not contain a refresh token")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])

        let data = try await send(request: request, redactedDescription: "OAuth refresh")
        return try JSONDecoder().decode(GeminiRefreshResponse.self, from: data).accessToken
    }

    private static func loadCodeAssist(accessToken: String, endpoint: URL) async throws -> GeminiLoadCodeAssistResponse {
        var request = URLRequest(url: endpoint.appending(path: ":loadCodeAssist"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "cloudaicompanionProject": NSNull(),
            "metadata": [
                "ideType": "IDE_UNSPECIFIED",
                "platform": "PLATFORM_UNSPECIFIED",
                "pluginType": "GEMINI",
                "duetProject": NSNull(),
            ],
        ])

        let data = try await send(request: request, redactedDescription: "Code Assist load")
        return try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: data)
    }

    private static func retrieveUserQuota(accessToken: String, project: String, endpoint: URL) async throws -> Data {
        var request = URLRequest(url: endpoint.appending(path: ":retrieveUserQuota"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["project": project])
        return try await send(request: request, redactedDescription: "Code Assist quota")
    }

    private static func send(request: URLRequest, redactedDescription: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiProbeError(message: "\(redactedDescription) returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GeminiProbeError(message: "\(redactedDescription) returned HTTP \(http.statusCode); raw body redacted")
        }
        return data
    }

    private static func formEncoded(_ values: [String: String]) -> Data {
        values
            .map { key, value in
                "\(escape(key))=\(escape(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func printSummary(buckets: [GeminiQuotaBucket], authPath: String, endpoint: URL, tierName: String?) {
        print("Gemini Code Assist quota probe")
        print("endpoint: \(endpoint.absoluteString)")
        print("auth: \(redactedPath(authPath))")
        print("tier: \(tierName ?? "unknown")")
        print("buckets: \(buckets.count)")
        print("redacted: tokens, account identifiers, project IDs, emails, headers, raw response bodies")
        print("")

        for bucket in buckets.sorted(by: { $0.modelID < $1.modelID }) {
            let remaining = bucket.remainingFraction.map { String(format: "%.1f%% remaining", $0 * 100) } ?? "unknown remaining"
            let used = bucket.usedPercent.map { String(format: "%.1f%% used", $0) } ?? "unknown used"
            let amount = bucket.remainingAmount.map { "remaining amount \($0)" } ?? "remaining amount absent"
            let reset = bucket.resetsAt.map { ContextPanelDateFormatting.string(from: $0) } ?? "unknown reset"
            print("- \(bucket.modelID): \(used), \(remaining), \(amount), resets \(reset)")
        }
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
