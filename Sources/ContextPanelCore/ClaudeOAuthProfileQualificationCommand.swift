import Foundation

public enum ClaudeOAuthProfileQualificationCommand {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    public static func run(
        arguments: [String],
        accountStore: AccountConfigurationStore = AccountConfigurationStore(
            configurationURL: ContextPanelLocations.accountConfigurationURL(),
            fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()),
        check: @Sendable (String) async throws -> ClaudeOAuthProfileShape = { accountID in
            try await ClaudeOAuthProfileQualification(credentialStore: ProviderCredentialStore()).check(accountID: accountID)
        }
    ) async -> Result {
        if arguments == ["--help"] {
            return result(0, output: "usage: Context Panel --claude-profile-shape\nReports candidate profile field types only for enabled Claude accounts; no values or identifiers. Does not refresh credentials.")
        }
        guard arguments.isEmpty else { return result(64, error: "Invalid arguments; use --claude-profile-shape --help.") }
        guard FileManager.default.fileExists(atPath: accountStore.configurationURL.path)
                || accountStore.fallbackConfigurationURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true
        else { return result(1, error: "Account setup is missing; configure Claude in Context Panel first.") }
        // Decode the saved document without load()'s migration/write side effects.
        let configuration: AccountConfigurationDocument
        do {
            guard let source = FileManager.default.fileExists(atPath: accountStore.configurationURL.path)
                ? accountStore.configurationURL : accountStore.fallbackConfigurationURL
            else { return result(1, error: "Account setup is missing.") }
            configuration = try JSONDecoder.contextPanelISO8601.decode(AccountConfigurationDocument.self, from: Data(contentsOf: source))
            guard configuration.schemaVersion == 1 else { return result(1, error: "Account setup is unsupported.") }
        } catch { return result(1, error: "Account setup could not be read.") }
        let accounts = configuration.accounts.filter { $0.isEnabled && $0.connectorKind == .claudeOAuthUsage }
        guard !accounts.isEmpty else { return result(1, error: "No enabled Claude accounts.") }
        var output: [String] = []
        var errors: [String] = []
        for (index, account) in accounts.enumerated() {
            // Report only the ordinal, never the saved account name or identifier.
            let label = "Claude source \(index + 1)"
            do { output.append("\(label)\n\(try await check(account.id).summary)") }
            catch let error as ClaudeOAuthProfileQualification.Failure {
                errors.append("\(label): \(error.localizedDescription)")
            } catch { errors.append("\(label): Profile check unavailable.") }
        }
        return result(errors.isEmpty ? 0 : 1, output: output.joined(separator: "\n"), error: errors.joined(separator: "\n"))
    }

    private static func result(_ code: Int32, output: String = "", error: String = "") -> Result {
        Result(exitCode: code, standardOutput: Data((output.isEmpty ? "" : output + "\n").utf8),
               standardError: Data((error.isEmpty ? "" : error + "\n").utf8))
    }
}
