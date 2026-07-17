import Darwin
import Foundation

public enum LimitWarningWebhookPreset: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case genericJSON
    case discord

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .genericJSON:
            "Generic JSON"
        case .discord:
            "Discord"
        }
    }
}

public struct LimitWarningWebhookSettings: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public var isEnabled: Bool
    public var preset: LimitWarningWebhookPreset
    public var destinationLabel: String
    public var mentionText: String
    public var timeoutSeconds: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case preset
        case destinationLabel
        case mentionText
        case timeoutSeconds
    }

    public init(
        isEnabled: Bool = false,
        preset: LimitWarningWebhookPreset = .discord,
        destinationLabel: String = "",
        mentionText: String = "",
        timeoutSeconds: Double = 5
    ) {
        schemaVersion = 1
        self.isEnabled = isEnabled
        self.preset = preset
        self.destinationLabel = Self.clampedDestinationLabel(destinationLabel)
        self.mentionText = Self.clampedMentionText(mentionText)
        self.timeoutSeconds = Self.clampedTimeout(seconds: timeoutSeconds)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        preset = try container.decodeIfPresent(LimitWarningWebhookPreset.self, forKey: .preset) ?? .discord
        destinationLabel = Self.clampedDestinationLabel(
            try container.decodeIfPresent(String.self, forKey: .destinationLabel) ?? ""
        )
        mentionText = Self.clampedMentionText(
            try container.decodeIfPresent(String.self, forKey: .mentionText) ?? ""
        )
        timeoutSeconds = Self.clampedTimeout(
            seconds: try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? 5
        )
    }

    public static var defaultSettings: LimitWarningWebhookSettings {
        LimitWarningWebhookSettings()
    }

    public mutating func setDestinationLabel(_ label: String) {
        destinationLabel = Self.clampedDestinationLabel(label)
    }

    public mutating func setMentionText(_ text: String) {
        mentionText = Self.clampedMentionText(text)
    }

    private static func clampedDestinationLabel(_ label: String) -> String {
        String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
    }

    private static func clampedMentionText(_ text: String) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }

    private static func clampedTimeout(seconds: Double) -> Double {
        min(max(seconds, 2), 15)
    }
}

public struct LimitWarningWebhookSettingsStore: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL) {
        self.settingsURL = settingsURL
    }

    public func load() -> LimitWarningWebhookSettings {
        loadIfAvailable() ?? .defaultSettings
    }

    public func loadIfAvailable() -> LimitWarningWebhookSettings? {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return nil
        }

        do {
            let settings = try JSONDecoder().decode(
                LimitWarningWebhookSettings.self,
                from: try Data(contentsOf: settingsURL)
            )
            guard settings.schemaVersion == 1 else { return nil }
            return settings
        } catch {
            return nil
        }
    }

    public func save(_ settings: LimitWarningWebhookSettings) throws {
        let directory = settingsURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: [.atomic])
    }
}

public struct LimitWarningWebhookDeliveryRecord: Codable, Equatable, Sendable {
    public let deliveryKey: String
    public let laneID: String
    public let channelID: String
    public let isTest: Bool
    public var lastAttemptedAt: Date
    public var lastSucceededAt: Date?
    public var lastHTTPStatus: Int?
    public var lastError: String?

    public init(
        deliveryKey: String,
        laneID: String,
        channelID: String = LimitWarningWebhookDeliveryState.defaultChannelID,
        isTest: Bool = false,
        lastAttemptedAt: Date,
        lastSucceededAt: Date?,
        lastHTTPStatus: Int?,
        lastError: String?
    ) {
        self.deliveryKey = deliveryKey
        self.laneID = laneID
        self.channelID = channelID
        self.isTest = isTest
        self.lastAttemptedAt = lastAttemptedAt
        self.lastSucceededAt = lastSucceededAt
        self.lastHTTPStatus = lastHTTPStatus
        self.lastError = lastError.map(ConnectorRedactor.safeErrorDescription)
    }

    public var succeeded: Bool { lastSucceededAt != nil }
}

public struct LimitWarningWebhookDeliveryState: Codable, Equatable, Sendable {
    public static let defaultChannelID = "primary-webhook"

