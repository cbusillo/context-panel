import Foundation
import Darwin

public enum ContextPanelLocations {
    public static let appGroupID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
    public static let companionAppGroupID = "group.com.shinycomputers.contextpanel"
    public static let iCloudContainerID = "iCloud.com.shinycomputers.contextpanel"
    public static let appBundleID = "com.shinycomputers.contextpanel"
    public static let companionAppBundleID = "com.shinycomputers.contextpanel"
    public static let widgetExtensionBundleID = "com.shinycomputers.contextpanel.widget"
    public static let companionWidgetExtensionBundleID = "com.shinycomputers.contextpanel.widget"
    public static let refreshAgentBundleID = "com.shinycomputers.contextpanel.refresh-agent"
    public static let companionSyncDocumentFileName = "context-panel-companion.json"

    public static var isRunningInAppSandbox: Bool {
        getenv("APP_SANDBOX_CONTAINER_ID") != nil
            || environmentFlag("CONTEXT_PANEL_APP_SANDBOX")
    }

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? platformApplicationSupportFallbackDirectory()
        return base.appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    public static func bookmarkStoreURL() -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "file-bookmarks.json")
        }
        return applicationSupportDirectory().appending(path: "file-bookmarks.json")
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

    public static func widgetSandboxLocalSnapshotDirectory() -> URL {
        applicationSupportDirectory()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func widgetContainerLocalSnapshotDirectory() -> URL {
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

    public static func widgetSandboxLocalDisplayPreferencesURL() -> URL {
        applicationSupportDirectory().appending(path: "widget-display-preferences.json")
    }

    public static func widgetSandboxLocalFastModeForecastSettingsURL() -> URL {
        applicationSupportDirectory().appending(path: "fast-mode-forecast-settings.json")
    }

    public static func companionSyncDocumentURL(appGroupID: String? = nil) -> URL {
        companionSyncDirectory(appGroupID: appGroupID)
            .appending(path: companionSyncDocumentFileName)
    }

    public static func companionRefreshSettingsURL(appGroupID: String = companionAppGroupID) -> URL? {
        companionRefreshSettingsURL(appGroupID: appGroupID) { appGroupContainerURL(appGroupID: $0) }
    }

    public static func companionAppearanceSettingsURL(appGroupID: String = companionAppGroupID) -> URL? {
        companionAppearanceSettingsURL(appGroupID: appGroupID) { appGroupContainerURL(appGroupID: $0) }
    }

    static func companionRefreshSettingsURL(
        appGroupID: String,
        containerURL: (String) -> URL?
    ) -> URL? {
        guard let containerURL = containerURL(appGroupID) else {
            return nil
        }
        return companionSyncDirectory(containerURL: containerURL)
            .appending(path: "companion-refresh-settings.json")
    }

    static func companionAppearanceSettingsURL(
        appGroupID: String,
        containerURL: (String) -> URL?
    ) -> URL? {
        guard let containerURL = containerURL(appGroupID) else {
            return nil
        }
        return companionSyncDirectory(containerURL: containerURL)
            .appending(path: "companion-appearance-settings.json")
    }

    public static func companionAppGroupSyncDocumentURL(
        appGroupID: String = companionAppGroupID
    ) -> URL? {
        guard let containerURL = appGroupContainerURL(appGroupID: appGroupID) else {
            return nil
        }
        return companionSyncDirectory(containerURL: containerURL)
            .appending(path: companionSyncDocumentFileName)
    }

    public static func companionSyncStoreSet(
        appGroupID: String? = appGroupID,
        iCloudContainerID: String? = iCloudContainerID
    ) -> CompanionSyncStoreSet {
        let localStore = CompanionSyncStore(documentURL: companionSyncDocumentURL(appGroupID: appGroupID))
        return CompanionSyncStoreSet(stores: [localStore])
    }

    public static func accountConfigurationURL() -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "accounts.json")
        }

        return applicationSupportDirectory().appending(path: "accounts.json")
    }

    private static func companionSyncDirectory(appGroupID: String?) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return companionSyncDirectory(containerURL: containerURL)
        }

        return applicationSupportDirectory()
            .appending(path: "Companion", directoryHint: .isDirectory)
    }

    private static func companionSyncDirectory(containerURL: URL) -> URL {
        containerURL
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Companion", directoryHint: .isDirectory)
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

    public static func backgroundRefreshSettingsURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "background-refresh-settings.json")
        }

        return applicationSupportDirectory().appending(path: "background-refresh-settings.json")
    }

    public static func refreshDiagnosticsStateURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "refresh-diagnostics-state.json")
        }

        return applicationSupportDirectory().appending(path: "refresh-diagnostics-state.json")
    }

    public static func resetExpiryRefreshStateURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "reset-expiry-refresh-state.json")
        }

        return applicationSupportDirectory().appending(path: "reset-expiry-refresh-state.json")
    }

    public static func limitWarningSettingsURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "limit-warning-settings.json")
        }

        return applicationSupportDirectory().appending(path: "limit-warning-settings.json")
    }

    public static func limitWarningStateURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "limit-warning-state.json")
        }

        return applicationSupportDirectory().appending(path: "limit-warning-state.json")
    }

    public static func limitWarningPendingNotificationsURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "limit-warning-pending-notifications.json")
        }

        return applicationSupportDirectory().appending(path: "limit-warning-pending-notifications.json")
    }

    public static func webhookSettingsURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "webhook-settings.json")
        }

        return applicationSupportDirectory().appending(path: "webhook-settings.json")
    }

    public static func webhookDeliveryStateURL(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "webhook-delivery-state.json")
        }

        return applicationSupportDirectory().appending(path: "webhook-delivery-state.json")
    }

    public static func everyCodeUsageDirectory() -> URL {
        let defaultUsageDirectory = realUserHomeDirectory()
            .appending(path: ".code", directoryHint: .isDirectory)
            .appending(path: "usage", directoryHint: .isDirectory)
        return everyCodeUsageDirectories().first ?? defaultUsageDirectory
    }

    public static func everyCodeUsageDirectories() -> [URL] {
        everyCodeUsageDirectories(
            environment: ProcessInfo.processInfo.environment,
            fileManager: .default
        )
    }

    static func everyCodeUsageDirectories(
        environment: [String: String],
        fileManager: FileManager
    ) -> [URL] {
        var candidates: [URL] = []
        if let codeHome = environment["CODE_HOME"], !codeHome.isEmpty {
            candidates.append(URL(fileURLWithPath: codeHome, isDirectory: true)
                .appending(path: "usage", directoryHint: .isDirectory))
        }
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            candidates.append(URL(fileURLWithPath: codexHome, isDirectory: true)
                .appending(path: "usage", directoryHint: .isDirectory))
        }

        let defaultUsageDirectory = realUserHomeDirectory()
            .appending(path: ".code", directoryHint: .isDirectory)
            .appending(path: "usage", directoryHint: .isDirectory)
        candidates.append(defaultUsageDirectory)

        let directories = candidates.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { normalizedPath($0.path) == normalizedPath(url.path) }) {
                result.append(url)
            }
        }
        return directories.first(where: { fileManager.fileExists(atPath: $0.path) })
            .map { [$0] }
            ?? Array(directories.prefix(1))
    }

    public static func promptCacheUsageDirectory(forAuthPath authPath: String?) -> URL? {
        guard let authPath else { return nil }
        let expanded = NSString(string: authPath).expandingTildeInPath
        let authDirectory = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        let name = authDirectory.lastPathComponent
        guard name == ".code" || name == ".codex" || name.hasPrefix(".code-") || name.hasPrefix(".codex-") else {
            return nil
        }
        return authDirectory.appending(path: "usage", directoryHint: .isDirectory)
    }

    public static func promptCacheTelemetryDirectory(appGroupID: String? = nil) -> URL {
        if let containerURL = appGroupContainerURL(appGroupID: appGroupID) {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "PromptCache", directoryHint: .isDirectory)
        }

        return applicationSupportDirectory()
            .appending(path: "PromptCache", directoryHint: .isDirectory)
    }

    public static func promptCacheMirrorTargetURL(
        destination: URL,
        sourceDirectory: URL,
        fileURL: URL
    ) -> URL {
        let sourceID = ConnectorRedactor.localAccountID(provider: .openAI, path: normalizedPath(sourceDirectory.path))
        return destination
            .appending(path: sourceID, directoryHint: .isDirectory)
            .appending(path: fileURL.lastPathComponent)
    }

    public static func normalizedPath(_ path: String) -> String {
        var normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized.hasPrefix("/private/var/") {
            normalized = "/var/" + normalized.dropFirst("/private/var/".count)
        }
        return normalized
    }

    public static func realUserHomeDirectory() -> URL {
        if let passwd = getpwuid(getuid()), let homeDirectory = passwd.pointee.pw_dir {
            let home = String(cString: homeDirectory)
            if !home.isEmpty {
                return URL(fileURLWithPath: home, isDirectory: true)
            }
        }
        #if os(macOS)
        if let user = ProcessInfo.processInfo.environment["USER"],
           let home = NSHomeDirectoryForUser(user), !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
        #else
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private static func platformApplicationSupportFallbackDirectory() -> URL {
        #if os(macOS)
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        #else
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
        #endif
    }

    private static func hostApplicationSupportDirectory() -> URL {
        realUserHomeDirectory()
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    private static func environmentFlag(_ name: String) -> Bool {
        guard let value = getenv(name) else { return false }
        return String(cString: value) == "1"
    }

    private static func appGroupContainerURL(appGroupID: String?) -> URL? {
        guard let appGroupID else { return nil }
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return containerURL
        }
        return nil
    }
}
