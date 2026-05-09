import ContextPanelCore
import AppKit
import ServiceManagement
import SwiftUI
import WidgetKit
import WebKit

@main
struct ContextPanelPreviewApp: App {
    @NSApplicationDelegateAdaptor(ContextPanelAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppRoot(model: appDelegate.model)
                .frame(minWidth: 1080, idealWidth: 1080, minHeight: 720, idealHeight: 720)
        }
        .defaultSize(width: 1080, height: 720)

        Settings {
            SettingsPane()
        }
    }
}

@MainActor
final class ContextPanelAppDelegate: NSObject, NSApplicationDelegate {
    let model = ContextPanelAppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerRefreshAgent()
        model.loadSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func registerRefreshAgent() {
        let service = SMAppService.loginItem(identifier: ContextPanelLocations.refreshAgentBundleID)
        guard service.status != .enabled else { return }
        do {
            try service.register()
        } catch {
            model.setError("Background refresh could not be enabled: \(error.localizedDescription)")
        }
    }
}

enum AppNavigationSelection: Hashable {
    case overview
    case provider(Provider)
    case mainLimit(MainLimitSummary.ID)
}

struct AppRoot: View {
    @ObservedObject var model: ContextPanelAppModel
    @State private var selection: AppNavigationSelection? = .overview

    private var snapshot: UsageSnapshot {
        model.currentSnapshot
    }

    var body: some View {
        HStack(spacing: 0) {
            AccountsSidebar(model: model, snapshot: snapshot, selection: $selection)
                .frame(width: 240)
            Divider()
            MainContent(model: model, snapshot: snapshot, selection: selection ?? .overview)
                .frame(minWidth: 760)
        }
        .tint(CPTheme.accent)
        .sheet(isPresented: $model.isClaudeWebCapturePresented) {
            ClaudeWebCaptureSheet(model: model)
                .frame(minWidth: 980, minHeight: 680)
        }
    }
}

struct SettingsPane: View {
    @StateObject private var model = SettingsPaneModel()

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(model.accounts) { account in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ProviderBadge(provider: account.provider)
                            Text(account.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(account.isEnabled ? "Enabled" : "Disabled")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(account.isEnabled ? CPTheme.statusColor(.healthy) : CPTheme.tertiaryText)
                        }
                        Text(model.detailText(for: account))
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.secondaryText)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Diagnostics") {
                DetailRow(label: "Config", value: ConnectorRedactor.redactedPath(model.configurationPath))
                DetailRow(label: "Status", value: model.status.rawValue)
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.statusColor(.failure))
                }
            }

            Section("Widget Main Limits") {
                Text("Drag to reorder. The medium widget uses the first 3 visible limits; the large widget uses the first 5.")
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)

                List {
                    ForEach(model.widgetPreferences.mainLimits) { preference in
                        WidgetMainLimitPreferenceRow(
                            preference: preference,
                            isVisible: Binding(
                                get: { preference.isVisible },
                                set: { model.setWidgetMainLimit(preference, isVisible: $0) }
                            )
                        )
                    }
                    .onMove(perform: model.moveWidgetMainLimits)
                }
                .listStyle(.inset)
                .frame(height: 184)
            }

            Section("Reset Primer") {
                Toggle(isOn: Binding(
                    get: { model.resetPrimerSettings.isEnabled },
                    set: { model.setResetPrimerEnabled($0) }
                )) {
                    Text("Enable reset primer")
                }
                .toggleStyle(.switch)

                Stepper(
                    value: Binding(
                        get: { model.resetPrimerSettings.delayMinutesAfterReset },
                        set: { model.setResetPrimerDelay($0) }
                    ),
                    in: 0...120,
                    step: 5
                ) {
                    DetailRow(
                        label: "Delay after reset",
                        value: "\(model.resetPrimerSettings.delayMinutesAfterReset) min"
                    )
                }

                Stepper(
                    value: Binding(
                        get: { model.resetPrimerSettings.accountStaggerMinutes },
                        set: { model.setResetPrimerStagger($0) }
                    ),
                    in: 0...120,
                    step: 5
                ) {
                    DetailRow(
                        label: "Stagger accounts",
                        value: "\(model.resetPrimerSettings.accountStaggerMinutes) min"
                    )
                }

                List {
                    ForEach(model.resetPrimerSettings.accountPreferences) { preference in
                        ResetPrimerAccountPreferenceRow(
                            preference: preference,
                            isEnabled: Binding(
                                get: { preference.isEnabled },
                                set: { model.setResetPrimerAccount(preference.accountID, isEnabled: $0) }
                            )
                        )
                    }
                }
                .listStyle(.inset)
                .frame(height: 150)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 360)
        .onAppear { model.load() }
    }
}

@MainActor
final class SettingsPaneModel: ObservableObject {
    @Published private(set) var accounts: [LocalProviderAccountConfiguration] = []
    @Published private(set) var widgetPreferences: WidgetDisplayPreferences = .defaultPreferences
    @Published private(set) var resetPrimerSettings: ResetPrimerSettings = .defaultSettings
    @Published private(set) var status: UsageStatus = .unknown
    @Published private(set) var errorMessage: String?

