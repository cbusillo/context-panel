import ContextPanelCloudKitSync
import ContextPanelCore
import ContextPanelTVSupport
import SwiftUI

@main
struct ContextPanelTVApp: App {
    var body: some Scene {
        WindowGroup {
            TVRootView()
        }
    }
}

@MainActor
private struct TVRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tv-presentation-mode") private var presentationModeRawValue = TVPresentationMode.fullDetail.rawValue
    @State private var model = TVSyncModel()
    @State private var navigationPath: [String] = []

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
        TVRunwayPresentation(snapshot: model.snapshot, mode: presentationMode)
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

                if let syncErrorMessage = model.lastSyncErrorMessage {
                    TVSyncAlert(message: syncErrorMessage)
                        .padding(.horizontal, 72)
                        .padding(.bottom, 28)
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
            .navigationDestination(for: String.self) { providerRawValue in
                if let section = presentation.sections.first(where: { $0.provider.rawValue == providerRawValue }) {
                    TVProviderDetailView(section: section, mode: presentationMode)
                }
            }
            .onOpenURL { url in
                guard url.scheme == "contextpaneltv", url.host == "provider" else { return }
                let providerRawValue = url.lastPathComponent
                guard presentation.sections.contains(where: { $0.provider.rawValue == providerRawValue }) else { return }
                navigationPath = [providerRawValue]
            }
        }
        .preferredColorScheme(.dark)
    }
}

@MainActor
@Observable
private final class TVSyncModel {
    private let remoteStore: CompanionRemoteSyncStore
    private let cacheStore: CompanionSyncStore
    private let receiptStore: TVSyncReceiptStore
    private let usesPreviewFixture: Bool
    private var reloadTask: Task<Void, Never>?
    private var needsReloadAfterCurrentTask = false

    private(set) var result: CompanionSyncLoadResult
    private(set) var displayResult: CompanionSyncLoadResult
    private(set) var snapshot: WidgetSnapshot
    private(set) var lastSyncErrorMessage: String?
    private(set) var lastReceivedAt: Date?
    private(set) var isLoading = false

