import Foundation

public enum CodexHomeDiscovery {
    /// Metadata-only discovery in an explicitly user-authorized directory.
    /// Never read auth.json contents or follow unselected child symlinks.
    public static func find(in root: URL, fileManager: FileManager = .default) throws -> [URL] {
        if hasRegularAuthFile(root) { return [root] }
        return try fileManager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [])
            .filter { candidate in
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                return values.isDirectory == true && values.isSymbolicLink != true
                    && hasRegularAuthFile(candidate)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
    private static func hasRegularAuthFile(_ home: URL) -> Bool {
        let values = try? home.appending(path: "auth.json").resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}
