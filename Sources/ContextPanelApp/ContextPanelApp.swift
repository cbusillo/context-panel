import ContextPanelCore
import ContextPanelCloudKitSync
import ContextPanelSettingsUI
import ContextPanelValidationGalleryUI
import AppKit
import Combine
import os
import ServiceManagement
import SwiftUI
@preconcurrency import UserNotifications
import WidgetKit

private let contextPanelLogger = Logger(subsystem: "com.shinycomputers.contextpanel", category: "app")

private func reloadContextPanelWidgetTimeline() {
    WidgetCenter.shared.reloadTimelines(ofKind: ContextPanelWidgetIdentity.kind)
}

@main
struct ContextPanelApp: App {
    @NSApplicationDelegateAdaptor(ContextPanelAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Context Panel", id: "main") {
            AppRoot(model: appDelegate.model)
                .frame(minWidth: 1080, idealWidth: 1080, minHeight: 720, idealHeight: 720)
                .onOpenURL { url in
                    appDelegate.handleExternalURL(url, source: "SwiftUI")
                }
                .handlesExternalEvents(preferring: ["overview", "reconnect"], allowing: ["overview", "reconnect"])
        }
        .defaultSize(width: 1080, height: 720)
        .handlesExternalEvents(matching: ["overview", "reconnect"])

        Settings {
            SettingsPane(appModel: appDelegate.model, navigation: appDelegate.settingsNavigation)
        }
    }
}

struct SettingsNavigationRequest: Equatable {
    enum Destination: Equatable {
        case accounts
        case cacheStats
        case validationGallery(ValidationGalleryRoute)
    }

    let id = UUID()
    let destination: Destination?
}

@MainActor
final class SettingsNavigationModel: ObservableObject {
    @Published private(set) var request: SettingsNavigationRequest?

    func focus(_ destination: SettingsNavigationRequest.Destination) {
        request = SettingsNavigationRequest(destination: destination)
    }

    func clear() {
        request = SettingsNavigationRequest(destination: nil)
    }

    func consumeRequest() -> SettingsNavigationRequest? {
        defer { request = nil }
        return request
    }
}

@MainActor
final class ContextPanelAppDelegate: NSObject, NSApplicationDelegate {
    private static let widgetTimelineRecoveryThrottle: TimeInterval = 30

    let model = ContextPanelAppModel()
    let settingsNavigation = SettingsNavigationModel()
    private var settingsWindow: NSWindow?
    private var pendingLimitWarningObserver: NSObjectProtocol?
    private var widgetSnapshotUpdateObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screensDidWakeObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var lastWidgetTimelineRecoveryAt: Date?
    private let backgroundRefreshSettingsStore = BackgroundRefreshSettingsStore(
        settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        if handleCommandLineUtilityMode() {
            return
        }
        registerOpenURLAppleEventHandler()
        registerPendingLimitWarningObserver()
        registerWidgetSnapshotUpdateObserver()
        registerWidgetTimelineRecoveryObservers()
        reconcileRefreshAgentRegistration()
        model.loadSnapshot()
        Task { await model.deliverPendingLimitWarnings() }
        reloadContextPanelWidgetTimeline()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let pendingLimitWarningObserver {
            DistributedNotificationCenter.default().removeObserver(pendingLimitWarningObserver)
        }
        if let widgetSnapshotUpdateObserver {
            DistributedNotificationCenter.default().removeObserver(widgetSnapshotUpdateObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if let screensDidWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(screensDidWakeObserver)
        }
        if let becomeActiveObserver {
            NotificationCenter.default.removeObserver(becomeActiveObserver)
        }
        RefreshAgentRegistration.cancelPendingRepair()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func registerOpenURLAppleEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenURLAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleOpenURLAppleEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString)
        else {
            contextPanelLogger.error("open URL AppleEvent ignored because URL was missing or invalid")
            return
        }

        handleExternalURL(url, source: "AppleEvent")
    }

    private func registerPendingLimitWarningObserver() {
        pendingLimitWarningObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(LimitWarningNotificationWakeup.distributedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { await self?.model.deliverPendingLimitWarnings() }
        }
    }

    private func registerWidgetSnapshotUpdateObserver() {
        widgetSnapshotUpdateObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(ContextPanelWidgetRefreshWakeup.distributedNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.model.loadSnapshot(reloadWidgetTimelines: false)
                reloadContextPanelWidgetTimeline()
            }
        }
    }

    private func registerWidgetTimelineRecoveryObservers() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverWidgetTimelineAfterWakeOrActivation()
            }
        }
        screensDidWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverWidgetTimelineAfterWakeOrActivation()
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.recoverWidgetTimelineAfterWakeOrActivation()
            }
        }
    }

    private func recoverWidgetTimelineAfterWakeOrActivation() {
        let now = Date()
        if let lastWidgetTimelineRecoveryAt,
           now.timeIntervalSince(lastWidgetTimelineRecoveryAt) < Self.widgetTimelineRecoveryThrottle {
            return
        }
        lastWidgetTimelineRecoveryAt = now
        model.loadSnapshot(reloadWidgetTimelines: false)
        reloadContextPanelWidgetTimeline()
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
            RefreshAgentRegistration.clearPersistedState()
        } catch {
            model.setError("Background refresh could not be disabled: \(error.localizedDescription)")
        }
        NSApp.terminate(nil)
        return true
    }

    private func reconcileRefreshAgentRegistration() {
        let settings = backgroundRefreshSettingsStore.load()
        do {
            try RefreshAgentRegistration.reconcile(settings: settings)
        } catch {
            model.setError("Background refresh could not be updated: \(error.localizedDescription)")
        }
        RefreshAgentRegistration.repairIfEnabledAgentDoesNotLaunch(
            settingsStore: backgroundRefreshSettingsStore
        ) { [weak self] diagnostic in
            if let diagnostic {
                self?.model.setError(diagnostic.userFacingMessage)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = Self.mainWindow(), flag {
            presentMainWindow(window)
            return false
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleExternalURL(url, source: "NSApplication")
        }
    }

    func handleExternalURL(_ url: URL, source: String) {
        contextPanelLogger.info(
            "open URL received source=\(source, privacy: .public) scheme=\(url.scheme ?? "none", privacy: .public) path=\(url.path, privacy: .public)"
        )
        model.handleOpenURL(url)
        presentWindow(for: url)
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

    private func presentSettingsWindow(destination: SettingsNavigationRequest.Destination? = nil) {
        NSApp.activate(ignoringOtherApps: true)

        if let destination {
            settingsNavigation.focus(destination)
        } else {
            settingsNavigation.clear()
        }

        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) ||
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil) {
            return
        }

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsPane(appModel: model, navigation: settingsNavigation)
                .frame(minWidth: 520, minHeight: 560)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Context Panel Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 620))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window
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

    func presentWindow(for url: URL) {
        if url.host?.lowercased() == "settings" || ValidationGalleryRoute(url: url) != nil {
            presentSettingsWindow(destination: settingsDestination(for: url))
        } else {
            presentMainWindowWhenAvailable()
        }
    }

    private func settingsDestination(for url: URL) -> SettingsNavigationRequest.Destination? {
        if let galleryRoute = ValidationGalleryRoute(url: url) {
            return .validationGallery(galleryRoute)
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if path == "cache-stats" {
            return .cacheStats
        }
        return nil
    }
}

enum AppNavigationSelection: Hashable {
    case overview
    case reconnect
    case provider(Provider)
    case providerAccount(Provider, String)
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
    @ObservedObject var navigation: SettingsNavigationModel
    @StateObject private var model = SettingsPaneModel()
    @State private var focusedDestination: SettingsNavigationRequest.Destination?
    @State private var galleryRoute: ValidationGalleryRoute?

