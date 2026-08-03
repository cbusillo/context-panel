@preconcurrency import CloudKit
import ContextPanelCore
import ContextPanelCloudKitSync
import ContextPanelCompanionSupport
import ContextPanelSettingsUI
import ContextPanelValidationGalleryUI
import ContextPanelWidgetUI
import SwiftUI
import UIKit
import WidgetKit

@MainActor
private func companionRuntimeDeviceClass() -> RuntimeCompanionDeviceClass {
    #if os(visionOS)
    .vision
    #else
    UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    #endif
}

private func reloadContextPanelCompanionWidgetTimeline() {
    WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelCompanionWidgetIdentity.kind)
}

private struct CompanionWidgetRenderSignature: Equatable {
    let state: WidgetSnapshotState
    let generatedAt: Date
    let comparesGeneratedAt: Bool
    let limits: [UsageLimit]
    let reports: [StoredProviderReport]
    let promptCacheObservations: [PromptCacheObservation]
    let promptCacheWidgetState: PromptCacheWidgetState
    let observedBurnRates: [String: ObservedBurnRate]
    let fastModeForecastSettings: FastModeForecastSettings
    let status: UsageStatus
    let message: String
    let refreshAttentionSummary: RefreshAttentionSummary?
    let syncErrorMessage: String?
    let displayPreferences: WidgetDisplayPreferences
    let deliveryStatus: CompanionSyncDeliveryStatus?

    init(
        result: CompanionSyncLoadResult,
        displayPreferences: WidgetDisplayPreferences,
        now: Date
    ) {
        let snapshot = WidgetSnapshot.fromCompanionSync(
            result,
            now: now,
            stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(
                maximumAge: SnapshotFreshness.companionProviderMaximumAge
            )
        )
        state = snapshot.state
        generatedAt = snapshot.generatedAt
        comparesGeneratedAt = result.document != nil
        limits = snapshot.limits
        reports = snapshot.reports
        promptCacheObservations = snapshot.promptCacheObservations
        promptCacheWidgetState = snapshot.promptCacheWidgetState
        observedBurnRates = snapshot.observedBurnRates
        fastModeForecastSettings = snapshot.fastModeForecastSettings
        status = snapshot.status
        message = snapshot.message
        refreshAttentionSummary = snapshot.refreshAttentionSummary
        syncErrorMessage = snapshot.syncErrorMessage
        self.displayPreferences = displayPreferences
        deliveryStatus = result.transportMetadata?.deliveryStatus
    }

    var snapshot: WidgetSnapshot {
        WidgetSnapshot(
            state: state,
            generatedAt: generatedAt,
            limits: limits,
            reports: reports,
            promptCacheObservations: promptCacheObservations,
            promptCacheWidgetState: promptCacheWidgetState,
            observedBurnRates: observedBurnRates,
            fastModeForecastSettings: fastModeForecastSettings,
            status: status,
            message: message,
            refreshAttentionSummary: refreshAttentionSummary,
            syncErrorMessage: syncErrorMessage
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
            && lhs.comparesGeneratedAt == rhs.comparesGeneratedAt
            && (!lhs.comparesGeneratedAt || !rhs.comparesGeneratedAt || lhs.generatedAt == rhs.generatedAt)
            && lhs.limits == rhs.limits
            && lhs.reports == rhs.reports
            && lhs.promptCacheObservations == rhs.promptCacheObservations
            && lhs.promptCacheWidgetState == rhs.promptCacheWidgetState
            && lhs.observedBurnRates == rhs.observedBurnRates
            && lhs.fastModeForecastSettings == rhs.fastModeForecastSettings
            && lhs.status == rhs.status
            && lhs.message == rhs.message
            && lhs.refreshAttentionSummary == rhs.refreshAttentionSummary
            && lhs.syncErrorMessage == rhs.syncErrorMessage
            && lhs.displayPreferences == rhs.displayPreferences
            && lhs.deliveryStatus == rhs.deliveryStatus
    }
}

@main
struct ContextPanelCompanionApp: App {
    @UIApplicationDelegateAdaptor(CompanionAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
        }
    }
}

