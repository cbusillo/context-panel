import Foundation
import Darwin

public enum ContextPanelLocations {
    public static let appGroupID = "MM5YXC7T6E.group.com.shinycomputers.contextpanel"
    public static let companionAppGroupID = "group.com.shinycomputers.contextpanel"
    public static let watchAppGroupID = companionAppGroupID
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

    public static func googleAntigravityStatusLineSnapshotURL(
        appGroupID: String = appGroupID
    ) -> URL? {
        guard let containerURL = appGroupContainerURL(appGroupID: appGroupID) else {
            return nil
        }
        return containerURL
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Provider Inputs", directoryHint: .isDirectory)
            .appending(path: "antigravity-status-line.json")
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

    public static func companionWidgetDisplayPreferencesURL(appGroupID: String = companionAppGroupID) -> URL? {
        companionWidgetDisplayPreferencesURL(appGroupID: appGroupID) { appGroupContainerURL(appGroupID: $0) }
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

    static func companionWidgetDisplayPreferencesURL(
        appGroupID: String,
        containerURL: (String) -> URL?
    ) -> URL? {
        guard let containerURL = containerURL(appGroupID) else {
            return nil
        }
        return containerURL
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "widget-display-preferences.json")
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

    public static func companionCloudKitUserScopeStateURL(
        appGroupID: String = companionAppGroupID
    ) -> URL? {
        guard let containerURL = appGroupContainerURL(appGroupID: appGroupID) else {
            return nil
        }
        return companionSyncDirectory(containerURL: containerURL)
            .appending(path: "cloudkit-user-scope.json")
    }

    public static func watchCompanionCacheURL() -> URL {
        watchCompanionAppGroupCacheURL() ?? watchCompanionProcessCacheURL()
    }

    public static func watchCompanionAppGroupCacheURL(
        appGroupID: String = watchAppGroupID
    ) -> URL? {
        watchCompanionAppGroupCacheURL(appGroupID: appGroupID) {
            appGroupContainerURL(appGroupID: $0)
        }
    }

    static func watchCompanionAppGroupCacheURL(
        appGroupID: String,
        containerURL: (String) -> URL?
    ) -> URL? {
        guard let containerURL = containerURL(appGroupID) else { return nil }
        return companionSyncDirectory(containerURL: containerURL)
            .appending(path: "context-panel-watch-cache.json")
    }

    public static func watchCompanionProcessCacheURL() -> URL {
        applicationSupportDirectory()
            .appending(path: "Companion", directoryHint: .isDirectory)
            .appending(path: "context-panel-watch-cache.json")
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

    public static func runtimeValidationDirectory(appGroupID: String? = nil) -> URL {
        if let appGroupID,
           let directoryURL = sharedRuntimeValidationDirectory(appGroupID: appGroupID) {
            return directoryURL
        }

        return applicationSupportDirectory()
            .appending(path: "Validation", directoryHint: .isDirectory)
    }

    public static func sharedRuntimeValidationDirectory(appGroupID: String) -> URL? {
        guard let containerURL = appGroupContainerURL(appGroupID: appGroupID) else {
            return nil
        }
        #if os(tvOS)
        return containerURL
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "Caches", directoryHint: .isDirectory)
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Validation", directoryHint: .isDirectory)
        #else
        return containerURL
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Validation", directoryHint: .isDirectory)
        #endif
    }

    public static func runtimeValidationSessionURL(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "runtime-session.json")
    }

    public static func archivedRuntimeValidationSessionURL(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "runtime-session-last.json")
    }

    public static func runtimeValidationSessionsDirectory(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "Runtime Sessions", directoryHint: .isDirectory)
    }

    public static func runtimeReceiptDirectory(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "Runtime Receipts", directoryHint: .isDirectory)
    }

    public static func runtimeReceiptInboxDirectory(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "Remote Runtime Receipts", directoryHint: .isDirectory)
    }

    public static func runtimeReceiptRelayStateURL(appGroupID: String? = nil) -> URL {
        runtimeValidationDirectory(appGroupID: appGroupID)
            .appending(path: "runtime-receipt-relay-state.json")
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

    public static func codexTelemetryDirectories() -> [URL] {
        [CodexClient.codex, .codexLab].map { client in
            client.homeDirectory().appending(path: client.telemetryFolderName, directoryHint: .isDirectory)
        }
    }

    public static func promptCacheUsageDirectory(forAuthPath authPath: String?) -> URL? {
        guard let authPath, let client = CodexClient.inferred(fromAuthPath: authPath), client != .everyCode else { return nil }
        let expanded = NSString(string: authPath).expandingTildeInPath
        let authDirectory = URL(fileURLWithPath: expanded).deletingLastPathComponent()
        return authDirectory.appending(path: client.telemetryFolderName, directoryHint: .isDirectory)
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
        promptCacheMirrorTargetURL(
            destination: destination,
            sourceIDPath: normalizedPath(sourceDirectory.path),
            fileURL: fileURL
        )
    }

    public static func promptCacheMirrorTargetURL(
        destination: URL,
        sourceIDPath: String,
        fileURL: URL
    ) -> URL {
        let sourceID = ConnectorRedactor.localAccountID(provider: .openAI, path: normalizedPath(sourceIDPath))
        return destination
            .appending(path: sourceID, directoryHint: .isDirectory)
            .appending(path: fileURL.lastPathComponent)
    }

    /// Compare a user-selected telemetry folder without changing its stored source identity.
    public static func promptCacheDirectorySelectionMatches(selected: URL, expected: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: selected.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        if normalizedPath(selected.path) == normalizedPath(expected.path) { return true }
        return normalizedPath(selected.resolvingSymlinksInPath().path)
            == normalizedPath(expected.resolvingSymlinksInPath().path)
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
