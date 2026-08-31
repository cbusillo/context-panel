import ContextPanelCore
import Foundation

public struct TVSyncReceipt: Codable, Equatable, Sendable {
    public static let schemaVersion = 2

    public let schemaVersion: Int
    public let receivedAt: Date
    public let generatedAt: Date
    public let publishedAt: Date
    public let cloudKitUserScope: CompanionCloudKitUserScope

    public init(
        document: CompanionSyncDocument,
        receivedAt: Date,
        cloudKitUserScope: CompanionCloudKitUserScope
    ) {
        schemaVersion = Self.schemaVersion
        self.receivedAt = receivedAt
        generatedAt = document.snapshot.generatedAt
        publishedAt = document.snapshot.publishedAt
        self.cloudKitUserScope = cloudKitUserScope
    }

    public var version: TVCompanionSyncVersion {
        TVCompanionSyncVersion(generatedAt: generatedAt, publishedAt: publishedAt)
    }

    public func matches(_ document: CompanionSyncDocument) -> Bool {
        version == TVCompanionSyncVersion(document: document)
            && document.cloudKitUserScope == cloudKitUserScope
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

    public func save(
        document: CompanionSyncDocument,
        receivedAt: Date,
        cloudKitUserScope: CompanionCloudKitUserScope
    ) throws {
        guard document.cloudKitUserScope == cloudKitUserScope else {
            throw SnapshotStoreError.corruptStore(
                "tvOS sync receipt belongs to another CloudKit account scope."
            )
        }
        let receipt = TVSyncReceipt(
            document: document,
            receivedAt: receivedAt,
            cloudKitUserScope: cloudKitUserScope
        )
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

    public func remove() throws {
        guard FileManager.default.fileExists(atPath: receiptURL.path) else { return }
        try FileManager.default.removeItem(at: receiptURL)
    }

    public func removeIfCurrent(_ expectedReceipt: TVSyncReceipt?) throws {
        var removalError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: receiptURL,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                let currentFileExists = FileManager.default.fileExists(atPath: coordinatedURL.path)
                guard currentFileExists else { return }
                guard let currentReceipt = Self.loadReceipt(at: coordinatedURL) else { return }
                guard currentReceipt == expectedReceipt else { return }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                removalError = error
            }
        }
        if let removalError { throw removalError }
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
