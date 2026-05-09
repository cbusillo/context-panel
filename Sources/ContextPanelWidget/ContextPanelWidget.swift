import ContextPanelCore
import SwiftUI
import WidgetKit

struct ContextPanelWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
}

struct ContextPanelTimelineProvider: TimelineProvider {
    let store: JSONSnapshotStore
    let containerFallbackStore: JSONSnapshotStore
    let hostFallbackStore: JSONSnapshotStore
    let fallbackStore: JSONSnapshotStore
    let preferencesStore: WidgetDisplayPreferencesStore
    let containerFallbackPreferencesStore: WidgetDisplayPreferencesStore
    let hostFallbackPreferencesStore: WidgetDisplayPreferencesStore
    let fallbackPreferencesStore: WidgetDisplayPreferencesStore
    let forecastSettingsStore: FastModeForecastSettingsStore
    let containerFallbackForecastSettingsStore: FastModeForecastSettingsStore
    let hostFallbackForecastSettingsStore: FastModeForecastSettingsStore
    let fallbackForecastSettingsStore: FastModeForecastSettingsStore

    init(
        store: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackStore: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.widgetDevelopmentContainerSnapshotDirectory()
        ),
        hostFallbackStore: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.hostDevelopmentSnapshotDirectory()
        ),
        fallbackStore: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.widgetDevelopmentSnapshotDirectory()
        ),
        preferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackPreferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.widgetDevelopmentContainerDisplayPreferencesURL()
        ),
        hostFallbackPreferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.hostDevelopmentDisplayPreferencesURL()
        ),
        fallbackPreferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.widgetDevelopmentDisplayPreferencesURL()
        ),
        forecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackForecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.widgetDevelopmentContainerFastModeForecastSettingsURL()
        ),
        hostFallbackForecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.hostDevelopmentFastModeForecastSettingsURL()
        ),
        fallbackForecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.widgetDevelopmentFastModeForecastSettingsURL()
        )
    ) {
        self.store = store
        self.containerFallbackStore = containerFallbackStore
        self.hostFallbackStore = hostFallbackStore
        self.fallbackStore = fallbackStore
        self.preferencesStore = preferencesStore
        self.containerFallbackPreferencesStore = containerFallbackPreferencesStore
        self.hostFallbackPreferencesStore = hostFallbackPreferencesStore
        self.fallbackPreferencesStore = fallbackPreferencesStore
        self.forecastSettingsStore = forecastSettingsStore
        self.containerFallbackForecastSettingsStore = containerFallbackForecastSettingsStore
        self.hostFallbackForecastSettingsStore = hostFallbackForecastSettingsStore
        self.fallbackForecastSettingsStore = fallbackForecastSettingsStore
    }

    func placeholder(in context: Context) -> ContextPanelWidgetEntry {
        ContextPanelWidgetEntry(date: Date(), snapshot: .placeholder, displayPreferences: .defaultPreferences)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWidgetEntry) -> Void) {
        completion(entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWidgetEntry>) -> Void) {
        let now = Date()
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 10, to: now) ?? now.addingTimeInterval(600)
        completion(Timeline(entries: [entry(date: now)], policy: .after(nextRefresh)))
    }

    private func entry(date: Date) -> ContextPanelWidgetEntry {
        let displayPreferences = loadDisplayPreferences()
        let forecastSettings = loadForecastSettings()
        let result = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 20 * 60), now: date)
        if result.snapshot == nil || result.status == .failure {
            for fallbackStore in [containerFallbackStore, hostFallbackStore, fallbackStore] {
                let fallback = fallbackStore.loadCurrent(
                    policy: SnapshotStoreStalenessPolicy(maximumAge: 20 * 60),
                    now: date
                )
                guard fallback.snapshot != nil else { continue }
                return ContextPanelWidgetEntry(
                    date: date,
                    snapshot: WidgetSnapshot.fromStore(
                        fallback,
                        now: date,
                        history: fallbackStore.loadHistory(),
                        fastModeForecastSettings: forecastSettings
                    ),
                    displayPreferences: displayPreferences
                )
            }
        }
        return ContextPanelWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromStore(
                result,
                now: date,
                history: store.loadHistory(),
                fastModeForecastSettings: forecastSettings
            ),
            displayPreferences: displayPreferences
        )
    }

    private func loadDisplayPreferences() -> WidgetDisplayPreferences {
        for store in [
            preferencesStore,
            containerFallbackPreferencesStore,
            hostFallbackPreferencesStore,
            fallbackPreferencesStore,
        ] {
            if let preferences = store.loadIfAvailable() {
                return preferences
            }
        }
        return .defaultPreferences
    }

    private func loadForecastSettings() -> FastModeForecastSettings {
        for store in [
            forecastSettingsStore,
            containerFallbackForecastSettingsStore,
            hostFallbackForecastSettingsStore,
            fallbackForecastSettingsStore,
        ] {
            if let settings = store.loadIfAvailable() {
                return settings
            }
        }
        return .defaultSettings
    }
}

struct ContextPanelWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ContextPanelWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            ContextPanelSmallWidget(snapshot: entry.snapshot)
        case .systemLarge, .systemExtraLarge:
            ContextPanelLargeWidget(snapshot: entry.snapshot, displayPreferences: entry.displayPreferences)
        default:
            ContextPanelMediumWidget(snapshot: entry.snapshot, displayPreferences: entry.displayPreferences)
        }
    }
}

@main
struct ContextPanelWidget: Widget {
    let kind = "ContextPanelWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContextPanelTimelineProvider()) { entry in
            ContextPanelWidgetView(entry: entry)
                .containerBackground(CPWTheme.surface, for: .widget)
        }
        .configurationDisplayName("Context Panel")
        .description("AI account usage limits, reset timing, and fast-mode safety from local snapshots.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

extension WidgetSnapshot {
    static var placeholder: WidgetSnapshot {
        let now = Date()
        return WidgetSnapshot(
            state: .ready,
            generatedAt: now,
            limits: [
                UsageLimit(
                    provider: .openAI,
                    accountID: "placeholder-openai",
                    accountName: "OpenAI",
                    label: "Codex Weekly",
                    windowLabel: "Weekly",
                    modelLabel: "Codex",
                    unit: .percent,
                    used: 52,
                    limit: 100,
                    resetsAt: now.addingTimeInterval(18_000),
                    lastUpdatedAt: now.addingTimeInterval(-90),
                    confidence: .observed
                ),
                UsageLimit(
                    provider: .google,
                    accountID: "placeholder-google",
                    accountName: "Gemini",
                    label: "gemini-3-pro-preview",
                    windowLabel: "Daily",
                    modelLabel: "gemini-3-pro-preview",
                    unit: .percent,
                    used: 12,
                    limit: 100,
                    resetsAt: now.addingTimeInterval(86_400),
                    lastUpdatedAt: now.addingTimeInterval(-90),
                    confidence: .observed
                ),
            ],
            status: .healthy,
            message: "Fast mode looks safe."
        )
    }
}
