import Foundation
import Testing

@testable import ContextPanelCore
@testable import ContextPanelCompanionSupport

private let signatureNow = Date(timeIntervalSince1970: 1_900_000_000)

private func signatureResult(label: String) -> CompanionSyncLoadResult {
    // The provider reports the login email as the account name; Settings carries the typed label.
    let setup = LocalProviderAccountConfiguration(id: "setup", provider: .openAI, connectorKind: .codexRateLimits,
        displayName: label, authPath: "/synthetic/auth.json")
    let stored = StoredUsageSnapshot(savedAt: signatureNow,
        snapshot: UsageSnapshot(generatedAt: signatureNow, limits: [UsageLimit(provider: .openAI, accountID: "setup",
            configuredAccountID: "setup", accountName: "login@example.invalid", label: "Weekly", unit: .percent,
            used: 20, limit: 100, resetsAt: signatureNow.addingTimeInterval(3600), lastUpdatedAt: signatureNow)]),
        reports: [StoredProviderReport(provider: .openAI, accountID: "setup", configuredAccountID: "setup",
            accountName: "login@example.invalid", generatedAt: signatureNow, status: .healthy, errorMessage: nil)])
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: signatureNow,
        accountDisplayMetadata: AccountDisplayMetadata.companion(configuration: [setup], stored: stored, now: signatureNow),
        accountBurnRates: ["burn-account": ["weekly": ObservedBurnRate(limitID: "weekly", unitsPerHour: 2,
            observedDurationHours: 3, sampleCount: 4)]])
    return CompanionSyncLoadResult(document: document, status: .healthy)
}

@Test func companionAppShowsTheSyncedSnapshotWithItsTypedAccountNames() {
    let result = signatureResult(label: "typed@example.invalid")
    let signature = CompanionWidgetRenderSignature(result: result, displayPreferences: .defaultPreferences, now: signatureNow)
    let synced = WidgetSnapshot.fromCompanionSync(result, now: signatureNow, stalenessPolicy: SnapshotStoreStalenessPolicy
        .appDefault(maximumAge: SnapshotFreshness.companionProviderMaximumAge))
    #expect(signature.snapshot == synced)
    #expect(signature.snapshot.accountOverview(now: signatureNow).accounts.map(\.metadata.label) == ["typed@example.invalid"])
}

@Test func renamingAnAccountOnTheMacReloadsCompanionWidgets() {
    let before = CompanionWidgetRenderSignature(result: signatureResult(label: "First name"),
        displayPreferences: .defaultPreferences, now: signatureNow)
    let after = CompanionWidgetRenderSignature(result: signatureResult(label: "Second name"),
        displayPreferences: .defaultPreferences, now: signatureNow)
    #expect(before != after)
    #expect(before == CompanionWidgetRenderSignature(result: signatureResult(label: "First name"),
        displayPreferences: .defaultPreferences, now: signatureNow))
}

@Test func missingDocumentLoadsAtDifferentTimesDoNotReloadCompanionWidgets() {
    let missing = CompanionSyncLoadResult(document: nil, status: .unknown)
    #expect(CompanionWidgetRenderSignature(result: missing, displayPreferences: .defaultPreferences, now: signatureNow)
        == CompanionWidgetRenderSignature(result: missing, displayPreferences: .defaultPreferences,
            now: signatureNow.addingTimeInterval(60)))
}
