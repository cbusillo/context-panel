import ContextPanelCloudKitSync
import ContextPanelCore
import ContextPanelTVSupport
import SwiftUI

@main
struct ContextPanelTVApp: App {
    @UIApplicationDelegateAdaptor(ContextPanelTVAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            TVRootView()
        }
    }
}

@MainActor
private struct TVRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(TVPreferenceKeys.presentationMode) private var presentationModeRawValue = TVPresentationMode.fullDetail.rawValue
    @AppStorage(TVPreferenceKeys.providerBadgesEnabled) private var providerBadgesEnabled = false
    @AppStorage(TVPreferenceKeys.cloudKitSubscriptionError) private var subscriptionErrorMessage = ""
    @AppStorage(TVPreferenceKeys.remoteNotificationRegistrationError) private var remoteNotificationErrorMessage = ""
    @State private var model = TVSyncModel()
    @State private var navigationPath: [String] = []
    @State private var pendingProviderRawValue: String?
    @State private var badgeAuthorizationNoticeMessage: String?
    @State private var badgeAuthorizationTask: Task<Void, Never>?

    init() {
        #if DEBUG
        if let providerRawValue = TVPreviewFixtures.requestedProviderRawValue {
            _navigationPath = State(initialValue: [providerRawValue])
        }
        #endif
    }

    private var presentationMode: TVPresentationMode {
        TVPresentationMode(rawValue: presentationModeRawValue) ?? .fullDetail
    }

    private var presentation: TVRunwayPresentation {
        TVRunwayPresentation(
            snapshot: model.snapshot,
            preferences: model.displayPreferences,
            mode: presentationMode,
            isRefreshing: model.isLoading
        )
    }

    private var systemSurfacePublication: TVSystemSurfacePublication {
        TVSystemSurfacePublication(
            snapshot: model.snapshot,
            preferences: model.displayPreferences,
            version: model.displayVersion,
            mode: presentationMode,
            badgesEnabled: providerBadgesEnabled
        )
    }

    private var providerBadgesBinding: Binding<Bool> {
        Binding(
            get: { providerBadgesEnabled },
            set: { setProviderBadgesEnabled($0) }
        )
    }

    private var visibleNoticeMessage: String? {
        model.syncNoticeMessage
            ?? backgroundUpdateNoticeMessage
            ?? model.systemSurfaceNoticeMessage
            ?? badgeAuthorizationNoticeMessage
            ?? model.systemSurfaceEventMessage
    }

    private var backgroundUpdateNoticeMessage: String? {
        guard !subscriptionErrorMessage.isEmpty || !remoteNotificationErrorMessage.isEmpty else { return nil }
        return "Automatic updates couldn’t be enabled yet. Context Panel retries when it opens, and Refresh still works now."
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack(alignment: .bottom) {
                TVTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 40) {
                        TVHeaderView(
                            presentation: presentation,
                            receivedAt: model.lastReceivedAt,
                            isRefreshing: model.isLoading,
                            presentationModeRawValue: $presentationModeRawValue,
                            providerBadgesEnabled: providerBadgesBinding,
                            onRefresh: { model.reload() }
                        )

                        if presentation.isEmpty {
                            TVEmptyRunwayView(presentation: presentation)
                        } else {
                            TVProviderOverviewGrid(
                                sections: presentation.sections,
                                mode: presentationMode
                            )
                        }
                    }
                    .padding(.horizontal, 72)
                    .padding(.vertical, 48)
                }

                if let visibleNoticeMessage {
                    TVSyncAlert(message: visibleNoticeMessage)
                        .padding(.horizontal, 72)
                        .padding(.bottom, 28)
                }
            }
            .onChange(of: scenePhase, initial: true) { _, phase in
                if phase == .active {
                    model.reload()
                }
            }
            .onChange(of: systemSurfacePublication, initial: true) { _, publication in
                model.publishSystemSurfaces(publication)
            }
            .onReceive(NotificationCenter.default.publisher(
                for: .contextPanelTVBackgroundSyncDidUpdateCache
            )) { _ in
                model.adoptCachedSnapshot()
            }
            .navigationDestination(for: String.self) { providerRawValue in
                if let section = presentation.sections.first(where: { $0.provider.rawValue == providerRawValue }) {
                    TVProviderDetailView(
                        section: section,
                        mode: presentationMode,
                        snapshotState: presentation.state,
                        generatedAt: presentation.generatedAt
                    )
                }
            }
            .onChange(of: presentation.sections.map { $0.provider.rawValue }) { _, _ in
                resolvePendingProviderRoute()
            }
            .onOpenURL { url in
                guard let route = TVAppRoute(url: url) else { return }
                switch route {
                case .runway:
                    pendingProviderRawValue = nil
                    navigationPath = []
                case let .provider(provider):
                    pendingProviderRawValue = provider.rawValue
                    resolvePendingProviderRoute()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func resolvePendingProviderRoute() {
        guard let pendingProviderRawValue else { return }
        guard presentation.sections.contains(where: { $0.provider.rawValue == pendingProviderRawValue }) else {
            return
        }
        navigationPath = [pendingProviderRawValue]
        self.pendingProviderRawValue = nil
    }

    private func setProviderBadgesEnabled(_ enabled: Bool) {
        badgeAuthorizationTask?.cancel()
        guard enabled else {
            providerBadgesEnabled = false
            badgeAuthorizationNoticeMessage = nil
            return
        }

        badgeAuthorizationTask = Task {
            let authorized = await TVSystemSurfaceCoordinator.shared.requestBadgeAuthorization()
            guard !Task.isCancelled else { return }
            if authorized {
                providerBadgesEnabled = true
                badgeAuthorizationNoticeMessage = nil
            } else {
                providerBadgesEnabled = false
                badgeAuthorizationNoticeMessage =
                    "Provider badges are off. Allow badges in Apple TV Settings to enable them."
            }
        }
    }
}

private struct TVSystemSurfacePublication: Equatable, Sendable {
    let snapshot: WidgetSnapshot
    let preferences: WidgetDisplayPreferences
    let version: TVCompanionSyncVersion?
    let mode: TVPresentationMode
    let badgesEnabled: Bool
}

@MainActor
@Observable
private final class TVSyncModel {
    private let remoteStore: CompanionRemoteSyncStore
    private let cacheStore: CompanionSyncStore
    private let receiptStore: TVSyncReceiptStore
    private let usesPreviewFixture: Bool
    private let forcesRemoteFailure: Bool
    private var reloadTask: Task<Void, Never>?
    private var systemSurfaceTask: Task<Void, Never>?
    private var pendingSystemSurfacePublication: TVSystemSurfacePublication?
    private var systemSurfaceEventClearTask: Task<Void, Never>?

    private(set) var result: CompanionSyncLoadResult
    private(set) var displayResult: CompanionSyncLoadResult
    private(set) var snapshot: WidgetSnapshot
    private(set) var syncNoticeMessage: String?
    private(set) var systemSurfaceNoticeMessage: String?
    private(set) var systemSurfaceEventMessage: String?
    private(set) var lastReceivedAt: Date?
    private(set) var isLoading = false

    var displayPreferences: WidgetDisplayPreferences {
        displayResult.document?.widgetDisplayPreferences ?? .defaultPreferences
    }

    var displayVersion: TVCompanionSyncVersion? {
        displayResult.document.map { TVCompanionSyncVersion(document: $0) }
    }

    init(now: Date = Date()) {
        remoteStore = CompanionCloudKitSyncStoreFactory.make()
        let localCacheLocations = TVLocalCacheLocations.live()
        cacheStore = CompanionSyncStore(
            documentURL: localCacheLocations.companionDocumentURL
        )
        let localReceiptStore = TVSyncReceiptStore(
            receiptURL: localCacheLocations.receiptURL
        )
        receiptStore = localReceiptStore

        #if DEBUG
        forcesRemoteFailure = TVPreviewFixtures.forcesRemoteFailure
        #else
        forcesRemoteFailure = false
        #endif

        #if DEBUG
        if let fixtureResult = TVPreviewFixtures.requestedResult(now: now) {
            usesPreviewFixture = true
            result = fixtureResult
            displayResult = fixtureResult
            lastReceivedAt = fixtureResult.transportMetadata?.receivedAt
            syncNoticeMessage = fixtureResult.transportMetadata?.deliveryStatus == .failed
                ? Self.cloudUnavailableMessage
                : nil
            snapshot = WidgetSnapshot.fromCompanionSync(
                fixtureResult,
                now: now,
                stalenessPolicy: Self.stalenessPolicy
            )
            return
        }
        #endif

        usesPreviewFixture = false
        let cachedResult = cacheStore.load(policy: Self.stalenessPolicy, now: now)
        result = cachedResult
        displayResult = cachedResult
        lastReceivedAt = cachedResult.document
            .flatMap { localReceiptStore.load(matching: $0)?.receivedAt }
        snapshot = WidgetSnapshot.fromCompanionSync(
            cachedResult,
            now: now,
            stalenessPolicy: Self.stalenessPolicy
        )
    }

    func reload() {
        guard !usesPreviewFixture else { return }
        guard reloadTask == nil else { return }

        let startedAt = Date()
        let startingVersion = displayVersion
        isLoading = true
        syncNoticeMessage = nil
        result = CompanionSyncLoadResult(document: result.document, status: .loading)
        let shouldForceRemoteFailure = forcesRemoteFailure

        reloadTask = Task { [weak self, remoteStore, cacheStore, receiptStore] in
            defer {
                if let self {
                    isLoading = false
                    reloadTask = nil
                }
            }

            let remoteLoad = shouldForceRemoteFailure
                ? Self.forcedRemoteFailureLoadResult()
                : await remoteStore.load(now: startedAt)
            guard !Task.isCancelled, let self else { return }
            let completedAt = Date()
            let loaded = remoteLoad.result
            result = loaded
            var persistenceNoticeMessage: String?
            var wasSupersededByNewerCache = false

            if let document = loaded.document {
                let cacheSaveResult = cacheStore.saveResult(
                    document,
                    policy: Self.stalenessPolicy,
                    now: completedAt
                ) { currentResult in
                    TVCompanionSyncCachePolicy.shouldKeepCurrent(
                        currentResult,
                        replacingWith: document
                    )
                }
                let incomingVersion = TVCompanionSyncVersion(document: document)
                switch cacheSaveResult {
                case let .keptCurrent(currentResult):
                    result = currentResult
                    displayResult = currentResult
                    if let currentDocument = currentResult.document {
                        if TVCompanionSyncVersion(document: currentDocument) == incomingVersion {
                            do {
                                try receiptStore.save(
                                    document: currentDocument,
                                    receivedAt: completedAt
                                )
                            } catch {
                                persistenceNoticeMessage = Self.syncReceiptUnavailableMessage
                            }
                        }
                        lastReceivedAt = receiptStore.load(matching: currentDocument)?.receivedAt
                            ?? lastReceivedAt
                    }
                case let .saved(saveResult):
                    if saveResult.succeeded {
                        do {
                            try receiptStore.save(document: document, receivedAt: completedAt)
                        } catch {
                            persistenceNoticeMessage = Self.syncReceiptUnavailableMessage
                        }
                    } else {
                        persistenceNoticeMessage = Self.offlineCacheUnavailableMessage
                    }
                    lastReceivedAt = receiptStore.load(matching: document)?.receivedAt
                        ?? completedAt
                    displayResult = loaded
                }
            } else {
                let cached = cacheStore.load(policy: Self.stalenessPolicy, now: completedAt)
                if let cachedDocument = cached.document {
                    let receipt = receiptStore.load(matching: cachedDocument)
                    lastReceivedAt = receipt?.receivedAt ?? lastReceivedAt
                    wasSupersededByNewerCache = TVCompanionSyncAttemptPolicy.cacheSupersedesAttempt(
                        document: cachedDocument,
                        receipt: receipt,
                        startingVersion: startingVersion,
                        startedAt: startedAt
                    )
                    if wasSupersededByNewerCache {
                        result = cached
                        displayResult = cached
                    } else {
                        displayResult = CompanionSyncLoadResult(
                            document: cachedDocument,
                            status: .stale,
                            transportMetadata: cached.transportMetadata,
                            transportStatuses: loaded.transportStatuses
                        )
                    }
                } else {
                    displayResult = loaded
                }
            }

            syncNoticeMessage = TVSyncNoticePolicy.shouldShowCloudUnavailable(for: remoteLoad)
                && !wasSupersededByNewerCache
                ? Self.cloudUnavailableMessage
                : persistenceNoticeMessage
            snapshot = WidgetSnapshot.fromCompanionSync(
                displayResult,
                now: completedAt,
                stalenessPolicy: Self.stalenessPolicy
            )
        }
    }

    func adoptCachedSnapshot(now: Date = Date()) {
        guard !usesPreviewFixture else { return }
        let cachedResult = cacheStore.load(policy: Self.stalenessPolicy, now: now)
        guard let document = cachedResult.document else { return }

        result = cachedResult
        displayResult = cachedResult
        lastReceivedAt = receiptStore.load(matching: document)?.receivedAt
        syncNoticeMessage = nil
        snapshot = WidgetSnapshot.fromCompanionSync(
            cachedResult,
            now: now,
            stalenessPolicy: Self.stalenessPolicy
        )
    }

    func publishSystemSurfaces(_ publication: TVSystemSurfacePublication) {
        pendingSystemSurfacePublication = publication
        guard systemSurfaceTask == nil else { return }

        systemSurfaceTask = Task { [weak self] in
            guard let self else { return }
            defer { systemSurfaceTask = nil }

            while let publication = pendingSystemSurfacePublication {
                pendingSystemSurfacePublication = nil
                let update = await TVSystemSurfaceCoordinator.shared.update(
                    snapshot: publication.snapshot,
                    preferences: publication.preferences,
                    version: publication.version
                )
                guard !Task.isCancelled else { return }
                systemSurfaceNoticeMessage = update.noticeMessage
                if update.badgeCount == 0 {
                    systemSurfaceEventClearTask?.cancel()
                    systemSurfaceEventMessage = nil
                } else {
                    presentSystemSurfaceEvent(update.eventMessage)
                }
            }
        }
    }

    private func presentSystemSurfaceEvent(_ message: String?) {
        guard let message else { return }
        systemSurfaceEventClearTask?.cancel()
        systemSurfaceEventMessage = message
        systemSurfaceEventClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, self?.systemSurfaceEventMessage == message else { return }
            self?.systemSurfaceEventMessage = nil
        }
    }

    private static let stalenessPolicy = SnapshotStoreStalenessPolicy.appDefault(
        maximumAge: SnapshotFreshness.companionProviderMaximumAge
    )

    private static let cloudUnavailableMessage =
        "Cloud sync is unavailable. Showing saved runway; open Context Panel on your Mac if this persists."
    private static let offlineCacheUnavailableMessage =
        "Runway loaded, but it could not be saved for offline use."
    private static let syncReceiptUnavailableMessage =
        "Runway saved for offline use, but its sync time could not be recorded."

    private static func forcedRemoteFailureLoadResult() -> CompanionRemoteSyncLoadResult {
        let message = "Offline validation mode"
        return CompanionRemoteSyncLoadResult(
            result: CompanionSyncLoadResult(
                document: nil,
                status: .failure,
                errorMessage: message,
                transportStatuses: [
                    CompanionSyncTransportStatus(
                        source: .cloudKit,
                        isAvailable: false,
                        succeeded: false,
                        loadedDocument: false,
                        errorMessage: message
                    ),
                ]
            ),
            outcome: CompanionRemoteSyncOutcome(
                isAvailable: false,
                succeeded: false,
                errorMessage: message
            )
        )
    }
}

