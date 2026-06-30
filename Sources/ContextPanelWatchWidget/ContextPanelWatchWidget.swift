import ContextPanelCloudKitSync
import ContextPanelCore
import SwiftUI
import WidgetKit

struct ContextPanelWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ContextPanelWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextPanelWatchWidgetEntry {
        let date = Date()
        return ContextPanelWatchWidgetEntry(date: date, snapshot: placeholderSnapshot(date: date))
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
        let result = await CompanionCloudKitSyncStoreFactory.make().load(now: date).result
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromCompanionSync(
                result,
                now: date,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
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
        WatchLimitDisplay.rows(from: entry.snapshot, maximumCount: 1).first
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchCircularComplication(limit: limit, snapshot: entry.snapshot)
        case .accessoryRectangular:
            WatchRectangularComplication(limit: limit, snapshot: entry.snapshot)
        case .accessoryInline:
            WatchInlineComplication(limit: limit, snapshot: entry.snapshot)
        case .accessoryCorner:
            WatchCornerComplication(limit: limit, snapshot: entry.snapshot)
        default:
            WatchRectangularComplication(limit: limit, snapshot: entry.snapshot)
        }
    }
}

struct WatchCircularComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    var body: some View {
        Gauge(value: limit?.capacityRatio ?? 0) {
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
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    var body: some View {
        if let limit {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(limit.title)
                    Text(limit.subtitle)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(limit.remainingText)
                        .foregroundStyle(watchStatusColor(limit.status))
                }
                .font(.caption.weight(.semibold))
                .lineLimit(1)

                ProgressView(value: limit.capacityRatio)
                    .tint(watchStatusColor(limit.status))

                Text(limit.context)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                Gauge(value: limit?.capacityRatio ?? 0) {
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
