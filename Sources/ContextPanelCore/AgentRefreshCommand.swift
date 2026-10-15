import Foundation

/// Headless local refresh. Uses the same adapters and refresh lock as the app and helper.
public enum AgentRefreshCommand {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardOutput: Data
        public let standardError: Data
    }

    public static func run(
        arguments: [String],
        accountStore: AccountConfigurationStore = AccountConfigurationStore(
            configurationURL: ContextPanelLocations.accountConfigurationURL(),
            fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
        ),
        now: Date = Date(),
        sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        refresh: @Sendable (Date) async throws -> SnapshotRefreshRunDecision
    ) async -> Result {
        if arguments == ["--help"] {
            return result(0, output: """
                usage: "Context Panel" --refresh-now
                Refresh every enabled local source and wait for the saved readings.
                Google imports the latest AGY bridge observation; run AGY for a new observation.
                Exit codes: 0 saved, 1 incomplete or failed, 64 invalid arguments.
                """)
        }
        guard arguments.isEmpty else {
            return result(64, error: "Invalid arguments; use --refresh-now --help.")
        }
        // Do not create default setup merely because an unattended command was invoked.
        guard FileManager.default.fileExists(atPath: accountStore.configurationURL.path)
            || accountStore.fallbackConfigurationURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true
        else {
            return result(1, error: "Account setup is missing; configure accounts in Context Panel first.")
        }
        let configuration = accountStore.load(now: now)
        guard configuration.status == .healthy else {
            return result(1, error: "Account setup could not be read; check Settings in Context Panel.")
        }
        let accounts = configuration.document.accounts.filter { $0.isEnabled && !$0.isRetiredSource }
        guard !accounts.isEmpty else {
            return result(1, error: "No enabled provider sources; enable an account in Context Panel.")
        }

        var decision = SnapshotRefreshRunDecision.skippedAlreadyRunning
        do {
            for attempt in 0..<31 {
                decision = try await refresh(now)
                guard decision == .skippedAlreadyRunning else { break }
                if attempt < 30 { try await sleep() }
            }
        } catch {
            // Filesystem/decoder errors can include private paths and raw values.
            return result(1, error: "Refresh could not complete or save its readings; check storage and provider diagnostics in Context Panel.")
        }
        guard case let .refreshed(outcome) = decision else {
            if decision == .skippedAlreadyRunning {
                return result(1, error: "Another refresh is still running after the bounded wait; retry --refresh-now when it finishes.")
            }
            return result(1, error: "Refresh did not save provider readings; check provider setup in Context Panel.")
        }
        guard outcome.didSaveSnapshot, outcome.storedSnapshot != nil else {
            return result(1, error: "Refresh did not save its readings; check local storage in Context Panel.")
        }

        // Refresh can apply shared removals, deleting a setup row intentionally.
        let updatedConfiguration = accountStore.load(now: now)
        guard updatedConfiguration.status == .healthy else {
            return result(1, error: "Account setup could not be read after refresh; check Settings in Context Panel.")
        }
        let remainingAccounts = updatedConfiguration.document.accounts.filter { $0.isEnabled && !$0.isRetiredSource }
        var messages: [String] = []
        var failures: [String] = []
        for (index, account) in remainingAccounts.enumerated() {
            // An ordinal identifies the failing setup row without printing local names or IDs.
            let source = "\(account.provider.rawValue) source \(index + 1)"
            let reports = outcome.refreshResult.sourceReports.filter {
                $0.provider == account.provider && $0.configuredAccountID == account.id
            }
            guard !reports.isEmpty else {
                failures.append("\(source): no reading returned; check this source in Settings.")
                continue
            }
            for report in reports {
                guard [.healthy, .close, .limited].contains(report.status), !report.limits.isEmpty else {
                    let reason = report.errorMessage ?? "No usable reading returned; check provider diagnostics in Context Panel."
                    failures.append("\(source): \(ConnectorRedactor.safeErrorDescription(reason))")
                    continue
                }
                if account.provider == .google {
                    messages.append("\(source): saved AGY bridge observation from \(report.generatedAt.ISO8601Format()); run AGY to publish a new observation.")
                } else {
                    messages.append("\(source): saved readings.")
                }
            }
        }
        return result(failures.isEmpty ? 0 : 1, output: messages.joined(separator: "\n"),
                      error: failures.joined(separator: "\n"))
    }

    private static func result(_ exitCode: Int32, output: String = "", error: String = "") -> Result {
        Result(exitCode: exitCode, standardOutput: Data((output.isEmpty ? "" : output + "\n").utf8),
               standardError: Data((error.isEmpty ? "" : error + "\n").utf8))
    }
}
