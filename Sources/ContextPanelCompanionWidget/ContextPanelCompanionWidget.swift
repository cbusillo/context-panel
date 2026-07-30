import ContextPanelCloudKitSync
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
        CompanionWidgetLoadQueue.loadTimeline(date: Date(), completion: completion)
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
    private static let remoteStore = CompanionCloudKitSyncStoreFactory.make()

    static func load(date: Date, completion: @escaping (ContextPanelCompanionWidgetEntry) -> Void) {
        let completion = CompanionWidgetCompletion(completion)
        queue.async {
            completion.call(entry(
                date: date,
                result: CompanionSyncLoader.loadWidgetMirror(now: date),
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                    maximumAge: SnapshotFreshness.companionProviderMaximumAge
                )
            ))
        }
    }

    static func loadTimeline(
        date: Date,
        completion: @escaping (Timeline<ContextPanelCompanionWidgetEntry>) -> Void
    ) {
        let completion = CompanionWidgetCompletion(completion)
        Task.detached(priority: .utility) {
            let policy = SnapshotStoreStalenessPolicy.appDefault(
                maximumAge: SnapshotFreshness.companionProviderMaximumAge
            )
            let result = await CompanionSyncLoader.loadWidgetTimeline(
                remoteStore: remoteStore,
                now: date
            )
            let currentEntry = entry(date: date, result: result, stalenessPolicy: policy)
            let settings = ContextPanelLocations.companionRefreshSettingsURL()
                .map { CompanionRefreshSettingsStore(settingsURL: $0).load() }
                ?? .defaultSettings
            let refreshInterval = shouldRetrySoon(result)
                ? SnapshotFreshness.widgetTimelineInterval
                : settings.widgetInterval
            let refreshPolicy = TimelineReloadPolicy.after(date.addingTimeInterval(refreshInterval))
            guard currentEntry.snapshot.state == .ready else {
                completion.call(Timeline(entries: [currentEntry], policy: refreshPolicy))
                return
            }
            let staleTransition = policy.nextStaleTransitionDate(
                for: currentEntry.snapshot.usageSnapshot,
                now: date
            )
            let ageTransition = policy.nextAgeStaleTransitionDate(
                for: currentEntry.snapshot.usageSnapshot,
                now: date
            )
            let resetTransitions = currentEntry.snapshot.resetCreditSurfaceTransitionDates(
                now: date,
                maximumAge: SnapshotFreshness.companionProviderMaximumAge
            ).filter {
                guard let ageTransition else { return true }
                return $0 <= ageTransition
            }
            let transitionDates = Set(
                [staleTransition].compactMap { $0 } + resetTransitions
            ).filter { $0 > date }.sorted()
            guard !transitionDates.isEmpty else {
                completion.call(Timeline(entries: [currentEntry], policy: refreshPolicy))
                return
            }
            completion.call(Timeline(
                entries: [currentEntry] + transitionDates.map {
                    entry(date: $0, result: result, stalenessPolicy: policy)
                },
                policy: refreshPolicy
            ))
        }
    }

    private static func entry(
        date: Date,
        result: CompanionSyncLoadResult,
        stalenessPolicy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelCompanionWidgetEntry {
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

    private static func shouldRetrySoon(_ result: CompanionSyncLoadResult) -> Bool {
        result.document == nil
            || result.status == .failure
            || result.status == .stale
            || result.transportStatuses.contains(where: \.missingRecord)
            || result.transportStatuses.contains { !$0.succeeded }
    }
}

private final class CompanionWidgetCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func call(_ value: Value) {
        completion(value)
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
            links: CompanionDeepLinks.widgetLinks,
            showsResetCreditSurfaces: true,
            resetCreditMaximumAge: SnapshotFreshness.companionProviderMaximumAge,
            presentationDate: entry.date
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