    private let store = AccountConfigurationStore(
        configurationURL: ContextPanelLocations.accountConfigurationURL(),
        fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
    )
    private let widgetPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let widgetApplicationSupportPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDevelopmentDisplayPreferencesURL()
    )
    private let widgetContainerPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDevelopmentContainerDisplayPreferencesURL()
    )
    private let widgetHostPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.hostDevelopmentDisplayPreferencesURL()
    )
    private let resetPrimerSettingsStore = ResetPrimerSettingsStore(
        settingsURL: ContextPanelLocations.resetPrimerSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    private var widgetPreferenceStores: WidgetDisplayPreferencesStoreSet {
        WidgetDisplayPreferencesStoreSet(stores: [
            widgetPreferenceStore,
            widgetApplicationSupportPreferenceStore,
            widgetContainerPreferenceStore,
            widgetHostPreferenceStore,
        ])
    }

    var configurationPath: String {
        store.configurationURL.path
    }

    func load() {
        let result = store.load()
        accounts = result.document.accounts
        widgetPreferences = widgetPreferenceStores.load()
        var primerSettings = resetPrimerSettingsStore.load()
        primerSettings.syncAccounts(result.document.accounts)
        resetPrimerSettings = primerSettings
        status = result.status
        errorMessage = result.errorMessage
    }

    func setWidgetMainLimit(_ preference: WidgetMainLimitPreference, isVisible: Bool) {
        var updated = widgetPreferences
        updated.setMainLimit(provider: preference.provider, window: preference.window, isVisible: isVisible)
        saveWidgetPreferences(updated)
    }

    func moveWidgetMainLimits(from source: IndexSet, to destination: Int) {
        var updated = widgetPreferences
        updated.moveMainLimits(fromOffsets: source, toOffset: destination)
        saveWidgetPreferences(updated)
    }

    private func saveWidgetPreferences(_ updated: WidgetDisplayPreferences) {
        do {
            try widgetPreferenceStores.save(updated)
            widgetPreferences = updated
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setResetPrimerEnabled(_ isEnabled: Bool) {
        var updated = resetPrimerSettings
        updated.isEnabled = isEnabled
        saveResetPrimerSettings(updated)
    }

    func setResetPrimerDelay(_ minutes: Int) {
        var updated = resetPrimerSettings
        updated.setDelayMinutesAfterReset(minutes)
        saveResetPrimerSettings(updated)
    }

    func setResetPrimerStagger(_ minutes: Int) {
        var updated = resetPrimerSettings
        updated.setAccountStaggerMinutes(minutes)
        saveResetPrimerSettings(updated)
    }

    func setResetPrimerAccount(_ accountID: String, isEnabled: Bool) {
        var updated = resetPrimerSettings
        updated.setAccount(accountID, isEnabled: isEnabled)
        saveResetPrimerSettings(updated)
    }

    private func saveResetPrimerSettings(_ updated: ResetPrimerSettings) {
        do {
            try resetPrimerSettingsStore.save(updated)
            resetPrimerSettings = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func detailText(for account: LocalProviderAccountConfiguration) -> String {
        let path = account.authPath ?? account.statsPath ?? account.commandPath ?? account.connectorKind.rawValue
        return "\(account.connectorKind.rawValue) · \(ConnectorRedactor.redactedPath(path))"
    }
}

struct ResetPrimerAccountPreferenceRow: View {
    let preference: ResetPrimerAccountPreference
    @Binding var isEnabled: Bool

    var body: some View {
        Toggle(isOn: $isEnabled) {
            HStack(spacing: 8) {
                ProviderBadge(provider: preference.provider)
                Text(preference.accountName)
                Spacer()
                Text(preference.isEnabled ? "Enabled" : "Off")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 2)
    }
}

struct WidgetMainLimitPreferenceRow: View {
    let preference: WidgetMainLimitPreference
    @Binding var isVisible: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CPTheme.tertiaryText)
                .frame(width: 14)
            Toggle(isOn: $isVisible) {
                HStack(spacing: 8) {
                    ProviderBadge(provider: preference.provider)
                    Text(preference.window.displayName)
                    Spacer()
                    Text(preference.isVisible ? "Shown" : "Hidden")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPTheme.secondaryText)
                }
            }
            .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}

struct AccountsSidebar: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    @Binding var selection: AppNavigationSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "gauge.with.dots.needle.67percent")
                    .tag(AppNavigationSelection.overview)
            }
            Section("Providers") {
                ForEach(Provider.allCases) { provider in
                    let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                    if !summaries.isEmpty {
                        ProviderSidebarRow(provider: provider, summaries: summaries)
                            .tag(AppNavigationSelection.provider(provider))
                        ForEach(summaries) { summary in
                            SidebarMainLimitRow(summary: summary)
                                .tag(AppNavigationSelection.mainLimit(summary.id))
                        }
                    }
                }
            }
        }
        .navigationTitle("Context Panel")
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    Task { await model.refreshLocalConnectors() }
                } label: {
                    Label(model.isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.isRefreshing)

                Button {
                    model.openClaudeWebCapture()
                } label: {
                    Label("Claude Web", systemImage: "gauge.with.dots.needle.67percent")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(12)
        }
    }
}

struct ProviderSidebarRow: View {
    let provider: Provider
    let summaries: [MainLimitSummary]

    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: provider)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(summaries.count)")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

struct SidebarMainLimitRow: View {
    let summary: MainLimitSummary

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(status: summary.status, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.window.displayName)
                    .font(.system(size: 13, weight: .medium))
                Text(summary.sidebarDetailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(summary.compactUsageText)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct MainContent: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    let selection: AppNavigationSelection

    var body: some View {
        switch selection {
        case .overview:
            OverviewDashboard(model: model, snapshot: snapshot)
        case .provider(let provider):
            ProviderDashboard(model: model, snapshot: snapshot, provider: provider)
        case .mainLimit(let id):
            if let summary = snapshot.mainLimitSummaries.first(where: { $0.id == id }) {
                MainLimitDetail(model: model, summary: summary, generatedAt: snapshot.generatedAt)
            } else {
                OverviewDashboard(model: model, snapshot: snapshot)
            }
        }
    }
}

struct OverviewDashboard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot

    private var constrainedSummaries: [MainLimitSummary] {
        Array(snapshot.mostConstrainedMainLimitSummaries.prefix(5))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderCard(model: model, snapshot: snapshot)
                SetupStatusStrip(model: model)
                SectionHeader(title: "Main Limits", trailing: "\(snapshot.mainLimitSummaries.count) windows")
                VStack(spacing: 10) {
                    ForEach(constrainedSummaries) { summary in
                        MainLimitRow(summary: summary)
                    }
                }
                SectionHeader(title: "Provider Groups", trailing: snapshot.nearestResetText)
                ProviderGroupGrid(snapshot: snapshot)
                AdditionalLimitsSection(snapshot: snapshot)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
    }
}

struct ProviderDashboard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    let provider: Provider

    private var summaries: [MainLimitSummary] {
        snapshot.mainLimitSummaries.filter { $0.provider == provider }
    }

    private var additionalLimits: [UsageLimit] {
        snapshot.additionalLimits.filter { $0.provider == provider }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                ProviderHeaderCard(model: model, provider: provider, summaries: summaries)
                SectionHeader(title: "Main Limits", trailing: "\(summaries.count) windows")
                VStack(spacing: 10) {
                    ForEach(summaries) { summary in
                        MainLimitRow(summary: summary)
                    }
                }
                if !additionalLimits.isEmpty {
                    AdditionalLimitsSection(snapshot: snapshot, provider: provider)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
    }
}

