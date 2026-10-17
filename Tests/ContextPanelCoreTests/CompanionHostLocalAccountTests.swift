import Foundation
import Testing

@testable import ContextPanelCore

private let hostLocalIdentityKey = ProviderAccountIdentityKey(keyID: UUID(), secret: Data(repeating: 29, count: 32))!

@Test func companionsDoNotShowPreIdentityMembershipsOnceTheProviderIsVerified() {
    let now = Date(timeIntervalSince1970: 2_000_000)
    let document = hostLocalDocument(now: now, accounts: [
        hostLocalAccount("Current", provider: .openAI, id: "openai-current", identity: .verified),
        hostLocalAccount("Codex Lab", provider: .openAI, id: "openai-lab", identity: .unverified),
        hostLocalAccount("person@example.invalid", provider: .openAI, id: "openai-old-login", identity: .unverified),
        hostLocalAccount("Waiting", provider: .openAI, id: "openai-waiting", identity: .waitingForSharedKey),
        hostLocalAccount("Gemini", provider: .google, id: "google-gemini", identity: .notExposedByConnector),
    ])

    let names = hostLocalPresentedNames(document, now: now)

    #expect(names == ["Current", "Gemini", "Waiting"])
}

@Test func companionsKeepUnverifiedAccountsWhenTheProviderHasNoVerifiedAccount() {
    let now = Date(timeIntervalSince1970: 2_100_000)
    let document = hostLocalDocument(now: now, accounts: [
        hostLocalAccount("Older Mac A", provider: .openAI, id: "openai-a", identity: .unverified),
        hostLocalAccount("Older Mac B", provider: .openAI, id: "openai-b", identity: .unverified),
    ])

    #expect(hostLocalPresentedNames(document, now: now) == ["Older Mac A", "Older Mac B"])
}

@Test func aConfiguredAccountWhoseAuthCannotBeReadStaysVisibleBesideAVerifiedSibling() async throws {
    let now = Date(timeIntervalSince1970: 2_400_000)
    let missing = LocalProviderAccountConfiguration(id: "missing-login", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Missing login", authPath: "/synthetic/missing/auth.json")
    let connector = CodexRateLimitConnector(
        accounts: [CodexAccountConfiguration(configuredAccountID: missing.id, authPath: "/synthetic/missing/auth.json",
                                             accountName: "Missing login")],
        httpClient: HostLocalNoNetwork(), identityResolver: ProviderAccountIdentityResolver { _ in nil },
        fileLoader: { _ in throw CocoaError(.fileReadNoSuchFile) })
    // The real unreadable-auth failure report carries no identity status, like a pre-identity reading.
    let failed = await connector.refresh(now: now).reports.map(StoredProviderReport.init(report:))
    let current = LocalProviderAccountConfiguration(id: "current-login", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: "Current", authPath: "/synthetic/current/auth.json")
    let identity = ProviderAccountIdentityMaterial(provider: .openAI, kind: .chatGPTAccountID, identifier: "current")
        .map { hostLocalIdentityKey.identity(for: $0).bound(toLocalAccountID: "openai-current") }
    let limit = UsageLimit(provider: .openAI, accountID: "openai-current", configuredAccountID: current.id,
        accountName: "Current", label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 20, limit: 100, lastUpdatedAt: now)
    let verified = StoredProviderReport(provider: .openAI, accountID: "openai-current", configuredAccountID: current.id,
        accountName: "Current", generatedAt: now, status: .healthy, errorMessage: nil, sharedAccountIdentity: identity)
    let stored = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: [limit]),
                                     reports: [verified] + failed)

    let presented = MacSharedAccountPresentation.make(stored: stored, configuration: [current, missing], now: now)
        .accountOverview(now: now).accounts.map(\.metadata.label).sorted()

    #expect(presented == ["Current", "Missing login"])
}

private struct HostLocalNoNetwork: ConnectorHTTPClient {
    func data(for request: ConnectorHTTPRequest) async throws -> ConnectorHTTPResponse {
        throw URLError(.notConnectedToInternet)
    }
}

private struct HostLocalAccount {
    let name: String
    let provider: Provider
    let id: String
    let identity: ProviderAccountIdentityStatus
}

private func hostLocalAccount(_ name: String, provider: Provider, id: String,
                              identity: ProviderAccountIdentityStatus) -> HostLocalAccount {
    HostLocalAccount(name: name, provider: provider, id: id, identity: identity)
}

private func hostLocalDocument(now: Date, accounts: [HostLocalAccount]) -> CompanionSyncDocument {
    let limits = accounts.map { account in
        UsageLimit(provider: account.provider, accountID: account.id, configuredAccountID: account.id,
                   accountName: account.name, label: "Weekly", windowLabel: "Weekly", unit: .percent,
                   used: 20, limit: 100, lastUpdatedAt: now)
    }
    let reports = accounts.map { account in
        StoredProviderReport(provider: account.provider, accountID: account.id, configuredAccountID: account.id,
            accountName: account.name, generatedAt: now, status: .healthy, errorMessage: nil,
            sharedAccountIdentity: account.identity == .verified
                ? ProviderAccountIdentityMaterial(provider: account.provider, kind: .chatGPTAccountID, identifier: account.id)
                    .map { hostLocalIdentityKey.identity(for: $0).bound(toLocalAccountID: account.id) } : nil,
            accountIdentityStatus: account.identity)
    }
    let stored = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: now, limits: limits), reports: reports)
    return CompanionSyncDocument(snapshot: CompanionSnapshot(storedSnapshot: stored, publishedAt: now))
}

private func hostLocalPresentedNames(_ document: CompanionSyncDocument, now: Date) -> [String] {
    WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: document, status: .healthy), now: now)
        .accountOverview(now: now).accounts.map(\.metadata.label).sorted()
}
