import ContextPanelCore
import ContextPanelTVSupport
import Foundation
import Testing

@Test func neverObservedCompanionSetupKeepsItsAccountWithoutClaimingSavedUsage() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let stored = StoredUsageSnapshot(savedAt: now, snapshot: UsageSnapshot(generatedAt: .distantPast, limits: []), reports: [])
    let metadata = AccountDisplayMetadata(id: "setup", configurationID: "setup", provider: .anthropic, label: "Synthetic", sourceConfigured: false, readState: .notConnected)
    let document = CompanionSyncDocument(snapshot: CompanionSnapshot(storedSnapshot: stored, publishedAt: now), accountDisplayMetadata: [metadata])
    let widget = WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: document, status: .healthy), now: now)
    #expect(widget.state == .setupNeeded)
    #expect(widget.refreshAttentionSummary == nil)
    let account = try #require(widget.accountOverview(now: now).accounts.first)
    #expect(account.state == .notConnected)
    #expect(account.remainingFraction == nil)
    let shelf = TVTopShelfDocument(snapshot: widget, mode: .fullDetail, now: now)
    #expect(!shelf.isStale(at: now))
    #expect(shelf.freshnessText(at: now) == AccountTerms.noCurrentReading)
    #expect(shelf.cards.first?.detail == account.stateText)
    #expect(shelf.cards.count == 1)
}