    var body: some View {
        Form {
            if focusedDestination == .cacheStats {
                cacheStatsSetupSection
            }

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
                            } else if account.connectorKind == .googleAntigravityQuota {
                                let authorizationSummary = model.authorizationSummary(
                                    for: account,
                                    storedSnapshot: appModel.storedSnapshot
                                )
                                HStack(spacing: 8) {
                                    Text(authorizationSummary.text)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CPTheme.statusColor(authorizationSummary.status))
                                    if model.hasSavedAuthorization(account) {
                                        Button("Copy Remove") { model.copyAntigravityBridgeRemovalCommand() }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button("Forget", role: .destructive) {
                                            model.forgetAntigravityBridgeData()
                                            refreshAfterAuthorization()
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    } else {
                                        Button("Copy Setup") { model.copyAntigravityBridgeSetupCommand() }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        Button("Copy Remove") { model.copyAntigravityBridgeRemovalCommand() }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    }
                                }
                            } else if model.hasSavedAuthorization(account) {
                                let authorizationSummary = model.authorizationSummary(
                                    for: account,
                                    storedSnapshot: appModel.storedSnapshot
                                )
                                HStack(spacing: 8) {
                                    Text(authorizationSummary.text)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CPTheme.statusColor(authorizationSummary.status))
                                    if model.canAuthorizeAuthFile(for: account) {
                                        Button("Change") { authorizeAuthFile(for: account) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                    } else if model.canManageOAuth(for: account) {
                                        Button("Reconnect") { reconnectOAuth(for: account) }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        Button("Disconnect", role: .destructive) { disconnectOAuth(for: account) }
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
                        if let promptCacheText = model.promptCacheUsageDetailText(for: account) {
                            HStack(spacing: 8) {
                                Text(promptCacheText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(CPTheme.secondaryText)
                                    .lineLimit(2)
                                Spacer(minLength: 8)
                                if model.hasSavedPromptCacheUsageAuthorization(account) {
                                    Text("Usage saved")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(CPTheme.statusColor(.healthy))
                                    Button("Change") { authorizePromptCacheUsage(for: account) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                } else if model.needsPromptCacheUsageAuthorization(account) {
                                    Button("Enable Cache Stats") { authorizePromptCacheUsage(for: account) }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
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
                ForEach(model.refreshDiagnosticRows(now: Date())) { row in
                    DetailRow(label: row.label, value: row.value)
                }
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
                if let noticeMessage = model.noticeMessage {
                    Text(noticeMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.statusColor(.healthy))
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

            Section("Limit Warnings") {
                Toggle(isOn: Binding(
                    get: { model.limitWarningSettings.isEnabled },
                    set: { model.setLimitWarningsEnabled($0) }
                )) {
                    Text("Notify when capacity is low")
                }
                .toggleStyle(.switch)

                Picker("Warn at", selection: Binding(
                    get: { model.limitWarningSettings.thresholdPercentRemaining },
                    set: { model.setLimitWarningThreshold($0) }
                )) {
                    ForEach([5, 10, 15, 20, 25, 50], id: \.self) { percent in
                        Text("\(percent)% left").tag(percent)
                    }
                }
                .disabled(!model.limitWarningSettings.isEnabled)

                Toggle(isOn: Binding(
                    get: { model.limitWarningSettings.playsSound },
                    set: { model.setLimitWarningSoundEnabled($0) }
                )) {
                    Text("Play sound")
                }
                .toggleStyle(.switch)
                .disabled(!model.limitWarningSettings.isEnabled)

                Text(model.limitWarningStatusText)
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)

                Divider()

                Toggle(isOn: Binding(
                    get: { model.webhookSettings.isEnabled },
                    set: { model.setWebhookEnabled($0) }
                )) {
                    Text("Send webhook alerts")
                }
                .toggleStyle(.switch)

                Picker("Webhook type", selection: Binding(
                    get: { model.webhookSettings.preset },
                    set: { model.setWebhookPreset($0) }
                )) {
                    ForEach(LimitWarningWebhookPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .disabled(!model.webhookSettings.isEnabled)

                SecureField("Webhook URL", text: $model.webhookURLInputText)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.webhookSettings.isEnabled)

                HStack(spacing: 8) {
                    Button("Save URL") { model.saveWebhookURL() }
                        .disabled(!model.webhookSettings.isEnabled || model.webhookURLInputText.isEmpty)
                    Button("Clear URL") { model.clearWebhookURL() }
                        .disabled(model.webhookURLDisplayText.isEmpty)
                    Spacer()
                    Text(model.webhookURLDisplayText.isEmpty ? "No webhook URL saved" : model.webhookURLDisplayText)
                        .font(.system(size: 11))
                        .foregroundStyle(CPTheme.secondaryText)
                }

                TextField("Destination label", text: Binding(
                    get: { model.webhookSettings.destinationLabel },
                    set: { model.setWebhookDestinationLabel($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(!model.webhookSettings.isEnabled)

                TextField("Discord mention", text: Binding(
                    get: { model.webhookSettings.mentionText },
                    set: { model.setWebhookMentionText($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .disabled(!model.webhookSettings.isEnabled || model.webhookSettings.preset != .discord)

                HStack(spacing: 8) {
                    Button(model.webhookTestButtonText) { model.sendWebhookTest() }
                        .disabled(!model.canSendWebhookTest)
                    Text(model.webhookStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(CPTheme.secondaryText)
                    Spacer()
                }
            }

            Section("Widget Main Limits") {
                Text("Choose which main limits appear in the widget and drag rows to set their priority.")
                    .font(.system(size: 11))
                    .foregroundStyle(CPTheme.secondaryText)

                List {
                    WidgetMainLimitSettingsRows(
                        preferences: model.widgetPreferences,
                        colors: ContextPanelSettingsControlColors(
                            primaryText: CPTheme.primaryText,
                            secondaryText: CPTheme.secondaryText,
                            tertiaryText: CPTheme.tertiaryText
                        ),
                        providerLabel: { provider in
                            ProviderBadge(provider: provider)
                        },
                        onVisibilityChange: model.setWidgetMainLimit(_:isVisible:),
                        onMove: model.moveWidgetMainLimits(from:to:)
                    )
                }
                .listStyle(.inset)
                .frame(height: widgetMainLimitListHeight)
            }

        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 360)
        .sheet(isPresented: $model.isClaudeOAuthCodeSheetPresented) {
            ClaudeOAuthCodeSheet(model: model) {}
        }
        .sheet(item: $galleryRoute) { route in
            SettingsValidationGallerySheet(route: route)
        }
        .onAppear {
            model.load()
            consumeNavigationRequest(clearWhenEmpty: true)
        }
        .onChange(of: navigation.request?.id) { _, _ in
            consumeNavigationRequest()
        }
        .onChange(of: model.authorizationRefreshCounter) { _, _ in
            refreshAfterAuthorization()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .contextPanelRefreshAgentRegistrationDiagnosticDidChange
            )
        ) { _ in
            model.reloadBackgroundRefreshRegistrationDiagnostic()
        }
    }

    private var widgetMainLimitListHeight: CGFloat {
        let rowHeight: CGFloat = 36
        let verticalInset: CGFloat = 16
        let minimumVisibleRows: CGFloat = 4
        let rowCount = CGFloat(model.widgetPreferences.mainLimits.count)
        return max(rowHeight * minimumVisibleRows, rowHeight * rowCount) + verticalInset
    }

    private func consumeNavigationRequest(clearWhenEmpty: Bool = false) {
        guard let request = navigation.consumeRequest() else {
            if clearWhenEmpty {
                focusedDestination = nil
            }
            return
        }
        if case let .validationGallery(route) = request.destination {
            galleryRoute = route
            focusedDestination = nil
        } else {
            focusedDestination = request.destination
        }
    }

    private func authorizeAuthFile(for account: LocalProviderAccountConfiguration) {
        model.authorizeAuthFile(for: account) {
            refreshAfterAuthorization()
        }
    }

    private var cacheStatsSetupSection: some View {
        Section("Cache Stats") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.promptCacheSetupText)
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let account = model.promptCacheSetupAccount {
                    Button(model.hasSavedPromptCacheUsageAuthorization(account) ? "Change Usage Folder" : "Enable Cache Stats") {
                        authorizePromptCacheUsage(for: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func authorizePromptCacheUsage(for account: LocalProviderAccountConfiguration) {
        model.authorizePromptCacheUsage(for: account) {
            refreshAfterAuthorization()
        }
    }

    private func reconnectOAuth(for account: LocalProviderAccountConfiguration) {
        switch account.connectorKind {
        case .claudeOAuthUsage:
            model.authorizeClaudeOAuth(for: account)
        case .googleAntigravityQuota:
            model.copyAntigravityBridgeSetupCommand()
        case .codexRateLimits:
            break
        }
    }

    private func disconnectOAuth(for account: LocalProviderAccountConfiguration) {
        Task {
            guard await model.disconnectOAuth(for: account) else { return }
            await appModel.refreshLocalConnectors()
        }
    }

    private func refreshAfterAuthorization() {
        Task {
            await appModel.refreshLocalConnectors()
            model.load()
        }
    }
}

private struct SettingsValidationGallerySheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: ValidationGalleryRoute

    var body: some View {
        NavigationStack {
            ValidationGalleryView(
                route: route,
                supportedPresentations: [.overview, .detail, .reconnect, .diagnostics, .widget],
                applicationPreview: { context in
                    AnyView(MacValidationGalleryPreview(context: context))
                }
            )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
        }
        .frame(minWidth: 1_120, minHeight: 720)
    }
}

@MainActor
struct MacValidationGalleryPreview: View {
    @Environment(\.colorScheme) private var hostColorScheme
    @StateObject private var model: ContextPanelAppModel

    let context: ValidationGalleryContext

    init(context: ValidationGalleryContext) {
        self.context = context
        _model = StateObject(wrappedValue: ContextPanelAppModel.validationFixture(context: context))
    }

    private var previewColorScheme: ColorScheme {
        switch context.appearance {
        case .adaptive:
            hostColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    var body: some View {
        Group {
            switch context.presentation {
            case .overview:
                OverviewDashboard(
                    model: model,
                    snapshot: context.snapshot.usageSnapshot,
                    presentationDate: context.presentationDate
                )
            case .detail:
                if let summary = context.snapshot.usageSnapshot.mainLimitSummaries.first {
                    MainLimitDetail(
                        model: model,
                        summary: summary,
                        generatedAt: context.snapshot.generatedAt,
                        presentationDate: context.presentationDate
                    )
                } else {
                    ContentUnavailableView(
                        "No sample limit",
                        systemImage: "gauge.with.dots.needle.0percent",
                        description: Text("Choose a sample state with a limit to review the detail presentation.")
                    )
                }
            case .reconnect:
                ReconnectDashboardLayout(
                    appModel: model,
                    accountsTitle: "Next Step",
                    onRefresh: {}
                ) {
                    Text(model.emptyAttentionActionText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(CPTheme.secondaryText)
                }
            case .diagnostics:
                MacValidationDiagnosticsPreview(context: context)
            case .settings, .widget:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 460, alignment: .topLeading)
        .environment(\.colorScheme, previewColorScheme)
    }
}

struct MacValidationDiagnosticsPreview: View {
    let context: ValidationGalleryContext

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader(title: "Diagnostics", trailing: "Sample state")
                DetailCard(title: "Snapshot") {
                    DetailRow(label: "Status", value: context.snapshot.status.previewStatusText)
                    DetailRow(
                        label: "Updated",
                        value: context.snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    DetailRow(label: "Fixture", value: context.fixture.title)
                    DetailRow(label: "Proof", value: "Shared view only")
                }
                ProviderAccessAlertsSection(alerts: context.snapshot.providerAccessAlerts)
                PromptCacheOverviewCard(
                    summary: PromptCacheSummary(
                        observations: context.snapshot.promptCacheObservations,
                        now: context.presentationDate
                    )
                )
                if let syncErrorMessage = context.snapshot.syncErrorMessage {
                    DetailCard(title: "Refresh") {
                        Text(syncErrorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.statusColor(.failure))
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
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
                .disabled(model.isCompletingClaudeOAuth)
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
        .interactiveDismissDisabled(model.isCompletingClaudeOAuth)
    }
}

struct SettingsAccountRefreshSummary: Equatable {
    let text: String
    let status: UsageStatus
}

struct RefreshDiagnosticRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

private extension RefreshDiagnosticsDecision {
    var displayText: String {
        switch self {
        case .refreshed:
            "refreshed"
        case .skippedFresh:
            "skipped fresh"
        case .skippedAlreadyRunning:
            "already running"
        case .skippedNoReports:
            "no reports"
        case .failed:
            "failed"
        }
    }
}

private extension CompanionSyncDiagnosticsOutcome {
    var displayText: String {
        switch self {
        case .healthy:
            "healthy"
        case .partial:
            "partial"
        case .unavailable:
            "unavailable"
        case .stale:
            "stale"
        case .failed:
            "failed"
        }
    }
}

@MainActor
final class SettingsPaneModel: NSObject, ObservableObject {
    @Published private(set) var accounts: [LocalProviderAccountConfiguration] = []
    @Published private(set) var widgetPreferences: WidgetDisplayPreferences = .defaultPreferences
    @Published private(set) var backgroundRefreshSettings: BackgroundRefreshSettings = .defaultSettings
    @Published private(set) var backgroundRefreshRegistrationDiagnostic: RefreshAgentRegistrationDiagnostic?
    @Published private(set) var limitWarningSettings: LimitWarningSettings = .defaultSettings
    @Published private(set) var webhookSettings: LimitWarningWebhookSettings = .defaultSettings
    @Published private(set) var webhookDeliveryState: LimitWarningWebhookDeliveryState = .empty
    @Published private(set) var webhookURLDisplayText: String = ""
    @Published var webhookURLInputText: String = ""
    @Published private(set) var isSendingWebhookTest = false
    @Published private(set) var lastWebhookTestSentAt: Date?
    @Published private(set) var status: UsageStatus = .unknown
    @Published private(set) var errorMessage: String?
    @Published private(set) var noticeMessage: String?
    @Published private(set) var authorizedPaths: Set<String> = []
    @Published private(set) var missingAuthPaths: Set<String> = []
    @Published private(set) var legacyAuthPaths: Set<String> = []
    @Published private(set) var authorizedPromptCacheUsagePaths: Set<String> = []
    @Published private(set) var missingPromptCacheUsagePaths: Set<String> = []
    @Published var isClaudeOAuthCodeSheetPresented = false
    @Published private(set) var isCompletingClaudeOAuth = false
    @Published private(set) var authorizationRefreshCounter = 0

    private let bookmarkStore = SecureFileBookmarkStore(storeURL: ContextPanelLocations.bookmarkStoreURL())
    private let credentialStore = ProviderCredentialStore()
    private var recentlyVerifiedAuthPaths: Set<String> = []
    private var recentlyVerifiedPromptCacheUsagePaths: Set<String> = []
    private var pendingClaudeOAuth: PendingClaudeOAuth?
    private var completingClaudeOAuthState: String?
    private var claudeOAuthCompletionTask: Task<Void, Never>?
    private var webhookTestCooldownTask: Task<Void, Never>?
    private var backgroundRefreshRegistrationErrorMessage: String?

    deinit {
        claudeOAuthCompletionTask?.cancel()
        webhookTestCooldownTask?.cancel()
    }

    var pendingClaudeOAuthAuthorizationURL: URL? {
        pendingClaudeOAuth?.authorizationURL
    }

    private let store = AccountConfigurationStore(
        configurationURL: ContextPanelLocations.accountConfigurationURL(),
        fallbackConfigurationURL: ContextPanelLocations.legacyAccountConfigurationURL()
    )
    private let widgetPreferenceStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let backgroundRefreshSettingsStore = BackgroundRefreshSettingsStore(
        settingsURL: ContextPanelLocations.backgroundRefreshSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let limitWarningSettingsStore = LimitWarningSettingsStore(
        settingsURL: ContextPanelLocations.limitWarningSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let limitWarningStateStore = LimitWarningStateStore(
        stateURL: ContextPanelLocations.limitWarningStateURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let limitWarningPendingNotificationStore = LimitWarningPendingNotificationStore(
        queueURL: ContextPanelLocations.limitWarningPendingNotificationsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let webhookSettingsStore = LimitWarningWebhookSettingsStore(
        settingsURL: ContextPanelLocations.webhookSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let webhookDeliveryStateStore = LimitWarningWebhookDeliveryStateStore(
        stateURL: ContextPanelLocations.webhookDeliveryStateURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let refreshDiagnosticsStore = RefreshDiagnosticsStateStore(
        stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let webhookSecretStore = LimitWarningWebhookSecretStore()

    private var webhookDeliveryService: LimitWarningWebhookDeliveryService {
        LimitWarningWebhookDeliveryService(
            warningSettingsStore: limitWarningSettingsStore,
            settingsStore: webhookSettingsStore,
            stateStore: webhookDeliveryStateStore,
            secretStore: webhookSecretStore
        )
    }

    private var antigravityBridgeStore: GoogleAntigravityStatusLineSnapshotStore? {
        ContextPanelLocations.googleAntigravityStatusLineSnapshotURL().map {
            GoogleAntigravityStatusLineSnapshotStore(snapshotURL: $0)
        }
    }

    private var widgetPreferenceStores: WidgetDisplayPreferencesStoreSet {
        WidgetDisplayPreferencesStoreSet(stores: [widgetPreferenceStore])
    }

    var configurationPath: String {
        store.configurationURL.path
    }

    var promptCacheSetupAccount: LocalProviderAccountConfiguration? {
        accounts.first { account in
            account.isEnabled &&
                account.supportsPromptCacheTelemetry &&
                needsPromptCacheUsageAuthorization(account)
        } ?? accounts.first { account in
            account.isEnabled && account.supportsPromptCacheTelemetry
        }
    }

    var promptCacheSetupText: String {
        guard let account = promptCacheSetupAccount else {
            return "Connect an OpenAI CLI account first, then enable cache stats from this panel."
        }
        if hasSavedPromptCacheUsageAuthorization(account) {
            return "Cache stats are enabled for \(account.displayName). Change the usage folder if the widget cannot read cache hit rates."
        }
        return "Enable cache stats for \(account.displayName) by selecting its \(account.effectiveCodexClient?.telemetryFolderName ?? "usage") folder. Only token counts are shared with the widget."
    }

    var backgroundRefreshStatusText: String {
        if backgroundRefreshSettings.isEnabled {
            if let backgroundRefreshRegistrationDiagnostic {
                return backgroundRefreshRegistrationDiagnostic.userFacingMessage
            }
            return "Updates run every \(backgroundRefreshSettings.intervalMinutes) minutes in the background."
        }
        return "Background updates are off. Manual refresh still works."
    }

    var limitWarningStatusText: String {
        if limitWarningSettings.isEnabled {
            return "Context Panel warns once when a main limit falls to \(limitWarningSettings.thresholdPercentRemaining)% remaining."
        }
        return "Warnings are off. Turn them on to get a local alert before a main limit runs out."
    }

    var webhookStatusText: String {
        guard let latest = webhookDeliveryState.latestRecord else {
            if let latestTest = webhookDeliveryState.latestTestRecord {
                let time = latestTest.lastAttemptedAt.formatted(date: .omitted, time: .shortened)
                if latestTest.succeeded {
                    return "Last webhook test sent at \(time)."
                }
                if let status = latestTest.lastHTTPStatus {
                    return "Last webhook test failed at \(time): HTTP \(status)."
                }
                return "Last webhook test failed at \(time): \(latestTest.lastError ?? "unknown error")."
            }
            if webhookSettings.isEnabled {
                return "Webhook alerts are on. No delivery attempts yet."
            }
            return "Webhook alerts are off. Add a webhook URL to send limit warnings outside this Mac."
        }
        let time = latest.lastAttemptedAt.formatted(date: .omitted, time: .shortened)
        if latest.succeeded {
            return "Last webhook sent at \(time)."
        }
        if let status = latest.lastHTTPStatus {
            return "Last webhook failed at \(time): HTTP \(status)."
        }
        return "Last webhook failed at \(time): \(latest.lastError ?? "unknown error")."
    }

    var refreshDiagnosticsState: RefreshDiagnosticsState {
        refreshDiagnosticsStore.load()
    }

    func refreshDiagnosticRows(now: Date) -> [RefreshDiagnosticRow] {
        let state = refreshDiagnosticsState
        var rows: [RefreshDiagnosticRow] = []
        if let run = state.lastRun {
            rows.append(RefreshDiagnosticRow(
                id: "last-agent-wake",
                label: run.source == .refreshAgent ? "Agent last woke" : "App refresh started",
                value: relativeDiagnosticTime(run.startedAt, now: now)
            ))
            rows.append(RefreshDiagnosticRow(
                id: "last-refresh-decision",
                label: "Refresh decision",
                value: diagnosticDecisionText(run)
            ))
        } else {
            rows.append(RefreshDiagnosticRow(
                id: "last-agent-wake",
                label: "Agent last woke",
                value: "No background run recorded"
            ))
        }
        if let successfulRun = state.lastSuccessfulRun {
            rows.append(RefreshDiagnosticRow(
                id: "last-successful-run",
                label: "Last successful run",
                value: diagnosticSuccessText(successfulRun, now: now)
            ))
        }
        rows.append(RefreshDiagnosticRow(
            id: "last-companion-publish",
            label: "Companion publish",
            value: state.lastCompanionPublish.map { diagnosticCompanionSyncText($0, now: now) }
                ?? "No companion publish recorded"
        ))
        rows.append(RefreshDiagnosticRow(
            id: "last-companion-load",
            label: "Companion load",
            value: state.lastCompanionLoad.map { diagnosticCompanionSyncText($0, now: now) }
                ?? "No companion load recorded"
        ))
        if let evaluatedAt = state.lastAlertEvaluationAt {
            let eventCount = state.lastAlertEvaluationEventCount ?? 0
            rows.append(RefreshDiagnosticRow(
                id: "last-alert-eval",
                label: "Limit warning eval",
                value: "\(relativeDiagnosticTime(evaluatedAt, now: now)) · \(eventCount) event\(eventCount == 1 ? "" : "s")"
            ))
        }
        if let notification = state.lastLocalNotification {
            rows.append(RefreshDiagnosticRow(
                id: "last-local-notification",
                label: "Local warning queue",
                value: diagnosticAlertText(notification, now: now)
            ))
        }
        if let webhook = state.lastWebhook {
            rows.append(RefreshDiagnosticRow(
                id: "last-webhook",
                label: "Webhook warning",
                value: diagnosticAlertText(webhook, now: now)
            ))
        }
        return rows
    }

    private func diagnosticDecisionText(_ run: RefreshDiagnosticsRun) -> String {
        let decision = run.decision?.displayText ?? "running"
        var parts = [decision]
        if let intervalSeconds = run.intervalSeconds {
            parts.append("every \(max(intervalSeconds / 60, 1)) min")
        }
        if let reportCount = run.reportCount {
            let failureCount = run.failureCount ?? 0
            if failureCount > 0 {
                parts.append("\(failureCount)/\(reportCount) provider failures")
            } else {
                parts.append("\(reportCount) provider reports")
            }
        }
        if let errorMessage = run.errorMessage, !errorMessage.isEmpty {
            parts.append(errorMessage)
        }
        return parts.joined(separator: " · ")
    }

    private func diagnosticSuccessText(_ run: RefreshDiagnosticsRun, now: Date) -> String {
        let time = run.savedSnapshotAt ?? run.finishedAt ?? run.startedAt
        let reportCount = run.reportCount ?? 0
        let failureCount = run.failureCount ?? 0
        let limitCount = run.limitCount ?? 0
        var parts = [relativeDiagnosticTime(time, now: now)]
        parts.append("\(reportCount) reports")
        parts.append("\(limitCount) limits")
        if failureCount > 0 {
            parts.append("\(failureCount) failure\(failureCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ")
    }

    private func diagnosticCompanionSyncText(_ record: CompanionSyncDiagnosticsRecord, now: Date) -> String {
        var parts = [relativeDiagnosticTime(record.attemptedAt, now: now), record.outcome.displayText]
        if let appGroupSucceeded = record.appGroupSucceeded {
            parts.append(appGroupSucceeded ? "app group ok" : "app group failed")
        }
        if let iCloudAvailable = record.iCloudAvailable, !iCloudAvailable {
            parts.append("iCloud unavailable")
        } else if let iCloudSucceeded = record.iCloudSucceeded {
            parts.append(iCloudSucceeded ? "iCloud ok" : "iCloud failed")
        }
        if let loadedDocument = record.loadedDocument {
            parts.append(loadedDocument ? "loaded" : "not loaded")
        }
        if record.cloudKitMissingRecord == true {
            parts.append("CloudKit record missing")
        }
        if let mirroredDocument = record.mirroredDocument {
            parts.append(mirroredDocument ? "mirrored" : "mirror failed")
        }
        if record.stale == true {
            parts.append("stale mirror")
        }
        if let error = record.errorMessage, !error.isEmpty {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    private func diagnosticAlertText(_ record: RefreshDiagnosticsAlertRecord, now: Date) -> String {
        var parts = [relativeDiagnosticTime(record.attemptedAt, now: now)]
        if record.succeeded {
            parts.append("succeeded")
        } else if record.channel == .localNotification, record.errorMessage == nil {
            parts.append("queued")
        } else {
            parts.append("failed")
        }
        parts.append("\(record.eventCount) event\(record.eventCount == 1 ? "" : "s")")
        if let status = record.lastHTTPStatus {
            parts.append("HTTP \(status)")
        }
        if let error = record.errorMessage, !error.isEmpty {
            parts.append(error)
        }
        return parts.joined(separator: " · ")
    }

    private func relativeDiagnosticTime(_ date: Date, now: Date) -> String {
        let seconds = max(Int(now.timeIntervalSince(date)), 0)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    var canSendWebhookTest: Bool {
        webhookSettings.isEnabled
            && !webhookURLDisplayText.isEmpty
            && !isSendingWebhookTest
            && !isWebhookTestCoolingDown
    }

    var webhookTestButtonText: String {
        if isSendingWebhookTest { return "Sending..." }
        if isWebhookTestCoolingDown { return "Sent" }
        return "Send Test"
    }

    private var isWebhookTestCoolingDown: Bool {
        guard let lastWebhookTestSentAt else { return false }
        return Date().timeIntervalSince(lastWebhookTestSentAt) < 30
    }

    func load() {
        let result = store.load()
        accounts = result.document.accounts
        var loadedAuthorizedPaths = Set(accounts.compactMap { account -> String? in
            guard let authPath = account.effectiveAuthPath else { return nil }
            guard account.connectorKind.requiresSecurityScopedAuthFile else { return nil }
            let expanded = NSString(string: authPath).expandingTildeInPath
            return bookmarkStore.hasReadableCurrentBookmark(for: expanded) || hasImportedCredential(for: account)
                ? expanded
                : nil
        })
        loadedAuthorizedPaths.formUnion(recentlyVerifiedAuthPaths)
        authorizedPaths = loadedAuthorizedPaths

        var loadedMissingPaths = Set(accounts.compactMap { account -> String? in
            guard let authPath = account.effectiveAuthPath else { return nil }
            guard account.connectorKind.requiresSecurityScopedAuthFile else { return nil }
            let expanded = NSString(string: authPath).expandingTildeInPath
            return bookmarkStore.hasReadableCurrentBookmark(for: expanded) || hasImportedCredential(for: account)
                ? nil
                : expanded
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

        let usagePaths = promptCacheUsagePaths(for: accounts)
        var loadedUsagePaths = Set(usagePaths.filter { path in
            bookmarkStore.hasCurrentBookmark(for: path) && bookmarkStore.canResolveBookmark(for: path)
        })
        loadedUsagePaths.formUnion(recentlyVerifiedPromptCacheUsagePaths)
        authorizedPromptCacheUsagePaths = loadedUsagePaths

        var loadedMissingUsagePaths = Set(usagePaths.filter { path in
            !bookmarkStore.hasCurrentBookmark(for: path) || !bookmarkStore.canResolveBookmark(for: path)
        })
        loadedMissingUsagePaths.subtract(recentlyVerifiedPromptCacheUsagePaths)
        missingPromptCacheUsagePaths = loadedMissingUsagePaths

        widgetPreferences = widgetPreferenceStores.load()
        backgroundRefreshSettings = backgroundRefreshSettingsStore.load()
        reloadBackgroundRefreshRegistrationDiagnostic()
        limitWarningSettings = limitWarningSettingsStore.load()
        webhookSettings = webhookSettingsStore.load()
        webhookDeliveryState = webhookDeliveryStateStore.load()
        refreshWebhookURLDisplayText()
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
            if updated.isEnabled {
                RefreshAgentRegistration.repairIfEnabledAgentDoesNotLaunch(
                    settingsStore: backgroundRefreshSettingsStore
                ) { [weak self] _ in
                    self?.reloadBackgroundRefreshRegistrationDiagnostic()
                }
            }
        }
    }

    func setBackgroundRefreshInterval(_ minutes: Int) {
        var updated = backgroundRefreshSettings
        updated.setIntervalMinutes(minutes)
        if saveBackgroundRefreshSettings(updated) {
            reconcileRefreshAgentRegistration(settings: updated)
        }
    }

    func setLimitWarningsEnabled(_ isEnabled: Bool) {
        if isEnabled {
            Task { await enableLimitWarningNotifications() }
        } else {
            var updated = limitWarningSettings
            updated.isEnabled = false
            if saveLimitWarningSettings(updated) {
                clearLimitWarningState()
            }
        }
    }

    func setLimitWarningThreshold(_ percent: Int) {
        var updated = limitWarningSettings
        updated.setThresholdPercentRemaining(percent)
        if saveLimitWarningSettings(updated) {
            clearLimitWarningState()
        }
    }

    func setLimitWarningSoundEnabled(_ isEnabled: Bool) {
        var updated = limitWarningSettings
        updated.playsSound = isEnabled
        _ = saveLimitWarningSettings(updated)
    }

    func setWebhookEnabled(_ isEnabled: Bool) {
        var updated = webhookSettings
        updated.isEnabled = isEnabled
        _ = saveWebhookSettings(updated)
    }

    func setWebhookPreset(_ preset: LimitWarningWebhookPreset) {
        var updated = webhookSettings
        updated.preset = preset
        saveWebhookSettingsAndResetState(updated)
    }

    func setWebhookDestinationLabel(_ label: String) {
        var updated = webhookSettings
        updated.setDestinationLabel(label)
        _ = saveWebhookSettings(updated)
    }

    func setWebhookMentionText(_ text: String) {
        var updated = webhookSettings
        updated.setMentionText(text)
        _ = saveWebhookSettings(updated)
    }

    func saveWebhookURL() {
        let trimmed = webhookURLInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = LimitWarningWebhookSecretStore.validatedWebhookURL(trimmed) else {
            errorMessage = "Webhook URL must be a valid https URL."
            return
        }
        let service = webhookDeliveryService
        let secretStore = webhookSecretStore
        Task { @MainActor [weak self] in
            do {
                try await service.updateConfiguration { try secretStore.saveWebhookURL(url) }
                self?.webhookURLInputText = ""
                self?.webhookURLDisplayText = Self.redactedWebhookURL(url)
                self?.webhookDeliveryState = .empty
            } catch {
                self?.errorMessage = "Webhook URL could not be saved: \(error.localizedDescription)"
            }
        }
    }

    func clearWebhookURL() {
        let service = webhookDeliveryService
        let secretStore = webhookSecretStore
        Task { @MainActor [weak self] in
            do {
                try await service.updateConfiguration { try secretStore.deleteWebhookURL() }
                self?.webhookURLDisplayText = ""
                self?.webhookURLInputText = ""
                self?.webhookDeliveryState = .empty
            } catch {
                self?.errorMessage = "Webhook URL could not be cleared: \(error.localizedDescription)"
            }
        }
    }

    func sendWebhookTest() {
        guard canSendWebhookTest else { return }
        isSendingWebhookTest = true
        Task {
            let service = webhookDeliveryService
            let result = await service.sendTest()
            await MainActor.run {
                webhookDeliveryState = webhookDeliveryStateStore.load()
                isSendingWebhookTest = false
                let sentAt = Date()
                lastWebhookTestSentAt = sentAt
                scheduleWebhookTestCooldownRefresh(sentAt: sentAt)
                if result.succeeded {
                    errorMessage = nil
                } else if let message = result.errorMessage {
                    errorMessage = "Webhook test failed: \(message)"
                } else {
                    errorMessage = "Webhook test could not be sent. Save a webhook URL first."
                }
            }
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

    @discardableResult
    private func saveLimitWarningSettings(_ updated: LimitWarningSettings) -> Bool {
        do {
            try limitWarningSettingsStore.save(updated)
            limitWarningSettings = updated
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    private func saveWebhookSettings(_ updated: LimitWarningWebhookSettings) -> Bool {
        do {
            try webhookSettingsStore.save(updated)
            webhookSettings = updated
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func saveWebhookSettingsAndResetState(_ updated: LimitWarningWebhookSettings) {
        let service = webhookDeliveryService
        let settingsStore = webhookSettingsStore
        Task { @MainActor [weak self] in
            do {
                try await service.updateConfiguration { try settingsStore.save(updated) }
                self?.webhookSettings = updated
                self?.webhookDeliveryState = .empty
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshWebhookURLDisplayText() {
        do {
            if let url = try webhookSecretStore.loadWebhookURL() {
                webhookURLDisplayText = Self.redactedWebhookURL(url)
            } else {
                webhookURLDisplayText = ""
            }
        } catch {
            webhookURLDisplayText = ""
        }
    }

    private static func redactedWebhookURL(_ url: URL) -> String {
        guard let host = url.host else { return "Saved webhook URL" }
        return "Saved webhook for \(host)"
    }

    private func clearLimitWarningState() {
        do {
            try limitWarningStateStore.save(.empty)
            try limitWarningPendingNotificationStore.save(.empty)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleWebhookTestCooldownRefresh(sentAt: Date) {
        webhookTestCooldownTask?.cancel()
        webhookTestCooldownTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard let self, self.lastWebhookTestSentAt == sentAt else { return }
            self.lastWebhookTestSentAt = nil
            self.webhookTestCooldownTask = nil
        }
    }

    @MainActor
    private func enableLimitWarningNotifications() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            var updated = limitWarningSettings
            updated.isEnabled = true
            _ = saveLimitWarningSettings(updated)
        case .notDetermined:
            do {
                let isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
                if isAuthorized {
                    var updated = limitWarningSettings
                    updated.isEnabled = true
                    _ = saveLimitWarningSettings(updated)
                } else {
                    var updated = limitWarningSettings
                    updated.isEnabled = false
                    _ = saveLimitWarningSettings(updated)
                    errorMessage = "Notifications are off for Context Panel. Enable them in System Settings to receive limit warnings."
                }
            } catch {
                var updated = limitWarningSettings
                updated.isEnabled = false
                _ = saveLimitWarningSettings(updated)
                errorMessage = "Limit warning notifications could not be enabled: \(error.localizedDescription)"
            }
        case .denied:
            var updated = limitWarningSettings
            updated.isEnabled = false
            _ = saveLimitWarningSettings(updated)
            errorMessage = "Notifications are off for Context Panel. Enable them in System Settings to receive limit warnings."
        @unknown default:
            var updated = limitWarningSettings
            updated.isEnabled = false
            _ = saveLimitWarningSettings(updated)
            errorMessage = "Context Panel could not read its notification permission. Check System Settings before enabling limit warnings."
        }
    }

    private func reconcileRefreshAgentRegistration(settings: BackgroundRefreshSettings) {
        do {
            try RefreshAgentRegistration.reconcile(settings: settings)
            reloadBackgroundRefreshRegistrationDiagnostic()
        } catch {
            let diagnostic = RefreshAgentRegistration.currentDiagnostic
            backgroundRefreshRegistrationDiagnostic = diagnostic
            setBackgroundRefreshRegistrationError(
                diagnostic?.userFacingMessage ??
                    "Background refresh could not be updated: \(error.localizedDescription)"
            )
        }
    }

    func reloadBackgroundRefreshRegistrationDiagnostic() {
        let diagnostic = RefreshAgentRegistration.currentDiagnostic
        backgroundRefreshRegistrationDiagnostic = diagnostic
        setBackgroundRefreshRegistrationError(diagnostic?.userFacingMessage)
    }

    private func setBackgroundRefreshRegistrationError(_ message: String?) {
        if errorMessage == backgroundRefreshRegistrationErrorMessage {
            errorMessage = nil
        }
        backgroundRefreshRegistrationErrorMessage = message
        if let message {
            errorMessage = message
        }
    }

    func setAccount(_ accountID: String, isEnabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        accounts[index].isEnabled = isEnabled
        saveAccounts()
    }

    func copyAntigravityBridgeSetupCommand() {
        copyAntigravityBridgeCommand(
            GoogleAntigravityStatusLineSetup.setupCommand(applicationBundleURL: Bundle.main.bundleURL),
            notice: "Copied the AGY bridge setup command. AGY supports one custom status-line command; paste only if you are not replacing another customization."
        )
    }

    func copyAntigravityBridgeRemovalCommand() {
        copyAntigravityBridgeCommand(
            GoogleAntigravityStatusLineSetup.removeCommand,
            notice: "Copied the AGY bridge removal command. Paste it into AGY CLI, then use Forget in Context Panel."
        )
    }

    func forgetAntigravityBridgeData() {
        do {
            try antigravityBridgeStore?.delete()
            noticeMessage = "Forgot the saved AGY quota data."
            errorMessage = nil
        } catch {
            noticeMessage = nil
            errorMessage = "Antigravity bridge data could not be forgotten."
        }
    }

    private func copyAntigravityBridgeCommand(_ command: String, notice: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(command, forType: .string) else {
            noticeMessage = nil
            errorMessage = "The Antigravity bridge command could not be copied."
            return
        }
        errorMessage = nil
        noticeMessage = notice
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
            reloadContextPanelWidgetTimeline()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAccounts() {
        do {
            try store.save(AccountConfigurationDocument(updatedAt: Date(), accounts: accounts))
            reloadContextPanelWidgetTimeline()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func needsAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        guard account.isEnabled else { return false }
        if account.connectorKind == .claudeOAuthUsage {
            return !hasImportedCredential(for: account)
        }
        if account.connectorKind == .googleAntigravityQuota {
            return antigravityBridgeSnapshot() == nil
        }
        guard let authPath = account.effectiveAuthPath else { return false }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return false }
        let expanded = NSString(string: authPath).expandingTildeInPath
        return !bookmarkStore.hasReadableCurrentBookmark(for: expanded) && !hasImportedCredential(for: account)
    }

    func hasSavedAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        if account.connectorKind == .claudeOAuthUsage {
            return hasImportedCredential(for: account)
        }
        if account.connectorKind == .googleAntigravityQuota {
            return antigravityBridgeSnapshot() != nil
        }
        guard let authPath = account.effectiveAuthPath else { return false }
        guard account.connectorKind.requiresSecurityScopedAuthFile else { return false }
        let expanded = NSString(string: authPath).expandingTildeInPath
        return authorizedPaths.contains(expanded)
    }

    func needsPromptCacheUsageAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        guard account.isEnabled, account.supportsPromptCacheTelemetry else { return false }
        return !promptCacheUsagePaths(for: [account]).allSatisfy { authorizedPromptCacheUsagePaths.contains($0) }
    }

    func hasSavedPromptCacheUsageAuthorization(_ account: LocalProviderAccountConfiguration) -> Bool {
        guard account.supportsPromptCacheTelemetry else { return false }
        let paths = promptCacheUsagePaths(for: [account])
        return !paths.isEmpty && paths.allSatisfy { authorizedPromptCacheUsagePaths.contains($0) }
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

    func canAuthorizePromptCacheUsage(for account: LocalProviderAccountConfiguration) -> Bool {
        account.supportsPromptCacheTelemetry
    }

    func canManageOAuth(for account: LocalProviderAccountConfiguration) -> Bool {
        account.connectorKind == .claudeOAuthUsage
    }

    func authorizationSummary(
        for account: LocalProviderAccountConfiguration,
        storedSnapshot: StoredUsageSnapshot?
    ) -> SettingsAccountRefreshSummary {
        if account.connectorKind == .googleAntigravityQuota {
            guard let snapshot = antigravityBridgeSnapshot() else {
                return SettingsAccountRefreshSummary(text: "Setup required", status: .unknown)
            }
            let activeBuckets = snapshot.buckets.filter { !$0.isDisabled }
            if activeBuckets.isEmpty || activeBuckets.allSatisfy({ $0.remainingFraction == nil }) {
                return SettingsAccountRefreshSummary(text: "Bridge active · quota unavailable", status: .unknown)
            }
            if activeBuckets.contains(where: { bucket in
                guard let resetsAt = bucket.resetsAt else { return false }
                return resetsAt > snapshot.observedAt && resetsAt <= Date()
            }) {
                return SettingsAccountRefreshSummary(text: "Bridge active · reset assumed", status: .healthy)
            }
            let text = snapshot.planTier.map { "Bridge active · \($0)" } ?? "Bridge active"
            return SettingsAccountRefreshSummary(text: text, status: .healthy)
        }

        if account.connectorKind == .claudeOAuthUsage,
           let report = storedSnapshot?.reports
            .filter({ account.matchesProviderReport($0) })
            .max(by: { $0.generatedAt < $1.generatedAt }),
           report.requiresCredentialReconnect {
            return SettingsAccountRefreshSummary(text: "Reconnect required", status: .failure)
        }

        let text = switch account.connectorKind {
        case .claudeOAuthUsage:
            "Connected"
        case .googleAntigravityQuota:
            "Setup required"
        case .codexRateLimits:
            "File saved"
        }
        let status: UsageStatus = switch account.connectorKind {
        case .googleAntigravityQuota:
            .unknown
        case .claudeOAuthUsage, .codexRateLimits:
            .healthy
        }
        return SettingsAccountRefreshSummary(text: text, status: status)
    }

    func disconnectOAuth(for account: LocalProviderAccountConfiguration) async -> Bool {
        guard canManageOAuth(for: account) else { return false }
        if pendingClaudeOAuth?.accountID == account.id {
            cancelClaudeOAuth()
        }
        let accountIDs = oauthCredentialAccountIDs(for: account)
        let credentialStore = credentialStore
        do {
            guard try await Self.deleteOAuthCredentials(
                accountIDs: accountIDs,
                credentialStore: credentialStore
            ) else {
                errorMessage = "Another refresh is still running. Try disconnecting again in a moment."
                return false
            }
            errorMessage = nil
            load()
            reloadContextPanelWidgetTimeline()
            return true
        } catch {
            errorMessage = error.localizedDescription
        }
        return false
    }

    private nonisolated static func deleteOAuthCredentials(
        accountIDs: [String],
        credentialStore: ProviderCredentialStore
    ) async throws -> Bool {
        let lock = SnapshotRefreshLock.appDefault()
        let startedAt = ContinuousClock.now
        while !Task.isCancelled {
            if let _ = try await lock.withLock({
                for accountID in accountIDs {
                    try credentialStore.delete(accountID: accountID)
                }
            }) {
                return true
            }
            guard startedAt.duration(to: ContinuousClock.now) < .seconds(30) else {
                return false
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CancellationError()
    }

    private func oauthCredentialAccountIDs(for account: LocalProviderAccountConfiguration) -> [String] {
        switch account.connectorKind {
        case .claudeOAuthUsage:
            return Array(Set([account.id, "claude-local-default", "claude-oauth-default"]))
        case .googleAntigravityQuota:
            return [account.id]
        case .codexRateLimits:
            return [account.id]
        }
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
        if reports.contains(where: \.requiresCredentialReconnect) {
            return SettingsAccountRefreshSummary(
                text: "Last \(refreshSubject) failed; reconnect required",
                status: .failure
            )
        }
        if !reports.reconnectBlockingFailures(coveredBy: storedSnapshot.snapshot.limits).isEmpty {
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
        guard !successfulReports.isEmpty else {
            return SettingsAccountRefreshSummary(text: "Last \(refreshSubject) unavailable", status: .unknown)
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
        case .googleAntigravityQuota:
            "Google refresh"
        case .claudeOAuthUsage:
            "Claude refresh"
        }
    }

    func authorizeClaudeOAuth(for account: LocalProviderAccountConfiguration) {
        guard account.connectorKind == .claudeOAuthUsage else { return }
        do {
            claudeOAuthCompletionTask?.cancel()
            claudeOAuthCompletionTask = nil
            let flow = try PendingClaudeOAuth(accountID: account.id)
            pendingClaudeOAuth = flow
            completingClaudeOAuthState = nil
            isCompletingClaudeOAuth = false
            isClaudeOAuthCodeSheetPresented = true
            contextPanelLogger.info("Claude OAuth connect clicked for accountID=\(account.id, privacy: .private)")
            let opened = NSWorkspace.shared.open(flow.authorizationURL)
            contextPanelLogger.info("Claude OAuth authorization URL open result=\(opened, privacy: .public)")
            if !opened {
                errorMessage = "Claude authorization did not open automatically. Use the link in the Connect Claude sheet."
            }
        } catch {
            contextPanelLogger.error("Claude OAuth connect failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
            errorMessage = error.localizedDescription
        }
    }

    func cancelClaudeOAuth() {
        claudeOAuthCompletionTask?.cancel()
        claudeOAuthCompletionTask = nil
        pendingClaudeOAuth = nil
        completingClaudeOAuthState = nil
        isCompletingClaudeOAuth = false
    }

    func completeClaudeOAuth(code: String, onConnected: @escaping () -> Void) {
        guard let flow = pendingClaudeOAuth else { return }
        let authorizationCode = ClaudeOAuthFlow.normalizedAuthorizationCode(from: code)
        guard !authorizationCode.code.isEmpty else { return }
        isCompletingClaudeOAuth = true
        completingClaudeOAuthState = flow.state
        contextPanelLogger.info("Claude OAuth code exchange started")
        let exchangeService = ClaudeOAuthCodeExchangeService(credentialStore: credentialStore)
        let flowAccountID = flow.accountID
        let flowState = flow.state
        claudeOAuthCompletionTask?.cancel()
        claudeOAuthCompletionTask = Task { [weak self] in
            do {
                _ = try await exchangeService.exchangeAndCommit(
                    authorizationCode: authorizationCode,
                    codeVerifier: flow.pkce.verifier,
                    state: flow.state,
                    redirectURI: flow.redirectURI
                ) { [weak self] encodedCredentials in
                    guard let self else { throw CancellationError() }
                    try await self.commitClaudeOAuthCredentials(
                        encodedCredentials,
                        accountID: flowAccountID,
                        state: flowState
                    )
                }
                await MainActor.run {
                    guard let self else { return }
                    guard self.pendingClaudeOAuth?.accountID == flow.accountID,
                          self.pendingClaudeOAuth?.state == flow.state
                    else {
                        contextPanelLogger.info("Claude OAuth code exchange ignored because the flow is no longer active")
                        if self.completingClaudeOAuthState == flow.state {
                            self.isCompletingClaudeOAuth = false
                            self.completingClaudeOAuthState = nil
                        }
                        return
                    }
                    contextPanelLogger.info("Claude OAuth code exchange succeeded")
                    self.pendingClaudeOAuth = nil
                    self.claudeOAuthCompletionTask = nil
                    self.isCompletingClaudeOAuth = false
                    self.completingClaudeOAuthState = nil
                    self.isClaudeOAuthCodeSheetPresented = false
                    self.errorMessage = nil
                    self.authorizationRefreshCounter += 1
                    onConnected()
                }
            } catch {
                await MainActor.run {
                    contextPanelLogger.error("Claude OAuth code exchange failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
                    guard let self else { return }
                    if self.completingClaudeOAuthState == flow.state {
                        self.claudeOAuthCompletionTask = nil
                        self.isCompletingClaudeOAuth = false
                        self.completingClaudeOAuthState = nil
                        self.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func commitClaudeOAuthCredentials(_ data: Data, accountID: String, state: String) throws {
        guard !Task.isCancelled,
              pendingClaudeOAuth?.accountID == accountID,
              pendingClaudeOAuth?.state == state,
              completingClaudeOAuthState == state
        else {
            throw CancellationError()
        }
        try credentialStore.save(data, accountID: accountID)
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

    func authorizePromptCacheUsage(for account: LocalProviderAccountConfiguration, onVerified: @escaping () -> Void = {}) {
        guard let usageDirectory = account.promptCacheDirectory else { return }

        let panel = NSOpenPanel()
        panel.message = "Select the \(account.effectiveCodexClient?.telemetryFolderName ?? "usage") folder for \(account.displayName). Recent token counts are read locally; session text is never copied."
        panel.prompt = "Select Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = usageDirectory

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let selectedPath = ContextPanelLocations.normalizedPath(url.path)
            let expectedPath = ContextPanelLocations.normalizedPath(usageDirectory.path)
            guard selectedPath == expectedPath else {
                errorMessage = "Select \(ConnectorRedactor.redactedPath(expectedPath)) for \(account.displayName) cache stats."
                return
            }
            guard Self.directoryLooksLikePromptCacheUsage(url) else {
                errorMessage = "Select the telemetry folder for this client. Cache stats appear after usage is recorded."
                return
            }
            do {
                try bookmarkStore.createAndStoreBookmark(for: url, path: expectedPath)
                guard bookmarkStore.canResolveBookmark(for: expectedPath) else {
                    errorMessage = "Usage access could not be verified for \(account.displayName)."
                    missingPromptCacheUsagePaths.insert(expectedPath)
                    authorizedPromptCacheUsagePaths.remove(expectedPath)
                    return
                }
                authorizedPromptCacheUsagePaths.insert(expectedPath)
                missingPromptCacheUsagePaths.remove(expectedPath)
                recentlyVerifiedPromptCacheUsagePaths.insert(expectedPath)
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

    func promptCacheUsageDetailText(for account: LocalProviderAccountConfiguration) -> String? {
        guard let path = account.promptCacheDirectory?.path else { return nil }
        let detail: String
        switch account.effectiveCodexClient {
        case .codex: detail = "Recent session sample; account unknown"
        case .codexLab: detail = "Measured between refreshes; first refresh starts a baseline"
        default: detail = "Cache stats source"
        }
        return "\(detail) · \(ConnectorRedactor.redactedPath(path))"
    }

    private func detailSourceLabel(for account: LocalProviderAccountConfiguration) -> String {
        switch account.connectorKind {
        case .googleAntigravityQuota:
            return "AGY status-line quota export"
        case .claudeOAuthUsage:
            return "Claude OAuth"
        default:
            return account.connectorKind.rawValue
        }
    }

    private func setupInstruction(for account: LocalProviderAccountConfiguration) -> String {
        switch account.connectorKind {
        case .codexRateLimits:
            if account.effectiveCodexClient == .codexLab || account.effectiveCodexClient == .everyCode {
                return "Select auth_accounts.json for \(account.effectiveCodexClient?.displayName ?? account.displayName). ChatGPT accounts are read from this file"
            }
            if account.effectiveCodexClient == .codex {
                return "Select auth.json for Codex"
            }
            return "Select the OpenAI CLI auth JSON file"
        case .googleAntigravityQuota:
            return "Paste Copy Setup into AGY CLI once. Current AGY runs publish quota; AGY supports one status line and Context Panel never reads its login"
        case .claudeOAuthUsage:
            return "Connect Claude with OAuth for automatic background refresh"
        }
    }

    private func promptCacheUsagePaths(for accounts: [LocalProviderAccountConfiguration]) -> [String] {
        Array(Set(accounts.compactMap { account -> String? in
            guard account.isEnabled, let path = account.promptCacheDirectory?.path else { return nil }
            return ContextPanelLocations.normalizedPath(path)
        })).sorted()
    }

    private static func directoryLooksLikePromptCacheUsage(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func hasImportedCredential(for account: LocalProviderAccountConfiguration) -> Bool {
        switch account.connectorKind {
        case .googleAntigravityQuota:
            return antigravityBridgeSnapshot() != nil
        case .claudeOAuthUsage:
            return oauthCredentialAccountIDs(for: account).contains { accountID in
                (try? credentialStore.load(accountID: accountID)) != nil
            }
        case .codexRateLimits:
            return (try? credentialStore.load(accountID: account.id)) != nil
        }
    }

    private func antigravityBridgeSnapshot() -> GoogleAntigravityStatusLineSnapshot? {
        try? antigravityBridgeStore?.load()
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

private extension AccountConnectorKind {
    var requiresSecurityScopedAuthFile: Bool {
        switch self {
        case .codexRateLimits:
            return true
        case .googleAntigravityQuota, .claudeOAuthUsage:
            return false
        }
    }
}

struct AccountsSidebar: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    @Binding var selection: AppNavigationSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "gauge.medium")
                    .tag(AppNavigationSelection.overview)
                if model.shouldShowReconnectNavigation {
                    Label(model.attentionNavigationTitle, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CPTheme.statusColor(.failure))
                        .tag(AppNavigationSelection.reconnect)
                }
            }
            Section("Providers") {
                let reports = model.storedSnapshot?.reports ?? []
                let resetCreditSummary = ResetCreditSurfaceAdvisor.appSummary(
                    reports: reports,
                    limits: snapshot.limits,
                    now: Date()
                )
                ForEach(Provider.allCases) { provider in
                    let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                    if shouldShowProviderNavigation(provider: provider, summaries: summaries, reports: reports) {
                        ProviderSidebarRow(
                            provider: provider,
                            limitCount: summaries.count,
                            resetCreditSummary: provider == .openAI ? resetCreditSummary : nil
                        )
                            .tag(AppNavigationSelection.provider(provider))
                        ForEach(summaries.sortedForSidebar) { summary in
                            SidebarRateLimitRow(
                                summary: summary,
                                status: providerStatusIncludingAccessAlerts(
                                    provider: provider,
                                    baseStatuses: [summary.status],
                                    alerts: model.providerAccessAlerts
                                )
                            )
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
    let resetCreditSummary: ProviderResetCreditSurfaceSummary?

    var body: some View {
        HStack(spacing: 8) {
            ProviderBadge(provider: provider)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            if let resetCreditSummary {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .help(resetCreditHelpText(resetCreditSummary))
                    .accessibilityHidden(true)
            }
            Spacer()
            if limitCount > 0 {
                Text("\(limitCount)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [provider.displayName]
        if limitCount > 0 {
            parts.append(limitCount == 1 ? "1 main limit" : "\(limitCount) main limits")
        }
        if let resetCreditSummary {
            parts.append(resetCreditAccessibilityText(resetCreditSummary))
        }
        return parts.joined(separator: ", ")
    }
}

struct SidebarRateLimitRow: View {
    let summary: MainLimitSummary
    let status: UsageStatus

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(status: status, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.previewWindowLine)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                Text(summary.sidebarTimingText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(summary.compactUsageText)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
                .assumedResetHelp(summary.hasAssumedScheduledResetCapacity)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.quantitativeAccessibilityLabel)
        .accessibilityValue(summary.usedPressureAccessibilityValue(status: status))
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
        case let .providerAccount(provider, accountID):
            ProviderDashboard(
                model: model,
                snapshot: snapshot,
                provider: provider,
                focusedAccountID: accountID
            )
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
    let presentationDate: Date

    init(
        model: ContextPanelAppModel,
        snapshot: UsageSnapshot,
        presentationDate: Date = Date()
    ) {
        self.model = model
        self.snapshot = snapshot
        self.presentationDate = presentationDate
    }

    private var savedSummaries: [MainLimitSummary] {
        model.widgetPreferences.visibleMainLimitSummaries(
            from: snapshot.mainLimitSummaries,
            maximumCount: snapshot.mainLimitSummaries.count
        )
    }

    var body: some View {
        let keepWorkingForecast = KeepWorkingForecast(
            summaries: snapshot.mainLimitSummaries,
            observedBurnRates: model.observedBurnRates,
            settings: model.fastModeForecastSettings,
            now: presentationDate
        )
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderCard(model: model, snapshot: snapshot, keepWorkingForecast: keepWorkingForecast)
                if keepWorkingForecast.remainingPercent != nil && !keepWorkingForecast.isLimited {
                    UsagePaceCard(keepWorkingForecast: keepWorkingForecast)
                }
                SetupStatusStrip(model: model)
                ProviderAccessAlertsSection(alerts: model.providerAccessAlerts)
                PromptCacheOverviewCard(summary: model.promptCacheSummary)
                SectionHeader(
                    title: "All Limits",
                    trailing: keepWorkingForecast.rows.isEmpty ? "No limits selected" : "\(keepWorkingForecast.rows.count) windows"
                )
                if savedSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No limits selected")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        Text("Choose at least one limit in Settings to show it here.")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    .padding(.vertical, 8)
                } else {
                    if keepWorkingForecast.rows.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(savedSummaries) { summary in
                                MainLimitRow(
                                    summary: summary,
                                    status: providerStatusIncludingAccessAlerts(
                                        provider: summary.provider,
                                        baseStatuses: [summary.status],
                                        alerts: model.providerAccessAlerts
                                    )
                                )
                            }
                        }
                    } else {
                        AllLimitsScanCard(
                            rows: keepWorkingForecast.rows.filter { row in
                                savedSummaries.contains { $0.id == row.id }
                            },
                            providerAccessAlerts: model.providerAccessAlerts
                        )
                    }
                    let additionalSummaries = savedSummaries.filter {
                        $0.window != .fiveHour && $0.window != .weekly
                    }
                    if !additionalSummaries.isEmpty {
                        SectionHeader(title: "Other Limits")
                        VStack(spacing: 10) {
                            ForEach(additionalSummaries) { summary in
                                MainLimitRow(
                                    summary: summary,
                                    status: providerStatusIncludingAccessAlerts(
                                        provider: summary.provider,
                                        baseStatuses: [summary.status],
                                        alerts: model.providerAccessAlerts
                                    )
                                )
                            }
                        }
                    }
                }
                AdditionalLimitsSection(snapshot: snapshot)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
    }
}

struct UsagePaceCard: View {
    let keepWorkingForecast: KeepWorkingForecast

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Usage pace")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(keepWorkingForecast.paceBand.copy.capitalized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(paceColor)
            }

            if let recent = keepWorkingForecast.recentPercentPerHour,
               let required = keepWorkingForecast.requiredPercentPerHour {
                HStack(alignment: .lastTextBaseline, spacing: 18) {
                    PaceMetric(label: "Recent pace", value: rateText(recent), color: paceColor)
                    Divider().frame(height: 30)
                    PaceMetric(label: "To last until reset", value: rateText(required), color: CPTheme.primaryText)
                    Spacer(minLength: 0)
                }

                PaceBandControl(
                    paceBand: keepWorkingForecast.paceBand,
                    paceRatio: recent / max(required, 0.000_001)
                )
            } else {
                Text("Measuring recent use")
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.secondaryText)
            }

            if let outcome = keepWorkingForecast.outcomeCopy(density: .full) {
                Text(outcome)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(paceColor)
            }
        }
        .padding(18)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 12))
    }

    private var paceColor: Color {
        switch keepWorkingForecast.paceBand {
        case .over:
            CPTheme.statusColor(.close)
        case .under, .on, .idle:
            CPTheme.statusColor(.healthy)
        case .unknown:
            CPTheme.secondaryText
        }
    }

    private func rateText(_ rate: Double) -> String {
        "\(KeepWorkingForecast.rateText(rate))/h"
    }
}

private struct PaceMetric: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CPLabel(label)
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }
}

private struct PaceBandControl: View {
    let paceBand: KeepWorkingPaceBand
    let paceRatio: Double

    private var markerPosition: CGFloat {
        let normalized = min(max(paceRatio, 0), 2)
        return normalized <= 1 ? CGFloat(normalized * 0.5) : CGFloat(0.5 + (normalized - 1) * 0.25)
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Under pace")
                Spacer()
                Text("On pace")
                Spacer()
                Text("Over pace")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(CPTheme.tertiaryText)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(CPTheme.line)
                    Capsule()
                        .fill(CPTheme.statusColor(.healthy).opacity(0.75))
                        .frame(width: proxy.size.width * 0.5)
                    Capsule()
                        .fill(CPTheme.statusColor(.close).opacity(0.75))
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: proxy.size.width * 0.5)
                    Rectangle()
                        .fill(CPTheme.primaryText.opacity(0.75))
                        .frame(width: 1, height: 12)
                        .offset(x: proxy.size.width * 0.5)
                    Circle()
                        .fill(markerColor)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(proxy.size.width * markerPosition - 5, 0), proxy.size.width - 10))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage pace")
        .accessibilityValue(paceBand.copy)
    }

    private var markerColor: Color {
        switch paceBand {
        case .over:
            CPTheme.statusColor(.close)
        case .under, .on, .idle:
            CPTheme.statusColor(.healthy)
        case .unknown:
            CPTheme.secondaryText
        }
    }
}

private enum AllLimitsScanLayout {
    static let spacing: CGFloat = 12
    static let providerWidth: CGFloat = 46
    static let minimumLimitWidth: CGFloat = 150
    static let statusWidth: CGFloat = 82
}

struct AllLimitsScanCard: View {
    let rows: [KeepWorkingLimitRow]
    let providerAccessAlerts: [ProviderAccessAlert]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: AllLimitsScanLayout.spacing) {
                Text("Provider")
                    .frame(width: AllLimitsScanLayout.providerWidth, alignment: .leading)
                Text("5-hour")
                    .frame(
                        minWidth: AllLimitsScanLayout.minimumLimitWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                Text("Weekly")
                    .frame(
                        minWidth: AllLimitsScanLayout.minimumLimitWidth,
                        maxWidth: .infinity,
                        alignment: .leading
                    )
                Text("Status")
                    .frame(width: AllLimitsScanLayout.statusWidth, alignment: .trailing)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(CPTheme.tertiaryText)

            ForEach(providers) { provider in
                let fiveHour = rows.first { $0.provider == provider && $0.window == .fiveHour }
                let weekly = rows.first { $0.provider == provider && $0.window == .weekly }
                if fiveHour != nil || weekly != nil {
                    AllLimitsScanRow(
                        provider: provider,
                        fiveHour: fiveHour,
                        weekly: weekly,
                        status: providerStatusIncludingAccessAlerts(
                            provider: provider,
                            baseStatuses: [fiveHour?.status, weekly?.status].compactMap { $0 },
                            alerts: providerAccessAlerts
                        )
                    )
                }
            }
        }
        .padding(16)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var providers: [Provider] {
        rows.reduce(into: []) { result, row in
            if !result.contains(row.provider) {
                result.append(row.provider)
            }
        }
    }
}

private struct AllLimitsScanRow: View {
    let provider: Provider
    let fiveHour: KeepWorkingLimitRow?
    let weekly: KeepWorkingLimitRow?
    let status: UsageStatus

    var body: some View {
        HStack(spacing: AllLimitsScanLayout.spacing) {
            ProviderBadge(provider: provider, compact: true)
                .frame(width: AllLimitsScanLayout.providerWidth, alignment: .leading)
            LimitWindowScanCell(row: fiveHour, fallback: "5-hour")
                .frame(
                    minWidth: AllLimitsScanLayout.minimumLimitWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            LimitWindowScanCell(row: weekly, fallback: "Weekly")
                .frame(
                    minWidth: AllLimitsScanLayout.minimumLimitWidth,
                    maxWidth: .infinity,
                    alignment: .leading
                )
            Text(status.previewStatusText.capitalized)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(CPTheme.statusColor(status))
                .frame(width: AllLimitsScanLayout.statusWidth, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Divider().opacity(0.55)
        }
    }
}

private struct LimitWindowScanCell: View {
    let row: KeepWorkingLimitRow?
    let fallback: String

    var body: some View {
        if let row {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(resetCopy(row))
                        .font(.system(size: 10))
                        .foregroundStyle(CPTheme.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(row.remainingPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                RemainingCapacityScanBar(remainingPercent: row.remainingPercent, status: row.status)
            }
        } else {
            Text("No \(fallback.lowercased()) data")
                .font(.system(size: 10))
                .foregroundStyle(CPTheme.tertiaryText)
        }
    }

    private func resetCopy(_ row: KeepWorkingLimitRow) -> String {
        guard let resetsAt = row.resetsAt else { return "Reset unknown" }
        return resetsAt.formatted(.dateTime.weekday(.wide).hour().minute())
    }
}

private struct RemainingCapacityScanBar: View {
    let remainingPercent: Int?
    let status: UsageStatus

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(CPTheme.line)
                .overlay(alignment: .leading) {
                    if let remainingPercent {
                        Capsule()
                            .fill(CPTheme.statusColor(status))
                            .frame(width: proxy.size.width * CGFloat(remainingPercent) / 100)
                    }
                }
        }
        .frame(height: 4)
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
        ReconnectDashboardLayout(
            appModel: appModel,
            accountsTitle: accountsNeedingAction.isEmpty ? "Next Step" : "Accounts",
            onRefresh: {
                Task { await appModel.refreshLocalConnectors() }
            }
        ) {
            if accountsNeedingAction.isEmpty {
                Text(appModel.emptyAttentionActionText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
            } else {
                ForEach(accountsNeedingAction) { account in
                    ReconnectAccountRow(
                        account: account,
                        settingsModel: settingsModel,
                        attentionReport: appModel.providerReportNeedingAttention(for: account),
                        refreshSummary: settingsModel.refreshSummary(
                            for: account,
                            storedSnapshot: appModel.storedSnapshot
                        ),
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
        .sheet(isPresented: $settingsModel.isClaudeOAuthCodeSheetPresented) {
            ClaudeOAuthCodeSheet(model: settingsModel) {
                Task {
                    await appModel.refreshLocalConnectors()
                    settingsModel.load()
                }
            }
        }
        .onAppear {
            settingsModel.load()
        }
        .onChange(of: settingsModel.authorizationRefreshCounter) { _, _ in
            refreshAfterAuthorization()
        }
    }

    private func refreshAfterAuthorization() {
        Task {
            await appModel.refreshLocalConnectors()
            settingsModel.load()
        }
    }
}

private struct ReconnectDashboardLayout<AccountsContent: View>: View {
    @ObservedObject var appModel: ContextPanelAppModel

    let accountsTitle: String
    let onRefresh: () -> Void
    @ViewBuilder let accountsContent: AccountsContent

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
                    Button(action: onRefresh) {
                        Label(
                            appModel.isRefreshing ? "Refreshing" : "Refresh now",
                            systemImage: "arrow.clockwise"
                        )
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

                DetailCard(title: accountsTitle) {
                    VStack(alignment: .leading, spacing: 10) {
                        accountsContent
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(CPTheme.background)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentRate.map(Self.percentText) ?? "—")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CPTheme.primaryText)
                    Text("Current hit rate")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CPTheme.tertiaryText)
                        .textCase(.uppercase)
                }
                .frame(width: 112, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "chart.xyaxis.line")
                            .foregroundStyle(CPTheme.secondaryText)
                        Text("Prompt Cache")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        Text(comparisonText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(CPTheme.statusColor(comparisonTone))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(CPTheme.statusColor(comparisonTone).opacity(0.10))
                            .clipShape(Capsule())
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Prompt cache")
            .accessibilityValue(accessibilityValue)
        }
    }

    private var comparisonText: String {
        switch summary.latestRateComparison {
        case .above(let points):
            return "\(points) \(points == 1 ? "pt" : "pts") above average"
        case .below(let points):
            return "\(points) \(points == 1 ? "pt" : "pts") below average"
        case .matching:
            return "Matches average"
        case .unavailable:
            return "Average unavailable"
        }
    }

    private var comparisonTone: UsageStatus {
        switch summary.latestRateComparison {
        case .above, .matching:
            return .healthy
        case .below:
            return .close
        case .unavailable:
            return .unknown
        }
    }

    private var accessibilityValue: String {
        let current = currentRate.map { "\(Int(($0 * 100).rounded())) percent" } ?? "unknown"
        var value = "Hit rate \(current)."
        if let averageRate {
            value += " \(comparisonText). Recent average \(Int((averageRate * 100).rounded())) percent."
        } else {
            value += " Recent average unavailable."
        }
        if summary.hasPossibleCacheBreak {
            value += " Possible cache break; cached input dropped sharply on the latest window."
        }
        value += " Input \(summary.totalInputTokens) tokens. Cached \(summary.totalCachedInputTokens) tokens."
        if let uncached = summary.totalUncachedInputTokens {
            value += " Uncached \(uncached) tokens."
        }
        if let latest = summary.latest {
            let age = relativeAge(latest.observedAt)
            value += age == "now"
                ? " \(latest.windowLabel), observed now."
                : " \(latest.windowLabel), observed \(age) ago."
        }
        return value
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
        } else if account.connectorKind == .googleAntigravityQuota {
            if settingsModel.needsAuthorization(account) {
                Button("Copy Setup") { settingsModel.copyAntigravityBridgeSetupCommand() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Refresh") { onRefresh() }
                    .buttonStyle(.bordered)
            }
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
        if settingsModel.needsAuthorization(account) {
            return account.connectorKind == .googleAntigravityQuota
                ? "One-time AGY bridge setup is required."
                : "Account access is missing."
        }
        if settingsModel.hasLegacyAuthorization(account) { return "File access needs to be refreshed." }
        if account.connectorKind == .codexRateLimits, refreshSummary?.status == .failure {
            return "Sign in again with the configured Codex or Codex Lab client, then reselect its auth file."
        }
        if account.connectorKind == .claudeOAuthUsage { return "Reconnect Claude if refresh keeps failing." }
        if account.connectorKind == .googleAntigravityQuota {
            if attentionReport?.hasProviderConfigurationFailure == true {
                return "Google setup is missing from this build. Check provider configuration, then refresh."
            }
            return attentionReport?.userFacingErrorMessage
                ?? "AGY quota updates whenever AGY runs. Idle time alone does not require setup again."
        }
        return settingsModel.detailText(for: account)
    }
}

struct ProviderDashboard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    let provider: Provider
    var focusedAccountID: String? = nil

    private var summaries: [MainLimitSummary] {
        snapshot.mainLimitSummaries.filter { $0.provider == provider }
    }

    private var additionalLimits: [UsageLimit] {
        snapshot.additionalLimits.filter { $0.provider == provider }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    ProviderHeaderCard(model: model, provider: provider, summaries: summaries)
                    ProviderAccessAlertsSection(
                        alerts: model.providerAccessAlerts.filter { $0.provider == provider }
                    )
                    SectionHeader(title: "Main Limits", trailing: "\(summaries.count) windows")
                    VStack(spacing: 10) {
                        ForEach(summaries) { summary in
                            MainLimitRow(
                                summary: summary,
                                status: providerStatusIncludingAccessAlerts(
                                    provider: provider,
                                    baseStatuses: [summary.status],
                                    alerts: model.providerAccessAlerts
                                )
                            )
                        }
                    }
                    if provider == .openAI {
                        OpenAIAccountLimitsSection(
                            summaries: summaries,
                            reports: model.storedSnapshot?.reports ?? [],
                            now: Date()
                        )
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
            .onAppear { scrollToFocusedAccount(using: proxy) }
            .onChange(of: focusedAccountID) { _, _ in scrollToFocusedAccount(using: proxy) }
        }
    }

    private func scrollToFocusedAccount(using proxy: ScrollViewProxy) {
        guard provider == .openAI, let focusedAccountID else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo("openai-account:\(focusedAccountID)", anchor: .center)
            }
        }
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
    let reports: [StoredProviderReport]
    let now: Date

    private var accounts: [OpenAIAccountLimitSummary] {
        OpenAIAccountLimitSummary.accounts(from: summaries, reports: reports)
    }

    private var guidanceByAccountID: [String: ProviderResetCreditGuidance] {
        Dictionary(
            ResetCreditGuidanceAdvisor.guidance(
                reports: reports,
                limits: summaries.flatMap(\.limits),
                now: now
            ).map { ($0.accountID, $0) },
            uniquingKeysWith: { current, candidate in
                candidate.resetCredits.observedAt > current.resetCredits.observedAt ? candidate : current
            }
        )
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
                        OpenAIAccountLimitRow(
                            account: account,
                            resetCreditGuidance: guidanceByAccountID[account.accountID],
                            now: now
                        )
                        .id("openai-account:\(account.accountID)")
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
    let resetCreditGuidance: ProviderResetCreditGuidance?
    let now: Date

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
            if let resetCreditGuidance {
                Divider()
                    .overlay(CPTheme.line)
                OpenAIResetCreditRow(guidance: resetCreditGuidance, now: now)
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct OpenAIResetCreditRow: View {
    let guidance: ProviderResetCreditGuidance
    let now: Date

    private var status: UsageStatus {
        switch guidance.state {
        case .considerUsingNow:
            .limited
        case .considerBefore:
            .close
        case .hold:
            .healthy
        case let .refresh(reason):
            reason == .staleObservation ? .stale : .unknown
        }
    }

    private var availabilityText: String {
        switch guidance.state {
        case .refresh(.staleObservation), .refresh(.inconsistentObservation), .refresh(.expiryElapsed):
            "\(guidance.countText) last observed"
        case .hold, .considerUsingNow, .considerBefore, .refresh:
            "\(guidance.countText) available"
        }
    }

    private var expiryText: String {
        guard let expiry = guidance.resetCredits.earliestKnownExpiry else { return "Expiry unknown" }
        let prefix = guidance.resetCredits.coverage == .partial ? "Earliest known expiry" : "Earliest expiry"
        return "\(prefix) \(expiry.formatted(date: .abbreviated, time: .shortened))"
    }

    private var freshnessText: String {
        let age = SnapshotFreshness.compactAgeText(since: guidance.resetCredits.observedAt, now: now)
        return switch guidance.state {
        case .refresh(.staleObservation):
            "\(age) · stale"
        case .refresh(.inconsistentObservation), .refresh(.expiryElapsed):
            "\(age) · refresh"
        case .hold, .considerUsingNow, .considerBefore, .refresh:
            age
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.counterclockwise.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CPTheme.statusColor(status))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Reset credits")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CPTheme.secondaryText)
                    Spacer(minLength: 8)
                    Text(availabilityText)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CPTheme.primaryText)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(expiryText)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CPTheme.tertiaryText)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(freshnessText)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(CPTheme.tertiaryText)
                        .lineLimit(1)
                }
                Text(guidance.recommendationTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPTheme.statusColor(status))
                Text(guidance.recommendationDetail(now: now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let observed = guidance.resetCredits.observedAt.formatted(date: .long, time: .shortened)
        let expiry = guidance.resetCredits.earliestKnownExpiry
            .map { "Earliest known expiry \($0.formatted(date: .long, time: .shortened))." }
            ?? "Expiry unknown."
        return "\(availabilityText) for \(guidance.accountName). \(expiry) Observed \(observed). \(guidance.recommendationTitle). \(guidance.recommendationDetail(now: now))"
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
            UsagePressureBar(usedRatio: limit?.usageRatio, status: limit?.status ?? .unknown, height: 4)
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

struct OpenAIAccountLimitSummary: Identifiable {
    let accountID: String
    let accountName: String
    let limits: [UsageLimit]
    let reportStatus: UsageStatus?

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
        let statuses = limits.map(\.status) + [reportStatus].compactMap { $0 }
        return statuses.isEmpty ? .unknown : statuses.contextPanelWorstStatus
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

    static func accounts(
        from summaries: [MainLimitSummary],
        reports: [StoredProviderReport]
    ) -> [OpenAIAccountLimitSummary] {
        let limits = summaries
            .filter { $0.provider == .openAI }
            .flatMap(\.limits)
            .filter { $0.isMainLimit }
        let positiveResetReports = reports.filter {
            $0.provider == .openAI && ($0.resetCredits?.availableCount ?? 0) > 0
        }
        let reportsByAccountID = Dictionary(grouping: positiveResetReports, by: \.accountID)
            .compactMapValues(preferredReport)
        let accountIDs = Set(limits.map(\.accountID)).union(reportsByAccountID.keys)
        return accountIDs
            .map { accountID in
                let report = reportsByAccountID[accountID]
                let accountLimits = limits.filter { $0.accountID == accountID }
                return OpenAIAccountLimitSummary(
                    accountID: accountID,
                    accountName: accountLimits.first?.accountName ?? report?.accountName ?? "OpenAI Account",
                    limits: accountLimits.sortedForOpenAIAccount,
                    reportStatus: report?.status
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private static func preferredReport(in reports: [StoredProviderReport]) -> StoredProviderReport? {
        reports.max { lhs, rhs in
            if lhs.generatedAt != rhs.generatedAt {
                return lhs.generatedAt < rhs.generatedAt
            }
            let lhsObservedAt = lhs.resetCredits?.observedAt ?? .distantPast
            let rhsObservedAt = rhs.resetCredits?.observedAt ?? .distantPast
            if lhsObservedAt != rhsObservedAt {
                return lhsObservedAt < rhsObservedAt
            }
            return lhs.accountID > rhs.accountID
        }
    }
}

func shouldShowProviderNavigation(
    provider: Provider,
    summaries: [MainLimitSummary],
    reports: [StoredProviderReport]
) -> Bool {
    if !summaries.isEmpty {
        return true
    }
    guard provider == .openAI else {
        return false
    }
    return reports.contains {
        $0.provider == provider && ($0.resetCredits?.availableCount ?? 0) > 0
    }
}

func providerStatusIncludingAccessAlerts(
    provider: Provider,
    baseStatuses: [UsageStatus],
    alerts: [ProviderAccessAlert]
) -> UsageStatus {
    let accessStatuses = alerts
        .filter { $0.provider == provider }
        .map(\.status)
    let statuses = baseStatuses + accessStatuses
    return statuses.isEmpty ? .unknown : statuses.contextPanelWorstStatus
}

struct HeaderCard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    let keepWorkingForecast: KeepWorkingForecast

    private var answerSelection: MainLimitAnswerSelection {
        model.widgetPreferences.mainLimitAnswerSelection(from: snapshot.mainLimitSummaries)
    }

    private var primaryLane: WidgetMainLimitLane? {
        answerSelection.primary
    }

    private var primarySummary: MainLimitSummary? {
        if let activeWindow = keepWorkingForecast.activeWindow,
           let forecastSummary = snapshot.mainLimitSummaries.first(where: {
               $0.provider == .openAI && $0.window == activeWindow
           }) {
            return forecastSummary
        }
        return primaryLane?.summary
    }

    private var closestSummary: MainLimitSummary? {
        answerSelection.closest?.summary
    }

    private var closestStatus: UsageStatus {
        guard let closestSummary else { return .unknown }
        return displayStatus(source: providerStatusIncludingAccessAlerts(
            provider: closestSummary.provider,
            baseStatuses: [closestSummary.status],
            alerts: model.providerAccessAlerts
        ))
    }

    private var primaryStatus: UsageStatus {
        guard let provider = primarySummary?.provider else {
            return displayStatus(source: .unknown)
        }
        return displayStatus(source: providerStatusIncludingAccessAlerts(
            provider: provider,
            baseStatuses: primarySummary.map { [$0.status] } ?? [],
            alerts: model.providerAccessAlerts
        ))
    }

    private var resetCreditSummary: ProviderResetCreditSurfaceSummary? {
        ResetCreditSurfaceAdvisor.appSummary(
            reports: model.storedSnapshot?.reports ?? [],
            limits: snapshot.limits,
            now: Date()
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(keepWorkingForecast.remainingPercent == nil ? snapshot.headline : keepWorkingForecast.promptCopy)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(1)
                Text(keepWorkingForecast.accountCount > 0
                    ? "OpenAI · \(keepWorkingForecast.accountCopy) combined"
                    : snapshot.subheadline)
                    .font(.system(size: 13))
                    .foregroundStyle(CPTheme.secondaryText)
                if keepWorkingForecast.remainingPercent != nil,
                   let outcome = keepWorkingForecast.outcomeCopy(density: .full) {
                    Text(outcome)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(CPTheme.statusColor(
                            keepWorkingForecast.isLimited
                                ? .limited
                                : keepWorkingForecast.paceBand == .over ? .close : .healthy
                        ))
                }
                if let reset = keepWorkingForecast.resetCopy(density: .full) {
                    Text(reset)
                        .font(.system(size: 12))
                    .foregroundStyle(CPTheme.secondaryText)
                }
                if keepWorkingForecast.remainingPercent == nil {
                    Text(model.fastModeForecast.copy)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(CPTheme.secondaryText)
                }
                HStack(spacing: 8) {
                    if let recentUse = keepWorkingForecast.recentUsedCopy(density: .full) {
                        TagLabel(recentUse)
                    }
                    TagLabel("\(snapshot.mainLimitSummaries.count) windows")
                    if let resetCreditSummary {
                        ResetCreditAvailabilityTag(summary: resetCreditSummary)
                    }
                    if model.storeStatus != .healthy {
                        TagLabel(model.storeStatus.previewStatusText.capitalized)
                    }
                }
            }
            Spacer(minLength: 16)
            VStack(spacing: 8) {
                MetricDial(
                    metric: .remainingCapacity(remainingRatio: primarySummary?.remainingCapacityRatio),
                    status: primaryStatus,
                    accessibilityName: primarySummary.map {
                        "Main limit, \($0.provider.displayName), \($0.window.displayName), remaining capacity"
                    } ?? "Main limit remaining capacity",
                    sublabel: "left",
                    size: 116
                )
                Text(primarySummary.map { "\($0.provider.displayName) · \($0.window.displayName)" } ?? "No limits selected")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 180)
                if let closestSummary {
                    Divider()
                        .frame(width: 168)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            StatusMark(status: closestStatus, size: 7)
                            Text("Closest to limit")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CPTheme.primaryText)
                        }
                        Text(
                            "\(closestSummary.provider.displayName) · \(closestSummary.previewWindowName) · \(closestSummary.previewRemainingHeadline)"
                        )
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(CPTheme.secondaryText)
                        .lineLimit(2)
                    }
                    .frame(width: 180, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Closest to limit")
                    .accessibilityValue(
                        "\(closestSummary.provider.displayName), \(closestSummary.previewWindowName), \(closestSummary.previewRemainingHeadline), \(closestStatus.accessibilityStatusText)"
                    )
                }
            }
        }
        .padding(22)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 14, x: 0, y: 8)
    }

    private func displayStatus(source: UsageStatus) -> UsageStatus {
        switch model.storeStatus {
        case .failure:
            .failure
        case .stale:
            .stale
        case .loading:
            .loading
        case .healthy, .close, .limited, .unknown:
            source
        }
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

    private var providerStatus: UsageStatus {
        providerStatusIncludingAccessAlerts(
            provider: provider,
            baseStatuses: summaries.map(\.status),
            alerts: model.providerAccessAlerts
        )
    }

    private var resetCreditSummary: ProviderResetCreditSurfaceSummary? {
        guard provider == .openAI else { return nil }
        return ResetCreditSurfaceAdvisor.appSummary(
            reports: model.storedSnapshot?.reports ?? [],
            limits: summaries.flatMap(\.limits),
            now: Date()
        )
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
                    if let resetCreditSummary {
                        ResetCreditAvailabilityTag(summary: resetCreditSummary)
                    }
                    if model.storeStatus != .healthy {
                        TagLabel(model.storeStatus.previewStatusText.capitalized)
                    }
                }
            }
            Spacer(minLength: 16)
            if let tightestSummary {
                MetricDial(
                    metric: .remainingCapacity(remainingRatio: tightestSummary.remainingCapacityRatio),
                    status: providerStatus,
                    accessibilityName: "\(provider.displayName) \(tightestSummary.previewWindowName) \(tightestSummary.accountText) remaining capacity",
                    sublabel: "remaining",
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
                title: "Saved usage",
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
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.primaryErrorStatusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CPTheme.statusColor(.failure))
                        .lineLimit(1)
                    if let detail = model.primaryErrorDetailText {
                        Text(detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(CPTheme.secondaryText)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: 420, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .help(errorMessage)
            }
        }
        .padding(14)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 10))
    }
}

struct ProviderAccessAlertsSection: View {
    let alerts: [ProviderAccessAlert]

    var body: some View {
        if !alerts.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Provider Access", trailing: alerts.count == 1 ? "1 account" : "\(alerts.count) accounts")
                ForEach(alerts) { alert in
                    ProviderAccessAlertCard(alert: alert)
                }
            }
        }
    }
}

private struct ProviderAccessAlertCard: View {
    let alert: ProviderAccessAlert

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CPTheme.statusColor(alert.status))
                .frame(width: 28, height: 28)
                .background(CPTheme.statusColor(alert.status).opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(alert.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                Text(alert.accountName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .lineLimit(1)
                Text(alert.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.secondaryText)
                if let resetText = alert.resetDisplayText() {
                    Text("Plan access resets \(resetText)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPTheme.secondaryText)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(CPTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(CPTheme.stroke(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
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

    private var accessibilityLabel: String {
        var components = [alert.title, alert.accountName, alert.detail]
        if let resetText = alert.resetAccessibilityText() {
            components.append("Plan access resets at \(resetText)")
        }
        return components.joined(separator: ". ")
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
                UsagePressureBar(
                    usedRatio: snapshot.tightestMainLimitSummary?.usageRatio,
                    status: snapshot.aggregateStatus,
                    height: 6
                )
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
                    UsagePressureBar(
                        usedRatio: snapshot.tightestMainLimitSummary?.usageRatio,
                        status: snapshot.aggregateStatus,
                        height: 6
                    )
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
    let presentationDate: Date

    init(
        model: ContextPanelAppModel,
        summary: MainLimitSummary,
        generatedAt: Date,
        presentationDate: Date = Date()
    ) {
        self.model = model
        self.summary = summary
        self.generatedAt = generatedAt
        self.presentationDate = presentationDate
    }

    private var providerAccessAlerts: [ProviderAccessAlert] {
        model.providerAccessAlerts.filter { $0.provider == summary.provider }
    }

    private var presentationStatus: UsageStatus {
        providerStatusIncludingAccessAlerts(
            provider: summary.provider,
            baseStatuses: [summary.status],
            alerts: providerAccessAlerts
        )
    }

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
                    StatusMark(status: presentationStatus, size: 10)
                        .accessibilityHidden(true)
                }

                ProviderAccessAlertsSection(alerts: providerAccessAlerts)

                HStack(alignment: .top, spacing: 18) {
                    MetricDial(
                        metric: .remainingCapacity(remainingRatio: summary.remainingCapacityRatio),
                        status: presentationStatus,
                        accessibilityName: "\(summary.provider.displayName) \(summary.previewWindowName) remaining capacity",
                        sublabel: "remaining",
                        displayText: summary.detailRemainingValue,
                        accessibilityValue: summary.detailRemainingAccessibilityValue(status: presentationStatus),
                        size: 140
                    )
                    .frame(width: 180)
                    .assumedResetHelp(summary.hasAssumedScheduledResetCapacity)

                    DetailCard(title: "Forecast") {
                        Text(forecastCopy)
                            .font(.system(size: 15, weight: .medium))
                        Text("Fast mode spends about 2× capacity for about 1.5× throughput.")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.secondaryText)
                        Text("Confidence: \(summary.confidence.rawValue)")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                }

                DetailCard(title: "Accounts") {
                    ForEach(summary.previewLimits) { limit in
                        MainLimitAccountRow(limit: limit, presentationDate: presentationDate)
                    }
                }

                DetailCard(title: "Pooled capacity") {
                    if let caption = summary.pooledCapacityCaption {
                        Text(caption)
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    DetailRow(label: "Remaining", value: summary.detailRemainingText)
                    DetailRow(label: "Used", value: summary.detailUsedValue)
                    DetailRow(label: summary.detailPoolLabel, value: summary.detailLimitValue)
                    DetailRow(label: "Status", value: presentationStatus.accessibilityStatusText)
                    DetailRow(label: "Updated", value: summary.lastUpdatedAt.map(model.relativeTime) ?? "unknown")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summary.pooledCapacityAccessibilityLabel)
                .accessibilityValue(summary.pooledCapacityAccessibilityValue(
                    updatedText: summary.lastUpdatedAt.map(model.relativeTime) ?? "unknown",
                    status: presentationStatus
                ))
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
                now: presentationDate,
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
    let presentationDate: Date

    init(limit: UsageLimit, presentationDate: Date = Date()) {
        self.limit = limit
        self.presentationDate = presentationDate
    }

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
                    .assumedResetHelp(limit.isAssumedAfterScheduledReset)
                Text(limit.previewResetConfidenceText(relativeTo: presentationDate))
                    .font(.system(size: 10))
                    .foregroundStyle(CPTheme.tertiaryText)
            }
        }
        .padding(10)
        .background(CPTheme.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(limit.mainLimitAccessibilityLabel)
        .accessibilityValue(limit.remainingCapacityAccessibilityValue)
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

private extension View {
    @ViewBuilder
    func assumedResetHelp(_ isAssumed: Bool) -> some View {
        if isAssumed {
            help(UsagePresentationAssumption.scheduledReset.accessibilityText)
        } else {
            self
        }
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
    var status: UsageStatus? = nil

    private var presentationStatus: UsageStatus {
        status ?? summary.status
    }

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
                    UsagePressureBar(usedRatio: summary.usageRatio, status: presentationStatus)
                    Text(compact ? summary.resetText : summary.previewResetConfidenceText)
                        .font(.system(size: 10))
                        .foregroundStyle(presentationStatus == .stale ? CPTheme.statusColor(.stale) : CPTheme.tertiaryText)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.quantitativeAccessibilityLabel)
        .accessibilityValue(summary.usedPressureAccessibilityValue(status: presentationStatus))
    }
}

@MainActor
final class ContextPanelAppModel: ObservableObject {
    @Published private(set) var storedSnapshot: StoredUsageSnapshot?
    @Published private(set) var storeStatus: UsageStatus = .unknown
    @Published private(set) var historyCount: Int = 0
    @Published private(set) var configuredAccounts: [LocalProviderAccountConfiguration] = []
    @Published private(set) var widgetPreferences: WidgetDisplayPreferences = .defaultPreferences
    @Published private(set) var fastModeForecastSettings: FastModeForecastSettings = .defaultSettings
    @Published private(set) var observedBurnRates: [String: ObservedBurnRate] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshAt: Date?
    @Published private(set) var navigationRequest: AppNavigationSelection?
    private var isDeliveringPendingLimitWarnings = false
    private var pendingLimitWarningDeliveryRequested = false
    private var observedBurnRatesTask: Task<Void, Never>?

    private let refreshService: SnapshotRefreshService
    private let refreshRunner: SnapshotRefreshRunner
    private let forecastSettingsStore = FastModeForecastSettingsStore(
        settingsURL: ContextPanelLocations.fastModeForecastSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let widgetPreferencesStore = WidgetDisplayPreferencesStore(
        preferencesURL: ContextPanelLocations.widgetDisplayPreferencesURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private let refreshDiagnosticsStore = RefreshDiagnosticsStateStore(
        stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
    )
    private lazy var limitWarningNotificationService = AppLimitWarningNotificationService.appDefault()
    private let refreshAttentionPolicyCache = SnapshotStoreStalenessPolicyCache(
        initialPolicy: SnapshotStoreStalenessPolicy(maximumAge: SnapshotFreshness.appMaximumAge),
        loadPolicy: {
            SnapshotStoreStalenessPolicy.appDefault(maximumAge: SnapshotFreshness.appMaximumAge)
        }
    )
    private let runtimeReceiptRecorder: RuntimeReceiptRecorder
    private let runtimeReceiptRelay: RuntimeReceiptRelayCoordinator?
    private let fixedPresentationDate: Date?

    private var presentationDate: Date {
        fixedPresentationDate ?? Date()
    }

    private var observedSnapshot: UsageSnapshot {
        storedSnapshot?.snapshot ?? UsageSnapshot(generatedAt: presentationDate, limits: [])
    }

    var currentSnapshot: UsageSnapshot {
        observedSnapshot.presented(at: presentationDate)
    }

    var fastModeForecast: FastModeCapacityPortfolioForecast {
        currentSnapshot.mainLimitSummaries.openAIFastModeCapacityForecast(
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings
        )
    }

    var promptCacheSummary: PromptCacheSummary {
        PromptCacheSummary(
            observations: storedSnapshot?.promptCacheObservations ?? [],
            now: presentationDate
        )
    }

    var providerAccessAlerts: [ProviderAccessAlert] {
        guard let storedSnapshot else { return [] }
        return storedSnapshot.providerAccessAlerts(
            stalenessPolicy: refreshAttentionPolicyCache.policy,
            now: presentationDate
        )
    }

    var lastRefreshText: String {
        lastRefreshAt.map(relativeTime) ?? "not yet"
    }

    var primaryErrorStatusText: String {
        if let report = primaryProviderReportNeedingAttention {
            if report.hasProviderConfigurationFailure {
                return "Fix \(report.provider.displayName) setup"
            }
            return "\(report.provider.displayName) needs attention"
        }
        return switch storeStatus {
        case .failure:
            "Reconnect account"
        case .stale:
            hasProviderReconnectIssue ? "Reconnect account" : refreshAttentionSummary?.refreshNeededTitle ?? "Refresh needed"
        case .unknown:
            "Awaiting data; see Settings"
        default:
            "Needs attention; see Settings"
        }
    }

    var primaryErrorDetailText: String? {
        if let report = primaryProviderReportNeedingAttention {
            if let errorMessage = report.userFacingErrorMessage, !errorMessage.isEmpty {
                return errorMessage
            }
            if report.hasProviderConfigurationFailure {
                return "Check the app configuration, then refresh."
            }
            if report.status == .failure {
                return "Reconnect this account, then refresh."
            }
            return "Refresh now, then check the provider status if it persists."
        }
        if let refreshAttentionSummary, storeStatus == .stale {
            return refreshAttentionSummary.refreshNeededDetail
        }
        return nil
    }

    var shouldShowReconnectNavigation: Bool {
        storeStatus == .failure || storeStatus == .stale || !providerReportsNeedingAttention.isEmpty
    }

    var attentionNavigationTitle: String {
        if let report = primaryProviderReportNeedingAttention, report.status == .failure {
            if report.hasProviderConfigurationFailure {
                return "Fix \(report.provider.displayName) setup"
            }
            if report.provider == .google,
               let errorMessage = report.userFacingErrorMessage,
               !errorMessage.isEmpty {
                return "\(report.provider.displayName) needs attention"
            }
            return "Reconnect \(report.provider.displayName)"
        }
        if storeStatus == .failure || hasProviderReconnectIssue {
            return "Reconnect account"
        }
        return refreshAttentionSummary?.refreshNeededTitle ?? "Refresh needed"
    }

    var reconnectSummaryText: String {
        if let report = primaryProviderReportNeedingAttention {
            let target = "\(report.provider.displayName) · \(report.accountName)"
            if report.hasProviderConfigurationFailure {
                return "\(target) needs provider setup. Check the app configuration, then refresh."
            }
            if let errorMessage = report.userFacingErrorMessage, !errorMessage.isEmpty {
                return "\(target) needs attention: \(errorMessage)"
            }
            if report.status == .failure {
                return "\(target) needs attention. Reconnect this account, then refresh."
            }
            return "\(target) needs attention. Refresh now, then check the provider status if it persists."
        }
        if let refreshAttentionSummary, storeStatus == .stale {
            return refreshAttentionSummary.refreshNeededDetail
        }
        if storeStatus == .stale {
            if hasProviderReconnectIssue {
                return "The widget is showing old percentages. Reconnect the affected account, then refresh."
            }
            return "The widget is showing old percentages. Refresh Context Panel to update the data."
        }
        if storeStatus == .failure {
            return "The latest refresh failed. Reconnect the affected account, then refresh."
        }
        if !providerReportsNeedingAttention.isEmpty {
            return "One or more provider refreshes need attention. Reconnect the affected account, then refresh."
        }
        return "Refresh is healthy right now."
    }

    var emptyAttentionActionText: String {
        if isRefreshing {
            return "Refresh is running. This should clear when providers return fresh data."
        }
        if storeStatus == .stale,
           refreshAttentionSummary != nil,
           providerReportsNeedingAttention.isEmpty {
            return "No account reconnect is needed for this state. Refresh Context Panel to update expired reset windows; if this persists, check provider diagnostics in Settings."
        }
        return "No account reconnect is available for this state. Try Refresh now; if this persists, check provider diagnostics in Settings."
    }

    var refreshAttentionSummary: RefreshAttentionSummary? {
        refreshAttentionPolicyCache.policy.refreshAttentionSummary(
            for: storedSnapshot,
            now: presentationDate
        )
    }

    var providerReportsNeedingAttention: [StoredProviderReport] {
        guard let storedSnapshot else { return [] }
        return storedSnapshot.reports.reconnectBlockingFailures(coveredBy: storedSnapshot.snapshot.limits)
            + storedSnapshot.reports.filter(\.needsNonFailureRefreshAttention)
    }

    private var primaryProviderReportNeedingAttention: StoredProviderReport? {
        providerReportsNeedingAttention.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status.attentionSortRank > rhs.status.attentionSortRank }
            if lhs.provider != rhs.provider { return lhs.provider.displayName < rhs.provider.displayName }
            return lhs.accountName < rhs.accountName
        }.first
    }

    var hasProviderReconnectIssue: Bool {
        guard let storedSnapshot else { return false }
        return !storedSnapshot.reports.reconnectBlockingFailures(coveredBy: storedSnapshot.snapshot.limits).isEmpty
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
                    detail: report.userFacingErrorMessage
                )
            } ?? []
    }

    init(
        refreshService: SnapshotRefreshService? = nil,
        runtimeReceiptRecorder: RuntimeReceiptRecorder = .appDefault(surface: .macOSApp),
        runtimeReceiptRelay: RuntimeReceiptRelayCoordinator? = nil,
        enablesRuntimeReceiptRelay: Bool = true,
        fixedPresentationDate: Date? = nil
    ) {
        let resolvedRefreshService = refreshService ?? .appDefault(
            companionRemoteStore: CompanionCloudKitSyncStoreFactory.make()
        )
        self.refreshService = resolvedRefreshService
        refreshRunner = SnapshotRefreshRunner(service: resolvedRefreshService)
        self.runtimeReceiptRecorder = runtimeReceiptRecorder
        self.fixedPresentationDate = fixedPresentationDate
        self.runtimeReceiptRelay = enablesRuntimeReceiptRelay
            ? runtimeReceiptRelay ?? .appDefaultPublisher(
                remoteStore: RuntimeReceiptCloudKitStoreFactory.make()
            )
            : nil
    }

    static func validationFixture(context: ValidationGalleryContext) -> ContextPanelAppModel {
        let validationDirectory = FileManager.default.temporaryDirectory.appending(
            path: "ContextPanelValidationGallery",
            directoryHint: .isDirectory
        )
        let refreshService = SnapshotRefreshService(
            accountStore: AccountConfigurationStore(
                configurationURL: validationDirectory.appending(path: "accounts.json")
            ),
            stores: SnapshotRefreshStores(
                primary: JSONSnapshotStore(rootDirectory: validationDirectory)
            ),
            promptCacheTelemetryMirror: { _, _ in },
            promptCacheTelemetryReader: { _ in [] }
        )
        let model = ContextPanelAppModel(
            refreshService: refreshService,
            runtimeReceiptRecorder: .disabled(),
            enablesRuntimeReceiptRelay: false,
            fixedPresentationDate: context.presentationDate
        )
        model.storedSnapshot = context.storedSnapshot
        model.storeStatus = context.snapshot.status
        model.historyCount = 3
        model.widgetPreferences = context.displayPreferences
        model.fastModeForecastSettings = context.snapshot.fastModeForecastSettings
        model.observedBurnRates = context.snapshot.observedBurnRates
        model.errorMessage = context.snapshot.syncErrorMessage
        model.lastRefreshAt = context.snapshot.generatedAt
        return model
    }

    func loadSnapshot(reloadWidgetTimelines: Bool = true) {
        fastModeForecastSettings = forecastSettingsStore.load()
        widgetPreferences = widgetPreferencesStore.load()
        let accounts = refreshService.loadConfiguredAccounts().document.accounts
        configuredAccounts = accounts
        let refreshAttentionPolicy = refreshAttentionPolicyCache.reload()
        let result = refreshService.loadCurrent(
            policy: refreshAttentionPolicy,
            now: Date()
        )
        storedSnapshot = result.snapshot
        lastRefreshAt = result.snapshot?.savedAt
        storeStatus = result.status
        if let loadErrorMessage = result.errorMessage, !loadErrorMessage.isEmpty {
            errorMessage = loadErrorMessage
        } else if let attentionMessage = primaryProviderReportNeedingAttention?.userFacingErrorMessage,
                  !attentionMessage.isEmpty {
            errorMessage = attentionMessage
        } else {
            errorMessage = nil
        }
        historyCount = refreshService.historyCount()
        refreshObservedBurnRates()
        recordRuntimeReceipt(result)
        if reloadWidgetTimelines {
            reloadContextPanelWidgetTimeline()
        }
    }

    private func recordRuntimeReceipt(_ result: SnapshotStoreLoadResult) {
        let stateBranch: RuntimeReceiptStateBranch
        if result.snapshot == nil {
            stateBranch = result.status == .failure ? .failure : .setupNeeded
        } else {
            stateBranch = switch result.status {
            case .failure:
                .failure
            case .stale:
                .stale
            case .healthy, .close, .limited:
                .ready
            case .loading, .unknown:
                .unknown
            }
        }
        let outcome: RuntimeReceiptOutcome = switch stateBranch {
        case .ready:
            .success
        case .failure:
            .failure
        case .setupNeeded, .stale, .unknown, .refreshed, .skippedFresh,
             .skippedAlreadyRunning, .skippedNoReports:
            .degraded
        }
        runtimeReceiptRecorder.record(
            trigger: .appSnapshotLoad,
            presentationMode: .appOverview,
            selectedSource: result.snapshot == nil ? .none : .appGroupSnapshot,
            presentationDigest: RuntimePresentationDigest.storedSnapshot(
                result.snapshot,
                status: result.status
            ),
            stateBranch: stateBranch,
            outcome: outcome
        )
        guard let runtimeReceiptRelay else { return }
        Task {
            _ = await runtimeReceiptRelay.synchronize()
        }
    }

    private func refreshObservedBurnRates(now: Date = Date()) {
        observedBurnRatesTask?.cancel()
        let refreshService = refreshService
        let currentSnapshot = observedSnapshot
        let generatedAt = currentSnapshot.generatedAt
        observedBurnRatesTask = Task.detached(priority: .userInitiated) { [weak self] in
            let history = refreshService.loadHistory(
                query: SnapshotStoreQuery(since: now.addingTimeInterval(-24 * 3_600))
            )
            guard !Task.isCancelled else { return }
            let rates = MainLimitBurnRateEstimator.observedBurnRates(
                current: currentSnapshot,
                history: history,
                now: now
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self?.observedSnapshot.generatedAt == generatedAt else { return }
                self?.observedBurnRates = rates
            }
        }
    }

    func handleOpenURL(_ url: URL) {
        switch url.host?.lowercased() {
        case "settings":
            break
        case "reconnect":
            navigationRequest = .reconnect
        case "overview":
            navigationRequest = .overview
        case "provider":
            let providerValue = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
            guard let provider = Provider(rawValue: providerValue) else {
                navigationRequest = .overview
                return
            }
            let accountID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == "account" }?
                .value
            navigationRequest = accountID.map { .providerAccount(provider, $0) } ?? .provider(provider)
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
        let startedAt = Date()
        let runID = recordRefreshStarted(at: startedAt)

        do {
            let decision = try await refreshRunner.refresh()
            recordRefreshFinished(runID: runID, decision: decision, finishedAt: Date())
            if case .skippedAlreadyRunning = decision {
                loadSnapshot()
                storeStatus = .stale
                errorMessage = "Another refresh is still running. Try again in a moment."
                return
            }
            await limitWarningNotificationService.notifyIfNeeded(decision: decision)
            loadSnapshot()
        } catch {
            recordRefreshFailed(runID: runID, finishedAt: Date(), error: error)
            storeStatus = .failure
            errorMessage = error.localizedDescription
        }
    }

    private func recordRefreshStarted(at startedAt: Date) -> String {
        let runID = UUID().uuidString
        try? refreshDiagnosticsStore.update { state in
            state.recordRunStarted(id: runID, source: .app, at: startedAt)
        }
        return runID
    }

    private func recordRefreshFinished(runID: String, decision: SnapshotRefreshRunDecision, finishedAt: Date) {
        try? refreshDiagnosticsStore.update { state in
            state.recordRunFinished(
                id: runID,
                decision: decision.diagnosticsDecision,
                finishedAt: finishedAt,
                reportCount: decision.diagnosticsReportCount,
                failureCount: decision.diagnosticsFailureCount,
                limitCount: decision.diagnosticsLimitCount,
                savedSnapshotAt: decision.diagnosticsSavedSnapshotAt
            )
        }
    }

    private func recordRefreshFailed(runID: String, finishedAt: Date, error: Error) {
        try? refreshDiagnosticsStore.update { state in
            state.recordRunFinished(
                id: runID,
                decision: .failed,
                finishedAt: finishedAt,
                errorMessage: error.localizedDescription
            )
        }
    }

    func deliverPendingLimitWarnings() async {
        if isDeliveringPendingLimitWarnings {
            pendingLimitWarningDeliveryRequested = true
            return
        }
        isDeliveringPendingLimitWarnings = true
        defer { isDeliveringPendingLimitWarnings = false }
        repeat {
            pendingLimitWarningDeliveryRequested = false
            await limitWarningNotificationService.deliverPendingNotifications()
        } while pendingLimitWarningDeliveryRequested
    }

    func setError(_ message: String) {
        storeStatus = .failure
        errorMessage = ConnectorRedactor.safeErrorDescription(message)
    }

    func relativeTime(_ date: Date) -> String {
        let seconds = max(Int(presentationDate.timeIntervalSince(date)), 0)
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

struct MetricDial: View {
    let metric: MetricProgress
    let status: UsageStatus
    let accessibilityName: String
    let sublabel: String
    var displayText: String? = nil
    var accessibilityValue: String? = nil
    var size: CGFloat = 96
    var thickness: CGFloat = 6

    var body: some View {
        ZStack {
            Circle()
                .stroke(CPTheme.line, lineWidth: thickness)
            if let ratio = metric.ratio {
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(
                        CPTheme.statusColor(status),
                        style: StrokeStyle(lineWidth: thickness, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            } else {
                Circle()
                    .stroke(
                        CPTheme.statusColor(status),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                    )
            }
            VStack(spacing: 0) {
                Text(displayText ?? metric.percentText)
                    .font(.system(size: size > 100 ? 30 : 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPTheme.primaryText)
                Text(sublabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPTheme.tertiaryText)
                    .textCase(.uppercase)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(accessibilityValue ?? (metric.isIndeterminate ? metric.accessibilityValue : "\(metric.accessibilityValue), \(status.accessibilityStatusText)"))
    }
}

private struct AppLimitWarningNotificationService {
    let settingsStore: LimitWarningSettingsStore
    let stateStore: LimitWarningStateStore
    let pendingNotificationStore: LimitWarningPendingNotificationStore
    let webhookService: LimitWarningWebhookDeliveryService
    let notificationCenter: UNUserNotificationCenter
    let diagnosticsStore: RefreshDiagnosticsStateStore

    static func appDefault() -> AppLimitWarningNotificationService {
        AppLimitWarningNotificationService(
            settingsStore: LimitWarningSettingsStore(
                settingsURL: ContextPanelLocations.limitWarningSettingsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            stateStore: LimitWarningStateStore(
                stateURL: ContextPanelLocations.limitWarningStateURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            pendingNotificationStore: LimitWarningPendingNotificationStore(
                queueURL: ContextPanelLocations.limitWarningPendingNotificationsURL(appGroupID: ContextPanelLocations.appGroupID)
            ),
            webhookService: .appDefault(),
            notificationCenter: .current(),
            diagnosticsStore: RefreshDiagnosticsStateStore(
                stateURL: ContextPanelLocations.refreshDiagnosticsStateURL(appGroupID: ContextPanelLocations.appGroupID)
            )
        )
    }

    func notifyIfNeeded(decision: SnapshotRefreshRunDecision) async {
        let webhookResults = await webhookService.deliverIfNeeded(decision: decision)
        recordWebhookDiagnostics(webhookResults, attemptedAt: Date())
        guard case let .refreshed(outcome) = decision else { return }
        let settings = settingsStore.load()
        let state = stateStore.load()
        let warningSnapshot = LimitWarningSnapshotResolver.effectiveSnapshot(
            transientSnapshot: outcome.refreshResult.snapshot,
            persistedSnapshot: loadPersistedSnapshot()
        )
        let presentationSnapshot = warningSnapshot.presented(at: outcome.savedAt)
        prunePendingNotifications(for: presentationSnapshot)
        let result = LimitWarningEvaluator.evaluate(
            settings: settings,
            state: state,
            snapshot: presentationSnapshot,
            now: outcome.savedAt
        )
        recordAlertEvaluation(at: outcome.savedAt, eventCount: result.events.count)
        var commitPlan = LimitWarningNotificationCommitPlan(
            currentState: state,
            targetState: result.state,
            snapshot: presentationSnapshot,
            settings: settings
        )
        guard commitPlan.hasPendingChanges else { return }
        if commitPlan.hasPersistedStateChanges {
            do {
                try stateStore.save(commitPlan.persistedState)
            } catch {
                contextPanelLogger.error("limit warning state save failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
            }
        }
        if result.events.isEmpty {
            return
        }

        if !result.events.isEmpty {
            guard await notificationsAreAuthorized() else {
                recordLocalNotificationDiagnostics(
                    attemptedAt: outcome.savedAt,
                    succeededAt: nil,
                    eventCount: result.events.count,
                    errorMessage: "notifications are not authorized for Context Panel"
                )
                return
            }
        }
        for event in result.events {
            guard await deliver(event: event, playsSound: settings.playsSound) else {
                recordLocalNotificationDiagnostics(
                    attemptedAt: outcome.savedAt,
                    succeededAt: nil,
                    eventCount: result.events.count,
                    errorMessage: "notification delivery failed"
                )
                return
            }
            commitPlan.commitDeliveredEvent(for: event.laneID)
            do {
                try stateStore.save(commitPlan.persistedState)
            } catch {
                contextPanelLogger.error("limit warning state save failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
            }
        }
        recordLocalNotificationDiagnostics(
            attemptedAt: outcome.savedAt,
            succeededAt: outcome.savedAt,
            eventCount: result.events.count,
            errorMessage: nil
        )
    }

    func deliverPendingNotifications() async {
        let queue = pendingNotificationStore.load()
        guard !queue.notifications.isEmpty else { return }
        let state = stateStore.load()
        let alreadyDeliveredNotifications = queue.notifications.filter { notification in
            state.record(for: notification.id)?.matchesDeliveredNotification(notification) == true
        }
        removePendingNotifications(alreadyDeliveredNotifications)

        let pendingNotifications = queue.notifications.filter { notification in
            !alreadyDeliveredNotifications.contains(notification)
        }
        guard !pendingNotifications.isEmpty else { return }
        guard await notificationsAreAuthorized() else {
            recordLocalNotificationDiagnostics(
                attemptedAt: Date(),
                succeededAt: nil,
                eventCount: pendingNotifications.count,
                errorMessage: "notifications are not authorized for Context Panel"
            )
            contextPanelLogger.error("pending limit warnings could not be delivered: notifications are not authorized for Context Panel")
            return
        }

        var deliveredNotifications: [LimitWarningPendingNotification] = []
        var commitPlan = LimitWarningNotificationCommitPlan(
            currentState: state,
            targetState: pendingTargetState(from: pendingNotifications, currentState: state),
            snapshot: pendingSnapshot(from: pendingNotifications),
            settings: settingsStore.load(),
            prunesMissingLanes: false
        )
        for notification in pendingNotifications {
            if await deliver(event: notification.event, playsSound: notification.playsSound) {
                var deliveredCommitPlan = commitPlan
                deliveredCommitPlan.commitDeliveredEvent(for: notification.id)
                do {
                    try stateStore.save(deliveredCommitPlan.persistedState)
                    commitPlan = deliveredCommitPlan
                    deliveredNotifications.append(notification)
                } catch {
                    contextPanelLogger.error("limit warning state save failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
                }
            }
        }
        removePendingNotifications(deliveredNotifications)
        recordLocalNotificationDiagnostics(
            attemptedAt: Date(),
            succeededAt: deliveredNotifications.isEmpty ? nil : Date(),
            eventCount: pendingNotifications.count,
            errorMessage: deliveredNotifications.isEmpty ? "no pending notifications delivered" : nil
        )
    }

    private func recordAlertEvaluation(at evaluatedAt: Date, eventCount: Int) {
        try? diagnosticsStore.update { state in
            state.recordAlertEvaluation(at: evaluatedAt, eventCount: eventCount)
        }
    }

    private func recordLocalNotificationDiagnostics(
        attemptedAt: Date,
        succeededAt: Date?,
        eventCount: Int,
        errorMessage: String?
    ) {
        try? diagnosticsStore.update { state in
            state.recordAlert(RefreshDiagnosticsAlertRecord(
                channel: .localNotification,
                attemptedAt: attemptedAt,
                succeededAt: succeededAt,
                eventCount: eventCount,
                errorMessage: errorMessage
            ))
        }
    }

    private func recordWebhookDiagnostics(_ results: [LimitWarningWebhookDeliveryResult], attemptedAt: Date) {
        guard let summary = LimitWarningWebhookDeliverySummary(results: results) else { return }
        try? diagnosticsStore.update { state in
            state.recordAlert(RefreshDiagnosticsAlertRecord(
                channel: .webhook,
                attemptedAt: attemptedAt,
                succeededAt: summary.succeeded ? attemptedAt : nil,
                eventCount: summary.eventCount,
                lastHTTPStatus: summary.lastHTTPStatus,
                errorMessage: summary.errorMessage
            ))
        }
    }

    private func removePendingNotifications(_ notifications: [LimitWarningPendingNotification]) {
        guard !notifications.isEmpty else { return }
        do {
            var updatedQueue = pendingNotificationStore.load()
            updatedQueue.remove(notifications)
            try pendingNotificationStore.save(updatedQueue)
        } catch {
            contextPanelLogger.error("pending limit warning queue update failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
        }
    }

    private func prunePendingNotifications(for snapshot: UsageSnapshot) {
        do {
            var queue = pendingNotificationStore.load()
            let previousCount = queue.notifications.count
            queue.removeNotifications(forMissing: Set(snapshot.mainLimitSummaries.map(\.id)))
            guard queue.notifications.count != previousCount else { return }
            try pendingNotificationStore.save(queue)
        } catch {
            contextPanelLogger.error("pending limit warning queue pruning failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
        }
    }

    private func notificationsAreAuthorized() async -> Bool {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    private func loadPersistedSnapshot() -> StoredUsageSnapshot? {
        JSONSnapshotStore(
            rootDirectory: ContextPanelLocations.snapshotDirectory(appGroupID: ContextPanelLocations.appGroupID)
        ).loadCurrent().snapshot
    }

    private func pendingTargetState(
        from notifications: [LimitWarningPendingNotification],
        currentState: LimitWarningState
    ) -> LimitWarningState {
        var state = currentState
        for notification in notifications {
            let event = notification.event
            state.upsert(LimitWarningRecord(
                laneID: event.laneID,
                lastThresholdPercentRemaining: event.thresholdPercentRemaining,
                lastNotifiedAt: notification.queuedAt,
                lastCapacityRatio: event.capacityRatio,
                resetIdentity: event.resetsAt.map { String(Int($0.timeIntervalSince1970)) }
            ))
        }
        return state
    }

    private func pendingSnapshot(from notifications: [LimitWarningPendingNotification]) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: notifications.last?.queuedAt ?? Date(),
            limits: []
        )
    }

    @discardableResult
    private func deliver(event: LimitWarningEvent, playsSound: Bool) async -> Bool {
        await deliver(event.notificationPresentation(playsSound: playsSound))
    }

    @discardableResult
    private func deliver(_ presentation: LimitWarningNotificationPresentation) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        if presentation.playsSound {
            content.sound = .default
        }
        let request = UNNotificationRequest(
            identifier: presentation.identifier,
            content: content,
            trigger: nil
        )
        do {
            try await notificationCenter.add(request)
            return true
        } catch {
            contextPanelLogger.error("limit warning notification failed: \(ConnectorRedactor.safeErrorDescription(error), privacy: .private)")
            return false
        }
    }
}

struct UsagePressureBar: View {
    let usedRatio: Double?
    let status: UsageStatus
    var height: CGFloat = 4

    private var metric: MetricProgress {
        .usedPressure(usedRatio: usedRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(CPTheme.line)
                if let ratio = metric.ratio {
                    Capsule()
                        .fill(CPTheme.statusColor(status))
                        .frame(width: proxy.size.width * ratio)
                } else {
                    Capsule()
                        .stroke(
                            CPTheme.statusColor(status),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage pressure")
        .accessibilityValue(metric.accessibilityValue)
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

private struct ResetCreditAvailabilityTag: View {
    let summary: ProviderResetCreditSurfaceSummary
    @State private var isHovering = false

    private var tone: Color {
        summary.isLastSeenOnly ? CPTheme.statusColor(.stale) : CPTheme.accent
    }

    private var destination: URL {
        URL(string: "contextpanel://provider/\(summary.provider.rawValue)")!
    }

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.counterclockwise.circle")
                    .font(.system(size: 10, weight: .semibold))
                Text(resetCreditTagText(summary))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tone)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tone.opacity(isHovering ? 0.15 : 0.08))
            .clipShape(Capsule())
            .overlay {
                Capsule()
                    .stroke(tone.opacity(isHovering ? 0.42 : 0.18), lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(resetCreditHelpText(summary))
        .accessibilityLabel(resetCreditAccessibilityText(summary))
        .accessibilityHint("Opens OpenAI detail in Context Panel")
        .onHover { isHovering in
            self.isHovering = isHovering
            (isHovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
    }
}

private func resetCreditTagText(_ summary: ProviderResetCreditSurfaceSummary) -> String {
    let prefix = summary.isLastSeenOnly ? "Reset credits last seen" : "Reset credits"
    return "\(prefix) · \(summary.accountCountText)"
}

private func resetCreditHelpText(_ summary: ProviderResetCreditSurfaceSummary) -> String {
    summary.isLastSeenOnly
        ? "Reset credits were last seen on \(summary.accountCountText)."
        : "Reset credits are available on \(summary.accountCountText)."
}

private func resetCreditAccessibilityText(_ summary: ProviderResetCreditSurfaceSummary) -> String {
    summary.isLastSeenOnly
        ? "Reset credits were last seen on \(summary.providerAccountCountText)."
        : "Reset credits are available on \(summary.providerAccountCountText)."
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
        light: NSColor(red: 105 / 255, green: 105 / 255, blue: 113 / 255, alpha: 1),
        dark: NSColor(red: 151 / 255, green: 154 / 255, blue: 164 / 255, alpha: 1)
    )
    static let accent = adaptiveColor(
        light: NSColor(red: 74 / 255, green: 91 / 255, blue: 122 / 255, alpha: 1),
        dark: NSColor(red: 137 / 255, green: 161 / 255, blue: 211 / 255, alpha: 1)
    )

    static func providerColor(_ provider: Provider) -> Color {
        switch provider {
        case .openAI:
            adaptiveColor(
                light: NSColor(red: 56 / 255, green: 92 / 255, blue: 126 / 255, alpha: 1),
                dark: NSColor(red: 107 / 255, green: 164 / 255, blue: 218 / 255, alpha: 1)
            )
        case .anthropic:
            adaptiveColor(
                light: NSColor(red: 139 / 255, green: 102 / 255, blue: 51 / 255, alpha: 1),
                dark: NSColor(red: 220 / 255, green: 174 / 255, blue: 103 / 255, alpha: 1)
            )
        case .google:
            adaptiveColor(
                light: NSColor(red: 35 / 255, green: 116 / 255, blue: 106 / 255, alpha: 1),
                dark: NSColor(red: 83 / 255, green: 183 / 255, blue: 168 / 255, alpha: 1)
            )
        }
    }

    static func statusColor(_ status: UsageStatus) -> Color {
        switch status {
        case .healthy:
            adaptiveColor(
                light: NSColor(red: 61 / 255, green: 111 / 255, blue: 78 / 255, alpha: 1),
                dark: NSColor(red: 102 / 255, green: 181 / 255, blue: 132 / 255, alpha: 1)
            )
        case .close:
            adaptiveColor(
                light: NSColor(red: 125 / 255, green: 91 / 255, blue: 26 / 255, alpha: 1),
                dark: NSColor(red: 217 / 255, green: 173 / 255, blue: 81 / 255, alpha: 1)
            )
        case .limited, .failure:
            adaptiveColor(
                light: NSColor(red: 132 / 255, green: 62 / 255, blue: 62 / 255, alpha: 1),
                dark: NSColor(red: 220 / 255, green: 119 / 255, blue: 119 / 255, alpha: 1)
            )
        case .stale:
            adaptiveColor(
                light: NSColor(red: 112 / 255, green: 84 / 255, blue: 57 / 255, alpha: 1),
                dark: NSColor(red: 194 / 255, green: 158 / 255, blue: 117 / 255, alpha: 1)
            )
        case .unknown, .loading:
            adaptiveColor(
                light: NSColor(red: 90 / 255, green: 90 / 255, blue: 99 / 255, alpha: 1),
                dark: NSColor(red: 170 / 255, green: 173 / 255, blue: 182 / 255, alpha: 1)
            )
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

    var tightestRemainingCapacityRatio: Double? {
        tightestMainLimitSummary?.remainingCapacityRatio
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
        if let roundedRemainingPercent { return "\(assumptionPrefix)\(roundedRemainingPercent)% left" }
        guard let remaining else { return "Unknown" }
        return "\(assumptionPrefix)\(remaining) left"
    }

    var compactUsageText: String {
        guard unit != nil, used != nil, limit != nil else {
            return status == .failure ? "—" : "?"
        }
        if let roundedUsedPercent {
            return "\(assumptionPrefix)\(roundedUsedPercent)% used"
        }
        guard let used, let limit else { return "?" }
        return "\(assumptionPrefix)\(used)/\(limit)"
    }

    var previewUsageText: String {
        guard unit != nil, used != nil, limit != nil else {
            return status == .failure ? "refresh failed" : "unknown"
        }
        if let roundedUsedPercent {
            return "\(assumptionPrefix)\(roundedUsedPercent)% used"
        }
        guard let used, let limit else { return "unknown" }
        return "\(assumptionPrefix)\(used)/\(limit) used"
    }

    var previewWindowLine: String {
        "\(previewWindowName) · \(accountText)"
    }

    var compactPreviewWindowLine: String {
        "\(compactPreviewWindowName) · \(accountText)"
    }

    var sidebarTimingText: String {
        if status == .stale {
            guard let lastUpdatedAt else { return "stale · update time unknown" }
            return "stale · updated \(lastUpdatedAt.widgetRelativeText)"
        }
        return resetText
    }

    var accountText: String {
        accountCount == 1 ? "1 account" : "\(accountCount) accounts"
    }

    var resetText: String {
        if status == .failure { return "refresh failed" }
        if hasAssumedScheduledResetCapacity { return "assumed reset" }
        guard let resetsAt else { return "reset not reported" }
        if resetsAt < Date().addingTimeInterval(-60) { return "reset passed" }
        if resetsAt.shouldShowWidgetDateTime {
            return "resets \(resetsAt.widgetRelativeText) · \(resetsAt.widgetDateTimeText)"
        }
        return "resets \(resetsAt.widgetRelativeText)"
    }

    var previewResetConfidenceText: String {
        if hasAssumedScheduledResetCapacity {
            return UsagePresentationAssumption.scheduledReset.displayText.lowercased()
        }
        return "\(resetText) · \(confidence.previewText)"
    }

    var detailRemainingValue: String {
        if let pooledPercentCapacity {
            return "\(assumptionPrefix)\(pooledPercentCapacity.remainingPercent)%"
        }
        return remaining.map { "\(assumptionPrefix)\($0)" } ?? "?"
    }

    func detailRemainingAccessibilityValue(status: UsageStatus) -> String {
        if let pooledPercentCapacity {
            let value = "\(assumptionAccessibilityPrefix)\(pooledPercentCapacity.remainingPercent) percent remaining, \(status.accessibilityStatusText)"
            return accessibilityValueWithAssumption(value)
        }
        guard let remaining else { return "Remaining capacity unknown" }
        return accessibilityValueWithAssumption(
            "\(assumptionAccessibilityPrefix)\(remaining) \(accessibilityUnitText) remaining, \(status.accessibilityStatusText)"
        )
    }

    var detailUsedValue: String {
        if let pooledPercentCapacity {
            return "\(assumptionPrefix)\(pooledPercentCapacity.usedPoints) pts · \(pooledPercentCapacity.usedPercent)%"
        }
        let value = detailValue(used)
        return hasAssumedScheduledResetCapacity && value != "?" ? "≈\(value)" : value
    }

    var detailLimitValue: String {
        if let pooledPercentCapacity {
            return "\(pooledPercentCapacity.poolPoints) pts"
        }
        return detailValue(limit)
    }

    var detailRemainingText: String {
        if let pooledPercentCapacity {
            return "\(assumptionPrefix)\(pooledPercentCapacity.remainingPoints) pts · \(pooledPercentCapacity.remainingPercent)%"
        }
        let value = detailValue(remaining)
        return hasAssumedScheduledResetCapacity && value != "?" ? "≈\(value)" : value
    }

    var detailPoolLabel: String {
        pooledPercentCapacity == nil ? "Limit" : "Pool"
    }

    var pooledCapacityCaption: String? {
        guard let pooledPercentCapacity else { return nil }
        let scope = pooledCapacityScopeText(pooledPercentCapacity)
        if let pointsPerAccount = pooledPercentCapacity.pointsPerAccount {
            return "\(scope), normalized to \(pointsPerAccount) pts each"
        }
        return "\(scope), \(pooledPercentCapacity.poolPoints) pooled pts total"
    }

    var quantitativeAccessibilityLabel: String {
        "\(provider.displayName), \(previewWindowName), \(accountText)"
    }

    func usedPressureAccessibilityValue(status: UsageStatus) -> String {
        let usage: String
        if let roundedUsedPercent {
            usage = "\(assumptionAccessibilityPrefix)\(roundedUsedPercent) percent used"
        } else if let used, let limit {
            usage = "\(assumptionAccessibilityPrefix)\(used) of \(limit) \(accessibilityUnitText) used"
        } else {
            usage = "Usage unknown"
        }
        if hasAssumedScheduledResetCapacity {
            return "\(usage), \(accessibilityStateText(status: status)). \(UsagePresentationAssumption.scheduledReset.accessibilityText)."
        }
        return "\(usage), \(accessibilityStateText(status: status)). \(resetAccessibilityText). \(confidence.previewText)."
    }

    func pooledCapacityAccessibilityValue(updatedText: String, status: UsageStatus) -> String {
        let capacity: String
        if let pooledPercentCapacity {
            capacity = "\(assumptionAccessibilityPrefix)\(pooledPercentCapacity.remainingPercent) percent remaining, \(pooledPercentCapacity.remainingPoints) of \(pooledPercentCapacity.poolPoints) points. \(assumptionAccessibilityPrefix)\(pooledPercentCapacity.usedPercent) percent used"
        } else {
            capacity = "\(detailRemainingText) remaining. \(detailUsedValue) used. \(detailLimitValue) limit"
        }
        let value = "\(pooledCapacityScopeText(pooledPercentCapacity)). \(capacity). \(accessibilityStateText(status: status)). Updated \(updatedText)."
        return accessibilityValueWithAssumption(value)
    }

    var pooledCapacityAccessibilityLabel: String {
        "Pooled \(provider.displayName) \(previewWindowName) capacity, \(pooledCapacityScopeText(pooledPercentCapacity))"
    }

    var resetAccessibilityText: String {
        if status == .failure { return "Refresh failed" }
        if hasAssumedScheduledResetCapacity {
            return UsagePresentationAssumption.scheduledReset.accessibilityText
        }
        guard let resetsAt else { return "Reset not reported" }
        return resetsAt.accessibilityResetText
    }

    private var assumptionPrefix: String {
        hasAssumedScheduledResetCapacity ? "≈" : ""
    }

    private var assumptionAccessibilityPrefix: String {
        hasAssumedScheduledResetCapacity ? "approximately " : ""
    }

    private func accessibilityValueWithAssumption(_ value: String) -> String {
        guard hasAssumedScheduledResetCapacity else { return value }
        return "\(value). \(UsagePresentationAssumption.scheduledReset.accessibilityText)."
    }

    private func accessibilityStateText(status: UsageStatus) -> String {
        if status == .stale, let lastUpdatedAt {
            return "stale, updated \(lastUpdatedAt.accessibilityAgeText)"
        }
        if status == .stale { return "stale, update time unknown" }
        return status.accessibilityStatusText
    }

    private func pooledCapacityScopeText(_ pooledPercentCapacity: PooledPercentCapacity?) -> String {
        guard let pooledPercentCapacity else { return accountText }
        let contributing = pooledPercentCapacity.contributingAccountCount
        guard contributing != accountCount else { return accountText }
        return "\(contributing) of \(accountCount) accounts contributing"
    }

    private var accessibilityUnitText: String {
        switch unit {
        case .percent:
            return "percentage points"
        case .tokens:
            return "tokens"
        case .requests:
            return "requests"
        case .credits:
            return "credits"
        case .units, .unknown, nil:
            return "units"
        }
    }

    private func detailValue(_ value: Int?) -> String {
        guard let value else { return "unknown" }
        guard let unit else { return "\(value)" }
        switch unit {
        case .percent:
            return "\(value) pts"
        case .tokens:
            return "\(value) tokens"
        case .requests:
            return "\(value) requests"
        case .credits:
            return "\(value) credits"
        case .units, .unknown:
            return "\(value) units"
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
        self
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
        if unit == .percent { return "\(assumptionPrefix)\(remaining)% left" }
        return "\(assumptionPrefix)\(remaining) left"
    }

    var compactUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "unknown"
        }
        guard let used, let limit else { return status == .failure ? "—" : "?" }
        return "\(assumptionPrefix)\(used)/\(limit)"
    }

    var percentText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "unknown"
        }
        guard let usageRatio else { return status == .failure ? "—" : "?" }
        return "\(assumptionPrefix)\(Int(usageRatio * 100))%"
    }

    var previewUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "limit unknown"
        }
        if isModelCapacityLimit {
            return previewRemainingHeadline
        }
        if unit == .percent, let used {
            return "\(assumptionPrefix)\(used)% used"
        }
        if let used, let limit {
            return "\(assumptionPrefix)\(used)/\(limit) used"
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
            return "\(assumptionPrefix)\(used)%"
        }
        guard let used, let limit else { return status == .failure ? "—" : "?" }
        return "\(assumptionPrefix)\(used)/\(limit)"
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

    var mainLimitAccessibilityLabel: String {
        [mainLimitAccountTitle, mainLimitAccountSubtitle]
            .filter { !$0.isEmpty }
            .deduplicated()
            .joined(separator: ", ")
    }

    var remainingCapacityAccessibilityValue: String {
        let capacity: String
        if unit == .percent, let remaining {
            capacity = "\(assumptionAccessibilityPrefix)\(remaining) percent remaining"
        } else if let remaining {
            capacity = "\(assumptionAccessibilityPrefix)\(remaining) \(accessibilityUnitText) remaining"
        } else {
            capacity = "Remaining capacity unknown"
        }
        if isAssumedAfterScheduledReset {
            return "\(capacity), \(accessibilityStateText). \(UsagePresentationAssumption.scheduledReset.accessibilityText)."
        }
        return "\(capacity), \(accessibilityStateText). \(resetAccessibilityText). \(confidence.previewText)."
    }

    private var resetAccessibilityText: String {
        if status == .failure { return "Refresh failed" }
        if isAssumedAfterScheduledReset {
            return UsagePresentationAssumption.scheduledReset.accessibilityText
        }
        guard let resetsAt else { return "Reset not reported" }
        return resetsAt.accessibilityResetText
    }

    private var accessibilityStateText: String {
        if status == .stale, let lastUpdatedAt {
            return "stale, updated \(lastUpdatedAt.accessibilityAgeText)"
        }
        if status == .stale { return "stale, update time unknown" }
        return status.accessibilityStatusText
    }

    private var accessibilityUnitText: String {
        switch unit {
        case .percent:
            return "percentage points"
        case .tokens:
            return "tokens"
        case .requests:
            return "requests"
        case .credits:
            return "credits"
        case .units, .unknown:
            return "units"
        }
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
            return [accountName, windowLabel]
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
        resetText(relativeTo: Date())
    }

    var previewResetConfidenceText: String {
        previewResetConfidenceText(relativeTo: Date())
    }

    func previewResetConfidenceText(relativeTo presentationDate: Date) -> String {
        if isAssumedAfterScheduledReset {
            return UsagePresentationAssumption.scheduledReset.displayText.lowercased()
        }
        return "\(resetText(relativeTo: presentationDate)) · \(confidence.previewText)"
    }

    func resetText(relativeTo presentationDate: Date) -> String {
        if status == .failure { return "refresh failed" }
        if isAssumedAfterScheduledReset { return "assumed reset" }
        guard let resetsAt else { return "reset not reported" }
        if resetsAt < presentationDate.addingTimeInterval(-60) { return "reset passed" }
        if resetsAt.shouldShowWidgetDateTime(relativeTo: presentationDate) {
            return "resets \(resetsAt.widgetRelativeText(relativeTo: presentationDate)) · \(resetsAt.widgetDateTimeText)"
        }
        return "resets \(resetsAt.widgetRelativeText(relativeTo: presentationDate))"
    }

    private var assumptionPrefix: String {
        isAssumedAfterScheduledReset ? "≈" : ""
    }

    private var assumptionAccessibilityPrefix: String {
        isAssumedAfterScheduledReset ? "approximately " : ""
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

    var accessibilityStatusText: String {
        switch self {
        case .healthy:
            "available"
        case .close:
            "close to limit"
        case .limited:
            "limited"
        case .stale:
            "stale"
        case .unknown:
            "unknown"
        case .failure:
            "refresh failed"
        case .loading:
            "refreshing"
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
        widgetRelativeText(relativeTo: Date())
    }

    func widgetRelativeText(relativeTo presentationDate: Date) -> String {
        let seconds = Int(timeIntervalSince(presentationDate))
        if abs(seconds) < 60 { return "now" }
        if seconds >= 0 {
            let minutes = Self.roundedUpMinutes(seconds: seconds)
            if minutes < 60 { return "in \(minutes)m" }
            let hours = Self.roundedUpHours(minutes: minutes)
            if hours <= 24 { return "in \(hours)h" }
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
        shouldShowWidgetDateTime(relativeTo: Date())
    }

    func shouldShowWidgetDateTime(relativeTo presentationDate: Date) -> Bool {
        abs(timeIntervalSince(presentationDate)) >= 24 * 3_600
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

    var accessibilityResetText: String {
        let seconds = Int(timeIntervalSince(Date()))
        if abs(seconds) < 60 { return "Resets now" }
        guard seconds > 0 else { return "Reset passed" }
        let minutes = Self.roundedUpMinutes(seconds: seconds)
        if minutes < 60 {
            return "Resets in \(minutes) \(minutes == 1 ? "minute" : "minutes")"
        }
        let hours = Self.roundedUpHours(minutes: minutes)
        if hours <= 24 {
            return "Resets in \(hours) \(hours == 1 ? "hour" : "hours")"
        }
        let days = max(Int(ceil(Double(hours) / 24)), 1)
        return "Resets in \(days) \(days == 1 ? "day" : "days")"
    }

    var accessibilityAgeText: String {
        let seconds = max(Int(Date().timeIntervalSince(self)), 0)
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) \(minutes == 1 ? "minute" : "minutes") ago"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) \(hours == 1 ? "hour" : "hours") ago"
        }
        let days = hours / 24
        return "\(days) \(days == 1 ? "day" : "days") ago"
    }

    private static func formatDaysAndHours(hours: Int) -> String {
        let days = hours / 24
        let remainingHours = hours % 24
        if remainingHours == 0 {
            return "\(days)d"
        }
        return "\(days)d \(remainingHours)h"
    }

    private static func roundedUpMinutes(seconds: Int) -> Int {
        max((seconds + 59) / 60, 1)
    }

    private static func roundedUpHours(minutes: Int) -> Int {
        max((minutes + 59) / 60, 1)
    }
}

extension [UsageStatus] {
    var worstStatus: UsageStatus {
        contextPanelWorstStatus
    }
}
