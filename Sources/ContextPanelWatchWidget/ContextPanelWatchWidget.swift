import ContextPanelCloudKitSync
import ContextPanelCore
import SwiftUI
import WidgetKit

enum ContextPanelWatchComplicationFamily: String, CaseIterable, Identifiable {
    case circular
    case rectangular
    case inline
    case corner

    var id: String { rawValue }

    var widgetFamily: WidgetFamily {
        switch self {
        case .circular: .accessoryCircular
        case .rectangular: .accessoryRectangular
        case .inline: .accessoryInline
        case .corner: .accessoryCorner
        }
    }

}

struct ContextPanelWatchWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
}

#if CONTEXT_PANEL_WATCH_WIDGET_EXTENSION

private struct ContextPanelWatchWidgetSelection {
    let entry: ContextPanelWatchWidgetEntry
    let loaded: WatchCompanionCacheLoadResult
}

private struct ContextPanelWatchWidgetTimelineSelection {
    let timeline: Timeline<ContextPanelWatchWidgetEntry>
    let current: ContextPanelWatchWidgetSelection
}

struct ContextPanelWatchWidgetProvider: TimelineProvider {
    let runtimeReceiptRecorder: RuntimeReceiptRecorder

    init(runtimeReceiptRecorder: RuntimeReceiptRecorder) {
        self.runtimeReceiptRecorder = runtimeReceiptRecorder
    }

