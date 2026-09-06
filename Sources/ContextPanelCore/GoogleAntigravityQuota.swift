import Darwin
import Foundation

public struct GoogleAntigravityAccountConfiguration: Equatable, Sendable {
    public let accountID: String
    public let accountName: String

    public init(accountID: String, accountName: String = "Antigravity") {
        self.accountID = accountID
        self.accountName = accountName
    }
}

public struct GoogleAntigravityStatusLineBucket: Codable, Equatable, Sendable {
    public let id: String
    public let remainingFraction: Double?
    public let resetsAt: Date?
    public let isDisabled: Bool

    public init(id: String, remainingFraction: Double?, resetsAt: Date?, isDisabled: Bool = false) {
        self.id = id
        self.remainingFraction = remainingFraction
        self.resetsAt = resetsAt
        self.isDisabled = isDisabled
    }
}

public struct GoogleAntigravityStatusLineSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sourceVersion: String?
    public let planTier: String?
    public let observedAt: Date
    public let buckets: [GoogleAntigravityStatusLineBucket]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        sourceVersion: String? = nil,
        planTier: String? = nil,
        observedAt: Date,
        buckets: [GoogleAntigravityStatusLineBucket]
    ) {
        self.schemaVersion = schemaVersion
        self.sourceVersion = sourceVersion
        self.planTier = planTier
        self.observedAt = observedAt
        self.buckets = buckets
    }
}

public enum GoogleAntigravityStatusLineStoreError: LocalizedError, Equatable, Sendable {
    case unavailable
    case unsafeDirectory
    case unsafeFile
    case oversizedFile
    case unsupportedSchema(Int)
    case invalidSnapshot
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Antigravity bridge storage is unavailable."
        case .unsafeDirectory, .unsafeFile:
            "Antigravity bridge storage did not pass local safety checks."
        case .oversizedFile:
            "Antigravity bridge data exceeded the supported size."
        case .unsupportedSchema:
            "Antigravity bridge data needs a newer Context Panel build."
        case .invalidSnapshot:
            "Antigravity bridge data is invalid."
        case .writeFailed:
            "Antigravity bridge data could not be saved."
        }
    }
}

public struct GoogleAntigravityStatusLineSnapshotStore: Sendable {
    public static let maximumSnapshotBytes = 64 * 1_024

    private static let canonicalSnapshotFileName = "antigravity-status-line.json"
    private static let staleTemporaryFileAge: TimeInterval = 24 * 60 * 60

    public let snapshotURL: URL

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    public func load() throws -> GoogleAntigravityStatusLineSnapshot? {
        guard Self.isValidFileName(snapshotURL.lastPathComponent) else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        guard let directoryDescriptor = try Self.openSecureDirectory(
            snapshotURL.deletingLastPathComponent(),
            createIfMissing: false
        ) else {
            return nil
        }
        defer { close(directoryDescriptor) }
        guard let data = try Self.readSecureFile(
            named: snapshotURL.lastPathComponent,
            directoryDescriptor: directoryDescriptor,
            maximumBytes: Self.maximumSnapshotBytes
        ) else {
            return nil
        }

        let snapshot: GoogleAntigravityStatusLineSnapshot
        do {
            snapshot = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityStatusLineSnapshot.self, from: data)
        } catch {
            throw GoogleAntigravityStatusLineStoreError.invalidSnapshot
        }
        guard snapshot.schemaVersion == GoogleAntigravityStatusLineSnapshot.currentSchemaVersion else {
            throw GoogleAntigravityStatusLineStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard Self.isValid(snapshot: snapshot) else {
            throw GoogleAntigravityStatusLineStoreError.invalidSnapshot
        }
        return snapshot
    }

    public func save(_ snapshot: GoogleAntigravityStatusLineSnapshot) throws {
        guard snapshot.schemaVersion == GoogleAntigravityStatusLineSnapshot.currentSchemaVersion,
              Self.isValid(snapshot: snapshot)
        else {
            throw GoogleAntigravityStatusLineStoreError.invalidSnapshot
        }
        guard Self.isValidFileName(snapshotURL.lastPathComponent) else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }

