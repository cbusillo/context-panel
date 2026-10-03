import ContextPanelCore
import Foundation
import Darwin

let result = AgentAccountSnapshotCommand.run(arguments: Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(result.standardOutput)
FileHandle.standardError.write(result.standardError)
exit(result.exitCode)
