import ContextPanelCloudKitSync
import ContextPanelCore
import SwiftUI

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

                if model.snapshot.limits.isEmpty {
                    WatchEmptySection(
                        result: model.displayResult
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
    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()
    private let presentationPreferencesRemoteStore = CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
    private let presentationPreferencesStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.watchPresentationPreferencesCacheURL()
    )
    private var reloadTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var displayResult = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private var lastGoodDocument: CompanionSyncDocument?
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences
    private(set) var lastSyncErrorMessage: String?
    private(set) var isLoading = false

    var displayLimits: [WatchLimitDisplay] {
        WatchLimitDisplay.rows(from: snapshot, maximumCount: 8)
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
        let cachedDisplayPreferences = presentationPreferencesStore.loadIfAvailable()

        reloadTask = Task { [weak self, remoteStore, presentationPreferencesRemoteStore, presentationPreferencesStore] in
            defer {
                if let self {
                    isLoading = false
                    reloadTask = nil
                    if needsReloadAfterCurrentTask {
                        reload()
                    }
                }
            }
            async let loadedSnapshot = remoteStore.load(now: now)
            async let loadedPresentation = presentationPreferencesRemoteStore.load()
            let loaded = await loadedSnapshot.result
            let presentationDocument = await loadedPresentation.document
            guard !Task.isCancelled else { return }
            guard let self else { return }
            if let document = loaded.document {
                lastGoodDocument = document
            }
            let displayResult = loaded.document == nil && loaded.status == .failure
                ? CompanionSyncLoadResult(
                    document: lastGoodDocument,
                    status: lastGoodDocument == nil ? .failure : .stale,
                    errorMessage: lastGoodDocument == nil ? loaded.errorMessage : nil,
                    transportStatuses: lastGoodDocument == nil ? loaded.transportStatuses : []
                )
                : loaded
            result = loaded
            self.displayResult = displayResult
            lastSyncErrorMessage = loaded.status == .failure ? loaded.errorMessage : nil
            snapshot = WidgetSnapshot.fromCompanionSync(
                displayResult,
                now: now,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            )
            if let presentationPreferences = presentationDocument?.widgetDisplayPreferences {
                try? presentationPreferencesStore.save(presentationPreferences)
            }
            displayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: presentationDocument?.widgetDisplayPreferences ?? cachedDisplayPreferences,
                synced: displayResult.document?.widgetDisplayPreferences
            )
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
                        .foregroundStyle(presentation.tint)
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
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct WatchEmptySection: View {
    let result: CompanionSyncLoadResult

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
        switch result.status {
        case .stale:
            "No saved limits"
        default:
            "No usage limits yet"
        }
    }

    private var emptyDetail: String {
        switch result.status {
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

            HStack(spacing: 6) {
                Text(limit.context)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let resetText {
                    Text(resetText)
                        .lineLimit(1)
                }
            }
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

private struct WatchSyncPresentation {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    let generatedText: String?
    let generatedAccessibilityText: String?
    let shouldShowDetail: Bool

    init(result: CompanionSyncLoadResult, snapshot: WidgetSnapshot, syncErrorMessage: String?) {
        switch result.status {
        case .healthy, .close, .limited:
            if let generatedAt = result.document?.snapshot.generatedAt {
                generatedText = SnapshotFreshness.compactAgeText(since: generatedAt)
                generatedAccessibilityText = generatedAt.formatted(.relative(presentation: .numeric))
            } else {
                generatedText = nil
                generatedAccessibilityText = nil
            }
        case .stale, .failure, .loading, .unknown:
            generatedText = nil
            generatedAccessibilityText = nil
        }
        shouldShowDetail = result.status == .failure || result.status == .stale || result.status == .unknown

        switch result.status {
        case .healthy, .close, .limited:
            title = "Synced"
            detail = snapshot.message
            symbol = "checkmark.circle"
            tint = .green
        case .stale:
            title = "Saved usage is stale"
            detail = syncErrorMessage == nil
                ? "Open Context Panel on your Mac to refresh this watch."
                : "Showing saved usage because the latest update failed."
            symbol = "clock.badge.exclamationmark"
            tint = .yellow
        case .loading:
            title = "Checking for updates"
            detail = "Looking for the latest usage from your Mac."
            symbol = "arrow.clockwise.icloud"
            tint = .secondary
        case .failure:
            title = "Update unavailable"
            detail = "The watch could not load the latest usage from your Mac."
            symbol = "icloud.slash"
            tint = .red
        case .unknown:
            title = "Waiting for your Mac"
            detail = "Open Context Panel on your Mac to share usage with this watch."
            symbol = "icloud.and.arrow.down"
            tint = .secondary
        }
    }
}
