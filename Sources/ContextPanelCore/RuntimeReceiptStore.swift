import Darwin
import Foundation

public struct RuntimeValidationSession: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumDuration: TimeInterval = 6 * 60 * 60
    public static let maximumClockSkew: TimeInterval = 5 * 60
    public static let maximumReceiptTTL: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumReceiptCount = 512

    public let schemaVersion: Int
    public let id: UUID
    public let createdAt: Date
    public let expiresAt: Date
    public let expectedManifestID: String
    public let enabledSurfaces: [RuntimeSurface]
    public let minimumWriteIntervalSeconds: TimeInterval
    public let receiptTTLSeconds: TimeInterval
    public let maximumReceiptCount: Int

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        expiresAt: Date,
        expectedManifestID: String,
        enabledSurfaces: [RuntimeSurface],
        minimumWriteIntervalSeconds: TimeInterval = 30,
        receiptTTLSeconds: TimeInterval = 24 * 60 * 60,
        maximumReceiptCount: Int = 128
    ) {
        schemaVersion = Self.schemaVersion
        self.id = id
        self.createdAt = Self.wholeSecond(createdAt)
        self.expiresAt = Self.wholeSecond(expiresAt)
        self.expectedManifestID = expectedManifestID
        self.enabledSurfaces = Array(Set(enabledSurfaces)).sorted { $0.rawValue < $1.rawValue }
        self.minimumWriteIntervalSeconds = minimumWriteIntervalSeconds
        self.receiptTTLSeconds = receiptTTLSeconds
        self.maximumReceiptCount = maximumReceiptCount
    }

    public func permits(
        _ identity: RuntimeSurfaceBuildIdentity,
        now: Date
    ) -> Bool {
        guard schemaVersion == Self.schemaVersion,
              RuntimeSurfaceFingerprints.isSHA256(expectedManifestID),
              createdAt <= expiresAt,
              expiresAt.timeIntervalSince(createdAt) <= Self.maximumDuration,
              createdAt <= now.addingTimeInterval(Self.maximumClockSkew),
              now < expiresAt,
              expectedManifestID == identity.build.manifestID,
              !enabledSurfaces.isEmpty,
              Set(enabledSurfaces).count == enabledSurfaces.count,
              enabledSurfaces.contains(identity.surface),
              minimumWriteIntervalSeconds >= 0,
              minimumWriteIntervalSeconds <= 5 * 60,
              minimumWriteIntervalSeconds.rounded(.down) == minimumWriteIntervalSeconds,
              receiptTTLSeconds >= 60,
              receiptTTLSeconds <= Self.maximumReceiptTTL,
              receiptTTLSeconds.rounded(.down) == receiptTTLSeconds,
              maximumReceiptCount > 0,
              maximumReceiptCount <= Self.maximumReceiptCount
        else {
            return false
        }
        return true
    }

    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

public struct RuntimeValidationSessionStore: Sendable {
    public let sessionURL: URL

    public init(sessionURL: URL) {
        self.sessionURL = sessionURL
    }

    public func activeSession(
        for identity: RuntimeSurfaceBuildIdentity,
        now: Date = Date()
    ) -> RuntimeValidationSession? {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? Self.makeDecoder().decode(RuntimeValidationSession.self, from: data),
              session.permits(identity, now: now)
        else {
            return nil
        }
        return session
    }

    public func save(_ session: RuntimeValidationSession) throws {
        try FileManager.default.createDirectory(
            at: sessionURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.makeEncoder().encode(session).write(to: sessionURL, options: [.atomic])
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
}

public enum RuntimeReceiptStoreSaveResult: Equatable, Sendable {
    case saved
    case rateLimited
    case busy
}

public enum RuntimeReceiptStoreError: Error, Equatable, Sendable {
    case invalidReceipt
}

public struct RuntimeReceiptStore: Sendable {
    public static let maximumRetainedReceiptCount = 4_096

    public let directoryURL: URL
    public let maximumRetainedReceiptCount: Int

    public init(
        directoryURL: URL,
        maximumRetainedReceiptCount: Int = Self.maximumRetainedReceiptCount
    ) {
        self.directoryURL = directoryURL
        self.maximumRetainedReceiptCount = max(
            1,
            min(maximumRetainedReceiptCount, Self.maximumRetainedReceiptCount)
        )
    }

    public func save(
        _ receipt: RuntimeReceipt,
        session: RuntimeValidationSession,
        now: Date = Date()
    ) throws -> RuntimeReceiptStoreSaveResult {
        guard receipt.isStructurallyValid,
              receipt.sessionID == session.id,
              receipt.sessionCreatedAt == RuntimeValidationSession.wholeSecond(session.createdAt),
              receipt.sessionExpiresAt == RuntimeValidationSession.wholeSecond(session.expiresAt),
              receipt.retentionExpiresAt == RuntimeValidationSession.wholeSecond(
                  receipt.observedAt.addingTimeInterval(session.receiptTTLSeconds)
              ),
              session.permits(receipt.buildIdentity, now: receipt.observedAt)
        else {
            throw RuntimeReceiptStoreError.invalidReceipt
        }
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        guard let lock = try ReceiptDirectoryLock(directoryURL: directoryURL) else {
            return .busy
        }
        defer { lock.unlock() }

        var storedReceipts = loadReceipts()
        if storedReceipts.contains(where: { stored in
            stored.rateLimitKey == receipt.rateLimitKey
                && stored.observedAt <= now
                && now.timeIntervalSince(stored.observedAt) < session.minimumWriteIntervalSeconds
        }) {
            return .rateLimited
        }

        let receiptURL = directoryURL.appending(path: "\(receipt.id).json")
        try Self.makeEncoder().encode(receipt).write(to: receiptURL, options: [.atomic])
        storedReceipts.append(receipt)
        prune(storedReceipts, session: session, now: now)
        return .saved
    }

    public func loadReceipts() -> [RuntimeReceipt] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let receipt = try? Self.makeDecoder().decode(RuntimeReceipt.self, from: data),
                      receipt.isStructurallyValid
                else {
                    return nil
                }
                return receipt
            }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
                if lhs.processInstanceID != rhs.processInstanceID {
                    return lhs.processInstanceID.uuidString < rhs.processInstanceID.uuidString
                }
                return lhs.processSequence < rhs.processSequence
            }
    }

    private func prune(
        _ receipts: [RuntimeReceipt],
        session: RuntimeValidationSession,
        now: Date
    ) {
        let unexpired = receipts.filter { now < $0.retentionExpiresAt }
        let currentSessionReceipts = unexpired
            .filter { $0.sessionID == session.id }
            .sorted { lhs, rhs in
                if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
                if lhs.processInstanceID != rhs.processInstanceID {
                    return lhs.processInstanceID.uuidString < rhs.processInstanceID.uuidString
                }
                return lhs.processSequence < rhs.processSequence
            }
            .suffix(session.maximumReceiptCount)
        let retained = (
            unexpired.filter { $0.sessionID != session.id }
                + currentSessionReceipts
        ).sorted { lhs, rhs in
            if lhs.observedAt != rhs.observedAt { return lhs.observedAt < rhs.observedAt }
            if lhs.processInstanceID != rhs.processInstanceID {
                return lhs.processInstanceID.uuidString < rhs.processInstanceID.uuidString
            }
            return lhs.processSequence < rhs.processSequence
        }.suffix(maximumRetainedReceiptCount)
        let retainedIDs = Set(retained.map(\.id))

        for receipt in receipts where !retainedIDs.contains(receipt.id) {
            try? FileManager.default.removeItem(
                at: directoryURL.appending(path: "\(receipt.id).json")
            )
        }
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
}

