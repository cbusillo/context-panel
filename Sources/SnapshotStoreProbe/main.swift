import ContextPanelCore
import Foundation

struct SnapshotStoreProbeError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ProbeConfiguration {
    let outputDirectory: URL
    let codexAuthPath: String?
    let includeClaude: Bool

    static func fromArguments(_ arguments: [String]) throws -> ProbeConfiguration {
        var outputDirectory: URL?
        var codexAuthPath: String?
        var includeClaude = false
        var iterator = arguments.dropFirst().makeIterator()

        while let argument = iterator.next() {
            switch argument {
            case "--output":
                guard let value = iterator.next() else {
                    throw SnapshotStoreProbeError(message: "--output requires a directory path")
                }
                outputDirectory = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            case "--codex-auth":
                guard let value = iterator.next() else {
                    throw SnapshotStoreProbeError(message: "--codex-auth requires a path")
                }
                codexAuthPath = value
            case "--include-claude":
                includeClaude = true
            case "--help", "-h":
                printHelp()
                Foundation.exit(0)
            default:
                throw SnapshotStoreProbeError(message: "unknown argument: \(argument)")
            }
        }

        return ProbeConfiguration(
            outputDirectory: outputDirectory ?? defaultOutputDirectory(),
            codexAuthPath: codexAuthPath,
            includeClaude: includeClaude
        )
    }

    private static func defaultOutputDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "context-panel-snapshot-store", directoryHint: .isDirectory)
    }

    private static func printHelp() {
        print("""
        Usage: swift run SnapshotStoreProbe [--output /tmp/context-panel-store] [--codex-auth ~/.codex/auth.json] [--include-claude]

        Refreshes selected local connectors, writes the normalized snapshot to
        the JSON snapshot store, then reloads it. The store contains normalized
        usage state only; tokens, account identifiers, project IDs, emails,
        headers, and raw provider responses are not persisted.
        """)
    }
}

@main
struct SnapshotStoreProbe {
    static func main() async {
        do {
            let configuration = try ProbeConfiguration.fromArguments(CommandLine.arguments)
            let connectors = makeConnectors(configuration: configuration)
            guard !connectors.isEmpty else {
                throw SnapshotStoreProbeError(message: "no connectors selected")
            }

            let result = await ProviderConnectorRuntime(connectors: connectors).refreshAll()
            let store = JSONSnapshotStore(rootDirectory: configuration.outputDirectory)
            try store.save(StoredUsageSnapshot(savedAt: Date(), refreshResult: result))
            let loaded = store.loadCurrent(policy: SnapshotStoreStalenessPolicy())

            print("Context Panel snapshot store probe")
            print("store: \(ConnectorRedactor.redactedPath(configuration.outputDirectory.path))")
            print("reports: \(result.reports.count)")
            print("limits: \(result.snapshot.limits.count)")
            print("load status: \(loaded.status.rawValue)")
            print("history entries: \(store.loadHistory().count)")
            print("redacted: tokens, account identifiers, project IDs, emails, headers, raw response bodies")
        } catch {
            fputs("SnapshotStoreProbe failed: \(error.localizedDescription)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func makeConnectors(configuration: ProbeConfiguration) -> [any ProviderConnector] {
        var connectors: [any ProviderConnector] = []
        if let codexAuthPath = configuration.codexAuthPath {
            connectors.append(CodexRateLimitConnector(accounts: [
                CodexAccountConfiguration(authPath: codexAuthPath)
            ]))
        }
        if configuration.includeClaude {
            connectors.append(ClaudeLocalStatusConnector(accounts: [ClaudeAccountConfiguration()]))
        }
        return connectors
    }
}

