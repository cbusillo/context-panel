#if os(macOS)
import Foundation
import Testing
@testable import ContextPanelCore

@Test func googleAntigravitySetupCommandPreservesConfiguration() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "setup's home-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let bin = root.appending(path: "my agy's bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let agy = bin.appending(path: "agy")
    try "#!/bin/sh\nexit 0\n".write(to: agy, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agy.path)
    let bundle = root.appending(path: "Context Panel's Preview.app")
    let setup = GoogleAntigravityUsageSetup.setupCommand(applicationBundleURL: bundle)
    let hooks = root.appending(path: ".gemini/config/hooks.json")
    let settings = root.appending(path: ".gemini/antigravity-cli/settings.json")
    func run(_ command: String) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", command]
        process.environment = ["HOME": root.path, "PATH": "\(bin.path):/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    func read(_ url: URL) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? NSDictionary)
    }
    func write(_ value: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: value).write(to: url)
    }
    #expect(try run(GoogleAntigravityUsageSetup.removeCommand) == 0)
    #expect(!FileManager.default.fileExists(atPath: hooks.path))
    #expect(try run(setup) == 0)
    let installed = try read(hooks)
    let entry = try #require(installed[GoogleAntigravityUsageSetup.hookName] as? NSDictionary)
    let stop = try #require(entry["Stop"] as? [[String: Any]])
    #expect(stop.first?["command"] as? String == GoogleAntigravityUsageSetup.hookCommand(applicationBundleURL: bundle, agyExecutable: agy.path))
    let permissions = try FileManager.default.attributesOfItem(atPath: hooks.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    #expect(!FileManager.default.fileExists(atPath: settings.path))
    #expect(try run(setup) == 0)
    #expect(try read(hooks) == installed)

    try write([:], to: hooks)
    #expect(try run(setup) == 0)
    #expect(try read(hooks) == installed)

    let other: [String: Any] = ["Stop": [["type": "command", "command": "echo other"]]]
    try write(["other": other, GoogleAntigravityUsageSetup.hookName: ["old": true]], to: hooks)
    let oldAgent = bundle.appending(path: "Contents/MacOS/ContextPanelRefreshAgent")
    try write(["theme": "dark", "statusLine": ["type": "command", "command": "\(GoogleAntigravityUsageSetup.shellQuoted(oldAgent.path)) --ingest-antigravity-status-line"]], to: settings)
    let managedHooks = root.appending(path: "managed-hooks.json")
    let managedSettings = root.appending(path: "managed-settings.json")
    for (link, target) in [(hooks, managedHooks), (settings, managedSettings)] {
        try FileManager.default.moveItem(at: link, to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    }
    #expect(try run(setup) == 0)
    #expect(try read(hooks)["other"] as? NSDictionary == other as NSDictionary)
    #expect(try read(hooks)[GoogleAntigravityUsageSetup.hookName] as? NSDictionary == entry)
    #expect(try read(settings) == ["theme": "dark"] as NSDictionary)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: hooks.path) == managedHooks.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == managedSettings.path)
    let custom: [String: Any] = ["statusLine": ["command": "echo 'ContextPanelRefreshAgent --ingest-antigravity-status-line'"], "theme": "light"]
    try write(custom, to: settings)
    #expect(try run(setup) == 0)
    #expect(try read(settings) == custom as NSDictionary)
    #expect(try run(GoogleAntigravityUsageSetup.removeCommand) == 0)
    #expect(try read(hooks) == ["other": other] as NSDictionary)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: hooks.path) == managedHooks.path)
    #expect(try read(settings) == custom as NSDictionary)
    #expect(try run(GoogleAntigravityUsageSetup.removeCommand) == 0)
    #expect(try read(hooks) == ["other": other] as NSDictionary)

    try Data("{broken".utf8).write(to: hooks)
    #expect(try run(setup) != 0)
    #expect(try Data(contentsOf: hooks) == Data("{broken".utf8))
}
#endif