private final class CompanionAppDelegate: NSObject, UIApplicationDelegate {
    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        Task { [remoteStore] in
            _ = await remoteStore.registerSubscription()
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let notification = CKNotification(
            fromRemoteNotificationDictionary: userInfo
        ) as? CKQueryNotification,
            CompanionCloudKitNotificationPolicy.accepts(
                subscriptionID: notification.subscriptionID,
                recordName: notification.recordID?.recordName
            ) else {
            completionHandler(.noData)
            return
        }
        Task { [remoteStore] in
            let loaded = await Task.detached(priority: .userInitiated) {
                await CompanionSyncLoader.load(remoteStore: remoteStore)
            }.value
            await MainActor.run {
                if loaded.document != nil {
                    reloadContextPanelCompanionWidgetTimeline()
                    completionHandler(.newData)
                } else if loaded.status == .failure {
                    completionHandler(.failed)
                } else {
                    completionHandler(.noData)
                }
            }
        }
    }
}

@MainActor
private struct CompanionRootView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CompanionSyncModel()
    @State private var galleryRoute: ValidationGalleryRoute?

    private var previewThemeVariant: CPWThemeVariant {
        #if os(visionOS)
        model.appearanceSettings.visionOSAppAppearance.cpwThemeVariant
        #else
        .adaptive
        #endif
    }

    private var surfacePalette: CompanionSurfacePalette {
        #if os(visionOS)
        .visionOS(appearance: model.appearanceSettings.visionOSAppAppearance)
        #else
        .adaptive
        #endif
    }

    private var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    private var isPad: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var layoutPlatform: CompanionLayoutPlatform {
        #if os(visionOS)
        .visionOS
        #else
        isPhone ? .phone : .pad
        #endif
    }

    private var usesPageHeader: Bool {
        isPad
            && horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
    }

    private var pagePadding: CGFloat {
        CompanionLayoutPolicy.pagePadding(platform: layoutPlatform)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let layoutMode = CompanionLayoutPolicy.mode(
                    availableWidth: geometry.size.width,
                    platform: layoutPlatform,
                    usesAccessibilityTextSizes: dynamicTypeSize.isAccessibilitySize
                )

                ScrollView {
                    VStack(alignment: .leading, spacing: CompanionLayoutPolicy.singleColumnSpacing) {
                        if usesPageHeader {
                            CompanionPageHeader(result: model.result) {
                                model.reload()
                            }
                        }
                        companionContent(layoutMode: layoutMode)
                    }
                        .frame(
                            maxWidth: CompanionLayoutPolicy.maximumContentWidth(
                                layoutMode: layoutMode,
                                platform: layoutPlatform
                            )
                        )
                        .frame(maxWidth: .infinity)
                        .padding(pagePadding)
                }
                .background(surfacePalette.pageBackground.ignoresSafeArea())
            }
            .companionNavigationChrome(usesPageHeader: usesPageHeader)
            .toolbar {
                if !usesPageHeader {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.reload()
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        galleryRoute = ValidationGalleryRoute()
                    } label: {
                        Label("Validation Gallery", systemImage: "rectangle.on.rectangle.badge.eye")
                    }
                }
            }
            .task {
                model.registerCloudKitSubscription()
                model.reload()
            }
            .task(id: model.refreshSettings.intervalMinutes) {
                await model.runPeriodicRefreshLoop()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    model.reload()
                }
            }
            .onOpenURL { url in
                if let route = ValidationGalleryRoute(url: url) {
                    galleryRoute = route
                }
            }
            .sheet(item: $galleryRoute) { route in
                CompanionValidationGallerySheet(route: route)
            }
        }
        .environment(\.companionSurfacePalette, surfacePalette)
        .companionVisionOSAppearance(model.appearanceSettings)
    }

    @ViewBuilder
    private func companionContent(layoutMode: CompanionLayoutMode) -> some View {
        let layout = layoutMode == .twoColumn
            ? AnyLayout(
                HStackLayout(
                    alignment: .top,
                    spacing: CompanionLayoutPolicy.columnSpacing(platform: layoutPlatform)
                )
            )
            : AnyLayout(
                VStackLayout(alignment: .leading, spacing: CompanionLayoutPolicy.singleColumnSpacing)
            )

        layout {
            instrumentColumn(layoutMode: layoutMode)
            settingsColumn(layoutMode: layoutMode)
        }
    }

    private func instrumentColumn(layoutMode: CompanionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: CompanionLayoutPolicy.singleColumnSpacing) {
            widgetPreview
                .frame(height: layoutMode == .twoColumn ? CompanionLayoutPolicy.wideWidgetHeight : nil)
                .frame(maxWidth: .infinity, minHeight: CompanionLayoutPolicy.wideWidgetHeight)

            CompanionProviderAccessAlertsView(alerts: model.snapshot.providerAccessAlerts)
            CompanionSyncStatusView(result: model.result)
        }
        .frame(
            minWidth: layoutMode == .twoColumn
                ? CompanionLayoutPolicy.instrumentMinimumWidth(platform: layoutPlatform)
                : nil,
            maxWidth: layoutMode == .twoColumn
                ? CompanionLayoutPolicy.instrumentMaximumWidth(platform: layoutPlatform)
                : .infinity,
            alignment: .topLeading
        )
        .layoutPriority(layoutMode == .twoColumn ? 1 : 0)
    }

    private var widgetPreview: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ContextPanelWidgetContentView(
                family: .systemLarge,
                snapshot: model.snapshot,
                displayPreferences: model.displayPreferences,
                links: CompanionDeepLinks.previewLinks,
                showsResetCreditSurfaces: true,
                resetCreditMaximumAge: SnapshotFreshness.companionProviderMaximumAge,
                presentationDate: context.date
            )
            .cpwThemeVariant(previewThemeVariant)
            .background(
                CPWTheme.surface(variant: previewThemeVariant),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private func settingsColumn(layoutMode: CompanionLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: CompanionLayoutPolicy.singleColumnSpacing) {
            CompanionWidgetMainLimitsSettingsView(
                preferences: model.displayPreferences,
                isLoaded: model.hasLoadedDisplayPreferences,
                isEditable: model.canEditDisplayPreferences,
                errorMessage: model.displayPreferencesErrorMessage,
                onVisibilityChange: model.setWidgetMainLimit(_:isVisible:),
                onMove: model.moveWidgetMainLimits(from:to:)
            )

            CompanionRefreshSettingsView(
                settings: model.refreshSettings,
                errorMessage: model.settingsErrorMessage,
                onIntervalChange: model.updateRefreshInterval(minutes:)
            )

            #if os(visionOS)
            CompanionAppearanceSettingsView(
                settings: model.appearanceSettings,
                errorMessage: model.appearanceErrorMessage,
                onAppAppearanceChange: model.updateVisionOSAppAppearance(_:),
                onWidgetAppearanceChange: model.updateVisionOSWidgetAppearance(_:)
            )
            #endif
        }
        .frame(
            width: layoutMode == .twoColumn
                ? CompanionLayoutPolicy.settingsColumnWidth(platform: layoutPlatform)
                : nil,
            alignment: .topLeading
        )
    }
}