    public let schemaVersion: Int
    public var records: [LimitWarningWebhookDeliveryRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case records
    }

    public init(records: [LimitWarningWebhookDeliveryRecord] = []) {
        schemaVersion = 1
        self.records = Self.normalized(records)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        records = Self.normalized(try container.decode([LimitWarningWebhookDeliveryRecord].self, forKey: .records))
    }

    public static var empty: LimitWarningWebhookDeliveryState { LimitWarningWebhookDeliveryState() }

    public var latestRecord: LimitWarningWebhookDeliveryRecord? {
        records.filter { !$0.isTest }.max { lhs, rhs in lhs.lastAttemptedAt < rhs.lastAttemptedAt }
    }

    public var latestTestRecord: LimitWarningWebhookDeliveryRecord? {
        records.filter(\.isTest).max { lhs, rhs in lhs.lastAttemptedAt < rhs.lastAttemptedAt }
    }

    public func record(for deliveryKey: String) -> LimitWarningWebhookDeliveryRecord? {
        records.first { $0.deliveryKey == deliveryKey }
    }

    public func hasSucceeded(deliveryKey: String) -> Bool {
        record(for: deliveryKey)?.succeeded == true
    }

    public mutating func upsert(_ record: LimitWarningWebhookDeliveryRecord) {
        let identity = Self.identityKey(for: record)
        if let index = records.firstIndex(where: { Self.identityKey(for: $0) == identity }) {
            records[index] = record
        } else {
            records.append(record)
        }
        records = Self.normalized(records)
    }

    public mutating func removeRecords(forMissing laneIDs: Set<String>) {
        records.removeAll { !$0.isTest && !laneIDs.contains($0.laneID) }
    }

    private static func normalized(_ records: [LimitWarningWebhookDeliveryRecord]) -> [LimitWarningWebhookDeliveryRecord] {
        records
            .reduce(into: [String: LimitWarningWebhookDeliveryRecord]()) { result, record in
                let identity = identityKey(for: record)
                guard !identity.isEmpty else { return }
                if let existing = result[identity], existing.lastAttemptedAt > record.lastAttemptedAt {
                    return
                }
                result[identity] = record
            }
            .values
            .sorted { lhs, rhs in
                let lhsIdentity = identityKey(for: lhs)
                let rhsIdentity = identityKey(for: rhs)
                return lhsIdentity < rhsIdentity
            }
    }

    private static func identityKey(for record: LimitWarningWebhookDeliveryRecord) -> String {
        if record.isTest {
            return "test:\(record.channelID)"
        }
        return "live:\(record.channelID):\(record.laneID)"
    }
}

public struct LimitWarningWebhookDeliveryStateStore: Sendable {
    public let stateURL: URL

    public init(stateURL: URL) {
        self.stateURL = stateURL
    }

    public func load() -> LimitWarningWebhookDeliveryState {
        loadIfAvailable() ?? .empty
    }

    public func loadIfAvailable() -> LimitWarningWebhookDeliveryState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(
                LimitWarningWebhookDeliveryState.self,
                from: try Data(contentsOf: stateURL)
            )
            guard state.schemaVersion == 1 else { return nil }
            return state
        } catch {
            return nil
        }
    }

    public func save(_ state: LimitWarningWebhookDeliveryState) throws {
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }
}

public protocol LimitWarningWebhookSecretLoading: Sendable {
    func loadWebhookURL() throws -> URL?
}

public protocol LimitWarningWebhookSecretStoring: LimitWarningWebhookSecretLoading {
    func saveWebhookURL(_ url: URL) throws
    func deleteWebhookURL() throws
}

public struct LimitWarningWebhookSecretStore: LimitWarningWebhookSecretStoring {
    public static let defaultService = "com.shinycomputers.contextpanel.webhook-credentials"
    public static let defaultAccountID = "primary-webhook-url"

    private let credentialStore: ProviderCredentialStore
    private let accountID: String

    public init(
        service: String = Self.defaultService,
        accessGroup: String? = ProviderCredentialStore.defaultAccessGroup,
        accountID: String = Self.defaultAccountID
    ) {
        credentialStore = ProviderCredentialStore(service: service, accessGroup: accessGroup)
        self.accountID = accountID
    }

