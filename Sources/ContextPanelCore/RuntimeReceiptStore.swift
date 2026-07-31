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
        guard isStructurallyValid(now: now, requiresActive: true),
              expectedManifestID == identity.build.manifestID,
              enabledSurfaces.contains(identity.surface)
        else {
            return false
        }
        return true
    }

    public func isStructurallyValid(
        now: Date,
        requiresActive: Bool
    ) -> Bool {
        schemaVersion == Self.schemaVersion
            && RuntimeSurfaceFingerprints.isSHA256(expectedManifestID)
            && createdAt <= expiresAt
            && expiresAt.timeIntervalSince(createdAt) <= Self.maximumDuration
            && createdAt <= now.addingTimeInterval(Self.maximumClockSkew)
            && (!requiresActive || now < expiresAt)
            && !enabledSurfaces.isEmpty
            && Set(enabledSurfaces).count == enabledSurfaces.count
            && minimumWriteIntervalSeconds >= 0
            && minimumWriteIntervalSeconds <= 5 * 60
            && minimumWriteIntervalSeconds.rounded(.down) == minimumWriteIntervalSeconds
            && receiptTTLSeconds >= 60
            && receiptTTLSeconds <= Self.maximumReceiptTTL
            && receiptTTLSeconds.rounded(.down) == receiptTTLSeconds
            && maximumReceiptCount > 0
            && maximumReceiptCount <= Self.maximumReceiptCount
    }

    public func permitsRelay(
        expectedManifestID: String,
        eligibleSurfaces: [RuntimeSurface],
        now: Date
    ) -> Bool {
        isStructurallyValid(now: now, requiresActive: true)
            && self.expectedManifestID == expectedManifestID
            && !Set(enabledSurfaces).isDisjoint(with: eligibleSurfaces)
    }

    public var receiptRetentionExpiresAt: Date {
        Self.wholeSecond(expiresAt.addingTimeInterval(receiptTTLSeconds))
    }

    public func isRetained(now: Date) -> Bool {
        isStructurallyValid(now: now, requiresActive: false)
            && now < receiptRetentionExpiresAt
    }

    static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }
}

public struct RuntimeValidationSessionStore: Sendable {
    public let sessionURL: URL

    public var archivedSessionURL: URL {
        sessionURL.deletingLastPathComponent().appending(path: "runtime-session-last.json")
    }

    public var sessionsDirectoryURL: URL {
        sessionURL.deletingLastPathComponent().appending(
            path: "Runtime Sessions",
            directoryHint: .isDirectory
        )
    }

    public var remoteStateURL: URL {
        sessionURL.deletingLastPathComponent().appending(
            path: "runtime-session-remote-state.json"
        )
    }

    public init(sessionURL: URL) {
        self.sessionURL = sessionURL
    }

    public func activeSession(
        for identity: RuntimeSurfaceBuildIdentity,
        now: Date = Date()
    ) -> RuntimeValidationSession? {
        guard let session = activeSession(now: now),
              session.permits(identity, now: now)
        else {
            return nil
        }
        return session
    }

    public func activeSession(now: Date = Date()) -> RuntimeValidationSession? {
        loadSession(at: sessionURL, now: now, requiresActive: true)
    }

    public func latestSession(now: Date = Date()) -> RuntimeValidationSession? {
        if let current = loadSession(at: sessionURL, now: now, requiresActive: false) {
            return current
        }
        return retainedSessions(now: now).last
    }

    public func retainedSessions(now: Date = Date()) -> [RuntimeValidationSession] {
        var urls = [sessionURL, archivedSessionURL]
        if let journalURLs = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            urls.append(contentsOf: journalURLs.filter { $0.pathExtension == "json" })
        }

        var sessionsByID: [UUID: RuntimeValidationSession] = [:]
        var conflictingIDs: Set<UUID> = []
        for url in urls {
            guard let session = loadSession(at: url, now: now, requiresActive: false),
                  session.isRetained(now: now)
            else {
                continue
            }
            if let existing = sessionsByID[session.id], existing != session {
                sessionsByID.removeValue(forKey: session.id)
                conflictingIDs.insert(session.id)
            } else if !conflictingIDs.contains(session.id) {
                sessionsByID[session.id] = session
            }
        }
        return sessionsByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func save(_ session: RuntimeValidationSession) throws {
        try save(session, now: session.createdAt)
    }

