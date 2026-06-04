import Foundation

public enum ConnectorError: LocalizedError, Equatable, Sendable {
    case missingAuth(String)
    case invalidAuth(String)
    case httpFailure(operation: String, statusCode: Int)
    case nonHTTPResponse(String)
    case processFailure(operation: String, exitCode: Int32)
    case decodingFailure(String)

    public var errorDescription: String? {
        switch self {
        case let .missingAuth(message), let .invalidAuth(message), let .nonHTTPResponse(message), let .decodingFailure(message):
            return message
        case let .httpFailure(operation, statusCode):
            if statusCode == 401 || statusCode == 403 {
                return "\(operation) was not authorized. Reauthorize this account and try again."
            }
            if statusCode == 429 {
                return "\(operation) is rate limited. Try again after the provider reset window."
            }
            return "\(operation) returned HTTP \(statusCode); raw body redacted"
        case let .processFailure(operation, exitCode):
            return "\(operation) failed with exit code \(exitCode); stderr redacted"
        }
    }
}

public struct ProviderConnectorReport: Equatable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let configuredAccountID: String?
    public let accountName: String
    public let generatedAt: Date
    public let limits: [UsageLimit]
    public let status: UsageStatus
    public let errorMessage: String?

    public init(
        provider: Provider,
        accountID: String,
        configuredAccountID: String? = nil,
        accountName: String,
        generatedAt: Date,
        limits: [UsageLimit],
        status: UsageStatus? = nil,
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
        self.configuredAccountID = configuredAccountID
        self.accountName = accountName
        self.generatedAt = generatedAt
        self.limits = limits
        self.status = status ?? UsageSnapshot(generatedAt: generatedAt, limits: limits).aggregateStatus
        self.errorMessage = errorMessage.map(ConnectorRedactor.redact)
    }
}

public struct ConnectorRefreshResult: Equatable, Sendable {
    public let generatedAt: Date
    public let reports: [ProviderConnectorReport]
    public let promptCacheObservations: [PromptCacheObservation]

    public init(
        generatedAt: Date,
        reports: [ProviderConnectorReport],
        promptCacheObservations: [PromptCacheObservation] = []
    ) {
        self.generatedAt = generatedAt
        self.reports = reports
        self.promptCacheObservations = promptCacheObservations
    }

    public var snapshot: UsageSnapshot {
        UsageSnapshot(generatedAt: generatedAt, limits: reports.flatMap(\.limits))
    }
}

public protocol ProviderConnector: Sendable {
    var provider: Provider { get }

    func refresh(now: Date) async -> ConnectorRefreshResult
}

public struct FailingProviderConnector: ProviderConnector {
    public let provider: Provider
    private let accountID: String
    private let accountName: String
    private let message: String

    public init(provider: Provider, accountID: String, accountName: String, message: String) {
        self.provider = provider
        self.accountID = accountID
        self.accountName = accountName
        self.message = message
    }

    public func refresh(now: Date) async -> ConnectorRefreshResult {
        ConnectorRefreshResult(generatedAt: now, reports: [
            ProviderConnectorReport(
                provider: provider,
                accountID: accountID,
                accountName: accountName,
                generatedAt: now,
                limits: [],
                status: .failure,
                errorMessage: message
            ),
        ])
    }
}

public struct ProviderConnectorRuntime: Sendable {
    private let connectors: [any ProviderConnector]

    public init(connectors: [any ProviderConnector]) {
        self.connectors = connectors
    }