    public func loadWebhookURL() throws -> URL? {
        guard
            let data = try credentialStore.load(accountID: accountID),
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return Self.validatedWebhookURL(value)
    }

    public func saveWebhookURL(_ url: URL) throws {
        guard let validatedURL = Self.validatedWebhookURL(url.absoluteString) else {
            throw SecretError.invalidURL
        }
        try credentialStore.save(Data(validatedURL.absoluteString.utf8), accountID: accountID)
    }

    public func deleteWebhookURL() throws {
        try credentialStore.delete(accountID: accountID)
    }

    public static func validatedWebhookURL(_ value: String) -> URL? {
        LimitWarningWebhookURLPolicy.validatedURL(value)
    }

    public enum SecretError: LocalizedError, Sendable {
        case invalidURL

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Webhook URL must be a non-local https URL."
            }
        }
    }
}

public enum LimitWarningWebhookURLPolicy {
    public static func validatedURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https",
            url.user == nil,
            url.password == nil,
            let host = normalizedHost(url.host),
            isPublicHost(host)
        else {
            return nil
        }
        return url
    }

    public static func allowsRedirect(
        statusCode: Int,
        from sourceURL: URL,
        to destinationURL: URL
    ) -> Bool {
        guard
            statusCode == 307 || statusCode == 308,
            let validatedDestination = validatedURL(destinationURL.absoluteString),
            let sourceHost = normalizedHost(sourceURL.host),
            let destinationHost = normalizedHost(validatedDestination.host)
        else {
            return false
        }
        return sourceURL.scheme?.lowercased() == "https"
            && sourceHost == destinationHost
            && effectivePort(sourceURL) == effectivePort(validatedDestination)
    }

    private static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        let normalized = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? 443
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let hostWithoutTrailingDot = host.hasSuffix(".") ? String(host.dropLast()) : host
        guard hostWithoutTrailingDot != "localhost",
              !hostWithoutTrailingDot.hasSuffix(".localhost"),
              !hostWithoutTrailingDot.hasSuffix(".local"),
              hostWithoutTrailingDot != "metadata.google.internal"
        else {
            return false
        }
        if let bytes = ipv4Bytes(hostWithoutTrailingDot) {
            return isPublicIPv4(bytes)
        }
        if let bytes = ipv6Bytes(hostWithoutTrailingDot) {
            return isPublicIPv6(bytes)
        }
        return hostWithoutTrailingDot.contains(".")
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        return switch (bytes[0], bytes[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168):
            false
        case (100, 64...127):
            false
        case (172, 16...31):
            false
        case (192, 0), (192, 2), (192, 88):
            false
        case (198, 18...19), (198, 51), (203, 0):
            false
        case (224...255, _):
            false
        default:
            true
        }
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) {
            return false
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 {
            return false
        }
        if bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFF {
            return false
        }
        if bytes[0] == 0xFE,
           bytes[1] & 0xC0 == 0x80 || bytes[1] & 0xC0 == 0xC0 {
            return false
        }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }),
           bytes[10] == 0xFF,
           bytes[11] == 0xFF {
            return isPublicIPv4(Array(bytes.suffix(4)))
        }
        return true
    }
}

public struct LimitWarningWebhookPayload: Equatable, Sendable {
    public let data: Data
    public let contentType: String
}

public enum LimitWarningWebhookPayloadBuilder {
    public static func deliveryKey(
        event: LimitWarningEvent,
        channelID: String = LimitWarningWebhookDeliveryState.defaultChannelID
    ) -> String {
        let resetIdentity = event.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "no-reset"
        return [channelID, event.laneID, resetIdentity, String(event.thresholdPercentRemaining)]
            .joined(separator: ":")
    }

    public static func payload(
        for event: LimitWarningEvent,
        settings: LimitWarningWebhookSettings,
        sentAt: Date,
        appVersion: String = "Context Panel"
    ) throws -> LimitWarningWebhookPayload {
        switch settings.preset {
        case .genericJSON:
            return try genericPayload(for: event, settings: settings, sentAt: sentAt, appVersion: appVersion)
        case .discord:
            return try discordPayload(for: event, settings: settings, sentAt: sentAt, appVersion: appVersion)
        }
    }

