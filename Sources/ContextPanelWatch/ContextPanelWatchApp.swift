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
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    model.reload()
                }
            }
        }
    }
}

@MainActor
@Observable
private final class WatchSyncModel {
    private let companionLoader: WatchCompanionLoader
    private var reloadTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var displayResult = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences
    private(set) var lastSyncErrorMessage: String?
    private(set) var isLoading = false

    init() {
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
            if WatchComplicationTimelineReloadPolicy.shouldReload(after: loaded) {
                WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelWatchWidgetIdentity.kind)
            }
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
