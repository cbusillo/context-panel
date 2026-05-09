import Foundation

public enum ContextPanelLocations {
    public static let appGroupID = "group.com.shinycomputers.contextpanel"
    public static let macAppStoreAppGroupID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
    public static let widgetExtensionBundleID = "com.shinycomputers.contextpanel.widget"
    public static let refreshAgentBundleID = "com.shinycomputers.contextpanel.refresh-agent"

    public static var isRunningInAppSandbox: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static var usesDevelopmentWidgetMirrors: Bool {
        !isRunningInAppSandbox
    }

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    public static func snapshotDirectory(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "Snapshots", directoryHint: .isDirectory)
        }

        return applicationSupportDirectory()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func widgetDevelopmentSnapshotDirectory() -> URL {
        applicationSupportDirectory()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func hostDevelopmentSnapshotDirectory() -> URL {
        hostApplicationSupportDirectory()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func widgetDevelopmentContainerSnapshotDirectory() -> URL {
        realUserHomeDirectory()
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Containers", directoryHint: .isDirectory)
            .appending(path: widgetExtensionBundleID, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func widgetDevelopmentDisplayPreferencesURL() -> URL {
        applicationSupportDirectory().appending(path: "widget-display-preferences.json")
    }

    public static func widgetDevelopmentFastModeForecastSettingsURL() -> URL {
        applicationSupportDirectory().appending(path: "fast-mode-forecast-settings.json")
    }

    public static func hostDevelopmentDisplayPreferencesURL() -> URL {
        hostApplicationSupportDirectory().appending(path: "widget-display-preferences.json")
    }

    public static func hostDevelopmentFastModeForecastSettingsURL() -> URL {
        hostApplicationSupportDirectory().appending(path: "fast-mode-forecast-settings.json")
    }

    public static func widgetDevelopmentContainerDisplayPreferencesURL() -> URL {
        realUserHomeDirectory()
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Containers", directoryHint: .isDirectory)
            .appending(path: widgetExtensionBundleID, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "widget-display-preferences.json")
    }

    public static func widgetDevelopmentContainerFastModeForecastSettingsURL() -> URL {
        realUserHomeDirectory()
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Containers", directoryHint: .isDirectory)
            .appending(path: widgetExtensionBundleID, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "fast-mode-forecast-settings.json")
    }

    public static func accountConfigurationURL() -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "accounts.json")
        }

        return applicationSupportDirectory().appending(path: "accounts.json")
    }

    public static func legacyAccountConfigurationURL() -> URL {
        applicationSupportDirectory().appending(path: "accounts.json")
    }

    public static func widgetDisplayPreferencesURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "widget-display-preferences.json")
        }

        return applicationSupportDirectory().appending(path: "widget-display-preferences.json")
    }

    public static func fastModeForecastSettingsURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "fast-mode-forecast-settings.json")
        }

        return applicationSupportDirectory().appending(path: "fast-mode-forecast-settings.json")
    }

    private static func hostApplicationSupportDirectory() -> URL {
        realUserHomeDirectory()
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    private static func appGroupContainerURL(appGroupID: String?) -> URL? {
        let groupIDs = appGroupID == Self.appGroupID
            ? [Self.appGroupID, Self.macAppStoreAppGroupID]
            : [appGroupID].compactMap { $0 }

        for groupID in groupIDs {
            if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
                return containerURL
            }
        }

        return nil
    }

    private static func realUserHomeDirectory() -> URL {
        if let home = NSHomeDirectoryForUser(NSUserName()), !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
