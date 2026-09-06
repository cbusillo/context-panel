import Foundation
import Testing

@testable import ContextPanelCore

private struct CodexSessionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ lines: [String], name: String = "session.jsonl", suffix: String = "") throws -> URL {
        let directory = root.appendingPathComponent("2027/01/15")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n" + suffix).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func event(_ age: TimeInterval, input: Int, cached: Int?, lastInput: Int? = nil, lastCached: Int? = nil) -> String {
        let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-age))
        let cachedJSON = cached.map { ",\"cached_input_tokens\":\($0)" } ?? ""
        let lastCachedJSON = lastCached.map { ",\"cached_input_tokens\":\($0)" } ?? ""
        let lastJSON = lastInput.map { ",\"last_token_usage\":{\"input_tokens\":\($0)\(lastCachedJSON)}" } ?? ""
        return "{\"timestamp\":\"\(timestamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input)\(cachedJSON)}\(lastJSON)}}}"
    }

    func observations(
        client: CodexClient = .codex,
        maximumAge: TimeInterval = 3600
    ) -> [PromptCacheObservation] {
        CodexSessionTelemetryReader.observations(
            rootDirectory: root,
            client: client,
            now: now,
            maximumAge: maximumAge
        )
    }
}

@Test func codexSessionUsesTypedClientIdentityWithoutChangingEventFingerprint() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(100, input: 100, cached: 80),
        fixture.event(90, input: 200, cached: 160),
    ])

    let codex = try #require(fixture.observations(client: .codex).first)
    let lab = try #require(fixture.observations(client: .codexLab).first)
    #expect(codex.id == lab.id)
    #expect(codex.accountID == "codex-session-unattributed")
    #expect(codex.accountName == "Codex · Account unknown")
    #expect(lab.accountID == "codex-lab-session-unattributed")
    #expect(lab.accountName == "Codex Lab · Account unknown")
    #expect(CodexSessionTelemetryReader.observations(
        rootDirectory: fixture.root,
        client: .everyCode,
        now: fixture.now
    ).isEmpty)
}

@Test func codexSessionDeltasExcludeRepeatedTotalsAndUseBoundaryBaseline() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(4000, input: 1000, cached: 800),
        fixture.event(100, input: 1300, cached: 1000),
        fixture.event(90, input: 1300, cached: 1000),
        fixture.event(20, input: 1500, cached: 1100),
    ])
    let observations = fixture.observations()
    #expect(observations.count == 2)
    #expect(observations.map(\.tokens.inputTokens) == [200, 300])
    #expect(observations.map(\.tokens.cachedInputTokens) == [100, 200])
    #expect(observations.allSatisfy { $0.windowLabel == "Session increment" })
    #expect(observations.allSatisfy { $0.measurement == .increment })
}

@Test func codexSessionSingleTurnRequiresMatchingLastCounters() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)])
    #expect(fixture.observations().first?.tokens.inputTokens == 100)
    try fixture.write([fixture.event(10, input: 100, cached: 80, lastInput: 50, lastCached: 40)])
    #expect(fixture.observations().isEmpty)
}

@Test func codexSessionMissingCacheIsUnknownAndExplicitZeroIsMeasured() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(100, input: 100, cached: nil),
        fixture.event(90, input: 200, cached: nil),
        fixture.event(80, input: 300, cached: 0),
        fixture.event(70, input: 400, cached: 0),
    ])
    let observations = fixture.observations()
    #expect(observations.map(\.tokens.cachedInputTokens) == [0, nil, nil])
    #expect(observations.first?.hitRate == 0)
}

@Test func codexSessionSkipsMalformedPartialFutureAndStaleRecords() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(8000, input: 100, cached: 80),
        fixture.event(4000, input: 200, cached: 160),
        "not-json",
        fixture.event(-20, input: 9999, cached: 9000),
        fixture.event(10, input: 300, cached: 240),
    ], suffix: "{\"timestamp\":\"partial")
    let observations = fixture.observations()
    #expect(observations.count == 1)
    #expect(observations.first?.tokens.inputTokens == 100)
    #expect(observations.first?.tokens.cachedInputTokens == 80)
    #expect(fixture.observations(maximumAge: -1).isEmpty)
    #expect(fixture.observations(maximumAge: .infinity).isEmpty)
}

