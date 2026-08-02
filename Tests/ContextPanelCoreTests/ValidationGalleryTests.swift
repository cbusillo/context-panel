import AppKit
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import ContextPanelCore
@testable import ContextPanelValidationFixtures
@testable import ContextPanelValidationGalleryUI
@testable import ContextPanelWidgetUI

@Test func validationFixtureCatalogCoversEveryDeclaredStateOnce() {
    let fixtures = ValidationFixtureCatalog.all

    #expect(fixtures.map(\.id) == ValidationFixtureID.allCases)
    #expect(Set(fixtures.map(\.id)).count == fixtures.count)
    #expect(fixtures.count == 9)
}

@Test func validationFixturesUseOnlySyntheticAccountIdentity() {
    for fixture in ValidationFixtureCatalog.all {
        #expect(!fixture.title.contains("@"))
        #expect(!fixture.purpose.contains("@"))
        #expect(!fixture.message.contains("@"))
        #expect(fixture.syncErrorMessage?.contains("@") != true)

        for limit in fixture.limits {
            #expect(limit.accountID.hasPrefix("sample-"))
            #expect(limit.accountName.hasPrefix("Sample "))
            #expect(!limit.accountName.contains("@"))
            #expect(!limit.label.contains("@"))
            #expect(!limit.windowLabel.contains("@"))
            #expect(limit.modelLabel?.contains("@") != true)
        }
    }
}

@Test func validationGalleryRouteAcceptsOnlyAllowlistedValues() throws {
    let direct = try #require(URL(
        string: "contextpanel://validation-gallery?fixture=stale&family=systemLarge&appearance=dark"
    ))
    let directRoute = try #require(ValidationGalleryRoute(url: direct))
    #expect(directRoute.fixtureID == .stale)
    #expect(directRoute.family == .systemLarge)
    #expect(directRoute.appearance == .dark)

    let settings = try #require(URL(
        string: "contextpanelcompanion://settings/validation-gallery?fixture=healthy"
    ))
    #expect(ValidationGalleryRoute(url: settings) == ValidationGalleryRoute())

    let invalidURLs = [
        "file:///tmp/validation-gallery",
        "contextpanel://validation-gallery/extra",
        "contextpanel://validation-gallery?fixture=unknown",
        "contextpanel://validation-gallery?payload=private",
        "contextpanel://validation-gallery?fixture=healthy&fixture=stale",
        "contextpanel://validation-gallery#private",
    ]
    for rawURL in invalidURLs {
        let url = try #require(URL(string: rawURL))
        #expect(ValidationGalleryRoute(url: url) == nil)
    }
}

@Test func validationGalleryAdapterUsesInjectedPresentationDate() throws {
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate
    let snapshot = ValidationGalleryFixtureAdapter().snapshot(
        fixtureID: .resetVisible,
        presentationDate: presentationDate
    )
    let fiveHour = try #require(snapshot.limits.first {
        $0.provider == .openAI && $0.windowLabel == "5-hour"
    })
    let resetDate = try #require(fiveHour.resetsAt)

    #expect(snapshot.generatedAt == presentationDate.addingTimeInterval(-50))
    #expect(resetDate == presentationDate.addingTimeInterval(38 * 60))
    #expect(resetDate.widgetRelativeText(relativeTo: presentationDate) == "in 38m")
    #expect(fiveHour.widgetResetConfidenceText(presentationDate: presentationDate) == "38m")
}

@MainActor
@Test func validationGalleryRenderMatrixIsBoundedAndNonempty() throws {
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate
    let adapter = ValidationGalleryFixtureAdapter()
    let links = ContextPanelWidgetLinks(
        overview: URL(string: "contextpanel-validation://sample")!,
        reconnect: URL(string: "contextpanel-validation://sample")!,
        cacheStatsSettings: URL(string: "contextpanel-validation://sample")!,
        resetCreditInteraction: .none
    )
    let stateScenarios = ValidationFixtureID.allCases.map {
        ($0, ValidationGalleryFamily.systemMedium, CPWThemeVariant.light)
    }
    let familyScenarios: [(ValidationFixtureID, ValidationGalleryFamily, CPWThemeVariant)] = [
        (.healthy, .systemSmall, .dark),
        (.healthy, .systemLarge, .dark),
        (.fitFallback, .systemSmall, .light),
    ]

    for (fixtureID, family, theme) in stateScenarios + familyScenarios {
        let snapshot = adapter.snapshot(fixtureID: fixtureID, presentationDate: presentationDate)
        let content = ContextPanelWidgetContentView(
            family: family.widgetFamily,
            snapshot: snapshot,
            displayPreferences: adapter.displayPreferences,
            links: links,
            showsResetCreditSurfaces: true,
            presentationDate: presentationDate
        )
        .cpwThemeVariant(theme)
        .frame(width: family.width, height: family.height)
        .background(CPWTheme.surface(variant: theme))
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try #require(renderer.nsImage)

        #expect(image.size.width == family.width)
        #expect(image.size.height == family.height)
        #expect((image.tiffRepresentation?.count ?? 0) > 1_000)
    }
}

@MainActor
@Test func validationGalleryWholeSurfaceRenders() throws {
    let route = ValidationGalleryRoute(
        fixtureID: .resetVisible,
        family: .systemMedium,
        appearance: .light
    )
    let rendered = try renderGallery(route: route, width: 1_024, height: 768)

    #expect(rendered.bitmap.pixelsWide == 1_024)
    #expect(rendered.bitmap.pixelsHigh == 768)
    #expect(rendered.pngData.count > 20_000)

    if let outputPath = ProcessInfo.processInfo.environment["CONTEXT_PANEL_VALIDATION_GALLERY_PREVIEW_PATH"] {
        try rendered.pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

@MainActor
@Test func validationGalleryCompactSurfaceRenders() throws {
    let route = ValidationGalleryRoute(
        fixtureID: .fitFallback,
        family: .systemSmall,
        appearance: .dark
    )
    let rendered = try renderGallery(route: route, width: 390, height: 844)

    #expect(rendered.bitmap.pixelsWide == 390)
    #expect(rendered.bitmap.pixelsHigh == 844)
    #expect(rendered.pngData.count > 15_000)

    if let outputPath = ProcessInfo.processInfo.environment["CONTEXT_PANEL_VALIDATION_GALLERY_COMPACT_PREVIEW_PATH"] {
        try rendered.pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

@MainActor
private func renderGallery(
    route: ValidationGalleryRoute,
    width: CGFloat,
    height: CGFloat
) throws -> (bitmap: NSBitmapImageRep, pngData: Data) {
    let content = ValidationGalleryView(route: route)
        .frame(width: width, height: height)
        .environment(\.colorScheme, .light)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: .aqua)
    hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    hostingView.layoutSubtreeIfNeeded()
    let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let pngData = try #require(bitmap.representation(using: .png, properties: [:]))
    return (bitmap, pngData)
}
