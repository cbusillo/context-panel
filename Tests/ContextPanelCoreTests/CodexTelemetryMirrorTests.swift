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

    func writeLab(
        input: Int,
        cached: Int?,
        at date: Date,
        filename: String = "private-account.json",
        secret: String = "sensitive-account-and-payload"
    ) throws {
        var totals: [String: Any] = ["input_tokens": input]
        if let cached { totals["cached_input_tokens"] = cached }
        let payload: [String: Any] = [
            "last_updated": ISO8601DateFormatter().string(from: date),
            "account_id": secret,
            "private_payload": secret,
            "totals": totals,
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: source.appendingPathComponent(filename))
    }

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
    func mirror(at date: Date, client: CodexClient = .codexLab) throws -> PromptCacheTelemetryMirrorResult {
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

@Test func codexLabNativeSessionMirrorCountsNormalizedEventsPrivatelyAndIdempotently() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "sessions")
    defer { fixture.remove() }
    let secret = "private-lab-transcript-and-auth-token"
    try fixture.writeSession(secret: secret)

    try fixture.mirror(at: fixture.start, client: .codexLab)
    let first = try fixture.persisted()
    try fixture.mirror(at: fixture.start, client: .codexLab)
    let second = try fixture.persisted()

    #expect(first.observations == second.observations)
    #expect(first.refreshedAt == second.refreshedAt)
    #expect(first.baselines.isEmpty)
    #expect(first.observations.map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
    #expect(first.observations.first?.accountID == "codex-lab-session-unattributed")
    #expect(first.observations.first?.accountName == "Codex Lab · Account unknown")
    let mirroredText = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
    #expect(!mirroredText.contains(secret))
    #expect(!mirroredText.contains("response_item"))
    #expect(!mirroredText.contains("auth.json"))
    #expect(!mirroredText.contains(fixture.source.path))
}

@Test func codexLabConfiguredSessionsPathSelectsNativeReaderAfterResolutionToUsageNamedDirectory() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "usage")
    defer { fixture.remove() }
    try fixture.writeSession()
    let target = fixture.destination.appendingPathComponent("resolved/telemetry.json")

    try CodexTelemetryMirror.write(
        source: fixture.source,
        sourceIDPath: fixture.root.appendingPathComponent("configured/sessions").path,
        client: .codexLab,
        target: target,
        now: fixture.start,
        fileManager: .default
    )

    let mirror = try JSONDecoder().decode(CodexTelemetryMirror.self, from: Data(contentsOf: target))
    #expect(mirror.observations.map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
    #expect(mirror.observations.first?.accountName == "Codex Lab · Account unknown")
    #expect(mirror.baselines.isEmpty)
}

@Test func copiedSessionEventDeduplicatesAcrossCodexAndLabMirrors() throws {
    let fixture = try CodexMirrorFixture(sourceFolderName: "sessions")
    defer { fixture.remove() }
    try fixture.writeSession()
    let codexTarget = fixture.destination.appendingPathComponent("codex/telemetry.json")
    let labTarget = fixture.destination.appendingPathComponent("lab/telemetry.json")
    for (client, target) in [(CodexClient.codex, codexTarget), (.codexLab, labTarget)] {
        try CodexTelemetryMirror.write(
            source: fixture.source,
            sourceIDPath: fixture.root.appendingPathComponent("\(client.rawValue)/sessions").path,
            client: client,
            target: target,
            now: fixture.start,
            fileManager: .default
        )
    }

    let codex = try JSONDecoder().decode(CodexTelemetryMirror.self, from: Data(contentsOf: codexTarget))
    let lab = try JSONDecoder().decode(CodexTelemetryMirror.self, from: Data(contentsOf: labTarget))
    #expect(codex.observations.first?.id == lab.observations.first?.id)
    #expect(codex.observations.first?.accountID != lab.observations.first?.accountID)
    #expect(PromptCacheTelemetryReader.mirroredObservations(
        rootDirectory: fixture.destination,
        now: fixture.start
    ).count == 1)
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

