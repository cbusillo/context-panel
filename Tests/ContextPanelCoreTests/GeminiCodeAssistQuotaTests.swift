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

@Test func geminiQuotaPayloadParserHandlesMissingBuckets() throws {
    let json = #"{"notBuckets": true}"#

    let buckets = try GeminiQuotaPayloadParser.buckets(from: Data(json.utf8))

    #expect(buckets.isEmpty)
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
