import ContextPanelCore
import Foundation

public struct TVSyncReceipt: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let receivedAt: Date
    public let generatedAt: Date
    public let publishedAt: Date

    public init(document: CompanionSyncDocument, receivedAt: Date) {
        schemaVersion = Self.schemaVersion
        self.receivedAt = receivedAt
        generatedAt = document.snapshot.generatedAt
        publishedAt = document.snapshot.publishedAt
    }

    public var version: TVCompanionSyncVersion {
        TVCompanionSyncVersion(generatedAt: generatedAt, publishedAt: publishedAt)
    }

    public func matches(_ document: CompanionSyncDocument) -> Bool {
        version == TVCompanionSyncVersion(document: document)
    }

    public func shouldKeepCurrent(replacingWith incomingReceipt: TVSyncReceipt) -> Bool {
        if version != incomingReceipt.version {
            return version > incomingReceipt.version
        }
        return receivedAt >= incomingReceipt.receivedAt
    }
}

public struct TVSyncReceiptStore: Sendable {
    public let receiptURL: URL

    public init(receiptURL: URL) {
        self.receiptURL = receiptURL
    }

    public func load(matching document: CompanionSyncDocument) -> TVSyncReceipt? {
        guard let receipt = Self.loadReceipt(at: receiptURL) else { return nil }
        return receipt.matches(document) ? receipt : nil
    }

    public func save(document: CompanionSyncDocument, receivedAt: Date) throws {
        let receipt = TVSyncReceipt(document: document, receivedAt: receivedAt)
        let data = try JSONEncoder().encode(receipt)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: receiptURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                if let currentReceipt = Self.loadReceipt(at: coordinatedURL),
                   currentReceipt.shouldKeepCurrent(replacingWith: receipt)
                {
                    return
                }
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }

    private static func loadReceipt(at url: URL) -> TVSyncReceipt? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let receipt = try? JSONDecoder().decode(TVSyncReceipt.self, from: data) else { return nil }
        guard receipt.schemaVersion == TVSyncReceipt.schemaVersion else { return nil }
        return receipt
    }
}

public enum TVCompanionSyncAttemptPolicy {
    public static func cacheSupersedesAttempt(
        document: CompanionSyncDocument,
        receipt: TVSyncReceipt?,
        startingVersion: TVCompanionSyncVersion?,
        startedAt: Date
    ) -> Bool {
        let cachedVersion = TVCompanionSyncVersion(document: document)
        if let startingVersion {
            if cachedVersion > startingVersion { return true }
        } else {
            return true
        }
        return receipt?.receivedAt ?? .distantPast > startedAt
    }
}
