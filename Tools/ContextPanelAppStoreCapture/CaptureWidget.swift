import ContextPanelCore
import ContextPanelWidgetUI
import SwiftUI
import WidgetKit

// This extension belongs only to the disposable fixture app. It has no shared
// container, credential store, provider client, subscription or refresh service.
private struct CaptureEntry: TimelineEntry {
    let date: Date
}

private struct CaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaptureEntry { CaptureEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (CaptureEntry) -> Void) {
        completion(CaptureEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureEntry>) -> Void) {
        completion(Timeline(entries: [CaptureEntry(date: .now)], policy: .never))
    }
}

private struct CaptureWidgetContent: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        #if os(visionOS)
        let dark = CompanionAppearanceSettings.defaultSettings.resolvedVisionOSWidgetAppearance == .dark
        #endif
        ContextPanelWidgetContentView(
            family: family,
            snapshot: ScreenshotFixture.widgetSnapshot,
            links: ContextPanelWidgetLinks(
                overview: URL(string: "contextpanel-fixture://overview")!,
                reconnect: URL(string: "contextpanel-fixture://reconnect")!,
                cacheStatsSettings: URL(string: "contextpanel-fixture://settings")!),
            showsResetCreditSurfaces: true,
            resetCreditMaximumAge: ScreenshotFixture.widgetMaximumAge,
            presentationDate: ScreenshotFixture.date,
            allowsNavigation: false)
            .environment(\.locale, ScreenshotFixture.locale)
            .environment(\.timeZone, ScreenshotFixture.timeZone)
            .containerBackground(CPWTheme.surface, for: .widget)
            #if os(visionOS)
            .cpwThemeVariant(dark ? .dark : .light)
            .environment(\.colorScheme, dark ? .dark : .light)
            .preferredColorScheme(dark ? .dark : .light)
            #endif
    }
}

@main
struct CaptureWidget: Widget {
    init() { ScreenshotFixture.configureProcess() }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ScreenshotFixture.widgetKind, provider: CaptureProvider()) { _ in
            CaptureWidgetContent()
        }
        .configurationDisplayName("Context Panel")
        #if os(macOS)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        #else
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        #endif
        .contentMarginsDisabled()
    }
}
