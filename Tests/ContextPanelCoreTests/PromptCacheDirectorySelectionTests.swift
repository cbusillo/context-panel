import Foundation
import Testing

@testable import ContextPanelCore

private struct PromptCacheDirectoryFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func directory(_ path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func link(_ path: String, to target: URL) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func promptCacheDirectorySelectionAcceptsSymlinkTargetsInBothDirections() throws {
    let fixture = try PromptCacheDirectoryFixture()
    defer { fixture.remove() }
    let actual = try fixture.directory("storage/sessions")
    let link = try fixture.link("sessions", to: actual)
    let parentLink = try fixture.link("client", to: actual.deletingLastPathComponent())
    let nested = parentLink.appending(path: "sessions")

    for expected in [actual, link, nested] {
        for selected in [actual, link, nested] {
            #expect(ContextPanelLocations.promptCacheDirectorySelectionMatches(selected: selected, expected: expected))
        }
    }
    #expect(ContextPanelLocations.normalizedPath(link.path) != ContextPanelLocations.normalizedPath(actual.path))
}

@Test func promptCacheDirectorySelectionRejectsOtherDirectoriesAndUnavailableTargets() throws {
    let fixture = try PromptCacheDirectoryFixture()
    defer { fixture.remove() }
    let expected = try fixture.directory("configured/sessions")
    let other = try fixture.directory("unrelated/sessions")
    let child = try fixture.directory("configured/sessions/child")
    let missing = fixture.root.appending(path: "missing")
    let broken = try fixture.link("broken", to: missing)
    let file = fixture.root.appending(path: "file.json")
    try Data().write(to: file)

    for selected in [other, child, expected.deletingLastPathComponent(), missing, broken, file] {
        #expect(!ContextPanelLocations.promptCacheDirectorySelectionMatches(selected: selected, expected: expected))
    }
    #expect(!ContextPanelLocations.promptCacheDirectorySelectionMatches(selected: missing, expected: missing))
    #expect(!ContextPanelLocations.promptCacheDirectorySelectionMatches(selected: expected, expected: broken))
}

#if os(macOS)
@Test func promptCacheLabUpgradeRequiresSessionsGrantAndKeepsLegacyBookmark() throws {
    let fixture = try PromptCacheDirectoryFixture()
    defer { fixture.remove() }
    let usage = try fixture.directory(".codex-lab/usage")
    let sessions = try fixture.directory(".codex-lab/sessions")
    let account = LocalProviderAccountConfiguration(
        id: "retained-lab-account", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Codex Lab", authPath: usage.deletingLastPathComponent().appending(path: "auth_accounts.json").path,
        codexClient: .codexLab
    )
    let decoded = try JSONDecoder().decode(LocalProviderAccountConfiguration.self, from: JSONEncoder().encode(account))
    #expect(decoded == account)
    #expect(decoded.promptCacheDirectory?.path == sessions.path)
    let store = SecureFileBookmarkStore(storeURL: fixture.root.appending(path: "bookmarks.json"))
    let oldKey = ContextPanelLocations.normalizedPath(usage.path)
    let newKey = ContextPanelLocations.normalizedPath(sessions.path)
    try store.createAndStoreBookmark(for: usage, path: oldKey)
    let oldBookmark = try #require(store.currentBookmarkData(for: oldKey))
    #expect(!store.hasCurrentBookmark(for: newKey))
    try store.createAndStoreBookmark(for: sessions, path: newKey)
    #expect(store.currentBookmarkData(for: oldKey) == oldBookmark)
    #expect(store.hasCurrentBookmark(for: newKey))
    #expect(store.canResolveBookmark(for: newKey))
}

@Test(arguments: [true, false])
func promptCacheSymlinkKeepsLogicalKeyAndSingleMirrorIdentity(usesBookmark: Bool) throws {
    let fixture = try PromptCacheDirectoryFixture()
    defer { fixture.remove() }
    let selected = try fixture.directory("storage/sessions")
    _ = try fixture.directory(".codex")
    let configured = try fixture.link(".codex/sessions", to: selected)
    let key = ContextPanelLocations.normalizedPath(configured.path)
    let realKey = ContextPanelLocations.normalizedPath(selected.path)
    let store = SecureFileBookmarkStore(storeURL: fixture.root.appending(path: "bookmarks.json"))
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let timestamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-10))
    let payload = """
    {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":70},"last_token_usage":{"input_tokens":100,"cached_input_tokens":70}}}}
    """
    try (payload + "\n").write(to: selected.appending(path: "session.jsonl"), atomically: true, encoding: .utf8)

    #expect(ContextPanelLocations.promptCacheDirectorySelectionMatches(selected: selected, expected: configured))
    if usesBookmark {
        try store.createAndStoreBookmark(for: selected, path: key)
        #expect(store.hasCurrentBookmark(for: key))
        #expect(!store.hasStoredBookmark(for: realKey))
        let resolvedPath = try store.withResolvedURL(for: key) { $0.resolvingSymlinksInPath().path }
        #expect(resolvedPath == selected.resolvingSymlinksInPath().path)
    }

    let destination = fixture.root.appending(path: "mirror")
    for refresh in [now, now.addingTimeInterval(1)] {
        let result = try PromptCacheTelemetryMirrorService.mirror(
            bookmarkStore: usesBookmark ? store : nil, sourceDirectories: [configured], sourceClients: [key: .codex],
            now: refresh, destination: destination
        )
        #expect(result.copied == 1)
    }
    let sourceID = ConnectorRedactor.localAccountID(provider: .openAI, path: key)
    let directories = try FileManager.default.contentsOfDirectory(atPath: destination.path)
    #expect(directories == [sourceID])
    let observations = PromptCacheTelemetryReader.mirroredObservations(rootDirectory: destination, now: now.addingTimeInterval(1))
    #expect(observations.count == 1)
    #expect(observations.first?.tokens.inputTokens == 100)
    #expect(observations.first?.tokens.cachedInputTokens == 70)
}
#endif