    public static func testEvent(now: Date = Date()) -> LimitWarningEvent {
        LimitWarningEvent(
            laneID: "test:fiveHour",
            provider: .openAI,
            window: .fiveHour,
            thresholdPercentRemaining: 10,
            capacityRatio: 0.08,
            remaining: 8,
            limit: 100,
            resetsAt: now.addingTimeInterval(45 * 60),
            accountCount: 2
        )
    }

    private static func genericPayload(
        for event: LimitWarningEvent,
        settings: LimitWarningWebhookSettings,
        sentAt: Date,
        appVersion: String
    ) throws -> LimitWarningWebhookPayload {
        let payload: [String: Any] = [
            "type": "context_panel.limit_warning",
            "app": "Context Panel",
            "appVersion": appVersion,
            "sentAt": ContextPanelDateFormatting.string(from: sentAt),
            "event": eventDictionary(event),
            "destination": destinationDictionary(settings),
        ]
        return LimitWarningWebhookPayload(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            contentType: "application/json"
        )
    }

    private static func discordPayload(
        for event: LimitWarningEvent,
        settings: LimitWarningWebhookSettings,
        sentAt: Date,
        appVersion: String
    ) throws -> LimitWarningWebhookPayload {
        let title = event.title
        let fields: [[String: Any]] = [
            ["name": "Capacity", "value": capacityText(event), "inline": false],
            ["name": "Reset", "value": resetText(event), "inline": true],
        ]
        let embed: [String: Any] = [
            "title": title,
            "description": discordDescription(event),
            "color": discordColor(for: event.capacityRatio),
            "fields": fields,
            "footer": ["text": "Context Panel \(appVersion)"],
            "timestamp": ContextPanelDateFormatting.string(from: sentAt),
        ]
        var payload: [String: Any] = ["embeds": [embed]]
        if !settings.mentionText.isEmpty {
            payload["content"] = settings.mentionText
            payload["allowed_mentions"] = ["parse": ["users", "roles", "everyone"]]
        }
        return LimitWarningWebhookPayload(
            data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            contentType: "application/json"
        )
    }

    private static func eventDictionary(_ event: LimitWarningEvent) -> [String: Any] {
        var dictionary: [String: Any] = [
            "laneID": event.laneID,
            "provider": event.provider.rawValue,
            "providerName": event.provider.displayName,
            "window": event.window.rawValue,
            "windowName": event.window.displayName,
            "thresholdPercentRemaining": event.thresholdPercentRemaining,
            "percentRemaining": Int((event.capacityRatio * 100).rounded()),
            "capacityRatio": event.capacityRatio,
            "accountCount": event.accountCount,
        ]
        if let remaining = event.remaining {
            dictionary["remaining"] = remaining
        }
        if let limit = event.limit {
            dictionary["limit"] = limit
        }
        if let resetsAt = event.resetsAt {
            dictionary["resetsAt"] = ContextPanelDateFormatting.string(from: resetsAt)
        }
        return dictionary
    }

    private static func destinationDictionary(_ settings: LimitWarningWebhookSettings) -> [String: Any] {
        var dictionary: [String: Any] = ["preset": settings.preset.rawValue]
        if !settings.destinationLabel.isEmpty {
            dictionary["label"] = settings.destinationLabel
        }
        return dictionary
    }

    private static func discordColor(for capacityRatio: Double) -> Int {
        if capacityRatio <= 0.05 { return 0xD92D20 }
        if capacityRatio <= 0.15 { return 0xF79009 }
        return 0xFEC84B
    }

    private static func discordDescription(_ event: LimitWarningEvent) -> String {
        "\(event.provider.displayName) \(event.window.displayName) capacity is below your "
            + "\(event.thresholdPercentRemaining)% warning threshold."
    }

    private static func capacityText(_ event: LimitWarningEvent) -> String {
        let percent = Int((event.capacityRatio * 100).rounded())
        let limitSummary: String
        if let remaining = event.remaining, let limit = event.limit {
            limitSummary = " (\(remaining)/\(limit) points)"
        } else {
            limitSummary = ""
        }
        return "\(capacityBar(for: event.capacityRatio)) \(percent)% left\(limitSummary)"
    }