@Test func codexLabMirrorUsesMeasuredRefreshDeltaInsteadOfLifetimeTotals() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 10_000, cached: 1_000, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    #expect(try fixture.persisted().baselines.count == 1)
    #expect(fixture.observations(at: fixture.start).isEmpty)

    let later = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 10_100, cached: 1_080, at: later)
    try fixture.mirror(at: later)
    let observations = fixture.observations(at: later)
    #expect(observations.count == 1)
    #expect(observations.first?.tokens.inputTokens == 100)
    #expect(observations.first?.tokens.cachedInputTokens == 80)
    #expect(observations.first?.hitRate == 0.8)
    #expect(observations.first?.windowLabel == "Since refresh")
    #expect(observations.first?.observedAt == later)
    #expect(observations.first?.measurement == .increment)
}

@Test func codexLabMirrorTemporaryInvalidRecordPreservesMeasuredHistoryWithoutReusingBaseline() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let measured = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 1_100, cached: 880, at: measured)
    try fixture.mirror(at: measured)
    let original = fixture.observations(at: measured)
    let invalid = fixture.start.addingTimeInterval(120)
    try Data("{unfinished".utf8).write(to: fixture.source.appendingPathComponent("private-account.json"))
    try fixture.mirror(at: invalid)
    #expect(fixture.observations(at: invalid) == original)
    #expect(try fixture.persisted().baselines.isEmpty)
    let recovered = fixture.start.addingTimeInterval(180)
    try fixture.writeLab(input: 9_000, cached: 8_000, at: recovered)
    try fixture.mirror(at: recovered)
    #expect(fixture.observations(at: recovered) == original)
    #expect(try fixture.persisted().baselines.count == 1)
}

@Test func codexLabMirrorEarlierRefreshCannotOverwriteNewerBaseline() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let later = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 1_100, cached: 880, at: later)
    try fixture.mirror(at: later)
    let original = fixture.observations(at: later)
    try fixture.mirror(at: fixture.start)
    #expect(fixture.observations(at: later) == original)
    #expect(try fixture.persisted().refreshedAt == later)
}

@Test func codexLabMirrorIdleTimestampChangesDoNotReplayUsage() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let measured = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 1_100, cached: 880, at: measured)
    try fixture.mirror(at: measured)
    let original = fixture.observations(at: measured)
    let idle = fixture.start.addingTimeInterval(120)
    try fixture.writeLab(input: 1_100, cached: 880, at: idle)
    try fixture.mirror(at: idle)
    #expect(fixture.observations(at: idle) == original)
}

@Test func codexLabMirrorCounterResetDoesNotCreateLifetimeSpike() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 10_000, cached: 9_000, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let reset = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 100, cached: 0, at: reset)
    try fixture.mirror(at: reset)
    #expect(fixture.observations(at: reset).isEmpty)
    let resumed = fixture.start.addingTimeInterval(120)
    try fixture.writeLab(input: 200, cached: 80, at: resumed)
    try fixture.mirror(at: resumed)
    #expect(fixture.observations(at: resumed).map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
}

@Test func codexLabMirrorMissingCacheStaysUnknownUntilMeasuredBaselineRecovers() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: nil, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let unknown = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 1_100, cached: nil, at: unknown)
    try fixture.mirror(at: unknown)
    #expect(fixture.observations(at: unknown).first?.tokens.cachedInputTokens == nil)
    #expect(fixture.observations(at: unknown).first?.tokens.inputTokens == 100)
    let baseline = fixture.start.addingTimeInterval(120)
    try fixture.writeLab(input: 1_200, cached: 900, at: baseline)
    try fixture.mirror(at: baseline)
    #expect(fixture.observations(at: baseline).first?.tokens.cachedInputTokens == nil)
    let recovered = fixture.start.addingTimeInterval(180)
    try fixture.writeLab(input: 1_300, cached: 980, at: recovered)
    try fixture.mirror(at: recovered)
    let observations = fixture.observations(at: recovered)
    #expect(observations.count == 3)
    #expect(observations.first?.tokens.cachedInputTokens == 80)
    #expect(observations.first?.hitRate == 0.8)
}