private struct CompanionValidationGallerySheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: ValidationGalleryRoute

    var body: some View {
        NavigationStack {
            ValidationGalleryView(route: route)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
    }
}

private struct CompanionPageHeader: View {
    @Environment(\.companionSurfacePalette) private var palette

    let result: CompanionSyncLoadResult
    let onRefresh: () -> Void

    private var presentation: CompanionSyncPresentation {
        CompanionSyncPresentation(result: result)
    }

    private var lastSyncedAt: Date? {
        result.transportMetadata?.receivedAt
            ?? result.transportMetadata?.mirroredAt
            ?? result.document?.snapshot.publishedAt
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Context Panel")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.primaryText)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    Text(presentation.title)
                    if let lastSyncedAt {
                        Text("·")
                            .foregroundStyle(palette.tertiaryText)
                        Text("Synced " + lastSyncedAt.formatted(.relative(presentation: .named)))
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 20)

            Button(action: onRefresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
@Observable
private final class CompanionSyncModel {
    private let refreshSettingsStore: CompanionRefreshSettingsStore?
    private let appearanceSettingsStore: CompanionAppearanceSettingsStore?
    private let displayPreferencesStore: WidgetDisplayPreferencesStore?
    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()
    private let presentationPreferencesRemoteStore: CompanionPresentationRemoteStore?
    private let runtimeReceiptRecorder: RuntimeReceiptRecorder
    private let runtimeReceiptRelay: RuntimeReceiptRelayCoordinator?

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences
    private(set) var refreshSettings: CompanionRefreshSettings
    private(set) var appearanceSettings: CompanionAppearanceSettings
    private(set) var settingsErrorMessage: String?
    private(set) var appearanceErrorMessage: String?
    private(set) var displayPreferencesErrorMessage: String?
    private(set) var hasLoadedDisplayPreferences = false
    private var reloadTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false
    private var lastWidgetTimelineReloadAt: Date?
    private var lastWidgetRenderSignature: CompanionWidgetRenderSignature?
    private var presentationPreferencesSaveTask: Task<Void, Never>?
    private var lastSyncedPresentationPreferences: WidgetDisplayPreferences?
    private var desiredPresentationPreferences: WidgetDisplayPreferences?

    init(
        runtimeReceiptRecorder: RuntimeReceiptRecorder? = nil,
        runtimeReceiptRelay: RuntimeReceiptRelayCoordinator? = nil
    ) {
        let deviceClass = companionRuntimeDeviceClass()
        let appSurface = RuntimeSurface.companionApp(for: deviceClass)
        self.runtimeReceiptRecorder = runtimeReceiptRecorder ?? .appGroupRequired(
            surface: appSurface,
            appGroupID: ContextPanelLocations.companionAppGroupID
        )
        self.runtimeReceiptRelay = runtimeReceiptRelay ?? .appGroupReceiver(
            remoteStore: RuntimeReceiptCloudKitStoreFactory.make(),
            expectedManifestID: RuntimeBuildIdentityLoader.load(
                surface: appSurface
            )?.build.manifestID,
            eligibleSurfaces: [
                appSurface,
                .companionWidget(for: deviceClass),
            ],
            appGroupID: ContextPanelLocations.companionAppGroupID
        )
        #if os(iOS)
        presentationPreferencesRemoteStore = UIDevice.current.userInterfaceIdiom == .phone
            ? CompanionCloudKitSyncStoreFactory.makePresentationPreferences()
            : nil
        #else
        presentationPreferencesRemoteStore = nil
        #endif

        if let settingsURL = ContextPanelLocations.companionRefreshSettingsURL() {
            let store = CompanionRefreshSettingsStore(settingsURL: settingsURL)
            refreshSettingsStore = store
            refreshSettings = store.load()
        } else {
            refreshSettingsStore = nil
            refreshSettings = .defaultSettings
            settingsErrorMessage = "Auto-update settings are using defaults because shared app storage is unavailable."
        }

        if let appearanceSettingsURL = ContextPanelLocations.companionAppearanceSettingsURL() {
            let store = CompanionAppearanceSettingsStore(settingsURL: appearanceSettingsURL)
            appearanceSettingsStore = store
            appearanceSettings = store.load()
        } else {
            appearanceSettingsStore = nil
            appearanceSettings = .defaultSettings
            appearanceErrorMessage = "Appearance settings are using defaults because shared app storage is unavailable."
        }

        if let displayPreferencesURL = ContextPanelLocations.companionWidgetDisplayPreferencesURL() {
            let store = WidgetDisplayPreferencesStore(preferencesURL: displayPreferencesURL)
            displayPreferencesStore = store
            if let localDisplayPreferences = store.loadIfAvailable() {
                displayPreferences = localDisplayPreferences
                hasLoadedDisplayPreferences = true
            }
        } else {
            displayPreferencesStore = nil
            displayPreferencesErrorMessage = "Widget display settings could not be saved because shared app storage is unavailable."
        }
    }

    func reload(now: Date = Date()) {
        guard reloadTask == nil else {
            needsReloadAfterCurrentTask = true
            return
        }
        needsReloadAfterCurrentTask = false
        reloadTask = Task { [weak self] in
            defer {
                if let self {
                    reloadTask = nil
                    if needsReloadAfterCurrentTask {
                        reload()
                    }
                }
            }
            let remoteStore = self?.remoteStore
            let presentationPreferencesRemoteStore = self?.presentationPreferencesRemoteStore
            let displayPreferencesStore = self?.displayPreferencesStore
            let runtimeReceiptRelay = self?.runtimeReceiptRelay
            async let sessionRelayResult = runtimeReceiptRelay?.synchronizeSession(now: now)
            let (loaded, presentationDocument, localDisplayPreferences) = await Task.detached(priority: .userInitiated) {
                let localDisplayPreferences = displayPreferencesStore?.loadIfAvailable()
                async let loaded = CompanionSyncLoader.load(remoteStore: remoteStore, now: now)
                async let presentationDocument = presentationPreferencesRemoteStore?.load().document
                return (
                    await loaded,
                    await presentationDocument,
                    localDisplayPreferences
                )
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            _ = await sessionRelayResult
            let effectiveDisplayPreferences = WidgetDisplayPreferences.companionEffectivePreferences(
                localOverride: localDisplayPreferences,
                synced: presentationDocument?.widgetDisplayPreferences ?? loaded.document?.widgetDisplayPreferences
            )
            let loadedSignature = CompanionWidgetRenderSignature(
                result: loaded,
                displayPreferences: effectiveDisplayPreferences,
                now: now
            )
            result = loaded
            snapshot = loadedSignature.snapshot
            displayPreferences = loadedSignature.displayPreferences
            hasLoadedDisplayPreferences = true
            recordRuntimeReceipt(
                result: loaded,
                snapshot: loadedSignature.snapshot,
                displayPreferences: loadedSignature.displayPreferences,
                presentationDate: now
            )
            Task { [runtimeReceiptRelay] in
                _ = await runtimeReceiptRelay?.relayReceipts(now: Date())
            }
            if let presentationPreferences = presentationDocument?.widgetDisplayPreferences {
                lastSyncedPresentationPreferences = presentationPreferences
            }
            if localDisplayPreferences == nil,
               presentationDocument != nil {
                try? displayPreferencesStore?.save(effectiveDisplayPreferences)
            } else if let localDisplayPreferences,
                      presentationDocument?.widgetDisplayPreferences != localDisplayPreferences {
                syncDisplayPreferencesToWatch(localDisplayPreferences)
            }
            reloadWidgetTimelineIfNeeded(
                force: loadedSignature != lastWidgetRenderSignature,
                now: now
            )
            lastWidgetRenderSignature = loadedSignature
        }
    }

    private func recordRuntimeReceipt(
        result: CompanionSyncLoadResult,
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        presentationDate: Date
    ) {
        let evidence = CompanionRuntimeReceiptEvidence(
            result: result,
            snapshot: snapshot,
            displayPreferences: displayPreferences,
            appearanceSettings: runtimeAppearanceSettings,
            presentationSurface: .app,
            presentationMode: .appOverview,
            presentationDate: presentationDate
        )
        runtimeReceiptRecorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .appOverview,
            selectedSource: evidence.selectedSource,
            presentationDigest: evidence.presentationDigest,
            stateBranch: evidence.stateBranch,
            outcome: evidence.outcome,
            observedAt: presentationDate
        )
    }

    private var runtimeAppearanceSettings: CompanionAppearanceSettings? {
        #if os(visionOS)
        appearanceSettings
        #else
        nil
        #endif
    }

    private func reloadWidgetTimelineIfNeeded(force: Bool, now: Date = Date()) {
        if !force,
           let lastWidgetTimelineReloadAt,
           now.timeIntervalSince(lastWidgetTimelineReloadAt) < refreshSettings.widgetInterval {
            return
        }
        lastWidgetTimelineReloadAt = now
        reloadContextPanelCompanionWidgetTimeline()
    }

    func registerCloudKitSubscription() {
        Task { [remoteStore] in
            _ = await remoteStore.registerSubscription()
        }
    }

    func runPeriodicRefreshLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(refreshSettings.intervalSeconds))
            } catch {
                return
            }
            reload()
        }
    }

    func updateRefreshInterval(minutes: Int) {
        var updated = refreshSettings
        updated.setIntervalMinutes(minutes)
        guard let refreshSettingsStore else {
            settingsErrorMessage = "Auto-update settings could not be saved because shared app storage is unavailable."
            return
        }
        do {
            try refreshSettingsStore.save(updated)
            refreshSettings = updated
            settingsErrorMessage = nil
            reloadContextPanelCompanionWidgetTimeline()
            reload()
        } catch {
            settingsErrorMessage = "Auto-update settings could not be saved."
        }
    }

    func setWidgetMainLimit(_ preference: WidgetMainLimitPreference, isVisible: Bool) {
        var updated = displayPreferences
        updated.setMainLimit(
            provider: preference.provider,
            window: preference.window,
            isVisible: isVisible
        )
        saveDisplayPreferences(updated)
    }

    func moveWidgetMainLimits(from source: IndexSet, to destination: Int) {
        var updated = displayPreferences
        updated.moveMainLimits(fromOffsets: source, toOffset: destination)
        saveDisplayPreferences(updated)
    }

    private func saveDisplayPreferences(_ updated: WidgetDisplayPreferences) {
        guard let displayPreferencesStore else {
            displayPreferencesErrorMessage = "Widget display settings could not be saved because shared app storage is unavailable."
            return
        }
        do {
            try displayPreferencesStore.save(updated)
            displayPreferences = updated
            displayPreferencesErrorMessage = nil
            recordRuntimeReceipt(
                result: result,
                snapshot: snapshot,
                displayPreferences: updated,
                presentationDate: Date()
            )
            reloadContextPanelCompanionWidgetTimeline()
            syncDisplayPreferencesToWatch(updated)
        } catch {
            displayPreferencesErrorMessage = "Widget display settings could not be saved."
        }
    }

    var canEditDisplayPreferences: Bool {
        hasLoadedDisplayPreferences && displayPreferencesStore != nil
    }

    private func syncDisplayPreferencesToWatch(_ preferences: WidgetDisplayPreferences) {
        guard let presentationPreferencesRemoteStore else { return }
        desiredPresentationPreferences = preferences
        if presentationPreferencesSaveTask == nil,
           lastSyncedPresentationPreferences == preferences {
            desiredPresentationPreferences = nil
            return
        }
        guard presentationPreferencesSaveTask == nil else { return }

        presentationPreferencesSaveTask = Task { [weak self, presentationPreferencesRemoteStore] in
            while let self, let desiredPreferences = self.desiredPresentationPreferences {
                if self.lastSyncedPresentationPreferences == desiredPreferences {
                    self.desiredPresentationPreferences = nil
                    break
                }

                let outcome = await presentationPreferencesRemoteStore.save(
                    CompanionPresentationDocument(widgetDisplayPreferences: desiredPreferences)
                )
                if outcome.succeeded {
                    self.lastSyncedPresentationPreferences = desiredPreferences
                    if self.desiredPresentationPreferences == desiredPreferences {
                        self.desiredPresentationPreferences = nil
                    }
                    if self.displayPreferences == desiredPreferences {
                        self.displayPreferencesErrorMessage = nil
                    }
                } else {
                    if self.displayPreferences == desiredPreferences {
                        self.displayPreferencesErrorMessage = "Saved on this device, but the Apple Watch update failed."
                    }
                    if self.desiredPresentationPreferences == desiredPreferences {
                        break
                    }
                }
            }
            self?.presentationPreferencesSaveTask = nil
        }
    }

    func updateVisionOSAppAppearance(_ appearance: CompanionVisionOSAppAppearance) {
        var updated = appearanceSettings
        updated.visionOSAppAppearance = appearance
        saveAppearanceSettings(updated)
    }

    func updateVisionOSWidgetAppearance(_ appearance: CompanionVisionOSWidgetAppearance) {
        var updated = appearanceSettings
        updated.visionOSWidgetAppearance = appearance
        saveAppearanceSettings(updated)
    }

    private func saveAppearanceSettings(_ updated: CompanionAppearanceSettings) {
        guard let appearanceSettingsStore else {
            appearanceErrorMessage = "Appearance settings could not be saved because shared app storage is unavailable."
            return
        }
        do {
            try appearanceSettingsStore.save(updated)
            appearanceSettings = updated
            appearanceErrorMessage = nil
            recordRuntimeReceipt(
                result: result,
                snapshot: snapshot,
                displayPreferences: displayPreferences,
                presentationDate: Date()
            )
            reloadContextPanelCompanionWidgetTimeline()
        } catch {
            appearanceErrorMessage = "Appearance settings could not be saved."
        }
    }
}

