import ContextPanelCore
import Foundation
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print("usage: ContextPanelAccountSnapshot [--storage-root <Context Panel storage directory>]")
    exit(0)
}
let root: URL
if arguments.isEmpty {
    root = ContextPanelLocations.realUserHomeDirectory()
        .appending(path: "Library/Group Containers")
        .appending(path: ContextPanelLocations.appGroupID)
        .appending(path: "Context Panel")
} else if arguments.count == 2, arguments[0] == "--storage-root" {
    root = URL(fileURLWithPath: NSString(string: arguments[1]).expandingTildeInPath)
} else {
    FileHandle.standardError.write(Data("Invalid arguments; use --help.\n".utf8))
    exit(64)
}

do {
    let projection = try AgentAccountSnapshot.read(rootDirectory: root)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(projection)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    // Never interpolate errors: decoder and filesystem errors may contain private paths/values.
    FileHandle.standardError.write(Data("Account snapshot unavailable or unsupported; check the publisher's storage and refresh.\n".utf8))
    exit(1)
}
