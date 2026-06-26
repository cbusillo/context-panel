import ContextPanelCore
import ContextPanelCloudKitSync
import ContextPanelCompanionSupport
import ContextPanelWidgetUI
import SwiftUI
import UIKit
import WidgetKit

private func reloadContextPanelCompanionWidgetTimeline() {
    WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelCompanionWidgetIdentity.kind)
}

private struct CompanionWidgetRenderSignature: Equatable {
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let deliveryStatus: CompanionSyncDeliveryStatus?

    init(result: CompanionSyncLoadResult, now: Date) {
        snapshot = WidgetSnapshot.fromCompanionSync(
            result,
            now: now,
            stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
        )
        displayPreferences = result.document?.widgetDisplayPreferences ?? .defaultPreferences
        deliveryStatus = result.transportMetadata?.deliveryStatus
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CompanionSyncModel()

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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ContextPanelWidgetContentView(
                        family: .systemLarge,
                        snapshot: model.snapshot,
                        displayPreferences: model.displayPreferences,
                        links: CompanionDeepLinks.links
                    )
                    .frame(maxWidth: .infinity, minHeight: 360)
                    .cpwThemeVariant(previewThemeVariant)
                    .background(
                        CPWTheme.surface(variant: previewThemeVariant),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )

                    CompanionSyncStatusView(result: model.result)

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
                .padding()
            }
            .background(surfacePalette.pageBackground.ignoresSafeArea())
            .navigationTitle("Context Panel")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
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
        }
        .environment(\.companionSurfacePalette, surfacePalette)
        .companionVisionOSAppearance(model.appearanceSettings)
    }
}

@MainActor
@Observable
private final class CompanionSyncModel {
    private let refreshSettingsStore: CompanionRefreshSettingsStore?
    private let appearanceSettingsStore: CompanionAppearanceSettingsStore?
    private let remoteStore = CompanionCloudKitSyncStoreFactory.make()

    private(set) var result = CompanionSyncLoadResult(document: nil, status: .unknown)
    private(set) var snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: nil, status: .unknown)
    )
    private(set) var displayPreferences = WidgetDisplayPreferences.defaultPreferences
    private(set) var refreshSettings: CompanionRefreshSettings
    private(set) var appearanceSettings: CompanionAppearanceSettings
    private(set) var settingsErrorMessage: String?
    private(set) var appearanceErrorMessage: String?
    private var reloadTask: Task<Void, Never>?
    private var iCloudCacheRefreshTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false
    private var lastWidgetTimelineReloadAt: Date?
    private var lastWidgetRenderSignature: CompanionWidgetRenderSignature?

    init() {
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
            let loaded = await Task.detached(priority: .userInitiated) {
                await CompanionSyncLoader.load(remoteStore: remoteStore, now: now)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let loadedSignature = CompanionWidgetRenderSignature(result: loaded, now: now)
            result = loaded
            snapshot = loadedSignature.snapshot
            displayPreferences = loadedSignature.displayPreferences
            reloadWidgetTimelineIfNeeded(
                force: loadedSignature != lastWidgetRenderSignature,
                now: now
            )
            lastWidgetRenderSignature = loadedSignature
            refreshICloudCacheIfNeeded()
        }
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

    private func refreshICloudCacheIfNeeded() {
        guard iCloudCacheRefreshTask == nil else { return }
        guard ContextPanelLocations.cachedCompanionUbiquitySyncDocumentURL() == nil else { return }
        iCloudCacheRefreshTask = Task { [weak self] in
            let refreshedURL = await Task.detached(priority: .utility) {
                ContextPanelLocations.refreshCachedCompanionUbiquitySyncDocumentURL()
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            iCloudCacheRefreshTask = nil
            if refreshedURL != nil {
                reload()
            }
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("Auto-update", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.primaryText)
                Spacer(minLength: 12)
                Picker("Auto-update", selection: Binding(
                    get: { settings.intervalMinutes },
                    set: { minutes in
                        MainActor.assumeIsolated {
                            onIntervalChange(minutes)
                        }
                    }
                )) {
                    ForEach(CompanionRefreshSettings.allowedIntervalMinutes, id: \.self) { minutes in
                        Text("\(minutes)m").tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .foregroundStyle(palette.primaryText)
            }
            Text("Widgets may update less often when iOS limits background refreshes.")
                .font(.footnote)
                .foregroundStyle(palette.secondaryText)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(palette.errorText)
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

#if os(visionOS)
private struct CompanionAppearanceSettingsView: View {
    @Environment(\.companionSurfacePalette) private var palette

    let settings: CompanionAppearanceSettings
    let errorMessage: String?
    let onAppAppearanceChange: (CompanionVisionOSAppAppearance) -> Void
    let onWidgetAppearanceChange: (CompanionVisionOSWidgetAppearance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.primaryText)

            VStack(alignment: .leading, spacing: 10) {
                appearanceRow("App") {
                    CompanionAppearanceSegmentedControl(
                        values: CompanionVisionOSAppAppearance.allCases,
                        selection: settings.visionOSAppAppearance,
                        label: { $0.label },
                        onSelect: { appearance in
                            MainActor.assumeIsolated {
                                onAppAppearanceChange(appearance)
                            }
                        }
                    )
                }

                appearanceRow("Widget") {
                    CompanionAppearanceSegmentedControl(
                        values: CompanionVisionOSWidgetAppearance.allCases,
                        selection: settings.visionOSWidgetAppearance,
                        label: { $0.label },
                        onSelect: { appearance in
                            MainActor.assumeIsolated {
                                onWidgetAppearanceChange(appearance)
                            }
                        }
                    )
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(palette.errorText)
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

    private func appearanceRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(palette.secondaryText)
            content()
        }
    }
}

private struct CompanionAppearanceSegmentedControl<Value: Hashable>: View {
    @Environment(\.companionSurfacePalette) private var palette

    let values: [Value]
    let selection: Value
    let label: (Value) -> String
    let onSelect: (Value) -> Void

    init(
        values: [Value],
        selection: Value,
        label: @escaping (Value) -> String,
        onSelect: @escaping (Value) -> Void
    ) {
        self.values = values
        self.selection = selection
        self.label = label
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selection
                Button {
                    onSelect(value)
                } label: {
                    Text(label(value))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(isSelected ? palette.selectedSegmentText : palette.unselectedSegmentText)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .padding(.horizontal, 8)
                        .background(
                            isSelected ? palette.selectedSegmentBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(value))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(
            palette.segmentBackground,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.border, lineWidth: 1)
        }
    }
}

private extension CompanionVisionOSAppAppearance {
    var label: String {
        switch self {
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }
}

private extension CompanionVisionOSWidgetAppearance {
    var label: String {
        switch self {
        case .matchApp:
            "Match App"
        case .dark:
            "Dark"
        case .light:
            "Light"
        }
    }
}
#endif

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
