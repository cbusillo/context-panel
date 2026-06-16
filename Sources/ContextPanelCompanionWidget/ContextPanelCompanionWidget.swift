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
}

struct ContextPanelCompanionTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextPanelCompanionWidgetEntry {
        ContextPanelCompanionWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshot.fromCompanionSync(CompanionSyncLoadResult(document: nil, status: .unknown)),
            displayPreferences: .defaultPreferences
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelCompanionWidgetEntry) -> Void) {
        loadEntry(date: Date(), completion: completion)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelCompanionWidgetEntry>) -> Void) {
        let now = Date()
        loadEntry(date: now) { entry in
            completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
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
            completion(entry(date: date))
        }
    }

    private static func entry(date: Date) -> ContextPanelCompanionWidgetEntry {
        let result = CompanionSyncLoader.load(now: date)
        return ContextPanelCompanionWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromCompanionSync(result, now: date),
            displayPreferences: result.document?.widgetDisplayPreferences ?? .defaultPreferences
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
        .containerBackground(CPWTheme.surface, for: .widget)
    }
}

@main
struct ContextPanelCompanionWidget: Widget {
    let kind = "ContextPanelCompanionWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContextPanelCompanionTimelineProvider()) { entry in
            ContextPanelCompanionWidgetView(entry: entry)
        }
        .configurationDisplayName("Context Panel")
        .description("View AI usage limits synced from your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}
