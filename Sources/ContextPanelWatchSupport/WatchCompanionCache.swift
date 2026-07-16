import ContextPanelCore
import Foundation
import OSLog

private let watchCompanionCacheLogger = Logger(
    subsystem: "com.shinycomputers.contextpanel",
    category: "watch-companion-cache"
)

public struct WatchCompanionCacheLoadResult: Equatable, Sendable {
    public let result: CompanionSyncLoadResult
    public let displayPreferences: WidgetDisplayPreferences?

    public init(
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences?
    ) {
        self.result = result
        self.displayPreferences = displayPreferences
    }
}

enum WatchCompanionCacheSaveOutcome: Equatable, Sendable {
    case saved
    case keptCurrent(WatchCompanionCacheLoadResult)
    case failed
}

public final class WatchCompanionCache: @unchecked Sendable {
    private static let fileLock = NSLock()

    private let cacheURL: URL

    public init(cacheURL: URL = ContextPanelLocations.watchCompanionCacheURL()) {
        self.cacheURL = cacheURL
    }

    public func load() -> WatchCompanionCacheLoadResult {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else {
            return WatchCompanionCacheLoadResult(
                result: CompanionSyncLoadResult(document: nil, status: .unknown),
                displayPreferences: nil
            )
        }

        do {
            let payload = try Self.decodePayload(from: Data(contentsOf: cacheURL))
            return Self.loadResult(from: payload)
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion cache read failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return WatchCompanionCacheLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "Context Panel Watch could not read saved usage."
                ),
                displayPreferences: nil
            )
        }
    }

    @discardableResult
    public func save(
        document: CompanionSyncDocument,
        displayPreferences: WidgetDisplayPreferences,
        now: Date = Date()
    ) -> Bool {
        switch saveSelectingNewest(
            document: document,
            displayPreferences: displayPreferences,
            now: now
        ) {
        case .saved, .keptCurrent:
            true
        case .failed:
            false
        }
    }

    func saveSelectingNewest(
        document: CompanionSyncDocument,
        displayPreferences: WidgetDisplayPreferences,
        now: Date
    ) -> WatchCompanionCacheSaveOutcome {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        do {
            let candidate = Payload(
                document: document,
                displayPreferences: displayPreferences,
                cachedAt: now
            )
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: cacheURL.path),
               let current = try? Self.decodePayload(from: Data(contentsOf: cacheURL)),
               Self.shouldKeepCurrent(current.document, over: document) {
                return .keptCurrent(Self.loadResult(from: current))
            }
            try Self.makeEncoder().encode(candidate).write(to: cacheURL, options: .atomic)
            return .saved
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion cache save failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return .failed
        }
    }

    @discardableResult
    public func remove() -> Bool {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: cacheURL)
            return true
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion cache removal failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return false
        }
    }

    static func shouldKeepCurrent(
        _ current: CompanionSyncDocument?,
        over candidate: CompanionSyncDocument
    ) -> Bool {
        guard let current else { return false }
        if current.snapshot.generatedAt != candidate.snapshot.generatedAt {
            return current.snapshot.generatedAt > candidate.snapshot.generatedAt
        }
        return current.snapshot.publishedAt > candidate.snapshot.publishedAt
    }

    private static func loadResult(from payload: Payload) -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: payload.document,
                status: payload.document.companionStatus,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: .localCache,
                    mirroredAt: payload.cachedAt,
                    deliveryStatus: .healthy
                )
            ),
            displayPreferences: payload.displayPreferences
        )
    }

    private static func decodePayload(from data: Data) throws -> Payload {
        let payload = try makeDecoder().decode(Payload.self, from: data)
        guard payload.schemaVersion == Payload.schemaVersion,
              payload.document.schemaVersion == CompanionSyncDocument.schemaVersion,
              payload.document.snapshot.schemaVersion == CompanionSnapshot.schemaVersion
        else {
            throw CacheError.unsupportedSchema
        }
        return payload
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

    private struct Payload: Codable, Equatable, Sendable {
        static let schemaVersion = 1

        let schemaVersion: Int
        let document: CompanionSyncDocument
        let displayPreferences: WidgetDisplayPreferences
        let cachedAt: Date

        init(
            document: CompanionSyncDocument,
            displayPreferences: WidgetDisplayPreferences,
            cachedAt: Date
        ) {
            schemaVersion = Self.schemaVersion
            self.document = document
            self.displayPreferences = displayPreferences
            self.cachedAt = cachedAt
        }
    }

    private enum CacheError: Error {
        case unsupportedSchema
    }
}
