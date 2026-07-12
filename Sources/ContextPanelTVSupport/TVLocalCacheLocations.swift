import ContextPanelCore
import Foundation

public struct TVLocalCacheLocations: Equatable, Sendable {
    public let rootDirectory: URL

    public init(cachesDirectory: URL) {
        rootDirectory = cachesDirectory
            .appending(path: "Context Panel", directoryHint: .isDirectory)
    }

    public var companionDocumentURL: URL {
        rootDirectory
            .appending(path: "Companion", directoryHint: .isDirectory)
            .appending(path: ContextPanelLocations.companionSyncDocumentFileName)
    }

    public var receiptURL: URL {
        rootDirectory.appending(path: "tv-sync-receipt.json")
    }

    public var providerAlertStateURL: URL {
        rootDirectory.appending(path: "provider-alert-state.json")
    }

    public static func live(fileManager: FileManager = .default) -> TVLocalCacheLocations {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return TVLocalCacheLocations(cachesDirectory: cachesDirectory)
    }
}

public struct TVCompanionSyncVersion: Comparable, Equatable, Sendable {
    public let generatedAt: Date
    public let publishedAt: Date

    public init(generatedAt: Date, publishedAt: Date) {
        self.generatedAt = generatedAt
        self.publishedAt = publishedAt
    }

    public init(document: CompanionSyncDocument) {
        self.init(
            generatedAt: document.snapshot.generatedAt,
            publishedAt: document.snapshot.publishedAt
        )
    }

    public static func < (lhs: TVCompanionSyncVersion, rhs: TVCompanionSyncVersion) -> Bool {
        if lhs.generatedAt != rhs.generatedAt {
            return lhs.generatedAt < rhs.generatedAt
        }
        return lhs.publishedAt < rhs.publishedAt
    }
}

public struct TVSystemSurfaceContent: Equatable, Sendable {
    public let snapshot: WidgetSnapshot
    public let preferences: WidgetDisplayPreferences
    public let version: TVCompanionSyncVersion?

    public init(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        version: TVCompanionSyncVersion?
    ) {
        self.snapshot = snapshot
        self.preferences = preferences
        self.version = version
    }
}

public struct TVSystemSurfaceContentSelection: Sendable {
    private var latestContent: TVSystemSurfaceContent?

    public init() {}

    public mutating func select(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        version: TVCompanionSyncVersion?
    ) -> TVSystemSurfaceContent {
        let incomingContent = TVSystemSurfaceContent(
            snapshot: snapshot,
            preferences: preferences,
            version: version
        )
        guard let latestContent else {
            self.latestContent = incomingContent
            return incomingContent
        }

        switch (latestContent.version, version) {
        case let (.some(latestVersion), .some(incomingVersion)) where incomingVersion < latestVersion:
            return latestContent
        case (.some, .none):
            return latestContent
        default:
            self.latestContent = incomingContent
            return incomingContent
        }
    }
}

public enum TVCompanionSyncCachePolicy {
    public static func shouldKeepCurrent(
        _ currentResult: CompanionSyncLoadResult,
        replacingWith incomingDocument: CompanionSyncDocument
    ) -> Bool {
        guard let currentDocument = currentResult.document else { return false }
        return TVCompanionSyncVersion(document: currentDocument)
            >= TVCompanionSyncVersion(document: incomingDocument)
    }
}
