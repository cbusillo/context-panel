import ContextPanelCloudKitSync
import ContextPanelCore
import Foundation
import SwiftUI
import WidgetKit

private let watchValidationGalleryLaunchArgument = "--context-panel-validation-gallery"

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
    @State private var isValidationGalleryPresented = ProcessInfo.processInfo.arguments.contains(
        watchValidationGalleryLaunchArgument
    )

    var body: some View {
        NavigationStack {
            List {
                WatchUsageContent(
                    result: model.displayResult,
                    snapshot: model.snapshot,
                    displayPreferences: model.displayPreferences,
                    syncErrorMessage: model.lastSyncErrorMessage,
                    presentationDate: Date()
                )
            }
            .navigationDestination(isPresented: $isValidationGalleryPresented) {
                WatchValidationGalleryView()
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
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("CKAccountChangedNotification")
            )) { _ in
                model.handleCloudKitAccountChange()
            }
        }
    }
}

struct WatchUsageContent: View {
    let result: CompanionSyncLoadResult
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let syncErrorMessage: String?
    let presentationDate: Date

    private var displayLimits: [WatchLimitDisplay] {
        WatchLimitDisplay.mainLaneRows(
            from: snapshot,
            preferences: displayPreferences,
            maximumCount: 8
        )
    }

    private var keepWorkingForecast: KeepWorkingForecast? {
        guard snapshot.state == .ready else { return nil }
        let forecast = snapshot.keepWorkingForecast(presentationDate: presentationDate)
        return forecast.remainingPercent == nil ? nil : forecast
    }

    var body: some View {
        WatchStatusSection(
            result: result,
            snapshot: snapshot,
            syncErrorMessage: syncErrorMessage,
            presentationDate: presentationDate
        )

        if let keepWorkingForecast {
            WatchForecastSection(forecast: keepWorkingForecast)
        }

        if let alert = snapshot.primaryProviderAccessAlert {
            WatchProviderAccessSection(alert: alert, presentationDate: presentationDate)
        }

        if displayLimits.isEmpty {
            WatchEmptySection(
                result: result,
                hasSourceLimits: !snapshot.limits.isEmpty
            )
        } else {
            Section {
                ForEach(displayLimits) { limit in
                    WatchLimitRow(limit: limit, presentationDate: presentationDate)
                }
            }
        }
    }
}

@MainActor
@Observable
private final class WatchSyncModel {
    private let cache: WatchCompanionCache
    private let companionLoader: WatchCompanionLoader
    private let runtimeReceiptRecorder: RuntimeReceiptRecorder
    private let runtimeReceiptRelay: RuntimeReceiptRelayCoordinator?
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

    init(
        runtimeReceiptRecorder: RuntimeReceiptRecorder? = nil,
        runtimeReceiptRelay: RuntimeReceiptRelayCoordinator? = nil
    ) {
        let cache = WatchCompanionCache()
        self.cache = cache
        let remoteStore = CompanionCloudKitSyncStoreFactory.make()
        let presentationStore = CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
        self.runtimeReceiptRecorder = runtimeReceiptRecorder ?? .appGroupRequired(
            surface: .watchOSApp,
            appGroupID: ContextPanelLocations.watchAppGroupID
        )
        self.runtimeReceiptRelay = runtimeReceiptRelay ?? .appGroupReceiver(
            remoteStore: RuntimeReceiptCloudKitStoreFactory.make(),
            expectedManifestID: RuntimeBuildIdentityLoader.load(
                surface: .watchOSApp
            )?.build.manifestID,
            eligibleSurfaces: [.watchOSApp, .watchOSComplication],
            appGroupID: ContextPanelLocations.watchAppGroupID
        )
        companionLoader = WatchCompanionLoader(
            cache: cache,
            resolveUserScopeResolution: { await remoteStore.currentUserScopeResolution() },
            loadDocument: { now in await remoteStore.load(now: now) },
            loadPresentation: { await presentationStore.load() }
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

        reloadTask = Task { [weak self, companionLoader, runtimeReceiptRelay] in
            defer {
                if let self {
                    isLoading = false
                    reloadTask = nil
                    if needsReloadAfterCurrentTask {
                        reload()
                    }
                }
            }
            async let sessionRelayResult = runtimeReceiptRelay?.synchronizeSession(now: now)
            let loaded = await companionLoader.load(now: now)
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = await sessionRelayResult
            result = loaded.result
            displayResult = loaded.result
            lastSyncErrorMessage = loaded.result.errorMessage
            let loadedSnapshot = WidgetSnapshot.fromCompanionSync(
                loaded.result,
                now: now,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            )
            snapshot = loadedSnapshot
            let effectiveDisplayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: loaded.displayPreferences,
                synced: loaded.result.document?.widgetDisplayPreferences
            )
            displayPreferences = effectiveDisplayPreferences
            recordRuntimeReceipt(
                loaded: loaded,
                snapshot: loadedSnapshot,
                displayPreferences: effectiveDisplayPreferences,
                presentationDate: now
            )
            Task { [runtimeReceiptRelay] in
                _ = await runtimeReceiptRelay?.relayReceipts(now: Date())
            }
            if WatchComplicationTimelineReloadPolicy.shouldReload(after: loaded) {
                WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelWatchWidgetIdentity.kind)
            }
        }
    }

    func handleCloudKitAccountChange() {
        _ = cache.invalidateUserScope()
        result = CompanionSyncLoadResult(document: nil, status: .unknown)
        displayResult = result
        snapshot = WidgetSnapshot.fromCompanionSync(result)
        displayPreferences = .defaultPreferences
        lastSyncErrorMessage = nil
        WidgetCenter.shared.reloadAllTimelines()
        reload()
    }

    private func recordRuntimeReceipt(
        loaded: WatchCompanionCacheLoadResult,
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        presentationDate: Date
    ) {
        let evidence = CompanionRuntimeReceiptEvidence(
            result: loaded.result,
            snapshot: snapshot,
            displayPreferences: displayPreferences,
            appearanceSettings: nil,
            presentationSurface: .app,
            presentationMode: .watchApp,
            presentationDate: presentationDate
        )
        let exceededDeadlineWithoutSavedData = loaded.disposition == .deadlineExceeded
            && loaded.result.document == nil
        runtimeReceiptRecorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .watchApp,
            selectedSource: evidence.selectedSource,
            presentationDigest: evidence.presentationDigest,
            stateBranch: exceededDeadlineWithoutSavedData ? .unknown : evidence.stateBranch,
            outcome: exceededDeadlineWithoutSavedData ? .degraded : evidence.outcome,
            observedAt: presentationDate
        )
    }
}

