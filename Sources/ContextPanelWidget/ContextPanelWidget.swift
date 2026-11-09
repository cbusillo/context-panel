import ContextPanelCore
import ContextPanelWidgetUI
import SwiftUI
import WidgetKit
import os

private let widgetTimelineLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "widget-timeline")

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
    let historyLoader: (JSONSnapshotStore, SnapshotStoreQuery) -> [StoredUsageSnapshot]

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
        ),
        historyLoader: @escaping (JSONSnapshotStore, SnapshotStoreQuery) -> [StoredUsageSnapshot] = {
            $0.loadHistory(query: $1)
        }
    ) {
        self.store = store
        self.containerFallbackStore = containerFallbackStore
        self.preferencesStore = preferencesStore
        self.containerFallbackPreferencesStore = containerFallbackPreferencesStore
        self.forecastSettingsStore = forecastSettingsStore
        self.containerFallbackForecastSettingsStore = containerFallbackForecastSettingsStore
        self.accountStore = accountStore
        self.bookmarkStore = bookmarkStore
        self.historyLoader = historyLoader
    }

    func placeholder(in context: Context) -> ContextPanelWidgetEntry {
        ContextPanelWidgetEntry(date: Date(), snapshot: .placeholder, displayPreferences: .defaultPreferences)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWidgetEntry) -> Void) {
        completion(entry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWidgetEntry>) -> Void) {
        let now = Date()
        widgetTimelineLogger.info("Timeline request started")
        let nextRefresh = now.addingTimeInterval(SnapshotFreshness.widgetTimelineInterval)
        let entries = timelineEntries(date: now)
        widgetTimelineLogger.notice("Timeline prepared: entries=\(entries.count, privacy: .public) elapsed-seconds=\(Date().timeIntervalSince(now), privacy: .public) snapshot-age-seconds=\(now.timeIntervalSince(entries[0].snapshot.generatedAt), privacy: .public)")
        completion(Timeline(entries: entries, policy: .after(nextRefresh)))
    }

    func timelineEntries(date: Date) -> [ContextPanelWidgetEntry] {
        let policy = SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
        var historyCache: [URL: [StoredUsageSnapshot]] = [:]
        let currentEntry = entry(date: date, stalenessPolicy: policy, historyCache: &historyCache)
        guard currentEntry.snapshot.state == .ready else { return [currentEntry] }
        let staleTransition = policy.nextStaleTransitionDate(
            for: currentEntry.snapshot.usageSnapshot,
            now: date
        )
        let ageTransition = policy.nextAgeStaleTransitionDate(
            for: currentEntry.snapshot.usageSnapshot,
            now: date
        )
        let resetTransitions = currentEntry.snapshot.resetCreditSurfaceTransitionDates(now: date).filter {
            guard let ageTransition else { return true }
            return $0 <= ageTransition
        }
        let transitionDates = Set(
            [staleTransition].compactMap { $0 } + resetTransitions
        ).filter { $0 > date }.sorted()
        return [currentEntry] + transitionDates.map {
            entry(date: $0, stalenessPolicy: policy, cacheValidationDate: date, historyCache: &historyCache)
        }
    }

    func entry(date: Date) -> ContextPanelWidgetEntry {
        entry(
            date: date,
            stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                maximumAge: SnapshotFreshness.widgetMaximumAge
            )
        )
    }

    private func entry(
        date: Date,
        stalenessPolicy policy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelWidgetEntry {
        var historyCache: [URL: [StoredUsageSnapshot]] = [:]
        return entry(date: date, stalenessPolicy: policy, historyCache: &historyCache)
    }

    private func entry(
        date: Date,
        stalenessPolicy policy: SnapshotStoreStalenessPolicy,
        cacheValidationDate: Date? = nil,
        historyCache: inout [URL: [StoredUsageSnapshot]]
    ) -> ContextPanelWidgetEntry {
        let displayPreferences = loadDisplayPreferences()
        let forecastSettings = loadForecastSettings()
        let promptCacheWidgetState = WidgetSnapshot.promptCacheWidgetState(
            accountStore: accountStore,
            bookmarkStore: bookmarkStore,
            now: date
        )
        let configurationDocument = (try? Data(contentsOf: accountStore.configurationURL)).flatMap {
            try? JSONDecoder.contextPanelISO8601.decode(AccountConfigurationDocument.self, from: $0)
        }
        let configuration = configurationDocument?.accounts
        let sharedDocument = MacSharedAccountCache(cacheURL: accountStore.configurationURL.deletingLastPathComponent().appending(path: MacSharedAccountCache.filename)).load(now: cacheValidationDate ?? date)
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
                        history: loadForecastHistory(store: containerFallbackStore, result: fallback,
                            date: cacheValidationDate ?? date, cache: &historyCache),
                        fastModeForecastSettings: forecastSettings,
                        promptCacheWidgetState: promptCacheWidgetState,
                        stalenessPolicy: policy,
                        configuration: configuration, sharedDocument: sharedDocument, publisherID: configurationDocument?.publisherID, accountIntentDocument: configurationDocument,
                        receipts: LaunchReceiptStore.load(rootDirectory: accountStore.configurationURL.deletingLastPathComponent(), now: date)
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
                history: loadForecastHistory(store: store, result: result,
                    date: cacheValidationDate ?? date, cache: &historyCache),
                fastModeForecastSettings: forecastSettings,
                promptCacheWidgetState: promptCacheWidgetState,
                stalenessPolicy: policy,
                configuration: configuration, sharedDocument: sharedDocument, publisherID: configurationDocument?.publisherID, accountIntentDocument: configurationDocument,
                receipts: LaunchReceiptStore.load(rootDirectory: accountStore.configurationURL.deletingLastPathComponent(), now: date)
            ),
            displayPreferences: displayPreferences
        )
    }

    private func loadForecastHistory(
        store: JSONSnapshotStore,
        result: SnapshotStoreLoadResult,
        date: Date,
        cache: inout [URL: [StoredUsageSnapshot]]
    ) -> [StoredUsageSnapshot] {
        guard let snapshot = result.snapshot else { return [] }
        if let history = cache[store.rootDirectory] { return history }
        // Forecasts use a rolling window, including when an old snapshot is shown.
        // Reuse that window for every future entry instead of decoding the archive again.
        let start = min(date, snapshot.snapshot.generatedAt)
            .addingTimeInterval(-MainLimitBurnRateEstimator.historyLookback)
        let history = historyLoader(store, SnapshotStoreQuery(since: start))
        cache[store.rootDirectory] = history
        return history
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
            links: ContextPanelWidgetURL.links,
            showsResetCreditSurfaces: true,
            presentationDate: entry.date
        )
    }
}

enum ContextPanelWidgetURL {
    static let overview = URL(string: "contextpanel://overview")!
    static let links = ContextPanelWidgetLinks(overview: overview)
}

@main
struct ContextPanelWidget: Widget {
    let kind = ContextPanelWidgetIdentity.kind

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
