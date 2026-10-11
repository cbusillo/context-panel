import AppKit
import ContextPanelCompanionSupport
import ContextPanelCore
import ContextPanelSettingsUI
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import SwiftUI
import Testing

@Test func spatialOverviewKeepsCardsWideWhenOnlyTheLedgerNeedsToStack() {
    let intermediateWidth = AccountDashboardPanel.minimumTableWidth - 1
    #expect(SpatialAccountOverviewPanel.usesCompactAccounts(contentWidth: intermediateWidth, accessibility: false))
    #expect(!SpatialAccountOverviewPanel.usesCompactCards(contentWidth: intermediateWidth, accessibility: false))
    #expect(!SpatialAccountOverviewPanel.usesCompactAccounts(contentWidth: AccountDashboardPanel.minimumTableWidth, accessibility: false))
    #expect(SpatialAccountOverviewPanel.usesCompactCards(contentWidth: 492, accessibility: false))
    for width in [CGFloat.nan, -.infinity, .infinity, -1] {
        #expect(SpatialAccountOverviewPanel.usesCompactAccounts(contentWidth: width, accessibility: false))
        #expect(SpatialAccountOverviewPanel.usesCompactCards(contentWidth: width, accessibility: false))
    }
    #expect(SpatialAccountOverviewPanel.usesCompactAccounts(contentWidth: 1080, accessibility: true))
    #expect(SpatialAccountOverviewPanel.usesCompactCards(contentWidth: 1080, accessibility: true))
}

@MainActor
@Test func spatialOverviewReflowsDenseAccountsInsteadOfClippingTheirLedger() throws {
    let now = ValidationFixtureCatalog.referencePresentationDate
    let snapshot = ValidationGalleryFixtureAdapter().snapshot(
        fixture: ValidationFixtureCatalog.fixture(id: .denseAccounts), presentationDate: now)
    let presentation = CompanionSyncPresentation(result: CompanionSyncLoadResult(document: nil, status: snapshot.status))
    func render(width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: SpatialAccountOverviewPanel(
            overview: snapshot.accountOverview(now: now, maximumAge: SnapshotFreshness.companionProviderMaximumAge),
            now: now, contentWidth: width,
            syncTitle: presentation.title, syncDetail: presentation.detail, syncSymbol: presentation.symbol,
            lastSyncedAt: now, openAccount: { _ in }, openDeadlines: {})
            .frame(width: width).environment(\.colorScheme, .light))
        return try #require(renderer.cgImage)
    }
    let wide = try render(width: 1080)
    let medium = try render(width: 762)
    let narrow = try render(width: 492)
    #expect(medium.height > wide.height)
    #expect(narrow.height > medium.height)
    #expect(narrow.width < medium.width && medium.width < wide.width)
}
