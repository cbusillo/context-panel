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

public struct GoogleAntigravityUsageBucket: Codable, Equatable, Sendable {
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

public struct GoogleAntigravityUsageSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let observedAt: Date
    public let buckets: [GoogleAntigravityUsageBucket]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        observedAt: Date,
        buckets: [GoogleAntigravityUsageBucket]
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.buckets = buckets
    }
}

public enum GoogleAntigravityUsageStoreError: LocalizedError, Equatable, Sendable {
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

public struct GoogleAntigravityUsageSnapshotStore: Sendable {
    public static let maximumSnapshotBytes = 64 * 1_024

    private static let canonicalSnapshotFileName = "antigravity-status-line.json"
    private static let staleTemporaryFileAge: TimeInterval = 24 * 60 * 60

    public let snapshotURL: URL

    public init(snapshotURL: URL) {
        self.snapshotURL = snapshotURL
    }

    public func load() throws -> GoogleAntigravityUsageSnapshot? {
        guard Self.isValidFileName(snapshotURL.lastPathComponent) else {
            throw GoogleAntigravityUsageStoreError.unsafeFile
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

        let snapshot: GoogleAntigravityUsageSnapshot
        do {
            snapshot = try JSONDecoder.contextPanelISO8601.decode(GoogleAntigravityUsageSnapshot.self, from: data)
        } catch {
            throw GoogleAntigravityUsageStoreError.invalidSnapshot
        }
        guard snapshot.schemaVersion == GoogleAntigravityUsageSnapshot.currentSchemaVersion else {
            throw GoogleAntigravityUsageStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        guard Self.isValid(snapshot: snapshot) else {
            throw GoogleAntigravityUsageStoreError.invalidSnapshot
        }
        return snapshot
    }

    public func save(_ snapshot: GoogleAntigravityUsageSnapshot) throws {
        guard snapshot.schemaVersion == GoogleAntigravityUsageSnapshot.currentSchemaVersion,
              Self.isValid(snapshot: snapshot)
        else {
            throw GoogleAntigravityUsageStoreError.invalidSnapshot
        }
        guard Self.isValidFileName(snapshotURL.lastPathComponent) else {
            throw GoogleAntigravityUsageStoreError.unsafeFile
        }

        let data: Data
        do {
            data = try Self.makeEncoder().encode(snapshot)
        } catch {
            throw GoogleAntigravityUsageStoreError.invalidSnapshot
        }
        guard data.count <= Self.maximumSnapshotBytes else {
            throw GoogleAntigravityUsageStoreError.oversizedFile
        }

        guard let directoryDescriptor = try Self.openSecureDirectory(
            snapshotURL.deletingLastPathComponent(),
            createIfMissing: true
        ) else {
            throw GoogleAntigravityUsageStoreError.unavailable
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
            throw GoogleAntigravityUsageStoreError.unsafeFile
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
            throw GoogleAntigravityUsageStoreError.unsafeFile
        }
        defer { close(descriptor) }

        var information = stat()
        guard fstat(descriptor, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_uid == geteuid(),
              information.st_nlink == 1
        else {
            throw GoogleAntigravityUsageStoreError.unsafeFile
        }
        guard unlinkat(directoryDescriptor, snapshotURL.lastPathComponent, 0) == 0 else {
            throw GoogleAntigravityUsageStoreError.unsafeFile
        }
        _ = fsync(directoryDescriptor)
    }

    private static func isValid(snapshot: GoogleAntigravityUsageSnapshot) -> Bool {
        guard snapshot.buckets.count <= GoogleAntigravityUsageBridge.maximumBucketCount else { return false }
        return snapshot.buckets.allSatisfy { bucket in
            GoogleAntigravityUsageBridge.isValidBucketID(bucket.id)
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
                throw GoogleAntigravityUsageStoreError.unavailable
            }
            descriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if descriptor < 0, errno == ENOENT, !createIfMissing {
            return nil
        }
        guard descriptor >= 0 else {
            throw GoogleAntigravityUsageStoreError.unsafeDirectory
        }

        var information = stat()
        let isSafeDirectory = fstat(descriptor, &information) == 0
            && (information.st_mode & S_IFMT) == S_IFDIR
            && information.st_uid == geteuid()
            && information.st_nlink >= 1
        guard isSafeDirectory else {
            close(descriptor)
            throw GoogleAntigravityUsageStoreError.unsafeDirectory
        }

        if createIfMissing {
            guard fchmod(descriptor, S_IRWXU) == 0 else {
                close(descriptor)
                throw GoogleAntigravityUsageStoreError.unsafeDirectory
            }
        } else if information.st_mode & 0o077 != 0 {
            close(descriptor)
            throw GoogleAntigravityUsageStoreError.unsafeDirectory
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
            throw GoogleAntigravityUsageStoreError.unsafeFile
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
                ? GoogleAntigravityUsageStoreError.oversizedFile
                : GoogleAntigravityUsageStoreError.unsafeFile
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(8_192, maximumBytes + 1))
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw GoogleAntigravityUsageStoreError.unsafeFile
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumBytes else {
                throw GoogleAntigravityUsageStoreError.oversizedFile
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
            throw GoogleAntigravityUsageStoreError.writeFailed
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
                        throw GoogleAntigravityUsageStoreError.writeFailed
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
                throw GoogleAntigravityUsageStoreError.writeFailed
            }
            shouldRemoveTemporaryFile = false
            _ = fsync(directoryDescriptor)
        } catch {
            throw error as? GoogleAntigravityUsageStoreError ?? .writeFailed
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

public enum GoogleAntigravityUsageIngestResult: Equatable, Sendable {
    case saved(GoogleAntigravityUsageSnapshot)
    case ignoredMissingQuota
    case ignoredEmptyQuota
}

public enum GoogleAntigravityUsageBridgeError: LocalizedError, Equatable, Sendable {
    case oversizedInput
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .oversizedInput:
            "Antigravity usage input was too large."
        case .invalidPayload:
            "Antigravity usage input was invalid."
        }
    }
}

public enum GoogleAntigravityUsageBridge {
    public static let maximumInputBytes = 64 * 1_024
    public static let maximumBucketCount = 128

    public static func ingest(
        data: Data,
        observedAt: Date = Date(),
        store: GoogleAntigravityUsageSnapshotStore
    ) throws -> GoogleAntigravityUsageIngestResult {
        guard data.count <= maximumInputBytes else {
            throw GoogleAntigravityUsageBridgeError.oversizedInput
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw GoogleAntigravityUsageBridgeError.invalidPayload
        }
        guard payload.status == "SUCCESS", payload.command?.name == "usage" else {
            throw GoogleAntigravityUsageBridgeError.invalidPayload
        }
        guard let groups = payload.command?.data?.groups else {
            return .ignoredMissingQuota
        }
        guard groups.count <= maximumBucketCount else {
            throw GoogleAntigravityUsageBridgeError.invalidPayload
        }
        let quota = groups.flatMap { $0.buckets ?? [] }
        guard !quota.isEmpty else {
            return .ignoredEmptyQuota
        }
        guard quota.count <= maximumBucketCount, Set(quota.map(\.id)).count == quota.count else {
            throw GoogleAntigravityUsageBridgeError.invalidPayload
        }

        let buckets = try quota.map { bucket -> GoogleAntigravityUsageBucket in
            let id = bucket.id
            guard isValidBucketID(id) else {
                throw GoogleAntigravityUsageBridgeError.invalidPayload
            }
            if let remainingFraction = bucket.remainingFraction,
               !remainingFraction.isFinite || !(0 ... 1).contains(remainingFraction) {
                throw GoogleAntigravityUsageBridgeError.invalidPayload
            }

            let resetsAt: Date?
            if let resetTime = bucket.resetTime {
                guard let parsed = ContextPanelDateFormatting.date(from: resetTime) else {
                    throw GoogleAntigravityUsageBridgeError.invalidPayload
                }
                resetsAt = parsed
            } else {
                resetsAt = nil
            }

            return GoogleAntigravityUsageBucket(
                id: id,
                remainingFraction: bucket.remainingFraction,
                resetsAt: resetsAt,
                isDisabled: bucket.disabled ?? false
            )
        }.sorted { $0.id < $1.id }

        let snapshot = GoogleAntigravityUsageSnapshot(
            observedAt: observedAt,
            buckets: buckets
        )
        try store.save(snapshot)
        return .saved(snapshot)
    }

    public static func publish(
        snapshot: GoogleAntigravityUsageSnapshot,
        configuration: AccountConfigurationDocument,
        runner: SnapshotRefreshRunner
    ) async throws {
        let accounts = configuration.accounts.filter {
            $0.isEnabled && $0.connectorKind == .googleAntigravityQuota
        }.map { GoogleAntigravityAccountConfiguration(accountID: $0.id, accountName: $0.displayName) }
        guard !accounts.isEmpty else { return }
        let result = await GoogleAntigravityQuotaConnector(
            accounts: accounts,
            snapshotLoader: SavedSnapshot(snapshot: snapshot)
        ).refresh(now: snapshot.observedAt)
        let decision = try await runner.saveMerged(
            refreshResult: result,
            savedAt: snapshot.observedAt,
            retryFor: .seconds(10),
            preservesUnreportedAccounts: true
        )
        guard case .refreshed(let outcome) = decision, outcome.didSaveSnapshot else {
            throw GoogleAntigravityUsageBridgeError.invalidPayload
        }
    }

    private struct SavedSnapshot: GoogleAntigravityQuotaSnapshotLoading {
        let snapshot: GoogleAntigravityUsageSnapshot
        func load() -> GoogleAntigravityUsageSnapshot? { snapshot }
    }

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

    private struct Payload: Decodable {
        let status: String
        let command: Command?
    }

    private struct Command: Decodable {
        let name: String
        let data: QuotaData?
    }

    private struct QuotaData: Decodable {
        let groups: [Group]?
    }

    private struct Group: Decodable {
        let buckets: [Bucket]?
    }

    private struct Bucket: Decodable {
        let id: String
        let remainingFraction: Double?
        let resetTime: String?
        let disabled: Bool?

        private enum CodingKeys: String, CodingKey {
            case id
            case remainingFraction = "remaining_fraction"
            case resetTime = "reset_time"
            case disabled
        }
    }
}

public protocol GoogleAntigravityQuotaSnapshotLoading: Sendable {
    func load() throws -> GoogleAntigravityUsageSnapshot?
}

extension GoogleAntigravityUsageSnapshotStore: GoogleAntigravityQuotaSnapshotLoading {}

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
        let snapshot: GoogleAntigravityUsageSnapshot?
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
        snapshot: GoogleAntigravityUsageSnapshot?,
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
                errorMessage: "Antigravity bridge setup is required. Copy the setup command from Context Panel and paste it into AGY CLI once. Later AGY runs publish quota automatically.",
            accountIdentityStatus: .notExposedByConnector
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
                errorMessage: "The Antigravity bridge is active, but AGY did not report active quota buckets.",
            accountIdentityStatus: .notExposedByConnector
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
            errorMessage: nil,
            accountIdentityStatus: .notExposedByConnector
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
            errorMessage: message,
            accountIdentityStatus: .notExposedByConnector
        )
    }