    private static func capacityBar(for capacityRatio: Double) -> String {
        let segments = 10
        let clampedRatio = min(max(capacityRatio, 0), 1)
        let filled = Int((clampedRatio * Double(segments)).rounded())
        let empty = segments - filled
        return "[\(String(repeating: "#", count: filled))\(String(repeating: "-", count: empty))]"
    }

    private static func resetText(_ event: LimitWarningEvent) -> String {
        guard let resetsAt = event.resetsAt else { return "Unknown" }
        return "<t:\(Int(resetsAt.timeIntervalSince1970)):R>"
    }
}

public struct LimitWarningWebhookDeliveryResult: Equatable, Sendable {
    public let attempted: Bool
    public let succeeded: Bool
    public let statusCode: Int?
    public let errorMessage: String?

    public static var skipped: LimitWarningWebhookDeliveryResult {
        LimitWarningWebhookDeliveryResult(attempted: false, succeeded: false, statusCode: nil, errorMessage: nil)
    }
}

public struct LimitWarningWebhookDeliverySummary: Equatable, Sendable {
    public let succeeded: Bool
    public let eventCount: Int
    public let lastHTTPStatus: Int?
    public let errorMessage: String?

    public init?(results: [LimitWarningWebhookDeliveryResult]) {
        guard !results.isEmpty else { return nil }
        succeeded = results.allSatisfy(\.succeeded)
        eventCount = results.count
        lastHTTPStatus = results.reversed().compactMap(\.statusCode).first
        errorMessage = results.reversed().compactMap(\.errorMessage).first
    }
}

public protocol LimitWarningWebhookPosting: Sendable {
    func post(payload: LimitWarningWebhookPayload, to url: URL, timeoutSeconds: Double) async throws -> Int
}

public struct URLSessionLimitWarningWebhookPoster: LimitWarningWebhookPosting {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        session = URLSession(
            configuration: configuration,
            delegate: LimitWarningWebhookRedirectDelegate(),
            delegateQueue: nil
        )
    }

    public func post(payload: LimitWarningWebhookPayload, to url: URL, timeoutSeconds: Double) async throws -> Int {
        guard LimitWarningWebhookURLPolicy.validatedURL(url.absoluteString) != nil else {
            throw LimitWarningWebhookSecretStore.SecretError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = payload.data
        request.setValue(payload.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("Context Panel", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { return 0 }
        return httpResponse.statusCode
    }
}

private final class LimitWarningWebhookRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard
            let sourceURL = task.currentRequest?.url,
            let destinationURL = request.url,
            LimitWarningWebhookURLPolicy.allowsRedirect(
                statusCode: response.statusCode,
                from: sourceURL,
                to: destinationURL
            )
        else {
            return nil
        }
        return request
    }
}

public struct LimitWarningWebhookDeliveryService: Sendable {
    public enum ConfigurationError: LocalizedError, Sendable {
        case lockTimedOut

        public var errorDescription: String? {
            "Another webhook delivery is still running. Try again in a moment."
        }
    }

    public let warningSettingsStore: LimitWarningSettingsStore
    public let settingsStore: LimitWarningWebhookSettingsStore
    public let stateStore: LimitWarningWebhookDeliveryStateStore
    public let secretStore: any LimitWarningWebhookSecretLoading
    public let poster: any LimitWarningWebhookPosting
    public let appVersion: String
    public let deliveryLock: SnapshotRefreshLock
    public let lockWaitDuration: Duration
    public let lockRetryInterval: Duration

    public init(
        warningSettingsStore: LimitWarningSettingsStore,
        settingsStore: LimitWarningWebhookSettingsStore,
        stateStore: LimitWarningWebhookDeliveryStateStore,
        secretStore: any LimitWarningWebhookSecretLoading,
        poster: any LimitWarningWebhookPosting = URLSessionLimitWarningWebhookPoster(),
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
        deliveryLock: SnapshotRefreshLock? = nil,
        lockWaitDuration: Duration = .seconds(30),
        lockRetryInterval: Duration = .milliseconds(50)
    ) {
        self.warningSettingsStore = warningSettingsStore
        self.settingsStore = settingsStore
        self.stateStore = stateStore
        self.secretStore = secretStore
        self.poster = poster
        self.appVersion = appVersion
        self.deliveryLock = deliveryLock ?? SnapshotRefreshLock(
            lockURL: stateStore.stateURL.appendingPathExtension("lock")
        )
        self.lockWaitDuration = lockWaitDuration
        self.lockRetryInterval = lockRetryInterval
    }