private struct CompanionSurfacePalette {
    let pageBackground: Color
    let cardBackground: Color
    let primaryText: Color
    let secondaryText: Color
    let tertiaryText: Color
    let errorText: Color
    let border: Color
    let segmentBackground: Color
    let selectedSegmentBackground: Color
    let selectedSegmentText: Color
    let unselectedSegmentText: Color

    static var adaptive: CompanionSurfacePalette {
        CompanionSurfacePalette(
            pageBackground: Color(uiColor: .systemGroupedBackground),
            cardBackground: Color(uiColor: .secondarySystemGroupedBackground),
            primaryText: .primary,
            secondaryText: .secondary,
            tertiaryText: Color(uiColor: .tertiaryLabel),
            errorText: .red,
            border: .clear,
            segmentBackground: Color(uiColor: .tertiarySystemFill),
            selectedSegmentBackground: Color.accentColor,
            selectedSegmentText: .white,
            unselectedSegmentText: .secondary
        )
    }

    #if os(visionOS)
    static func visionOS(appearance: CompanionVisionOSAppAppearance) -> CompanionSurfacePalette {
        switch appearance {
        case .dark:
            CompanionSurfacePalette(
                pageBackground: Color(red: 20 / 255, green: 21 / 255, blue: 24 / 255),
                cardBackground: Color(red: 32 / 255, green: 33 / 255, blue: 36 / 255),
                primaryText: Color(red: 239 / 255, green: 240 / 255, blue: 242 / 255),
                secondaryText: Color(red: 178 / 255, green: 180 / 255, blue: 186 / 255),
                tertiaryText: Color(red: 128 / 255, green: 131 / 255, blue: 139 / 255),
                errorText: Color(red: 232 / 255, green: 139 / 255, blue: 139 / 255),
                border: Color.white.opacity(0.11),
                segmentBackground: Color.white.opacity(0.08),
                selectedSegmentBackground: Color(red: 95 / 255, green: 116 / 255, blue: 154 / 255),
                selectedSegmentText: Color.white,
                unselectedSegmentText: Color(red: 205 / 255, green: 208 / 255, blue: 214 / 255)
            )
        case .light:
            CompanionSurfacePalette(
                pageBackground: Color(red: 242 / 255, green: 243 / 255, blue: 245 / 255),
                cardBackground: Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255),
                primaryText: Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255),
                secondaryText: Color(red: 87 / 255, green: 87 / 255, blue: 92 / 255),
                tertiaryText: Color(red: 130 / 255, green: 130 / 255, blue: 136 / 255),
                errorText: Color(red: 172 / 255, green: 64 / 255, blue: 64 / 255),
                border: Color.black.opacity(0.08),
                segmentBackground: Color.black.opacity(0.06),
                selectedSegmentBackground: Color(red: 74 / 255, green: 91 / 255, blue: 122 / 255),
                selectedSegmentText: Color.white,
                unselectedSegmentText: Color(red: 60 / 255, green: 61 / 255, blue: 66 / 255)
            )
        }
    }
    #endif
}

