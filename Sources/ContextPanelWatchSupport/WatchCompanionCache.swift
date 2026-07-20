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
    let displayPreferencesUpdatedAt: Date?
    let cacheRevision: UUID?

    public init(
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences?
    ) {
        self.result = result
        self.displayPreferences = displayPreferences
        displayPreferencesUpdatedAt = nil
        cacheRevision = nil
    }

    init(
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences?,
        displayPreferencesUpdatedAt: Date?,
        cacheRevision: UUID?
    ) {
        self.result = result
        self.displayPreferences = displayPreferences
        self.displayPreferencesUpdatedAt = displayPreferencesUpdatedAt
        self.cacheRevision = cacheRevision
    }

    public static func == (
        lhs: WatchCompanionCacheLoadResult,
        rhs: WatchCompanionCacheLoadResult
    ) -> Bool {
        lhs.result == rhs.result && lhs.displayPreferences == rhs.displayPreferences
    }
}

enum WatchCompanionCacheSaveOutcome: Equatable, Sendable {
    case saved(WatchCompanionCacheLoadResult)
    case keptCurrent(WatchCompanionCacheLoadResult)
    case failed
}

enum WatchCompanionCacheRemoveOutcome: Equatable, Sendable {
    case removed
    case keptCurrent(WatchCompanionCacheLoadResult)
    case failed
}

public final class WatchCompanionCache: @unchecked Sendable {
    private static let fileLock = NSLock()

    private let cacheURL: URL
    private let legacyCacheURL: URL?
    private let source: CompanionSyncSource

    public convenience init() {
        let processCacheURL = ContextPanelLocations.watchCompanionProcessCacheURL()
        if let sharedCacheURL = ContextPanelLocations.watchCompanionAppGroupCacheURL() {
            self.init(
                cacheURL: sharedCacheURL,
                legacyCacheURL: processCacheURL,
                source: .appGroup
            )
        } else {
            watchCompanionCacheLogger.error(
                "Watch companion App Group is unavailable; using process-local saved usage."
            )
            self.init(cacheURL: processCacheURL)
        }
    }

    public init(
        cacheURL: URL,
        legacyCacheURL: URL? = nil,
        source: CompanionSyncSource = .localCache
    ) {
        self.cacheURL = cacheURL
        self.legacyCacheURL = legacyCacheURL == cacheURL ? nil : legacyCacheURL
        self.source = source
    }

    public func load(now: Date? = nil) -> WatchCompanionCacheLoadResult {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }

        do {
            try migrateLegacyPayloadIfAvailable()
            if let payload = try Self.coordinatedLoadPayload(at: cacheURL) {
                return Self.loadResult(from: payload, now: now, source: source)
            }
            return Self.emptyLoadResult()
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
        displayPreferencesUpdatedAt: Date? = nil,
        now: Date = Date()
    ) -> Bool {
        switch saveSelectingNewest(
            document: document,
            displayPreferences: displayPreferences,
            displayPreferencesUpdatedAt: displayPreferencesUpdatedAt
                ?? document.snapshot.generatedAt,
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
        displayPreferencesUpdatedAt: Date?,
        now: Date
    ) -> WatchCompanionCacheSaveOutcome {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        do {
            let outcome = try Self.coordinatedWriteSelectingNewest(
                document: document,
                displayPreferences: displayPreferences,
                displayPreferencesUpdatedAt: displayPreferencesUpdatedAt,
                cachedAt: now,
                to: cacheURL
            )
            switch outcome {
            case .saved(let payload):
                return .saved(Self.loadResult(from: payload, now: now, source: source))
            case .keptCurrent(let payload):
                return .keptCurrent(Self.loadResult(from: payload, now: now, source: source))
            }
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
        do {
            try Self.coordinatedRemove(at: cacheURL)
            if let legacyCacheURL {
                try Self.coordinatedRemove(at: legacyCacheURL)
            }
            return true
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion cache removal failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return false
        }
    }

    func removeIfCurrent(
        _ expected: WatchCompanionCacheLoadResult,
        now: Date
    ) -> WatchCompanionCacheRemoveOutcome {
        Self.fileLock.lock()
        defer { Self.fileLock.unlock() }
        do {
            let outcome = try Self.coordinatedRemoveIfCurrent(
                at: cacheURL,
                expected: expected
            )
            switch outcome {
            case .removed:
                if let legacyCacheURL {
                    try Self.coordinatedRemove(at: legacyCacheURL)
                }
                return .removed
            case .keptCurrent(let payload):
                return .keptCurrent(Self.loadResult(from: payload, now: now, source: source))
            }
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion cache conditional removal failed: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return .failed
        }
    }

    private func migrateLegacyPayloadIfAvailable() throws {
        guard let legacyCacheURL else { return }
        let legacyPayload: Payload?
        do {
            legacyPayload = try Self.coordinatedLoadPayload(at: legacyCacheURL)
        } catch {
            let error = error as NSError
            watchCompanionCacheLogger.error(
                "Watch companion legacy cache migration skipped: domain=\(error.domain, privacy: .public) code=\(error.code)"
            )
            return
        }
        guard let legacyPayload else { return }

        _ = try Self.coordinatedWriteSelectingNewest(
            document: legacyPayload.document,
            displayPreferences: legacyPayload.displayPreferences,
            displayPreferencesUpdatedAt: legacyPayload.displayPreferencesUpdatedAt,
            cachedAt: legacyPayload.cachedAt,
            to: cacheURL
        )
        try Self.coordinatedRemove(at: legacyCacheURL)
    }

    private static func emptyLoadResult() -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(document: nil, status: .unknown),
            displayPreferences: nil,
            displayPreferencesUpdatedAt: nil,
            cacheRevision: nil
        )
    }