@Test func codexLabMirrorRejectsStaleAndFutureSamples() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let later = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 2_000, cached: 1_600, at: later.addingTimeInterval(1))
    try fixture.mirror(at: later)
    #expect(fixture.observations(at: later).isEmpty)
    #expect(try fixture.persisted().baselines.isEmpty)
    try fixture.writeLab(
        input: 3_000,
        cached: 2_400,
        at: later.addingTimeInterval(-PromptCacheSummary.defaultMaximumAge - 1)
    )
    try fixture.mirror(at: later)
    #expect(fixture.observations(at: later).isEmpty)
    #expect(try fixture.persisted().baselines.isEmpty)
}

@Test func codexLabMirrorExpiredBaselineDoesNotCreateRecentLifetimeDelta() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let later = fixture.start.addingTimeInterval(PromptCacheSummary.defaultMaximumAge + 1)
    try fixture.writeLab(input: 100_000, cached: 80_000, at: later)
    try fixture.mirror(at: later)
    #expect(fixture.observations(at: later).isEmpty)
    #expect(try fixture.persisted().baselines.count == 1)
}

@Test func codexLabMirrorPreservesDistinctAccountsWithoutCopyingPrivateIdentity() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    let secrets = ["raw-owner-alpha", "raw-owner-beta"]
    for secret in secrets {
        try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start, filename: secret + ".json", secret: secret)
    }
    try fixture.mirror(at: fixture.start)
    let later = fixture.start.addingTimeInterval(60)
    for secret in secrets {
        try fixture.writeLab(input: 1_100, cached: 880, at: later, filename: secret + ".json", secret: secret)
    }
    try fixture.mirror(at: later)
    let observations = fixture.observations(at: later)
    #expect(observations.count == 2)
    #expect(Set(observations.map(\.accountID)).count == 2)
    #expect(Set(observations.map(\.accountName)).count == 2)
    #expect(observations.allSatisfy { $0.accountName.hasPrefix("Codex Lab · Account ") })
    let files = try fixture.mirrorFiles()
    #expect(files.map(\.lastPathComponent) == ["telemetry.json"])
    let mirroredText = String(decoding: try Data(contentsOf: #require(files.first)), as: UTF8.self)
    for secret in secrets { #expect(!mirroredText.contains(secret)) }
    #expect(!mirroredText.contains("account_id"))
    #expect(!mirroredText.contains("private_payload"))
    #expect(!mirroredText.contains(fixture.source.path))
}

@Test func codexLabMirrorKeepsAccountLabelsStableWhenAnotherAccountAppears() throws {
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
    try fixture.mirror(at: fixture.start)
    let later = fixture.start.addingTimeInterval(60)
    try fixture.writeLab(input: 1_100, cached: 880, at: later)
    try fixture.mirror(at: later)
    let original = try #require(fixture.observations(at: later).first)
    let added = fixture.start.addingTimeInterval(120)
    try fixture.writeLab(input: 1_200, cached: 960, at: added)
    try fixture.writeLab(input: 500, cached: 400, at: added, filename: "aaa-new-account.json")
    try fixture.mirror(at: added)
    let names = fixture.observations(at: added).filter { $0.accountID == original.accountID }.map(\.accountName)
    #expect(names.count == 2)
    #expect(Set(names) == [original.accountName])
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
    let fixture = try CodexMirrorFixture()
    defer { fixture.remove() }
    try fixture.writeLab(input: 1_000, cached: 800, at: fixture.start)
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
