import Foundation

public enum CodexHomeDiscovery {
    /// Metadata-only discovery in an explicitly user-authorized directory.
    /// Never read auth.json contents or follow unselected child symlinks.
    public static func find(in root: URL, fileManager: FileManager = .default) throws -> [URL] {
        if fileManager.fileExists(atPath: root.appending(path: "auth.json").path) { return [root] }
        return try fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            .filter { candidate in
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
                    && fileManager.fileExists(atPath: candidate.appending(path: "auth.json").path)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