private struct TVHeaderView: View {
    let presentation: TVRunwayPresentation
    let receivedAt: Date?
    let isRefreshing: Bool
    @Binding var presentationModeRawValue: String
    @Binding var providerBadgesEnabled: Bool
    let onRefresh: () -> Void

    private var presentationMode: TVPresentationMode {
        TVPresentationMode(rawValue: presentationModeRawValue) ?? .fullDetail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 36) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Context Panel")
                    .font(.system(size: 58, weight: .bold, design: .rounded))

                Text(presentation.headline)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(statusColor)

                Text(presentation.detail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: 900, alignment: .leading)
            }

            Spacer(minLength: 32)

            VStack(alignment: .trailing, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    VStack(alignment: .trailing, spacing: 8) {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(statusColor)
                                .frame(width: 12, height: 12)
                            Text(presentation.status.tvStatusLabel)
                                .font(.headline)
                                .lineLimit(1)
                        }

                        if presentation.state == .setupNeeded {
                            Text(isRefreshing ? "Contacting CloudKit" : "No usage received yet")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            HStack(spacing: 8) {
                                Text("Usage \(Self.compactAge(since: presentation.generatedAt, now: context.date))")
                                if let receivedAt {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text("Synced \(Self.compactAge(since: receivedAt, now: context.date))")
                                }
                            }
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                    }
                }

                HStack(spacing: 16) {
                    Button(action: onRefresh) {
                        Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)

                    Menu {
                        Picker("Presentation", selection: $presentationModeRawValue) {
                            ForEach(TVPresentationMode.allCases) { mode in
                                Text(mode.displayName)
                                .tag(mode.rawValue)
                            }
                        }

                        Divider()

                        Toggle(isOn: $providerBadgesEnabled) {
                            Label("Provider Attention Badge", systemImage: "app.badge")
                        }
                    } label: {
                        Label(presentationMode.displayName, systemImage: "slider.horizontal.3")
                    }
                    .accessibilityHint(
                        "\(presentationMode.detail) Provider badges are optional and show only limited or failed providers."
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var statusColor: Color {
        TVTheme.statusColor(presentation.status)
    }

    private static func compactAge(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }
}

private struct TVProviderOverviewGrid: View {
    let sections: [TVProviderRunwaySection]
    let mode: TVPresentationMode

    var body: some View {
        GeometryReader { geometry in
            let spacing: CGFloat = 30
            let totalSpacing = spacing * CGFloat(max(sections.count - 1, 0))
            let availableWidth = max(geometry.size.width - totalSpacing, 1)
            let cardWidth = min(560, availableWidth / CGFloat(max(sections.count, 1)))

            HStack(alignment: .top, spacing: spacing) {
                ForEach(sections) { section in
                    NavigationLink(value: section.provider.rawValue) {
                        TVProviderOverviewCard(section: section, mode: mode)
                            .frame(width: cardWidth)
                    }
                    .buttonStyle(TVFocusButtonStyle())
                    .focusEffectDisabled()
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
        }
        .frame(height: 520)
    }
}

private struct TVProviderOverviewCard: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let section: TVProviderRunwaySection
    let mode: TVPresentationMode

    private var lane: TVRunwayLane {
        section.primaryLane ?? section.lanes[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(TVTheme.providerColor(section.provider))
                    .frame(width: 8, height: 32)

                Text(section.provider.displayName.uppercased())
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 12)

                Text(section.status.tvStatusLabel)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(TVTheme.statusColor(section.status))
                    .lineLimit(1)
            }

            Text(lane.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            if let remainingPercent = lane.remainingPercent {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(remainingPercent)%")
                        .font(.system(size: 92, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("left")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(lane.kind == .accountStatus ? "No fresh capacity" : "Unknown")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TVCapacityBar(ratio: lane.capacityRatio, provider: lane.provider)

            if let closestLane = section.closestLane {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Closest to limit")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(TVTheme.statusColor(closestLane.status))
                    Text(closestLimitText(closestLane))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if mode != .countsOnly {
                VStack(alignment: .leading, spacing: 7) {
                    if let timingAndAccountsText {
                        Text(timingAndAccountsText)
                    }
                    if let detailText = lane.detailText {
                        Text(detailText)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

        }
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 468, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    TVTheme.providerColor(section.provider).opacity(0.22),
                    Color.white.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 28, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(
                    isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.1),
                    lineWidth: isFocused ? 3 : 1
                )
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.025 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.16), radius: isFocused ? 26 : 10, y: 12)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open \(section.provider.displayName) details")
    }

    private var accessibilityLabel: String {
        var components = [section.provider.displayName, section.status.tvStatusLabel, lane.title]
        if let remainingPercent = lane.remainingPercent {
            components.append("\(remainingPercent) percent left")
        }
        if let accessibilityResetText = lane.accessibilityResetText {
            components.append(accessibilityResetText)
        }
        if let accountCountText = lane.accountCountText {
            components.append(accountCountText)
        }
        if let detailText = lane.detailText {
            components.append(detailText)
        }
        if let closestLane = section.closestLane {
            components.append("Closest to limit, \(closestLimitText(closestLane))")
        }
        components.append(section.trackedWindowText)
        return components.joined(separator: ", ")
    }

    private var timingAndAccountsText: String? {
        let components = [lane.resetText, lane.accountCountText].compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func closestLimitText(_ closestLane: TVRunwayLane) -> String {
        if let remainingPercent = closestLane.remainingPercent {
            return "\(closestLane.title) · \(remainingPercent)% left"
        }
        return "\(closestLane.title) · unknown"
    }
}

private struct TVProviderDetailView: View {
    let section: TVProviderRunwaySection
    let mode: TVPresentationMode
    let snapshotState: WidgetSnapshotState
    let generatedAt: Date

    private var primaryMetrics: [TVRunwayMetric] {
        guard mode == .fullDetail,
              let primaryLane = section.detailPrimaryLane,
              primaryLane.metrics.count > 1 else {
            return []
        }
        return primaryLane.metrics
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(TVTheme.providerColor(section.provider))
                        .frame(width: 9, height: 42)
                    Text(section.provider.displayName)
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                    Text(section.status.tvStatusLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TVTheme.statusColor(section.status))
                    Spacer()
                    Text(section.trackedWindowText)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                TVFreshnessNotice(state: snapshotState, generatedAt: generatedAt)

                if let primaryLane = section.detailPrimaryLane {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Primary runway")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        NavigationLink {
                            TVRunwayDetailView(
                                lane: primaryLane,
                                mode: mode,
                                snapshotState: snapshotState,
                                generatedAt: generatedAt
                            )
                        } label: {
                            TVProviderPrimaryCard(lane: primaryLane, mode: mode)
                        }
                        .buttonStyle(TVFocusButtonStyle())
                        .focusEffectDisabled()
                    }
                }

                if !section.accountNames.isEmpty && primaryMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(section.accountNames.count == 1 ? "Account" : "Accounts")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(section.accountNames.joined(separator: " · "))
                            .font(.title3.weight(.medium))
                            .lineLimit(2)
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.white.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                    )
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accountNamesAccessibilityLabel)
                }

                if !primaryMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Account runway")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        ForEach(primaryMetrics) { metric in
                            TVMetricRow(metric: metric, provider: section.provider)
                        }
                    }
                }

                if !section.detailSecondaryLanes.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Other limits")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        ForEach(section.detailSecondaryLanes) { lane in
                            NavigationLink {
                                TVRunwayDetailView(
                                    lane: lane,
                                    mode: mode,
                                    snapshotState: snapshotState,
                                    generatedAt: generatedAt
                                )
                            } label: {
                                TVProviderLaneRow(lane: lane, mode: mode)
                            }
                            .buttonStyle(TVFocusButtonStyle())
                            .focusEffectDisabled()
                        }
                    }
                }
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 64)
        }
        .background(TVTheme.background.ignoresSafeArea())
    }

    private var accountNamesAccessibilityLabel: String {
        let heading = section.accountNames.count == 1 ? "Account" : "Accounts"
        return ([heading] + section.accountNames).joined(separator: ", ")
    }
}

