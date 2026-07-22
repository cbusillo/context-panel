import ContextPanelCloudKitSync
import ContextPanelCore
import SwiftUI
import WidgetKit

@main
struct ContextPanelWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}

@MainActor
private struct WatchRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = WatchSyncModel()

    var body: some View {
        NavigationStack {
            List {
                WatchUpgradeCanarySection(
                    history: model.canaryHistory,
                    identity: model.canaryIdentity,
                    configurationBeforeReload: model.canaryConfigurationBeforeReload,
                    configurationAfterReload: model.canaryConfigurationAfterReload,
                    reloadRequestedAt: model.canaryReloadRequestedAt,
                    configurationBeforeError: model.canaryConfigurationBeforeError,
                    configurationAfterError: model.canaryConfigurationAfterError,
                    receiptStoreError: model.canaryReceiptStoreError
                )

                WatchStatusSection(
                    result: model.displayResult,
                    snapshot: model.snapshot,
                    syncErrorMessage: model.lastSyncErrorMessage
                )

                if model.displayLimits.isEmpty {
                    WatchEmptySection(
                        result: model.displayResult,
                        hasSourceLimits: !model.snapshot.limits.isEmpty
                    )
                } else {
                    Section {
                        ForEach(model.displayLimits) { limit in
                            WatchLimitRow(limit: limit)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        model.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    .accessibilityLabel("Refresh")
                }
            }
            .task {
                model.reload()
                if scenePhase == .active {
                    model.activateCanaryProbe()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.reload()
                    model.activateCanaryProbe()
                }
            }
        }
    }
}

@MainActor
@Observable
private final class WatchSyncModel {
    private let companionLoader: WatchCompanionLoader
    private let canaryStore: WatchUpgradeCanaryEventStore?
    private var reloadTask: Task<Void, Never>?
    private var canaryObservationTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false
    private var canaryProbeStarted = false

    let canaryIdentity = WatchUpgradeCanaryBuildIdentity.current()

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var displayResult = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences
    private(set) var lastSyncErrorMessage: String?
    private(set) var canaryHistory: [WatchUpgradeCanaryHistoryEvent] = []
    private(set) var canaryConfigurationBeforeReload: WatchUpgradeCanaryConfigurationSnapshot?
    private(set) var canaryConfigurationAfterReload: WatchUpgradeCanaryConfigurationSnapshot?
    private(set) var canaryReloadRequestedAt: Date?
    private(set) var canaryConfigurationBeforeError: String?
    private(set) var canaryConfigurationAfterError: String?
    private(set) var canaryReceiptStoreError: String?
    private(set) var isLoading = false

    init() {
        canaryStore = WatchUpgradeCanaryEventStore()
        canaryReceiptStoreError = canaryStore == nil
            ? "Shared receipt store unavailable"
            : nil
        let cache = WatchCompanionCache()
        let remoteStore = CompanionCloudKitSyncStoreFactory.make()
        let presentationStore = CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
        companionLoader = WatchCompanionLoader(
            cache: cache,
            loadDocument: { now in await remoteStore.load(now: now) },
            loadPresentation: { await presentationStore.load() }
        )
    }

    var displayLimits: [WatchLimitDisplay] {
        WatchLimitDisplay.mainLaneRows(
            from: snapshot,
            preferences: displayPreferences,
            maximumCount: 8
        )
    }

    func reload(now: Date = Date()) {
        guard reloadTask == nil else {
            needsReloadAfterCurrentTask = true
            return
        }
        needsReloadAfterCurrentTask = false
        isLoading = true
        result = CompanionSyncLoadResult(document: result.document, status: .loading)
        displayResult = CompanionSyncLoadResult(document: displayResult.document, status: .loading)
        lastSyncErrorMessage = nil

        reloadTask = Task { [weak self, companionLoader] in
            defer {
                if let self {
                    isLoading = false
                    reloadTask = nil
                    if needsReloadAfterCurrentTask {
                        reload()
                    }
                }
            }
            let loaded = await companionLoader.load(now: now)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            result = loaded.result
            displayResult = loaded.result
            lastSyncErrorMessage = loaded.result.errorMessage
            snapshot = WidgetSnapshot.fromCompanionSync(
                loaded.result,
                now: now,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            )
            let effectiveDisplayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: loaded.displayPreferences,
                synced: loaded.result.document?.widgetDisplayPreferences
            )
            displayPreferences = effectiveDisplayPreferences
            refreshCanaryHistory()
        }
    }

    func activateCanaryProbe() {
        guard !canaryProbeStarted else { return }
        canaryProbeStarted = true
        WatchUpgradeCanaryRecorder.recordAppAsync(event: .appActivated)
        canaryObservationTask = Task { [weak self] in
            guard let self else { return }
            let before = await currentCanaryConfiguration()
            canaryConfigurationBeforeReload = before.snapshot
            canaryConfigurationBeforeError = before.error
            WatchUpgradeCanaryRecorder.recordAppAsync(
                event: .configurationsBeforeReload,
                configuration: before.snapshot
            )
            refreshCanaryHistory()
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let reloadDate = Date()
            WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelWatchWidgetIdentity.kind)
            canaryReloadRequestedAt = reloadDate
            WatchUpgradeCanaryRecorder.recordAppAsync(
                event: .reloadRequested,
                observedAt: reloadDate
            )

            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let after = await currentCanaryConfiguration()
            canaryConfigurationAfterReload = after.snapshot
            canaryConfigurationAfterError = after.error
            WatchUpgradeCanaryRecorder.recordAppAsync(
                event: .configurationsAfterReload,
                configuration: after.snapshot
            )
            refreshCanaryHistory()

            for delay in [10, 45] {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refreshCanaryHistory()
            }
        }
    }

    private func refreshCanaryHistory() {
        guard let canaryStore else {
            canaryReceiptStoreError = "Shared receipt store unavailable"
            return
        }
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return (events: try canaryStore.loadHistory(), error: nil as String?)
                } catch {
                    let error = error as NSError
                    return (
                        events: [WatchUpgradeCanaryHistoryEvent](),
                        error: "Receipt read failed: \(error.domain) \(error.code)"
                    )
                }
            }.value
            guard let self else { return }
            if let error = result.error {
                canaryReceiptStoreError = error
                return
            }
            canaryReceiptStoreError = nil
            canaryHistory = mergeCanaryHistory(result.events)
        }
    }

    private func mergeCanaryHistory(
        _ loadedEvents: [WatchUpgradeCanaryHistoryEvent]
    ) -> [WatchUpgradeCanaryHistoryEvent] {
        var eventsByID = Dictionary(uniqueKeysWithValues: canaryHistory.map { ($0.id, $0) })
        for event in loadedEvents {
            if let existing = eventsByID[event.id], existing.observedAt > event.observedAt {
                continue
            }
            eventsByID[event.id] = event
        }
        return eventsByID.values.sorted { left, right in
            if left.observedAt == right.observedAt {
                return left.id < right.id
            }
            return left.observedAt < right.observedAt
        }
    }

    private func currentCanaryConfiguration() async -> (
        snapshot: WatchUpgradeCanaryConfigurationSnapshot?,
        error: String?
    ) {
        await withCheckedContinuation { continuation in
            WidgetCenter.shared.getCurrentConfigurations { result in
                switch result {
                case let .success(configurations):
                    var familyCounts: [WatchUpgradeCanaryFamily: Int] = [:]
                    var matchingKindCount = 0
                    var otherKindCount = 0
                    for configuration in configurations {
                        guard configuration.kind == ContextPanelWatchWidgetIdentity.kind else {
                            otherKindCount += 1
                            continue
                        }
                        matchingKindCount += 1
                        if let family = WatchUpgradeCanaryFamily(widgetFamily: configuration.family) {
                            familyCounts[family, default: 0] += 1
                        }
                    }
                    continuation.resume(returning: (
                        WatchUpgradeCanaryConfigurationSnapshot(
                            matchingKindCount: matchingKindCount,
                            otherKindCount: otherKindCount,
                            familyCounts: familyCounts
                        ),
                        nil
                    ))
                case let .failure(error):
                    let error = error as NSError
                    continuation.resume(returning: (
                        nil,
                        "\(error.domain) \(error.code)"
                    ))
                }
            }
        }
    }
}

