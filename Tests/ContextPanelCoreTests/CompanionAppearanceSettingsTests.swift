@testable import ContextPanelCore
import Foundation
import Testing

@Test func companionAppearanceSettingsDefaultsToVisionOSDarkAndMatchingWidget() {
    let settings = CompanionAppearanceSettings.defaultSettings

    #expect(settings.visionOSAppAppearance == .dark)
    #expect(settings.visionOSWidgetAppearance == .matchApp)
    #expect(settings.resolvedVisionOSWidgetAppearance == .dark)
}

@Test func companionAppearanceSettingsResolvesWidgetAppearance() {
    #expect(CompanionAppearanceSettings(
        visionOSAppAppearance: .light,
        visionOSWidgetAppearance: .matchApp
    ).resolvedVisionOSWidgetAppearance == .light)
    #expect(CompanionAppearanceSettings(
        visionOSAppAppearance: .light,
        visionOSWidgetAppearance: .dark
    ).resolvedVisionOSWidgetAppearance == .dark)
    #expect(CompanionAppearanceSettings(
        visionOSAppAppearance: .dark,
        visionOSWidgetAppearance: .light
    ).resolvedVisionOSWidgetAppearance == .light)
}

@Test func companionAppearanceSettingsStoreRoundTripsAndFallsBackToDefault() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appending(path: "companion-appearance-settings.json")
    let store = CompanionAppearanceSettingsStore(settingsURL: url)

    #expect(store.load() == .defaultSettings)

    let saved = CompanionAppearanceSettings(
        visionOSAppAppearance: .light,
        visionOSWidgetAppearance: .dark
    )
    try store.save(saved)

    #expect(store.load() == saved)

    try Data(#"{"schemaVersion":99,"visionOSAppAppearance":"dark","visionOSWidgetAppearance":"matchApp"}"#.utf8)
        .write(to: url)
    #expect(store.loadIfAvailable() == nil)
    #expect(store.load() == .defaultSettings)

    try Data("not-json".utf8).write(to: url)
    #expect(store.loadIfAvailable() == nil)
    #expect(store.load() == .defaultSettings)
}

@Test func companionAppearanceSettingsURLRequiresSharedCompanionStorage() {
    let unavailableURL = ContextPanelLocations.companionAppearanceSettingsURL(appGroupID: "missing.group") { _ in nil }
    let availableURL = ContextPanelLocations.companionAppearanceSettingsURL(appGroupID: "available.group") { _ in
        URL(fileURLWithPath: "/tmp/context-panel-group", isDirectory: true)
    }

    #expect(unavailableURL == nil)
    #expect(availableURL?.path == "/tmp/context-panel-group/Context Panel/Companion/companion-appearance-settings.json")
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-companion-appearance-settings-tests")
        .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
