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
        sourceDirectories: [URL] = ContextPanelLocations.codexTelemetryDirectories(),
        sourceClients: [String: CodexClient] = [:],
        now: Date = Date(),
        destination: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        fileManager: FileManager = .default
    ) throws -> PromptCacheTelemetryMirrorResult {
        guard let bookmarkStore else {
            return try mirror(
                sourceDirectories: sourceDirectories,
                sourceClients: sourceClients,
                now: now,
                destination: destination,
                fileManager: fileManager
            )
        }

        let preservesAllConfiguredSources = bookmarkStore.hasUnreadableStore()

        return try mirror(
            sourceDirectories: sourceDirectories,
            sourceClients: sourceClients,
            now: now,
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
                if ContextPanelLocations.isRunningInAppSandbox {
                    throw CocoaError(.fileReadNoPermission)
                }
                return try body(source)
            }
        )
    }

    public static func mirror(
        sourceDirectories: [URL] = ContextPanelLocations.codexTelemetryDirectories(),
        sourceClients: [String: CodexClient] = [:],
        now: Date = Date(),
        destination: URL = ContextPanelLocations.promptCacheTelemetryDirectory(appGroupID: ContextPanelLocations.appGroupID),
        fileManager: FileManager = .default
    ) throws -> PromptCacheTelemetryMirrorResult {
        try mirror(
            sourceDirectories: sourceDirectories,
            sourceClients: sourceClients,
            now: now,
            destination: destination,
            fileManager: fileManager,
            preserveUnreadableSource: { _ in false },
            sourceResolver: { source, body in try body(source) }
        )
    }

    private static func mirror(
        sourceDirectories: [URL],
        sourceClients: [String: CodexClient],
        now: Date,
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
            if preserveUnreadableSource(source) || fileManager.fileExists(atPath: source.path) {
                preservedSourceMirrorDirectories.insert(sourceMirrorPath)
            }
            let client = sourceClients[sourcePath] ?? [CodexClient.codex, .codexLab].first { client in
                ContextPanelLocations.normalizedPath(client.homeDirectory().appending(path: client.telemetryFolderName).path) == sourcePath
            } ?? CodexClient.inferred(fromAuthPath: source.deletingLastPathComponent().appending(path: "auth.json").path)

            guard let sourceResult = try? sourceResolver(source, { resolvedSource in
                try mirrorSource(
                    source: resolvedSource,
                    sourceIDPath: sourcePath,
                    client: client,
                    now: now,
                    destination: destination,
                    fileManager: fileManager
                )
            }) else { continue }
            copied += sourceResult.copied
            removed += sourceResult.removed
            readableSourceMirrorDirectories.insert(sourceResult.sourceMirrorPath)
            preservedSourceMirrorDirectories.insert(sourceResult.sourceMirrorPath)
        }

        if readableSourceMirrorDirectories.isEmpty {
            // Keep configured last-good sources during transient access failures,
            // while still removing sources the user has switched off.
            for source in sourceDirectories {
                preservedSourceMirrorDirectories.insert(ContextPanelLocations.normalizedPath(
                    destination.appending(path: ConnectorRedactor.localAccountID(
                        provider: .openAI, path: ContextPanelLocations.normalizedPath(source.path)
                    )).path
                ))
            }
        }
        removed += try removeOrphanedSourceMirrors(
            in: destination, preserving: preservedSourceMirrorDirectories, fileManager: fileManager
        )
        if !readableSourceMirrorDirectories.isEmpty || sourceDirectories.isEmpty {
            removed += try removeLegacyFlatMirrors(in: destination, fileManager: fileManager)
        }

        return PromptCacheTelemetryMirrorResult(copied: copied, removed: removed)
    }

    private static func mirrorSource(
        source: URL,
        sourceIDPath: String,
        client: CodexClient?,
        now: Date,
        destination: URL,
        fileManager: FileManager
    ) throws -> SourceMirrorResult {
        let sourceMirrorDirectory = destination.appending(
            path: ConnectorRedactor.localAccountID(provider: .openAI, path: sourceIDPath),
            directoryHint: .isDirectory
        )
        if client == .codex || client == .codexLab || source.lastPathComponent == "sessions" {
            // Fail before replacing last-good data when a bookmarked folder is unavailable.
            _ = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            let target = sourceMirrorDirectory.appending(path: "telemetry.json")
            try CodexTelemetryMirror.write(source: source, sourceIDPath: sourceIDPath, client: client, target: target, now: now, fileManager: fileManager)
            let removed = try removeStaleMirrors(in: sourceMirrorDirectory, preserving: [ContextPanelLocations.normalizedPath(target.path)], fileManager: fileManager)
            return SourceMirrorResult(copied: 1, removed: removed, sourceMirrorPath: ContextPanelLocations.normalizedPath(sourceMirrorDirectory.path))
        }
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