        let data: Data
        do {
            data = try Self.makeEncoder().encode(snapshot)
        } catch {
            throw GoogleAntigravityStatusLineStoreError.invalidSnapshot
        }
        guard data.count <= Self.maximumSnapshotBytes else {
            throw GoogleAntigravityStatusLineStoreError.oversizedFile
        }

        guard let directoryDescriptor = try Self.openSecureDirectory(
            snapshotURL.deletingLastPathComponent(),
            createIfMissing: true
        ) else {
            throw GoogleAntigravityStatusLineStoreError.unavailable
        }
        defer { close(directoryDescriptor) }
        Self.removeStaleTemporaryFiles(
            for: snapshotURL.lastPathComponent,
            directoryDescriptor: directoryDescriptor,
            now: Date()
        )
        try Self.writeSecureFile(
            data,
            named: snapshotURL.lastPathComponent,
            directoryDescriptor: directoryDescriptor
        )
    }

    public func delete() throws {
        guard Self.isValidFileName(snapshotURL.lastPathComponent) else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        guard let directoryDescriptor = try Self.openSecureDirectory(
            snapshotURL.deletingLastPathComponent(),
            createIfMissing: false
        ) else {
            return
        }
        defer { close(directoryDescriptor) }

        let descriptor = openat(
            directoryDescriptor,
            snapshotURL.lastPathComponent,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1
        else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        guard unlinkat(directoryDescriptor, snapshotURL.lastPathComponent, 0) == 0 else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        _ = fsync(directoryDescriptor)
    }

    private static func isValid(snapshot: GoogleAntigravityStatusLineSnapshot) -> Bool {
        guard snapshot.buckets.count <= GoogleAntigravityStatusLineBridge.maximumBucketCount else { return false }
        guard snapshot.sourceVersion.map(GoogleAntigravityStatusLineBridge.isValidSourceVersion) ?? true else { return false }
        guard snapshot.planTier.map(GoogleAntigravityStatusLineBridge.isValidPlanTier) ?? true else { return false }
        return snapshot.buckets.allSatisfy { bucket in
            GoogleAntigravityStatusLineBridge.isValidBucketID(bucket.id)
                && bucket.remainingFraction.map { $0.isFinite && (0 ... 1).contains($0) } ?? true
        }
    }

    private static func isValidFileName(_ fileName: String) -> Bool {
        !fileName.isEmpty && fileName != "." && fileName != ".." && !fileName.contains("/")
    }

    private static func openSecureDirectory(
        _ directoryURL: URL,
        createIfMissing: Bool
    ) throws -> Int32? {
        var descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT, createIfMissing {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw GoogleAntigravityStatusLineStoreError.unavailable
            }
            descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT, !createIfMissing {
            return nil
        }
        guard descriptor >= 0 else {
            throw GoogleAntigravityStatusLineStoreError.unsafeDirectory
        }

        var information = stat()
        let isSafeDirectory = fstat(descriptor, &information) == 0
            && (information.st_mode & S_IFMT) == S_IFDIR
            && information.st_uid == geteuid()
            && information.st_nlink >= 1
        guard isSafeDirectory else {
            close(descriptor)
            throw GoogleAntigravityStatusLineStoreError.unsafeDirectory
        }

        if createIfMissing {
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                close(descriptor)
                throw GoogleAntigravityStatusLineStoreError.unsafeDirectory
            }
        } else if information.st_mode & 0o077 != 0 {
            close(descriptor)
            throw GoogleAntigravityStatusLineStoreError.unsafeDirectory
        }
        return descriptor
    }

    private static func readSecureFile(
        named fileName: String,
        directoryDescriptor: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw GoogleAntigravityStatusLineStoreError.unsafeFile
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_mode & 0o077 == 0,
              information.st_size >= 0,
              information.st_size <= maximumBytes
        else {
            throw information.st_size > maximumBytes
                ? GoogleAntigravityStatusLineStoreError.oversizedFile
                : GoogleAntigravityStatusLineStoreError.unsafeFile
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(8_192, maximumBytes + 1))
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw GoogleAntigravityStatusLineStoreError.unsafeFile
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw GoogleAntigravityStatusLineStoreError.oversizedFile
            }
        }
        return data
    }

    private static func removeStaleTemporaryFiles(
        for destinationFileName: String,
        directoryDescriptor: Int32,
        now: Date
    ) {
        guard destinationFileName == canonicalSnapshotFileName else { return }

        let enumerationDescriptor = openat(
            directoryDescriptor,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard enumerationDescriptor >= 0 else { return }
        guard let directory = fdopendir(enumerationDescriptor) else {
            close(enumerationDescriptor)
            return
        }
        defer { closedir(directory) }

        var removedFile = false
        while let entry = readdir(directory) {
            guard let fileName = directoryEntryName(entry),
                  isCanonicalTemporaryFileName(fileName),
                  removeStaleTemporaryFile(
                      named: fileName,
                      directoryDescriptor: directoryDescriptor,
                      now: now
                  )
            else {
                continue
            }
            removedFile = true
        }
        if removedFile {
            _ = fsync(directoryDescriptor)
        }
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String? {
        let length = Int(entry.pointee.d_namlen)
        let capacity = MemoryLayout.size(ofValue: entry.pointee.d_name)
        guard length > 0, length < capacity else { return nil }
        return withUnsafePointer(to: entry.pointee.d_name) { name in
            name.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
                String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8)
            }
        }
    }

    private static func isCanonicalTemporaryFileName(_ fileName: String) -> Bool {
        let prefix = ".\(canonicalSnapshotFileName)."
        let suffix = ".tmp"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return false }

        let identifier = fileName.dropFirst(prefix.count).dropLast(suffix.count)
        guard identifier.count == 36,
              let uuid = UUID(uuidString: String(identifier))
        else {
            return false
        }
        return uuid.uuidString == identifier
    }

    private static func removeStaleTemporaryFile(
        named fileName: String,
        directoryDescriptor: Int32,
        now: Date
    ) -> Bool {
        var pathInformation = stat()
        guard fstatat(directoryDescriptor, fileName, &pathInformation, AT_SYMLINK_NOFOLLOW) == 0,
              isEligibleStaleTemporaryFile(pathInformation, now: now)
        else {
            return false
        }

        let descriptor = openat(
            directoryDescriptor,
            fileName,
            O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var descriptorInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              isSameFile(pathInformation, descriptorInformation),
              isEligibleStaleTemporaryFile(descriptorInformation, now: now)
        else {
            return false
        }

        var finalPathInformation = stat()
        guard fstatat(directoryDescriptor, fileName, &finalPathInformation, AT_SYMLINK_NOFOLLOW) == 0,
              isSameFile(descriptorInformation, finalPathInformation),
              isEligibleStaleTemporaryFile(finalPathInformation, now: now)
        else {
            return false
        }
        return unlinkat(directoryDescriptor, fileName, 0) == 0
    }

    static func isEligibleStaleTemporaryFile(_ information: stat, now: Date) -> Bool {
        guard (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              (information.st_mode & 0o7777) == (S_IRUSR | S_IWUSR),
              information.st_size >= 0,
              information.st_size <= maximumSnapshotBytes,
              information.st_mtimespec.tv_nsec >= 0,
              information.st_mtimespec.tv_nsec < 1_000_000_000
        else {
            return false
        }

        let modificationTime = TimeInterval(information.st_mtimespec.tv_sec)
            + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        return now.timeIntervalSince1970 - modificationTime >= staleTemporaryFileAge
    }

    private static func isSameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func writeSecureFile(
        _ data: Data,
        named destinationFileName: String,
        directoryDescriptor: Int32
    ) throws {
        let temporaryFileName = ".\(destinationFileName).\(UUID().uuidString).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryFileName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw GoogleAntigravityStatusLineStoreError.writeFailed
        }

        var shouldRemoveTemporaryFile = true
        defer {
            close(descriptor)
            if shouldRemoveTemporaryFile {
                unlinkat(directoryDescriptor, temporaryFileName, 0)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), rawBuffer.count - offset)
                    if written <= 0 {
                        if errno == EINTR { continue }
                        throw GoogleAntigravityStatusLineStoreError.writeFailed
                    }
                    offset += written
                }
            }
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
                  fsync(descriptor) == 0,
                  renameat(
                      directoryDescriptor,
                      temporaryFileName,
                      directoryDescriptor,
                      destinationFileName
                  ) == 0
            else {
                throw GoogleAntigravityStatusLineStoreError.writeFailed
            }
            shouldRemoveTemporaryFile = false
            _ = fsync(directoryDescriptor)
        } catch {
            throw error as? GoogleAntigravityStatusLineStoreError ?? .writeFailed
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public enum GoogleAntigravityStatusLineIngestResult: Equatable, Sendable {
    case saved(GoogleAntigravityStatusLineSnapshot)
    case ignoredMissingQuota
    case ignoredEmptyQuota
}

public enum GoogleAntigravityStatusLineBridgeError: LocalizedError, Equatable, Sendable {
    case oversizedInput
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .oversizedInput:
            "Antigravity status input was too large."
        case .invalidPayload:
            "Antigravity status input was invalid."
        }
    }
}