    func placeholder(in context: Context) -> ContextPanelWatchWidgetEntry {
        let date = Date()
        return ContextPanelWatchWidgetEntry(
            date: date,
            snapshot: placeholderSnapshot(date: date),
            displayPreferences: .defaultPreferences
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (ContextPanelWatchWidgetEntry) -> Void) {
        WatchWidgetLoadQueue.loadSnapshot(date: Date()) { selection in
            recordRuntimeReceipt(
                selection,
                trigger: .widgetSnapshot,
                family: context.family
            )
            completion(selection.entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ContextPanelWatchWidgetEntry>) -> Void) {
        let date = Date()
        WatchWidgetLoadQueue.loadTimeline(date: date) { selection in
            recordRuntimeReceipt(
                selection.current,
                trigger: .widgetTimeline,
                family: context.family
            )
            completion(selection.timeline)
        }
    }

    private func recordRuntimeReceipt(
        _ selection: ContextPanelWatchWidgetSelection,
        trigger: RuntimeReceiptTrigger,
        family: WidgetFamily
    ) {
        let presentationMode = runtimePresentationMode(for: family)
        let evidence = CompanionRuntimeReceiptEvidence(
            result: selection.loaded.result,
            snapshot: selection.entry.snapshot,
            displayPreferences: selection.entry.displayPreferences,
            appearanceSettings: nil,
            presentationSurface: .widget,
            presentationMode: presentationMode,
            presentationDate: selection.entry.date
        )
        let exceededDeadlineWithoutSavedData = selection.loaded.disposition == .deadlineExceeded
            && selection.loaded.result.document == nil
        runtimeReceiptRecorder.record(
            trigger: trigger,
            presentationMode: presentationMode,
            selectedSource: evidence.selectedSource,
            presentationDigest: evidence.presentationDigest,
            stateBranch: exceededDeadlineWithoutSavedData ? .unknown : evidence.stateBranch,
            outcome: exceededDeadlineWithoutSavedData ? .degraded : evidence.outcome,
            observedAt: selection.entry.date
        )
    }

    private func runtimePresentationMode(for family: WidgetFamily) -> RuntimeReceiptPresentationMode {
        switch family {
        case .accessoryCircular:
            .widgetAccessoryCircular
        case .accessoryRectangular:
            .widgetAccessoryRectangular
        case .accessoryInline:
            .widgetAccessoryInline
        case .accessoryCorner:
            .widgetAccessoryCorner
        default:
            .widgetAccessoryUnknown
        }
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
    private static let loader: WatchCompanionLoader = {
        let remoteStore = CompanionCloudKitSyncStoreFactory.make()
        let presentationStore = CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
        return WatchCompanionLoader(
            cache: cache,
            loadDocument: { now in await remoteStore.load(now: now) },
            loadPresentation: { await presentationStore.load() }
        )
    }()

    static func loadSnapshot(date: Date, completion: @escaping (ContextPanelWatchWidgetSelection) -> Void) {
        let completion = WatchWidgetCompletion(completion)
        queue.async {
            completion.call(entry(
                date: date,
                loaded: cache.load(now: date),
                stalenessPolicy: stalenessPolicy
            ))
        }
    }

    static func loadTimeline(
        date: Date,
        completion: @escaping (ContextPanelWatchWidgetTimelineSelection) -> Void
    ) {
        let completion = WatchWidgetCompletion(completion)
        Task.detached(priority: .utility) {
            let loaded = await loader.load(now: date)
            let current = entry(
                date: date,
                loaded: loaded,
                stalenessPolicy: stalenessPolicy
            )
            let currentEntry = current.entry
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
                completion.call(ContextPanelWatchWidgetTimelineSelection(
                    timeline: Timeline(entries: [currentEntry], policy: refreshPolicy),
                    current: current
                ))
                return
            }
            completion.call(ContextPanelWatchWidgetTimelineSelection(
                timeline: Timeline(
                    entries: [
                        currentEntry,
                        entry(
                            date: staleDate,
                            loaded: loaded,
                            stalenessPolicy: stalenessPolicy
                        ).entry,
                    ],
                    policy: refreshPolicy
                ),
                current: current
            ))
        }
    }

    private static var stalenessPolicy: SnapshotStoreStalenessPolicy {
        SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
    }

    private static func entry(
        date: Date,
        loaded: WatchCompanionCacheLoadResult,
        stalenessPolicy: SnapshotStoreStalenessPolicy
    ) -> ContextPanelWatchWidgetSelection {
        let result = loaded.result
        return ContextPanelWatchWidgetSelection(
            entry: ContextPanelWatchWidgetEntry(
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
            ),
            loaded: loaded
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
#endif

struct ContextPanelWatchWidgetView: View {
    static let supportedFamilies = ContextPanelWatchComplicationFamily.allCases.map(\.widgetFamily)

    @Environment(\.widgetFamily) private var environmentFamily

    let entry: ContextPanelWatchWidgetEntry
    private let explicitFamily: WidgetFamily?
    private let explicitPresentationDate: Date?

    init(
        entry: ContextPanelWatchWidgetEntry,
        family: WidgetFamily? = nil,
        presentationDate: Date? = nil
    ) {
        self.entry = entry
        explicitFamily = family
        explicitPresentationDate = presentationDate
    }

    private var family: WidgetFamily {
        explicitFamily ?? environmentFamily
    }

    private var presentationDate: Date {
        explicitPresentationDate ?? entry.date
    }

    private var compactContent: WatchComplicationContent {
        mainLaneContent(maximumCount: 1)
    }

    private var rectangularContent: WatchComplicationContent {
        mainLaneContent(maximumCount: 2)
    }

    private var inlineContent: WatchComplicationContent {
        WatchComplicationContent.inline(
            from: entry.snapshot,
            preferences: entry.displayPreferences
        )
    }

    private func mainLaneContent(maximumCount: Int) -> WatchComplicationContent {
        WatchComplicationContent.mainLane(
            from: entry.snapshot,
            preferences: entry.displayPreferences,
            maximumCount: maximumCount
        )
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            if let alert = compactContent.providerAccessFallback {
                WatchCircularProviderAccessComplication(alert: alert, presentationDate: presentationDate)
            } else {
                WatchCircularComplication(
                    limit: compactContent.limits.first,
                    snapshot: entry.snapshot,
                    presentationDate: presentationDate
                )
            }
        case .accessoryRectangular:
            if let alert = rectangularContent.providerAccessFallback {
                WatchRectangularProviderAccessComplication(alert: alert, presentationDate: presentationDate)
            } else {
                WatchRectangularComplication(
                    limits: rectangularContent.limits,
                    snapshot: entry.snapshot,
                    presentationDate: presentationDate
                )
            }
        case .accessoryInline:
            if let alert = inlineContent.providerAccessFallback {
                WatchInlineProviderAccessComplication(alert: alert, presentationDate: presentationDate)
            } else {
                WatchInlineComplication(
                    limits: inlineContent.limits,
                    snapshot: entry.snapshot,
                    presentationDate: presentationDate
                )
            }
        case .accessoryCorner:
            if let alert = compactContent.providerAccessFallback {
                WatchCornerProviderAccessComplication(alert: alert, presentationDate: presentationDate)
            } else {
                WatchCornerComplication(
                    limit: compactContent.limits.first,
                    snapshot: entry.snapshot,
                    presentationDate: presentationDate
                )
            }
        default:
            if let alert = rectangularContent.providerAccessFallback {
                WatchRectangularProviderAccessComplication(alert: alert, presentationDate: presentationDate)
            } else {
                WatchRectangularComplication(
                    limits: rectangularContent.limits,
                    snapshot: entry.snapshot,
                    presentationDate: presentationDate
                )
            }
        }
    }
}

private struct WatchCircularProviderAccessComplication: View {
    let alert: ProviderAccessAlert
    let presentationDate: Date

    var body: some View {
        ZStack {
            Circle()
                .stroke(watchStatusColor(alert.status), lineWidth: 3)
            Image(systemName: watchProviderAccessSymbol(alert))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(watchStatusColor(alert.status))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(watchProviderAccessAccessibilityText(alert, now: presentationDate))
    }
}

private struct WatchRectangularProviderAccessComplication: View {
    let alert: ProviderAccessAlert
    let presentationDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(alert.title, systemImage: watchProviderAccessSymbol(alert))
                .font(.caption.weight(.semibold))
                .foregroundStyle(watchStatusColor(alert.status))
                .lineLimit(1)
            Text(watchProviderAccessDetail(alert, now: presentationDate))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(watchProviderAccessAccessibilityText(alert, now: presentationDate))
    }
}

private struct WatchInlineProviderAccessComplication: View {
    let alert: ProviderAccessAlert
    let presentationDate: Date

    var body: some View {
        Text(watchProviderAccessInlineText(alert, now: presentationDate))
            .accessibilityLabel(watchProviderAccessAccessibilityText(alert, now: presentationDate))
    }
}

private struct WatchCornerProviderAccessComplication: View {
    let alert: ProviderAccessAlert
    let presentationDate: Date

    var body: some View {
        Text(watchProviderAccessCornerText(alert))
            .widgetCurvesContent()
            .widgetLabel {
                Label(alert.title, systemImage: watchProviderAccessSymbol(alert))
                    .foregroundStyle(watchStatusColor(alert.status))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(watchProviderAccessAccessibilityText(alert, now: presentationDate))
    }
}

struct WatchCircularComplication: View {
    let limit: WatchLimitDisplay?
    let snapshot: WidgetSnapshot
    let presentationDate: Date

    @ViewBuilder
    var body: some View {
        if let limit, let ratio = limit.remainingCapacity.ratio {
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(limit.accessibilitySentence(direction: .remaining, now: presentationDate))
        } else {
            ZStack {
                Circle()
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                Image(systemName: fallbackSymbol)
                    .font(.caption2.weight(.semibold))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                limit?.accessibilitySentence(direction: .remaining, now: presentationDate)
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
    let presentationDate: Date

    var body: some View {
        if !limits.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(limits) { limit in
                    WatchRectangularLimitLine(limit: limit, presentationDate: presentationDate)
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
    let presentationDate: Date

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
        .accessibilityLabel(limit.accessibilitySentence(direction: .remaining, now: presentationDate))
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
    let presentationDate: Date

    private var primary: WatchLimitDisplay? {
        limits.first
    }

    var body: some View {
        if let primary {
            ViewThatFits(in: .horizontal) {
                if limits.count > 1 {
                    Text(twoLimitText(primary: primary, secondary: limits[1]))
                        .accessibilityLabel(
                            primary.accessibilitySentence(direction: .remaining, now: presentationDate)
                                + ". "
                                + limits[1].accessibilitySentence(direction: .remaining, now: presentationDate)
                        )
                }
                Text("\(primary.title) \(primary.subtitle) · \(primary.remainingInlineText)")
                    .accessibilityLabel(
                        primary.accessibilitySentence(direction: .remaining, now: presentationDate)
                    )
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
    let presentationDate: Date

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
                .accessibilityLabel(limit.accessibilitySentence(direction: .remaining, now: presentationDate))
        } else {
            Text("—")
                .widgetCurvesContent()
                .widgetLabel {
                    Text(limit?.title ?? watchEmptyText(for: snapshot, compact: true))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    limit?.accessibilitySentence(direction: .remaining, now: presentationDate)
                        ?? watchEmptyText(for: snapshot, compact: false)
                )
                .foregroundStyle(limit.map { watchStatusColor($0.status) } ?? watchStatusColor(snapshot.status))
        }
    }

}

#if CONTEXT_PANEL_WATCH_WIDGET_EXTENSION
struct ContextPanelWatchWidget: Widget {
    let kind = ContextPanelWatchWidgetIdentity.kind

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: ContextPanelWatchWidgetProvider(
                runtimeReceiptRecorder: .appGroupRequired(
                    surface: .watchOSComplication,
                    appGroupID: ContextPanelLocations.watchAppGroupID
                )
            )
        ) { entry in
            ContextPanelWatchWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Context Panel")
        .description("Shows remaining capacity for the AI usage limits you chose.")
        .supportedFamilies(ContextPanelWatchWidgetView.supportedFamilies)
    }
}

@main
struct ContextPanelWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        ContextPanelWatchWidget()
    }
}
#endif

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

private func watchProviderAccessSymbol(_ alert: ProviderAccessAlert) -> String {
    switch alert.accessState.kind {
    case .blockedUntilReset:
        "exclamationmark"
    case .paidFallbackActive:
        "dollarsign"
    case .degraded:
        "questionmark"
    case .available, .pressure, .unknown:
        "circle"
    }
}

private func watchProviderAccessDetail(_ alert: ProviderAccessAlert, now: Date) -> String {
    if let resetText = alert.resetDisplayText(now: now) {
        return "Reset \(resetText)"
    }
    return alert.detail
}

private func watchProviderAccessInlineText(_ alert: ProviderAccessAlert, now: Date) -> String {
    if let resetText = alert.resetDisplayText(now: now) {
        return "\(alert.title) until \(resetText)"
    }
    return alert.title
}

private func watchProviderAccessCornerText(_ alert: ProviderAccessAlert) -> String {
    switch alert.accessState.kind {
    case .blockedUntilReset:
        "Limited"
    case .paidFallbackActive:
        "Paid"
    case .degraded:
        "Unknown"
    case .available, .pressure, .unknown:
        "—"
    }
}

private func watchProviderAccessAccessibilityText(_ alert: ProviderAccessAlert, now: Date) -> String {
    var components = [alert.title, alert.accountName, alert.detail]
    if let resetText = alert.resetAccessibilityText(now: now) {
        components.append("Plan access resets at \(resetText)")
    }
    return components.joined(separator: ". ")
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
