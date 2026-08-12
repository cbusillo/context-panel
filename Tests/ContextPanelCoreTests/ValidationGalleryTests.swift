import AppKit
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import ContextPanelCore
@testable import ContextPanelTVSupport
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
        string: "contextpanel://validation-gallery?fixture=stale&family=systemLarge&appearance=dark&presentation=diagnostics"
    ))
    let directRoute = try #require(ValidationGalleryRoute(url: direct))
    #expect(directRoute.fixtureID == .stale)
    #expect(directRoute.family == .systemLarge)
    #expect(directRoute.appearance == .dark)
    #expect(directRoute.presentation == .diagnostics)

    let settingsPresentation = try #require(URL(
        string: "contextpanelcompanion://validation-gallery?presentation=settings"
    ))
    #expect(ValidationGalleryRoute(url: settingsPresentation)?.presentation == .settings)

    let reconnectPresentation = try #require(URL(
        string: "contextpanel://validation-gallery?presentation=reconnect"
    ))
    #expect(ValidationGalleryRoute(url: reconnectPresentation)?.presentation == .reconnect)

    let settings = try #require(URL(
        string: "contextpanelcompanion://settings/validation-gallery?fixture=healthy"
    ))
    #expect(ValidationGalleryRoute(url: settings) == ValidationGalleryRoute())

    let invalidURLs = [
        "file:///tmp/validation-gallery",
        "contextpanel://validation-gallery/extra",
        "contextpanel://validation-gallery?fixture=unknown",
        "contextpanel://validation-gallery?presentation=unknown",
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
    #expect(!snapshot.observedBurnRates.isEmpty)
}

@Test func watchValidationFixturesCoverAppAndComplicationBoundaries() throws {
    let adapter = WatchValidationFixtureAdapter()
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate

    for state in WatchValidationAppState.allCases {
        let context = adapter.appContext(state: state, presentationDate: presentationDate)
        #expect(context.presentationDate == presentationDate)
        #expect(context.snapshot.generatedAt <= presentationDate)
        #expect(context.snapshot.limits.allSatisfy { $0.accountID.hasPrefix("sample-") })
        #expect(context.snapshot.reports.allSatisfy { $0.accountID.hasPrefix("sample-") })
    }

    let providerAccess = adapter.complicationContext(
        state: .providerAccess,
        presentationDate: presentationDate
    )
    let alert = try #require(providerAccess.snapshot.primaryProviderAccessAlert)
    #expect(alert.accountID.hasPrefix("sample-"))
    #expect(alert.accessState.kind == .blockedUntilReset)
    #expect(alert.accessState.resetsAt == presentationDate.addingTimeInterval(3 * 3_600))

    let unknown = adapter.complicationContext(
        state: .unknown,
        presentationDate: presentationDate
    )
    #expect(unknown.snapshot.state == .setupNeeded)
    #expect(unknown.result.document == nil)
}

@Test func tvValidationFixturesAreDeterministicAndSynthetic() throws {
    let adapter = TVValidationFixtureAdapter()
    let presentationDate = ValidationFixtureCatalog.referencePresentationDate

    for state in TVValidationState.allCases {
        let context = adapter.context(state: state, presentationDate: presentationDate)
        let repeatedContext = adapter.context(state: state, presentationDate: presentationDate)
        #expect(context.presentationDate == presentationDate)
        #expect(context.snapshot.generatedAt <= presentationDate)
        #expect(context.snapshot == repeatedContext.snapshot)
        #expect(context.receivedAt == repeatedContext.receivedAt)
        #expect(context.displayPreferences == repeatedContext.displayPreferences)
        #expect(context.snapshot.limits.allSatisfy { limit in
            limit.accountID.hasPrefix("sample-")
                && limit.accountName.hasPrefix("Sample ")
                && !limit.accountName.contains("@")
        })
        #expect(context.snapshot.reports.allSatisfy { report in
            report.accountID.hasPrefix("sample-")
                && report.accountName.hasPrefix("Sample ")
                && !report.accountName.contains("@")
        })

        let first = TVRunwayPresentation(
            snapshot: context.snapshot,
            preferences: context.displayPreferences,
            mode: .fullDetail,
            isRefreshing: state == .loading,
            now: presentationDate
        )
        let second = TVRunwayPresentation(
            snapshot: repeatedContext.snapshot,
            preferences: repeatedContext.displayPreferences,
            mode: .fullDetail,
            isRefreshing: state == .loading,
            now: repeatedContext.presentationDate
        )
        #expect(first == second)
    }

    let setup = adapter.context(state: .setupNeeded, presentationDate: presentationDate)
    #expect(setup.result.document == nil)

    let partial = adapter.context(state: .partialFailure, presentationDate: presentationDate)
    #expect(partial.snapshot.limits.isEmpty == false)
    #expect(partial.snapshot.reports.contains { $0.status == .failure })

    let providerAccess = adapter.context(state: .providerAccess, presentationDate: presentationDate)
    let alert = try #require(providerAccess.snapshot.primaryProviderAccessAlert)
    #expect(alert.accessState.kind == .blockedUntilReset)
    #expect(alert.accessState.resetsAt == presentationDate.addingTimeInterval(3 * 3_600))
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

    #expect(rendered.bitmap.size.width == 1_024)
    #expect(rendered.bitmap.size.height == 768)
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

    #expect(rendered.bitmap.size.width == 390)
    #expect(rendered.bitmap.size.height == 844)
    #expect(rendered.pngData.count > 15_000)

    if let outputPath = ProcessInfo.processInfo.environment["CONTEXT_PANEL_VALIDATION_GALLERY_COMPACT_PREVIEW_PATH"] {
        try rendered.pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
    }
}

@MainActor
@Test func validationGalleryApplicationSurfaceRendersAtAccessibilitySizeInDarkMode() throws {
    let route = ValidationGalleryRoute(
        fixtureID: .denseAccounts,
        family: .systemLarge,
        appearance: .dark,
        presentation: .overview
    )
    let content = ValidationGalleryView(
        route: route,
        supportedPresentations: [.overview, .detail, .reconnect, .diagnostics, .settings, .widget],
        applicationPreview: { context in
            AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    Text("Production overview")
                        .font(.title2)
                    Text(context.fixture.purpose)
                    Text("\(context.snapshot.limits.count) sample limits")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            )
        }
    )
    .frame(width: 1_024, height: 1_024)
    .environment(\.colorScheme, .dark)
    .environment(\.dynamicTypeSize, .accessibility1)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: .darkAqua)
    hostingView.frame = NSRect(x: 0, y: 0, width: 1_024, height: 1_024)
    hostingView.layoutSubtreeIfNeeded()
    let bitmap = try #require(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    let pngData = try #require(bitmap.representation(using: .png, properties: [:]))

    #expect(pngData.count > 20_000)
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