public enum RuntimeReceiptRecordResult: Equatable, Sendable {
    case saved
    case inactiveSession
    case invalidPresentationDigest
    case rateLimited
    case busy
    case failed
}

public final class RuntimeReceiptProcessContext: @unchecked Sendable {
    public static let shared = RuntimeReceiptProcessContext()

    public let id: UUID
    private let stateLock = NSLock()
    private var sequence: UInt64 = 0

    public init(id: UUID = UUID()) {
        self.id = id
    }

    func nextSequence() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        sequence &+= 1
        return sequence
    }
}

public final class RuntimeReceiptRecorder: @unchecked Sendable {
    private let identity: RuntimeSurfaceBuildIdentity?
    private let sessionStore: RuntimeValidationSessionStore
    private let receiptStore: RuntimeReceiptStore
    private let processContext: RuntimeReceiptProcessContext

    public init(
        identity: RuntimeSurfaceBuildIdentity?,
        sessionStore: RuntimeValidationSessionStore,
        receiptStore: RuntimeReceiptStore,
        processContext: RuntimeReceiptProcessContext = .shared
    ) {
        self.identity = identity
        self.sessionStore = sessionStore
        self.receiptStore = receiptStore
        self.processContext = processContext
    }

    public static func appDefault(
        surface: RuntimeSurface,
        bundle: Bundle = .main,
        appGroupID: String = ContextPanelLocations.appGroupID
    ) -> RuntimeReceiptRecorder {
        RuntimeReceiptRecorder(
            identity: RuntimeBuildIdentityLoader.load(surface: surface, bundle: bundle),
            sessionStore: RuntimeValidationSessionStore(
                sessionURL: ContextPanelLocations.runtimeValidationSessionURL(appGroupID: appGroupID)
            ),
            receiptStore: RuntimeReceiptStore(
                directoryURL: ContextPanelLocations.runtimeReceiptDirectory(appGroupID: appGroupID)
            )
        )
    }

    @discardableResult
    public func record(
        trigger: RuntimeReceiptTrigger,
        presentationMode: RuntimeReceiptPresentationMode,
        selectedSource: RuntimeReceiptSelectedSource,
        presentationDigest: String,
        stateBranch: RuntimeReceiptStateBranch,
        outcome: RuntimeReceiptOutcome,
        observedAt: Date = Date()
    ) -> RuntimeReceiptRecordResult {
        guard let identity,
              let session = sessionStore.activeSession(for: identity, now: observedAt)
        else {
            return .inactiveSession
        }
        guard RuntimeSurfaceFingerprints.isSHA256(presentationDigest) else {
            return .invalidPresentationDigest
        }

        let sequence = processContext.nextSequence()
        let receipt = RuntimeReceipt(
            session: session,
            observedAt: observedAt,
            processInstanceID: processContext.id,
            processSequence: sequence,
            buildIdentity: identity,
            trigger: trigger,
            presentationMode: presentationMode,
            selectedSource: selectedSource,
            presentationDigest: presentationDigest,
            stateBranch: stateBranch,
            outcome: outcome
        )

        do {
            switch try receiptStore.save(receipt, session: session, now: observedAt) {
            case .saved:
                return .saved
            case .rateLimited:
                return .rateLimited
            case .busy:
                return .busy
            }
        } catch {
            return .failed
        }
    }

}

private final class ReceiptDirectoryLock {
    private let descriptor: Int32

    init?(directoryURL: URL) throws {
        let lockURL = directoryURL.appending(path: ".write.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    func unlock() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
