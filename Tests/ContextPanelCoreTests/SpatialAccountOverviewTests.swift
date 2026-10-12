import AppKit
import ContextPanelCore
import ContextPanelSettingsUI
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import SwiftUI
import Testing

@Test func spatialOverviewKeepsCardsWideWhenOnlyTheLedgerNeedsToStack() {
    let intermediateWidth = AccountDashboardPanel.minimumTableWidth - 1
    #expect(SpatialAccountOverviewLayout.usesCompactAccounts(contentWidth: intermediateWidth, accessibility: false))
    #expect(!SpatialAccountOverviewLayout.usesCompactCards(contentWidth: intermediateWidth, accessibility: false))
    #expect(!SpatialAccountOverviewLayout.usesCompactAccounts(contentWidth: AccountDashboardPanel.minimumTableWidth, accessibility: false))
    #expect(SpatialAccountOverviewLayout.usesCompactCards(contentWidth: 492, accessibility: false))
    for width in [CGFloat.nan, -.infinity, .infinity, -1] {
        #expect(SpatialAccountOverviewLayout.usesCompactAccounts(contentWidth: width, accessibility: false))
        #expect(SpatialAccountOverviewLayout.usesCompactCards(contentWidth: width, accessibility: false))
    }
    #expect(SpatialAccountOverviewLayout.usesCompactAccounts(contentWidth: 1080, accessibility: true))
    #expect(SpatialAccountOverviewLayout.usesCompactCards(contentWidth: 1080, accessibility: true))
}

@MainActor
@Test func spatialOverviewReflowsDenseAccountsInsteadOfClippingTheirLedger() throws {
    let now = ValidationFixtureCatalog.referencePresentationDate
    let snapshot = ValidationGalleryFixtureAdapter().snapshot(
        fixture: ValidationFixtureCatalog.fixture(id: .denseAccounts), presentationDate: now)
    func render(width: CGFloat) throws -> CGImage {
        let renderer = ImageRenderer(content: SpatialAccountOverviewPanel(
            overview: snapshot.accountOverview(now: now, maximumAge: SnapshotFreshness.companionProviderMaximumAge),
            now: now, contentWidth: width,
            openAccount: { _ in }, openDeadlines: {})
            .frame(width: width).environment(\.colorScheme, .light))
        return try #require(renderer.cgImage)
    }
    let wide = try render(width: 1080)
    let medium = try render(width: 762)
    let narrow = try render(width: 492)
    #expect(medium.height > wide.height)
    #expect(narrow.height > medium.height)
    // macOS has no UIKit Dynamic Type metrics. Test the shared opt-in typography here;
    // the visionOS capture verifies the platform's actual scaling.
    func scaledHeight(_ scale: CGFloat) throws -> Int {
        let renderer = ImageRenderer(content: AccountDashboardPanel(
            overview: snapshot.accountOverview(now: now), now: now, compact: true, textScale: scale,
            openAccount: { _ in }, openDeadlines: {}).frame(width: 492))
        return try #require(renderer.cgImage).height
    }
    #expect(try scaledHeight(2) > scaledHeight(1) + 200)
}
