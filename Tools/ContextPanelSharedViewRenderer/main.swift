import AppKit
import ContextPanelCore
import ContextPanelSettingsUI
import ContextPanelTVSupport
import ContextPanelWidgetUI
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import ContextPanelWatchSupport
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

// Account surfaces at their real point sizes: Mac pane, iPhone 15 Pro, Apple Watch 45 mm, Apple TV.
private let accountPresentationSizes: [String: CGSize] = [
    "account-overview": CGSize(width: 900, height: 880),
    "account-deadlines": CGSize(width: 900, height: 1_060),
    "account-detail": CGSize(width: 900, height: 720),
    "phone-overview": CGSize(width: 393, height: 1_900),
    "phone-detail": CGSize(width: 393, height: 852),
    "watch-app": CGSize(width: 198, height: 560),
    "watch-rectangular": CGSize(width: 184, height: 74),
    "watch-circular": CGSize(width: 76, height: 76),
    "tv-board": CGSize(width: 1_920, height: 1_080),
]

// Pixels per point. 1 by default; review screenshots use 2 to match a Retina display.
private let pixelScale: Int = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--scale"), index + 1 < arguments.count,
          let value = Int(arguments[index + 1]), (1...3).contains(value) else { return 1 }
    return value
}()

private func fail(_ message: String, status: Int32 = EX_USAGE) -> Never {
    FileHandle.standardError.write(Data("ContextPanelSharedViewRenderer: \(message)\n".utf8))
    exit(status)
}

private func parseArguments(_ arguments: [String]) -> (route: ValidationGalleryRoute, output: URL, scenario: Bool, deadlines: Bool, accountPresentation: String?, sixAccounts: Bool) {
    let names = ["--fixture", "--family", "--appearance", "--presentation", "--output", "--scenario", "--scale"]
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
    let accountPresentation = accountPresentationSizes.keys.contains(values["--presentation"] ?? "") ? values["--presentation"] : nil
    let sixAccounts = values["--scenario"] == "six-accounts"
    let presentationValue = deadlines || accountPresentation != nil ? "widget" : values["--presentation"] ?? ""
    if let scenario = values["--scenario"], scenario != "four-offers-long-name" && scenario != "six-accounts" { fail("unsupported scenario") }
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
        deadlines,
        accountPresentation,
        sixAccounts
    )
}

@MainActor
private func renderSize(route: ValidationGalleryRoute, scenario: Bool, deadlines: Bool) -> CGSize {
    scenario ? (deadlines ? CGSize(width: 760, height: 320) : CGSize(width: route.family.width, height: route.family.height)) : canvas
}

@MainActor
private func render(route: ValidationGalleryRoute, scenario: Bool, deadlines: Bool, accountPresentation: String?, sixAccounts: Bool) -> Data? {
    let isDark = route.appearance == .dark
    let size = accountPresentation.flatMap { accountPresentationSizes[$0] } ?? renderSize(route: route, scenario: scenario, deadlines: deadlines)
    let view: AnyView
    if accountPresentation != nil || sixAccounts {
        let now = ContextPanelDateFormatting.date(from: "2026-10-01T14:07:00Z")!
        let snapshot = accountFixture(now: now)
        let overview = snapshot.accountOverview(now: now)
        switch accountPresentation {
        case "account-overview":
            view = AnyView(AccountDashboardPanel(overview: overview, now: now, openAccount: { _ in }, openDeadlines: {}).padding(24))
        case "account-deadlines":
            view = AnyView(AccountDeadlinesPanel(overview: overview, now: now, openAccount: { _ in }).padding(24))
        case "account-detail":
            view = AnyView(AccountDashboardDetail(account: overview.accounts[0], overview: overview, now: now).padding(24))
        case "phone-overview":
            view = AnyView(AccountDashboardPanel(overview: overview, now: now, compact: true, openAccount: { _ in },
                openDeadlines: {}).padding(16))
        case "phone-detail":
            view = AnyView(AccountDashboardDetail(account: overview.accounts[0], overview: overview, now: now, compact: true).padding(16))
        case "watch-app":
            let nextIDs = Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id })
            view = AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(AccountTerms.accounts).font(.system(size: 15, weight: .semibold))
                WatchAccountHeadline(overview: overview, now: now)
                if let deadline = overview.nextDeadline { WatchBankedLine(deadline: deadline, now: now) }
                ForEach(overview.accounts) { account in
                    WatchAccountRow(account: account, isNext: nextIDs.contains(account.id), now: now,
                                    deadlines: overview.deadlines.filter { $0.accountID == account.id })
                        .padding(8).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 6).foregroundStyle(.white))
        case "watch-rectangular":
            view = AnyView(WatchAccountRectangularFace(overview: overview, now: now).padding(4).foregroundStyle(.white))
        case "watch-circular":
            view = AnyView(WatchAccountCircularFace(overview: overview).foregroundStyle(.white))
        case "tv-board":
            view = AnyView(TVAccountBoard(overview: overview, now: now).padding(.horizontal, 72).padding(.vertical, 48))
        default:
            view = AnyView(ContextPanelWidgetContentView(family: route.family.widgetFamily, snapshot: snapshot,
                displayPreferences: .defaultPreferences,
                links: ContextPanelWidgetLinks(overview: URL(string: "contextpanel://overview")!, reconnect: URL(string: "contextpanel://settings")!, cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!, resetCreditInteraction: .none),
                showsResetCreditSurfaces: true, presentationDate: now)
                .cpwThemeVariant(isDark ? .dark : .light))
        }
    } else if scenario {
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
    func tokenColor(_ token: AccountColorToken, dark: Bool) -> Color {
        let value = token.rgb(dark: dark)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: dark))
    }
    let content = view
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .foregroundStyle(tokenColor(.primary, dark: isDark))
        .background(accountPresentation?.hasPrefix("watch") == true ? tokenColor(.watchSurface, dark: true)
            : accountPresentation == "tv-board" ? tokenColor(.surface, dark: true)
            : deadlines || accountPresentation != nil ? CPWTheme.surface(variant: isDark ? .dark : .light) : Color.clear)
        .environment(\.colorScheme, isDark ? .dark : .light)
        // The gallery prints its fixed presentation time; pin how it is formatted so
        // the image does not depend on the host's region or time zone.
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    // pixelScale pixels per point regardless of the host display's backing scale.
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width) * pixelScale,
        pixelsHigh: Int(size.height) * pixelScale,
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