    public func refreshAll(now: Date = Date()) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        var promptCacheObservations: [PromptCacheObservation] = []
        for connector in connectors {
            let result = await connector.refresh(now: now)
            reports.append(contentsOf: result.reports)
            promptCacheObservations.append(contentsOf: result.promptCacheObservations)
        }
        return ConnectorRefreshResult(
            generatedAt: now,
            reports: Self.deduplicatedReports(reports),
            promptCacheObservations: Self.deduplicatedPromptCacheObservations(promptCacheObservations)
        )
    }

    private static func deduplicatedReports(_ reports: [ProviderConnectorReport]) -> [ProviderConnectorReport] {
        var indexesByAccount: [ConnectorProviderAccountKey: Int] = [:]
        var deduplicated: [ProviderConnectorReport] = []
        deduplicated.reserveCapacity(reports.count)

        for report in reports {
            let key = ConnectorProviderAccountKey(provider: report.provider, accountID: report.accountID)
            if let existingIndex = indexesByAccount[key] {
                let existing = deduplicated[existingIndex]
                let configuredAccountID = existing.configuredAccountID ?? report.configuredAccountID
                if existing.limits.isEmpty, !report.limits.isEmpty {
                    deduplicated[existingIndex] = report.replacingMissingConfiguredAccountID(
                        with: configuredAccountID,
                        accountName: mergedAccountName(existing: existing, report: report, prefersReportOnTie: true)
                    )
                } else if existing.configuredAccountID == nil || existing.limits.contains(where: { $0.configuredAccountID == nil }) {
                    deduplicated[existingIndex] = existing.replacingMissingConfiguredAccountID(
                        with: configuredAccountID,
                        accountName: mergedAccountName(
                            existing: existing,
                            report: report,
                            prefersReportOnTie: existing.limits.isEmpty
                        )
                    )
                }
            } else {
                indexesByAccount[key] = deduplicated.count
                deduplicated.append(report)
            }
        }

        return deduplicated
    }

    private static func deduplicatedPromptCacheObservations(
        _ observations: [PromptCacheObservation]
    ) -> [PromptCacheObservation] {
        var seen = Set<String>()
        return observations.filter { observation in
            seen.insert(observation.id).inserted
        }
    }

    private static func mergedAccountName(
        existing: ProviderConnectorReport,
        report: ProviderConnectorReport,
        prefersReportOnTie: Bool = false
    ) -> String? {
        guard existing.accountName.caseInsensitiveCompare(report.accountName) != .orderedSame else { return nil }
        let reportSpecificity = accountNameSpecificity(report.accountName)
        let existingSpecificity = accountNameSpecificity(existing.accountName)
        if reportSpecificity > existingSpecificity || (prefersReportOnTie && reportSpecificity == existingSpecificity) {
            return report.accountName
        }
        if existingSpecificity > reportSpecificity {
            return existing.accountName
        }
        return nil
    }

    private static func accountNameSpecificity(_ accountName: String) -> Int {
        var score = accountName.isEmpty ? 0 : 1
        if accountName.contains("@") { score += 2 }
        if accountName.contains(" · ") { score += 1 }
        return score
    }
}

private extension ProviderConnectorReport {
    func replacingMissingConfiguredAccountID(with fallback: String?, accountName replacementAccountName: String? = nil) -> ProviderConnectorReport {
        guard let fallback else { return self }
        return ProviderConnectorReport(
            provider: provider,
            accountID: accountID,
            configuredAccountID: fallback,
            accountName: replacementAccountName ?? accountName,
            generatedAt: generatedAt,
            limits: limits.map { $0.replacingMissingConfiguredAccountID(with: fallback, accountName: replacementAccountName) },
            status: status,
            errorMessage: errorMessage
        )
    }
}

private extension UsageLimit {
    func replacingMissingConfiguredAccountID(with fallback: String, accountName replacementAccountName: String? = nil) -> UsageLimit {
        guard configuredAccountID != fallback || replacementAccountName != nil else { return self }
        return UsageLimit(
            id: id,
            provider: provider,
            accountID: accountID,
            configuredAccountID: fallback,
            accountName: replacementAccountName ?? accountName,
            label: label,
            windowLabel: windowLabel,
            modelLabel: modelLabel,
            unit: unit,
            used: used,
            limit: limit,
            resetsAt: resetsAt,
            lastUpdatedAt: lastUpdatedAt,
            confidence: confidence,
            statusOverride: statusOverride,
            note: note
        )
    }
}

private struct ConnectorProviderAccountKey: Hashable {
    let provider: Provider
    let accountID: String
}

public struct ConnectorHTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?

    public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct ConnectorHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data

    public init(statusCode: Int, data: Data) {
        self.statusCode = statusCode
        self.data = data
    }
}

public protocol ConnectorHTTPClient: Sendable {
    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse
}

public struct URLSessionConnectorHTTPClient: ConnectorHTTPClient {
    public init() {}

    public func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.nonHTTPResponse("provider request returned a non-HTTP response")
        }
        return ConnectorHTTPResponse(statusCode: http.statusCode, data: data)
    }
}

public enum ConnectorRedactor {
    public static func redact(_ value: String) -> String {
        EvidenceRedactor.redact(value)
    }

    public static func redactedPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let home = ContextPanelLocations.realUserHomeDirectory().path
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return URL(fileURLWithPath: expanded).lastPathComponent
    }

    public static func localAccountID(provider: Provider, path: String) -> String {
        "\(provider.rawValue)-\(fnv1a(path))"
    }

    public static func localAccountID(provider: Provider, stableID: String) -> String {
        "\(provider.rawValue)-\(fnv1a(stableID))"
    }

    private static func fnv1a(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
