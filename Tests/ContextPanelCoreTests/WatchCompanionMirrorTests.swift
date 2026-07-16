import ContextPanelCore
import ContextPanelWatchSupport
import Foundation
import Testing

@Test func watchCompanionMirrorUsesADedicatedWatchAppGroup() {
    #expect(ContextPanelLocations.watchAppGroupID == "group.com.shinycomputers.contextpanel.watch")
}

@Test func watchCompanionMirrorSharesDocumentsAndDisplayPreferences() throws {
    let root = try watchMirrorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mirrorURL = root.appending(path: "watch-mirror.json")
    let mirror = WatchCompanionMirror(mirrorURL: mirrorURL)
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchMirrorDocument(generatedAt: generatedAt)
    let preferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .anthropic, window: .weekly, isVisible: true, sortOrder: 0),
    ])

    #expect(mirror.save(document: document, displayPreferences: preferences, now: generatedAt))
    let loaded = mirror.load()
    #expect(loaded.result.document == document)
    #expect(loaded.displayPreferences == preferences)
    #expect(FileManager.default.fileExists(atPath: mirrorURL.path))
}

@Test func watchCompanionMirrorCreatesItsFirstNestedAppGroupDirectory() throws {
    let root = try watchMirrorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mirrorURL = root
        .appending(path: "Context Panel", directoryHint: .isDirectory)
        .appending(path: "Companion", directoryHint: .isDirectory)
        .appending(path: "watch-mirror.json")
    let mirror = WatchCompanionMirror(mirrorURL: mirrorURL)
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let document = watchMirrorDocument(generatedAt: generatedAt)

    #expect(mirror.save(document: document, displayPreferences: .defaultPreferences, now: generatedAt))
    #expect(mirror.load().result.document == document)
}

@Test func watchCompanionMirrorKeepsANewerDocumentAndItsPreferences() throws {
    let root = try watchMirrorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mirror = WatchCompanionMirror(mirrorURL: root.appending(path: "watch-mirror.json"))
    let newerDate = Date(timeIntervalSince1970: 1_800_000_100)
    let olderDate = newerDate.addingTimeInterval(-100)
    let newer = watchMirrorDocument(generatedAt: newerDate)
    let older = watchMirrorDocument(generatedAt: olderDate)
    let newerPreferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .google, window: .weekly, isVisible: true, sortOrder: 0),
    ])
    let olderPreferences = WidgetDisplayPreferences(mainLimits: [
        WidgetMainLimitPreference(provider: .openAI, window: .weekly, isVisible: true, sortOrder: 0),
    ])

    #expect(mirror.save(document: newer, displayPreferences: newerPreferences, now: newerDate))
    #expect(mirror.save(document: older, displayPreferences: olderPreferences, now: newerDate))
    let loaded = mirror.load()
    #expect(loaded.result.document == newer)
    #expect(loaded.displayPreferences == newerPreferences)
}

@Test func watchCompanionMirrorReportsUnavailableSharedStorage() {
    let mirror = WatchCompanionMirror(mirrorURL: nil)

    let result = mirror.load().result

    #expect(result.document == nil)
    #expect(result.status == .failure)
    #expect(!mirror.save(
        document: watchMirrorDocument(generatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
        displayPreferences: .defaultPreferences
    ))
}

@Test func watchCompanionMirrorTreatsAMissingPayloadAsNotYetSynced() throws {
    let root = try watchMirrorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mirror = WatchCompanionMirror(mirrorURL: root.appending(path: "missing.json"))

    let loaded = mirror.load()

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .unknown)
    #expect(loaded.displayPreferences == nil)
}

@Test func watchCompanionMirrorRejectsACorruptPayload() throws {
    let root = try watchMirrorTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mirrorURL = root.appending(path: "watch-mirror.json")
    try Data("not-json".utf8).write(to: mirrorURL)
    let mirror = WatchCompanionMirror(mirrorURL: mirrorURL)

    let loaded = mirror.load()

    #expect(loaded.result.document == nil)
    #expect(loaded.result.status == .failure)
    #expect(loaded.displayPreferences == nil)
}

private func watchMirrorDocument(generatedAt: Date) -> CompanionSyncDocument {
    CompanionSyncDocument(snapshot: CompanionSnapshot(
        generatedAt: generatedAt,
        publishedAt: generatedAt.addingTimeInterval(5),
        limits: [],
        providerStatuses: [],
        promptCacheSummaries: []
    ))
}

private func watchMirrorTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-watch-mirror-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