@Test func codexSessionCopiedAndForkedHistoryDoesNotDoubleCount() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let shared = [
        fixture.event(100, input: 100, cached: 80),
        fixture.event(90, input: 200, cached: 160),
    ]
    try fixture.write(shared, name: "original.jsonl")
    try fixture.write(shared + [fixture.event(10, input: 300, cached: 180)], name: "fork.jsonl")
    let observations = fixture.observations()
    #expect(observations.count == 2)
    #expect(observations.reduce(0) { $0 + $1.tokens.inputTokens } == 200)
}

@Test func codexSessionCounterResetEstablishesFreshBaseline() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(100, input: 1000, cached: 800),
        fixture.event(90, input: 100, cached: 0),
        fixture.event(80, input: 200, cached: 50),
    ])
    #expect(fixture.observations().map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 50)])
}

@Test func codexSessionInvalidAndOutOfOrderCountersDoNotContaminateBaseline() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(100, input: 100, cached: 80),
        fixture.event(200, input: 999, cached: 900),
        fixture.event(90, input: -1, cached: 0),
        fixture.event(80, input: 150, cached: 200),
        fixture.event(70, input: Int.max, cached: 0),
        fixture.event(10, input: 200, cached: 160),
    ])
    #expect(fixture.observations().map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
}

@Test func codexSessionIgnoresCompleteButUnterminatedFinalRecord() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(100, input: 100, cached: 80),
    ], suffix: fixture.event(10, input: 200, cached: 160))
    #expect(fixture.observations().isEmpty)
}

@Test func codexSessionDoesNotExposeTranscriptIdentityOrCurrentAuth() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let secret = "private-prompt-and-account-secret"
    try fixture.write([
        "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(secret)\"}}",
        "{\"type\":\"response_item\",\"payload\":{\"text\":\"\(secret)\"}}",
        fixture.event(100, input: 100, cached: 80),
        fixture.event(90, input: 200, cached: 160),
    ], name: secret + ".jsonl")
    try Data("{\"account_id\":\"\(secret)\"}".utf8).write(to: fixture.root.appendingPathComponent("auth.json"))
    let observations = fixture.observations()
    #expect(observations.count == 1)
    #expect(observations.first?.accountID == "codex-session-unattributed")
    #expect(observations.first?.accountName == "Codex · Account unknown")
    let normalized = String(decoding: try JSONEncoder().encode(observations), as: UTF8.self)
    #expect(!normalized.contains(secret))
}

@Test func codexSessionIgnoresSymbolicLinks() throws {
    let fixture = try CodexSessionFixture()
    let outside = try CodexSessionFixture()
    defer { fixture.remove(); outside.remove() }
    let target = try outside.write([outside.event(10, input: 100, cached: 0, lastInput: 100, lastCached: 0)])
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked.jsonl"), withDestinationURL: target)
    try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked-directory"), withDestinationURL: outside.root)
    #expect(fixture.observations().isEmpty)
    let linkedRoot = fixture.root.appendingPathComponent("linked-directory")
    #expect(CodexSessionTelemetryReader.observations(rootDirectory: linkedRoot, now: fixture.now).isEmpty)
}

@Test func codexSessionMeasuresDepthRelativeToRootWithAliasedAncestor() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let parent = fixture.root.appendingPathComponent("real-parent/extra")
    let actualRoot = parent.appendingPathComponent("sessions")
    let day = actualRoot.appendingPathComponent("2027/01/15")
    try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    let event = fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)
    try (event + "\n").write(to: day.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    let alias = fixture.root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: parent)

    let direct = CodexSessionTelemetryReader.observations(rootDirectory: actualRoot, now: fixture.now)
    let aliased = CodexSessionTelemetryReader.observations(
        rootDirectory: alias.appendingPathComponent("sessions"), now: fixture.now
    )

    #expect(direct.count == 1)
    #expect(aliased == direct)
}

@Test func codexSessionBoundsTailAndSkipsLargeLines() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    try fixture.write([
        fixture.event(200, input: 100, cached: 80),
        String(repeating: "x", count: CodexSessionTelemetryReader.maximumFileBytes + 100),
        fixture.event(100, input: 200, cached: 160),
        String(repeating: "x", count: CodexSessionTelemetryReader.maximumLineBytes + 1),
        fixture.event(90, input: 300, cached: 240),
    ])
    let observations = fixture.observations()
    #expect(observations.count == 1)
    #expect(observations.first?.tokens.inputTokens == 100)
}