public enum GoogleAntigravityStatusLineBridge {
    public static let maximumInputBytes = 64 * 1_024
    public static let maximumBucketCount = 128

    public static func ingest(
        data: Data,
        observedAt: Date = Date(),
        store: GoogleAntigravityStatusLineSnapshotStore
    ) throws -> GoogleAntigravityStatusLineIngestResult {
        guard data.count <= maximumInputBytes else {
            throw GoogleAntigravityStatusLineBridgeError.oversizedInput
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw GoogleAntigravityStatusLineBridgeError.invalidPayload
        }
        if let version = payload.version, !isValidSourceVersion(version) {
            throw GoogleAntigravityStatusLineBridgeError.invalidPayload
        }
        if let planTier = payload.planTier, !isValidPlanTier(planTier) {
            throw GoogleAntigravityStatusLineBridgeError.invalidPayload
        }
        guard let quota = payload.quota else {
            return .ignoredMissingQuota
        }
        guard !quota.isEmpty else {
            return .ignoredEmptyQuota
        }
        guard quota.count <= maximumBucketCount else {
            throw GoogleAntigravityStatusLineBridgeError.invalidPayload
        }

        let buckets = try quota.map { id, bucket -> GoogleAntigravityStatusLineBucket in
            guard isValidBucketID(id) else {
                throw GoogleAntigravityStatusLineBridgeError.invalidPayload
            }
            if let remainingFraction = bucket.remainingFraction,
               !remainingFraction.isFinite || !(0 ... 1).contains(remainingFraction) {
                throw GoogleAntigravityStatusLineBridgeError.invalidPayload
            }

            let resetsAt: Date?
            if let resetTime = bucket.resetTime {
                guard let parsed = ContextPanelDateFormatting.date(from: resetTime) else {
                    throw GoogleAntigravityStatusLineBridgeError.invalidPayload
                }
                resetsAt = parsed
            } else if let resetInSeconds = bucket.resetInSeconds {
                guard resetInSeconds.isFinite,
                      (0 ... 366 * 24 * 60 * 60).contains(resetInSeconds)
                else {
                    throw GoogleAntigravityStatusLineBridgeError.invalidPayload
                }
                resetsAt = observedAt.addingTimeInterval(resetInSeconds)
            } else {
                resetsAt = nil
            }

            return GoogleAntigravityStatusLineBucket(
                id: id,
                remainingFraction: bucket.remainingFraction,
                resetsAt: resetsAt,
                isDisabled: bucket.disabled ?? false
            )
        }.sorted { $0.id < $1.id }

        let snapshot = GoogleAntigravityStatusLineSnapshot(
            sourceVersion: payload.version,
            planTier: payload.planTier,
            observedAt: observedAt,
            buckets: buckets
        )
        try store.save(snapshot)
        return .saved(snapshot)
    }

