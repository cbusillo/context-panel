import AppKit
import ContextPanelApp
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

// Renders one macOS shared-view cell (widget or Mac app presentation) to a PNG
// without launching the app. A widget is drawn in its family frame with the widget
// corner mask; an app presentation fills the window's detail area.
// Operator and CI tooling only: it links no app or widget bundle, registers
// nothing with LaunchServices or PlugInKit, and reads only synthetic fixtures.
//
//   ContextPanelSharedViewRenderer --fixture healthy --family systemSmall \
//     --appearance light --presentation widget --output cell.png
//
// Exit codes: EX_USAGE for bad arguments, 3 for a presentation the Mac gallery
// does not offer, EX_SOFTWARE when rendering fails, EX_CANTCREAT when writing fails.

private let interactive = CommandLine.arguments.contains("--interactive")
private let appStoreScenario: Bool = {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--scenario"), index + 1 < arguments.count else { return false }
    return arguments[index + 1] == "app-store"
}()
private var presentationWindow: NSWindow?

private let unsupportedPresentationStatus: Int32 = 3
private let macPresentations: Set<ValidationGalleryPresentation> = [.overview, .detail, .reconnect, .diagnostics, .widget]

// Default review sizes, plus App Store draft canvases selected by the app-store scenario.
private let accountPresentationSizes: [String: CGSize] = [
    "account-overview": appStoreScenario ? CGSize(width: 1_024, height: 1_366) : CGSize(width: 900, height: 880),
    "vision-overview": CGSize(width: 1_200, height: 900),
    "account-deadlines": CGSize(width: 900, height: 1_060),
    "account-detail": appStoreScenario ? CGSize(width: 1_440, height: 900) : CGSize(width: 900, height: 720),
    "phone-overview": CGSize(width: 393, height: 1_960),
    "phone-detail": appStoreScenario ? CGSize(width: 402, height: 874) : CGSize(width: 393, height: 852),
    "phone-detail-65": CGSize(width: 428, height: 926),
    "watch-app": appStoreScenario ? CGSize(width: 205, height: 251) : CGSize(width: 198, height: 560),
    "watch-rectangular": CGSize(width: 184, height: 74),
    "watch-circular": CGSize(width: 76, height: 76),
    "tv-board": CGSize(width: 1_920, height: 1_080),
    "settings-display-normal": CGSize(width: 720, height: 700),
    "settings-display-minimum": CGSize(width: 720, height: 600),
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
    let names = ["--fixture", "--family", "--appearance", "--presentation", "--output", "--scenario", "--scale", "--interactive"]
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
    if let interactive = values["--interactive"], interactive != "yes" { fail("--interactive requires yes") }
    if let scale = values["--scale"], Int(scale).map({ (1...3).contains($0) }) != true {
        fail("--scale requires 1, 2, or 3")
    }
    let accountPresentation = accountPresentationSizes.keys.contains(values["--presentation"] ?? "") ? values["--presentation"] : nil
    let sixAccounts = ["six-accounts", "app-store"].contains(values["--scenario"] ?? "")
    let presentationValue = deadlines || accountPresentation != nil ? "widget" : values["--presentation"] ?? ""
    if let scenario = values["--scenario"], !["four-offers-long-name", "six-accounts", "app-store"].contains(scenario) { fail("unsupported scenario") }
    guard let fixture = values["--fixture"].flatMap(ValidationFixtureID.init(rawValue:)),
          let family = values["--family"].flatMap(ValidationGalleryFamily.init(rawValue:)),
          let appearance = values["--appearance"].flatMap(ValidationGalleryAppearance.init(rawValue:)),
          appearance != .adaptive,
          let presentation = ValidationGalleryPresentation(rawValue: presentationValue),
          let output = values["--output"], !output.isEmpty
    else {
        fail("--fixture, --family, --appearance (light|dark), --presentation, and --output are required")
    }
    // Settings is a companion presentation. The Mac gallery does not offer it and would
    // fall back to another presentation, which would be the wrong image.
    guard macPresentations.contains(presentation) else {
        fail(
            "the Mac gallery has no \(presentation.rawValue) presentation",
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
    if scenario {
        return deadlines ? CGSize(width: 760, height: 320) : CGSize(width: route.family.width, height: route.family.height)
    }
    return cellFrame(route: route).size
}

private func cellFrame(route: ValidationGalleryRoute) -> SharedViewFrame {
    route.presentation == .widget ? route.family.frame(on: .mac) : SharedViewHost.mac.applicationFrame
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
        case "settings-display-normal", "settings-display-minimum":
            let preferences = WidgetDisplayPreferences.defaultPreferences
            let family: SettingsWidgetPreviewFamily = switch route.family.widgetFamily {
            case .systemSmall: .small
            case .systemLarge: .large
            default: .medium
            }
            view = AnyView(VStack(spacing: 0) {
                Picker(AccountTerms.settings, selection: .constant(AccountTerms.display)) {
                    ForEach([AccountTerms.accounts, AccountTerms.updates, AccountTerms.alerts, AccountTerms.display], id: \.self) {
                        Text($0).tag($0)
                    }
                }.pickerStyle(.segmented).padding(16)
                Form {
                    WidgetDisplaySettingsSections(snapshot: snapshot, preferences: preferences,
                        initialFamily: family, presentationDate: now,
                        providerLabel: { Text($0.shortName) },
                        onVisibilityChange: { _, _ in }, onMove: { _, _ in })
                }.formStyle(.grouped)
            })
        case "account-overview", "vision-overview":
            view = AnyView(AccountDashboardPanel(overview: overview, now: now, openAccount: { _ in }, openDeadlines: {}).padding(24))
        case "account-deadlines":
            view = AnyView(AccountDeadlinesPanel(overview: overview, now: now, openAccount: { _ in }).padding(24))
        case "account-detail":
            view = AnyView(AccountDashboardDetail(account: overview.accounts[0], overview: overview, now: now).padding(24))
        case "phone-overview":
            view = AnyView(AccountDashboardPanel(overview: overview, now: now, compact: true, openAccount: { _ in },
                openDeadlines: {}).padding(16))
        case "phone-detail", "phone-detail-65":
            view = AnyView(AccountDashboardDetail(account: overview.accounts[0], overview: overview, now: now, compact: true).padding(16))
        case "watch-app":
            let nextIDs = Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id })
            let visibleAccounts = appStoreScenario ? Array(overview.accounts.prefix(1)) : overview.accounts
            view = AnyView(VStack(alignment: .leading, spacing: 8) {
                Text(AccountTerms.accounts).font(.system(size: 15, weight: .semibold))
                if !appStoreScenario {
                    WatchAccountHeadline(overview: overview, now: now)
                    if let deadline = overview.nextDeadline { WatchBankedLine(deadline: deadline, now: now) }
                }
                ForEach(visibleAccounts) { account in
                    WatchAccountRow(account: account, isNext: nextIDs.contains(account.id), now: now,
                                    deadlines: overview.deadlines.filter { $0.accountID == account.id })
                        .padding(8).background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
            }.padding(.horizontal, 6).foregroundStyle(.white))
        case "watch-rectangular":
            view = AnyView(WatchAccountRectangularFace(overview: overview, now: now).padding(4).foregroundStyle(.white))
        case "watch-circular":
            view = AnyView(WatchAccountCircularFace(overview: overview, now: now).foregroundStyle(.white))
        case "tv-board":
            view = AnyView(TVAccountBoard(overview: overview, now: now).padding(.horizontal, 72).padding(.vertical, 48))
        default:
            view = AnyView(ContextPanelWidgetContentView(family: route.family.widgetFamily, snapshot: snapshot,
                links: ContextPanelWidgetLinks(overview: URL(string: "contextpanel://overview")!, reconnect: URL(string: "contextpanel://settings")!, cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!),
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
                reconnect: URL(string: "contextpanel://settings")!, cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!)
            view = AnyView(ContextPanelWidgetContentView(family: route.family.widgetFamily, snapshot: snapshot,
                links: links, showsResetCreditSurfaces: true, presentationDate: now)
                .cpwThemeVariant(isDark ? .dark : .light)
                .background(CPWTheme.surface(variant: isDark ? .dark : .light))
                .clipShape(RoundedRectangle(cornerRadius: 18)))
        }
    } else if route.presentation == .widget {
        view = AnyView(ContextPanelWidgetContentView(family: route.family.widgetFamily,
            snapshot: ValidationGalleryContext(route: route).snapshot,
            links: ContextPanelWidgetLinks(overview: URL(string: "contextpanel-validation://sample")!,
                reconnect: URL(string: "contextpanel-validation://sample")!,
                cacheStatsSettings: URL(string: "contextpanel-validation://sample")!),
            showsResetCreditSurfaces: true, presentationDate: ValidationFixtureCatalog.referencePresentationDate)
            .cpwThemeVariant(isDark ? .dark : .light)
            .sharedViewFrame(cellFrame(route: route)) { CPWTheme.surface(variant: isDark ? .dark : .light) })
    } else {
        view = AnyView(MacValidationGallery.presentation(route: route)
            .sharedViewFrame(cellFrame(route: route)) { Color(nsColor: .windowBackgroundColor) })
    }
    func tokenColor(_ token: AccountColorToken, dark: Bool) -> Color {
        let value = token.rgb(dark: dark)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: dark))
    }
    let content = view
        .frame(width: size.width, height: interactive ? nil : size.height, alignment: .topLeading)
        .frame(maxHeight: interactive ? .infinity : nil, alignment: .topLeading)
        .foregroundStyle(tokenColor(.primary, dark: isDark))
        .background(accountPresentation?.hasPrefix("watch") == true ? tokenColor(.watchSurface, dark: true)
            : accountPresentation == "tv-board" ? tokenColor(.surface, dark: true)
            : deadlines || accountPresentation != nil || appStoreScenario ? CPWTheme.surface(variant: isDark ? .dark : .light) : Color.clear)
        .environment(\.colorScheme, isDark ? .dark : .light)
        // The gallery prints its fixed presentation time; pin how it is formatted so
        // the image does not depend on the host's region or time zone.
        .environment(\.locale, Locale(identifier: "en_US_POSIX"))
        .environment(\.timeZone, TimeZone(identifier: "UTC") ?? .gmt)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hostingView.frame = NSRect(origin: .zero, size: size)
    if interactive {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings preview — synthetic data"
        window.contentMinSize = CGSize(width: 720, height: 600)
        window.contentView = hostingView
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        presentationWindow = window
        print("native-window=\(window.windowNumber) content=\(Int(size.width))x\(Int(size.height)) synthetic-only")
        fflush(stdout)
    }
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
        (appStoreScenario ? "Studio" : "A deliberately long OpenAI account name", .openAI, 85, 120, 40, 2 + 10 / 60.0, 0.45, 6, [24 + 20 / 60.0, 12 * 24 + 55 / 60.0]),
        (appStoreScenario ? "Work" : "work@example.invalid", .openAI, 28, 55, 12, 4, 0.4, 3, [26 * 24 + 3, 44 * 24 + 30 / 60.0]),
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
let size = accountPresentation.flatMap { accountPresentationSizes[$0] } ?? renderSize(route: route, scenario: scenario, deadlines: deadlines)
print("rendered \(route.id) \(Int(size.width))x\(Int(size.height)) \(png.count) bytes")
fflush(stdout)
if interactive { NSApp.run() }
