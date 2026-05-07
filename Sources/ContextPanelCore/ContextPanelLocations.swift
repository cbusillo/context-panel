import Foundation

public enum ContextPanelLocations {
    public static let appGroupID = "group.com.shinycomputers.contextpanel"

    public static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    public static func snapshotDirectory(appGroupID: String? = nil) -> URL {
        if
            let appGroupID,
            let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        {
            return containerURL
                .appending(path: "Context Panel", directoryHint: .isDirectory)
                .appending(path: "Snapshots", directoryHint: .isDirectory)
        }

        return applicationSupportDirectory()
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    public static func accountConfigurationURL() -> URL {
        applicationSupportDirectory().appending(path: "accounts.json")
    }
}