    public static func statusLineText(for result: GoogleAntigravityStatusLineIngestResult) -> String {
        switch result {
        case .ignoredMissingQuota:
            return "Context Panel · quota pending"
        case .ignoredEmptyQuota:
            return "Context Panel · quota unavailable"
        case .saved(let snapshot):
            guard let remaining = (snapshot.buckets
                .filter { !$0.isDisabled }
                .compactMap(\.remainingFraction)
                .min()) else {
                return "Context Panel · quota unavailable"
            }
            return "Context Panel · \(Int((remaining * 100).rounded()))% lowest quota"
        }
    }

    public static let failureStatusLineText = "Context Panel · quota sync unavailable"

    static func isValidBucketID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48 ... 57, 58, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    static func isValidSourceVersion(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 32 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 43, 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    static func isValidPlanTier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 32, 43, 45, 46, 48 ... 57, 65 ... 90, 95, 97 ... 122:
                true
            default:
                false
            }
        }
    }

    private struct Payload: Decodable {
        let version: String?
        let planTier: String?
        let quota: [String: Bucket]?

        private enum CodingKeys: String, CodingKey {
            case version
            case planTier = "plan_tier"
            case quota
        }
    }

    private struct Bucket: Decodable {
        let remainingFraction: Double?
        let resetTime: String?
        let resetInSeconds: Double?
        let disabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
            case resetInSeconds = "reset_in_seconds"
            case disabled
        }
    }
}

