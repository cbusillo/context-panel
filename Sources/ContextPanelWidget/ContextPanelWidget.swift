import ContextPanelCore
import ContextPanelWidgetUI
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
    let preferencesStore: WidgetDisplayPreferencesStore
    let containerFallbackPreferencesStore: WidgetDisplayPreferencesStore
    let forecastSettingsStore: FastModeForecastSettingsStore
    let containerFallbackForecastSettingsStore: FastModeForecastSettingsStore
    let accountStore: AccountConfigurationStore
    let bookmarkStore: SecureFileBookmarkStore

    init(
        store: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackStore: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.widgetSandboxLocalSnapshotDirectory()
        ),
        preferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackPreferencesStore: WidgetDisplayPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.widgetSandboxLocalDisplayPreferencesURL()
        ),
        forecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
        ),
        containerFallbackForecastSettingsStore: FastModeForecastSettingsStore = FastModeForecastSettingsStore(
            settingsURL: ContextPanelLocations.widgetSandboxLocalFastModeForecastSettingsURL()
        ),
        accountStore: AccountConfigurationStore = AccountConfigurationStore(
            configurationURL: ContextPanelLocations.accountConfigurationURL(),
            fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
        ),
        bookmarkStore: SecureFileBookmarkStore = SecureFileBookmarkStore(
            storeURL: ContextPanelLocations.bookmarkStoreURL()
        )
    ) {
        self.store = store
        self.containerFallbackStore = containerFallbackStore
        self.preferencesStore = preferencesStore
        self.containerFallbackPreferencesStore = containerFallbackPreferencesStore
        self.forecastSettingsStore = forecastSettingsStore
        self.containerFallbackForecastSettingsStore = containerFallbackForecastSettingsStore
        self.accountStore = accountStore
        self.bookmarkStore = bookmarkStore
    }

    func placeholder(in context: Context) -> ContextPanelWidgetEntry {
        ContextPanelWidgetEntry(date: Date(), snapshot: .placeholder, displayPreferences: .defaultPreferences)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWidgetEntry) -> Void) {
        completion(entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWidgetEntry>) -> Void) {
        let now = Date()
        let nextRefresh = now.addingTimeInterval(SnapshotFreshness.widgetTimelineInterval)
        completion(Timeline(entries: [entry(date: now)], policy: .after(nextRefresh)))
    }

    func entry(date: Date) -> ContextPanelWidgetEntry {
        let displayPreferences = loadDisplayPreferences()
        let forecastSettings = loadForecastSettings()
        let promptCacheWidgetState = WidgetSnapshot.promptCacheWidgetState(
            accountStore: accountStore,
            bookmarkStore: bookmarkStore,
            now: date
        )
        let policy = SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
        let result = store.loadCurrent(policy: policy, now: date)
        if result.snapshot == nil || result.status == .failure {
            let fallback = containerFallbackStore.loadCurrent(
                policy: policy,
                now: date
            )
            if fallback.snapshot != nil {
                return ContextPanelWidgetEntry(
                    date: date,
                    snapshot: WidgetSnapshot.fromStore(
                        fallback,
                        now: date,
                        history: containerFallbackStore.loadHistory(),
                        fastModeForecastSettings: forecastSettings,
                        promptCacheWidgetState: promptCacheWidgetState,
                        stalenessPolicy: policy
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
                fastModeForecastSettings: forecastSettings,
                promptCacheWidgetState: promptCacheWidgetState,
                stalenessPolicy: policy
            ),
            displayPreferences: displayPreferences
        )
    }

    private func loadDisplayPreferences() -> WidgetDisplayPreferences {
        WidgetDisplayPreferencesStoreSet(stores: [
            preferencesStore,
            containerFallbackPreferencesStore,
        ]).load()
    }

    private func loadForecastSettings() -> FastModeForecastSettings {
        for store in [forecastSettingsStore, containerFallbackForecastSettingsStore] {
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
        ContextPanelWidgetContentView(
            family: family,
            snapshot: entry.snapshot,
            displayPreferences: entry.displayPreferences,
            links: ContextPanelWidgetURL.links
        )
    }
}

enum ContextPanelWidgetURL {
    static let overview = URL(string: "contextpanel://overview")!
    static let reconnect = URL(string: "contextpanel://reconnect")!
    static let cacheStatsSettings = URL(string: "contextpanel://settings/cache-stats")!
    static let links = ContextPanelWidgetLinks(
        overview: overview,
        reconnect: reconnect,
        cacheStatsSettings: cacheStatsSettings
    )
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
        .description("Track AI usage limits, reset windows, and fast-mode status at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

extension WidgetSnapshot {
    static var placeholder: WidgetSnapshot {
        return WidgetSnapshot(
            state: .setupNeeded,
            generatedAt: Date(),
            limits: [],
            status: .unknown,
            message: "Set up Context Panel in the app."
        )
    }
}
