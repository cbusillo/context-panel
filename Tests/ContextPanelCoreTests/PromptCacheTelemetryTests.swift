import Foundation
import Testing

@testable import ContextPanelCore

@Test func promptCacheSummaryUsesTokenWeightedHitRateAndMissingCacheIsUnavailable() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "one",
            accountName: "Every Code",
            observedAt: now,
            windowLabel: "small",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 100)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "two",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "large",
            tokens: PromptCacheTokenSet(inputTokens: 900, cachedInputTokens: 450)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "missing",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-120),
            windowLabel: "missing",
            tokens: PromptCacheTokenSet(inputTokens: 500, cachedInputTokens: nil)
        ),
    ])

    #expect(summary.isAvailable)
    #expect(abs((summary.tokenWeightedHitRate ?? 0) - 0.55) < 0.0001)
    #expect(summary.totalInputTokens == 1_000)
    #expect(summary.totalCachedInputTokens == 550)
    #expect(summary.totalUncachedInputTokens == 450)
}

@Test func promptCacheSummaryFlagsSharpLatestDrop() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "latest",
            accountName: "Every Code",
            observedAt: now,
            windowLabel: "Latest",
            tokens: PromptCacheTokenSet(inputTokens: 2_000, cachedInputTokens: 50)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "previous",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "Previous",
            tokens: PromptCacheTokenSet(inputTokens: 10_000, cachedInputTokens: 9_500)
        ),
    ])

    #expect(summary.hasPossibleCacheBreak)
}

@Test func promptCacheSummaryComparesLatestAgainstRollingAverage() {
    let now = Date(timeIntervalSince1970: 1_000)
    let summary = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "latest",
            accountName: "Every Code",
            observedAt: now,
            windowLabel: "Latest",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 94)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "previous",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "Previous",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 66)
        ),
    ])

    #expect(summary.latestHitRate == 0.94)
    #expect(summary.tokenWeightedHitRate == 0.8)
    #expect(abs((summary.latestDeltaFromWeightedAverage ?? 0) - 0.14) < 0.0001)
    #expect(summary.comparisonStatus == .healthy)
}

@Test func promptCacheSummaryMarksMeaningfulLatestDrops() {
    let now = Date(timeIntervalSince1970: 1_000)
    let yellow = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "latest",
            accountName: "Every Code",
            observedAt: now,
            windowLabel: "Latest",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 72)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "previous",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "Previous",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 100)
        ),
    ])
    let red = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "latest",
            accountName: "Every Code",
            observedAt: now,
            windowLabel: "Latest",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 50)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "previous",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "Previous",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 100)
        ),
    ])

    #expect(yellow.comparisonStatus == .close)
    #expect(red.comparisonStatus == .limited)
}

@Test func promptCacheSummaryCanIgnoreStaleObservations() {
    let now = Date(timeIntervalSince1970: 10_000)
    let summary = PromptCacheSummary(observations: [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "fresh",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "Last hour",
            tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 90)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "stale",
            accountName: "Every Code",
            observedAt: now.addingTimeInterval(-7 * 60 * 60),
            windowLabel: "Last hour",
            tokens: PromptCacheTokenSet(inputTokens: 900, cachedInputTokens: 0)
        ),
    ], now: now)

    #expect(summary.observations.count == 1)
    #expect(summary.tokenWeightedHitRate == 0.9)
}

@Test func promptCacheObservationIDsIncludeObservationTime() {
    let first = PromptCacheObservation(
        provider: .openAI,
        accountID: "every-code",
        accountName: "Every Code",
        observedAt: Date(timeIntervalSince1970: 1_000),
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 90)
    )
    let second = PromptCacheObservation(
        provider: .openAI,
        accountID: "every-code",
        accountName: "Every Code",
        observedAt: Date(timeIntervalSince1970: 1_060),
        windowLabel: "Last hour",
        tokens: PromptCacheTokenSet(inputTokens: 100, cachedInputTokens: 80)
    )

    #expect(first.id != second.id)
}