public protocol GoogleAntigravityQuotaSnapshotLoading: Sendable {
    func load() throws -> GoogleAntigravityStatusLineSnapshot?
}

extension GoogleAntigravityStatusLineSnapshotStore: GoogleAntigravityQuotaSnapshotLoading {}

public struct GoogleAntigravityQuotaConnector: ProviderConnector {
    public let provider: Provider = .google

    private let accounts: [GoogleAntigravityAccountConfiguration]
    private let snapshotLoader: any GoogleAntigravityQuotaSnapshotLoading

    public init(
        accounts: [GoogleAntigravityAccountConfiguration],
        snapshotLoader: any GoogleAntigravityQuotaSnapshotLoading
    ) {
        self.accounts = accounts
        self.snapshotLoader = snapshotLoader
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        let snapshot: GoogleAntigravityStatusLineSnapshot?
        do {
            snapshot = try snapshotLoader.load()
        } catch {
            return ConnectorRefreshResult(generatedAt: now, reports: accounts.map { account in
                failureReport(
                    account: account,
                    now: now,
                    message: "Antigravity bridge data could not be read. The last good quota remains available while setup is checked."
                )
            })
        }

        return ConnectorRefreshResult(generatedAt: now, reports: accounts.map { account in
            report(account: account, snapshot: snapshot, now: now)
        })
    }

    private func report(
        account: GoogleAntigravityAccountConfiguration,
        snapshot: GoogleAntigravityStatusLineSnapshot?,
        now: Date
    ) -> ProviderConnectorReport {
        let localAccountID = ConnectorRedactor.localAccountID(provider: provider, stableID: account.accountID)
        guard let snapshot else {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.accountID,
                accountName: account.accountName,
                generatedAt: now,
                limits: [],
                status: .unknown,
                errorMessage: "Antigravity bridge setup is required. Copy the setup command from Context Panel and paste it into AGY CLI once. Later AGY runs publish quota automatically."
            )
        }

        guard snapshot.observedAt <= now.addingTimeInterval(5 * 60) else {
            return failureReport(
                account: account,
                now: now,
                message: "Antigravity bridge data had an invalid observation time."
            )
        }

        let limits = snapshot.buckets.filter { !$0.isDisabled }.map { bucket in
            usageLimit(
                bucket: bucket,
                account: account,
                localAccountID: localAccountID,
                observedAt: snapshot.observedAt
            )
        }