private struct CompanionSurfacePaletteKey: EnvironmentKey {
    static let defaultValue = CompanionSurfacePalette.adaptive
}

private extension EnvironmentValues {
    var companionSurfacePalette: CompanionSurfacePalette {
        get { self[CompanionSurfacePaletteKey.self] }
        set { self[CompanionSurfacePaletteKey.self] = newValue }
    }
}

private struct CompanionRefreshSettingsView: View {
    @Environment(\.companionSurfacePalette) private var palette

    let settings: CompanionRefreshSettings
    let errorMessage: String?
    let onIntervalChange: (Int) -> Void

    var body: some View {
        CompanionSettingsCard {
            CompanionRefreshSettingsControl(
                settings: settings,
                errorMessage: errorMessage,
                colors: palette.settingsControlColors,
                onIntervalChange: onIntervalChange
            )
        }
    }
}

private struct CompanionWidgetMainLimitsSettingsView: View {
    @Environment(\.companionSurfacePalette) private var palette
    @State private var isReordering = false

    let preferences: WidgetDisplayPreferences
    let isLoaded: Bool
    let isEditable: Bool
    let errorMessage: String?
    let onVisibilityChange: @MainActor (WidgetMainLimitPreference, Bool) -> Void
    let onMove: @MainActor (IndexSet, Int) -> Void