    init(now: Date = Date()) {
        remoteStore = CompanionCloudKitSyncStoreFactory.make()
        cacheStore = CompanionSyncStore(
            documentURL: ContextPanelLocations.companionSyncDocumentURL(appGroupID: nil)
        )
        let localReceiptStore = TVSyncReceiptStore(
            receiptURL: ContextPanelLocations.applicationSupportDirectory()
                .appending(path: "tv-sync-receipt.json")
        )
        receiptStore = localReceiptStore

        #if DEBUG
        if let fixtureResult = TVPreviewFixtures.requestedResult(now: now) {
            usesPreviewFixture = true
            result = fixtureResult
            displayResult = fixtureResult
            lastReceivedAt = fixtureResult.transportMetadata?.receivedAt
            lastSyncErrorMessage = fixtureResult.errorMessage
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

    func reload(now: Date = Date()) {
        guard !usesPreviewFixture else { return }
        guard reloadTask == nil else {
            needsReloadAfterCurrentTask = true
            return
        }

        needsReloadAfterCurrentTask = false
        isLoading = true
        lastSyncErrorMessage = nil
        result = CompanionSyncLoadResult(document: result.document, status: .loading)

        reloadTask = Task { [weak self, remoteStore, cacheStore, receiptStore] in
            defer {
                if let self {
                    isLoading = false
                    reloadTask = nil
                    if needsReloadAfterCurrentTask {
                        reload()
                    }
                }
            }

            let remoteLoad = await remoteStore.load(now: now)
            guard !Task.isCancelled, let self else { return }
            let loaded = remoteLoad.result
            result = loaded

            if let document = loaded.document {
                try? cacheStore.save(document)
                try? receiptStore.save(document: document, receivedAt: now)
                lastReceivedAt = now
                displayResult = loaded
            } else {
                let cached = cacheStore.load(policy: Self.stalenessPolicy, now: now)
                if let cachedDocument = cached.document {
                    displayResult = CompanionSyncLoadResult(
                        document: cachedDocument,
                        status: .stale,
                        transportMetadata: cached.transportMetadata,
                        transportStatuses: loaded.transportStatuses
                    )
                } else {
                    displayResult = loaded
                }
            }

            lastSyncErrorMessage = loaded.status == .failure ? loaded.errorMessage : nil
            snapshot = WidgetSnapshot.fromCompanionSync(
                displayResult,
                now: now,
                stalenessPolicy: Self.stalenessPolicy
            )
        }
    }

    private static let stalenessPolicy = SnapshotStoreStalenessPolicy.appDefault(
        maximumAge: SnapshotFreshness.companionProviderMaximumAge
    )
}

private struct TVHeaderView: View {
    let presentation: TVRunwayPresentation
    let receivedAt: Date?
    let isRefreshing: Bool
    @Binding var presentationModeRawValue: String
    let onRefresh: () -> Void

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
                    } label: {
                        Label("Display", systemImage: "slider.horizontal.3")
                    }
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

    let section: TVProviderRunwaySection
    let mode: TVPresentationMode

    private var lane: TVRunwayLane {
        section.lanes[0]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
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
                    Text("remaining")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Unknown")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TVCapacityBar(ratio: lane.capacityRatio, provider: lane.provider)

            if mode != .countsOnly {
                VStack(alignment: .leading, spacing: 7) {
                    if let resetText = lane.resetText {
                        Text(resetText)
                    }
                    if let accountCountText = lane.accountCountText {
                        Text(accountCountText)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(section.lanes.count == 1 ? "1 window tracked" : "\(section.lanes.count) windows tracked")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
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
        .scaleEffect(isFocused ? 1.025 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.45 : 0.16), radius: isFocused ? 26 : 10, y: 12)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var components = [section.provider.displayName, section.status.tvStatusLabel, lane.title]
        if let remainingPercent = lane.remainingPercent {
            components.append("\(remainingPercent) percent remaining")
        }
        if let resetText = lane.resetText {
            components.append(resetText)
        }
        return components.joined(separator: ", ")
    }
}

private struct TVProviderDetailView: View {
    let section: TVProviderRunwaySection
    let mode: TVPresentationMode

    private var columns: [GridItem] {
        let count = section.lanes.count == 1 ? 1 : min(section.lanes.count, 3)
        return Array(
            repeating: GridItem(.flexible(minimum: 360, maximum: 620), spacing: 32, alignment: .top),
            count: count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 44) {
                HStack(spacing: 16) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(TVTheme.providerColor(section.provider))
                        .frame(width: 9, height: 42)
                    Text(section.provider.displayName)
                        .font(.system(size: 58, weight: .bold, design: .rounded))
                    Text(section.status.tvStatusLabel)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TVTheme.statusColor(section.status))
                }

                LazyVGrid(columns: columns, alignment: .center, spacing: 32) {
                    ForEach(section.lanes) { lane in
                        NavigationLink {
                            TVRunwayDetailView(lane: lane, mode: mode)
                        } label: {
                            TVRunwayCard(lane: lane, mode: mode)
                        }
                        .buttonStyle(TVFocusButtonStyle())
                        .focusEffectDisabled()
                    }
                }
            }
            .padding(.horizontal, 84)
            .padding(.vertical, 72)
        }
        .background(TVTheme.background.ignoresSafeArea())
    }
}

private struct TVRunwayCard: View {
    @Environment(\.isFocused) private var isFocused

    let lane: TVRunwayLane
    let mode: TVPresentationMode

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(lane.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(lane.statusText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(TVTheme.statusColor(lane.status))
            }

            if let remainingPercent = lane.remainingPercent {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(remainingPercent)%")
                        .font(.system(size: mode == .countsOnly ? 84 : 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("remaining")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Unknown")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
            }

            TVCapacityBar(ratio: lane.capacityRatio, provider: lane.provider)

            if mode != .countsOnly {
                VStack(alignment: .leading, spacing: 6) {
                    if let accountCountText = lane.accountCountText {
                        Text(accountCountText)
                    }
                    if let resetText = lane.resetText {
                        Text(resetText)
                    }
                    if let exactCapacityText = lane.exactCapacityText {
                        Text(exactCapacityText)
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
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
        .scaleEffect(isFocused ? 1.018 : 1)
        .shadow(color: .black.opacity(isFocused ? 0.42 : 0.14), radius: isFocused ? 24 : 8, y: 12)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var components = [lane.provider.displayName, lane.title, lane.statusText]
        if let remainingPercent = lane.remainingPercent {
            components.append("\(remainingPercent) percent remaining")
        }
        if let resetText = lane.resetText {
            components.append(resetText)
        }
        return components.joined(separator: ", ")
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

                if let remainingPercent = lane.remainingPercent {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(remainingPercent)%")
                            .font(.system(size: 108, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("remaining")
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
                Text("\(remainingPercent)%")
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
            Text(presentation.headline)
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
}

private struct TVSyncAlert: View {
    let message: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Cloud sync is unavailable. Showing the last saved runway when possible.")
                .font(.headline)
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