@Test func codexSessionBoundsFileCount() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    for index in 0..<(CodexSessionTelemetryReader.maximumFiles + 2) {
        try fixture.write([
            fixture.event(TimeInterval(index), input: index + 1, cached: 0, lastInput: index + 1, lastCached: 0),
        ], name: "\(index).jsonl")
    }
    #expect(fixture.observations().count == CodexSessionTelemetryReader.maximumFiles)
}

@Test func codexSessionFindsTodayBeforeOversizedHistoricalTree() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let historicalDay = fixture.root.appendingPathComponent("2027/01/14")
    try FileManager.default.createDirectory(at: historicalDay, withIntermediateDirectories: true)
    // Empty directories exercise the discovery budget without thousands of
    // JSON writes or reads. Create historical entries before today's bucket.
    for index in 0...CodexSessionTelemetryReader.maximumEntries {
        try FileManager.default.createDirectory(
            at: historicalDay.appendingPathComponent("old-\(index)"),
            withIntermediateDirectories: false
        )
    }
    try fixture.write([fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)])
    #expect(fixture.observations().map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
}

@Test func codexSessionRetainsDirectRootCompatibility() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let event = fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)
    try (event + "\n").write(
        to: fixture.root.appendingPathComponent("direct.jsonl"), atomically: true, encoding: .utf8
    )
    #expect(fixture.observations().count == 1)
}

@Test func codexSessionFindsTodayBeforeOversizedTomorrowDirectory() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let tomorrow = fixture.root.appendingPathComponent("2027/01/16")
    try FileManager.default.createDirectory(at: tomorrow, withIntermediateDirectories: true)
    for index in 0...CodexSessionTelemetryReader.maximumEntries {
        try FileManager.default.createDirectory(
            at: tomorrow.appendingPathComponent("future-\(index)"),
            withIntermediateDirectories: false
        )
    }
    try fixture.write([fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)])
    #expect(fixture.observations().map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
}

@Test func codexSessionConsidersResumedFilesWithinCalendarHorizon() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let oldDay = fixture.root.appendingPathComponent("2026/02/01")
    try FileManager.default.createDirectory(at: oldDay, withIntermediateDirectories: true)
    let events = [
        fixture.event(100, input: 10_000, cached: 8_000),
        fixture.event(10, input: 10_100, cached: 8_080),
    ]
    try (events.joined(separator: "\n") + "\n").write(
        to: oldDay.appendingPathComponent("resumed.jsonl"), atomically: true, encoding: .utf8
    )
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now], ofItemAtPath: oldDay.appendingPathComponent("resumed.jsonl").path
    )
    // Modification time must keep the resumed older bucket in the bounded read
    // selection even when today's bucket already has the maximum file count.
    for index in 0..<CodexSessionTelemetryReader.maximumFiles {
        let file = try fixture.write([], name: "idle-\(index).jsonl")
        try FileManager.default.setAttributes([.modificationDate: fixture.now.addingTimeInterval(-100)], ofItemAtPath: file.path)
    }
    #expect(fixture.observations().map(\.tokens) == [PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)])
}

@Test func codexSessionDoesNotSearchBeyondCalendarHorizon() throws {
    let fixture = try CodexSessionFixture()
    defer { fixture.remove() }
    let oldDay = fixture.root.appendingPathComponent("2025/01/15")
    try FileManager.default.createDirectory(at: oldDay, withIntermediateDirectories: true)
    let event = fixture.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)
    try (event + "\n").write(
        to: oldDay.appendingPathComponent("old.jsonl"), atomically: true, encoding: .utf8
    )
    #expect(fixture.observations().isEmpty)
}

@Test func codexSessionRejectsSymlinkedCalendarDirectory() throws {
    let fixture = try CodexSessionFixture()
    let outside = try CodexSessionFixture()
    defer { fixture.remove(); outside.remove() }
    try outside.write([outside.event(10, input: 100, cached: 80, lastInput: 100, lastCached: 80)])
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("2027"),
        withDestinationURL: outside.root.appendingPathComponent("2027")
    )
    #expect(fixture.observations().isEmpty)
}