    var body: some View {
        CompanionSettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Label("Widget Main Limits", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.primaryText)
                    Spacer(minLength: 12)
                    Button(isReordering ? "Done" : "Reorder") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isReordering.toggle()
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!isEditable)
                }
                Text(displayPreferencesScopeText)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)

                if isLoaded {
                    WidgetMainLimitSettingsStack(
                        preferences: preferences,
                        colors: palette.settingsControlColors,
                        isReordering: isReordering,
                        providerLabel: { provider in
                            Text(provider.shortName)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(palette.primaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    palette.segmentBackground,
                                    in: Capsule()
                                )
                        },
                        onVisibilityChange: onVisibilityChange,
                        onMove: onMove
                    )
                    .disabled(!isEditable)
                } else {
                    ProgressView("Loading display settings…")
                        .frame(maxWidth: .infinity, minHeight: 80)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(palette.errorText)
                }
            }
        }
    }

    private var displayPreferencesScopeText: String {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .phone {
            "These choices apply to this companion, its widgets, and Apple Watch. Mac settings remain unchanged."
        } else {
            "These choices apply to this companion and its widgets. Mac settings remain unchanged."
        }
        #else
        "These choices apply to this companion and its widgets. Mac settings remain unchanged."
        #endif
    }

}

#if os(visionOS)
private struct CompanionAppearanceSettingsView: View {
    @Environment(\.companionSurfacePalette) private var palette

