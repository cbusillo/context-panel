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
            message: "Waiting for your Mac."
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

    private var inlineLimits: [WatchLimitDisplay] {
        WatchLimitDisplay.inlineRows(
            from: entry.snapshot,
            preferences: entry.displayPreferences
        )
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
            WatchInlineComplication(limits: inlineLimits, snapshot: entry.snapshot)
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

    @ViewBuilder
    var body: some View {
        if let limit, let ratio = limit.remainingCapacity.ratio {
            Gauge(value: ratio) {
                EmptyView()
            } currentValueLabel: {
                Text(limit.remainingText)
                    .minimumScaleFactor(0.55)
                    .overlay(alignment: .bottomTrailing) {
                        if let symbol = watchExceptionalStatusSymbol(limit.status) {
                            Image(systemName: symbol)
                                .font(.system(size: 7, weight: .semibold))
                                .offset(x: 3, y: 3)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.accessibilitySentence(direction: .remaining))
        } else {
            ZStack {
                Circle()
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: fallbackSymbol)
                    .font(.caption2.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                limit?.accessibilitySentence(direction: .remaining)
                    ?? watchEmptyText(for: snapshot, compact: false)
            )
        }
    }

    private var fallbackSymbol: String {
        guard limit == nil else { return "questionmark" }
        return snapshot.state == .ready || snapshot.state == .stale ? "eye.slash" : "icloud.slash"
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
        watchEmptyText(for: snapshot, compact: true)
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
            WatchMiniCapacityBar(metric: limit.remainingCapacity, tint: watchStatusColor(limit.status))
                .frame(width: 26, height: 3)
            Text(limit.remainingComplicationText)
                .foregroundStyle(watchStatusColor(limit.status))
                .layoutPriority(1)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.accessibilitySentence(direction: .remaining))
    }
}

private struct WatchMiniCapacityBar: View {
    let metric: MetricProgress
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            if let ratio = metric.ratio {
                ZStack(alignment: .leading) {
                    Capsule().fill(.tertiary)
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * ratio)
                }
            } else {
                Capsule()
                    .stroke(tint, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
    }
}

struct WatchInlineComplication: View {
    let limits: [WatchLimitDisplay]
    let snapshot: WidgetSnapshot

    private var primary: WatchLimitDisplay? {
        limits.first
    }

    var body: some View {
        if let primary {
            ViewThatFits(in: .horizontal) {
                if limits.count > 1 {
                    Text(twoLimitText(primary: primary, secondary: limits[1]))
                        .accessibilityLabel(
                            primary.accessibilitySentence(direction: .remaining)
                                + ". "
                                + limits[1].accessibilitySentence(direction: .remaining)
                        )
                }
                Text("\(primary.title) \(primary.subtitle) · \(primary.remainingInlineText)")
                    .accessibilityLabel(primary.accessibilitySentence(direction: .remaining))
            }
        } else {
            Text(watchEmptyText(for: snapshot, compact: false))
        }
    }

    private func twoLimitText(
        primary: WatchLimitDisplay,
        secondary: WatchLimitDisplay
    ) -> String {
        let secondaryProvider = primary.provider == secondary.provider
            ? ""
            : "\(secondary.provider.shortName) "
        return "\(primary.provider.shortName) \(primary.subtitle) \(primary.compactInlineQuantity) left"
            + " · \(secondaryProvider)\(secondary.subtitle) \(secondary.compactInlineQuantity)"
    }
}

struct WatchCornerComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    @ViewBuilder
    var body: some View {
        if let limit, let ratio = limit.remainingCapacity.ratio {
            Text(limit.remainingText)
                .widgetCurvesContent()
                .widgetLabel {
                    Gauge(value: ratio) {
                        Text(
                            limit.exceptionalStatusText.map { "\(limit.title) \($0)" }
                                ?? limit.title
                        )
                    }
                    .tint(watchStatusColor(limit.status))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(limit.accessibilitySentence(direction: .remaining))
        } else {
            Text("—")
                .widgetCurvesContent()
                .widgetLabel {
                    Text(limit?.title ?? watchEmptyText(for: snapshot, compact: true))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    limit?.accessibilitySentence(direction: .remaining)
                        ?? watchEmptyText(for: snapshot, compact: false)
                )
                .foregroundStyle(limit.map { watchStatusColor($0.status) } ?? watchStatusColor(snapshot.status))
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
        .description("Shows remaining capacity for the AI usage limits you chose.")
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
    case .stale:
        .orange
    case .unknown, .loading:
        .secondary
    }
}

private func watchEmptyText(for snapshot: WidgetSnapshot, compact: Bool) -> String {
    switch snapshot.state {
    case .ready, .stale:
        compact ? "No limits" : "No limits selected"
    case .failure:
        compact ? "Sync failed" : "Context Panel sync failed"
    case .setupNeeded:
        compact ? "Sync Mac" : "Context Panel needs sync"
    }
}

private func watchExceptionalStatusSymbol(_ status: UsageStatus) -> String? {
    switch status {
    case .stale:
        "clock"
    case .failure:
        "exclamationmark"
    case .loading:
        "arrow.clockwise"
    case .healthy, .close, .limited, .unknown:
        nil
    }
}
