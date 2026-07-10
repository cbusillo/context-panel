import ContextPanelCloudKitSync
import ContextPanelCore
import SwiftUI
import WidgetKit

struct ContextPanelWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
}

struct ContextPanelWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextPanelWatchWidgetEntry {
        let date = Date()
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: placeholderSnapshot(date: date),
            displayPreferences: .defaultPreferences
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWatchWidgetEntry) -> Void) {
        let completion = WidgetCompletion(completion)
        Task {
            completion.call(await entry(date: Date()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWatchWidgetEntry>) -> Void) {
        let date = Date()
        let completion = WidgetCompletion(completion)
        Task {
            completion.call(Timeline(
                entries: [await entry(date: date)],
                policy: .after(date.addingTimeInterval(15 * 60))
            ))
        }
    }

    private func entry(date: Date) async -> ContextPanelWatchWidgetEntry {
        let presentationPreferencesStore = WidgetDisplayPreferencesStore(
            preferencesURL: ContextPanelLocations.watchPresentationPreferencesCacheURL()
        )
        let cachedDisplayPreferences = presentationPreferencesStore.loadIfAvailable()
        async let loadedSnapshot = CompanionCloudKitSyncStoreFactory.make().load(now: date)
        async let loadedPresentation = CompanionCloudKitSyncStoreFactory.makePresentationPreferences().load()
        let result = await loadedSnapshot.result
        let presentationDocument = await loadedPresentation.document
        if let presentationPreferences = presentationDocument?.widgetDisplayPreferences {
            try? presentationPreferencesStore.save(presentationPreferences)
        }
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromCompanionSync(
                result,
                now: date,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            ),
            displayPreferences: WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: presentationDocument?.widgetDisplayPreferences ?? cachedDisplayPreferences,
                synced: result.document?.widgetDisplayPreferences
            )
        )
    }

    private func placeholderSnapshot(date: Date) -> WidgetSnapshot {
        WidgetSnapshot(
            state: .setupNeeded,
            generatedAt: date,
            limits: [],
            status: .unknown,
            message: "Waiting for Mac sync."
        )
    }
}

private struct WidgetCompletion<Value>: @unchecked Sendable {
    private let completion: (Value) -> Void

    init(_ completion: @escaping (Value) -> Void) {
        self.completion = completion
    }

    func call(_ value: Value) {
        completion(value)
    }
}

struct ContextPanelWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: ContextPanelWatchWidgetEntry

    private var limit: WatchLimitDisplay? {
        limits(maximumCount: 1).first
    }

    private var rectangularLimits: [WatchLimitDisplay] {
        limits(maximumCount: 2)
    }

    private func limits(maximumCount: Int) -> [WatchLimitDisplay] {
        WatchLimitDisplay.mainLaneRows(
            from: entry.snapshot,
            preferences: entry.displayPreferences,
            maximumCount: maximumCount
        )
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchCircularComplication(limit: limit, snapshot: entry.snapshot)
        case .accessoryRectangular:
            WatchRectangularComplication(limits: rectangularLimits, snapshot: entry.snapshot)
        case .accessoryInline:
            WatchInlineComplication(limit: limit, snapshot: entry.snapshot)
        case .accessoryCorner:
            WatchCornerComplication(limit: limit, snapshot: entry.snapshot)
        default:
            WatchRectangularComplication(limits: rectangularLimits, snapshot: entry.snapshot)
        }
    }
}

struct WatchCircularComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    var body: some View {
        Gauge(value: limit?.pressureRatio ?? 0) {
            Image(systemName: symbol)
        } currentValueLabel: {
            Text(limit?.remainingText ?? "--")
                .minimumScaleFactor(0.55)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tint)
    }

    private var symbol: String {
        limit == nil ? "icloud.slash" : "gauge.with.dots.needle.bottom.50percent"
    }

    private var tint: Color {
        limit.map { watchStatusColor($0.status) } ?? watchStatusColor(snapshot.status)
    }
}

struct WatchRectangularComplication: View {
    let limits: [WatchLimitDisplay]
    let snapshot: WidgetSnapshot

    var body: some View {
        if !limits.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(limits) { limit in
                    WatchRectangularLimitLine(limit: limit)
                }
            }
        } else {
            Label(emptyText, systemImage: "icloud.and.arrow.down")
                .font(.caption)
                .lineLimit(2)
        }
    }

    private var emptyText: String {
        snapshot.state == .failure ? "Sync failed" : "Sync Mac"
    }
}

private struct WatchRectangularLimitLine: View {
    let limit: WatchLimitDisplay

    var body: some View {
        HStack(spacing: 4) {
            Text(limit.title)
            Text(limit.subtitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: 2)
            WatchMiniPressureBar(value: limit.pressureRatio, tint: watchStatusColor(limit.status))
                .frame(width: 26, height: 3)
            Text(limit.remainingText)
                .foregroundStyle(watchStatusColor(limit.status))
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

private struct WatchMiniPressureBar: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.tertiary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * min(max(value, 0), 1))
                }
        }
    }
}

struct WatchInlineComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    var body: some View {
        if let limit {
            Text("\(limit.title) \(limit.subtitle) \(limit.remainingText)")
        } else {
            Text(snapshot.state == .failure ? "Context Panel sync failed" : "Context Panel needs sync")
        }
    }
}

struct WatchCornerComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    var body: some View {
        Text(limit?.remainingText ?? "--")
            .widgetCurvesContent()
            .widgetLabel {
                Gauge(value: limit?.pressureRatio ?? 0) {
                    Text(limit?.title ?? "Sync")
                }
                .tint(limit.map { watchStatusColor($0.status) } ?? watchStatusColor(snapshot.status))
            }
    }
}

struct ContextPanelWatchWidget: Widget {
    let kind = "ContextPanelWatchWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContextPanelWatchWidgetProvider()) { entry in
            ContextPanelWatchWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Context Panel")
        .description("Shows the tightest AI usage limit from your Mac sync.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct ContextPanelWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContextPanelWatchWidget()
    }
}

private func watchStatusColor(_ status: UsageStatus) -> Color {
    switch status {
    case .healthy:
        .green
    case .close:
        .yellow
    case .limited, .failure:
        .red
    case .stale, .unknown, .loading:
        .secondary
    }
}
