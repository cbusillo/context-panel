import Foundation
import Testing

@testable import ContextPanelCore

private struct CodexMirrorFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let sourceFolderName: String
    var source: URL { root.appendingPathComponent("private-client/\(sourceFolderName)") }
    var destination: URL { root.appendingPathComponent("mirror") }

    init(sourceFolderName: String = "usage") throws {
        self.sourceFolderName = sourceFolderName
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func writeSession(secret: String = "private-transcript-and-auth-token") throws {
        let directory = source.appendingPathComponent("2027/01/15")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baselineDate = ISO8601DateFormatter().string(from: start.addingTimeInterval(-60))
        let recentDate = ISO8601DateFormatter().string(from: start)
        let records = [
            "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(secret)\"}}",
            "{\"timestamp\":\"\(baselineDate)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1000,\"cached_input_tokens\":800},\"model_context_window\":272000}}}",
            "{\"timestamp\":\"\(recentDate)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":1100,\"cached_input_tokens\":880},\"last_token_usage\":{\"input_tokens\":100,\"cached_input_tokens\":80},\"model_context_window\":272000}}}",
        ]
        try (records.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent(secret + ".jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try Data("{\"token\":\"\(secret)\"}".utf8).write(to: source.appendingPathComponent("auth.json"))
    }

    @discardableResult
    func mirror(at date: Date, client: CodexClient = .codex) throws -> PromptCacheTelemetryMirrorResult {
        try PromptCacheTelemetryMirrorService.mirror(
            sourceDirectories: [source],
            sourceClients: [ContextPanelLocations.normalizedPath(source.path): client],
            now: date,
            destination: destination
        )
    }

    func mirrorFiles() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil))
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
    }

    func persisted() throws -> CodexTelemetryMirror {
        let file = try #require(try mirrorFiles().first)
        return try JSONDecoder().decode(CodexTelemetryMirror.self, from: Data(contentsOf: file))
    }

    func observations(at date: Date) -> [PromptCacheObservation] {
        PromptCacheTelemetryReader.mirroredObservations(rootDirectory: destination, now: date)
    }
}

@Test func retiredExplicitClientCannotMirrorNativeSessions() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "sessions")
    defer { fixture.remove() }
    try fixture.writeSession()
    let target = fixture.destination.appendingPathComponent("retired/telemetry.json")

    try CodexTelemetryMirror.write(
        source: fixture.source,
        sourceIDPath: fixture.source.path,
        client: .everyCode,
        target: target,
        now: fixture.start,
        fileManager: .default
    )

    let mirror = try JSONDecoder().decode(CodexTelemetryMirror.self, from: Data(contentsOf: target))
    #expect(mirror.observations.isEmpty)
    #expect(mirror.baselines.isEmpty)
}

@Test func codexSessionMirrorStoresOnlyNormalizedTelemetry() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "sessions")
    defer { fixture.remove() }
    let secret = "private-transcript-and-auth-token"
    try fixture.writeSession(secret: secret)
    try fixture.mirror(at: fixture.start, client: .codex)
    let observations = fixture.observations(at: fixture.start)
    #expect(observations.map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
    #expect(observations.first?.accountName == "Codex · Account unknown")
    let files = try fixture.mirrorFiles()
    #expect(files.map(\.lastPathComponent) == ["telemetry.json"])
    let text = String(decoding: try Data(contentsOf: #require(files.first)), as: UTF8.self)
    #expect(!text.contains(secret))
    #expect(!text.contains("response_item"))
    #expect(!text.contains("auth.json"))
    #expect(try fixture.persisted().baselines.isEmpty)
}

@Test func codexTelemetryMirrorDisablingAllSourcesClearsPersistedTelemetry() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "sessions")
    defer { fixture.remove() }
    try fixture.writeSession()
    try fixture.mirror(at: fixture.start)
    let result = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [], now: fixture.start, destination: fixture.destination
    )
    #expect(result.removed > 0)
    #expect(try fixture.mirrorFiles().isEmpty)
    #expect(fixture.observations(at: fixture.start).isEmpty)
}

@Test func codexTelemetryCacheBreakDoesNotCompareDifferentSourceAccounts() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let prior = PromptCacheObservation(
        provider: .openAI, accountID: "lab-account", accountName: "Codex Lab",
        observedAt: now.addingTimeInterval(-60), windowLabel: "Since refresh",
        tokens: PromptCacheTokenSet(inputTokens: 10_000, cachedInputTokens: 9_500)
    )
    let latest = PromptCacheObservation(
        provider: .openAI, accountID: "codex-unattributed", accountName: "Codex",
        observedAt: now, windowLabel: "Since refresh",
        tokens: PromptCacheTokenSet(inputTokens: 2_000, cachedInputTokens: 0)
    )
    #expect(!PromptCacheSummary(observations: [prior, latest]).hasPossibleCacheBreak)
    let sameAccount = PromptCacheObservation(
        provider: .openAI, accountID: prior.accountID, accountName: prior.accountName,
        observedAt: now, windowLabel: prior.windowLabel, tokens: latest.tokens
    )
    #expect(PromptCacheSummary(observations: [prior, sameAccount]).hasPossibleCacheBreak)
}
