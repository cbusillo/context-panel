import ContextPanelCore
import ContextPanelWidgetUI
import SwiftUI
import WidgetKit

struct ContextPanelWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
}

private struct ContextPanelWidgetSelection {
    let entry: ContextPanelWidgetEntry
    let selectedSource: RuntimeReceiptSelectedSource
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
    let runtimeReceiptRecorder: RuntimeReceiptRecorder

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
        runtimeReceiptRecorder: RuntimeReceiptRecorder = .appDefault(surface: .macOSWidget)
    ) {
        self.store = store
        self.containerFallbackStore = containerFallbackStore
        self.preferencesStore = preferencesStore
        self.containerFallbackPreferencesStore = containerFallbackPreferencesStore
        self.forecastSettingsStore = forecastSettingsStore
        self.containerFallbackForecastSettingsStore = containerFallbackForecastSettingsStore
        self.accountStore = accountStore
        self.bookmarkStore = bookmarkStore
        self.runtimeReceiptRecorder = runtimeReceiptRecorder
    }

    func placeholder(in context: Context) -> ContextPanelWidgetEntry {
        ContextPanelWidgetEntry(date: Date(), snapshot: .placeholder, displayPreferences: .defaultPreferences)
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWidgetEntry) -> Void) {
        let selection = entrySelection(date: Date())
        recordRuntimeReceipt(
            selection,
            trigger: .widgetSnapshot,
            family: context.family
        )
        completion(selection.entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWidgetEntry>) -> Void) {
        let now = Date()
        let nextRefresh = now.addingTimeInterval(SnapshotFreshness.widgetTimelineInterval)
        let selection = timelineSelection(date: now)
        recordRuntimeReceipt(
            selection.current,
            trigger: .widgetTimeline,
            family: context.family
        )
        completion(Timeline(entries: selection.entries, policy: .after(nextRefresh)))
    }

    func timelineEntries(date: Date) -> [ContextPanelWidgetEntry] {
        timelineSelection(date: date).entries
    }

    private func timelineSelection(
        date: Date
    ) -> (entries: [ContextPanelWidgetEntry], current: ContextPanelWidgetSelection) {
        let policy = SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
        let current = entrySelection(date: date, stalenessPolicy: policy)
        let currentEntry = current.entry
        guard currentEntry.snapshot.state == .ready else { return ([currentEntry], current) }
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
        let entries = [currentEntry] + transitionDates.map {
            entry(date: $0, stalenessPolicy: policy)
        }
        return (entries, current)
    }

    func entry(date: Date) -> ContextPanelWidgetEntry {
        entry(
            date: date,
            stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                maximumAge: SnapshotFreshness.widgetMaximumAge
            )
        )
    }

    private func entrySelection(date: Date) -> ContextPanelWidgetSelection {
        entrySelection(
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
        entrySelection(date: date, stalenessPolicy: policy).entry
    }

    private func entrySelection(
        date: Date,
        stalenessPolicy policy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelWidgetSelection {
        let displayPreferences = loadDisplayPreferences()
        let forecastSettings = loadForecastSettings()
        let promptCacheWidgetState = WidgetSnapshot.promptCacheWidgetState(
            accountStore: accountStore,
            bookmarkStore: bookmarkStore,
            now: date
        )
        let result = store.loadCurrent(policy: policy, now: date)
        if result.snapshot == nil || result.status == .failure {
            let fallback = containerFallbackStore.loadCurrent(
                policy: policy,
                now: date
            )
            if fallback.snapshot != nil {
                return ContextPanelWidgetSelection(
                    entry: ContextPanelWidgetEntry(
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
                    ),
                    selectedSource: .widgetSandboxMirror
                )
            }
        }
        return ContextPanelWidgetSelection(
            entry: ContextPanelWidgetEntry(
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
            ),
            selectedSource: result.snapshot == nil ? .none : .appGroupSnapshot
        )
    }

    private func recordRuntimeReceipt(
        _ selection: ContextPanelWidgetSelection,
        trigger: RuntimeReceiptTrigger,
        family: WidgetFamily
    ) {
        let stateBranch: RuntimeReceiptStateBranch = switch selection.entry.snapshot.state {
        case .ready:
            .ready
        case .setupNeeded:
            .setupNeeded
        case .stale:
            .stale
        case .failure:
            .failure
        }
        let outcome: RuntimeReceiptOutcome = switch stateBranch {
        case .ready:
            .success
        case .failure:
            .failure
        case .setupNeeded, .stale, .unknown, .refreshed, .skippedFresh,
             .skippedAlreadyRunning, .skippedNoReports:
            .degraded
        }
        let presentationMode = runtimePresentationMode(for: family)
        runtimeReceiptRecorder.record(
            trigger: trigger,
            presentationMode: presentationMode,
            selectedSource: selection.selectedSource,
            presentationDigest: RuntimePresentationDigest.widgetSnapshot(
                selection.entry.snapshot,
                displayPreferences: selection.entry.displayPreferences,
                presentationMode: presentationMode,
                presentationDate: selection.entry.date
            ),
            stateBranch: stateBranch,
            outcome: outcome,
            observedAt: selection.entry.date
        )
    }

    private func runtimePresentationMode(
        for family: WidgetFamily
    ) -> RuntimeReceiptPresentationMode {
        switch family {
        case .systemSmall:
            .widgetSystemSmall
        case .systemMedium:
            .widgetSystemMedium
        case .systemLarge:
            .widgetSystemLarge
        default:
            .widgetUnknown
        }
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
            links: ContextPanelWidgetURL.links,
            showsResetCreditSurfaces: true,
            presentationDate: entry.date
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
