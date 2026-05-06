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
            message
        case let .httpFailure(operation, statusCode):
            "\(operation) returned HTTP \(statusCode); raw body redacted"
        case let .processFailure(operation, exitCode):
            "\(operation) failed with exit code \(exitCode); stderr redacted"
        }
    }
}

public struct ProviderConnectorReport: Equatable, Sendable {
    public let provider: Provider
    public let accountID: String
    public let accountName: String
    public let generatedAt: Date
    public let limits: [UsageLimit]
    public let status: UsageStatus
    public let errorMessage: String?

    public init(
        provider: Provider,
        accountID: String,
        accountName: String,
        generatedAt: Date,
        limits: [UsageLimit],
        status: UsageStatus? = nil,
        errorMessage: String? = nil
    ) {
        self.provider = provider
        self.accountID = accountID
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

    public init(generatedAt: Date, reports: [ProviderConnectorReport]) {
        self.generatedAt = generatedAt
        self.reports = reports
    }

    public var snapshot: UsageSnapshot {
        UsageSnapshot(generatedAt: generatedAt, limits: reports.flatMap(\.limits))
    }
}

public protocol ProviderConnector: Sendable {
    var provider: Provider { get }

    func refresh(now: Date) async -> ConnectorRefreshResult
}

public struct ProviderConnectorRuntime: Sendable {
    private let connectors: [any ProviderConnector]

    public init(connectors: [any ProviderConnector]) {
        self.connectors = connectors
    }

    public func refreshAll(now: Date = Date()) async -> ConnectorRefreshResult {
        var reports: [ProviderConnectorReport] = []
        for connector in connectors {
            let result = await connector.refresh(now: now)
            reports.append(contentsOf: result.reports)
        }
        return ConnectorRefreshResult(generatedAt: now, reports: reports)
    }
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

public struct ConnectorProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data

    public init(exitCode: Int32, stdout: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
    }
}

public protocol ConnectorProcessClient: Sendable {
    func run(executable: String, arguments: [String]) throws -> ConnectorProcessResult
}

public struct DefaultConnectorProcessClient: ConnectorProcessClient {
    public init() {}

    public func run(executable: String, arguments: [String]) throws -> ConnectorProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        return ConnectorProcessResult(
            exitCode: process.terminationStatus,
            stdout: output.fileHandleForReading.readDataToEndOfFile()
        )
    }
}

public enum ConnectorRedactor {
    public static func redact(_ value: String) -> String {
        EvidenceRedactor.redact(value)
    }

    public static func redactedPath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if expanded.hasPrefix(home) {
            return "~" + expanded.dropFirst(home.count)
        }
        return URL(fileURLWithPath: expanded).lastPathComponent
    }

    public static func localAccountID(provider: Provider, path: String) -> String {
        "\(provider.rawValue)-\(fnv1a(path))"
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