struct HeaderCard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(snapshot.headline)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(2)
                Text(snapshot.subheadline)
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.secondaryText)
                Text(model.fastModeForecast.copy)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CPTheme.accent)
                Text("Fast mode assumes 1.5x throughput for 2x limit spend.")
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.tertiaryText)
                HStack(spacing: 8) {
                    TagLabel("\(snapshot.mainLimitSummaries.count) main windows")
                    TagLabel("accounts folded")
                    TagLabel(model.storeStatus.rawValue)
                }
            }
            Spacer(minLength: 16)
            CapacityDial(
                value: snapshot.tightestCapacityRatio,
                status: snapshot.aggregateStatus,
                label: "\(Int(snapshot.tightestCapacityRatio * 100))",
                sublabel: "left",
                size: 116
            )
        }
        .padding(22)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }
}

struct ProviderHeaderCard: View {
    @ObservedObject var model: ContextPanelAppModel
    let provider: Provider
    let summaries: [MainLimitSummary]

    private var tightestSummary: MainLimitSummary? {
        summaries.sorted { lhs, rhs in
            (lhs.usageRatio ?? 0) > (rhs.usageRatio ?? 0)
        }.first
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ProviderBadge(provider: provider)
                    Text(provider.displayName)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CPTheme.primaryText)
                }
                Text(providerSummaryText)
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.secondaryText)
                HStack(spacing: 8) {
                    TagLabel("\(summaries.count) main windows")
                    TagLabel("\(summaries.reduce(0) { $0 + $1.accountCount }) account windows")
                    TagLabel(model.storeStatus.rawValue)
                }
            }
            Spacer(minLength: 16)
            if let tightestSummary {
                CapacityDial(
                    value: tightestSummary.capacityRatio,
                    status: tightestSummary.status,
                    label: "\(Int((tightestSummary.capacityRatio * 100).rounded()))",
                    sublabel: "left",
                    size: 116
                )
            }
        }
        .padding(22)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private var providerSummaryText: String {
        guard !summaries.isEmpty else { return "No main limits available yet." }
        return summaries
            .map { "\($0.window.displayName.lowercased()) \($0.previewRemainingHeadline.lowercased())" }
            .joined(separator: " · ")
    }
}

struct SetupStatusStrip: View {
    @ObservedObject var model: ContextPanelAppModel

    var body: some View {
        HStack(spacing: 12) {
            SetupStatusItem(
                title: "Snapshot cache",
                value: model.storeStatus == .healthy ? "Ready" : model.storeStatus.rawValue,
                status: model.storeStatus
            )
            SetupStatusItem(
                title: "History",
                value: "\(model.historyCount) entries",
                status: model.historyCount > 0 ? .healthy : .unknown
            )
            SetupStatusItem(
                title: "Last refresh",
                value: model.lastRefreshText,
                status: model.isRefreshing ? .loading : .healthy
            )
            Spacer(minLength: 12)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.statusColor(.failure))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 10))
    }
}

struct SetupStatusItem: View {
    let title: String
    let value: String
    let status: UsageStatus

    var body: some View {
        HStack(spacing: 8) {
            StatusMark(status: status, size: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(1)
            }
        }
    }
}

struct WidgetPreviewGrid: View {
    let snapshot: UsageSnapshot

    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Usage Glance", trailing: "Native preview")
            HStack(alignment: .top, spacing: 12) {
                SmallWidgetPreview(snapshot: snapshot)
                MediumWidgetPreview(snapshot: snapshot)
            }
            LargeWidgetPreview(snapshot: snapshot)
        }
    }
}

struct SmallWidgetPreview: View {
    let snapshot: UsageSnapshot

    var body: some View {
        WidgetShell(width: 220, height: 220) {
            VStack(alignment: .leading, spacing: 10) {
                WidgetHeader(status: snapshot.aggregateStatus)
                Spacer()
                Text(snapshot.tightestMainLimitSummary?.previewRemainingHeadline ?? "No data")
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(snapshot.tightestMainLimitSummary?.previewWindowLine ?? "Add OpenAI, Anthropic, or Google.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(2)
                Text(snapshot.tightestMainLimitSummary?.previewResetConfidenceText ?? snapshot.subheadline)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
                CapacityBar(value: snapshot.tightestMainLimitSummary?.usageRatio ?? 0, status: snapshot.aggregateStatus, height: 6)
                Spacer()
                ProviderMiniStatus(snapshot: snapshot)
            }
        }
    }
}

struct MediumWidgetPreview: View {
    let snapshot: UsageSnapshot

    var body: some View {
        WidgetShell(width: 460, height: 220) {
            HStack(spacing: 18) {
                VStack(alignment: .leading) {
                    WidgetHeader(status: snapshot.aggregateStatus)
                    Spacer()
                    Text(snapshot.tightestMainLimitSummary?.previewRemainingHeadline ?? "No data")
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CPTheme.primaryText)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text(snapshot.tightestMainLimitSummary?.provider.displayName ?? "Set up accounts")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.secondaryText)
                        .textCase(.uppercase)
                    CapacityBar(value: snapshot.tightestMainLimitSummary?.usageRatio ?? 0, status: snapshot.aggregateStatus, height: 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(snapshot.fastModeForecast.copy)
                            .font(.system(size: 18, weight: .semibold))
                        Text(snapshot.providerPressureText)
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.tertiaryText)
                    }
                    Spacer()
                    Text(snapshot.nearestResetText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CPTheme.tertiaryText)
                }
                .frame(width: 150, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Main Limits", trailing: "\(snapshot.mainLimitSummaries.count) windows")
                    ForEach(snapshot.mostConstrainedMainLimitSummaries.prefix(4)) { summary in
                        MainLimitRow(summary: summary, compact: true)
                    }
                }
            }
        }
    }
}

struct LargeWidgetPreview: View {
    let snapshot: UsageSnapshot

