import ContextPanelCore
import SwiftUI
import WidgetKit

struct ContextPanelWatchWidgetEntry: TimelineEntry {
    let date: Date
}

struct ContextPanelWatchWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> ContextPanelWatchWidgetEntry {
        let entry = ContextPanelWatchWidgetEntry(date: Date())
        defer {
            record(
                event: .widgetPlaceholder,
                context: context,
                observedAt: entry.date
            )
        }
        return entry
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (ContextPanelWatchWidgetEntry) -> Void
    ) {
        let entry = ContextPanelWatchWidgetEntry(date: Date())
        completion(entry)
        record(event: .widgetSnapshot, context: context, observedAt: entry.date)
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<ContextPanelWatchWidgetEntry>) -> Void
    ) {
        let entry = ContextPanelWatchWidgetEntry(date: Date())
        completion(Timeline(entries: [entry], policy: .never))
        record(event: .widgetTimeline, context: context, observedAt: entry.date)
    }

    private func record(
        event: WatchUpgradeCanaryEvent,
        context: Context,
        observedAt: Date
    ) {
        guard let family = WatchUpgradeCanaryFamily(widgetFamily: context.family) else {
            return
        }
        WatchUpgradeCanaryRecorder.recordWidgetAsync(
            event: event,
            family: family,
            requestContext: WatchUpgradeCanaryRequestContext(isPreview: context.isPreview),
            observedAt: observedAt
        )
    }
}

struct ContextPanelWatchWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            WatchCanaryCircularView()
        case .accessoryRectangular:
            WatchCanaryRectangularView()
        case .accessoryInline:
            WatchCanaryInlineView()
        case .accessoryCorner:
            WatchCanaryCornerView()
        default:
            WatchCanaryRectangularView()
        }
    }
}

private struct WatchCanaryCircularView: View {
    var body: some View {
        ZStack {
            Circle()
                .stroke(.green, lineWidth: 4)
            Text(WatchUpgradeCanary.marker)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .foregroundStyle(.green)
        }
        .unredacted()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Upgrade probe Canary \(WatchUpgradeCanary.marker)")
    }
}

private struct WatchCanaryRectangularView: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(WatchUpgradeCanary.marker)
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text("UPDATE")
                Text("PROBE")
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.weight(.semibold))
            Spacer(minLength: 0)
        }
        .unredacted()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Upgrade probe Canary \(WatchUpgradeCanary.marker)")
    }
}

private struct WatchCanaryInlineView: View {
    var body: some View {
        Text("\(WatchUpgradeCanary.marker) · update probe")
            .fontWeight(.semibold)
            .unredacted()
            .accessibilityLabel("Upgrade probe Canary \(WatchUpgradeCanary.marker)")
    }
}

private struct WatchCanaryCornerView: View {
    var body: some View {
        Text(WatchUpgradeCanary.marker)
            .fontWeight(.black)
            .foregroundStyle(.green)
            .unredacted()
            .widgetCurvesContent()
            .widgetLabel {
                Text("Update probe")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Upgrade probe Canary \(WatchUpgradeCanary.marker)")
    }
}

private extension WatchUpgradeCanaryFamily {
    init?(widgetFamily: WidgetFamily) {
        switch widgetFamily {
        case .accessoryCircular:
            self = .circular
        case .accessoryCorner:
            self = .corner
        case .accessoryRectangular:
            self = .rectangular
        case .accessoryInline:
            self = .inline
        default:
            return nil
        }
    }
}

private extension WatchUpgradeCanaryRequestContext {
    init(isPreview: Bool) {
        self = isPreview ? .preview : .live
    }
}

struct ContextPanelWatchWidget: Widget {
    let kind = ContextPanelWatchWidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ContextPanelWatchWidgetProvider()) { _ in
            ContextPanelWatchWidgetView()
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Context Panel")
        .description("Neutral Watch upgrade probe.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner,
        ])
    }
}

@main
struct ContextPanelWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContextPanelWatchWidget()
    }
}
