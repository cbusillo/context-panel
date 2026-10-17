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
    ["schemaVersion": 1, "provider": "openai", "accountID": receiptAccount,
     "launchedAt": ISO8601DateFormatter().string(from: launchedAt)]
}

private func recordLaunch(_ arguments: [String], input: Data, root: URL) throws -> LaunchReceiptCommand.Result {
    try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch"] + arguments,
        input: { input }, now: receiptNow, rootDirectory: root))
}

@Test func recordLaunchWritesAReceiptTheSnapshotCounts() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let result = try recordLaunch(["--launcher", "supervisor"], input: try receiptJSON(validReceipt()), root: root)
    #expect(result.exitCode == 0)
    #expect(result.standardError.isEmpty)
    let name = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    #expect(!name.contains("/"))
    #expect(name.range(of: "^[0-9]{8}T[0-9]{6}Z-supervisor-[0-9a-f]+\\.json$", options: .regularExpression) != nil)

    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [name])
    let stored = try Data(contentsOf: directory.appending(path: name))
    let object = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(Set(object.keys) == LaunchReceiptCommand.receiptKeys)
    #expect(LaunchReceiptStore.load(rootDirectory: root, now: receiptNow)
        == [LaunchReceipt(provider: .openAI, accountID: receiptAccount, launchedAt: receiptNow)])
}

@Test func recordLaunchPrunesOnlyThisLaunchersDayOldReceipts() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: LaunchReceiptStore.directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dayOld = try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(-LaunchReceiptStore.lookback)))
    let recent = try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(-60)))
    let files = [
        "20270115T080000Z-supervisor-aa.json": dayOld,
        "20270115T080000Z-other-bb.json": dayOld,
        "20270115T075900Z-cc.json": dayOld,
        "20270115T075900Z-supervisor-dd.json": recent,
    ]
    for (name, data) in files { try data.write(to: directory.appending(path: name)) }

    let result = try recordLaunch(["--launcher", "supervisor"], input: try receiptJSON(validReceipt()), root: root)
    #expect(result.exitCode == 0)
    let written = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .newlines)
    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(remaining == ["20270115T080000Z-other-bb.json", "20270115T075900Z-cc.json",
                          "20270115T075900Z-supervisor-dd.json", written])
}

@Test func recordLaunchRejectsInvalidInputWithoutWriting() throws {
    let root = try receiptRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    var extra = validReceipt()
    extra["prompt"] = "private-secret"
    var wrongProvider = validReceipt()
    wrongProvider["provider"] = "anthropic"
    var schemaTwo = validReceipt()
    schemaTwo["schemaVersion"] = 2
    var padded = validReceipt()
    padded["accountID"] = receiptAccount + String(repeating: " ", count: 1_100)
    let inputs: [Data] = [
        try receiptJSON(extra), try receiptJSON(wrongProvider), try receiptJSON(schemaTwo), try receiptJSON(padded),
        try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(-2 * LaunchReceiptStore.lookback))),
        try receiptJSON(validReceipt(launchedAt: receiptNow.addingTimeInterval(3_600))),
        Data("private-secret".utf8), Data(),
    ]
    for input in inputs {
        let result = try recordLaunch(["--launcher", "supervisor"], input: input, root: root)
        #expect(result.exitCode == 64)
        #expect(result.standardOutput.isEmpty)
        #expect(!String(decoding: result.standardError, as: UTF8.self).contains("private-secret"))
    }
    for arguments in [[], ["--launcher"], ["--launcher", "Super/visor"], ["--launcher", "supervisor", "--storage-root", "/tmp"]] {
        let result = try #require(ContextPanelEntryPoint.recordLaunchResult(arguments: ["--record-launch"] + arguments,
            input: { Issue.record("stdin read for invalid arguments"); return Data() }, now: receiptNow, rootDirectory: root))
        #expect(result.exitCode == 64)
    }
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
    #expect(String(decoding: help.standardOutput, as: UTF8.self).contains("--record-launch"))
}