    var body: some View {
        WidgetShell(width: 460, height: 460) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        CPLabel("Context Panel")
                        Text(snapshot.fastModeForecast.copy)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        Text(snapshot.tightestMainLimitSummary?.previewWindowLine ?? snapshot.tightestSupportText)
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(snapshot.tightestMainLimitSummary?.previewRemainingHeadline ?? "No data")
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .foregroundStyle(CPTheme.primaryText)
                        Text(snapshot.providerPressureText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                }

                ProviderGroupGrid(snapshot: snapshot, compact: true)

                Spacer(minLength: 0)
                Divider()
                HStack {
                    Text(snapshot.fastModeForecast.copy)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPTheme.accent)
                        .lineLimit(1)
                    Spacer()
                    Text(snapshot.nearestResetText)
                        .font(.system(size: 10))
                        .foregroundStyle(CPTheme.tertiaryText)
                }
            }
        }
    }
}

struct ProviderGroupGrid: View {
    let snapshot: UsageSnapshot
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Provider.allCases) { provider in
                let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                if !summaries.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProviderBadge(provider: provider, compact: true)
                            Text(provider.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                            Spacer()
                            StatusMark(status: summaries.map(\.status).worstStatus, size: 7)
                        }
                        .foregroundStyle(CPTheme.secondaryText)
                        Divider()
                        ForEach(summaries.prefix(compact ? 3 : 4)) { summary in
                            MainLimitRow(summary: summary, compact: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

struct AdditionalLimitsSection: View {
    let snapshot: UsageSnapshot
    var provider: Provider?
    @State private var isExpanded = false

    private var limits: [UsageLimit] {
        snapshot.additionalLimits
            .filter { provider == nil || $0.provider == provider }
            .sorted { lhs, rhs in
                if lhs.provider != rhs.provider {
                    let lhsIndex = Provider.allCases.firstIndex(of: lhs.provider) ?? 0
                    let rhsIndex = Provider.allCases.firstIndex(of: rhs.provider) ?? 0
                    return lhsIndex < rhsIndex
                }
                if lhs.accountName != rhs.accountName {
                    return lhs.accountName < rhs.accountName
                }
                return lhs.displayLabel < rhs.displayLabel
            }
    }

    var body: some View {
        if !limits.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(spacing: 8) {
                    ForEach(limits) { limit in
                        AdditionalLimitRow(limit: limit)
                    }
                }
                .padding(.top, 10)
            } label: {
                SectionHeader(title: "Additional Limits", trailing: "\(limits.count) hidden from widget")
            }
            .padding(14)
            .background(CPTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(CPTheme.stroke(cornerRadius: 10))
        }
    }
}

struct AdditionalLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: limit.provider, compact: true)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.displayLabel)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
                Text(limit.contextLabel.isEmpty ? limit.accountName : limit.contextLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(limit.previewUsageText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPTheme.secondaryText)
                Text(limit.resetText)
                    .font(.system(size: 10))
                    .foregroundStyle(CPTheme.tertiaryText)
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MainLimitDetail: View {
    @ObservedObject var model: ContextPanelAppModel
    let summary: MainLimitSummary
    let generatedAt: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ProviderBadge(provider: summary.provider)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.window.displayName)
                            .font(.system(size: 22, weight: .semibold))
                        Text("\(summary.provider.displayName) · \(summary.accountText)")
                            .font(.system(size: 13))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    Spacer()
                    StatusMark(status: summary.status, size: 10)
                }

                CapacityDial(
                    value: summary.capacityRatio,
                    status: summary.status,
                    label: summary.detailRemainingValue,
                    sublabel: "left",
                    size: 140
                )
                .frame(maxWidth: .infinity)

                DetailCard(title: "Forecast") {
                    Text(forecastCopy)
                        .font(.system(size: 15, weight: .medium))
                    Text("Fast mode spends 2x capacity for about 1.5x throughput.")
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.secondaryText)
                    Text("Confidence: \(summary.confidence.rawValue)")
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.secondaryText)
                }

                DetailCard(title: "Pooled limit") {
                    DetailRow(label: "Provider", value: summary.provider.displayName)
                    DetailRow(label: "Window", value: summary.window.displayName)
                    DetailRow(label: "Accounts", value: "\(summary.accountCount)")
                    DetailRow(label: "Used", value: summary.used.map(String.init) ?? "unknown")
                    DetailRow(label: "Limit", value: summary.limit.map(String.init) ?? "unknown")
                    DetailRow(label: "Remaining", value: summary.remaining.map(String.init) ?? "unknown")
                    DetailRow(label: "Status", value: summary.status.rawValue)
                    DetailRow(label: "Updated", value: summary.lastUpdatedAt.map(model.relativeTime) ?? "unknown")
                }

                DetailCard(title: "Accounts") {
                    ForEach(summary.limits) { limit in
                        DetailRow(
                            label: limit.accountName,
                            value: "\(limit.remaining.map(String.init) ?? "?") left · \(limit.status.rawValue)"
                        )
                    }
                }
            }
            .padding(22)
        }
        .background(CPTheme.background)
        .navigationTitle("Details")
    }

    private var forecastCopy: String {
        guard let limit = summary.pooledLimit else {
            return "No limit data for this window yet."
        }
        if summary.provider == .openAI, limit.unit == .percent {
            let settings = model.fastModeForecastSettings
            return FastModeCapacityForecast(
                limitID: summary.id,
                accountName: limit.accountName,
                providerLimits: summary.limits,
                now: Date(),
                standardBurnRate: settings.defaultStandardBurnRateUnitsPerHour.map {
                    BurnRate(mode: .standard, unitsPerHour: $0)
                },
                fastBurnRate: settings.defaultStandardBurnRateUnitsPerHour.map {
                    BurnRate(mode: .fast, unitsPerHour: $0 * settings.fastModeMultiplier)
                },
                reserveUnits: settings.reserveUnits,
                minimumSafeHours: settings.minimumSafeHours
            ).copy
        }
        return limit.note ?? "Fast-mode forecast currently applies to OpenAI main windows."
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CPLabel(title)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 10))
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(CPTheme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced, weight: .medium))
        }
        .font(.system(size: 13))
    }
}

struct WidgetShell<Content: View>: View {
    let width: CGFloat
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(width: width, height: height)
            .background(CPTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(CPTheme.stroke(cornerRadius: 20))
            .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
    }
}

struct WidgetHeader: View {
    let status: UsageStatus