@Test func everyCodeUsageReaderParsesCachedInputTokens() throws {
    let directory = try promptCacheTemporaryDirectory()
    let usageURL = directory.appending(path: "usage.json")
    try Data(#"""
    {
        "version": 1,
        "last_updated": "2026-06-04T17:47:50.196967Z",
        "plan": "Pro",
        "tokens_last_hour": {
            "input_tokens": 1000,
            "cached_input_tokens": 750,
            "output_tokens": 20,
            "total_tokens": 1020
        }
    }
    """#.utf8).write(to: usageURL)

    let observations = PromptCacheTelemetryReader.everyCodeUsageObservations(
        rootDirectory: directory,
        now: Date(timeIntervalSince1970: 1_780_596_000),
        maximumAge: 24 * 60 * 60
    )

    #expect(observations.count == 1)
    #expect(observations[0].accountName == "Every Code · Pro")
    #expect(observations[0].windowLabel == "Last hour")
    #expect(observations[0].tokens.inputTokens == 1_000)
    #expect(observations[0].tokens.cachedInputTokens == 750)
    #expect(observations[0].hitRate == 0.75)
}

@Test func everyCodeUsageReaderDeduplicatesMirroredCopiesBySourceID() throws {
    let root = try promptCacheTemporaryDirectory()
    let live = root.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)

    let liveURL = live.appending(path: "usage.json")
    let sourceID = ConnectorRedactor.localAccountID(
        provider: .openAI,
        path: ContextPanelLocations.normalizedPath(liveURL.path)
    )
    let mirror = root.appending(path: sourceID, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90
    ).write(to: liveURL, atomically: true, encoding: .utf8)
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90,
        sourceID: sourceID
    ).write(to: mirror.appending(path: "usage.json"), atomically: true, encoding: .utf8)

    let observations = PromptCacheTelemetryReader.everyCodeUsageObservations(
        rootDirectory: root,
        now: Date(timeIntervalSince1970: 1_780_596_000),
        maximumAge: 24 * 60 * 60
    )

    #expect(observations.count == 1)
    #expect(observations[0].accountID == sourceID)
}

@Test func everyCodeUsageReaderKeepsDistinctStableIDsWithMatchingNamesAndTimes() throws {
    let directory = try promptCacheTemporaryDirectory()
    let first = directory.appending(path: "first.json")
    let second = directory.appending(path: "second.json")
    let payload = #"""
    {
        "version": 1,
        "last_updated": "2026-06-04T17:47:50.196967Z",
        "plan": "Pro",
        "tokens_last_hour": {
            "input_tokens": 1000,
            "cached_input_tokens": 750
        }
    }
    """#
    try Data(payload.utf8).write(to: first)
    try Data(payload.utf8).write(to: second)

    let observations = PromptCacheTelemetryReader.everyCodeUsageObservations(
        rootDirectory: directory,
        now: Date(timeIntervalSince1970: 1_780_596_000),
        maximumAge: 24 * 60 * 60
    )

    #expect(observations.count == 2)
    #expect(Set(observations.map(\.id)).count == 2)
    #expect(Set(observations.map(\.accountName)) == ["Every Code · Pro"])
}

@Test func everyCodeUsageReaderRecursesIntoMirroredSourceDirectories() throws {
    let root = try promptCacheTemporaryDirectory()
    let mirrorSource = root.appending(path: ".code", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: mirrorSource, withIntermediateDirectories: true)
    let usageURL = mirrorSource.appending(path: "usage.json")
    try Data(#"""
    {
        "version": 1,
        "last_updated": "2026-06-04T17:47:50.196967Z",
        "tokens_last_hour": {
            "input_tokens": 100,
            "cached_input_tokens": 90
        }
    }
    """#.utf8).write(to: usageURL)

    let observations = PromptCacheTelemetryReader.everyCodeUsageObservations(
        rootDirectory: root,
        now: Date(timeIntervalSince1970: 1_780_596_000),
        maximumAge: 24 * 60 * 60
    )

    #expect(observations.count == 1)
    #expect(observations[0].tokens.cachedInputTokens == 90)
}

@Test func promptCacheMirrorPreservesSourceRootInTargetPath() {
    let destination = URL(fileURLWithPath: "/tmp/prompt-cache-destination", isDirectory: true)
    let sourceDirectory = URL(fileURLWithPath: "/Users/test/.code/usage", isDirectory: true)
    let fileURL = sourceDirectory.appending(path: "usage.json")
    let sourceID = ConnectorRedactor.localAccountID(provider: .openAI, path: sourceDirectory.path)

    let target = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: sourceDirectory,
        fileURL: fileURL
    )

    #expect(target.path == "/tmp/prompt-cache-destination/\(sourceID)/usage.json")
}

@Test func promptCacheMirrorTargetUsesDistinctSourceRoots() {
    let destination = URL(fileURLWithPath: "/tmp/prompt-cache-destination", isDirectory: true)
    let firstSource = URL(fileURLWithPath: "/tmp/one/.code/usage", isDirectory: true)
    let secondSource = URL(fileURLWithPath: "/tmp/two/.code/usage", isDirectory: true)
    let firstTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: firstSource,
        fileURL: firstSource.appending(path: "usage.json")
    )
    let secondTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: secondSource,
        fileURL: secondSource.appending(path: "usage.json")
    )

    #expect(firstTarget != secondTarget)
}

@Test func everyCodeUsageDirectoriesUsesFallbackRootOrder() throws {
    let root = try promptCacheTemporaryDirectory()
    let codeHome = root.appending(path: "code-home", directoryHint: .isDirectory)
    let codexHome = root.appending(path: "codex-home", directoryHint: .isDirectory)
    let codeUsage = codeHome.appending(path: "usage", directoryHint: .isDirectory)
    let codexUsage = codexHome.appending(path: "usage", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: codexUsage, withIntermediateDirectories: true)

    var selected = ContextPanelLocations.everyCodeUsageDirectories(
        environment: [
            "CODE_HOME": codeHome.path,
            "CODEX_HOME": codexHome.path,
        ],
        fileManager: .default
    )
    #expect(selected == [codexUsage])

    try FileManager.default.createDirectory(at: codeUsage, withIntermediateDirectories: true)
    selected = ContextPanelLocations.everyCodeUsageDirectories(
        environment: [
            "CODE_HOME": codeHome.path,
            "CODEX_HOME": codexHome.path,
        ],
        fileManager: .default
    )
    #expect(selected == [codeUsage])
}

@Test func promptCacheMirrorServiceRemovesDeletedSourceFiles() throws {
    let root = try promptCacheTemporaryDirectory()
    let source = root.appending(path: "usage", directoryHint: .isDirectory)
    let destination = root.appending(path: "mirror", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let kept = source.appending(path: "kept.json")
    let deleted = source.appending(path: "deleted.json")
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90
    ).write(to: kept, atomically: true, encoding: .utf8)
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 80
    ).write(to: deleted, atomically: true, encoding: .utf8)

    let first = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source],
        destination: destination
    )
    try FileManager.default.removeItem(at: deleted)
    let second = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source],
        destination: destination
    )

    let keptTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: source,
        fileURL: kept
    )
    let deletedTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: source,
        fileURL: deleted
    )
    #expect(first.copied == 2)
    #expect(first.removed == 0)
    #expect(second.copied == 1)
    #expect(second.removed == 1)
    #expect(FileManager.default.fileExists(atPath: keptTarget.path))
    #expect(!FileManager.default.fileExists(atPath: deletedTarget.path))
}

@Test func promptCacheMirrorServiceRemovesLegacyFlatMirrorFiles() throws {
    let root = try promptCacheTemporaryDirectory()
    let source = root.appending(path: "usage", directoryHint: .isDirectory)
    let destination = root.appending(path: "mirror", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let sourceFile = source.appending(path: "usage.json")
    let legacyFlatMirror = destination.appending(path: "usage.json")
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90
    ).write(to: sourceFile, atomically: true, encoding: .utf8)
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 80
    ).write(to: legacyFlatMirror, atomically: true, encoding: .utf8)

    let result = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source],
        destination: destination
    )

    let nestedTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: source,
        fileURL: sourceFile
    )
    #expect(result.copied == 1)
    #expect(result.removed == 1)
    #expect(FileManager.default.fileExists(atPath: nestedTarget.path))
    #expect(!FileManager.default.fileExists(atPath: legacyFlatMirror.path))
}

@Test func promptCacheMirrorServiceRemovesOrphanedSourceDirectories() throws {
    let root = try promptCacheTemporaryDirectory()
    let activeSource = root.appending(path: "active", directoryHint: .isDirectory)
    let orphanedSource = root.appending(path: "orphaned", directoryHint: .isDirectory)
    let destination = root.appending(path: "mirror", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: activeSource, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: orphanedSource, withIntermediateDirectories: true)
    let activeFile = activeSource.appending(path: "usage.json")
    let orphanedFile = orphanedSource.appending(path: "usage.json")
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90
    ).write(to: activeFile, atomically: true, encoding: .utf8)
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 80
    ).write(to: orphanedFile, atomically: true, encoding: .utf8)

    let first = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [activeSource, orphanedSource],
        destination: destination
    )
    let second = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [activeSource],
        destination: destination
    )

    let activeTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: activeSource,
        fileURL: activeFile
    )
    let orphanedDirectoryID = ConnectorRedactor.localAccountID(provider: .openAI, path: orphanedSource.path)
    let orphanedDirectory = destination.appending(path: orphanedDirectoryID, directoryHint: .isDirectory)
    #expect(first.copied == 2)
    #expect(first.removed == 0)
    #expect(second.copied == 1)
    #expect(second.removed == 1)
    #expect(FileManager.default.fileExists(atPath: activeTarget.path))
    #expect(!FileManager.default.fileExists(atPath: orphanedDirectory.path))
}

@Test func promptCacheMirrorServicePreservesMirrorsWhenSourceCannotBeRead() throws {
    let root = try promptCacheTemporaryDirectory()
    let source = root.appending(path: "usage", directoryHint: .isDirectory)
    let destination = root.appending(path: "mirror", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceFile = source.appending(path: "usage.json")
    try promptCachePayload(
        lastUpdated: "2026-06-04T17:47:50.196967Z",
        cachedInputTokens: 90
    ).write(to: sourceFile, atomically: true, encoding: .utf8)

    let first = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source],
        destination: destination
    )
    try FileManager.default.removeItem(at: source)
    let second = try PromptCacheTelemetryMirrorService.mirror(
        sourceDirectories: [source],
        destination: destination
    )

    let mirroredTarget = ContextPanelLocations.promptCacheMirrorTargetURL(
        destination: destination,
        sourceDirectory: source,
        fileURL: sourceFile
    )
    #expect(first.copied == 1)
    #expect(first.removed == 0)
    #expect(second.copied == 0)
    #expect(second.removed == 0)
    #expect(FileManager.default.fileExists(atPath: mirroredTarget.path))
}

private func promptCacheTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "context-panel-prompt-cache-tests")
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func promptCachePayload(
    lastUpdated: String,
    cachedInputTokens: Int,
    sourceID: String? = nil
) -> String {
    let sourceIDLine = sourceID.map { ",\n        \"_context_panel_source_id\": \"\($0)\"" } ?? ""
    return #"""
    {
        "version": 1,
        "last_updated": "\#(lastUpdated)",
        "tokens_last_hour": {
            "input_tokens": 100,
            "cached_input_tokens": \#(cachedInputTokens)
        }\#(sourceIDLine)
    }
    """#
}
