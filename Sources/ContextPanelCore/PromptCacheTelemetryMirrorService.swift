import Foundation

public struct PromptCacheTelemetryMirrorResult: Equatable, Sendable {
    public let copied: Int
    public let removed: Int

    public init(copied: Int, removed: Int) {
        self.copied = copied
        self.removed = removed
    }
}

public enum PromptCacheTelemetryMirrorService {
    public static func mirror(
        sourceDirectories: [URL] = ContextPanelLocations.everyCodeUsageDirectories(),
        destination: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        fileManager: FileManager = .default
    ) throws -> PromptCacheTelemetryMirrorResult {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied = 0
        var removed = 0
        var seenSources = Set<String>()

        for source in sourceDirectories {
            let sourcePath = ContextPanelLocations.normalizedPath(source.path)
            guard seenSources.insert(sourcePath).inserted else { continue }

            let sourceMirrorDirectory = destination.appending(
                path: ConnectorRedactor.localAccountID(provider: .openAI, path: sourcePath),
                directoryHint: .isDirectory
            )
            var expectedTargets = Set<String>()
            let urls = usageJSONFileURLs(in: source, fileManager: fileManager)

            for url in urls {
                let target = ContextPanelLocations.promptCacheMirrorTargetURL(
                    destination: destination,
                    sourceDirectory: source,
                    fileURL: url
                )
                expectedTargets.insert(ContextPanelLocations.normalizedPath(target.path))
                try fileManager.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                let sourceID = ConnectorRedactor.localAccountID(
                    provider: .openAI,
                    path: ContextPanelLocations.normalizedPath(url.path)
                )
                if let data = mirroredData(from: url, sourceID: sourceID) {
                    try data.write(to: target)
                } else {
                    try fileManager.copyItem(at: url, to: target)
                }
                copied += 1
            }

            removed += try removeStaleMirrors(
                in: sourceMirrorDirectory,
                preserving: expectedTargets,
                fileManager: fileManager
            )
        }

        removed += try removeLegacyFlatMirrors(in: destination, fileManager: fileManager)

        return PromptCacheTelemetryMirrorResult(copied: copied, removed: removed)
    }

    private static func usageJSONFileURLs(in source: URL, fileManager: FileManager) -> [URL] {
        guard fileManager.fileExists(atPath: source.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return [] }

        return urls.filter { url in
            guard url.pathExtension == "json" else { return false }
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return resourceValues?.isRegularFile == true
        }
    }

    private static func removeStaleMirrors(
        in sourceMirrorDirectory: URL,
        preserving expectedTargets: Set<String>,
        fileManager: FileManager
    ) throws -> Int {
        guard fileManager.fileExists(atPath: sourceMirrorDirectory.path) else { return 0 }
        let urls = try fileManager.contentsOfDirectory(
            at: sourceMirrorDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var removed = 0
        for url in urls where url.pathExtension == "json"
            && !expectedTargets.contains(ContextPanelLocations.normalizedPath(url.path)) {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
        }
        if (try? fileManager.contentsOfDirectory(atPath: sourceMirrorDirectory.path).isEmpty) == true {
            try? fileManager.removeItem(at: sourceMirrorDirectory)
        }
        return removed
    }

    private static func removeLegacyFlatMirrors(in destination: URL, fileManager: FileManager) throws -> Int {
        guard fileManager.fileExists(atPath: destination.path) else { return 0 }
        let urls = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        var removed = 0
        for url in urls where url.pathExtension == "json" {
            let resourceValues = try? url.resourceValues(forKeys: [.isRegularFileKey])
            guard resourceValues?.isRegularFile == true else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    private static func mirroredData(from url: URL, sourceID: String) -> Data? {
        guard
            let data = try? Data(contentsOf: url),
            var payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        payload["_context_panel_source_id"] = sourceID
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