private struct TVProviderPrimaryCard: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let lane: TVRunwayLane
    let mode: TVPresentationMode

    var body: some View {
        HStack(alignment: .center, spacing: 48) {
            VStack(alignment: .leading, spacing: 16) {
                Text(lane.title)
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .lineLimit(2)
                Text(lane.statusText)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(TVTheme.statusColor(lane.status))

                if let metadataText {
                    Text(metadataText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 32)

            VStack(alignment: .trailing, spacing: 20) {
                if let remainingPercent = lane.remainingPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(remainingPercent)%")
                            .font(.system(size: mode == .countsOnly ? 92 : 86, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("left")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(lane.kind == .accountStatus ? "No fresh capacity" : "Unknown")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                TVCapacityBar(ratio: lane.capacityRatio, provider: lane.provider)
                    .frame(width: 620)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    TVTheme.providerColor(lane.provider).opacity(0.2),
                    Color.white.opacity(0.055),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(
                    isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.09),
                    lineWidth: isFocused ? 3 : 1
                )
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.018 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.42 : 0.14), radius: isFocused ? 24 : 8, y: 12)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open \(lane.title) details")
    }

    private var metadataText: String? {
        guard mode != .countsOnly else { return nil }
        let components = [lane.accountCountText, lane.resetText, lane.exactCapacityText, lane.detailText]
            .compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var components = [lane.provider.displayName, lane.title, lane.statusText]
        if let remainingPercent = lane.remainingPercent {
            components.append("\(remainingPercent) percent left")
        }
        if let accessibilityResetText = lane.accessibilityResetText {
            components.append(accessibilityResetText)
        }
        if let accountCountText = lane.accountCountText {
            components.append(accountCountText)
        }
        if let exactCapacityText = lane.exactCapacityText {
            components.append(exactCapacityText)
        }
        if let detailText = lane.detailText {
            components.append(detailText)
        }
        return components.joined(separator: ", ")
    }
}

private struct TVProviderLaneRow: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let lane: TVRunwayLane
    let mode: TVPresentationMode

    var body: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text(lane.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if let metadataText {
                    Text(metadataText)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let remainingPercent = lane.remainingPercent {
                    Text("\(remainingPercent)% left")
                        .font(.title2.bold().monospacedDigit())
                } else {
                    Text(lane.kind == .accountStatus ? "No fresh capacity" : "Unknown")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(lane.statusText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TVTheme.statusColor(lane.status))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    TVTheme.providerColor(lane.provider).opacity(0.12),
                    Color.white.opacity(0.045),
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.08),
                    lineWidth: isFocused ? 3 : 1
                )
        }
        .scaleEffect(isFocused && !reduceMotion ? 1.012 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.36 : 0.1), radius: isFocused ? 20 : 6, y: 10)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Open \(lane.title) details")
    }

    private var metadataText: String? {
        guard mode != .countsOnly else { return nil }
        let components = [lane.accountCountText, lane.resetText, lane.exactCapacityText, lane.detailText]
            .compactMap { $0 }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var components = [lane.provider.displayName, lane.title, lane.statusText]
        if let remainingPercent = lane.remainingPercent {
            components.append("\(remainingPercent) percent left")
        }
        if let accessibilityResetText = lane.accessibilityResetText {
            components.append(accessibilityResetText)
        }
        components.append(contentsOf: metadataComponents)
        return components.joined(separator: ", ")
    }

    private var metadataComponents: [String] {
        guard mode != .countsOnly else { return [] }
        return [lane.accountCountText, lane.exactCapacityText, lane.detailText]
            .compactMap { $0 }
    }
}

