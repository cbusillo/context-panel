import Foundation
import Testing
@testable import ContextPanelCore
@testable import ContextPanelApp

private let receiptNow = Date(timeIntervalSince1970: 1_800_000_000)
private let receiptAccount = "openai-0123456789abcdef"

private func receiptRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func receiptJSON(_ fields: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: fields)
}

private func validReceipt(launchedAt: Date = receiptNow) -> [String: Any] {
    ["schemaVersion": LaunchReceipt.currentSchemaVersion, "provider": "openai", "accountID": receiptAccount,
     "launchedAt": ISO8601DateFormatter().string(from: launchedAt)]
}

private func recordLaunch(_ arguments: [String], input: Data, root: URL, now: Date = receiptNow) throws -> LaunchReceiptCommand.Result {
    try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch"] + arguments,
        input: { input }, now: now, rootDirectory: root))
}

@Test func recordLaunchWritesAReceiptTheSnapshotCounts() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try recordLaunch(["--launcher", "supervisor"], input: try receiptJSON(validReceipt()), root: root)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let name = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    #expect(!name.contains("/"))

    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [name])
    let stored = try Data(contentsOf: directory.appending(path: name))
    let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(Set(object.keys) == LaunchReceiptCommand.receiptKeys)
    let loaded = LaunchReceiptStore.load(rootDirectory: root, now: receiptNow)
    #expect(loaded.map(\.accountID) == [receiptAccount])
    #expect(loaded.map(\.launchedAt) == [receiptNow])
    #expect(loaded.first?.receiptID != nil)
}

@Test func recordLaunchPrunesOnlyThisLaunchersDayOldReceipts() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    func write(_ launcher: String, at date: Date) throws -> String {
        let result = try recordLaunch(["--launcher", launcher], input: receiptJSON(validReceipt(launchedAt: date)), root: root, now: date)
        #expect(result.exitCode == 0)
        return String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    let oldTime = receiptNow.addingTimeInterval(-LaunchReceiptStore.lookback)
    let old = try write("supervisor", at: oldTime)
    let other = try write("other", at: oldTime)
    let recent = try write("supervisor", at: receiptNow.addingTimeInterval(-60))
    let legacy = "20270115T075900Z-cc.json"
    try receiptJSON(validReceipt(launchedAt: oldTime)).write(to: directory.appending(path: legacy))
    #expect(FileManager.default.fileExists(atPath: directory.appending(path: old).path))

    let result = try recordLaunch(["--launcher", "supervisor"], input: try receiptJSON(validReceipt()), root: root)
    #expect(result.exitCode == 0)
    let written = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(remaining == [other, legacy, recent, written])
}

@Test func recordLaunchRejectsInvalidInputWithoutWriting() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var extra = validReceipt()
    extra["prompt"] = "private-secret"
    var wrongProvider = validReceipt()
    wrongProvider["provider"] = "anthropic"
    var futureSchema = validReceipt()
    futureSchema["schemaVersion"] = LaunchReceipt.currentSchemaVersion + 1
    var newlineAccount = validReceipt()
    newlineAccount["accountID"] = receiptAccount + "\n"
    let valid = try receiptJSON(validReceipt())
    let oversized = valid + Data(repeating: 0x20, count: LaunchReceiptStore.maximumFileBytes)
    let inputs: [Data] = [
        try receiptJSON(extra), try receiptJSON(wrongProvider), try receiptJSON(futureSchema),
        try receiptJSON(newlineAccount),
        try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(-2 * LaunchReceiptStore.lookback))),
        try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(3_600))),
        oversized, Data("private-secret".utf8), Data(),
    ]
    for input in inputs {
        let result = try recordLaunch(["--launcher", "supervisor"], input: input, root: root)
        #expect(result.exitCode == 64)
        #expect(result.standardOutput.isEmpty)
        #expect(!String(decoding: result.standardError, as: UTF8.self).contains("private-secret"))
    }
    for arguments in [[], ["--launcher"], ["--launcher", "Super/visor"], ["--launcher", "supervisor\n"], ["--launcher", "supervisor", "--storage-root", "/tmp"]] {
        let result = try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch"] + arguments,
            input: { Issue.record("stdin read for invalid arguments"); return Data() }, now: receiptNow, rootDirectory: root))
        #expect(result.exitCode == 64)
    }
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: LaunchReceiptStore.directoryName).path))
}

@Test func recordLaunchPrunesOnlyItsOwnDayOldInterruptedWrites() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let oldTime = receiptNow.addingTimeInterval(-LaunchReceiptStore.lookback)
    // A killed writer can leave its same-directory temporary file before rename.
    let old = LaunchReceiptCommand.temporaryFileName(launcher: "supervisor")
    let other = LaunchReceiptCommand.temporaryFileName(launcher: "other")
    let recent = LaunchReceiptCommand.temporaryFileName(launcher: "supervisor")
    let unrelated = "other.tmp"
    let link = LaunchReceiptCommand.temporaryFileName(launcher: "supervisor")
    for name in [old, other, recent, unrelated] {
        let url = directory.appending(path: name)
        try Data("interrupted".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: name == recent ? receiptNow : oldTime], ofItemAtPath: url.path)
    }
    try FileManager.default.createSymbolicLink(at: directory.appending(path: link), withDestinationURL: directory.appending(path: old))
    LaunchReceiptCommand.prune(directory: directory, launcher: "supervisor", now: receiptNow)
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [other, recent, unrelated, link])
}

@Test func recordLaunchRejectsUnreadableOrOversizedStdinWithoutWriting() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appending(path: "input.json")
    try (receiptJSON(validReceipt()) + Data(repeating: 0x20, count: LaunchReceiptStore.maximumFileBytes)).write(to: file)
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let oversized = try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch", "--launcher", "supervisor"],
        input: { try LaunchReceiptCommand.readInput(from: handle) }, now: receiptNow, rootDirectory: root))
    #expect(oversized.exitCode == 64)
    #expect(oversized.standardOutput.isEmpty)
    try handle.close()
    let unreadable = try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch", "--launcher", "supervisor"],
        input: { try LaunchReceiptCommand.readInput(from: handle) }, now: receiptNow, rootDirectory: root))
    #expect(unreadable.exitCode == 64)
    #expect(unreadable.standardOutput.isEmpty)
    #expect(!unreadable.standardError.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: root.appending(path: LaunchReceiptStore.directoryName).path))
}

@Test func recordLaunchReportsStorageFailureWithoutPathOrReplacementStore() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let missing = root.appending(path: "private-secret-store")
    let result = try recordLaunch(["--launcher", "supervisor"], input: try receiptJSON(validReceipt()), root: missing)
    #expect(result.exitCode == 1)
    #expect(result.standardOutput.isEmpty)
    let message = String(decoding: result.standardError, as: UTF8.self)
    #expect(!message.isEmpty)
    #expect(!message.contains("private-secret"))
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func recordLaunchOnlyAnswersItsOwnMode() throws {
    #expect(ContextPanelEntryPoint.recordLaunchResult(arguments: [], input: { Data() }) == nil)
    #expect(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--account-snapshot"], input: { Data() }) == nil)
    let help = try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch", "--help"],
        input: { Issue.record("stdin read for help"); return Data() }))
    #expect(help.exitCode == 0)
    #expect(!help.standardOutput.isEmpty)
}