    var body: some View {
        HStack {
            CPLabel("Context Panel")
            Spacer()
            Text(status.previewStatusText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(CPTheme.statusColor(status))
                .textCase(.uppercase)
        }
    }
}

struct ProviderMiniStatus: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Provider.allCases) { provider in
                let hasMainLimits = snapshot.mainLimitSummaries.contains { $0.provider == provider }
                Text(provider.shortName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hasMainLimits ? CPTheme.providerColor(provider) : CPTheme.tertiaryText)
                    .lineLimit(1)
                    .opacity(hasMainLimits ? 1 : 0.35)
            }
        }
    }
}

struct MainLimitRow: View {
    let summary: MainLimitSummary
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: summary.provider, compact: true)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(compact ? summary.compactPreviewWindowLine : summary.previewWindowLine)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Text(summary.previewUsageText)
                        .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CPTheme.secondaryText)
                }
                HStack(spacing: 8) {
                    CapacityBar(value: summary.usageRatio ?? 0, status: summary.status)
                    Text(compact ? summary.resetText : summary.previewResetConfidenceText)
                        .font(.system(size: 10))
                        .foregroundStyle(summary.status == .stale ? CPTheme.statusColor(.stale) : CPTheme.tertiaryText)
                        .lineLimit(1)
                }
            }
        }
        .padding(compact ? 0 : 10)
        .background(compact ? Color.clear : CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: compact ? 0 : 8, style: .continuous))
        .overlay {
            if !compact {
                CPTheme.stroke(cornerRadius: 8)
            }
        }
    }
}

@MainActor
final class ContextPanelAppModel: ObservableObject {
    @Published private(set) var storedSnapshot: StoredUsageSnapshot?
    @Published private(set) var storeStatus: UsageStatus = .unknown
    @Published private(set) var historyCount: Int = 0
    @Published private(set) var configuredAccounts: [LocalProviderAccountConfiguration] = []
    @Published private(set) var fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
    @Published private(set) var isRefreshing = false
    @Published var isClaudeWebCapturePresented = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshAt: Date?