    private static func loadResult(
        from payload: Payload,
        now: Date?,
        source: CompanionSyncSource
    ) -> WatchCompanionCacheLoadResult {
        WatchCompanionCacheLoadResult(
            result: CompanionSyncLoadResult(
                document: payload.document,
                status: now.map {
                    payload.document.companionStatus(
                        now: $0,
                        stalenessPolicy: SnapshotStoreStalenessPolicy(
                            maximumAge: SnapshotFreshness.companionProviderMaximumAge
                        )
                    )
                } ?? payload.document.companionStatus,
                transportMetadata: CompanionSyncTransportMetadata(
                    source: source,
                    mirroredAt: payload.cachedAt,
                    deliveryStatus: .healthy
                )
            ),
            displayPreferences: payload.displayPreferences,
            displayPreferencesUpdatedAt: payload.displayPreferencesUpdatedAt,
            cacheRevision: payload.revision
        )
    }

    private static func coordinatedLoadPayload(at url: URL) throws -> Payload? {
        var payload: Payload?
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                payload = try decodePayload(from: Data(contentsOf: coordinatedURL))
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
        return payload
    }

    private static func coordinatedWriteSelectingNewest(
        document: CompanionSyncDocument,
        displayPreferences: WidgetDisplayPreferences,
        displayPreferencesUpdatedAt: Date?,
        cachedAt: Date,
        to url: URL
    ) throws -> PayloadWriteOutcome {
        var outcome: PayloadWriteOutcome?
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                try FileManager.default.createDirectory(
                    at: coordinatedURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let current = FileManager.default.fileExists(atPath: coordinatedURL.path)
                    ? try? decodePayload(from: Data(contentsOf: coordinatedURL))
                    : nil
                let selectedDocument = document.mergingForRemotePublish(existing: current?.document)
                let selectedPreferences = preferredDisplayPreferences(
                    candidate: displayPreferences,
                    candidateUpdatedAt: displayPreferencesUpdatedAt,
                    candidateCachedAt: cachedAt,
                    current: current
                )
                if let current,
                   selectedDocument == current.document,
                   selectedPreferences.preferences == current.displayPreferences,
                   selectedPreferences.updatedAt == current.displayPreferencesUpdatedAt {
                    outcome = .keptCurrent(current)
                    return
                }
                let candidate = Payload(
                    document: selectedDocument,
                    displayPreferences: selectedPreferences.preferences,
                    displayPreferencesUpdatedAt: selectedPreferences.updatedAt,
                    cachedAt: max(cachedAt, current?.cachedAt ?? cachedAt)
                )
                try makeEncoder().encode(candidate).write(to: coordinatedURL, options: .atomic)
                outcome = .saved(candidate)
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
        guard let outcome else { throw CacheError.missingPayload }
        return outcome
    }

    private static func preferredDisplayPreferences(
        candidate: WidgetDisplayPreferences,
        candidateUpdatedAt: Date?,
        candidateCachedAt: Date,
        current: Payload?
    ) -> DisplayPreferencesSelection {
        guard let current else {
            return DisplayPreferencesSelection(
                preferences: candidate,
                updatedAt: candidateUpdatedAt
            )
        }

        switch (candidateUpdatedAt, current.displayPreferencesUpdatedAt) {
        case let (candidateDate?, currentDate?) where candidateDate != currentDate:
            return candidateDate > currentDate
                ? DisplayPreferencesSelection(preferences: candidate, updatedAt: candidateDate)
                : DisplayPreferencesSelection(
                    preferences: current.displayPreferences,
                    updatedAt: currentDate
                )
        case let (candidateDate?, nil):
            return DisplayPreferencesSelection(preferences: candidate, updatedAt: candidateDate)
        case let (nil, currentDate?):
            return DisplayPreferencesSelection(
                preferences: current.displayPreferences,
                updatedAt: currentDate
            )
        case (nil, nil) where candidateCachedAt != current.cachedAt:
            return candidateCachedAt > current.cachedAt
                ? DisplayPreferencesSelection(preferences: candidate, updatedAt: nil)
                : DisplayPreferencesSelection(
                    preferences: current.displayPreferences,
                    updatedAt: nil
                )
        default:
            break
        }

        guard candidate != current.displayPreferences else {
            return DisplayPreferencesSelection(
                preferences: current.displayPreferences,
                updatedAt: current.displayPreferencesUpdatedAt
            )
        }
        let currentData = (try? makeEncoder().encode(current.displayPreferences)) ?? Data()
        let candidateData = (try? makeEncoder().encode(candidate)) ?? Data()
        return currentData.lexicographicallyPrecedes(candidateData)
            ? DisplayPreferencesSelection(
                preferences: candidate,
                updatedAt: candidateUpdatedAt
            )
            : DisplayPreferencesSelection(
                preferences: current.displayPreferences,
                updatedAt: current.displayPreferencesUpdatedAt
            )
    }

    private static func coordinatedRemove(at url: URL) throws {
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else { return }
                try FileManager.default.removeItem(at: coordinatedURL)
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
    }

    private static func coordinatedRemoveIfCurrent(
        at url: URL,
        expected: WatchCompanionCacheLoadResult
    ) throws -> PayloadRemoveOutcome {
        var outcome: PayloadRemoveOutcome?
        var accessError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url,
            options: .forDeleting,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                guard FileManager.default.fileExists(atPath: coordinatedURL.path) else {
                    outcome = .removed
                    return
                }
                let current = try decodePayload(from: Data(contentsOf: coordinatedURL))
                let matchesExpected: Bool
                if let expectedRevision = expected.cacheRevision,
                   let currentRevision = current.revision {
                    matchesExpected = currentRevision == expectedRevision
                } else {
                    matchesExpected = current.document == expected.result.document
                        && current.displayPreferences == expected.displayPreferences
                        && current.displayPreferencesUpdatedAt == expected.displayPreferencesUpdatedAt
                        && current.cachedAt == expected.result.transportMetadata?.mirroredAt
                }
                guard matchesExpected else {
                    outcome = .keptCurrent(current)
                    return
                }
                try FileManager.default.removeItem(at: coordinatedURL)
                outcome = .removed
            } catch {
                accessError = error
            }
        }
        if let accessError { throw accessError }
        if let coordinatorError { throw coordinatorError }
        guard let outcome else { throw CacheError.missingPayload }
        return outcome
    }

    private static func decodePayload(from data: Data) throws -> Payload {
        let payload = try makeDecoder().decode(Payload.self, from: data)
        guard Payload.supportedSchemaVersions.contains(payload.schemaVersion),
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
        static let schemaVersion = 2
        static let supportedSchemaVersions = 1 ... schemaVersion

        let schemaVersion: Int
        let revision: UUID?
        let document: CompanionSyncDocument
        let displayPreferences: WidgetDisplayPreferences
        let displayPreferencesUpdatedAt: Date?
        let cachedAt: Date

        init(
            document: CompanionSyncDocument,
            displayPreferences: WidgetDisplayPreferences,
            displayPreferencesUpdatedAt: Date?,
            cachedAt: Date
        ) {
            schemaVersion = Self.schemaVersion
            revision = UUID()
            self.document = document
            self.displayPreferences = displayPreferences
            self.displayPreferencesUpdatedAt = displayPreferencesUpdatedAt
            self.cachedAt = cachedAt
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case revision
            case document
            case displayPreferences
            case displayPreferencesUpdatedAt
            case cachedAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            revision = try container.decodeIfPresent(UUID.self, forKey: .revision)
            document = try container.decode(CompanionSyncDocument.self, forKey: .document)
            displayPreferences = try container.decode(
                WidgetDisplayPreferences.self,
                forKey: .displayPreferences
            )
            displayPreferencesUpdatedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .displayPreferencesUpdatedAt
            )
            cachedAt = try container.decode(Date.self, forKey: .cachedAt)
        }
    }

    private struct DisplayPreferencesSelection {
        let preferences: WidgetDisplayPreferences
        let updatedAt: Date?
    }

    private enum CacheError: Error {
        case missingPayload
        case unsupportedSchema
    }

    private enum PayloadWriteOutcome {
        case saved(Payload)
        case keptCurrent(Payload)
    }

    private enum PayloadRemoveOutcome {
        case removed
        case keptCurrent(Payload)
    }
}
