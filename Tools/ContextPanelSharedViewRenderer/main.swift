import AppKit
import ContextPanelCore
import ContextPanelSettingsUI
import ContextPanelWidgetUI
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import Foundation
import SwiftUI
import WidgetKit

// Renders one macOS Validation Gallery cell to a PNG without launching the app.
// Operator and CI tooling only: it links no app or widget bundle, registers
// nothing with LaunchServices or PlugInKit, and reads only synthetic fixtures.
//
//   ContextPanelSharedViewRenderer --fixture healthy --family systemSmall \
//     --appearance light --presentation widget --output cell.png
//
// Exit codes: EX_USAGE for bad arguments, 3 when the cell needs views this tool
// cannot draw, EX_SOFTWARE when rendering fails, EX_CANTCREAT when writing fails.

private let canvas = CGSize(width: 1_024, height: 768)

private let unsupportedPresentationStatus: Int32 = 3

private func fail(_ message: String, status: Int32 = EX_USAGE) -> Never {
    FileHandle.standardError.write(Data("ContextPanelSharedViewRenderer: \(message)\n".utf8))
    exit(status)
}

private func parseArguments(_ arguments: [String]) -> (route: ValidationGalleryRoute, output: URL, scenario: Bool, deadlines: Bool) {
    let names = ["--fixture", "--family", "--appearance", "--presentation", "--output", "--scenario"]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard names.contains(name), index + 1 < arguments.count, values[name] == nil else {
            fail("unexpected or repeated argument: \(name)")
        }
        values[name] = arguments[index + 1]
        index += 2
    }
    let deadlines = values["--presentation"] == "reset-deadlines"
    let presentationValue = deadlines ? "widget" : values["--presentation"] ?? ""
    if let scenario = values["--scenario"], scenario != "four-offers-long-name" { fail("unsupported scenario") }
    guard let fixture = values["--fixture"].flatMap(ValidationFixtureID.init(rawValue:)),
          let family = values["--family"].flatMap(ValidationGalleryFamily.init(rawValue:)),
          let appearance = values["--appearance"].flatMap(ValidationGalleryAppearance.init(rawValue:)),
          appearance != .adaptive,
          let presentation = ValidationGalleryPresentation(rawValue: presentationValue),
          let output = values["--output"], !output.isEmpty
    else {
        fail("--fixture, --family, --appearance (light|dark), --presentation, and --output are required")
    }
    // Application presentations are drawn by views that live in the Mac app target.
    // Without them the gallery falls back to the widget, which would be the wrong image.
    guard presentation == .widget else {
        fail(
            "only the widget presentation can be rendered headlessly; \(presentation.rawValue) needs the Mac app's views",
            status: unsupportedPresentationStatus
        )
    }
    return (
        ValidationGalleryRoute(
            fixtureID: fixture,
            family: family,
            appearance: appearance,
            presentation: presentation
        ),
        URL(fileURLWithPath: output),
        values["--scenario"] != nil || deadlines,
        deadlines
    )
}

@MainActor
private func renderSize(route: ValidationGalleryRoute, scenario: Bool, deadlines: Bool) -> CGSize {
    scenario ? (deadlines ? CGSize(width: 760, height: 320) : CGSize(width: route.family.width, height: route.family.height)) : canvas
}

@MainActor
private func render(route: ValidationGalleryRoute, scenario: Bool, deadlines: Bool) -> Data? {
    let isDark = route.appearance == .dark
    let size = renderSize(route: route, scenario: scenario, deadlines: deadlines)
    let view: AnyView
    if scenario {
        // Operator-owned synthetic data only: no publisher storage, account homes or credentials.
        let now = ContextPanelDateFormatting.date(from: "2026-10-01T02:00:00Z")!
        let name = "A deliberately long OpenAI account name"
        let limit = UsageLimit(provider: .openAI, accountID: "synthetic", accountName: name,
            label: "Codex Weekly", windowLabel: "Weekly", modelLabel: "Codex", unit: .percent,
            used: 71, limit: 100, resetsAt: now.addingTimeInterval(7 * 86_400), lastUpdatedAt: now, confidence: .observed)
        let expiryOffsets: [TimeInterval] = [2 * 86_400 + 20 * 60, 5 * 86_400 + 35 * 60, 12 * 86_400 + 55 * 60, 28 * 86_400 + 45 * 60]
        let expiryDates = expiryOffsets.map { now.addingTimeInterval($0) }
        let summary = ProviderResetCreditSummary(availableCount: 4, observedAt: now, coverage: .complete, knownExpiries: expiryDates)
        let report = StoredProviderReport(provider: .openAI, accountID: "synthetic", accountName: name,
            generatedAt: now, resetCredits: summary, status: .healthy, errorMessage: nil)
        if deadlines {
            view = AnyView(BankedResetDeadlinesView(reports: [report], limits: [limit], presentationDate: now).padding(14))
        } else {
            let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: [limit], reports: [report], status: .healthy, message: "")
            let links = ContextPanelWidgetLinks(overview: URL(string: "contextpanel://overview")!,
                reconnect: URL(string: "contextpanel://settings")!, cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!, resetCreditInteraction: .none)
            view = AnyView(ContextPanelWidgetContentView(family: route.family.widgetFamily, snapshot: snapshot,
                displayPreferences: .defaultPreferences, links: links, showsResetCreditSurfaces: true, presentationDate: now)
                .cpwThemeVariant(isDark ? .dark : .light)
                .background(CPWTheme.surface(variant: isDark ? .dark : .light))
                .clipShape(RoundedRectangle(cornerRadius: 18)))
        }
    } else {
        view = AnyView(ValidationGalleryView(route: route))
    }
    let content = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(isDark ? Color.white : Color.black)
        .background(deadlines ? CPWTheme.surface(variant: isDark ? .dark : .light) : Color.clear)
        .environment(\.colorScheme, isDark ? .dark : .light)
        // The gallery prints its fixed presentation time; pin how it is formatted so
        // the image does not depend on the host's region or time zone.
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    // One pixel per point regardless of the host display's backing scale.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return nil
    }
    bitmap.size = size
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
}

// The gallery formats its fixed presentation time with the process's current time
// zone and locale, not SwiftUI's environment. Pin both so the PNG is the same on
// every host.
setenv("TZ", "UTC", 1)
tzset()
NSTimeZone.default = TimeZone(identifier: "UTC") ?? .gmt
UserDefaults.standard.setVolatileDomain(
    ["AppleLocale": "en_US_POSIX", "AppleLanguages": ["en-US"]],
    forName: UserDefaults.argumentDomain
)

let (route, output, scenario, deadlines) = parseArguments(Array(CommandLine.arguments.dropFirst()))
guard !FileManager.default.fileExists(atPath: output.path) else {
    fail("refusing to overwrite \(output.path)")
}
guard let png = render(route: route, scenario: scenario, deadlines: deadlines) else {
    fail("the gallery cell could not be rendered", status: EX_SOFTWARE)
}
do {
    try png.write(to: output, options: .withoutOverwriting)
} catch {
    fail("the PNG could not be written", status: EX_CANTCREAT)
}
let size = renderSize(route: route, scenario: scenario, deadlines: deadlines)
print("rendered \(route.id) \(Int(size.width))x\(Int(size.height)) \(png.count) bytes")