    private let refreshService: SnapshotRefreshService
    private let refreshRunner: SnapshotRefreshRunner
    private let forecastSettingsStore = FastModeForecastSettingsStore(
        settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    var currentSnapshot: UsageSnapshot {
        storedSnapshot?.snapshot ?? SampleUsageData.snapshot
    }

    var fastModeForecast: FastModeCapacityPortfolioForecast {
        currentSnapshot.fastModeForecast(settings: fastModeForecastSettings)
    }

    var lastRefreshText: String {
        lastRefreshAt.map(relativeTime) ?? "not yet"
    }

    init() {
        refreshService = .appDefault()
        refreshRunner = SnapshotRefreshRunner(service: refreshService)
    }

    func loadSnapshot() {
        fastModeForecastSettings = forecastSettingsStore.load()
        let accounts = refreshService.loadConfiguredAccounts().document.accounts
        configuredAccounts = accounts
        let result = refreshService.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 15 * 60), now: Date())
        storedSnapshot = result.snapshot
        storeStatus = result.status
        if result.status == .failure || result.errorMessage != nil {
            errorMessage = result.errorMessage
        } else if errorMessage?.hasPrefix("Background refresh could not be enabled:") != true {
            errorMessage = nil
        }
        historyCount = refreshService.loadHistory().count
        mirrorSnapshotsForDevelopmentWidget()
        mirrorDisplayPreferencesForDevelopmentWidget()
    }

    func refreshLocalConnectors() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let decision = try await refreshRunner.refresh()
            if case let .refreshed(outcome) = decision {
                lastRefreshAt = outcome.savedAt
                WidgetCenter.shared.reloadAllTimelines()
            }
            loadSnapshot()
        } catch {
            storeStatus = .failure
            errorMessage = error.localizedDescription
        }
    }

    func setError(_ message: String) {
        storeStatus = .failure
        errorMessage = ConnectorRedactor.redact(message)
    }

    func openClaudeWebCapture() {
        isClaudeWebCapturePresented = true
    }

    func closeClaudeWebCapture() {
        isClaudeWebCapturePresented = false
    }

    func saveClaudeWebLimits(_ limits: [UsageLimit]) {
        guard !limits.isEmpty else { return }
        Task { await saveClaudeWebLimitsAsync(limits) }
    }

    private func saveClaudeWebLimitsAsync(_ limits: [UsageLimit]) async {
        let savedAt = Date()
        let report = ProviderConnectorReport(
            provider: .anthropic,
            accountID: "claude-web",
            accountName: "Claude Web",
            generatedAt: savedAt,
            limits: limits,
            status: .healthy
        )
        do {
            let decision = try await refreshRunner.saveMerged(
                refreshResult: ConnectorRefreshResult(generatedAt: savedAt, reports: [report]),
                savedAt: savedAt,
                retryFor: .seconds(5)
            )
            guard case .refreshed = decision else {
                setError("Snapshot is refreshing. Try saving Claude Web usage again in a moment.")
                return
            }
            lastRefreshAt = savedAt
            loadSnapshot()
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            storeStatus = .failure
            errorMessage = error.localizedDescription
        }
    }

    func relativeTime(_ date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func mirrorSnapshotsForDevelopmentWidget() {
        guard ContextPanelLocations.usesDevelopmentWidgetMirrors else { return }
        do {
            try refreshService.mirrorPrimarySnapshotToDevelopmentStores()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mirrorDisplayPreferencesForDevelopmentWidget() {
        guard ContextPanelLocations.usesDevelopmentWidgetMirrors else { return }
        let sourceURL = ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return }

        do {
            for destinationURL in [
                ContextPanelLocations.widgetDevelopmentDisplayPreferencesURL(),
                ContextPanelLocations.widgetDevelopmentContainerDisplayPreferencesURL(),
                ContextPanelLocations.hostDevelopmentDisplayPreferencesURL(),
            ] {
                if destinationURL.standardizedFileURL == sourceURL.standardizedFileURL {
                    continue
                }
                try FileManager.default.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

}

struct CapacityDial: View {
    let value: Double
    let status: UsageStatus
    let label: String
    let sublabel: String
    var size: CGFloat = 96
    var thickness: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(CPTheme.line, lineWidth: thickness)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(
                    CPTheme.statusColor(status),
                    style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: size > 100 ? 30 : 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPTheme.primaryText)
                Text(sublabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .textCase(.uppercase)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CapacityBar: View {
    let value: Double
    let status: UsageStatus
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(CPTheme.line)
                Capsule()
                    .fill(CPTheme.statusColor(status))
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

struct ProviderBadge: View {
    let provider: Provider
    var compact = false

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(CPTheme.providerColor(provider))
            .lineLimit(1)
    }
}

struct StatusMark: View {
    let status: UsageStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch status {
            case .healthy:
                Circle().fill(CPTheme.statusColor(status))
            case .close:
                Circle().trim(from: 0, to: 0.75).stroke(CPTheme.statusColor(status), lineWidth: 2)
            case .limited:
                RoundedRectangle(cornerRadius: 1).fill(CPTheme.statusColor(status))
            case .stale:
                Circle().stroke(CPTheme.statusColor(status), style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
            case .unknown:
                Text("?").font(.system(size: size + 3, weight: .semibold)).foregroundStyle(CPTheme.statusColor(status))
            case .failure:
                Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(CPTheme.statusColor(status))
            case .loading:
                Circle().stroke(CPTheme.statusColor(status), lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
    }
}

struct ClaudeWebCaptureSheet: View {
    @ObservedObject var model: ContextPanelAppModel
    @StateObject private var captureModel = ClaudeWebCaptureModel()

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Claude Web")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Complete Claude verification here. The app captures only official usage windows from the Usage page.")
                        .font(.system(size: 13))
                        .foregroundStyle(CPTheme.secondaryText)
                }

                HStack {
                    Button("Open Usage") { captureModel.openUsagePage() }
                    Button("Reload") { captureModel.reload() }
                    Spacer()
                    Button("Done") { model.closeClaudeWebCapture() }
                }

                Label(captureModel.statusText, systemImage: captureModel.statusIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(captureModel.limits.isEmpty ? CPTheme.secondaryText : CPTheme.primaryText)

                Divider()

                Text("Captured windows")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(CPTheme.secondaryText)

                if captureModel.limits.isEmpty {
                    ContentUnavailableView(
                        "Waiting for Claude usage",
                        systemImage: "network",
                        description: Text("The sheet auto-saves when Claude's usage endpoint returns percent windows.")
                    )
                    .frame(maxHeight: 220)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(captureModel.limits) { limit in
                                ClaudeWebCaptureLimitRow(limit: limit)
                            }
                        }
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Label("No cookies, tokens, headers, IDs, emails, local storage, or raw bodies are stored.", systemImage: "lock.shield")
                    Label("Saved rows are merged with OpenAI and Gemini instead of replacing them.", systemImage: "square.stack.3d.up")
                }
                .font(.system(size: 11))
                .foregroundStyle(CPTheme.secondaryText)
            }
            .frame(width: 330)
            .padding(18)
            .background(CPTheme.surface)

            Divider()

            ClaudeWebCaptureWebView(model: captureModel)
        }
        .onReceive(captureModel.$limits) { limits in
            guard !limits.isEmpty else { return }
            model.saveClaudeWebLimits(limits)
        }
    }
}

struct ClaudeWebCaptureLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(limit.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                    Text(limit.contextLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(CPTheme.secondaryText)
                }
                Spacer()
                Text(limit.compactUsageText)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
            }
            CapacityBar(value: limit.usageRatio ?? 0, status: limit.status)
            Text(limit.resetText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(CPTheme.tertiaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 8))
    }
}

@MainActor
final class ClaudeWebCaptureModel: ObservableObject {
    @Published var limits: [UsageLimit] = []
    @Published var statusText = "Opening Claude usage page"
    @Published var statusIcon = "safari"

    private lazy var navigationDelegate = ClaudeWebCaptureNavigationDelegate(owner: self)

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(ClaudeWebCaptureScriptHandler(owner: self), name: "claudeUsageCapture")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.networkProbeScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = navigationDelegate
        return view
    }()

    init() {
        openUsagePage()
    }

    func openUsagePage() {
        statusText = "Opening Claude usage page"
        statusIcon = "safari"
        webView.load(URLRequest(url: URL(string: "https://claude.ai/settings/usage")!))
    }

    func reload() {
        statusText = "Reloading Claude usage page"
        statusIcon = "arrow.clockwise"
        webView.reload()
    }

    fileprivate func record(payload: [String: Any]) {
        let windows = payload["windows"] as? [String: Any] ?? [:]
        let wrapped = ["rate_limits": windows]
        do {
            let data = try JSONSerialization.data(withJSONObject: wrapped)
            let parsed = try ClaudeWebUsageParser.usageLimits(
                from: data,
                accountID: "claude-web",
                accountName: "Claude Web",
                observedAt: Date()
            )
            guard !parsed.isEmpty else { return }
            limits = parsed
            statusText = "Captured and saved Claude web usage"
            statusIcon = "checkmark.circle.fill"
        } catch {
            statusText = "Capture failed: \(error.localizedDescription)"
            statusIcon = "exclamationmark.triangle"
        }
    }

    fileprivate func didFinishNavigation(url: URL?) {
        if let host = url?.host, host.contains("claude.ai"), limits.isEmpty {
            statusText = "Claude page loaded; waiting for usage API"
            statusIcon = "network"
        }
    }

    private static let networkProbeScript = #"""
    (() => {
      if (window.__contextPanelClaudeUsageCaptureInstalled) return;
      window.__contextPanelClaudeUsageCaptureInstalled = true;

      const windowKeys = new Set(['five_hour', 'seven_day', 'seven_day_opus', 'seven_day_sonnet', 'seven_day_oauth_apps']);
      const fieldKeys = new Set(['used_percentage', 'remaining_percentage', 'utilization', 'resets_at', 'reset_at']);

      function isUsageURL(rawUrl) {
        try { return /^\/api\/organizations\/[^/]+\/usage$/.test(new URL(rawUrl, window.location.href).pathname); }
        catch (_) { return false; }
      }

      function sanitizeWindow(value) {
        if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
        const sanitized = {};
        for (const key of fieldKeys) {
          const raw = value[key];
          if (typeof raw === 'number' || typeof raw === 'string') sanitized[key] = raw;
        }
        return Object.keys(sanitized).length ? sanitized : null;
      }

      function collectWindows(value, out = {}) {
        if (!value || typeof value !== 'object') return out;
        if (Array.isArray(value)) {
          value.slice(0, 3).forEach(item => collectWindows(item, out));
          return out;
        }
        for (const [key, child] of Object.entries(value)) {
          if (windowKeys.has(key)) {
            const sanitized = sanitizeWindow(child);
            if (sanitized) out[key] = sanitized;
          }
          collectWindows(child, out);
        }
        return out;
      }

      function post(payload) {
        try { window.webkit.messageHandlers.claudeUsageCapture.postMessage(payload); }
        catch (_) {}
      }

      function inspect(url, contentType, text) {
        if (!isUsageURL(url) || !/json/i.test(contentType || '')) return;
        try {
          const windows = collectWindows(JSON.parse(String(text || '')));
          if (Object.keys(windows).length) post({ windows });
        } catch (_) {}
      }

      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = async function(input, init) {
          const response = await originalFetch.apply(this, arguments);
          try {
            const clone = response.clone();
            const url = typeof input === 'string' ? input : (input && input.url) || '';
            clone.text().then(text => inspect(url, clone.headers.get('content-type') || '', text)).catch(() => {});
          } catch (_) {}
          return response;
        };
      }

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__cpClaudeUsageUrl = url;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function() {
        this.addEventListener('load', function() {
          try { inspect(this.__cpClaudeUsageUrl || '', this.getResponseHeader('content-type') || '', this.responseText || ''); }
          catch (_) {}
        });
        return originalSend.apply(this, arguments);
      };
    })();
    """#
}

final class ClaudeWebCaptureScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: ClaudeWebCaptureModel?

    init(owner: ClaudeWebCaptureModel) {
        self.owner = owner
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        Task { @MainActor [weak owner] in owner?.record(payload: payload) }
    }
}

final class ClaudeWebCaptureNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var owner: ClaudeWebCaptureModel?

    init(owner: ClaudeWebCaptureModel) {
        self.owner = owner
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak webView, weak owner] in owner?.didFinishNavigation(url: webView?.url) }
    }
}

struct ClaudeWebCaptureWebView: NSViewRepresentable {
    @ObservedObject var model: ClaudeWebCaptureModel

    func makeNSView(context: Context) -> WKWebView { model.webView }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                guard let first = values.first else { return }
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: proxy.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                        y: proxy.size.height * CGFloat(1 - min(max(value, 0), 1))
                    )
                }
                path.move(to: CGPoint(x: 0, y: proxy.size.height * CGFloat(1 - first)))
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
            .stroke(CPTheme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(CPTheme.tertiaryText)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.tertiaryText)
            }
        }
    }
}

struct CPLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(CPTheme.tertiaryText)
    }
}

struct TagLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(CPTheme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(CPTheme.accent.opacity(0.08))
            .clipShape(Capsule())
    }
}

enum CPTheme {
    static let background = adaptiveColor(
        light: NSColor(red: 244 / 255, green: 244 / 255, blue: 245 / 255, alpha: 1),
        dark: NSColor(red: 22 / 255, green: 23 / 255, blue: 25 / 255, alpha: 1)
    )
    static let surface = adaptiveColor(
        light: .white,
        dark: NSColor(red: 34 / 255, green: 35 / 255, blue: 38 / 255, alpha: 1)
    )
    static let surface2 = adaptiveColor(
        light: NSColor(red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(red: 43 / 255, green: 44 / 255, blue: 48 / 255, alpha: 1)
    )
    static let line = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.07),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    static let primaryText = adaptiveColor(
        light: NSColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1),
        dark: NSColor(red: 238 / 255, green: 239 / 255, blue: 241 / 255, alpha: 1)
    )
    static let secondaryText = adaptiveColor(
        light: NSColor(red: 87 / 255, green: 87 / 255, blue: 92 / 255, alpha: 1),
        dark: NSColor(red: 178 / 255, green: 180 / 255, blue: 186 / 255, alpha: 1)
    )
    static let tertiaryText = adaptiveColor(
        light: NSColor(red: 130 / 255, green: 130 / 255, blue: 136 / 255, alpha: 1),
        dark: NSColor(red: 128 / 255, green: 131 / 255, blue: 139 / 255, alpha: 1)
    )
    static let accent = Color(red: 74 / 255, green: 91 / 255, blue: 122 / 255)

    static func providerColor(_ provider: Provider) -> Color {
        switch provider {
        case .openAI:
            Color(red: 56 / 255, green: 92 / 255, blue: 126 / 255)
        case .anthropic:
            Color(red: 139 / 255, green: 102 / 255, blue: 51 / 255)
        case .google:
            Color(red: 35 / 255, green: 116 / 255, blue: 106 / 255)
        }
    }

    static func statusColor(_ status: UsageStatus) -> Color {
        switch status {
        case .healthy:
            Color(red: 74 / 255, green: 122 / 255, blue: 91 / 255)
        case .close:
            Color(red: 138 / 255, green: 106 / 255, blue: 42 / 255)
        case .limited, .failure:
            Color(red: 138 / 255, green: 74 / 255, blue: 74 / 255)
        case .stale, .unknown, .loading:
            Color(red: 106 / 255, green: 106 / 255, blue: 114 / 255)
        }
    }

    static func stroke(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(line, lineWidth: 1)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        })
    }
}

extension UsageSnapshot {
    var headline: String {
        "Know whether you can keep working."
    }

    var subheadline: String {
        "OpenAI, Anthropic, and Google capacity with local confidence."
    }

    var tightestMainLimitSummary: MainLimitSummary? {
        mostConstrainedMainLimitSummaries.first
    }

    var tightestUsageText: String {
        guard let tightestMainLimitSummary else { return "Set up accounts" }
        return tightestMainLimitSummary.previewRemainingHeadline
    }

    var tightestSupportText: String {
        guard let tightestMainLimitSummary else { return "Add OpenAI, Anthropic, or Google." }
        return "\(tightestMainLimitSummary.provider.shortName) · \(tightestMainLimitSummary.window.displayName) · \(tightestMainLimitSummary.accountText)"
    }

    var tightestCapacityRatio: Double {
        guard let ratio = tightestMainLimitSummary?.usageRatio else { return 0 }
        return max(1 - ratio, 0)
    }

    var fastModeForecast: FastModeCapacityPortfolioForecast {
        fastModeForecast(settings: .defaultSettings)
    }

    func fastModeForecast(settings: FastModeForecastSettings) -> FastModeCapacityPortfolioForecast {
        mainLimitSummaries.openAIFastModeCapacityForecast(
            settings: settings
        )
    }

    var providerPressureText: String {
        let limited = mainLimitSummaries.filter { $0.status == .limited }.count
        let close = mainLimitSummaries.filter { $0.status == .close }.count
        if limited > 0 || close > 0 {
            return "\(limited) limited · \(close) close"
        }
        return "main windows healthy"
    }

    var nearestResetText: String {
        let futureResets = mainLimitSummaries.compactMap(\.resetsAt).filter { $0 > Date() }.sorted()
        guard let reset = futureResets.first else { return "reset unknown" }
        return "nearest reset \(reset.widgetRelativeText)"
    }

    var additionalLimits: [UsageLimit] {
        limits.filter { !$0.isMainLimit }
    }
}

extension MainLimitSummary {
    var previewRemainingHeadline: String {
        guard unit != nil, remaining != nil else {
            if status == .failure { return "Failed" }
            return "Unknown"
        }
        if usageRatio != nil { return "\(Int((capacityRatio * 100).rounded()))% left" }
        guard let remaining else { return "Unknown" }
        return "\(remaining) left"
    }

    var compactUsageText: String {
        guard unit != nil, used != nil, limit != nil else {
            return status == .failure ? "—" : "?"
        }
        if usageRatio != nil {
            return "\(Int(((usageRatio ?? 0) * 100).rounded()))% used"
        }
        guard let used, let limit else { return "?" }
        return "\(used)/\(limit)"
    }

    var previewUsageText: String {
        guard unit != nil, used != nil, limit != nil else {
            return status == .failure ? "refresh failed" : "unknown"
        }
        if usageRatio != nil {
            return "\(Int(((usageRatio ?? 0) * 100).rounded()))% used"
        }
        guard let used, let limit else { return "unknown" }
        return "\(used)/\(limit) used"
    }

    var previewWindowLine: String {
        "\(window.displayName) · \(accountText)"
    }

    var compactPreviewWindowLine: String {
        "\(window.shortName) · \(accountText)"
    }

    var sidebarDetailText: String {
        "\(accountText) · \(previewRemainingHeadline.lowercased())"
    }

    var accountText: String {
        accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    var resetText: String {
        if status == .failure { return "refresh failed" }
        guard let resetsAt else { return "unknown reset" }
        if resetsAt < Date().addingTimeInterval(-60) { return "reset passed" }
        if resetsAt.shouldShowWidgetDateTime {
            return "resets \(resetsAt.widgetRelativeText) · \(resetsAt.widgetDateTimeText)"
        }
        return "resets \(resetsAt.widgetRelativeText)"
    }

    var previewResetConfidenceText: String {
        "\(resetText) · \(confidence.previewText)"
    }

    var detailRemainingValue: String {
        guard unit != .percent else {
            return "\(Int((capacityRatio * 100).rounded()))%"
        }
        return remaining.map(String.init) ?? "?"
    }
}

extension UsageLimit {
    var previewRemainingHeadline: String {
        guard let remaining else {
            if status == .failure { return "Failed" }
            return "Unknown"
        }
        if unit == .percent { return "\(remaining)% left" }
        return "\(remaining) left"
    }

    var compactUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "unknown"
        }
        guard let used, let limit else { return status == .failure ? "—" : "?" }
        return "\(used)/\(limit)"
    }

    var percentText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "unknown"
        }
        guard let usageRatio else { return status == .failure ? "—" : "?" }
        return "\(Int(usageRatio * 100))%"
    }

    var previewUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "allowance unknown"
        }
        if unit == .percent, let used {
            return "\(used)% used"
        }
        if let used, let limit {
            return "\(used)/\(limit) used"
        }
        if status == .failure { return "refresh failed" }
        return "unknown"
    }

    var previewWindowLine: String {
        [provider.shortName, accountName, displayLabel, modelLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .deduplicated()
            .joined(separator: " · ")
    }

    var resetText: String {
        if status == .failure { return "refresh failed" }
        guard let resetsAt else { return "unknown reset" }
        if resetsAt < Date().addingTimeInterval(-60) { return "reset passed" }
        if resetsAt.shouldShowWidgetDateTime {
            return "resets \(resetsAt.widgetRelativeText) · \(resetsAt.widgetDateTimeText)"
        }
        return "resets \(resetsAt.widgetRelativeText)"
    }

    var previewResetConfidenceText: String {
        "\(resetText) · \(confidence.previewText)"
    }
}

extension UsageStatus {
    var previewStatusText: String {
        switch self {
        case .healthy:
            "ok"
        case .close:
            "close"
        case .limited:
            "limited"
        case .stale:
            "stale"
        case .unknown:
            "unknown"
        case .failure:
            "failed"
        case .loading:
            "loading"
        }
    }
}

extension UsageConfidence {
    var previewText: String {
        switch self {
        case .official:
            "official"
        case .observed:
            "observed"
        case .manual:
            "manual"
        case .estimated:
            "estimated"
        case .unknown:
            "confidence unknown"
        }
    }
}

extension Array where Element == String {
    fileprivate func deduplicated() -> [String] {
        reduce(into: []) { result, value in
            if !result.contains(value) {
                result.append(value)
            }
        }
    }
}

extension Date {
    var widgetRelativeText: String {
        let seconds = Int(timeIntervalSince(Date()))
        if abs(seconds) < 60 { return "now" }
        if seconds >= 0 {
            let minutes = seconds / 60
            if minutes < 60 { return "in \(minutes)m" }
            let hours = minutes / 60
            if hours < 24 { return "in \(hours)h" }
            return "in \(Self.formatDaysAndHours(hours: hours))"
        }
        let elapsed = abs(seconds)
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(Self.formatDaysAndHours(hours: hours)) ago"
    }

    var shouldShowWidgetDateTime: Bool {
        abs(timeIntervalSince(Date())) >= 24 * 3_600
    }

    var widgetDateTimeText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE h:mm a"
        return formatter.string(from: self)
    }

    private static func formatDaysAndHours(hours: Int) -> String {
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
    }
}

extension [UsageStatus] {
    var worstStatus: UsageStatus {
        contextPanelWorstStatus
    }
}