    let settings: CompanionAppearanceSettings
    let errorMessage: String?
    let onAppAppearanceChange: @MainActor (CompanionVisionOSAppAppearance) -> Void
    let onWidgetAppearanceChange: @MainActor (CompanionVisionOSWidgetAppearance) -> Void

    var body: some View {
        CompanionSettingsCard {
            CompanionAppearanceSettingsControl(
                settings: settings,
                errorMessage: errorMessage,
                colors: palette.settingsControlColors,
                onAppAppearanceChange: onAppAppearanceChange,
                onWidgetAppearanceChange: onWidgetAppearanceChange
            )
        }
    }
}
#endif

private struct CompanionSettingsCard<Content: View>: View {
    @Environment(\.companionSurfacePalette) private var palette
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                palette.cardBackground,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(palette.border, lineWidth: 1)
            }
    }
}

private extension CompanionSurfacePalette {
    var settingsControlColors: ContextPanelSettingsControlColors {
        ContextPanelSettingsControlColors(
            primaryText: primaryText,
            secondaryText: secondaryText,
            tertiaryText: tertiaryText,
            errorText: errorText,
            segmentBackground: segmentBackground,
            selectedSegmentBackground: selectedSegmentBackground,
            selectedSegmentText: selectedSegmentText,
            unselectedSegmentText: unselectedSegmentText,
            border: border
        )
    }
}

