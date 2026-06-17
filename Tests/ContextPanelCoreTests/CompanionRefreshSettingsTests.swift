@testable import ContextPanelCore
import Foundation
import Testing

@Test func companionRefreshSettingsDefaultsToFiveMinutes() {
    let settings = CompanionRefreshSettings.defaultSettings

    #expect(settings.intervalMinutes == 5)
    #expect(settings.intervalSeconds == 300)
    #expect(settings.interval == 300)
    #expect(settings.widgetIntervalSeconds == 900)
    #expect(settings.widgetInterval == 900)
}

@Test func companionRefreshSettingsClampToAllowedCadence() {
    #expect(CompanionRefreshSettings(intervalMinutes: 1).intervalMinutes == 5)
    #expect(CompanionRefreshSettings(intervalMinutes: 9).intervalMinutes == 10)
    #expect(CompanionRefreshSettings(intervalMinutes: 14).intervalMinutes == 15)
    #expect(CompanionRefreshSettings(intervalMinutes: 45).intervalMinutes == 30)
    #expect(CompanionRefreshSettings(intervalMinutes: 999).intervalMinutes == 60)
    #expect(CompanionRefreshSettings(intervalMinutes: 10).widgetIntervalSeconds == 900)
    #expect(CompanionRefreshSettings(intervalMinutes: 30).widgetIntervalSeconds == 1_800)
}

@Test func companionRefreshSettingsStoreRoundTripsAndFallsBackToDefault() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "companion-refresh-settings.json")
    let store = CompanionRefreshSettingsStore(settingsURL: url)

    #expect(store.load() == .defaultSettings)

    let saved = CompanionRefreshSettings(intervalMinutes: 30)
    try store.save(saved)

    #expect(store.load() == saved)

    try Data(#"{"schemaVersion":99,"intervalMinutes":15}"#.utf8).write(to: url)
    #expect(store.loadIfAvailable() == nil)
    #expect(store.load() == .defaultSettings)

    try Data("not-json".utf8).write(to: url)
    #expect(store.loadIfAvailable() == nil)
    #expect(store.load() == .defaultSettings)
}

@Test func companionRefreshSettingsURLRequiresSharedCompanionStorage() {
    let unavailableURL = ContextPanelLocations.companionRefreshSettingsURL(appGroupID: "missing.group") { _ in nil }
    let availableURL = ContextPanelLocations.companionRefreshSettingsURL(appGroupID: "available.group") { _ in
        URL(fileURLWithPath: "/tmp/context-panel-group", isDirectory: true)
    }

    #expect(unavailableURL == nil)
    #expect(availableURL?.path == "/tmp/context-panel-group/Context Panel/Companion/companion-refresh-settings.json")
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-companion-refresh-settings-tests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
