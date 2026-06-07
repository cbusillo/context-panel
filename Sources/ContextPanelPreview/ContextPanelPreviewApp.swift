import ContextPanelCore
import AppKit
import Network
import os
import ServiceManagement
import SwiftUI
import WidgetKit

private let contextPanelLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "app")

@main
struct ContextPanelPreviewApp: App {
    @NSApplicationDelegateAdaptor(ContextPanelAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Context Panel", id: "main") {
            AppRoot(model: appDelegate.model)
                .frame(minWidth: 1080, idealWidth: 1080, minHeight: 720, idealHeight: 720)
                .onOpenURL { url in
                    appDelegate.model.handleOpenURL(url)
                    appDelegate.presentMainWindowWhenAvailable()
                }
                .handlesExternalEvents(preferring: ["overview", "reconnect"], allowing: ["*"])
        }
        .defaultSize(width: 1080, height: 720)
        .handlesExternalEvents(matching: ["overview", "reconnect"])

        Settings {
            SettingsPane(appModel: appDelegate.model)
        }
    }
}

@MainActor
final class ContextPanelAppDelegate: NSObject, NSApplicationDelegate {
    let model = ContextPanelAppModel()
    private let backgroundRefreshSettingsStore = BackgroundRefreshSettingsStore(
        settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleCommandLineUtilityMode() {
            return
        }
        reconcileRefreshAgentRegistration()
        model.loadSnapshot()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func handleCommandLineUtilityMode() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--refresh-local-connectors") {
            Task {
                await model.refreshLocalConnectors()
                await MainActor.run {
                    NSApp.terminate(nil)
                }
            }
            return true
        }
        guard arguments.contains("--unregister-refresh-agent") else { return false }

        let service = SMAppService.loginItem(identifier: ContextPanelLocations.refreshAgentBundleID)
        do {
            try service.unregister()
        } catch {
            model.setError("Background refresh could not be disabled: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
        return true
    }

    private func reconcileRefreshAgentRegistration() {
        let settings = backgroundRefreshSettingsStore.load()
        let service = SMAppService.loginItem(identifier: ContextPanelLocations.refreshAgentBundleID)
        do {
            if settings.isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            model.setError("Background refresh could not be updated: \(error.localizedDescription)")
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = Self.mainWindow(), flag {
            presentMainWindow(window)
            return false
        }
        return true
    }

    func presentMainWindowWhenAvailable(retriesRemaining: Int = 40) {
        if let window = Self.mainWindow() {
            presentMainWindow(window)
            return
        }

        guard retriesRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.presentMainWindowWhenAvailable(retriesRemaining: retriesRemaining - 1)
        }
    }

    private func presentMainWindow(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func mainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.title == "Context Panel" && window.isVisible && !window.isMiniaturized
        } ?? NSApp.windows.first { window in
            window.title == "Context Panel" && !window.isMiniaturized
        } ?? NSApp.windows.first { window in
            window.title == "Context Panel"
        }
    }
}

enum AppNavigationSelection: Hashable {
    case overview
    case reconnect
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
        .onReceive(model.$navigationRequest.compactMap { $0 }) { request in
            selection = request
            model.clearNavigationRequest()
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            model.loadSnapshot(reloadWidgetTimelines: false)
        }
    }
}

