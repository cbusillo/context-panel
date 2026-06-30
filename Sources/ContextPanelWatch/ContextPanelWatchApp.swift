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
                if model.snapshot.limits.isEmpty {
                    WatchEmptySection(
                        result: model.displayResult,
                        syncErrorMessage: model.lastSyncErrorMessage
                    )
                } else {
                    Section {
                        ForEach(model.displayLimits) { limit in
                            WatchLimitRow(limit: limit)
                        }
                    }
                }

                WatchStatusSection(
                    result: model.displayResult,
                    snapshot: model.snapshot,
                    syncErrorMessage: model.lastSyncErrorMessage
                )
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
    private var reloadTask: Task<Void, Never>?

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var displayResult = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private var lastGoodDocument: CompanionSyncDocument?
    private(set) var lastSyncErrorMessage: String?
    private(set) var isLoading = false

    var displayLimits: [WatchLimitDisplay] {
        WatchLimitDisplay.rows(from: snapshot, maximumCount: 5)
    }

    func reload(now: Date = Date()) {
        guard reloadTask == nil else { return }
        isLoading = true
        result = CompanionSyncLoadResult(document: result.document, status: .loading)
        displayResult = CompanionSyncLoadResult(document: displayResult.document, status: .loading)
        lastSyncErrorMessage = nil

        reloadTask = Task { [remoteStore] in
            let loaded = await remoteStore.load(now: now).result
            guard !Task.isCancelled else { return }
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
            isLoading = false
            reloadTask = nil
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
            HStack(spacing: 6) {
                Image(systemName: presentation.symbol)
                    .foregroundStyle(presentation.tint)
                Text(presentation.title)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let generatedText = presentation.generatedText {
                    Text(generatedText)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .font(.caption2.weight(.medium))
            .padding(.vertical, 1)
        }
    }
}

private struct WatchEmptySection: View {
    let result: CompanionSyncLoadResult
    let syncErrorMessage: String?

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
        case .loading:
            "Checking sync"
        case .failure:
            "Sync unavailable"
        case .stale:
            "Showing saved sync"
        default:
            "Waiting for Mac sync"
        }
    }

    private var emptyDetail: String {
        switch result.status {
        case .failure:
            syncErrorMessage.map { "The watch could not read the latest iCloud snapshot: \($0)" }
                ?? "The watch could not read the latest iCloud snapshot."
        case .stale:
            syncErrorMessage.map { "Showing saved data because the latest refresh failed: \($0)" }
                ?? "Showing saved data until your Mac publishes a fresh snapshot."
        default:
            "Open Context Panel on your Mac to publish usage limits through iCloud."
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
                Text(limit.remainingText)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(statusColor)
            }

            ProgressView(value: capacityRatio)
                .tint(statusColor)

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
    }

    private var capacityRatio: Double {
        limit.capacityRatio
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
        case .stale, .unknown, .loading:
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
    let shouldShowDetail: Bool

    init(result: CompanionSyncLoadResult, snapshot: WidgetSnapshot, syncErrorMessage: String?) {
        generatedText = result.document.map { document in
            document.snapshot.generatedAt.formatted(.relative(presentation: .numeric))
        }
        shouldShowDetail = false

        if let errorMessage = result.errorMessage ?? syncErrorMessage, result.status == .failure {
            title = "Sync failed"
            detail = "The watch could not read the latest iCloud snapshot: \(errorMessage)"
            symbol = "icloud.slash"
            tint = .red
            return
        }

        switch result.status {
        case .healthy, .close, .limited:
            title = "Synced"
            detail = snapshot.message
            symbol = "checkmark.circle"
            tint = .green
        case .stale:
            title = "Mac sync is stale"
            detail = syncErrorMessage.map { "Showing saved data. Latest refresh failed: \($0)" }
                ?? "Open Context Panel on your Mac to publish a fresh snapshot."
            symbol = "clock.badge.exclamationmark"
            tint = .yellow
        case .loading:
            title = "Loading Mac sync"
            detail = "Checking iCloud for the latest usage limits."
            symbol = "arrow.clockwise.icloud"
            tint = .secondary
        case .failure:
            title = "Sync failed"
            detail = syncErrorMessage.map { "The watch app could not read the synced snapshot: \($0)" }
                ?? "The watch app could not read the synced snapshot."
            symbol = "icloud.slash"
            tint = .red
        case .unknown:
            title = "Waiting for Mac sync"
            detail = "Open Context Panel on your Mac to publish usage limits through iCloud."
            symbol = "icloud.and.arrow.down"
            tint = .secondary
        }
    }

    private static func statusColor(_ status: UsageStatus) -> Color {
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
}