private struct CompanionProviderAccessAlertsView: View {
    @Environment(\.companionSurfacePalette) private var palette

    let alerts: [ProviderAccessAlert]

    var body: some View {
        if !alerts.isEmpty {
            CompanionSettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Provider access")
                        .font(.headline)
                        .foregroundStyle(palette.primaryText)

                    ForEach(alerts) { alert in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: symbolName(for: alert))
                                .font(.body.weight(.semibold))
                                .foregroundStyle(statusColor(for: alert))
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(alert.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(palette.primaryText)
                                Text(alert.accountName)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(palette.tertiaryText)
                                Text(alert.detail)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                                if let resetText = alert.resetDisplayText() {
                                    Text("Plan access resets \(resetText)")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(palette.secondaryText)
                                }
                            }
                            Spacer(minLength: 8)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(accessibilityLabel(for: alert))
                    }
                }
            }
        }
    }

    private func symbolName(for alert: ProviderAccessAlert) -> String {
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

    private func statusColor(for alert: ProviderAccessAlert) -> Color {
        switch alert.status {
        case .healthy:
            .green
        case .close:
            .orange
        case .limited, .failure:
            palette.errorText
        case .stale:
            .orange
        case .unknown, .loading:
            palette.secondaryText
        }
    }

    private func accessibilityLabel(for alert: ProviderAccessAlert) -> String {
        var components = [alert.title, alert.accountName, alert.detail]
        if let resetText = alert.resetAccessibilityText() {
            components.append("Plan access resets at \(resetText)")
        }
        return components.joined(separator: ". ")
    }
}

private struct CompanionSyncStatusView: View {
    @Environment(\.companionSurfacePalette) private var palette

    let result: CompanionSyncLoadResult

    private var presentation: CompanionSyncPresentation {
        CompanionSyncPresentation(result: result)
    }

    private var lastSyncedAt: Date? {
        result.transportMetadata?.receivedAt
            ?? result.transportMetadata?.mirroredAt
            ?? result.document?.snapshot.publishedAt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: presentation.symbol)
                .font(.headline)
                .foregroundStyle(palette.primaryText)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)

            if let usageSummary = presentation.usageSummary {
                Label(usageSummary, systemImage: "gauge.medium")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(palette.secondaryText)
            }

            if let lastSyncedAt {
                Text("Last synced " + lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(palette.tertiaryText)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            palette.cardBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
    }
}

private extension View {
    @ViewBuilder
    func companionNavigationChrome(usesPageHeader: Bool) -> some View {
        #if os(iOS)
        if usesPageHeader {
            toolbar(.hidden, for: .navigationBar)
        } else {
            navigationTitle("Context Panel")
        }
        #else
        navigationTitle("Context Panel")
        #endif
    }

    @ViewBuilder
    func companionVisionOSAppearance(_ settings: CompanionAppearanceSettings) -> some View {
        #if os(visionOS)
        environment(\.colorScheme, settings.visionOSAppAppearance.colorScheme)
            .preferredColorScheme(settings.visionOSAppAppearance.colorScheme)
        #else
        self
        #endif
    }
}

private extension CompanionVisionOSAppAppearance {
    var cpwThemeVariant: CPWThemeVariant {
        switch self {
        case .dark:
            .dark
        case .light:
            .light
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .dark:
            .dark
        case .light:
            .light
        }
    }
}