        if limits.isEmpty {
            return ProviderConnectorReport(
                provider: provider,
                accountID: localAccountID,
                configuredAccountID: account.accountID,
                accountName: account.accountName,
                generatedAt: snapshot.observedAt,
                limits: [],
                status: .unknown,
                errorMessage: "The Antigravity bridge is active, but AGY did not report active quota buckets."
            )
        }

        return ProviderConnectorReport(
            provider: provider,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            generatedAt: limits.compactMap(\.lastUpdatedAt).max() ?? snapshot.observedAt,
            limits: limits,
            status: nil,
            errorMessage: nil
        )
    }

    private func failureReport(
        account: GoogleAntigravityAccountConfiguration,
        now: Date,
        message: String
    ) -> ProviderConnectorReport {
        ProviderConnectorReport(
            provider: provider,
            accountID: ConnectorRedactor.localAccountID(provider: provider, stableID: account.accountID),
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            generatedAt: now,
            limits: [],
            status: .failure,
            errorMessage: message
        )
    }

    private func usageLimit(
        bucket: GoogleAntigravityStatusLineBucket,
        account: GoogleAntigravityAccountConfiguration,
        localAccountID: String,
        observedAt: Date
    ) -> UsageLimit {
        let labels = Self.labels(for: bucket.id)
        let used = bucket.remainingFraction.map { remaining in
            Int(((1 - remaining) * 100).rounded())
        }
        return UsageLimit(
            id: "\(provider.rawValue):\(localAccountID):agy:\(bucket.id)",
            provider: provider,
            accountID: localAccountID,
            configuredAccountID: account.accountID,
            accountName: account.accountName,
            label: labels.label,
            windowLabel: labels.window,
            modelLabel: labels.model,
            unit: .percent,
            used: used,
            limit: 100,
            resetsAt: bucket.resetsAt,
            lastUpdatedAt: observedAt,
            confidence: .observed,
            freshnessMode: .eventDriven,
            statusOverride: used == nil ? .unknown : nil,
            note: "source: AGY documented status-line quota export; bucket: \(bucket.id)"
        )
    }

    private static func labels(for bucketID: String) -> (label: String, window: String?, model: String?) {
        let components = bucketID
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        let window: String?
        let windowIndexes = Set(components.indices.filter { index in
            let component = components[index].lowercased()
            return component == "weekly" || component == "week" || component == "5h"
        })
        if components.contains(where: { ["weekly", "week"].contains($0.lowercased()) }) {
            window = "Weekly"
        } else if components.contains(where: { $0.lowercased() == "5h" }) {
            window = "5-hour"
        } else {
            window = nil
        }

        let modelComponents = components.enumerated().compactMap { index, component in
            windowIndexes.contains(index) ? nil : displayComponent(component)
        }
        let model = modelComponents.isEmpty ? nil : modelComponents.joined(separator: " ")
        let label = [model, window].compactMap { $0 }.joined(separator: " ")
        return (label.isEmpty ? bucketID : label, window, model)
    }

    private static func displayComponent(_ component: String) -> String {
        switch component.lowercased() {
        case "ai": "AI"
        case "agy": "AGY"
        case "gpt": "GPT"
        case "oss": "OSS"
        case "gemini": "Gemini"
        case "claude": "Claude"
        default:
            component.prefix(1).uppercased() + component.dropFirst()
        }
    }
}

public enum GoogleAntigravityStatusLineSetup {
    public static let removeCommand = "/statusline delete"

    public static func setupCommand(applicationBundleURL: URL) -> String {
        let executableURL = applicationBundleURL
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
            .appending(path: "LoginItems", directoryHint: .isDirectory)
            .appending(path: "ContextPanelRefreshAgent.app", directoryHint: .isDirectory)
            .appending(path: "Contents", directoryHint: .isDirectory)
            .appending(path: "MacOS", directoryHint: .isDirectory)
            .appending(path: "ContextPanelRefreshAgent")
        return "/statusline \(shellQuoted(executableURL.path)) --ingest-antigravity-status-line"
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
