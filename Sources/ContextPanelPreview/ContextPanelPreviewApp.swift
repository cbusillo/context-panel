import ContextPanelCore
import SwiftUI

@main
struct ContextPanelPreviewApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
                .frame(minWidth: 1280, minHeight: 720)
        }
    }
}

struct AppRoot: View {
    @StateObject private var model = ContextPanelAppModel()
    @State private var selectedID: UsageLimit.ID?

    private var snapshot: UsageSnapshot {
        model.currentSnapshot
    }

    private var selectedLimit: UsageLimit {
        if let selectedID, let match = snapshot.limits.first(where: { $0.id == selectedID }) {
            return match
        }
        return snapshot.mostConstrainedLimits.first ?? SampleUsageData.snapshot.mostConstrainedLimits[0]
    }

    var body: some View {
        HStack(spacing: 0) {
            AccountsSidebar(model: model, snapshot: snapshot, selectedID: $selectedID)
                .frame(width: 210)
            Divider()
            InstrumentDashboard(model: model, snapshot: snapshot)
                .frame(minWidth: 740)
            Divider()
            AccountDetail(model: model, limit: selectedLimit, generatedAt: snapshot.generatedAt)
                .frame(width: 320)
        }
        .tint(CPTheme.accent)
        .onAppear {
            model.loadSnapshot()
            selectedID = selectedID ?? snapshot.mostConstrainedLimits.first?.id
        }
    }
}

