import ContextPanelCore
import SwiftUI
import WidgetKit

struct ContextPanelWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct ContextPanelTimelineProvider: TimelineProvider {
    let store: JSONSnapshotStore

    init(
        store: JSONSnapshotStore = JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        )
    ) {
        self.store = store
    }

    func placeholder(in context: Context) -> ContextPanelWidgetEntry {
        ContextPanelWidgetEntry(date: Date(), snapshot: .placeholder)
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
        let result = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 20 * 60), now: date)
        return ContextPanelWidgetEntry(date: date, snapshot: WidgetSnapshot.fromStore(result, now: date))
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
            ContextPanelLargeWidget(snapshot: entry.snapshot)
        default:
            ContextPanelMediumWidget(snapshot: entry.snapshot)
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
