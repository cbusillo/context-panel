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
        if let family = WatchUpgradeCanaryFamily(widgetFamily: context.family) {
            WatchWidgetLoadQueue.recordPlaceholder(
                family: family,
                requestContext: WatchUpgradeCanaryRequestContext(isPreview: context.isPreview),
                requestID: UUID(),
                sessionID: WatchWidgetLoadQueue.captureCanarySessionID(),
                date: date
            )
        }
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: placeholderSnapshot(date: date),
            displayPreferences: .defaultPreferences
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWatchWidgetEntry) -> Void) {
        let date = Date()
        guard let family = WatchUpgradeCanaryFamily(widgetFamily: context.family) else {
            WatchWidgetLoadQueue.loadSnapshot(
                date: date,
                family: nil,
                requestContext: nil,
                requestID: nil,
                sessionID: nil,
                completion: completion
            )
            return
        }
        WatchWidgetLoadQueue.loadSnapshot(
            date: date,
            family: family,
            requestContext: WatchUpgradeCanaryRequestContext(isPreview: context.isPreview),
            requestID: UUID(),
            sessionID: WatchWidgetLoadQueue.captureCanarySessionID(),
            completion: completion
        )
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWatchWidgetEntry>) -> Void) {
        let date = Date()
        guard let family = WatchUpgradeCanaryFamily(widgetFamily: context.family) else {
            WatchWidgetLoadQueue.loadTimeline(
                date: date,
                family: nil,
                requestContext: nil,
                requestID: nil,
                sessionID: nil,
                completion: completion
            )
            return
        }
        WatchWidgetLoadQueue.loadTimeline(
            date: date,
            family: family,
            requestContext: WatchUpgradeCanaryRequestContext(isPreview: context.isPreview),
            requestID: UUID(),
            sessionID: WatchWidgetLoadQueue.captureCanarySessionID(),
            completion: completion
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

private enum WatchWidgetLoadQueue {
    private static let queue = DispatchQueue(
        label: "com.shinycomputers.contextpanel.watch-widget-load",
        qos: .utility
    )
    private static let cache = WatchCompanionCache()
    private static let canaryStore = WatchUpgradeCanaryReceiptStore()
    private static let loader: WatchCompanionLoader = {
        let remoteStore = CompanionCloudKitSyncStoreFactory.make()
        let presentationStore = CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
        return WatchCompanionLoader(
            cache: cache,
            loadDocument: { now in await remoteStore.load(now: now) },
            loadPresentation: { await presentationStore.load() }
        )
    }()

    static func recordPlaceholder(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        requestID: UUID,
        sessionID: UUID?,
        date: Date
    ) {
        _ = canaryStore?.recordWidgetObservation(
            event: .widgetPlaceholder,
            family: family,
            requestContext: requestContext,
            requestID: requestID,
            sessionID: sessionID,
            now: date
        )
    }

    static func captureCanarySessionID() -> UUID? {
        canaryStore?.captureWidgetSessionID()
    }

    static func loadSnapshot(
        date: Date,
        family: WatchUpgradeCanaryFamily?,
        requestContext: WatchUpgradeCanaryRequestContext?,
        requestID: UUID?,
        sessionID: UUID?,
        completion: @escaping (ContextPanelWatchWidgetEntry) -> Void
    ) {
        let completion = WatchWidgetCompletion(completion)
        queue.async {
            if let canaryStore, let family, let requestContext, let requestID {
                _ = canaryStore.recordWidgetObservation(
                    event: .widgetSnapshot,
                    family: family,
                    requestContext: requestContext,
                    requestID: requestID,
                    sessionID: sessionID,
                    now: date
                )
            }
            completion.call(entry(
                date: date,
                loaded: cache.load(),
                stalenessPolicy: stalenessPolicy
            ))
        }
    }

    static func loadTimeline(
        date: Date,
        family: WatchUpgradeCanaryFamily?,
        requestContext: WatchUpgradeCanaryRequestContext?,
        requestID: UUID?,
        sessionID: UUID?,
        completion: @escaping (Timeline<ContextPanelWatchWidgetEntry>) -> Void
    ) {
        let completion = WatchWidgetCompletion(completion)
        Task.detached(priority: .utility) {
            var startRecorded = false
            if let family, let requestContext, let requestID {
                startRecorded = canaryStore?.recordTimelineStarted(
                    family: family,
                    requestContext: requestContext,
                    requestID: requestID,
                    sessionID: sessionID,
                    now: date
                )?.requestID == requestID
            }
            let loaded = await loader.load(now: date)
            let currentEntry = entry(
                date: date,
                loaded: loaded,
                stalenessPolicy: stalenessPolicy
            )
            let refreshInterval: TimeInterval = switch loaded.result.status {
            case .failure, .stale:
                5 * 60
            case .healthy, .close, .limited, .unknown, .loading:
                15 * 60
            }
            let refreshPolicy = TimelineReloadPolicy.after(date.addingTimeInterval(refreshInterval))
            guard currentEntry.snapshot.state == .ready,
                  let staleDate = stalenessPolicy.nextStaleTransitionDate(
                    for: currentEntry.snapshot.usageSnapshot,
                    now: date
                  )
            else {
                recordTimelineCompletion(
                    family: family,
                    requestContext: requestContext,
                    requestID: requestID,
                    sessionID: sessionID,
                    startedAt: date,
                    startRecorded: startRecorded
                )
                completion.call(Timeline(entries: [currentEntry], policy: refreshPolicy))
                return
            }
            recordTimelineCompletion(
                family: family,
                requestContext: requestContext,
                requestID: requestID,
                sessionID: sessionID,
                startedAt: date,
                startRecorded: startRecorded
            )
            completion.call(Timeline(
                entries: [
                    currentEntry,
                    entry(
                        date: staleDate,
                        loaded: loaded,
                        stalenessPolicy: stalenessPolicy
                    ),
                ],
                policy: refreshPolicy
            ))
        }
    }

    private static func recordTimelineCompletion(
        family: WatchUpgradeCanaryFamily?,
        requestContext: WatchUpgradeCanaryRequestContext?,
        requestID: UUID?,
        sessionID: UUID?,
        startedAt: Date,
        startRecorded: Bool
    ) {
        guard startRecorded, let family, let requestContext, let requestID else { return }
        _ = canaryStore?.recordTimelineCompleted(
            family: family,
            requestContext: requestContext,
            requestID: requestID,
            startedAt: startedAt,
            sessionID: sessionID
        )
    }

    private static var stalenessPolicy: SnapshotStoreStalenessPolicy {
        SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
    }

    private static func entry(
        date: Date,
        loaded: WatchCompanionCacheLoadResult,
        stalenessPolicy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelWatchWidgetEntry {
        let result = loaded.result
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: WidgetSnapshot.fromCompanionSync(
                result,
                now: date,
                stalenessPolicy: stalenessPolicy
            ),
            displayPreferences: WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: loaded.displayPreferences,
                synced: result.document?.widgetDisplayPreferences
            )
        )
    }
}

private final class WatchWidgetCompletion<Value>: @unchecked Sendable {
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

private struct WatchUpgradeCanaryBadge: View {
    let size: CGFloat

    var body: some View {
        Text(WatchUpgradeCanary.marker)
            .font(.system(size: size, weight: .black, design: .rounded))
            .unredacted()
            .accessibilityHidden(true)
    }
}

struct WatchCircularComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot

    @ViewBuilder
    var body: some View {
        if let limit, let ratio = limit.remainingCapacity.ratio {
            ZStack(alignment: .top) {
                Gauge(value: ratio) {
                    EmptyView()
                } currentValueLabel: {
                    Text(limit.compactCircularQuantity)
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
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

                canaryMarker
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                limit.accessibilitySentence(direction: .remaining)
                    + " Upgrade canary \(WatchUpgradeCanary.marker)."
            )
        } else {
            ZStack {
                Circle()
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: fallbackSymbol)
                    .font(.caption2.weight(.semibold))
                canaryMarker
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                (limit?.accessibilitySentence(direction: .remaining)
                    ?? watchEmptyText(for: snapshot, compact: false))
                    + " Upgrade canary \(WatchUpgradeCanary.marker)."
            )
        }
    }

    private var canaryMarker: some View {
        VStack {
            WatchUpgradeCanaryBadge(size: 7)
            Spacer(minLength: 0)
        }
        .padding(.top, 1)
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
        HStack(spacing: 3) {
            WatchUpgradeCanaryBadge(size: 7)
                .frame(width: 7)
            content
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var content: some View {
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

    private var accessibilityText: String {
        let base = limits.isEmpty
            ? watchEmptyText(for: snapshot, compact: false)
            : limits.map { $0.accessibilitySentence(direction: .remaining) }
                .joined(separator: ". ")
        return base + " Upgrade canary \(WatchUpgradeCanary.marker)."
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
            HStack(spacing: 3) {
                WatchUpgradeCanaryBadge(size: 10)
                ViewThatFits(in: .horizontal) {
                    if limits.count > 1 {
                        Text(twoLimitText(primary: primary, secondary: limits[1]))
                            .accessibilityLabel(
                                primary.accessibilitySentence(direction: .remaining)
                                    + ". "
                                    + limits[1].accessibilitySentence(direction: .remaining)
                                    + ". Upgrade canary \(WatchUpgradeCanary.marker)."
                            )
                    }
                    Text("\(primary.title) \(primary.subtitle) · \(primary.remainingInlineText)")
                        .accessibilityLabel(
                            primary.accessibilitySentence(direction: .remaining)
                                + " Upgrade canary \(WatchUpgradeCanary.marker)."
                        )
                }
            }
        } else {
            HStack(spacing: 3) {
                WatchUpgradeCanaryBadge(size: 10)
                Text(watchEmptyText(for: snapshot, compact: false))
                    .accessibilityLabel(
                        watchEmptyText(for: snapshot, compact: false)
                            + " Upgrade canary \(WatchUpgradeCanary.marker)."
                    )
            }
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
            ZStack(alignment: .top) {
                Text(limit.remainingText)
                    .widgetCurvesContent()
                WatchUpgradeCanaryBadge(size: 7)
                    .padding(.top, 1)
            }
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
                .accessibilityLabel(
                    limit.accessibilitySentence(direction: .remaining)
                        + " Upgrade canary \(WatchUpgradeCanary.marker)."
                )
        } else {
            ZStack(alignment: .top) {
                Text("—")
                    .widgetCurvesContent()
                WatchUpgradeCanaryBadge(size: 7)
                    .padding(.top, 1)
            }
                .widgetLabel {
                    Text(limit?.title ?? watchEmptyText(for: snapshot, compact: true))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    (limit?.accessibilitySentence(direction: .remaining)
                        ?? watchEmptyText(for: snapshot, compact: false))
                        + " Upgrade canary \(WatchUpgradeCanary.marker)."
                )
                .foregroundStyle(limit.map { watchStatusColor($0.status) } ?? watchStatusColor(snapshot.status))
        }
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
