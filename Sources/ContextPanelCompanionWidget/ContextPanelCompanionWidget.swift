import ContextPanelCore
import ContextPanelCompanionSupport
import ContextPanelWidgetUI
import Foundation
import SwiftUI
import WidgetKit

struct ContextPanelCompanionWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let appearanceSettings: CompanionAppearanceSettings
}

struct ContextPanelCompanionTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextPanelCompanionWidgetEntry {
        ContextPanelCompanionWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: nil, status: .unknown)),
            displayPreferences: .defaultPreferences,
            appearanceSettings: .defaultSettings
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelCompanionWidgetEntry) -> Void) {
        loadEntry(date: Date(), completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelCompanionWidgetEntry>) -> Void) {
        let now = Date()
        CompanionWidgetLoadQueue.loadTimeline(date: now) { entries in
            let settings = ContextPanelLocations.companionRefreshSettingsURL()
                .map { CompanionRefreshSettingsStore(settingsURL: $0).load() }
                ?? .defaultSettings
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(settings.widgetInterval))))
        }
    }

    private func loadEntry(
        date: Date,
        completion: @escaping (ContextPanelCompanionWidgetEntry) -> Void
    ) {
        CompanionWidgetLoadQueue.load(date: date, completion: completion)
    }
}

private enum CompanionWidgetLoadQueue {
    private static let queue = DispatchQueue(
        label: "com.shinycomputers.contextpanel.companion-widget-load",
        qos: .utility
    )

    static func load(date: Date, completion: @escaping (ContextPanelCompanionWidgetEntry) -> Void) {
        queue.async {
            completion(entry(
                date: date,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                    maximumAge: SnapshotFreshness.widgetMaximumAge
                )
            ))
        }
    }

    static func loadTimeline(
        date: Date,
        completion: @escaping ([ContextPanelCompanionWidgetEntry]) -> Void
    ) {
        queue.async {
            let policy = SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            let currentEntry = entry(date: date, stalenessPolicy: policy)
            guard currentEntry.snapshot.state == .ready,
                  let staleDate = policy.nextStaleTransitionDate(
                    for: currentEntry.snapshot.usageSnapshot,
                    now: date
                  )
            else {
                completion([currentEntry])
                return
            }
            completion([currentEntry, entry(date: staleDate, stalenessPolicy: policy)])
        }
    }

    private static func entry(
        date: Date,
        stalenessPolicy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelCompanionWidgetEntry {
        let result = CompanionSyncLoader.loadWidgetMirror(now: date)
        let appearanceSettings = ContextPanelLocations.companionAppearanceSettingsURL()
            .map { CompanionAppearanceSettingsStore(settingsURL: $0).load() }
            ?? .defaultSettings
        let localDisplayPreferences = ContextPanelLocations.companionWidgetDisplayPreferencesURL()
            .flatMap { WidgetDisplayPreferencesStore(preferencesURL: $0).loadIfAvailable() }
        return ContextPanelCompanionWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromCompanionSync(
                result,
                now: date,
                stalenessPolicy: stalenessPolicy
            ),
            displayPreferences: WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: localDisplayPreferences,
                synced: result.document?.widgetDisplayPreferences
            ),
            appearanceSettings: appearanceSettings
        )
    }
}

struct ContextPanelCompanionWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContextPanelCompanionWidgetEntry

    var body: some View {
        ContextPanelWidgetContentView(
            family: family,
            snapshot: entry.snapshot,
            displayPreferences: entry.displayPreferences,
            links: CompanionDeepLinks.links
        )
        .visionOSWidgetAppearance(entry.appearanceSettings)
    }
}

@main
struct ContextPanelCompanionWidget: Widget {
    let kind = ContextPanelCompanionWidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContextPanelCompanionTimelineProvider()) { entry in
            ContextPanelCompanionWidgetView(entry: entry)
                .containerBackground(companionWidgetBackground(entry.appearanceSettings), for: .widget)
        }
        .configurationDisplayName("Context Panel")
        .description("View AI usage limits synced from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }

    private func companionWidgetBackground(_ settings: CompanionAppearanceSettings) -> Color {
        #if os(visionOS)
        CPWTheme.surface(variant: settings.resolvedVisionOSWidgetAppearance.cpwThemeVariant)
        #else
        CPWTheme.surface
        #endif
    }
}

private extension View {
    @ViewBuilder
    func visionOSWidgetAppearance(_ settings: CompanionAppearanceSettings) -> some View {
        #if os(visionOS)
        let appearance = settings.resolvedVisionOSWidgetAppearance
        cpwThemeVariant(appearance.cpwThemeVariant)
            .environment(\.colorScheme, appearance.colorScheme)
            .preferredColorScheme(appearance.colorScheme)
        #else
        self
        #endif
    }
}

private extension CompanionVisionOSAppAppearance {
    var cpwThemeVariant: CPWThemeVariant {
        switch self {
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