    public func save(
        _ session: RuntimeValidationSession,
        now: Date
    ) throws {
        let directoryURL = sessionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectoryURL,
            withIntermediateDirectories: true
        )
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }

        try saveUnlocked(session, now: now)
    }

    public func removeActiveSession() throws {
        let current = loadSession(at: sessionURL, now: Date(), requiresActive: false)
        try removeActiveSession(now: current?.createdAt ?? Date())
    }

    public func removeActiveSession(now: Date) throws {
        let directoryURL = sessionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }

        try removeActiveSessionUnlocked(now: now)
    }

    @discardableResult
    public func applyRemoteState(
        _ state: RuntimeValidationSessionRemoteState,
        session: RuntimeValidationSession?,
        stateUpdatedAt: Date?,
        now: Date
    ) throws -> Bool {
        guard state != .missing,
              let stateUpdatedAt,
              stateUpdatedAt <= now.addingTimeInterval(
                  RuntimeValidationSession.maximumClockSkew
              )
        else {
            return false
        }
        let directoryURL = sessionURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
            throw RuntimeReceiptRemoteSyncError.busy
        }
        defer { lock.unlock() }

        if let currentState = loadRemoteState() {
            if currentState.stateUpdatedAt > stateUpdatedAt {
                return false
            }
            if currentState.stateUpdatedAt == stateUpdatedAt {
                if currentState.state == state {
                    return false
                }
                if currentState.state == .cleared, state == .active {
                    return false
                }
            }
        }
        switch state {
        case .active:
            guard let session,
                  session.isStructurallyValid(now: now, requiresActive: true)
            else {
                throw RuntimeReceiptRemoteSyncError.invalidSession
            }
            try FileManager.default.createDirectory(
                at: sessionsDirectoryURL,
                withIntermediateDirectories: true
            )
            try saveUnlocked(session, now: now)
        case .cleared:
            try removeActiveSessionUnlocked(now: now)
        case .missing:
            return false
        }
        let remoteState = RuntimeValidationSessionRemoteMirrorState(
            state: state,
            stateUpdatedAt: stateUpdatedAt
        )
        try Self.makeRemoteStateEncoder().encode(remoteState).write(
            to: remoteStateURL,
            options: [.atomic]
        )
        return true
    }

    private func saveUnlocked(
        _ session: RuntimeValidationSession,
        now: Date
    ) throws {
        if let current = loadSession(at: sessionURL, now: now, requiresActive: false) {
            try archive(current)
        }
        let data = try Self.makeEncoder().encode(session)
        try data.write(to: sessionURL, options: [.atomic])
        try data.write(to: archivedSessionURL, options: [.atomic])
        try archive(session)
        pruneJournal(now: now)
    }

    private func removeActiveSessionUnlocked(now: Date) throws {
        let current = loadSession(at: sessionURL, now: now, requiresActive: false)
        if let current {
            try FileManager.default.createDirectory(
                at: sessionsDirectoryURL,
                withIntermediateDirectories: true
            )
            try archive(current)
            try Self.makeEncoder().encode(current).write(to: archivedSessionURL, options: [.atomic])
        }
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            try FileManager.default.removeItem(at: sessionURL)
        }
        pruneJournal(now: now)
    }

    private func loadRemoteState() -> RuntimeValidationSessionRemoteMirrorState? {
        guard let data = try? Data(contentsOf: remoteStateURL),
              let state = try? Self.makeRemoteStateDecoder().decode(
                  RuntimeValidationSessionRemoteMirrorState.self,
                  from: data
              ),
              state.schemaVersion == RuntimeValidationSessionRemoteMirrorState.schemaVersion
        else {
            return nil
        }
        return state
    }

    private func archive(_ session: RuntimeValidationSession) throws {
        let url = sessionsDirectoryURL.appending(
            path: "\(session.id.uuidString.lowercased()).json"
        )
        let data = try Self.makeEncoder().encode(session)
        if let existingData = try? Data(contentsOf: url) {
            guard let existing = try? Self.makeDecoder().decode(
                RuntimeValidationSession.self,
                from: existingData
            ),
            existing == session
            else {
                throw RuntimeReceiptRemoteSyncError.conflictingSession
            }
            return
        }
        try data.write(to: url, options: [.atomic])
    }

    private func pruneJournal(now: Date) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        let known = urls.compactMap { url -> (URL, RuntimeValidationSession)? in
            guard url.pathExtension == "json",
                  let session = loadSession(at: url, now: now, requiresActive: false)
            else {
                return nil
            }
            return (url, session)
        }
        let retainedURLs = Set(known.filter { $0.1.isRetained(now: now) }.map { $0.0 })
        for (url, _) in known where !retainedURLs.contains(url) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func loadSession(
        at url: URL,
        now: Date,
        requiresActive: Bool
    ) -> RuntimeValidationSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? Self.makeDecoder().decode(RuntimeValidationSession.self, from: data),
              session.isStructurallyValid(now: now, requiresActive: requiresActive)
        else {
            return nil
        }
        return session
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

    private static func makeRemoteStateEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func makeRemoteStateDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private struct RuntimeValidationSessionRemoteMirrorState: Codable, Equatable, Sendable {
    static let schemaVersion = 2

    let schemaVersion: Int
    let state: RuntimeValidationSessionRemoteState
    let stateUpdatedAt: Date

    init(state: RuntimeValidationSessionRemoteState, stateUpdatedAt: Date) {
        schemaVersion = Self.schemaVersion
        self.state = state
        self.stateUpdatedAt = stateUpdatedAt
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
        guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
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

        return RuntimeReceipt.ordered(urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let receipt = try? Self.makeDecoder().decode(RuntimeReceipt.self, from: data),
                      receipt.isStructurallyValid
                else {
                    return nil
                }
                return receipt
            })
    }

    public func loadUnexpiredReceipts(now: Date = Date()) -> [RuntimeReceipt] {
        loadReceipts().filter { now < $0.retentionExpiresAt }
    }

    public func pruneExpiredReceipts(now: Date = Date()) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            guard let lock = try RuntimeReceiptDirectoryLock(directoryURL: directoryURL) else {
                return
            }
            defer { lock.unlock() }
            for receipt in loadReceipts() where now >= receipt.retentionExpiresAt {
                try? FileManager.default.removeItem(
                    at: directoryURL.appending(path: "\(receipt.id).json")
                )
            }
        } catch {
            return
        }
    }

    private func prune(
        _ receipts: [RuntimeReceipt],
        session: RuntimeValidationSession,
        now: Date
    ) {
        let unexpired = receipts.filter { now < $0.retentionExpiresAt }
        let currentSessionReceipts = RuntimeReceipt.ordered(
            unexpired.filter { $0.sessionID == session.id }
        )
            .suffix(session.maximumReceiptCount)
        let retained = RuntimeReceipt.ordered(
            unexpired.filter { $0.sessionID != session.id }
                + currentSessionReceipts
        ).suffix(maximumRetainedReceiptCount)
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
    private let sessionStore: RuntimeValidationSessionStore?
    private let receiptStore: RuntimeReceiptStore?
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

    private init(processContext: RuntimeReceiptProcessContext = .shared) {
        identity = nil
        sessionStore = nil
        receiptStore = nil
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

    public static func appGroupRequired(
        surface: RuntimeSurface,
        bundle: Bundle = .main,
        appGroupID: String
    ) -> RuntimeReceiptRecorder {
        guard let validationDirectory = ContextPanelLocations.sharedRuntimeValidationDirectory(
            appGroupID: appGroupID
        ) else {
            return RuntimeReceiptRecorder()
        }
        return RuntimeReceiptRecorder(
            identity: RuntimeBuildIdentityLoader.load(surface: surface, bundle: bundle),
            sessionStore: RuntimeValidationSessionStore(
                sessionURL: validationDirectory.appending(path: "runtime-session.json")
            ),
            receiptStore: RuntimeReceiptStore(
                directoryURL: validationDirectory.appending(
                    path: "Runtime Receipts",
                    directoryHint: .isDirectory
                )
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
              let sessionStore,
              let receiptStore,
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

final class RuntimeReceiptDirectoryLock {
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