struct SettingsPane: View {
    @ObservedObject var appModel: ContextPanelAppModel
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
                            Toggle("", isOn: Binding(
                                get: { account.isEnabled },
                                set: { model.setAccount(account.id, isEnabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.mini)
                            if !account.isEnabled {
                                Text("Off")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(CPTheme.tertiaryText)
                            } else if model.hasSavedAuthorization(account) {
                                HStack(spacing: 8) {
                                    Text(model.authorizationSavedText(for: account))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CPTheme.statusColor(.healthy))
                                    if model.canAuthorizeAuthFile(for: account) {
                                        Button("Change") { authorizeAuthFile(for: account) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                            } else if model.hasLegacyAuthorization(account) {
                                HStack(spacing: 8) {
                                    Text("File access needs update")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CPTheme.statusColor(.stale))
                                    Button("Update") { authorizeAuthFile(for: account) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            } else if model.needsAuthorization(account) {
                                if model.canAuthorizeAuthFile(for: account) {
                                    Button("Select File") { authorizeAuthFile(for: account) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                } else if account.connectorKind == .claudeOAuthUsage {
                                    Button("Connect") { model.authorizeClaudeOAuth(for: account) }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                } else if account.connectorKind == .geminiCodeAssist {
                                    Button("Connect") { model.authorizeGoogleAntigravityOAuth(for: account) }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                }
                            } else {
                                Text(account.isEnabled ? "Enabled" : "Disabled")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(account.isEnabled ? CPTheme.statusColor(.healthy) : CPTheme.tertiaryText)
                            }
                        }
                        Text(model.detailText(for: account))
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.secondaryText)
                            .lineLimit(2)
                        if let refreshSummary = model.refreshSummary(for: account, storedSnapshot: appModel.storedSnapshot) {
                            Text(refreshSummary.text)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CPTheme.statusColor(refreshSummary.status))
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Diagnostics") {
                DetailRow(label: "Status", value: model.status.previewStatusText)
                DetailRow(label: "Last refresh", value: appModel.lastRefreshText)
                if let successfulRefreshText = appModel.lastSuccessfulProviderRefreshText {
                    DetailRow(label: "Last successful refresh", value: successfulRefreshText)
                }
                ForEach(appModel.diagnosticProviderReports) { report in
                    VStack(alignment: .leading, spacing: 4) {
                        DetailRow(label: report.title, value: report.summary)
                        if let detail = report.detail {
                            Text(detail)
                                .font(.system(size: 11))
                                .foregroundStyle(CPTheme.tertiaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.statusColor(.failure))
                        .textSelection(.enabled)
                }
            }

            Section("Background Refresh") {
                Toggle(isOn: Binding(
                    get: { model.backgroundRefreshSettings.isEnabled },
                    set: { model.setBackgroundRefreshEnabled($0) }
                )) {
                    Text("Refresh in background")
                }
                .toggleStyle(.switch)

                Picker("Refresh every", selection: Binding(
                    get: { model.backgroundRefreshSettings.intervalMinutes },
                    set: { model.setBackgroundRefreshInterval($0) }
                )) {
                    ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                        Text(minutes == 60 ? "1 hour" : "\(minutes) min").tag(minutes)
                    }
                }
                .disabled(!model.backgroundRefreshSettings.isEnabled)

                Text(model.backgroundRefreshStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)
            }

            Section("Widget Main Limits") {
                Text("Choose which main limits appear in the widget and drag rows to set their priority.")
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
                Text("Coming soon. Context Panel will be able to run a minimal refresh shortly after provider limits reset.")
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)

                Toggle("Reset primer", isOn: .constant(false))
                    .toggleStyle(.switch)
                    .disabled(true)

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
                .disabled(true)

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
                .disabled(true)

                List {
                    ForEach(model.resetPrimerSettings.accountPreferences) { preference in
                        ResetPrimerAccountPreferenceRow(
                            preference: preference,
                            isEnabled: Binding(
                                get: { preference.isEnabled },
                                set: { model.setResetPrimerAccount(preference.accountID, provider: preference.provider, isEnabled: $0) }
                            )
                        )
                    }
                }
                .listStyle(.inset)
                .frame(height: 150)
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 360)
        .sheet(isPresented: $model.isClaudeOAuthCodeSheetPresented) {
            ClaudeOAuthCodeSheet(model: model) {
                Task {
                    await appModel.refreshLocalConnectors()
                    model.load()
                }
            }
        }
        .sheet(isPresented: $model.isGoogleOAuthCodeSheetPresented) {
            GoogleAntigravityOAuthCodeSheet(model: model) {
                Task {
                    await appModel.refreshLocalConnectors()
                    model.load()
                }
            }
        }
        .onAppear { model.load() }
    }

    private func authorizeAuthFile(for account: LocalProviderAccountConfiguration) {
        model.authorizeAuthFile(for: account) {
            Task {
                await appModel.refreshLocalConnectors()
                model.load()
            }
        }
    }
}

struct ClaudeOAuthCodeSheet: View {
    @ObservedObject var model: SettingsPaneModel
    let onConnected: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Claude")
                .font(.system(size: 18, weight: .semibold))
            Text("After approving Claude in the browser, paste the authorization code here.")
                .font(.system(size: 12))
                .foregroundStyle(CPTheme.secondaryText)
            if let url = model.pendingClaudeOAuthAuthorizationURL {
                Link("Open Claude authorization", destination: url)
                    .font(.system(size: 12, weight: .medium))
                Text(url.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            TextField("Authorization code", text: $code)
                .textFieldStyle(.roundedBorder)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.statusColor(.failure))
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") {
                    model.cancelClaudeOAuth()
                    dismiss()
                }
                Spacer()
                Button(model.isCompletingClaudeOAuth ? "Connecting" : "Connect") {
                    model.completeClaudeOAuth(code: code) {
                        onConnected()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCompletingClaudeOAuth)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct GoogleAntigravityOAuthCodeSheet: View {
    @ObservedObject var model: SettingsPaneModel
    let onConnected: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect Google")
                .font(.system(size: 18, weight: .semibold))
            Text(
                model.isGoogleOAuthCallbackListening
                    ? "Approve Google in the browser. Context Panel is listening for the local callback and will finish automatically."
                    : "Approve Google in the browser. If the callback cannot return to Context Panel, paste the redirected URL or authorization code here."
            )
                .font(.system(size: 12))
                .foregroundStyle(CPTheme.secondaryText)
            if let url = model.pendingGoogleOAuthAuthorizationURL {
                Link("Open Google authorization", destination: url)
                    .font(.system(size: 12, weight: .medium))
                Text(url.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            TextField("Fallback redirect URL or authorization code", text: $code)
                .textFieldStyle(.roundedBorder)
            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.statusColor(.failure))
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") {
                    model.cancelGoogleAntigravityOAuth()
                    dismiss()
                }
                Spacer()
                Button(model.isCompletingGoogleOAuth ? "Connecting" : "Use Fallback") {
                    model.completeGoogleAntigravityOAuth(code: code) {
                        onConnected()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isCompletingGoogleOAuth)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear {
            model.cancelGoogleAntigravityOAuth()
        }
    }
}

struct SettingsAccountRefreshSummary: Equatable {
    let text: String
    let status: UsageStatus
}

@MainActor
final class SettingsPaneModel: ObservableObject {
    @Published private(set) var accounts: [LocalProviderAccountConfiguration] = []
    @Published private(set) var widgetPreferences: WidgetDisplayPreferences = .defaultPreferences
    @Published private(set) var resetPrimerSettings: ResetPrimerSettings = .defaultSettings
    @Published private(set) var backgroundRefreshSettings: BackgroundRefreshSettings = .defaultSettings
    @Published private(set) var status: UsageStatus = .unknown
    @Published private(set) var errorMessage: String?
    @Published private(set) var authorizedPaths: Set<String> = []
    @Published private(set) var missingAuthPaths: Set<String> = []
    @Published private(set) var legacyAuthPaths: Set<String> = []
    @Published var isClaudeOAuthCodeSheetPresented = false
    @Published private(set) var isCompletingClaudeOAuth = false
    @Published var isGoogleOAuthCodeSheetPresented = false
    @Published private(set) var isCompletingGoogleOAuth = false
    @Published private(set) var isGoogleOAuthCallbackListening = false

    private let bookmarkStore = SecureFileBookmarkStore(storeURL: ContextPanelLocations.bookmarkStoreURL())
    private let credentialStore = ProviderCredentialStore()
    private var recentlyVerifiedAuthPaths: Set<String> = []
    private var pendingClaudeOAuth: PendingClaudeOAuth?
    private var pendingGoogleOAuth: PendingGoogleAntigravityOAuth?
    private var googleOAuthCallbackServer: GoogleOAuthCallbackServer?

    var pendingClaudeOAuthAuthorizationURL: URL? {
        pendingClaudeOAuth?.authorizationURL
    }

    var pendingGoogleOAuthAuthorizationURL: URL? {
        pendingGoogleOAuth?.authorizationURL
    }

    private let store = AccountConfigurationStore(
        configurationURL: ContextPanelLocations.accountConfigurationURL(),
        fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
    )
    private let widgetPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let resetPrimerSettingsStore = ResetPrimerSettingsStore(
        settingsURL: ContextPanelLocations.resetPrimerSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let backgroundRefreshSettingsStore = BackgroundRefreshSettingsStore(
        settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    private var widgetPreferenceStores: WidgetDisplayPreferencesStoreSet {
        WidgetDisplayPreferencesStoreSet(stores: [widgetPreferenceStore])
    }

    var configurationPath: String {
        store.configurationURL.path
    }

    var backgroundRefreshStatusText: String {
        if backgroundRefreshSettings.isEnabled {
            return "Updates run every \(backgroundRefreshSettings.intervalMinutes) minutes in the background."
        }
        return "Background updates are off. Manual refresh still works."
    }

    func load() {
        let result = store.load()
        accounts = result.document.accounts
        var loadedAuthorizedPaths = Set(accounts.compactMap { account -> String? in
            guard let authPath = account.effectiveAuthPath else { return nil }
            guard account.connectorKind.requiresSecurityScopedAuthFile else { return nil }
            let expanded = NSString(string: authPath).expandingTildeInPath
            return bookmarkStore.hasCurrentBookmark(for: expanded) || hasImportedCredential(for: account) ? expanded : nil
        })
        loadedAuthorizedPaths.formUnion(recentlyVerifiedAuthPaths)
        authorizedPaths = loadedAuthorizedPaths

        var loadedMissingPaths = Set(accounts.compactMap { account -> String? in
            guard let authPath = account.effectiveAuthPath else { return nil }
            guard account.connectorKind.requiresSecurityScopedAuthFile else { return nil }
            let expanded = NSString(string: authPath).expandingTildeInPath
            return bookmarkStore.hasBookmark(for: expanded) || hasImportedCredential(for: account) ? nil : expanded
        })
        loadedMissingPaths.subtract(recentlyVerifiedAuthPaths)
        missingAuthPaths = loadedMissingPaths

        var loadedLegacyPaths = Set(accounts.compactMap { account -> String? in
            guard let authPath = account.effectiveAuthPath else { return nil }
            guard account.connectorKind.requiresSecurityScopedAuthFile else { return nil }
            let expanded = NSString(string: authPath).expandingTildeInPath
            guard !hasImportedCredential(for: account) else { return nil }
            return bookmarkStore.hasBookmark(for: expanded) && !bookmarkStore.hasCurrentBookmark(for: expanded) ? expanded : nil
        })
        loadedLegacyPaths.subtract(recentlyVerifiedAuthPaths)
        legacyAuthPaths = loadedLegacyPaths
        widgetPreferences = widgetPreferenceStores.load()
        backgroundRefreshSettings = backgroundRefreshSettingsStore.load()
        var primerSettings = resetPrimerSettingsStore.load()
        primerSettings.syncAccounts(result.document.accounts)
        resetPrimerSettings = primerSettings
        status = result.status
        if errorMessage == nil {
            errorMessage = result.errorMessage
        }
    }

    func setBackgroundRefreshEnabled(_ isEnabled: Bool) {
        var updated = backgroundRefreshSettings
        updated.isEnabled = isEnabled
        if saveBackgroundRefreshSettings(updated) {
            reconcileRefreshAgentRegistration(settings: updated)
        }
    }

    func setBackgroundRefreshInterval(_ minutes: Int) {
        var updated = backgroundRefreshSettings
        updated.setIntervalMinutes(minutes)
        if saveBackgroundRefreshSettings(updated) {
            reconcileRefreshAgentRegistration(settings: updated)
        }
    }

    @discardableResult
    private func saveBackgroundRefreshSettings(_ updated: BackgroundRefreshSettings) -> Bool {
        do {
            try backgroundRefreshSettingsStore.save(updated)
            backgroundRefreshSettings = updated
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func reconcileRefreshAgentRegistration(settings: BackgroundRefreshSettings) {
        let service = SMAppService.loginItem(identifier: ContextPanelLocations.refreshAgentBundleID)
        do {
            if settings.isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            errorMessage = "Background refresh could not be updated: \(error.localizedDescription)"
        }
    }

    func setAccount(_ accountID: String, isEnabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].isEnabled = isEnabled
        saveAccounts()
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

    func setResetPrimerAccount(_ accountID: String, provider: Provider, isEnabled: Bool) {
        var updated = resetPrimerSettings
        updated.setAccount(accountID, provider: provider, isEnabled: isEnabled)
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

    private func saveAccounts() {
        do {
            try store.save(AccountConfigurationDocument(updatedAt: Date(), accounts: accounts))
            var primerSettings = resetPrimerSettings
            primerSettings.syncAccounts(accounts)
            try resetPrimerSettingsStore.save(primerSettings)
            resetPrimerSettings = primerSettings
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func needsAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        guard account.isEnabled else { return false }
        if account.connectorKind == .claudeOAuthUsage || account.connectorKind == .geminiCodeAssist {
            return !hasImportedCredential(for: account)
        }
        guard let authPath = account.effectiveAuthPath else { return false }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return false }
        let expanded = NSString(string: authPath).expandingTildeInPath
        return !bookmarkStore.hasBookmark(for: expanded)
    }

    func hasSavedAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        if account.connectorKind == .claudeOAuthUsage || account.connectorKind == .geminiCodeAssist {
            return hasImportedCredential(for: account)
        }
        guard let authPath = account.effectiveAuthPath else { return false }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return false }
        let expanded = NSString(string: authPath).expandingTildeInPath
        return authorizedPaths.contains(expanded)
    }

    func hasLegacyAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        guard account.isEnabled else { return false }
        guard let authPath = account.effectiveAuthPath else { return false }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return false }
        let expanded = NSString(string: authPath).expandingTildeInPath
        return legacyAuthPaths.contains(expanded)
    }

    func canAuthorizeAuthFile(for account: LocalProviderAccountConfiguration) -> Bool {
        account.connectorKind.requiresSecurityScopedAuthFile
    }

    func authorizationSavedText(for account: LocalProviderAccountConfiguration) -> String {
        account.connectorKind == .claudeOAuthUsage || account.connectorKind == .geminiCodeAssist ? "Connected" : "File saved"
    }

    func refreshSummary(for account: LocalProviderAccountConfiguration, storedSnapshot: StoredUsageSnapshot?) -> SettingsAccountRefreshSummary? {
        guard account.isEnabled else { return nil }
        guard !needsAuthorization(account) else { return nil }
        guard !hasLegacyAuthorization(account) else { return nil }

        guard let storedSnapshot else {
            return SettingsAccountRefreshSummary(text: "No refresh yet", status: .unknown)
        }
        let reports = storedSnapshot.reports.filter { account.matchesProviderReport($0) }
        guard !reports.isEmpty else {
            return SettingsAccountRefreshSummary(text: "No refresh report yet", status: .unknown)
        }

        let refreshSubject = refreshSubjectText(for: account)
        if reports.hasReconnectBlockingFailure {
            return SettingsAccountRefreshSummary(text: "Last \(refreshSubject) failed; see Diagnostics", status: .failure)
        }
        if reports.contains(where: { $0.status == .stale }) {
            return SettingsAccountRefreshSummary(text: "Last \(refreshSubject) stale", status: .stale)
        }
        if reports.contains(where: { $0.status == .unknown }) {
            return SettingsAccountRefreshSummary(text: "Last \(refreshSubject) unknown", status: .unknown)
        }

        let successfulReports = reports.filter { report in
            report.status != .failure && report.status != .stale && report.status != .unknown
        }
        let count = successfulReports.count
        let accountText: String
        if account.connectorKind == .codexRateLimits, count > 1 {
            accountText = "\(count) OpenAI accounts"
        } else {
            accountText = successfulReports.first?.accountName ?? account.displayName
        }
        return SettingsAccountRefreshSummary(text: "Last \(refreshSubject) healthy: \(accountText)", status: .healthy)
    }

    private func refreshSubjectText(for account: LocalProviderAccountConfiguration) -> String {
        switch account.connectorKind {
        case .codexRateLimits:
            "OpenAI refresh"
        case .geminiCodeAssist:
            "Google refresh"
        case .claudeLocalStatus, .claudeOAuthUsage:
            "Claude refresh"
        }
    }

    func authorizeClaudeOAuth(for account: LocalProviderAccountConfiguration) {
        guard account.connectorKind == .claudeOAuthUsage else { return }
        do {
            let flow = try PendingClaudeOAuth(accountID: account.id)
            pendingClaudeOAuth = flow
            isClaudeOAuthCodeSheetPresented = true
            contextPanelLogger.info("Claude OAuth connect clicked for accountID=\(account.id, privacy: .public)")
            let opened = NSWorkspace.shared.open(flow.authorizationURL)
            contextPanelLogger.info("Claude OAuth authorization URL open result=\(opened, privacy: .public)")
            if !opened {
                errorMessage = "Claude authorization did not open automatically. Use the link in the Connect Claude sheet."
            }
        } catch {
            contextPanelLogger.error("Claude OAuth connect failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func cancelClaudeOAuth() {
        pendingClaudeOAuth = nil
        isCompletingClaudeOAuth = false
    }

    func authorizeGoogleAntigravityOAuth(for account: LocalProviderAccountConfiguration) {
        guard account.connectorKind == .geminiCodeAssist else { return }
        do {
            let flow = try PendingGoogleAntigravityOAuth(accountID: account.id)
            pendingGoogleOAuth = flow
            isGoogleOAuthCodeSheetPresented = true
            startGoogleOAuthCallbackListener(for: flow)
            contextPanelLogger.info("Google Antigravity OAuth connect clicked for accountID=\(account.id, privacy: .public)")
        } catch {
            contextPanelLogger.error("Google Antigravity OAuth connect failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func cancelGoogleAntigravityOAuth() {
        stopGoogleOAuthCallbackListener()
        pendingGoogleOAuth = nil
        isCompletingGoogleOAuth = false
    }

    func completeClaudeOAuth(code: String, onConnected: @escaping () -> Void) {
        guard let flow = pendingClaudeOAuth else { return }
        let authorizationCode = ClaudeOAuthFlow.normalizedAuthorizationCode(from: code)
        guard !authorizationCode.code.isEmpty else { return }
        isCompletingClaudeOAuth = true
        contextPanelLogger.info("Claude OAuth code exchange started")
        Task { [weak self] in
            do {
                let credentials = try await Self.exchangeClaudeOAuthCode(authorizationCode: authorizationCode, flow: flow)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try self?.credentialStore.save(try encoder.encode(credentials), accountID: flow.accountID)
                await MainActor.run {
                    contextPanelLogger.info("Claude OAuth code exchange succeeded")
                    self?.pendingClaudeOAuth = nil
                    self?.isCompletingClaudeOAuth = false
                    self?.isClaudeOAuthCodeSheetPresented = false
                    self?.errorMessage = nil
                    self?.load()
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    contextPanelLogger.error("Claude OAuth code exchange failed: \(error.localizedDescription, privacy: .public)")
                    self?.isCompletingClaudeOAuth = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func completeGoogleAntigravityOAuth(code: String, onConnected: @escaping () -> Void) {
        guard let flow = pendingGoogleOAuth else { return }
        let authorizationCode = GoogleAntigravityOAuthFlow.normalizedAuthorizationCode(from: code)
        guard !authorizationCode.code.isEmpty else { return }
        if let state = authorizationCode.state, state != flow.state {
            errorMessage = "Google authorization state did not match this connection attempt. Start Google sign-in again."
            return
        }
        completeGoogleAntigravityOAuth(authorizationCode: authorizationCode, flow: flow, onConnected: onConnected)
    }

    private func completeGoogleAntigravityOAuth(
        authorizationCode: GoogleAntigravityAuthorizationCode,
        flow: PendingGoogleAntigravityOAuth,
        onConnected: @escaping () -> Void
    ) {
        guard !isCompletingGoogleOAuth else { return }
        isCompletingGoogleOAuth = true
        contextPanelLogger.info("Google Antigravity OAuth code exchange started")
        Task { [weak self] in
            do {
                let credentials = try await Self.exchangeGoogleAntigravityOAuthCode(
                    authorizationCode: authorizationCode,
                    flow: flow
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try self?.credentialStore.save(try encoder.encode(credentials), accountID: flow.accountID)
                await MainActor.run {
                    contextPanelLogger.info("Google Antigravity OAuth code exchange succeeded")
                    self?.stopGoogleOAuthCallbackListener()
                    self?.pendingGoogleOAuth = nil
                    self?.isCompletingGoogleOAuth = false
                    self?.isGoogleOAuthCodeSheetPresented = false
                    self?.errorMessage = nil
                    self?.load()
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    contextPanelLogger.error("Google Antigravity OAuth code exchange failed: \(error.localizedDescription, privacy: .public)")
                    self?.isCompletingGoogleOAuth = false
                    self?.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func startGoogleOAuthCallbackListener(for flow: PendingGoogleAntigravityOAuth) {
        stopGoogleOAuthCallbackListener()
        do {
            let server = try GoogleOAuthCallbackServer(
                redirectURI: flow.redirectURI,
                expectedState: flow.state,
                onReady: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.pendingGoogleOAuth?.state == flow.state else { return }
                        self.isGoogleOAuthCallbackListening = true
                        self.openGoogleAuthorizationURL(flow.authorizationURL)
                    }
                },
                onFailure: { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.pendingGoogleOAuth?.state == flow.state else { return }
                        self.isGoogleOAuthCallbackListening = false
                        self.errorMessage = "Automatic Google callback could not start. Use the link in this sheet, then paste the redirected URL if Safari cannot return to Context Panel."
                        contextPanelLogger.error("Google OAuth callback listener failed: \(message, privacy: .public)")
                    }
                }
            ) { [weak self] authorizationCode in
                Task { @MainActor [weak self] in
                    guard let self, let activeFlow = self.pendingGoogleOAuth else { return }
                    guard activeFlow.state == flow.state else { return }
                    self.completeGoogleAntigravityOAuth(
                        authorizationCode: authorizationCode,
                        flow: activeFlow,
                        onConnected: { Task { await self.refreshAfterGoogleOAuthCallback() } }
                    )
                }
            }
            googleOAuthCallbackServer = server
            isGoogleOAuthCallbackListening = false
            errorMessage = nil
            server.start()
        } catch {
            isGoogleOAuthCallbackListening = false
            errorMessage = "Automatic Google callback could not start. Use the link in this sheet, then paste the redirected URL if Safari cannot return to Context Panel."
            contextPanelLogger.error("Google OAuth callback listener failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openGoogleAuthorizationURL(_ url: URL) {
        let opened = NSWorkspace.shared.open(url)
        contextPanelLogger.info("Google Antigravity OAuth authorization URL open result=\(opened, privacy: .public)")
        if !opened {
            errorMessage = "Google authorization did not open automatically. Use the link in the Connect Google sheet."
        }
    }

    private func stopGoogleOAuthCallbackListener() {
        googleOAuthCallbackServer?.cancel()
        googleOAuthCallbackServer = nil
        isGoogleOAuthCallbackListening = false
    }

    private func refreshAfterGoogleOAuthCallback() async {
        _ = try? await SnapshotRefreshRunner.appDefault().refresh()
        load()
    }

    func authorizeAuthFile(for account: LocalProviderAccountConfiguration, onVerified: @escaping () -> Void = {}) {
        guard let authPath = account.effectiveAuthPath else { return }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return }
        let expanded = NSString(string: authPath).expandingTildeInPath
        let fileURL = URL(fileURLWithPath: expanded)

        let panel = NSOpenPanel()
        panel.message = "Select \(fileURL.lastPathComponent) for \(account.displayName)."
        panel.prompt = "Select File"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.lastPathComponent
        if #available(macOS 11.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard url.lastPathComponent == fileURL.lastPathComponent else {
                errorMessage = "Select \(fileURL.lastPathComponent) for \(account.displayName)."
                return
            }
            do {
                try bookmarkStore.createAndStoreBookmark(for: url, path: expanded)
                guard bookmarkStore.canReadBookmark(for: expanded) else {
                    errorMessage = "File access could not be verified for \(account.displayName)."
                    missingAuthPaths.insert(expanded)
                    authorizedPaths.remove(expanded)
                    return
                }
                try credentialStore.save(try bookmarkStore.readData(for: expanded) ?? Data(), accountID: account.id)
                authorizedPaths.insert(expanded)
                missingAuthPaths.remove(expanded)
                legacyAuthPaths.remove(expanded)
                recentlyVerifiedAuthPaths.insert(expanded)
                errorMessage = nil
                onVerified()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func detailText(for account: LocalProviderAccountConfiguration) -> String {
        let path = account.effectiveAuthPath ?? detailSourceLabel(for: account)
        return "\(setupInstruction(for: account)) · \(ConnectorRedactor.redactedPath(path))"
    }

    private func detailSourceLabel(for account: LocalProviderAccountConfiguration) -> String {
        switch account.connectorKind {
        case .geminiCodeAssist:
            return "Google OAuth"
        case .claudeOAuthUsage:
            return "Claude OAuth"
        default:
            return account.connectorKind.rawValue
        }
    }

    private func setupInstruction(for account: LocalProviderAccountConfiguration) -> String {
        switch account.connectorKind {
        case .codexRateLimits:
            if account.displayName.localizedCaseInsensitiveContains("code") {
                return "Select auth_accounts.json. Every Code accounts are read from this file"
            }
            if account.displayName.localizedCaseInsensitiveContains("codex") {
                return "Select auth.json for Codex users"
            }
            return "Select the OpenAI CLI auth JSON file"
        case .geminiCodeAssist:
            return "Connect Google to read Antigravity model capacity"
        case .claudeLocalStatus:
            return "Claude reads Context Panel's statusline cache; no auth file selection is needed"
        case .claudeOAuthUsage:
            return "Connect Claude with OAuth for automatic background refresh"
        }
    }

    private func hasImportedCredential(for account: LocalProviderAccountConfiguration) -> Bool {
        (try? credentialStore.load(accountID: account.id)) != nil
    }

    private static func exchangeClaudeOAuthCode(
        authorizationCode: ClaudeOAuthAuthorizationCode,
        flow: PendingClaudeOAuth
    ) async throws -> ClaudeOAuthCredentials {
        let body = try ClaudeOAuthFlow.authorizationCodeTokenRequestBody(
            code: authorizationCode,
            codeVerifier: flow.pkce.verifier,
            state: flow.state,
            redirectURI: flow.redirectURI
        )
        var request = URLRequest(url: ClaudeOAuthMetadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.nonHTTPResponse("Claude OAuth token exchange returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            let redactedBody = ConnectorRedactor.redact(rawBody)
            throw ConnectorError.invalidAuth("Claude OAuth token exchange returned HTTP \(http.statusCode): \(redactedBody)")
        }
        let token = try JSONDecoder().decode(ClaudeOAuthTokenResponse.self, from: data)
        return ClaudeOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: token.scopes
        )
    }

    private static func exchangeGoogleAntigravityOAuthCode(
        authorizationCode: GoogleAntigravityAuthorizationCode,
        flow: PendingGoogleAntigravityOAuth
    ) async throws -> GoogleAntigravityOAuthCredentials {
        let body = try GoogleAntigravityOAuthFlow.authorizationCodeTokenRequestBody(
            code: authorizationCode,
            codeVerifier: flow.pkce.verifier,
            redirectURI: flow.redirectURI
        )
        var request = URLRequest(url: GoogleAntigravityOAuthMetadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.nonHTTPResponse("Google Antigravity OAuth token exchange returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let rawBody = String(data: data, encoding: .utf8) ?? ""
            let redactedBody = ConnectorRedactor.redact(rawBody)
            throw ConnectorError.invalidAuth("Google Antigravity OAuth token exchange returned HTTP \(http.statusCode): \(redactedBody)")
        }
        let token = try JSONDecoder().decode(GoogleAntigravityOAuthTokenResponse.self, from: data)
        return GoogleAntigravityOAuthCredentials(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) },
            scopes: token.scopes
        )
    }
}

private struct PendingClaudeOAuth {
    let accountID: String
    let pkce: OAuthPKCEChallenge
    let state: String
    let redirectURI: String
    let authorizationURL: URL

    init(accountID: String) throws {
        self.accountID = accountID
        pkce = try OAuthPKCE.makeChallenge()
        state = try OAuthPKCE.makeChallenge(byteCount: 24).verifier
        redirectURI = ClaudeOAuthFlow.manualRedirectURI
        authorizationURL = try ClaudeOAuthFlow.authorizationURL(codeChallenge: pkce.challenge, state: state, redirectURI: redirectURI)
    }
}

private struct PendingGoogleAntigravityOAuth {
    let accountID: String
    let pkce: OAuthPKCEChallenge
    let state: String
    let redirectURI: String
    let authorizationURL: URL

    init(accountID: String) throws {
        self.accountID = accountID
        pkce = try OAuthPKCE.makeChallenge()
        state = try OAuthPKCE.makeChallenge(byteCount: 24).verifier
        redirectURI = GoogleAntigravityOAuthFlow.manualRedirectURI
        authorizationURL = try GoogleAntigravityOAuthFlow.authorizationURL(
            codeChallenge: pkce.challenge,
            state: state,
            redirectURI: redirectURI
        )
    }
}

private final class GoogleOAuthCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let expectedState: String
    private let onReady: @Sendable () -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onCode: @Sendable (GoogleAntigravityAuthorizationCode) -> Void

    init(
        redirectURI: String,
        expectedState: String,
        onReady: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable (String) -> Void,
        onCode: @escaping @Sendable (GoogleAntigravityAuthorizationCode) -> Void
    ) throws {
        guard
            let url = URL(string: redirectURI),
            url.host == "localhost" || url.host == "127.0.0.1",
            let port = url.port,
            let nwPort = NWEndpoint.Port(rawValue: UInt16(port))
        else {
            throw ConnectorError.invalidAuth("Google OAuth callback URL is not a supported localhost URL.")
        }

        let parameters = NWParameters.tcp
        listener = try NWListener(using: parameters, on: nwPort)
        self.expectedState = expectedState
        self.onReady = onReady
        self.onFailure = onFailure
        self.onCode = onCode
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady()
            case .failed(let error), .waiting(let error):
                self.onFailure(error.localizedDescription)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .main)
    }

    func cancel() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let authorizationCode = Self.authorizationCode(from: request)
            let isExpectedCallback = authorizationCode?.state == expectedState
            let response = Self.httpResponse(success: isExpectedCallback)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let authorizationCode, isExpectedCallback {
                onCode(authorizationCode)
            }
        }
    }

    private static func authorizationCode(from request: String) -> GoogleAntigravityAuthorizationCode? {
        guard let requestLine = request.split(separator: "\n", maxSplits: 1).first else { return nil }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2, pieces[0] == "GET" else { return nil }
        let path = String(pieces[1])
        guard let url = URL(string: "http://localhost\(path)") else { return nil }
        guard url.path == "/oauth-callback" else { return nil }
        let authorizationCode = GoogleAntigravityOAuthFlow.normalizedAuthorizationCode(from: url.absoluteString)
        return authorizationCode.code.isEmpty ? nil : authorizationCode
    }

    private static func httpResponse(success: Bool) -> Data {
        let title = success ? "Context Panel received the Google callback" : "Context Panel could not read the Google callback"
        let body = """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font: -apple-system-body; margin: 32px; color: #1d1d1f;">
        <h1>\(title)</h1><p>You can close this browser tab and return to Context Panel.</p>
        </body></html>
        """
        let status = success ? "200 OK" : "400 Bad Request"
        let headers = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        return Data((headers + body).utf8)
    }
}

private extension AccountConnectorKind {
    var requiresSecurityScopedAuthFile: Bool {
        switch self {
        case .codexRateLimits:
            return true
        case .geminiCodeAssist, .claudeLocalStatus, .claudeOAuthUsage:
            return false
        }
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
                    Text(preference.window.settingsDisplayName)
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
                if model.shouldShowReconnectNavigation {
                    Label(model.attentionNavigationTitle, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CPTheme.statusColor(.failure))
                        .tag(AppNavigationSelection.reconnect)
                }
            }
            Section("Providers") {
                ForEach(Provider.allCases) { provider in
                    let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                    if !summaries.isEmpty {
                        ProviderSidebarRow(provider: provider, limitCount: summaries.count)
                            .tag(AppNavigationSelection.provider(provider))
                        ForEach(summaries.sortedForSidebar) { summary in
                            SidebarRateLimitRow(summary: summary)
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

            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(12)
        }
    }
}

struct ProviderSidebarRow: View {
    let provider: Provider
    let limitCount: Int

    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: provider)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(limitCount)")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

struct SidebarRateLimitRow: View {
    let summary: MainLimitSummary

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(status: summary.status, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.previewWindowLine)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(summary.sidebarDetailText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(summary.compactUsageText)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private extension Array where Element == MainLimitSummary {
    var sortedForSidebar: [MainLimitSummary] {
        sorted(by: { lhs, rhs in
            let lhsWindowRank = lhs.window.sortRankForSidebar
            let rhsWindowRank = rhs.window.sortRankForSidebar
            if lhsWindowRank != rhsWindowRank { return lhsWindowRank < rhsWindowRank }
            if lhs.previewWindowLine != rhs.previewWindowLine { return lhs.previewWindowLine < rhs.previewWindowLine }
            return lhs.id < rhs.id
        })
    }
}

private extension MainLimitWindow {
    var sortRankForSidebar: Int {
        switch self {
        case .fiveHour:
            0
        case .weekly:
            1
        case .daily:
            2
        case .availability:
            3
        }
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
        case .reconnect:
            ReconnectDashboard(appModel: model, snapshot: snapshot)
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
                PromptCacheOverviewCard(summary: model.promptCacheSummary)
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

struct ReconnectDashboard: View {
    @ObservedObject var appModel: ContextPanelAppModel
    let snapshot: UsageSnapshot
    @StateObject private var settingsModel = SettingsPaneModel()

    private var accountsNeedingAction: [LocalProviderAccountConfiguration] {
        settingsModel.accounts.filter { account in
            account.isEnabled && (
                settingsModel.needsAuthorization(account)
                    || settingsModel.hasLegacyAuthorization(account)
                    || appModel.reportNeedsAttention(account)
            )
        }
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 18) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(CPTheme.statusColor(.failure))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(appModel.attentionNavigationTitle)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        Text(appModel.reconnectSummaryText)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(CPTheme.secondaryText)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 12)
                    Button {
                        Task { await appModel.refreshLocalConnectors() }
                    } label: {
                        Label(appModel.isRefreshing ? "Refreshing" : "Refresh now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.isRefreshing)
                }
                .padding(22)
                .background(CPTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(CPTheme.stroke(cornerRadius: 12))

                if !appModel.providerReportsNeedingAttention.isEmpty {
                    DetailCard(title: "Refresh Status") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(appModel.diagnosticProviderReports) { report in
                                DiagnosticReportRow(report: report)
                            }
                        }
                    }
                }

                DetailCard(title: "Accounts") {
                    VStack(alignment: .leading, spacing: 10) {
                        if accountsNeedingAction.isEmpty {
                            Text("No account action is available. Try Refresh now; if the widget stays stale, reconnect the affected provider from Settings.")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(CPTheme.secondaryText)
                        } else {
                            ForEach(accountsNeedingAction) { account in
                                ReconnectAccountRow(
                                    account: account,
                                    settingsModel: settingsModel,
                                    attentionReport: appModel.providerReportNeedingAttention(for: account),
                                    refreshSummary: settingsModel.refreshSummary(for: account, storedSnapshot: appModel.storedSnapshot),
                                    onRefresh: {
                                        Task {
                                            await appModel.refreshLocalConnectors()
                                            settingsModel.load()
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
        .sheet(isPresented: $settingsModel.isClaudeOAuthCodeSheetPresented) {
            ClaudeOAuthCodeSheet(model: settingsModel) {
                Task {
                    await appModel.refreshLocalConnectors()
                    settingsModel.load()
                }
            }
        }
        .sheet(isPresented: $settingsModel.isGoogleOAuthCodeSheetPresented) {
            GoogleAntigravityOAuthCodeSheet(model: settingsModel) {
                Task {
                    await appModel.refreshLocalConnectors()
                    settingsModel.load()
                }
            }
        }
        .onAppear { settingsModel.load() }
    }
}

struct PromptCacheOverviewCard: View {
    let summary: PromptCacheSummary

    private var currentRate: Double? {
        summary.latestHitRate
    }

    private var averageRate: Double? {
        summary.tokenWeightedHitRate
    }

    var body: some View {
        if summary.isAvailable {
            HStack(alignment: .center, spacing: 18) {
                CapacityDial(
                    value: currentRate ?? 0,
                    status: summary.comparisonStatus,
                    label: currentRate.map(Self.percentText) ?? "--",
                    sublabel: "now",
                    size: 86,
                    thickness: 6
                )
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        StatusMark(status: summary.comparisonStatus, size: 8)
                        Text("Prompt Cache")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        if summary.hasPossibleCacheBreak {
                            TagLabel("Break?")
                        }
                    }
                    Text(summary.hasPossibleCacheBreak ? "Cached input dropped sharply on the latest window." : "Latest hit rate compared with the token-weighted recent average.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(summary.hasPossibleCacheBreak ? CPTheme.statusColor(.close) : CPTheme.secondaryText)
                        .lineLimit(2)
                    HStack(spacing: 14) {
                        PromptCacheMetric(label: "Average", value: averageRate.map(Self.percentText) ?? "--")
                        PromptCacheMetric(label: "Input", value: Self.compactNumber(summary.totalInputTokens))
                        PromptCacheMetric(label: "Cached", value: Self.compactNumber(summary.totalCachedInputTokens))
                        PromptCacheMetric(label: "Uncached", value: summary.totalUncachedInputTokens.map(Self.compactNumber) ?? "--")
                        if let latest = summary.latest {
                            PromptCacheMetric(label: latest.windowLabel, value: relativeAge(latest.observedAt))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(CPTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(CPTheme.stroke(cornerRadius: 8))
        }
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.1fK", Double(value) / 1_000)
        default:
            return "\(value)"
        }
    }
}

struct PromptCacheMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(CPTheme.primaryText)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(CPTheme.tertiaryText)
                .textCase(.uppercase)
                .lineLimit(1)
        }
    }
}

private struct DiagnosticReportRow: View {
    let report: DiagnosticProviderReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusMark(status: report.status, size: 8)
                Text(report.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                Spacer()
                Text(report.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CPTheme.statusColor(report.status))
            }
            if let detail = report.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ReconnectAccountRow: View {
    let account: LocalProviderAccountConfiguration
    @ObservedObject var settingsModel: SettingsPaneModel
    let attentionReport: StoredProviderReport?
    let refreshSummary: SettingsAccountRefreshSummary?
    let onRefresh: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderBadge(provider: account.provider)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                Text(statusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(2)
                if let refreshSummary {
                    Text(refreshSummary.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPTheme.statusColor(refreshSummary.status))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            actionButton
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var actionButton: some View {
        if attentionReport?.hasProviderConfigurationFailure == true {
            Button("Refresh") { onRefresh() }
                .buttonStyle(.bordered)
        } else if settingsModel.canAuthorizeAuthFile(for: account), shouldOfferAuthFileReconnect {
            Button("Reconnect") {
                settingsModel.authorizeAuthFile(for: account, onVerified: onRefresh)
            }
            .buttonStyle(.borderedProminent)
        } else if account.connectorKind == .claudeOAuthUsage {
            Button("Reconnect") {
                settingsModel.authorizeClaudeOAuth(for: account)
            }
            .buttonStyle(.borderedProminent)
        } else if account.connectorKind == .geminiCodeAssist {
            Button("Reconnect") {
                settingsModel.authorizeGoogleAntigravityOAuth(for: account)
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Refresh") { onRefresh() }
                .buttonStyle(.bordered)
        }
    }

    private var shouldOfferAuthFileReconnect: Bool {
        settingsModel.needsAuthorization(account)
            || settingsModel.hasLegacyAuthorization(account)
            || (account.connectorKind == .codexRateLimits && refreshSummary?.status == .failure)
    }

    private var statusText: String {
        if settingsModel.needsAuthorization(account) { return "Account access is missing." }
        if settingsModel.hasLegacyAuthorization(account) { return "File access needs to be refreshed." }
        if account.connectorKind == .codexRateLimits, refreshSummary?.status == .failure {
            return "Sign in again from Every Code or Codex, then reselect the auth file."
        }
        if account.connectorKind == .claudeOAuthUsage { return "Reconnect Claude if refresh keeps failing." }
        if account.connectorKind == .geminiCodeAssist {
            if attentionReport?.hasProviderConfigurationFailure == true {
                return "Google setup is missing from this build. Check provider configuration, then refresh."
            }
            return "Reconnect Google if Antigravity model availability refresh keeps failing."
        }
        return settingsModel.detailText(for: account)
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
                if provider == .openAI {
                    OpenAIAccountLimitsSection(summaries: summaries)
                } else {
                    ProviderAccountLimitsSection(summaries: summaries)
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

struct ProviderAccountLimitsSection: View {
    let summaries: [MainLimitSummary]

    var body: some View {
        if !summaries.isEmpty {
            DetailCard(title: "Account Limits") {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(summaries.sortedForSidebar) { summary in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(summary.previewWindowName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(CPTheme.primaryText)
                                Spacer()
                                Text(summary.previewRemainingHeadline)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(CPTheme.secondaryText)
                            }
                            ForEach(summary.previewLimits) { limit in
                                MainLimitAccountRow(limit: limit)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct OpenAIAccountLimitsSection: View {
    let summaries: [MainLimitSummary]

    private var accounts: [OpenAIAccountLimitSummary] {
        OpenAIAccountLimitSummary.accounts(from: summaries)
    }

    private var recommendation: AccountResetRecommendation? {
        UsageSnapshot(generatedAt: Date(), limits: summaries.flatMap(\.limits))
            .nextAccountToUse(provider: .openAI, window: .weekly)
    }

    var body: some View {
        if !accounts.isEmpty {
            DetailCard(title: "OpenAI Accounts") {
                VStack(alignment: .leading, spacing: 10) {
                    if let recommendation {
                        OpenAIRecommendedAccountRow(recommendation: recommendation)
                    }
                    ForEach(accounts) { account in
                        OpenAIAccountLimitRow(account: account)
                    }
                }
            }
        }
    }
}

private struct OpenAIRecommendedAccountRow: View {
    let recommendation: AccountResetRecommendation

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            StatusMark(status: recommendation.limit.status, size: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text("Use this account")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.secondaryText)
                Text(recommendation.accountName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            Text(recommendation.resetsAt.widgetRelativeText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(CPTheme.primaryText)
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OpenAIAccountLimitRow: View {
    let account: OpenAIAccountLimitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CPTheme.primaryText)
                        .lineLimit(1)
                    if let planText = account.planText {
                        Text(planText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CPTheme.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                StatusMark(status: account.status, size: 8)
            }
            HStack(spacing: 8) {
                OpenAIAccountWindowPill(title: "Weekly", limit: account.limit(for: .weekly))
                OpenAIAccountWindowPill(title: "5h", limit: account.limit(for: .fiveHour))
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OpenAIAccountWindowPill: View {
    let title: String
    let limit: UsageLimit?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CPTheme.secondaryText)
            Text(limit?.previewUsageText ?? "unknown")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(CPTheme.primaryText)
            CapacityBar(value: limit?.usageRatio ?? 0, status: limit?.status ?? .unknown, height: 4)
            Text(limit?.resetText ?? "unknown reset")
                .font(.system(size: 10))
                .foregroundStyle(CPTheme.tertiaryText)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OpenAIAccountLimitSummary: Identifiable {
    let accountID: String
    let accountName: String
    let limits: [UsageLimit]

    var id: String { accountID }

    var displayName: String {
        accountNameParts.first ?? accountName
    }

    var planText: String? {
        if accountNameParts.count > 1 {
            return accountNameParts.dropFirst().joined(separator: " · ")
        }
        return limits.lazy.compactMap(\.planText).first
    }

    var status: UsageStatus {
        limits.map(\.status).contextPanelWorstStatus
    }

    func limit(for window: MainLimitWindow) -> UsageLimit? {
        limits.first { $0.mainLimitWindow == window }
    }

    private var accountNameParts: [String] {
        accountName
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func accounts(from summaries: [MainLimitSummary]) -> [OpenAIAccountLimitSummary] {
        let limits = summaries
            .filter { $0.provider == .openAI }
            .flatMap(\.limits)
            .filter { $0.isMainLimit }
        return Dictionary(grouping: limits, by: \.accountID)
            .map { accountID, accountLimits in
                OpenAIAccountLimitSummary(
                    accountID: accountID,
                    accountName: accountLimits.first?.accountName ?? "OpenAI Account",
                    limits: accountLimits.sortedForOpenAIAccount
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
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
                Text("Fast mode works 50% faster, but uses limits about twice as quickly.")
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.tertiaryText)
                HStack(spacing: 8) {
                    TagLabel("\(snapshot.mainLimitSummaries.count) main windows")
                    TagLabel("Accounts pooled")
                    if model.storeStatus != .healthy {
                        TagLabel(model.storeStatus.previewStatusText.capitalized)
                    }
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
                    if model.storeStatus != .healthy {
                        TagLabel(model.storeStatus.previewStatusText.capitalized)
                    }
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
            .map { "\($0.previewWindowName.lowercased()) \($0.previewRemainingHeadline.lowercased())" }
            .joined(separator: " · ")
    }
}

struct SetupStatusStrip: View {
    @ObservedObject var model: ContextPanelAppModel

    var body: some View {
        HStack(spacing: 12) {
            SetupStatusItem(
                title: "Snapshot cache",
                value: model.storeStatus == .healthy ? "Ready" : model.storeStatus.previewStatusText.capitalized,
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
                Text(model.primaryErrorStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.statusColor(.failure))
                    .lineLimit(1)
                    .help(errorMessage)
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

    private var displayLimit: UsageLimit {
        limit.previewDisplayLimit
    }

    var body: some View {
        HStack(spacing: 10) {
            ProviderBadge(provider: displayLimit.provider, compact: true)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayLimit.additionalLimitTitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
                Text(displayLimit.additionalLimitSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(displayLimit.previewUsageText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPTheme.secondaryText)
                Text(displayLimit.resetText)
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
                        Text(summary.previewWindowName)
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
                    DetailRow(label: "Window", value: summary.previewWindowName)
                    DetailRow(label: "Accounts", value: "\(summary.accountCount)")
                    DetailRow(label: "Used", value: summary.detailUsedValue)
                    DetailRow(label: "Limit", value: summary.detailLimitValue)
                    DetailRow(label: "Remaining", value: summary.detailRemainingText)
                    DetailRow(label: "Status", value: summary.status.rawValue)
                    DetailRow(label: "Updated", value: summary.lastUpdatedAt.map(model.relativeTime) ?? "unknown")
                }

                DetailCard(title: "Accounts") {
                    ForEach(summary.previewLimits) { limit in
                        MainLimitAccountRow(limit: limit)
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
            let standardBurnRate = model.observedBurnRates[summary.id]?.unitsPerHour
                ?? settings.defaultStandardBurnRateUnitsPerHour
            return FastModeCapacityForecast(
                limitID: summary.id,
                accountName: limit.accountName,
                providerLimits: summary.liveLimits,
                now: Date(),
                standardBurnRate: standardBurnRate.map {
                    BurnRate(mode: .standard, unitsPerHour: $0)
                },
                fastBurnRate: standardBurnRate.map {
                    BurnRate(mode: .fast, unitsPerHour: $0 * settings.fastModeMultiplier)
                },
                reserveUnits: settings.reserveUnits,
                minimumSafeHours: settings.minimumSafeHours
            ).copy
        }
        return limit.note ?? "Fast-mode forecast currently applies to OpenAI main windows."
    }
}

struct MainLimitAccountRow: View {
    let limit: UsageLimit

    var body: some View {
        HStack(spacing: 12) {
            StatusMark(status: limit.status, size: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(limit.mainLimitAccountTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
                Text(limit.mainLimitAccountSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 3) {
                Text(usageText)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPTheme.primaryText)
                Text("\(limit.resetText) · \(limit.status.rawValue)")
                    .font(.system(size: 10))
                    .foregroundStyle(CPTheme.tertiaryText)
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var usageText: String {
        limit.previewRemainingHeadline
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
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var navigationRequest: AppNavigationSelection?

    private let refreshService: SnapshotRefreshService
    private let refreshRunner: SnapshotRefreshRunner
    private let forecastSettingsStore = FastModeForecastSettingsStore(
        settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    var currentSnapshot: UsageSnapshot {
        storedSnapshot?.snapshot ?? UsageSnapshot(generatedAt: Date(), limits: [])
    }

    var fastModeForecast: FastModeCapacityPortfolioForecast {
        currentSnapshot.mainLimitSummaries.openAIFastModeCapacityForecast(
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings
        )
    }

    var observedBurnRates: [String: ObservedBurnRate] {
        MainLimitBurnRateEstimator.observedBurnRates(
            current: currentSnapshot,
            history: refreshService.loadHistory(),
            now: Date()
        )
    }

    var promptCacheSummary: PromptCacheSummary {
        PromptCacheSummary(observations: storedSnapshot?.promptCacheObservations ?? [], now: Date())
    }

    var lastRefreshText: String {
        lastRefreshAt.map(relativeTime) ?? "not yet"
    }

    var primaryErrorStatusText: String {
        switch storeStatus {
        case .failure:
            "Reconnect account"
        case .stale:
            hasProviderReconnectIssue ? "Reconnect account" : "Refresh needed"
        case .unknown:
            "Awaiting data; see Settings"
        default:
            "Needs attention; see Settings"
        }
    }

    var shouldShowReconnectNavigation: Bool {
        storeStatus == .failure || storeStatus == .stale || !providerReportsNeedingAttention.isEmpty
    }

    var attentionNavigationTitle: String {
        if let report = primaryProviderReportNeedingAttention, report.status == .failure {
            if report.hasProviderConfigurationFailure {
                return "Fix \(report.provider.displayName) setup"
            }
            return "Reconnect \(report.provider.displayName)"
        }
        if storeStatus == .failure || hasProviderReconnectIssue {
            return "Reconnect account"
        }
        return "Refresh needed"
    }

    var reconnectSummaryText: String {
        if let report = primaryProviderReportNeedingAttention {
            let target = "\(report.provider.displayName) · \(report.accountName)"
            if report.hasProviderConfigurationFailure {
                return "\(target) needs provider setup. Check the app configuration, then refresh."
            }
            if let errorMessage = report.errorMessage, !errorMessage.isEmpty {
                return "\(target) needs attention: \(errorMessage)"
            }
            if report.status == .failure {
                return "\(target) needs attention. Reconnect this account, then refresh."
            }
            return "\(target) needs attention. Refresh now, then check the provider status if it persists."
        }
        if storeStatus == .stale {
            if hasProviderReconnectIssue {
                return "The widget is showing old percentages. Reconnect the affected account, then refresh."
            }
            return "The widget is showing old percentages. Refresh Context Panel to update the snapshot."
        }
        if storeStatus == .failure {
            return "The latest refresh failed. Reconnect the affected account, then refresh."
        }
        if !providerReportsNeedingAttention.isEmpty {
            return "One or more provider refreshes need attention. Reconnect the affected account, then refresh."
        }
        return "Refresh is healthy right now."
    }

    var providerReportsNeedingAttention: [StoredProviderReport] {
        guard let reports = storedSnapshot?.reports else { return [] }
        return reports.reconnectBlockingFailures + reports.filter(\.needsNonFailureRefreshAttention)
    }

    private var primaryProviderReportNeedingAttention: StoredProviderReport? {
        providerReportsNeedingAttention.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status.attentionSortRank > rhs.status.attentionSortRank }
            if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
            return lhs.accountName < rhs.accountName
        }.first
    }

    var hasProviderReconnectIssue: Bool {
        storedSnapshot?.reports.hasReconnectBlockingFailure ?? false
    }

    func reportNeedsAttention(_ account: LocalProviderAccountConfiguration) -> Bool {
        providerReportNeedingAttention(for: account) != nil
    }

    func providerReportNeedingAttention(for account: LocalProviderAccountConfiguration) -> StoredProviderReport? {
        providerReportsNeedingAttention.first { account.matchesProviderReport($0) }
    }

    var lastSuccessfulProviderRefreshText: String? {
        guard let report = storedSnapshot?.reports
            .filter({ $0.status != .failure && $0.status != .unknown })
            .max(by: { $0.generatedAt < $1.generatedAt })
        else { return nil }
        return "\(report.provider.displayName) · \(report.accountName) · \(relativeTime(report.generatedAt))"
    }

    var diagnosticProviderReports: [DiagnosticProviderReport] {
        storedSnapshot?.reports
            .filter(\.needsRefreshAttention)
            .sorted { lhs, rhs in
                if lhs.status != rhs.status { return lhs.status.attentionSortRank > rhs.status.attentionSortRank }
                if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
                return lhs.accountName < rhs.accountName
            }
            .map { report in
                DiagnosticProviderReport(
                    id: "\(report.provider.rawValue)-\(report.accountID)-\(report.status.rawValue)",
                    title: "\(report.provider.displayName) · \(report.accountName)",
                    summary: "\(report.status.previewStatusText) · \(relativeTime(report.generatedAt))",
                    status: report.status,
                    detail: report.errorMessage
                )
            } ?? []
    }

    init() {
        refreshService = .appDefault()
        refreshRunner = SnapshotRefreshRunner(service: refreshService)
    }

    func loadSnapshot(reloadWidgetTimelines: Bool = true) {
        fastModeForecastSettings = forecastSettingsStore.load()
        let accounts = refreshService.loadConfiguredAccounts().document.accounts
        configuredAccounts = accounts
        let result = refreshService.loadCurrent(
            policy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.appMaximumAge),
            now: Date()
        )
        storedSnapshot = result.snapshot
        lastRefreshAt = result.snapshot?.savedAt
        storeStatus = result.status
        if result.status == .failure || result.errorMessage != nil {
            errorMessage = result.errorMessage
        } else {
            errorMessage = nil
        }
        historyCount = refreshService.loadHistory().count
        if reloadWidgetTimelines {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    func handleOpenURL(_ url: URL) {
        switch url.host?.lowercased() {
        case "reconnect":
            navigationRequest = .reconnect
        case "overview":
            navigationRequest = .overview
        default:
            navigationRequest = .overview
        }
    }

    func clearNavigationRequest() {
        navigationRequest = nil
    }

    func refreshLocalConnectors() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let decision = try await refreshRunner.refresh()
            if case .skippedAlreadyRunning = decision {
                loadSnapshot()
                storeStatus = .stale
                errorMessage = "Another refresh is still running. Try again in a moment."
                return
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

    func relativeTime(_ date: Date) -> String {
        let seconds = max(Int(Date().timeIntervalSince(date)), 0)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

}

struct DiagnosticProviderReport: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let status: UsageStatus
    let detail: String?
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
        case .limited, .failure, .stale:
            Color(red: 138 / 255, green: 74 / 255, blue: 74 / 255)
        case .unknown, .loading:
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
        return "\(tightestMainLimitSummary.provider.shortName) · \(tightestMainLimitSummary.previewWindowName) · \(tightestMainLimitSummary.accountText)"
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
    var previewLimits: [UsageLimit] {
        let displayLimitsByID = Dictionary(
            liveLimits.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return limits.map { displayLimitsByID[$0.id] ?? $0.previewDisplayLimit }
    }

    var previewWindowName: String {
        displayWindowName
    }

    var compactPreviewWindowName: String {
        compactDisplayWindowName
    }

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
        if window == .availability {
            return previewRemainingHeadline
        }
        if usageRatio != nil {
            return "\(Int(((usageRatio ?? 0) * 100).rounded()))% used"
        }
        guard let used, let limit else { return "unknown" }
        return "\(used)/\(limit) used"
    }

    var previewWindowLine: String {
        "\(previewWindowName) · \(accountText)"
    }

    var compactPreviewWindowLine: String {
        "\(compactPreviewWindowName) · \(accountText)"
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

    var detailUsedValue: String {
        guard let used else { return "unknown" }
        return unit == .percent ? "\(used)%" : "\(used)"
    }

    var detailLimitValue: String {
        guard let limit else { return "unknown" }
        return unit == .percent ? "\(limit)%" : "\(limit)"
    }

    var detailRemainingText: String {
        guard let remaining else { return "unknown" }
        return unit == .percent ? "\(remaining)%" : "\(remaining)"
    }
}

private extension MainLimitWindow {
    var settingsDisplayName: String {
        switch self {
        case .availability:
            "Google reset window"
        default:
            displayName
        }
    }
}

private extension String {
    var isModelCapacityDisplayLabel: Bool {
        localizedCaseInsensitiveCompare("Model capacity") == .orderedSame
            || localizedCaseInsensitiveCompare("Availability") == .orderedSame
    }
}

extension UsageLimit {
    var previewDisplayLimit: UsageLimit {
        googleAntigravityResetCarriedForward(at: Date()) ?? self
    }

    var planText: String? {
        guard let note else { return nil }
        let prefix = "plan:"
        guard note.lowercased().hasPrefix(prefix) else { return nil }
        let rawPlan = note.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPlan.isEmpty else { return nil }
        return rawPlan.capitalized
    }

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
            return "limit unknown"
        }
        if isModelCapacityLimit {
            return previewRemainingHeadline
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

    var sidebarUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "unknown"
        }
        if isModelCapacityLimit {
            return previewRemainingHeadline
        }
        if unit == .percent, let used {
            return "\(used)%"
        }
        guard let used, let limit else { return status == .failure ? "—" : "?" }
        return "\(used)/\(limit)"
    }

    var sidebarTitleText: String {
        if mainLimitWindow == .availability {
            return [modelLabel, "capacity"].compactMap { $0 }.joined(separator: " ")
        }
        if let mainLimitWindow {
            let title = [mainLimitWindow.shortName, modelLabel ?? displayLabel]
                .compactMap { value in
                    guard !value.isEmpty else { return nil }
                    return value
                }
                .deduplicated()
                .joined(separator: " ")
            return title.isEmpty ? mainLimitWindow.displayName : title
        }
        let title = [windowLabel, modelLabel, displayLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .deduplicated()
            .joined(separator: " · ")
        return title.isEmpty ? displayLabel : title
    }

    var isVisibleInSidebar: Bool {
        if provider == .anthropic, unit == .unknown, displayLabel == "Claude status" {
            return false
        }
        return true
    }

    var mainLimitAccountTitle: String {
        if mainLimitWindow == .availability {
            return modelLabel ?? displayLabel
        }
        if hasDistinctModelLabel {
            return [modelLabel, mainLimitWindow?.displayName]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .deduplicated()
                .joined(separator: " · ")
        }
        return accountName
    }

    var mainLimitAccountSubtitle: String {
        if mainLimitWindow == .availability {
            return [windowLabel, accountName]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .deduplicated()
                .joined(separator: " · ")
        }
        if hasDistinctModelLabel {
            return [accountName, displayLabel]
                .compactMap { value in
                    guard !value.isEmpty else { return nil }
                    return value
                }
                .deduplicated()
                .joined(separator: " · ")
        }
        return displayLabel
    }

    private var hasDistinctModelLabel: Bool {
        guard let modelLabel, !modelLabel.isEmpty else { return false }
        let normalizedModel = modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedModel != normalizedAccount else { return false }
        let normalizedDisplay = displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedModel != normalizedDisplay
    }

    var additionalLimitTitle: String {
        if isModelCapacityLimit, let modelLabel, !modelLabel.isEmpty {
            return modelLabel
        }
        return displayLabel
    }

    var additionalLimitSubtitle: String {
        if isModelCapacityLimit {
            return [windowLabel, accountName]
                .compactMap { value in
                    guard let value, !value.isEmpty else { return nil }
                    return value
                }
                .deduplicated()
                .joined(separator: " · ")
        }
        return contextLabel.isEmpty ? accountName : contextLabel
    }

    var isModelCapacityLimit: Bool {
        windowLabel?.isModelCapacityDisplayLabel == true
    }

    var sidebarDetailText: String {
        let parts = [accountName, resetText]
            .compactMap { value in
                guard !value.isEmpty else { return nil }
                return value
            }
            .deduplicated()
        return parts.joined(separator: " · ")
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

private extension Array where Element == UsageLimit {
    var sortedForOpenAIAccount: [UsageLimit] {
        sorted { lhs, rhs in
            let lhsRank = lhs.mainLimitWindow?.openAIAccountSortRank ?? Int.max
            let rhsRank = rhs.mainLimitWindow?.openAIAccountSortRank ?? Int.max
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.displayLabel.localizedCaseInsensitiveCompare(rhs.displayLabel) == .orderedAscending
        }
    }
}

private extension MainLimitWindow {
    var openAIAccountSortRank: Int {
        switch self {
        case .weekly: return 0
        case .fiveHour: return 1
        case .daily: return 2
        case .availability: return 3
        }
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

    var attentionSortRank: Int {
        switch self {
        case .failure: 3
        case .unknown: 2
        case .stale: 1
        case .healthy, .close, .limited, .loading: 0
        }
    }
}

private extension StoredProviderReport {
    var needsRefreshAttention: Bool {
        status == .failure || needsNonFailureRefreshAttention
    }

    var needsNonFailureRefreshAttention: Bool {
        status == .stale || (status == .unknown && errorMessage != nil)
    }

    var hasProviderConfigurationFailure: Bool {
        guard provider == .google else { return false }
        guard let errorMessage else { return false }
        return errorMessage.localizedCaseInsensitiveContains("client id is not configured")
            || errorMessage.localizedCaseInsensitiveContains("client_id is missing")
            || errorMessage.localizedCaseInsensitiveContains("client secret is not configured")
            || errorMessage.localizedCaseInsensitiveContains("client_secret is missing")
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

    var widgetDateTimeWithRelativeText: String {
        let relative = widgetRelativeText
        let compactRelative = relative.hasPrefix("in ") ? String(relative.dropFirst(3)) : relative
        if shouldShowWidgetDateTime {
            return "\(widgetDateTimeText) (\(compactRelative))"
        }
        return compactRelative
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
