import Foundation

public struct PromptCacheTelemetryMirrorResult: Equatable, Sendable {
    public let copied: Int
    public let removed: Int

    public init(copied: Int, removed: Int) {
        self.copied = copied
        self.removed = removed
    }
}

private struct SourceMirrorResult {
    let copied: Int
    let removed: Int
    let sourceMirrorPath: String
}

public enum PromptCacheTelemetryMirrorService {
    public static func mirror(
        bookmarkStore: SecureFileBookmarkStore?,
        sourceDirectories: [URL] = ContextPanelLocations.everyCodeUsageDirectories(),
        destination: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        fileManager: FileManager = .default
    ) throws -> PromptCacheTelemetryMirrorResult {
        guard let bookmarkStore else {
            return try mirror(
                sourceDirectories: sourceDirectories,
                destination: destination,
                fileManager: fileManager
            )
        }

        let preservesAllConfiguredSources = bookmarkStore.hasUnreadableStore()

        return try mirror(
            sourceDirectories: sourceDirectories,
            destination: destination,
            fileManager: fileManager,
            preserveUnreadableSource: { source in
                preservesAllConfiguredSources
                    || bookmarkStore.hasStoredBookmark(for: ContextPanelLocations.normalizedPath(source.path))
            },
            sourceResolver: { source, body in
                let path = ContextPanelLocations.normalizedPath(source.path)
                if let result = try bookmarkStore.withResolvedURL(for: path, body) {
                    return result
                }
                return try body(source)
            }
        )
    }

    public static func mirror(
        sourceDirectories: [URL] = ContextPanelLocations.everyCodeUsageDirectories(),
        destination: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        fileManager: FileManager = .default
    ) throws -> PromptCacheTelemetryMirrorResult {
        try mirror(
            sourceDirectories: sourceDirectories,
            destination: destination,
            fileManager: fileManager,
            preserveUnreadableSource: { _ in false },
            sourceResolver: { source, body in try body(source) }
        )
    }

    private static func mirror(
        sourceDirectories: [URL],
        destination: URL,
        fileManager: FileManager,
        preserveUnreadableSource: (URL) -> Bool,
        sourceResolver: (URL, (URL) throws -> SourceMirrorResult) throws -> SourceMirrorResult
    ) throws -> PromptCacheTelemetryMirrorResult {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        var copied = 0
        var removed = 0
        var seenSources = Set<String>()
        var readableSourceMirrorDirectories = Set<String>()
        var preservedSourceMirrorDirectories = Set<String>()

        for source in sourceDirectories {
            let sourcePath = ContextPanelLocations.normalizedPath(source.path)
            guard seenSources.insert(sourcePath).inserted else { continue }
            let sourceMirrorDirectory = destination.appending(
                path: ConnectorRedactor.localAccountID(provider: .openAI, path: sourcePath),
                directoryHint: .isDirectory
            )
            let sourceMirrorPath = ContextPanelLocations.normalizedPath(sourceMirrorDirectory.path)
            if preserveUnreadableSource(source) {
                preservedSourceMirrorDirectories.insert(sourceMirrorPath)
            }

            guard let sourceResult = try? sourceResolver(source, { resolvedSource in
                try mirrorSource(
                    source: resolvedSource,
                    sourceIDPath: sourcePath,
                    destination: destination,
                    fileManager: fileManager
                )
            }) else { continue }
            copied += sourceResult.copied
            removed += sourceResult.removed
            readableSourceMirrorDirectories.insert(sourceResult.sourceMirrorPath)
            preservedSourceMirrorDirectories.insert(sourceResult.sourceMirrorPath)
        }

        if !readableSourceMirrorDirectories.isEmpty {
            removed += try removeOrphanedSourceMirrors(
                in: destination,
                preserving: preservedSourceMirrorDirectories,
                fileManager: fileManager
            )
            removed += try removeLegacyFlatMirrors(in: destination, fileManager: fileManager)
        }

        return PromptCacheTelemetryMirrorResult(copied: copied, removed: removed)
    }

    private static func mirrorSource(
        source: URL,
        sourceIDPath: String,
        destination: URL,
        fileManager: FileManager
    ) throws -> SourceMirrorResult {
        let sourceMirrorDirectory = destination.appending(
            path: ConnectorRedactor.localAccountID(provider: .openAI, path: sourceIDPath),
            directoryHint: .isDirectory
        )
        guard let urls = usageJSONFileURLs(in: source, fileManager: fileManager) else {
            throw CocoaError(.fileReadNoSuchFile)
        }

        var copied = 0
        var expectedTargets = Set<String>()

        for url in urls {
            let target = ContextPanelLocations.promptCacheMirrorTargetURL(
                destination: destination,
                sourceIDPath: sourceIDPath,
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
            let configuredFilePath = URL(
                fileURLWithPath: sourceIDPath,
                isDirectory: true
            ).appending(path: url.lastPathComponent).path
            let sourceID = ConnectorRedactor.localAccountID(
                provider: .openAI,
                path: ContextPanelLocations.normalizedPath(configuredFilePath)
            )
            if let data = mirroredData(from: url, sourceID: sourceID) {
                try data.write(to: target)
            } else {
                try fileManager.copyItem(at: url, to: target)
            }
            copied += 1
        }

        let removed = try removeStaleMirrors(
            in: sourceMirrorDirectory,
            preserving: expectedTargets,
            fileManager: fileManager
        )
        return SourceMirrorResult(
            copied: copied,
            removed: removed,
            sourceMirrorPath: ContextPanelLocations.normalizedPath(sourceMirrorDirectory.path)
        )
    }

    private static func usageJSONFileURLs(in source: URL, fileManager: FileManager) -> [URL]? {
        guard fileManager.fileExists(atPath: source.path),
              let urls = try? fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else { return nil }

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

    private static func removeOrphanedSourceMirrors(
        in destination: URL,
        preserving expectedSourceMirrorDirectories: Set<String>,
        fileManager: FileManager
    ) throws -> Int {
        guard fileManager.fileExists(atPath: destination.path) else { return 0 }
        let urls = try fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var removed = 0
        for url in urls {
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard resourceValues?.isDirectory == true else { continue }
            guard !expectedSourceMirrorDirectories.contains(ContextPanelLocations.normalizedPath(url.path)) else { continue }
            try fileManager.removeItem(at: url)
            removed += 1
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