    public static func appDefault(appGroupID: String = ContextPanelLocations.appGroupID) -> LimitWarningWebhookDeliveryService {
        LimitWarningWebhookDeliveryService(
            warningSettingsStore: LimitWarningSettingsStore(
                settingsURL: ContextPanelLocations.limitWarningSettingsURL(appGroupID: appGroupID)
            ),
            settingsStore: LimitWarningWebhookSettingsStore(
                settingsURL: ContextPanelLocations.webhookSettingsURL(appGroupID: appGroupID)
            ),
            stateStore: LimitWarningWebhookDeliveryStateStore(
                stateURL: ContextPanelLocations.webhookDeliveryStateURL(appGroupID: appGroupID)
            ),
            secretStore: LimitWarningWebhookSecretStore()
        )
    }

    public func updateConfiguration(_ operation: @escaping @Sendable () throws -> Void) async throws {
        let startedAt = ContinuousClock.now
        while !Task.isCancelled {
            if let _ = try await deliveryLock.withLock({
                try operation()
                try stateStore.save(.empty)
            }) {
                return
            }
            guard startedAt.duration(to: ContinuousClock.now) < lockWaitDuration else {
                throw ConfigurationError.lockTimedOut
            }
            try await Task.sleep(for: lockRetryInterval)
        }
        throw CancellationError()
    }

