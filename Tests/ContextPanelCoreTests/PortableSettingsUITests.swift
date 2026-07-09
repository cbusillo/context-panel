@testable import ContextPanelCore
import ContextPanelSettingsUI
import Foundation
import SwiftUI
import Testing

@Test func companionWidgetDisplayPreferencesURLRequiresSharedStorage() {
    let unavailableURL = ContextPanelLocations.companionWidgetDisplayPreferencesURL(
        appGroupID: "missing.group"
    ) { _ in nil }
    let availableURL = ContextPanelLocations.companionWidgetDisplayPreferencesURL(
        appGroupID: "available.group"
    ) { _ in
        URL(fileURLWithPath: "/tmp/context-panel-group", isDirectory: true)
    }

    #expect(unavailableURL == nil)
    #expect(availableURL?.path == "/tmp/context-panel-group/Context Panel/widget-display-preferences.json")
}

@Test func companionWidgetDisplayPreferencesPreferLocalOverride() {
    var synced = WidgetDisplayPreferences.defaultPreferences
    synced.setMainLimit(provider: .openAI, window: .weekly, isVisible: false)
    var local = WidgetDisplayPreferences.defaultPreferences
    local.setMainLimit(provider: .anthropic, window: .weekly, isVisible: false)

    #expect(WidgetDisplayPreferences.companionEffectivePreferences(
        localOverride: local,
        synced: synced
    ) == local)
    #expect(WidgetDisplayPreferences.companionEffectivePreferences(
        localOverride: nil,
        synced: synced
    ) == synced)
    #expect(WidgetDisplayPreferences.companionEffectivePreferences(
        localOverride: nil,
        synced: nil
    ) == .defaultPreferences)
}

@MainActor
@Test func portableSettingsControlsExposeValueAndActionAPIs() {
    let colors = ContextPanelSettingsControlColors()

    _ = CompanionRefreshSettingsControl(
        settings: .defaultSettings,
        errorMessage: nil,
        colors: colors,
        onIntervalChange: { _ in }
    )
    _ = CompanionAppearanceSettingsControl(
        settings: .defaultSettings,
        errorMessage: nil,
        colors: colors,
        onAppAppearanceChange: { _ in },
        onWidgetAppearanceChange: { _ in }
    )
    _ = WidgetMainLimitSettingsRows(
        preferences: .defaultPreferences,
        colors: colors,
        providerLabel: { provider in Text(provider.shortName) },
        onVisibilityChange: { _, _ in },
        onMove: { _, _ in }
    )
}

@Test func portableSettingsUISourceHasNoAdministrativePlatformDependencies() throws {
    let sourceDirectory = try repositoryRoot()
        .appending(path: "Sources/ContextPanelSettingsUI", directoryHint: .isDirectory)
    let sourceURLs = try FileManager.default.contentsOfDirectory(
        at: sourceDirectory,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    let source = try sourceURLs.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    let forbiddenSymbols = [
        "import AppKit",
        "import UIKit",
        "import ServiceManagement",
        "import Security",
        "import UserNotifications",
        "import WidgetKit",
        "import CloudKit",
        "NSOpenPanel",
        "NSWorkspace",
        "SMAppService",
        "UNUserNotificationCenter",
        "ProviderCredentialStore",
        "SecureFileBookmark",
        "LimitWarningWebhook",
        "SnapshotRefreshService",
        "AccountConfigurationStore",
    ]

    for symbol in forbiddenSymbols {
        #expect(!source.contains(symbol))
    }
}

private func repositoryRoot() throws -> URL {
    var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while candidate.path != "/" {
        if FileManager.default.fileExists(atPath: candidate.appending(path: "Package.swift").path) {
            return candidate
        }
        candidate.deleteLastPathComponent()
    }
    throw CocoaError(.fileNoSuchFile)
}
