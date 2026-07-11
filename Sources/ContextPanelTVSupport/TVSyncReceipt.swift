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

    public func matches(_ document: CompanionSyncDocument) -> Bool {
        generatedAt == document.snapshot.generatedAt
            && publishedAt == document.snapshot.publishedAt
    }
}

public struct TVSyncReceiptStore: Sendable {
    public let receiptURL: URL

    public init(receiptURL: URL) {
        self.receiptURL = receiptURL
    }

    public func load(matching document: CompanionSyncDocument) -> TVSyncReceipt? {
        guard let data = try? Data(contentsOf: receiptURL) else { return nil }
        guard let receipt = try? JSONDecoder().decode(TVSyncReceipt.self, from: data) else { return nil }
        return receipt.matches(document) ? receipt : nil
    }

    public func save(document: CompanionSyncDocument, receivedAt: Date) throws {
        let receipt = TVSyncReceipt(document: document, receivedAt: receivedAt)
        let data = try JSONEncoder().encode(receipt)
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: receiptURL, options: .atomic)
    }
}