    public func deliverIfNeeded(
        decision: SnapshotRefreshRunDecision,
        now: Date = Date()
    ) async -> [LimitWarningWebhookDeliveryResult] {
        guard case let .refreshed(outcome) = decision else { return [] }
        let persistedSnapshot = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        ).loadCurrent().snapshot
        return await deliverIfNeeded(
            snapshot: LimitWarningSnapshotResolver.effectiveSnapshot(
                transientSnapshot: outcome.refreshResult.snapshot,
                persistedSnapshot: persistedSnapshot
            ),
            now: now
        )
    }

    public func deliverIfNeeded(
        snapshot: UsageSnapshot,
        now: Date = Date()
    ) async -> [LimitWarningWebhookDeliveryResult] {
        await withDeliveryLock {
            await deliverIfNeededWhileLocked(snapshot: snapshot, now: now)
        } ?? []
    }

    private func deliverIfNeededWhileLocked(
        snapshot: UsageSnapshot,
        now: Date
    ) async -> [LimitWarningWebhookDeliveryResult] {
        let presentationSnapshot = snapshot.presented(at: now)
        var state = stateStore.load()
        state.removeRecords(forMissing: Set(presentationSnapshot.mainLimitSummaries.map(\.id)))
        defer { try? stateStore.save(state) }

        let settings = settingsStore.load()
        guard settings.isEnabled else { return [] }
        guard let webhookURL = try? secretStore.loadWebhookURL() else { return [] }
        let warningSettings = warningSettingsStore.load()
        let events = LimitWarningWebhookEventEvaluator.events(
            snapshot: presentationSnapshot,
            thresholdPercentRemaining: warningSettings.thresholdPercentRemaining
        )
        var results: [LimitWarningWebhookDeliveryResult] = []
        for event in events {
            let deliveryKey = LimitWarningWebhookPayloadBuilder.deliveryKey(event: event)
            guard !state.hasSucceeded(deliveryKey: deliveryKey) else { continue }
            let result = await deliver(
                event: event,
                settings: settings,
                webhookURL: webhookURL,
                deliveryKey: deliveryKey,
                now: now,
                state: &state
            )
            results.append(result)
        }
        return results
    }

    @discardableResult
    public func sendTest(now: Date = Date()) async -> LimitWarningWebhookDeliveryResult {
        await withDeliveryLock {
            await sendTestWhileLocked(now: now)
        } ?? LimitWarningWebhookDeliveryResult(
            attempted: false,
            succeeded: false,
            statusCode: nil,
            errorMessage: "Another webhook delivery is in progress. Try again in a moment."
        )
    }

    private func sendTestWhileLocked(now: Date) async -> LimitWarningWebhookDeliveryResult {
        var settings = settingsStore.load()
        settings.isEnabled = true
        guard let webhookURL = try? secretStore.loadWebhookURL() else {
            return LimitWarningWebhookDeliveryResult(
                attempted: false,
                succeeded: false,
                statusCode: nil,
                errorMessage: "Webhook URL is not configured."
            )
        }
        var state = stateStore.load()
        let event = LimitWarningWebhookPayloadBuilder.testEvent(now: now)
        let deliveryKey = "test:\(Int(now.timeIntervalSince1970))"
        let result = await deliver(
            event: event,
            settings: settings,
            webhookURL: webhookURL,
            deliveryKey: deliveryKey,
            now: now,
            state: &state
        )
        try? stateStore.save(state)
        return result
    }

    private func withDeliveryLock<T>(_ operation: () async -> T) async -> T? {
        let startedAt = ContinuousClock.now
        while !Task.isCancelled {
            do {
                if let value = try await deliveryLock.withLock(operation) {
                    return value
                }
            } catch {
                return nil
            }
            guard startedAt.duration(to: ContinuousClock.now) < lockWaitDuration else {
                return nil
            }
            do {
                try await Task.sleep(for: lockRetryInterval)
            } catch {
                return nil
            }
        }
        return nil
    }

    private func deliver(
        event: LimitWarningEvent,
        settings: LimitWarningWebhookSettings,
        webhookURL: URL,
        deliveryKey: String,
        now: Date,
        state: inout LimitWarningWebhookDeliveryState
    ) async -> LimitWarningWebhookDeliveryResult {
        do {
            let payload = try LimitWarningWebhookPayloadBuilder.payload(
                for: event,
                settings: settings,
                sentAt: now,
                appVersion: appVersion
            )
            let statusCode = try await poster.post(
                payload: payload,
                to: webhookURL,
                timeoutSeconds: settings.timeoutSeconds
            )
            let succeeded = (200...299).contains(statusCode)
            state.upsert(LimitWarningWebhookDeliveryRecord(
                deliveryKey: deliveryKey,
                laneID: event.laneID,
                isTest: deliveryKey.hasPrefix("test:"),
                lastAttemptedAt: now,
                lastSucceededAt: succeeded ? now : nil,
                lastHTTPStatus: statusCode,
                lastError: succeeded ? nil : "HTTP \(statusCode)"
            ))
            return LimitWarningWebhookDeliveryResult(
                attempted: true,
                succeeded: succeeded,
                statusCode: statusCode,
                errorMessage: succeeded ? nil : "HTTP \(statusCode)"
            )
        } catch {
            let message = ConnectorRedactor.safeErrorDescription(error)
            state.upsert(LimitWarningWebhookDeliveryRecord(
                deliveryKey: deliveryKey,
                laneID: event.laneID,
                isTest: deliveryKey.hasPrefix("test:"),
                lastAttemptedAt: now,
                lastSucceededAt: nil,
                lastHTTPStatus: nil,
                lastError: message
            ))
            return LimitWarningWebhookDeliveryResult(
                attempted: true,
                succeeded: false,
                statusCode: nil,
                errorMessage: message
            )
        }
    }
}

public enum LimitWarningWebhookEventEvaluator {
    public static func events(
        snapshot: UsageSnapshot,
        thresholdPercentRemaining: Int
    ) -> [LimitWarningEvent] {
        let threshold = Double(min(max(thresholdPercentRemaining, 1), 75)) / 100
        return snapshot.mainLimitSummaries.compactMap { summary in
            guard let usageRatio = summary.usageRatio else { return nil }
            let capacityRatio = max(1 - usageRatio, 0)
            guard capacityRatio <= threshold else { return nil }
            return LimitWarningEvent(
                laneID: summary.id,
                provider: summary.provider,
                window: summary.window,
                thresholdPercentRemaining: thresholdPercentRemaining,
                capacityRatio: capacityRatio,
                remaining: summary.remaining,
                limit: summary.limit,
                resetsAt: summary.resetsAt,
                accountCount: summary.accountCount
            )
        }
        .sorted { lhs, rhs in lhs.capacityRatio < rhs.capacityRatio }
    }
}
