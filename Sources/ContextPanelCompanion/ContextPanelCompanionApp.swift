import ContextPanelCore
import ContextPanelCompanionSupport
import ContextPanelWidgetUI
import SwiftUI
import UIKit
import WidgetKit

@main
struct ContextPanelCompanionApp: App {
    var body: some Scene {
        WindowGroup {
            CompanionRootView()
        }
    }
}

@MainActor
private struct CompanionRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CompanionSyncModel()

    private var previewThemeVariant: CPWThemeVariant {
        #if os(visionOS)
        model.appearanceSettings.resolvedVisionOSWidgetAppearance.cpwThemeVariant
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
                    .companionVisionOSWidgetAppearance(model.appearanceSettings)
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
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
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
        .companionVisionOSAppearance(model.appearanceSettings)
    }
}

@MainActor
@Observable
private final class CompanionSyncModel {
    private let refreshSettingsStore: CompanionRefreshSettingsStore?
    private let appearanceSettingsStore: CompanionAppearanceSettingsStore?

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
            let previousDocument = self?.result.document
            let loaded = await Task.detached(priority: .userInitiated) {
                CompanionSyncLoader.load(now: now)
            }.value
            guard !Task.isCancelled else { return }
            guard let self else { return }
            result = loaded
            snapshot = WidgetSnapshot.fromCompanionSync(
                loaded,
                now: now,
                stalenessPolicy: SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.widgetMaximumAge)
            )
            displayPreferences = loaded.document?.widgetDisplayPreferences ?? .defaultPreferences
            if loaded.document != previousDocument {
                WidgetCenter.shared.reloadAllTimelines()
            }
            refreshICloudCacheIfNeeded()
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
            WidgetCenter.shared.reloadAllTimelines()
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
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            appearanceErrorMessage = "Appearance settings could not be saved."
        }
    }
}

private struct CompanionRefreshSettingsView: View {
    let settings: CompanionRefreshSettings
    let errorMessage: String?
    let onIntervalChange: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label("Auto-update", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline.weight(.semibold))
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
            }
            Text("Widgets may update less often when iOS limits background refreshes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

#if os(visionOS)
private struct CompanionAppearanceSettingsView: View {
    let settings: CompanionAppearanceSettings
    let errorMessage: String?
    let onAppAppearanceChange: (CompanionVisionOSAppAppearance) -> Void
    let onWidgetAppearanceChange: (CompanionVisionOSWidgetAppearance) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Appearance", systemImage: "circle.lefthalf.filled")
                .font(.subheadline.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                appearanceRow("App") {
                    Picker("App", selection: Binding(
                        get: { settings.visionOSAppAppearance },
                        set: { appearance in
                            MainActor.assumeIsolated {
                                onAppAppearanceChange(appearance)
                            }
                        }
                    )) {
                        ForEach(CompanionVisionOSAppAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                appearanceRow("Widget") {
                    Picker("Widget", selection: Binding(
                        get: { settings.visionOSWidgetAppearance },
                        set: { appearance in
                            MainActor.assumeIsolated {
                                onWidgetAppearanceChange(appearance)
                            }
                        }
                    )) {
                        ForEach(CompanionVisionOSWidgetAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.label).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func appearanceRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
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
    let result: CompanionSyncLoadResult

    private var presentation: CompanionSyncPresentation {
        CompanionSyncPresentation(result: result)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(presentation.title, systemImage: presentation.symbol)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(presentation.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let usageSummary = presentation.usageSummary {
                Label(usageSummary, systemImage: "gauge.medium")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            if let generatedAt = result.document?.snapshot.generatedAt {
                Text("Last synced " + generatedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

private extension View {
    @ViewBuilder
    func companionVisionOSAppearance(_ settings: CompanionAppearanceSettings) -> some View {
        #if os(visionOS)
        preferredColorScheme(settings.visionOSAppAppearance.colorScheme)
        #else
        self
        #endif
    }

    @ViewBuilder
    func companionVisionOSWidgetAppearance(_ settings: CompanionAppearanceSettings) -> some View {
        #if os(visionOS)
        environment(\.colorScheme, settings.resolvedVisionOSWidgetAppearance.colorScheme)
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
