import CryptoKit
import Foundation

public struct CompanionCloudKitUserScope: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 64,
              rawValue.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return nil }
        self.rawValue = rawValue
    }

    public static func derive(
        containerIdentifier: String,
        userRecordName: String
    ) -> CompanionCloudKitUserScope {
        var data = Data("context-panel.cloudkit-user-scope.v1\0".utf8)
        data.append(contentsOf: containerIdentifier.utf8)
        data.append(0)
        data.append(contentsOf: userRecordName.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return CompanionCloudKitUserScope(rawValue: digest)!
    }
}

public struct CompanionCloudKitUserScopeStateStore: Sendable {
    private static let fileLock = NSLock()

    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func load() -> CompanionCloudKitUserScope? {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard let data = try? Data(contentsOf: stateURL),
              let payload = try? Self.makeDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == Payload.schemaVersion
        else { return nil }
        return payload.scope
    }

    public func save(_ scope: CompanionCloudKitUserScope, updatedAt: Date = Date()) throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        let payload = Payload(scope: scope, updatedAt: updatedAt)
        let data = try Self.makeEncoder().encode(payload)
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: stateURL, options: .atomic)
    }

    public func clear() throws {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return }
        try FileManager.default.removeItem(at: stateURL)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private struct Payload: Codable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let scope: CompanionCloudKitUserScope
        let updatedAt: Date

        init(scope: CompanionCloudKitUserScope, updatedAt: Date) {
            schemaVersion = Self.schemaVersion
            self.scope = scope
            self.updatedAt = updatedAt
        }
    }
}