private func accountFixture(now: Date) -> WidgetSnapshot {
    // Synthetic accounts only. Each row: name, provider, weekly used %, weekly reset (h), 5h used %, 5h reset (h),
    // weekly burn %/h, 5h burn %/h (nil while measuring), banked expiries (h).
    typealias Row = (String, Provider, Int, Double, Int, Double, Double?, Double?, [Double])
    let rows: [Row] = [
        ("A deliberately long OpenAI account name", .openAI, 85, 120, 40, 2 + 10 / 60.0, 0.45, 6, [24 + 20 / 60.0, 12 * 24 + 55 / 60.0]),
        ("work@example.invalid", .openAI, 28, 55, 12, 4, 0.4, 3, [26 * 24 + 3, 44 * 24 + 30 / 60.0]),
        ("Personal", .openAI, 11, 147, 0, 5, 0.03, nil, []),
        ("Claude primary", .anthropic, 63, 138, 78, 1 + 13 / 60.0, 0.35, 15, [4 * 24 + 20 / 60.0, 12 * 24 + 55 / 60.0]),
        ("Claude backup", .anthropic, 43, 74, 5, 4 + 40 / 60.0, 0.2, 1, []),
        ("Antigravity", .google, 9, 164, 0, 5, 0.05, nil, []),
    ]
    var limits: [UsageLimit] = []
    var reports: [StoredProviderReport] = []
    var metadata: [AccountDisplayMetadata] = []
    var rates: [String: [String: ObservedBurnRate]] = [:]
    for (index, row) in rows.enumerated() {
        let id = "synthetic-\(index)"
        for (window, used, resetHours, burn) in [("Weekly", row.2, row.3, row.6), ("5-hour", row.4, row.5, row.7)] {
            let limit = UsageLimit(provider: row.1, accountID: id, accountName: "Unexported provider identity",
                label: window, windowLabel: window, unit: .percent, used: used, limit: 100,
                resetsAt: now.addingTimeInterval(resetHours * 3_600), lastUpdatedAt: now, confidence: .observed)
            limits.append(limit)
            if let burn {
                rates[id, default: [:]][limit.id] = ObservedBurnRate(limitID: limit.id, unitsPerHour: burn,
                    observedDurationHours: 6, sampleCount: 24)
            }
        }
        let banked = row.8.isEmpty ? nil : ProviderResetCreditSummary(availableCount: row.8.count, observedAt: now,
            coverage: .complete, knownExpiries: row.8.map { now.addingTimeInterval($0 * 3_600) })
        reports.append(StoredProviderReport(provider: row.1, accountID: id, accountName: "Unexported provider identity",
            generatedAt: now, resetCredits: banked, status: .healthy, errorMessage: nil))
        metadata.append(AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(row.1, id),
            configurationID: AccountDisplayMetadata.safeID(row.1, id), provider: row.1, label: row.0, useLast: index == 2))
    }
    return WidgetSnapshot(state: .ready, generatedAt: now, limits: limits, reports: reports, status: .healthy,
        message: "", accountDisplayMetadata: metadata, accountBurnRates: rates)
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

let (route, output, scenario, deadlines, accountPresentation, sixAccounts) = parseArguments(Array(CommandLine.arguments.dropFirst()))
guard !FileManager.default.fileExists(atPath: output.path) else {
    fail("refusing to overwrite \(output.path)")
}
guard let png = render(route: route, scenario: scenario, deadlines: deadlines, accountPresentation: accountPresentation, sixAccounts: sixAccounts) else {
    fail("the gallery cell could not be rendered", status: EX_SOFTWARE)
}
do {
    try png.write(to: output, options: .withoutOverwriting)
} catch {
    fail("the PNG could not be written", status: EX_CANTCREAT)
}
let size = renderSize(route: route, scenario: scenario, deadlines: deadlines)
print("rendered \(route.id) \(Int(size.width))x\(Int(size.height)) \(png.count) bytes")