    private func usageLimit(
        bucket: GoogleAntigravityUsageBucket,
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
            note: "source: AGY /usage quota export; bucket: \(bucket.id)"
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

public enum GoogleAntigravityUsageSetup {
    public static let hookName = "context-panel-google-usage"

    public static var removeCommand: String {
        "Remove only the \"\(hookName)\" entry from ~/.gemini/config/hooks.json. Keep every other hook and setting. Then use Forget in Context Panel to remove its saved Google reading."
    }

    public static func hookCommand(applicationBundleURL: URL, agyExecutable: String = "agy") -> String {
        let executableURL = applicationBundleURL
            .appending(path: "Contents/Library/LoginItems/ContextPanelRefreshAgent.app/Contents/MacOS/ContextPanelRefreshAgent")
        return "\(shellQuoted(agyExecutable)) -p '/usage' --output-format json --print-timeout 30s </dev/null 2>/dev/null | \(shellQuoted(executableURL.path)) --ingest-antigravity-usage"
    }

    public static func setupCommand(applicationBundleURL: URL) -> String {
        let entry: [String: Any] = [hookName: ["Stop": [[
            "type": "command",
            "command": hookCommand(applicationBundleURL: applicationBundleURL),
            "timeout": 60,
        ]]]]
        let data = try! JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let json = String(decoding: data, as: UTF8.self)
        return """
        Set up Context Panel's Google reading in AGY. In ~/.gemini/config/hooks.json, add or replace only the "\(hookName)" entry shown below. Preserve every other hook and setting. Resolve 'agy' in its command to this AGY installation's absolute executable path, keeping shell quoting. Do not read or change login credentials. If an existing custom status line invokes ContextPanelRefreshAgent with --ingest-antigravity-status-line, remove that obsolete Context Panel status line with /statusline delete; preserve any other status line. Restart existing AGY sessions to load the hook.

        \(json)
        """
    }

    static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