private struct TVCapacityBar: View {
    let ratio: Double?
    let provider: Provider

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.11))

                if let ratio {
                    Capsule()
                        .fill(TVTheme.providerColor(provider))
                        .frame(width: geometry.size.width * min(max(ratio, 0), 1))
                } else {
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [8, 7]))
                }
            }
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}

private struct TVRunwayDetailView: View {
    let lane: TVRunwayLane
    let mode: TVPresentationMode
    let snapshotState: WidgetSnapshotState
    let generatedAt: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(lane.provider.displayName.uppercased())
                            .font(.headline.weight(.bold))
                            .foregroundStyle(TVTheme.providerColor(lane.provider))
                            .tracking(2)
                        Text(lane.title)
                            .font(.system(size: 58, weight: .bold, design: .rounded))
                    }
                    Spacer()
                    Text(lane.statusText)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TVTheme.statusColor(lane.status))
                }

                TVFreshnessNotice(state: snapshotState, generatedAt: generatedAt)

                if lane.kind == .accountStatus {
                    Label(
                        "Open Context Panel on your Mac to refresh or reconnect this account.",
                        systemImage: "macbook"
                    )
                    .font(.title3)
                    .foregroundStyle(.secondary)
                }

                if let remainingPercent = lane.remainingPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(remainingPercent)%")
                            .font(.system(size: 108, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("left")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    TVCapacityBar(ratio: lane.capacityRatio, provider: lane.provider)
                        .frame(maxWidth: 900)
                }

                if !lane.accountNames.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Accounts")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(lane.accountNames.joined(separator: " · "))
                            .font(.title3)
                    }
                }

                if !lane.metrics.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Capacity details")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        ForEach(lane.metrics) { metric in
                            TVMetricRow(metric: metric, provider: lane.provider)
                        }
                    }
                }
            }
            .padding(.horizontal, 96)
            .padding(.vertical, 72)
        }
        .background(TVTheme.background.ignoresSafeArea())
    }
}

