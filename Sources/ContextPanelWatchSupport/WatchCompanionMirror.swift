import ContextPanelCore
import Foundation

public struct WatchCompanionMirrorLoadResult: Equatable, Sendable {
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

public struct WatchCompanionMirror: Sendable {
    private let mirrorURL: URL?

    public init(mirrorURL: URL? = ContextPanelLocations.watchCompanionMirrorURL()) {
        self.mirrorURL = mirrorURL
    }

    public func load() -> WatchCompanionMirrorLoadResult {
        guard let mirrorURL else {
            return WatchCompanionMirrorLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "Context Panel Watch shared storage is unavailable."
                ),
                displayPreferences: nil
            )
        }
        guard FileManager.default.fileExists(atPath: mirrorURL.path) else {
            return WatchCompanionMirrorLoadResult(
                result: CompanionSyncLoadResult(document: nil, status: .unknown),
                displayPreferences: nil
            )
        }

        do {
            let payload = try Self.loadPayload(at: mirrorURL)
            return WatchCompanionMirrorLoadResult(
                result: CompanionSyncLoadResult(
                    document: payload.document,
                    status: payload.document.companionStatus,
                    transportMetadata: CompanionSyncTransportMetadata(
                        source: .appGroup,
                        mirroredAt: payload.mirroredAt,
                        deliveryStatus: .healthy
                    )
                ),
                displayPreferences: payload.displayPreferences
            )
        } catch {
            return WatchCompanionMirrorLoadResult(
                result: CompanionSyncLoadResult(
                    document: nil,
                    status: .failure,
                    errorMessage: "Context Panel Watch could not read shared usage."
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
        guard let mirrorURL else { return false }
        do {
            let candidate = Payload(
                document: document,
                displayPreferences: displayPreferences,
                mirroredAt: now
            )
            try Self.coordinatedWrite(candidate, to: mirrorURL)
            return true
        } catch {
            return false
        }
    }

    private static func shouldKeepCurrent(
        _ current: CompanionSyncDocument?,
        over candidate: CompanionSyncDocument
    ) -> Bool {
        guard let current else { return false }
        if current.snapshot.generatedAt != candidate.snapshot.generatedAt {
            return current.snapshot.generatedAt > candidate.snapshot.generatedAt
        }
        return current.snapshot.publishedAt > candidate.snapshot.publishedAt
    }

    private static func loadPayload(at mirrorURL: URL) throws -> Payload {
        var payload: Payload?
        var readError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: mirrorURL,
            options: [],
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                payload = try decodePayload(from: Data(contentsOf: coordinatedURL))
            } catch {
                readError = error
            }
        }
        if let readError { throw readError }
        if let coordinatorError { throw coordinatorError }
        guard let payload else { throw MirrorError.missingPayload }
        return payload
    }

    private static func coordinatedWrite(_ candidate: Payload, to mirrorURL: URL) throws {
        let data = try makeEncoder().encode(candidate)
        var writeError: Error?
        var coordinatorError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: mirrorURL,
            options: .forReplacing,
            error: &coordinatorError
        ) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path),
                   let current = try? decodePayload(from: Data(contentsOf: coordinatedURL)),
                   shouldKeepCurrent(current.document, over: candidate.document) {
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

    private static func decodePayload(from data: Data) throws -> Payload {
        let payload = try makeDecoder().decode(Payload.self, from: data)
        guard payload.schemaVersion == Payload.schemaVersion,
              payload.document.schemaVersion == CompanionSyncDocument.schemaVersion,
              payload.document.snapshot.schemaVersion == CompanionSnapshot.schemaVersion
        else {
            throw MirrorError.unsupportedSchema
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
        let mirroredAt: Date

        init(
            document: CompanionSyncDocument,
            displayPreferences: WidgetDisplayPreferences,
            mirroredAt: Date
        ) {
            schemaVersion = Self.schemaVersion
            self.document = document
            self.displayPreferences = displayPreferences
            self.mirroredAt = mirroredAt
        }
    }

    private enum MirrorError: Error {
        case missingPayload
        case unsupportedSchema
    }
}