private struct WatchForecastSection: View {
    let forecast: KeepWorkingForecast

    var body: some View {
        Section("OpenAI · \(forecast.windowCopy ?? "Limit") · \(forecast.accountCopy)") {
            HStack {
                Text(forecast.remainingPercent.map { "\($0)% left" } ?? "Capacity unknown")
                    .font(.headline.monospacedDigit())
                Spacer()
                Text(forecast.isLimited ? "limited" : forecast.paceBand.copy)
                    .foregroundStyle(forecast.isLimited || forecast.paceBand == .over ? .orange : .green)
            }
            if let outcome = forecast.outcomeCopy(density: .compact) {
                Text(outcome)
            }
            if let reset = forecast.resetCopy(density: .compact) {
                Text(reset)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WatchStatusSection: View {
    let result: CompanionSyncLoadResult
    let snapshot: WidgetSnapshot
    let syncErrorMessage: String?
    let presentationDate: Date

    private var presentation: WatchSyncPresentation {
        WatchSyncPresentation(
            result: result,
            snapshot: snapshot,
            syncErrorMessage: syncErrorMessage,
            now: presentationDate
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

private struct WatchProviderAccessSection: View {
    let alert: ProviderAccessAlert
    let presentationDate: Date

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Label(alert.title, systemImage: symbolName)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Text(alert.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let resetText = alert.resetDisplayText(now: presentationDate) {
                    Text("Plan access resets \(resetText)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
        }
    }

    private var symbolName: String {
        switch alert.accessState.kind {
        case .blockedUntilReset:
            "exclamationmark.octagon.fill"
        case .paidFallbackActive:
            "dollarsign.circle.fill"
        case .degraded:
            "questionmark.circle.fill"
        case .available, .pressure, .unknown:
            "circle.fill"
        }
    }

    private var statusColor: Color {
        switch alert.status {
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

    private var accessibilityLabel: String {
        var components = [alert.title, alert.accountName, alert.detail]
        if let resetText = alert.resetAccessibilityText(now: presentationDate) {
            components.append("Plan access resets at \(resetText)")
        }
        return components.joined(separator: ". ")
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
    let presentationDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            header

            pressureTrack

            footer
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.accessibilitySentence(direction: .used, now: presentationDate))
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(limit.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(limit.subtitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 4)
                usedText
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(limit.title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        subtitle
                        Spacer(minLength: 4)
                        usedText
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        subtitle
                        usedText
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var subtitle: some View {
        Text(limit.subtitle)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var usedText: some View {
        Text(limit.usedTextLabeled)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
            .accessibilityHidden(true)
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
        limit.resetText(now: presentationDate).map { "reset \($0)" }
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