private struct WatchUpgradeCanarySection: View {
    let history: [WatchUpgradeCanaryHistoryEvent]
    let identity: WatchUpgradeCanaryBuildIdentity
    let configurationBeforeReload: WatchUpgradeCanaryConfigurationSnapshot?
    let configurationAfterReload: WatchUpgradeCanaryConfigurationSnapshot?
    let reloadRequestedAt: Date?
    let configurationBeforeError: String?
    let configurationAfterError: String?
    let receiptStoreError: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Neutral canary \(WatchUpgradeCanary.marker)")
                    .font(.caption.weight(.semibold))
                Text("App \(WatchUpgradeCanary.marker) · \(identity.buildNumber)")
                    .font(.caption2)
                configurationRow(
                    label: "Before",
                    configuration: configurationBeforeReload,
                    error: configurationBeforeError
                )
                reloadRow
                configurationRow(
                    label: "After",
                    configuration: configurationAfterReload,
                    error: configurationAfterError
                )
                if let receiptStoreError {
                    Text(receiptStoreError)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                ForEach(WatchUpgradeCanaryFamily.allCases) { family in
                    familyRow(family)
                }
                historyRow
            }
        }
    }

    @ViewBuilder
    private func configurationRow(
        label: String,
        configuration: WatchUpgradeCanaryConfigurationSnapshot?,
        error: String?
    ) -> some View {
        HStack(spacing: 4) {
            Text(label)
            Spacer(minLength: 2)
            if let configuration {
                Text(configurationText(configuration))
            } else if let error {
                Text(error)
            } else {
                Text("pending")
            }
        }
        .font(.caption2)
        .foregroundStyle(configuration == nil ? .secondary : .primary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private var reloadRow: some View {
        HStack(spacing: 4) {
            Text("Reload")
            Spacer(minLength: 2)
            if let reloadRequestedAt {
                Text("sent")
                    .fontWeight(.semibold)
                Text(reloadRequestedAt, style: .timer)
                    .monospacedDigit()
            } else {
                Text("waiting for active scene")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private func configurationText(
        _ configuration: WatchUpgradeCanaryConfigurationSnapshot
    ) -> String {
        let families = configuration.families.map {
            "\($0.family.compactName)\($0.count)"
        }.joined(separator: " ")
        return "cfg \(configuration.matchingKindCount)"
            + (families.isEmpty ? "" : " · \(families)")
    }

    @ViewBuilder
    private func familyRow(_ family: WatchUpgradeCanaryFamily) -> some View {
        HStack(spacing: 4) {
            Text(family.displayName)
                .frame(width: 36, alignment: .leading)
            Spacer(minLength: 2)
            eventCell(family: family, requestContext: .live, prefix: "L")
            eventCell(family: family, requestContext: .preview, prefix: "P")
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.55)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func eventCell(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext,
        prefix: String
    ) -> some View {
        let event = latestEvent(family: family, requestContext: requestContext)
        Text("\(prefix) \(eventText(event))")
            .fontWeight(isCurrent(event) ? .semibold : .regular)
            .foregroundStyle(event == nil || !isCurrent(event) ? .secondary : .primary)
            .accessibilityLabel(eventAccessibilityLabel(event, requestContext: requestContext))
    }

    @ViewBuilder
    private var historyRow: some View {
        let markers = Set(history.filter { $0.component == .widget }.map(\.marker)).sorted()
        if markers.isEmpty {
            Text("History none")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("History \(markers.joined(separator: "/"))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func latestEvent(
        family: WatchUpgradeCanaryFamily,
        requestContext: WatchUpgradeCanaryRequestContext
    ) -> WatchUpgradeCanaryHistoryEvent? {
        let matchingEvents = history.filter {
                $0.component == .widget
                    && $0.family == family
                    && $0.requestContext == requestContext
            }
        let currentEvents = matchingEvents.filter { isCurrent($0) }
        if let strongestCurrentEvent = currentEvents.max(by: isWeakerEvidence) {
            return strongestCurrentEvent
        }
        return matchingEvents.max { $0.observedAt < $1.observedAt }
    }

    private func isWeakerEvidence(
        _ left: WatchUpgradeCanaryHistoryEvent,
        _ right: WatchUpgradeCanaryHistoryEvent
    ) -> Bool {
        let leftRank = evidenceRank(left)
        let rightRank = evidenceRank(right)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        return left.observedAt < right.observedAt
    }

    private func evidenceRank(_ event: WatchUpgradeCanaryHistoryEvent) -> Int {
        switch event.shortEventName {
        case "done":
            3
        case "snap":
            2
        case "ph":
            1
        default:
            0
        }
    }

    private func eventText(_ event: WatchUpgradeCanaryHistoryEvent?) -> String {
        guard let event else { return "—" }
        return "\(event.marker)-\(event.shortEventName)"
    }

    private func isCurrent(_ event: WatchUpgradeCanaryHistoryEvent?) -> Bool {
        guard let event else { return false }
        return event.marker == WatchUpgradeCanary.marker
            && event.marketingVersion == identity.marketingVersion
            && event.buildNumber == identity.buildNumber
    }

    private func eventAccessibilityLabel(
        _ event: WatchUpgradeCanaryHistoryEvent?,
        requestContext: WatchUpgradeCanaryRequestContext
    ) -> String {
        let context = requestContext == .preview ? "Preview" : "Live"
        guard let event else { return "\(context) receipt not observed." }
        return "\(context) Canary \(event.marker), \(event.eventName), build \(event.buildNumber)."
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

private struct WatchStatusSection: View {
    let result: CompanionSyncLoadResult
    let snapshot: WidgetSnapshot
    let syncErrorMessage: String?

    private var presentation: WatchSyncPresentation {
        WatchSyncPresentation(
            result: result,
            snapshot: snapshot,
            syncErrorMessage: syncErrorMessage
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: presentation.symbol)
                        .foregroundStyle(presentation.tone.color)
                    Text(presentation.title)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    if let generatedText = presentation.generatedText {
                        Text(generatedText)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel(presentation.generatedAccessibilityText ?? generatedText)
                    }
                }
                .font(.caption2.weight(.medium))

                if presentation.shouldShowDetail {
                    Text(presentation.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let diagnosticDetail = presentation.diagnosticDetail,
                   let diagnosticAccessibilityLabel = presentation.diagnosticAccessibilityLabel {
                    Text(verbatim: "Details: \(diagnosticDetail)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(diagnosticAccessibilityLabel)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct WatchEmptySection: View {
    let result: CompanionSyncLoadResult
    let hasSourceLimits: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(emptyTitle)
                    .font(.headline)
                Text(emptyDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyTitle: String {
        if hasSourceLimits {
            return "No limits selected"
        }
        return switch result.status {
        case .stale:
            "No saved limits"
        default:
            "No usage limits yet"
        }
    }

    private var emptyDetail: String {
        if hasSourceLimits {
            return "Choose visible limits in Context Panel on your Mac."
        }
        return switch result.status {
        case .loading:
            "Usage limits will appear when the update finishes."
        case .failure:
            "Try again after opening Context Panel on your Mac."
        case .stale:
            "No limits are available in the saved usage."
        case .unknown:
            "Open Context Panel on your Mac to share usage with this watch."
        case .healthy, .close, .limited:
            "No usage limits were reported."
        }
    }
}

private struct WatchLimitRow: View {
    let limit: WatchLimitDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(limit.subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(limit.usedTextLabeled)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }

            pressureTrack

            footer
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.accessibilitySentence(direction: .used))
    }

    @ViewBuilder
    private var pressureTrack: some View {
        if let ratio = limit.usedPressure.ratio {
            ProgressView(value: ratio)
                .tint(statusColor)
        } else {
            Capsule()
                .stroke(
                    statusColor,
                    style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
                .frame(height: 4)
        }
    }

    private var resetText: String? {
        limit.resetText.map { "reset \($0)" }
    }

    @ViewBuilder
    private var footer: some View {
        if let resetText {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(limit.context)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 4)
                    Text(resetText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(limit.context)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(resetText)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } else {
            Text(limit.context)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusColor: Color {
        switch limit.status {
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
}

private extension WatchSyncPresentationTone {
    var color: Color {
        switch self {
        case .available:
            .green
        case .warning:
            .yellow
        case .failure:
            .red
        case .neutral:
            .secondary
        }
    }
}
