import ContextPanelCore
import Foundation

struct ClaudeStatuslineSetupError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

struct ClaudeStatuslineSetupConfiguration {
    enum Mode {
        case install
        case diagnose
    }

    var mode: Mode = .install
    var settingsPath: String = ClaudeStatuslineSetup.defaultSettingsURL().path
    var command: String

    init(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        let scriptPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "scripts", directoryHint: .isDirectory)
            .appending(path: "claude-statusline-cache.sh")
            .path
        command = "\(shellQuoted(scriptPath))"

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--diagnose":
                mode = .diagnose
            case "--install":
                mode = .install
            case "--settings":
                index += 1
                guard index < arguments.count else {
                    throw ClaudeStatuslineSetupError(message: "--settings requires a path")
                }
                settingsPath = arguments[index]
            case "--command":
                index += 1
                guard index < arguments.count else {
                    throw ClaudeStatuslineSetupError(message: "--command requires a command string")
                }
                command = arguments[index]
            case "--help", "-h":
                throw ClaudeStatuslineSetupError(message: Self.usage)
            default:
                throw ClaudeStatuslineSetupError(message: "unknown argument: \(argument)")
            }
            index += 1
        }
    }

    static let usage = """
    Usage: swift run ClaudeStatuslineSetup [--install|--diagnose] [--settings ~/.claude/settings.json] [--command COMMAND]

    Installs or inspects Claude Code statusLine settings for Context Panel's
    sanitized Claude subscription cache. The command receives Claude Code JSON
    on stdin and writes only redacted limit percentages/resets to Context Panel.
    """
}

@main
struct ClaudeStatuslineSetupMain {
    static func main() throws {
        let configuration = try ClaudeStatuslineSetupConfiguration()
        let settingsURL = URL(fileURLWithPath: NSString(string: configuration.settingsPath).expandingTildeInPath)
        let settingsData = try? Data(contentsOf: settingsURL)

        switch configuration.mode {
        case .diagnose:
            let command = try ClaudeStatuslineSetup.statusLineCommand(in: settingsData)
            print("Claude settings: \(settingsURL.path)")
            if let command, !command.isEmpty {
                print("statusLine command: \(command)")
            } else {
                print("statusLine command: missing")
            }
            print("statusline cache: \(ClaudeStatuslineSetup.defaultRateLimitCacheURL().path)")
        case .install:
            let merged = try ClaudeStatuslineSetup.mergedSettingsData(
                existingData: settingsData,
                command: configuration.command
            )
            try FileManager.default.createDirectory(
                at: settingsURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try merged.write(to: settingsURL, options: [.atomic])
            print("Installed Claude statusLine command in \(settingsURL.path)")
            print("statusline cache: \(ClaudeStatuslineSetup.defaultRateLimitCacheURL().path)")
        }
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
