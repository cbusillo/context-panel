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

    public static func live(fileManager: FileManager = .default) -> TVLocalCacheLocations {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return TVLocalCacheLocations(cachesDirectory: cachesDirectory)
    }
}