struct AccountsSidebar: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot
    @Binding var selectedID: UsageLimit.ID?

    var body: some View {
        List(selection: $selectedID) {
            Section("Accounts") {
                ForEach(Provider.allCases) { provider in
                    let limits = snapshot.limits.filter { $0.provider == provider }
                    if !limits.isEmpty {
                        ProviderSidebarRow(provider: provider, limits: limits)
                        ForEach(limits) { limit in
                            SidebarLimitRow(limit: limit)
                                .tag(limit.id)
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
                } label: {
                    Label("Add Account", systemImage: "plus")
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
    let limits: [UsageLimit]

    var body: some View {
        HStack(spacing: 8) {
            ProviderGlyph(provider: provider, size: 12)
            Text(provider.displayName)
                .font(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(limits.count)")
                .font(.system(.caption, design: .monospaced, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}

struct SidebarLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        HStack(spacing: 10) {
            StatusMark(status: limit.status, size: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(limit.accountName)
                    .font(.system(size: 13, weight: .medium))
                Text(limit.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(limit.compactUsageText)
                .font(.system(.caption2, design: .monospaced, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

struct InstrumentDashboard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot

    private var constrained: [UsageLimit] {
        Array(snapshot.mostConstrainedLimits.prefix(4))
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 18) {
                HeaderCard(model: model, snapshot: snapshot)
                SetupStatusStrip(model: model)
                WidgetPreviewGrid(snapshot: snapshot)
                SectionHeader(title: "Most Constrained", trailing: "\(snapshot.limits.count) accounts")
                VStack(spacing: 10) {
                    ForEach(constrained) { limit in
                        AccountRow(limit: limit)
                    }
                }
                SectionHeader(title: "Provider Groups", trailing: "Last update 2m ago")
                ProviderGroupGrid(snapshot: snapshot)
            }
            .padding(24)
            .frame(minWidth: 720, alignment: .topLeading)
        }
        .background(CPTheme.background)
        .navigationTitle("Glance")
    }
}

struct HeaderCard: View {
    @ObservedObject var model: ContextPanelAppModel
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                CPLabel("Context Panel")
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
                HStack(spacing: 8) {
                    TagLabel("SwiftUI")
                    TagLabel("WidgetKit")
                    TagLabel(model.storeStatus.rawValue)
                }
            }
            Spacer(minLength: 16)
            CapacityDial(
                value: snapshot.aggregateCapacityRatio,
                status: snapshot.aggregateStatus,
                label: "\(Int(snapshot.aggregateCapacityRatio * 100))",
                sublabel: "capacity",
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
            SectionHeader(title: "Concept A · Instrument", trailing: "Native preview")
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
                Text(snapshot.tightestUsageText)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(CPTheme.primaryText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                Text(snapshot.tightestSupportText)
                    .font(.system(size: 12))
                    .foregroundStyle(CPTheme.secondaryText)
                    .lineLimit(2)
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
                    CapacityDial(
                        value: snapshot.aggregateCapacityRatio,
                        status: snapshot.aggregateStatus,
                        label: "\(Int(snapshot.aggregateCapacityRatio * 100))",
                        sublabel: "capacity",
                        size: 94
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working room")
                            .font(.system(size: 18, weight: .semibold))
                        Text("1 limited · 2 close")
                            .font(.system(size: 11))
                            .foregroundStyle(CPTheme.tertiaryText)
                    }
                    Spacer()
                    Text("nearest reset · 42m")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CPTheme.tertiaryText)
                }
                .frame(width: 150, alignment: .leading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Most Constrained", trailing: "4 accounts")
                    ForEach(snapshot.mostConstrainedLimits.prefix(4)) { limit in
                        AccountRow(limit: limit, compact: true)
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
                        Text("You're good for the afternoon.")
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundStyle(CPTheme.primaryText)
                        Text("Image gen on Team is the only blocker.")
                            .font(.system(size: 12))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    Spacer()
                    CapacityDial(
                        value: snapshot.aggregateCapacityRatio,
                        status: snapshot.aggregateStatus,
                        label: "\(Int(snapshot.aggregateCapacityRatio * 100))",
                        sublabel: "cap",
                        size: 84
                    )
                }

                ProviderGroupGrid(snapshot: snapshot, compact: true)

                Spacer(minLength: 0)
                Divider()
                HStack {
                    Sparkline(values: [0.72, 0.68, 0.7, 0.64, 0.62, 0.58, 0.64])
                        .frame(width: 120, height: 20)
                    Text("24h capacity")
                        .font(.system(size: 10))
                        .foregroundStyle(CPTheme.tertiaryText)
                    Spacer()
                    Text("next reset in 42m · upd 2m ago")
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
                let limits = snapshot.limits.filter { $0.provider == provider }
                if !limits.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            ProviderGlyph(provider: provider, size: 11)
                            Text(provider.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                            Spacer()
                            StatusMark(status: limits.map(\.status).worstStatus, size: 7)
                        }
                        .foregroundStyle(CPTheme.secondaryText)
                        Divider()
                        ForEach(limits.prefix(compact ? 3 : 4)) { limit in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(limit.accountName)
                                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(limit.percentText)
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundStyle(CPTheme.secondaryText)
                                }
                                Text(limit.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(CPTheme.tertiaryText)
                                    .lineLimit(1)
                                CapacityBar(value: limit.usageRatio ?? 0, status: limit.status)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

struct AccountDetail: View {
    @ObservedObject var model: ContextPanelAppModel
    let limit: UsageLimit
    let generatedAt: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    ProviderGlyph(provider: limit.provider, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(limit.accountName)
                            .font(.system(size: 22, weight: .semibold))
                        Text("\(limit.provider.displayName) · \(limit.label)")
                            .font(.system(size: 13))
                            .foregroundStyle(CPTheme.secondaryText)
                    }
                    Spacer()
                    StatusMark(status: limit.status, size: 10)
                }

                CapacityDial(
                    value: 1 - (limit.usageRatio ?? 0),
                    status: limit.status,
                    label: limit.remaining.map(String.init) ?? "?",
                    sublabel: "left",
                    size: 140
                )
                .frame(maxWidth: .infinity)

        DetailCard(title: "Forecast") {
                    Text(forecastCopy)
                        .font(.system(size: 15, weight: .medium))
                    Text("Confidence: \(limit.confidence.rawValue)")
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.secondaryText)
                }

                DetailCard(title: "Normalized limit") {
                    DetailRow(label: "Used", value: limit.used.map(String.init) ?? "unknown")
                    DetailRow(label: "Limit", value: limit.limit.map(String.init) ?? "unknown")
                    DetailRow(label: "Remaining", value: limit.remaining.map(String.init) ?? "unknown")
                    DetailRow(label: "Status", value: limit.status.rawValue)
                    DetailRow(label: "Updated", value: limit.lastUpdatedAt.map(model.relativeTime) ?? "unknown")
                }

                DetailCard(title: "Refresh history") {
                    Sparkline(values: [0.72, 0.68, 0.70, 0.64, 0.62, 0.58, 0.64])
                        .frame(height: 42)
                    Text("\(model.historyCount) cached snapshots. Last good snapshot is preserved for stale and failure states.")
                        .font(.system(size: 12))
                        .foregroundStyle(CPTheme.secondaryText)
                }

                DetailCard(title: "Setup") {
                    DetailRow(label: "Store", value: ConnectorRedactor.redactedPath(model.store.rootDirectory.path))
                    DetailRow(label: "Accounts", value: "\(model.configuredAccounts.filter(\.isEnabled).count) enabled")
                    ForEach(model.configuredAccounts) { account in
                        DetailRow(
                            label: account.displayName,
                            value: account.isEnabled ? account.connectorKind.rawValue : "disabled"
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
        if limit.provider == .openAI, limit.label.contains("GPT-5") {
            return FastModeForecast(
                input: FastModeForecastInput(
                        limit: limit,
                        now: model.now,
                    standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
                    fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 12),
                    reserveUnits: 6,
                    minimumSafeHours: 1
                )
            ).copy
        }
        return limit.note ?? "No fast-mode forecast for this limit yet."
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
            StatusMark(status: status, size: 9)
        }
    }
}

struct ProviderMiniStatus: View {
    let snapshot: UsageSnapshot

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Provider.allCases) { provider in
                let limits = snapshot.limits.filter { $0.provider == provider }
                HStack(spacing: 5) {
                    ProviderGlyph(provider: provider, size: 10)
                    Text(provider.shortName)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CPTheme.secondaryText)
                }
                .opacity(limits.isEmpty ? 0.35 : 1)
            }
        }
    }
}

struct AccountRow: View {
    let limit: UsageLimit
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            ProviderGlyph(provider: limit.provider, size: compact ? 11 : 13)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(limit.label)
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .lineLimit(1)
                    Text("· \(limit.accountName)")
                        .font(.system(size: compact ? 12 : 13))
                        .foregroundStyle(CPTheme.tertiaryText)
                        .lineLimit(1)
                    Spacer()
                    Text(limit.compactUsageText)
                        .font(.system(size: compact ? 10 : 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(CPTheme.secondaryText)
                }
                HStack(spacing: 8) {
                    CapacityBar(value: limit.usageRatio ?? 0, status: limit.status)
                    Text(limit.resetText)
                        .font(.system(size: 10))
                        .foregroundStyle(limit.status == .stale ? CPTheme.statusColor(.stale) : CPTheme.tertiaryText)
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
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefreshAt: Date?

    let now = Date()
    let store: JSONSnapshotStore
    let accountStore: AccountConfigurationStore

    var currentSnapshot: UsageSnapshot {
        storedSnapshot?.snapshot ?? SampleUsageData.snapshot
    }

    var fastModeForecast: FastModePortfolioForecast {
        let forecasts = currentSnapshot.limits
            .filter { $0.provider == .openAI && $0.unit == .percent }
            .map { limit in
                FastModeForecast(input: FastModeForecastInput(
                    limit: limit,
                    now: Date(),
                    standardBurnRate: BurnRate(mode: .standard, unitsPerHour: 2),
                    fastBurnRate: BurnRate(mode: .fast, unitsPerHour: 12),
                    reserveUnits: 6,
                    minimumSafeHours: 1
                ))
            }
        return FastModePortfolioForecast(forecasts: forecasts)
    }

    var lastRefreshText: String {
        lastRefreshAt.map(relativeTime) ?? "not yet"
    }

    init() {
        store = JSONSnapshotStore(rootDirectory: Self.defaultStoreDirectory())
        accountStore = AccountConfigurationStore(configurationURL: Self.defaultConfigurationURL())
    }

    func loadSnapshot() {
        let accounts = accountStore.load().document.accounts
        configuredAccounts = accounts
        let result = store.loadCurrent(policy: SnapshotStoreStalenessPolicy(maximumAge: 15 * 60), now: Date())
        storedSnapshot = result.snapshot
        storeStatus = result.status
        errorMessage = result.errorMessage
        historyCount = store.loadHistory().count
    }

    func refreshLocalConnectors() async {
        isRefreshing = true
        defer { isRefreshing = false }

        let accountDocument = accountStore.load().document
        configuredAccounts = accountDocument.accounts
        let connectors = AccountConnectorFactory.connectors(from: accountDocument)
        let refreshResult = await ProviderConnectorRuntime(connectors: connectors).refreshAll()
        let savedAt = Date()

        do {
            try store.save(StoredUsageSnapshot(savedAt: savedAt, refreshResult: refreshResult))
            lastRefreshAt = savedAt
            loadSnapshot()
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

    private static func defaultStoreDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    private static func defaultConfigurationURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base
            .appending(path: "Context Panel", directoryHint: .isDirectory)
            .appending(path: "accounts.json")
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

struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch provider {
            case .openAI:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(CPTheme.accent, lineWidth: 1.4)
            case .anthropic:
                Triangle()
                    .stroke(CPTheme.accent, lineWidth: 1.4)
            case .google:
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .rotation(.degrees(45))
                    .stroke(CPTheme.accent, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
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
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(CPTheme.accent)
                .rotationEffect(.degrees(45))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(CPTheme.tertiaryText)
        }
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

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum CPTheme {
    static let background = Color(red: 244 / 255, green: 244 / 255, blue: 245 / 255)
    static let surface = Color.white
    static let surface2 = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    static let line = Color.black.opacity(0.07)
    static let primaryText = Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255)
    static let secondaryText = primaryText.opacity(0.66)
    static let tertiaryText = primaryText.opacity(0.46)
    static let accent = Color(red: 74 / 255, green: 91 / 255, blue: 122 / 255)

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
}

extension UsageSnapshot {
    var headline: String {
        "Know whether you can keep working."
    }

    var subheadline: String {
        "OpenAI, Anthropic, and Google capacity with local confidence."
    }

    var tightestLimit: UsageLimit? {
        mostConstrainedLimits.first
    }

    var tightestUsageText: String {
        guard let tightestLimit else { return "Set up accounts" }
        return tightestLimit.compactUsageText == "?" ? "Unknown limit" : "\(tightestLimit.compactUsageText) left"
    }

    var tightestSupportText: String {
        guard let tightestLimit else { return "Add OpenAI, Anthropic, or Google." }
        return "\(tightestLimit.label) · \(tightestLimit.accountName) — your tightest account"
    }
}

extension UsageLimit {
    var compactUsageText: String {
        guard let used, let limit else { return status == .failure ? "—" : "?" }
        return "\(used)/\(limit)"
    }

    var percentText: String {
        guard let usageRatio else { return status == .failure ? "—" : "?" }
        return "\(Int(usageRatio * 100))%"
    }

    var resetText: String {
        switch status {
        case .failure:
            "refresh failed"
        case .unknown:
            "unknown"
        default:
            switch label {
            case "Image generation":
                "42m"
            case "Claude Opus":
                "1h 15m"
            case "GPT-5":
                "3h 20m"
            case "GPT-5 Thinking":
                "tomorrow 9:00"
            default:
                "tonight"
            }
        }
    }
}

extension [UsageStatus] {
    var worstStatus: UsageStatus {
        if contains(.limited) { return .limited }
        if contains(.failure) { return .failure }
        if contains(.close) { return .close }
        if contains(.stale) { return .stale }
        if contains(.unknown) { return .unknown }
        return .healthy
    }
}