private struct TVMetricRow: View {
    let metric: TVRunwayMetric
    let provider: Provider

    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text(metric.title)
                    .font(.title3.weight(.semibold))
                HStack(spacing: 12) {
                    if let exactCapacityText = metric.exactCapacityText {
                        Text(exactCapacityText)
                    }
                    if let resetText = metric.resetText {
                        Text(resetText)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Spacer()

            if let remainingPercent = metric.remainingPercent {
                Text("\(remainingPercent)% left")
                    .font(.title2.bold().monospacedDigit())
            } else {
                Text(metric.status.tvStatusLabel)
                    .font(.headline)
                    .foregroundStyle(TVTheme.statusColor(metric.status))
            }
        }
        .padding(26)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TVEmptyRunwayView: View {
    let presentation: TVRunwayPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 64, weight: .medium))
                .foregroundStyle(.secondary)
            Text(emptyStateTitle)
                .font(.system(size: 44, weight: .bold, design: .rounded))
            Text(presentation.detail)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 780, alignment: .leading)
        }
        .padding(52)
        .frame(maxWidth: .infinity, minHeight: 360, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private var emptyStateTitle: String {
        if presentation.status == .loading {
            return "Checking for Mac sync"
        }
        if presentation.state == .failure {
            return "Check your Mac connection"
        }
        return "Publish from your Mac"
    }
}

