import Foundation
import Testing

@testable import ContextPanelCore

@Test func geminiQuotaPayloadParserNormalizesBucketsAsPercentPressure() throws {
    let json = #"""
    {
      "buckets": [
        {
          "modelId": "gemini-3-flash-preview",
          "remainingFraction": 0.965,
          "resetTime": "2026-05-06T16:04:50Z"
        },
        {
          "modelId": "gemini-3.1-pro-preview",
          "remainingFraction": 1,
          "remainingAmount": 12,
          "resetTime": "2026-05-07T14:19:35Z"
        }
      ]
    }
    """#

    let buckets = try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))

    #expect(buckets.count == 2)
    #expect(buckets[0].modelID == "gemini-3-flash-preview")
    #expect(buckets[0].remainingFraction == 0.965)
    #expect(abs((buckets[0].usedPercent ?? 0) - 3.5) < 0.0001)
    #expect(ContextPanelDateFormatting.string(from: buckets[0].resetsAt!) == "2026-05-06T16:04:50Z")
    #expect(buckets[1].remainingAmount == 12)

    let limit = buckets[0].usageLimit(accountID: "local", accountName: "Gemini CLI", observedAt: Date(timeIntervalSince1970: 0))
    #expect(limit.provider == .google)
    #expect(limit.unit == .percent)
    #expect(limit.used == 4)
    #expect(limit.limit == 100)
    #expect(limit.confidence == .observed)
}

@Test func geminiQuotaPayloadParserPreservesMultipleWindowsAndBucketLabels() throws {
    let json = #"""
    {
      "quotaBuckets": [
        {
          "modelId": "gemini-3-pro",
          "bucketLabel": "Gemini Apps compute 5-hour",
          "remainingFraction": 0.6,
          "resetTime": "2026-05-22T18:00:00Z"
        },
        {
          "modelId": "gemini-3-pro",
          "bucketLabel": "Gemini Apps compute weekly",
          "remainingFraction": 0.2,
          "resetTime": "2026-05-29T13:00:00Z"
        },
        {
          "modelId": "gemini-3-flash",
          "bucketLabel": "experimental-compute-pool",
          "usagePercent": 12,
          "resetTime": "2026-05-23T13:00:00Z"
        }
      ]
    }
    """#

    let buckets = try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))
    let observedAt = ContextPanelDateFormatting.date(from: "2026-05-22T13:00:00Z")!
    let limits = buckets.map {
        $0.usageLimit(accountID: "local", accountName: "Gemini", observedAt: observedAt)
    }

    #expect(limits.count == 3)
    #expect(Set(limits.map(\.id)).count == 3)
    #expect(limits.map(\.label) == [
        "Gemini Apps compute 5-hour",
        "Gemini Apps compute weekly",
        "experimental-compute-pool",
    ])
    #expect(limits.map(\.windowLabel) == ["5-hour", "Weekly", "Daily"])
    #expect(limits.map(\.modelLabel) == ["gemini-3-pro", "gemini-3-pro", "gemini-3-flash"])
    #expect(limits.map(\.used) == [40, 80, 12])
}

@Test func geminiQuotaPayloadParserMarksExhaustedAmountBucketsAsLimited() throws {
    let json = #"""
    {
      "quotaBuckets": [
        {
          "modelId": "Gemini 3.5 Flash (Medium)",
          "bucketLabel": "Antigravity daily agent execution",
          "remainingAmount": 0,
          "totalAmount": 100,
          "resetWindow": "daily",
          "resetTime": "2026-06-06T12:10:00Z"
        }
      ]
    }
    """#

    let bucket = try #require(GeminiQuotaPayloadParser.buckets(from: Data(json.utf8)).first)
    let limit = bucket.usageLimit(
        accountID: "local",
        accountName: "Antigravity",
        observedAt: ContextPanelDateFormatting.date(from: "2026-06-05T14:00:00Z")!
    )

    #expect(bucket.remainingAmount == 0)
    #expect(bucket.totalAmount == 100)
    #expect(bucket.usedPercent == 100)
    #expect(limit.used == 100)
    #expect(limit.limit == 100)
    #expect(limit.status == .limited)
    #expect(limit.windowLabel == "Daily")
    #expect(limit.note?.contains("remaining amount: 0") == true)
}

@Test func geminiQuotaPayloadParserLetsAmountTotalsOverrideHealthyFraction() throws {
    let json = #"""
    {
      "quotaBuckets": [
        {
          "modelId": "Gemini 3.5 Flash (Medium)",
          "bucketLabel": "Antigravity daily agent execution",
          "remainingFraction": 1,
          "remainingAmount": 0,
          "totalAmount": 100,
          "resetWindow": "daily"
        }
      ]
    }
    """#

    let bucket = try #require(GeminiQuotaPayloadParser.buckets(from: Data(json.utf8)).first)
    let limit = bucket.usageLimit(
        accountID: "local",
        accountName: "Antigravity",
        observedAt: ContextPanelDateFormatting.date(from: "2026-06-05T14:00:00Z")!
    )

    #expect(bucket.usedPercent == 100)
    #expect(limit.used == 100)
    #expect(limit.status == .limited)
}

@Test func geminiQuotaPayloadParserLetsExplicitExhaustionOverrideHealthyFraction() throws {
    let json = #"""
    {
      "limits": [
        {
          "model": "Gemini 3.5 Flash (Medium)",
          "label": "Antigravity agent execution",
          "remainingFraction": 1,
          "exhausted": true,
          "period": "daily"
        }
      ]
    }
    """#

    let bucket = try #require(GeminiQuotaPayloadParser.buckets(from: Data(json.utf8)).first)
    let limit = bucket.usageLimit(
        accountID: "local",
        accountName: "Antigravity",
        observedAt: ContextPanelDateFormatting.date(from: "2026-06-05T14:00:00Z")!
    )

    #expect(bucket.isExhausted)
    #expect(bucket.usedPercent == 100)
    #expect(limit.used == 100)
    #expect(limit.status == .limited)
    #expect(limit.note?.contains("Antigravity reported quota exhausted") == true)
}

@Test func geminiQuotaPayloadParserDoesNotInventPercentFromBareRemainingAmount() throws {
    let json = #"""
    {
      "buckets": [
        {
          "modelId": "gemini-3-pro",
          "remainingAmount": 12,
          "resetWindow": "daily"
        }
      ]
    }
    """#

    let bucket = try #require(GeminiQuotaPayloadParser.buckets(from: Data(json.utf8)).first)
    let limit = bucket.usageLimit(
        accountID: "local",
        accountName: "Gemini",
        observedAt: ContextPanelDateFormatting.date(from: "2026-06-05T14:00:00Z")!
    )

    #expect(bucket.remainingAmount == 12)
    #expect(bucket.usedPercent == nil)
    #expect(limit.used == nil)
    #expect(limit.limit == nil)
    #expect(limit.status == .unknown)
}

@Test func geminiQuotaPayloadParserReportsMissingBuckets() throws {
    let json = #"{"notBuckets": true}"#

    #expect(throws: ConnectorError.self) {
        try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))
    }
}

@Test func antigravityCredentialDecoderReadsGoKeyringPayload() throws {
    let payload = #"{"auth_method":"consumer","token":{"access_token":"access-secret","refresh_token":"refresh-secret","token_type":"Bearer","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let stored = "go-keyring-base64:\(Data(payload.utf8).base64EncodedString())"

    let credentials = try AntigravityCredentialDecoder().geminiOAuthCredentials(from: Data(stored.utf8))

    #expect(credentials.accessToken == "access-secret")
    #expect(credentials.refreshToken == "refresh-secret")
    #expect(ContextPanelDateFormatting.string(from: try #require(credentials.expiresAt)) == "2099-05-22T17:00:00Z")
}

@Test func antigravityCredentialDecoderReadsGoKeyringPayloadWithTrailingWhitespace() throws {
    let payload = #"{"auth_method":"consumer","token":{"access_token":"access-secret","refresh_token":"refresh-secret","token_type":"Bearer","expiry":"2099-05-22T17:00:00.000000000Z"}}"#
    let stored = "go-keyring-base64:\(Data(payload.utf8).base64EncodedString())\n"

    let credentials = try AntigravityCredentialDecoder().geminiOAuthCredentials(from: Data(stored.utf8))

    #expect(credentials.accessToken == "access-secret")
    #expect(credentials.refreshToken == "refresh-secret")
}

@Test func antigravityCredentialSourceLoadsGeminiCredentialsFromKeychainPayload() throws {
    let payload = #"{"auth_method":"consumer","token":{"refresh_token":"refresh-secret"}}"#
    let stored = "go-keyring-base64:\(Data(payload.utf8).base64EncodedString())"
    let source = AntigravityKeychainCredentialSource(
        credentialLoader: InMemoryProviderCredentialStore(storage: [
            AntigravityKeychainCredentialSource.accountID: Data(stored.utf8),
        ])
    )

    let credentials = try source.loadCredentials()

    #expect(credentials?.refreshToken == "refresh-secret")
}

@Test func geminiOAuthCredentialDecoderAcceptsStringExpiryInLocalCredentials() throws {
    let payload = #"{"access_token":"access-secret","refresh_token":"refresh-secret","expiry":"2099-05-22T17:00:00.000000000Z"}"#

    let credentials = try GeminiOAuthCredentialDecoder.credentials(from: Data(payload.utf8))

    #expect(credentials.accessToken == "access-secret")
    #expect(credentials.refreshToken == "refresh-secret")
    #expect(ContextPanelDateFormatting.string(from: try #require(credentials.expiresAt)) == "2099-05-22T17:00:00Z")
}

@Test func geminiConnectorSurfacesQuotaShapeDiagnostics() async throws {
    let credentials = #"{"refresh_token":"refresh-secret"}"#.data(using: .utf8)!
    let refresh = #"{"access_token":"access-secret"}"#.data(using: .utf8)!
    let load = #"{"cloudaicompanionProject":"project-secret"}"#.data(using: .utf8)!
    let quota = #"{"buckets":[{"modelId":"gemini-3-pro"}]}"#.data(using: .utf8)!
    let http = GeminiQuotaStubHTTPClient(responses: [
        ConnectorHTTPResponse(statusCode: 200, data: refresh),
        ConnectorHTTPResponse(statusCode: 200, data: load),
        ConnectorHTTPResponse(statusCode: 200, data: quota),
    ])
    let connector = GeminiCodeAssistConnector(
        accounts: [GeminiAccountConfiguration(authPath: "/tmp/gemini.json", accountName: "Gemini", clientID: "client", clientSecret: "secret")],
        httpClient: http,
        fileLoader: { _ in credentials },
        antigravityCredentialSource: nil
    )

    let result = await connector.refresh(now: Date(timeIntervalSince1970: 0))

    #expect(result.reports.count == 1)
    #expect(result.reports[0].status == UsageStatus.failure)
    #expect(result.reports[0].errorMessage?.contains("Gemini Code Assist quota payload shape changed") == true)
    #expect(result.reports[0].errorMessage?.contains("raw body redacted") == true)
    #expect(result.snapshot.limits.isEmpty)
}

private final class GeminiQuotaStubHTTPClient: ConnectorHTTPClient, @unchecked Sendable {
    private var responses: [ConnectorHTTPResponse]

    init(responses: [ConnectorHTTPResponse]) {
        self.responses = responses
    }

    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        guard !responses.isEmpty else {
            throw ConnectorError.nonHTTPResponse("missing stub response")
        }
        return responses.removeFirst()
    }
}

@Test func geminiOAuthClientMetadataDiscoveryParsesInstalledCLIBundleShape() {
    let source = #"""
    const OAUTH_CLIENT_ID = 'client-id.apps.googleusercontent.com';
    let OAUTH_CLIENT_SECRET = 'client-secret';
    """#

    let metadata = GeminiOAuthClientMetadataDiscovery.parseClientMetadata(from: source)

    #expect(metadata?.clientID == "client-id.apps.googleusercontent.com")
    #expect(metadata?.clientSecret == "client-secret")
}

@Test func geminiOAuthClientMetadataDiscoveryPrefersEnvironmentValues() {
    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: [
            "GEMINI_OAUTH_CLIENT_ID": "env-client",
            "GEMINI_OAUTH_CLIENT_SECRET": "env-secret",
        ],
        fileLoader: { _ in "" },
        fileExists: { _ in false },
        directoryLister: { _ in [] }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "env-client", clientSecret: "env-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryScansInstalledBundleDirectory() {
    let source = #"""
    var OAUTH_CLIENT_ID = "bundle-client";
    var OAUTH_CLIENT_SECRET = "bundle-secret";
    """#

    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: [:],
        fileLoader: { path in
            path.hasSuffix("chunk-with-oauth.js") ? source : ""
        },
        fileExists: { _ in true },
        directoryLister: { root in
            root == "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle"
                ? ["\(root)/chunk-with-oauth.js"]
                : []
        }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "bundle-client", clientSecret: "bundle-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryScansCommandPathBundleDirectory() {
    let source = #"""
    var OAUTH_CLIENT_ID = "command-client";
    var OAUTH_CLIENT_SECRET = "command-secret";
    """#

    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: [:],
        commandPath: "/Users/test/.local/share/npm/bin/gemini.js",
        fileLoader: { path in
            path.hasSuffix("oauth-chunk.js") ? source : ""
        },
        fileExists: { path in
            path == "/Users/test/.local/share/npm/bin/gemini.js"
                || path == "/Users/test/.local/share/npm/bin/oauth-chunk.js"
        },
        directoryLister: { root in
            root == "/Users/test/.local/share/npm/bin"
                ? ["\(root)/oauth-chunk.js"]
                : []
        }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "command-client", clientSecret: "command-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryScansGeminiExecutableFromPATH() {
    let source = #"""
    var OAUTH_CLIENT_ID = "path-client";
    var OAUTH_CLIENT_SECRET = "path-secret";
    """#

    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: ["PATH": "/Users/test/.npm-global/bin:/usr/bin"],
        fileLoader: { path in
            path.hasSuffix("chunk.js") ? source : ""
        },
        fileExists: { path in
            path == "/Users/test/.npm-global/bin/gemini"
                || path == "/Users/test/.npm-global/bin/chunk.js"
        },
        directoryLister: { root in
            root == "/Users/test/.npm-global/bin"
                ? ["\(root)/chunk.js"]
                : []
        }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "path-client", clientSecret: "path-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryScansCommonUserLocalExecutableDirectory() {
    let source = #"""
    var OAUTH_CLIENT_ID = "user-local-client";
    var OAUTH_CLIENT_SECRET = "user-local-secret";
    """#
    let home = ContextPanelLocations.realUserHomeDirectory().path
    let executable = "\(home)/.local/bin/gemini"
    let bundleRoot = "\(home)/.local/lib/node_modules/@google/gemini-cli/bundle"

    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: [:],
        fileLoader: { path in
            path.hasSuffix("chunk.js") ? source : ""
        },
        fileExists: { path in
            path == executable
                || path == "\(bundleRoot)/chunk.js"
        },
        directoryLister: { root in
            root == bundleRoot
                ? ["\(root)/chunk.js"]
                : []
        }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "user-local-client", clientSecret: "user-local-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryHonorsBundledFallbackFlag() {
    let source = #"""
    var OAUTH_CLIENT_ID = "bundled-client";
    var OAUTH_CLIENT_SECRET = "bundled-secret";
    """#

    let metadata = GeminiOAuthClientMetadataDiscovery.discover(
        environment: [:],
        useBundledFallback: false,
        fileLoader: { _ in source },
        fileExists: { path in
            path == "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle/chunk.js"
        },
        directoryLister: { root in
            root == "/opt/homebrew/lib/node_modules/@google/gemini-cli/bundle"
                ? ["\(root)/chunk.js"]
                : []
        }
    )

    #expect(metadata == nil)
}

@Test func geminiOAuthClientMetadataDiscoveryParsesUserSelectedBundleDirectory() throws {
    let source = #"""
    var OAUTH_CLIENT_ID = "selected-client";
    var OAUTH_CLIENT_SECRET = "selected-secret";
    """#

    let metadata = try GeminiOAuthClientMetadataDiscovery.discover(
        fromUserSelectedURL: URL(fileURLWithPath: "/Users/test/gemini-cli/bundle", isDirectory: true),
        fileLoader: { path in
            path.hasSuffix("metadata.js") ? source : ""
        },
        directoryLister: { root in
            root == "/Users/test/gemini-cli/bundle" ? ["\(root)/metadata.js"] : []
        }
    )

    #expect(metadata == GeminiOAuthClientMetadata(clientID: "selected-client", clientSecret: "selected-secret"))
}

@Test func geminiOAuthClientMetadataDiscoveryReportsMissingUserSelectedMetadata() {
    #expect(throws: GeminiOAuthClientMetadataDiscoveryError.notFound) {
        try GeminiOAuthClientMetadataDiscovery.discover(
            fromUserSelectedURL: URL(fileURLWithPath: "/Users/test/gemini-cli/bundle", isDirectory: true),
            fileLoader: { _ in "" },
            directoryLister: { _ in [] }
        )
    }
}