private struct TVSyncAlert: View {
    let message: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct TVFreshnessNotice: View {
    let state: WidgetSnapshotState
    let generatedAt: Date

    @ViewBuilder
    var body: some View {
        if state == .stale || state == .failure {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Label(
                    state == .failure
                        ? "Provider issue · data \(Self.compactAge(since: generatedAt, now: context.date)) old"
                        : "Saved data · \(Self.compactAge(since: generatedAt, now: context.date)) old",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.headline)
                .foregroundStyle(state == .failure ? .orange : .yellow)
                .accessibilityLabel(
                    state == .failure
                        ? "Provider issue. Data from \(Self.spokenAge(since: generatedAt, now: context.date)) ago"
                        : "Saved data from \(Self.spokenAge(since: generatedAt, now: context.date)) ago"
                )
            }
        }
    }

    private static func compactAge(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private static func spokenAge(since date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "less than one minute" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) \(minutes == 1 ? "minute" : "minutes")" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) \(hours == 1 ? "hour" : "hours")" }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days")"
    }
}

private enum TVTheme {
    static let background = LinearGradient(
        colors: [
            Color(red: 0.035, green: 0.045, blue: 0.07),
            Color(red: 0.015, green: 0.02, blue: 0.035),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func providerColor(_ provider: Provider) -> Color {
        switch provider {
        case .openAI:
            Color(red: 0.24, green: 0.82, blue: 0.69)
        case .anthropic:
            Color(red: 0.96, green: 0.57, blue: 0.39)
        case .google:
            Color(red: 0.38, green: 0.66, blue: 1)
        }
    }

    static func statusColor(_ status: UsageStatus) -> Color {
        switch status {
        case .healthy:
            .green
        case .close:
            .yellow
        case .limited, .failure:
            .orange
        case .stale:
            .yellow
        case .unknown, .loading:
            .secondary
        }
    }
}

private struct TVFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private extension UsageStatus {
    var tvStatusLabel: String {
        switch self {
        case .healthy:
            "Available"
        case .close:
            "Close to limit"
        case .limited:
            "Limited"
        case .stale:
            "Stale"
        case .unknown:
            "Unknown"
        case .failure:
            "Needs attention"
        case .loading:
            "Refreshing"
        }
    }
}
