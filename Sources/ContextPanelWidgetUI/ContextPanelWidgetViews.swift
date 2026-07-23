import ContextPanelCore
import SwiftUI
import WidgetKit

#if canImport(AppKit)
import AppKit
private typealias CPWPlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
private typealias CPWPlatformColor = UIColor
#endif

public enum CPWThemeVariant: Sendable {
    case adaptive
    case light
    case dark
}

private struct CPWThemeVariantKey: EnvironmentKey {
    static let defaultValue: CPWThemeVariant = .adaptive
}

public extension EnvironmentValues {
    var cpwThemeVariant: CPWThemeVariant {
        get { self[CPWThemeVariantKey.self] }
        set { self[CPWThemeVariantKey.self] = newValue }
    }
}

public extension View {
    func cpwThemeVariant(_ variant: CPWThemeVariant) -> some View {
        environment(\.cpwThemeVariant, variant)
    }
}

public struct ContextPanelWidgetLinks: Sendable {
    public let overview: URL
    public let reconnect: URL
    public let cacheStatsSettings: URL

    public init(overview: URL, reconnect: URL, cacheStatsSettings: URL) {
        self.overview = overview
        self.reconnect = reconnect
        self.cacheStatsSettings = cacheStatsSettings
    }
}

public struct ContextPanelWidgetContentView: View {
    let family: WidgetFamily
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let links: ContextPanelWidgetLinks

    public init(
        family: WidgetFamily,
        snapshot: WidgetSnapshot,
        displayPreferences: WidgetDisplayPreferences,
        links: ContextPanelWidgetLinks
    ) {
        self.family = family
        self.snapshot = snapshot
        self.displayPreferences = displayPreferences
        self.links = links
    }

    public var body: some View {
        content
            .widgetURL(snapshot.widgetDeepLinkURL(links: links))
    }

    @ViewBuilder
    private var content: some View {
        if snapshot.shouldShowSetupPlaceholder {
            CPWSetupPlaceholderWidget(family: family)
        } else {
            switch family {
            case .systemSmall:
                ContextPanelSmallWidget(
                    snapshot: snapshot,
                    displayPreferences: displayPreferences
                )
            case .systemLarge, .systemExtraLarge:
                ContextPanelLargeWidget(
                    snapshot: snapshot,
                    displayPreferences: displayPreferences,
                    links: links
                )
            default:
                ContextPanelMediumWidget(
                    snapshot: snapshot,
                    displayPreferences: displayPreferences,
                    links: links
                )
            }
        }
    }
}

struct CPWSetupPlaceholderWidget: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let family: WidgetFamily

    private var isSmall: Bool {
        family == .systemSmall
    }

    var body: some View {
        VStack(alignment: .leading, spacing: isSmall ? 8 : 10) {
            HStack(spacing: 8) {
                Image(systemName: "gauge.medium")
                    .font(.system(size: isSmall ? 16 : 18, weight: .semibold))
                    .foregroundStyle(CPWTheme.accent)
                    .frame(width: isSmall ? 22 : 26, height: isSmall ? 22 : 26)
                Text("Context Panel")
                    .font(.system(size: isSmall ? 11 : 12, weight: .semibold))
                    .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("Set up Context Panel")
                .font(.system(size: isSmall ? 19 : 23, weight: .semibold))
                .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text("Open the app to add your first account.")
                .font(.system(size: isSmall ? 11 : 13, weight: .medium))
                .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                .lineLimit(isSmall ? 2 : 1)
                .minimumScaleFactor(0.88)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Open app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContextPanelSmallWidget: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences

    var body: some View {
        let selection = displayPreferences.mainLimitAnswerSelection(
            from: snapshot.usageSnapshot.mainLimitSummaries
        )
        let primary = selection.primary
        let supporting = selection.compactSupportingLanes(maximumCount: 2)

        VStack(alignment: .leading, spacing: 5) {
            if let problem = snapshot.widgetProblemText {
                CPWProblemLabel(problem, status: snapshot.widgetProblemStatus)
            }
            if let primary, supporting.isEmpty {
                CPWSmallSingleLimitView(lane: primary, snapshotState: snapshot.state)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if let primary {
                CPWSmallPrimaryLimitView(lane: primary, snapshotState: snapshot.state)
                ForEach(supporting) { lane in
                    CPWSmallRemainingLimitRow(lane: lane, snapshotState: snapshot.state)
                }
            } else {
                Text("No limit data")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(2)
                Text(snapshot.message)
                    .font(.system(size: 11))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct CPWSmallPrimaryLimitView: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let lane: WidgetMainLimitLane
    let snapshotState: WidgetSnapshotState

    private var summary: MainLimitSummary? {
        lane.summary
    }

    private var status: UsageStatus {
        snapshotState.smallWidgetPresentationStatus(source: summary?.status ?? .unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                CPWProviderBadge(provider: lane.provider, compact: true)
                Text(summary?.widgetSmallLaneWindowLine ?? lane.window.shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(summary?.widgetRemainingHeadline ?? "Unknown")
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            CPWRemainingCapacityBar(
                remainingRatio: summary?.widgetRemainingCapacityRatio,
                status: status,
                height: 5
            )
            if let resetText = summary?.widgetSmallResetConfidenceText {
                Text(resetText)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityLabel: String {
        guard let summary else {
            return "Main limit, \(lane.provider.displayName), \(lane.window.displayName)"
        }
        return "Main limit, \(summary.provider.displayName), \(summary.widgetWindowLine)"
    }

    private var accessibilityValue: String {
        summary?.widgetCapacityAccessibilityValue(snapshotState: snapshotState)
            ?? snapshotState.smallWidgetUnknownCapacityAccessibilityValue
    }
}

private struct CPWSmallSingleLimitView: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let lane: WidgetMainLimitLane
    let snapshotState: WidgetSnapshotState

    private var summary: MainLimitSummary? {
        lane.summary
    }

    private var status: UsageStatus {
        snapshotState.smallWidgetPresentationStatus(source: summary?.status ?? .unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary?.widgetRemainingHeadline ?? "Unknown")
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                .minimumScaleFactor(0.68)
                .lineLimit(1)
            HStack(spacing: 5) {
                CPWProviderBadge(provider: lane.provider, compact: true)
                Text(summary?.widgetSmallLaneWindowLine ?? lane.window.shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
            }
            if let resetText = summary?.widgetSmallResetConfidenceText {
                Text(resetText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .minimumScaleFactor(0.8)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            CPWRemainingCapacityBar(
                remainingRatio: summary?.widgetRemainingCapacityRatio,
                status: status,
                height: 5
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityLabel: String {
        guard let summary else {
            return "\(lane.provider.displayName), \(lane.window.displayName)"
        }
        return "\(summary.provider.displayName), \(summary.widgetWindowLine)"
    }

    private var accessibilityValue: String {
        summary?.widgetCapacityAccessibilityValue(snapshotState: snapshotState)
            ?? snapshotState.smallWidgetUnknownCapacityAccessibilityValue
    }
}

private struct CPWSmallRemainingLimitRow: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let lane: WidgetMainLimitLane
    let snapshotState: WidgetSnapshotState

    private var summary: MainLimitSummary? {
        lane.summary
    }

    private var status: UsageStatus {
        snapshotState.smallWidgetPresentationStatus(source: summary?.status ?? .unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                CPWProviderBadge(provider: lane.provider, compact: true)
                Text(summary?.widgetSmallLaneWindowLine ?? lane.window.shortName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 4)
                Text(summary?.widgetRemainingHeadline ?? "Unknown")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .layoutPriority(1)
            }
            HStack(spacing: 5) {
                CPWRemainingCapacityBar(
                    remainingRatio: summary?.widgetRemainingCapacityRatio,
                    status: status,
                    height: 4
                )
                Text(summary?.widgetSmallResetConfidenceText ?? "")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityLabel: String {
        guard let summary else {
            return "\(lane.provider.displayName), \(lane.window.displayName)"
        }
        return "\(summary.provider.displayName), \(summary.widgetWindowLine)"
    }

    private var accessibilityValue: String {
        summary?.widgetCapacityAccessibilityValue(snapshotState: snapshotState)
            ?? snapshotState.smallWidgetUnknownCapacityAccessibilityValue
    }
}

private extension WidgetSnapshotState {
    func smallWidgetPresentationStatus(source: UsageStatus) -> UsageStatus {
        switch self {
        case .ready:
            source
        case .stale:
            .stale
        case .failure:
            .failure
        case .setupNeeded:
            .unknown
        }
    }

    var smallWidgetUnknownCapacityAccessibilityValue: String {
        switch self {
        case .ready:
            "Remaining capacity unknown. Status unknown"
        case .stale:
            "Remaining capacity unknown. Data stale"
        case .failure:
            "Remaining capacity unknown. Refresh failed"
        case .setupNeeded:
            "Remaining capacity unknown. Setup needed"
        }
    }
}

struct ContextPanelMediumWidget: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let links: ContextPanelWidgetLinks

    var body: some View {
        let primaryLane = displayPreferences.mainLimitAnswerSelection(
            from: snapshot.usageSnapshot.mainLimitSummaries
        ).primary
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                if let problem = snapshot.widgetProblemText {
                    CPWProblemLabel(problem, status: snapshot.widgetProblemStatus)
                }
                Spacer(minLength: 0)
                CPWGlanceNumber(snapshot: snapshot, lane: primaryLane)
                Text(snapshot.fastModeVerdict)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(2)
                Text(snapshot.fastModeDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(2)
                Text(snapshot.fastModeResetDetail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
            }
            .frame(width: 124, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                let lanes = snapshot.visibleMainLimitLanes(
                    displayPreferences: displayPreferences,
                    maximumCount: 3
                )
                CPWSectionHeader(
                    title: "Limits",
                    accessory: CPWPromptCacheInlineStat(
                        state: snapshot.promptCacheWidgetState,
                        summary: snapshot.promptCacheSummary,
                        cacheStatsSettingsURL: links.cacheStatsSettings
                    )
                )
                if snapshot.shouldShowMainLimitEmptyRow {
                    CPWEmptyRow(message: snapshot.message)
                } else {
                    ForEach(lanes) { lane in
                        CPWMainLimitRow(lane: lane, snapshotState: snapshot.state)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContextPanelLargeWidget: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences
    let links: ContextPanelWidgetLinks

    var body: some View {
        let primaryLane = displayPreferences.mainLimitAnswerSelection(
            from: snapshot.usageSnapshot.mainLimitSummaries
        ).primary
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = snapshot.widgetProblemText {
                        CPWProblemLabel(problem, status: snapshot.widgetProblemStatus)
                    }
                    Text(snapshot.fastModeVerdict)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(snapshot.fastModeDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                        .lineLimit(1)
                    Text(snapshot.fastModeResetDetail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                CPWGlanceNumber(snapshot: snapshot, lane: primaryLane)
            }

            CPWProviderSummaryGrid(snapshot: snapshot, compact: true)
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                let lanes = snapshot.visibleMainLimitLanes(
                    displayPreferences: displayPreferences,
                    maximumCount: 5
                )
                CPWSectionHeader(
                    title: "Main Limits",
                    accessory: CPWPromptCacheInlineStat(
                        state: snapshot.promptCacheWidgetState,
                        summary: snapshot.promptCacheSummary,
                        cacheStatsSettingsURL: links.cacheStatsSettings
                    )
                )
                if snapshot.shouldShowMainLimitEmptyRow {
                    CPWEmptyRow(message: snapshot.message)
                } else {
                    ForEach(lanes) { lane in
                        CPWMainLimitRow(lane: lane, snapshotState: snapshot.state)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CPWPromptCacheInlineStat: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let state: PromptCacheWidgetState
    let summary: PromptCacheSummary
    let cacheStatsSettingsURL: URL

    private var currentRate: Double? {
        summary.latestHitRate
    }

    private var averageRate: Double? {
        summary.tokenWeightedHitRate
    }

    var body: some View {
        switch state {
        case .available:
            HStack(alignment: .center, spacing: 0) {
                HStack(spacing: 4) {
                    CPWStatusMark(status: summary.comparisonStatus, size: 5)
                    Text("Cache")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.45)
                        .textCase(.uppercase)
                    Text(currentRate.map(Self.percentText) ?? "--")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(CPWTheme.statusColor(summary.comparisonStatus))
                .padding(.leading, 6)
                .padding(.trailing, 5)

                Rectangle()
                    .fill(CPWTheme.line(variant: themeVariant).opacity(0.85))
                    .frame(width: 1, height: 11)

                HStack(spacing: 3) {
                    Text("avg")
                        .font(.system(size: 8, weight: .semibold))
                        .tracking(0.45)
                        .textCase(.uppercase)
                    Text(averageRate.map(Self.percentText) ?? "--")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                .padding(.leading, 5)
                .padding(.trailing, 6)
            }
            .lineLimit(1)
            .padding(.vertical, 2)
            .background(CPWTheme.line(variant: themeVariant).opacity(0.45))
            .clipShape(Capsule(style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(accessibilityLabel)
        case .needsAuthorization:
            Link(destination: cacheStatsSettingsURL) {
                promptCachePill(
                    text: "Enable Cache",
                    foreground: CPWTheme.accent,
                    background: CPWTheme.accent.opacity(0.16),
                    accessibilityLabel: "Enable cache stats"
                )
            }
            .buttonStyle(.plain)
        case .stale:
            promptCachePill(
                text: "Cache stale",
                foreground: CPWTheme.statusColor(.stale),
                background: CPWTheme.statusColor(.stale).opacity(0.14),
                accessibilityLabel: "Cache stats are stale"
            )
        case .unavailable:
            EmptyView()
        }
    }

    private func promptCachePill(
        text: String,
        foreground: Color,
        background: Color,
        accessibilityLabel: String
    ) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .clipShape(Capsule(style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if summary.hasPossibleCacheBreak {
            return "Prompt cache: possible cache break. Current rate \(currentRate.map(Self.percentText) ?? "unknown"), rolling average \(averageRate.map(Self.percentText) ?? "unknown")."
        }
        return "Prompt cache current \(currentRate.map(Self.percentText) ?? "unknown"), rolling average \(averageRate.map(Self.percentText) ?? "unknown")"
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

struct CPWProblemLabel: View {
    let text: String
    let status: UsageStatus

    init(_ text: String, status: UsageStatus) {
        self.text = text
        self.status = status
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.5)
            .textCase(.uppercase)
            .foregroundStyle(CPWTheme.statusColor(status))
            .lineLimit(1)
    }
}

struct CPWGlanceNumber: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot
    let lane: WidgetMainLimitLane?

    private var summary: MainLimitSummary? {
        lane?.summary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(headline)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(subheadline)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                .lineLimit(2)
            if lane?.provider == .openAI {
                CPWBurnPaceBar(
                    forecast: snapshot.fastModeForecast,
                    isStale: snapshot.state == .stale
                )
            }
        }
        .frame(width: 94, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var headline: String {
        if snapshot.needsProviderConnection { return "Not connected" }
        if let summary { return summary.widgetRemainingHeadline }
        return lane == nil ? "No data" : "Unknown"
    }

    private var subheadline: String {
        if snapshot.needsProviderConnection { return "No provider data yet" }
        guard let lane else { return snapshot.message }
        return "\(lane.provider.shortName) \(lane.window.displayName)"
    }

    private var accessibilityLabel: String {
        guard let lane else { return "Context Panel usage" }
        return "Main limit, \(lane.provider.displayName), \(lane.window.displayName)"
    }

    private var accessibilityValue: String {
        guard let summary else {
            return switch snapshot.state {
            case .ready:
                "Remaining capacity unknown. Main limit status unknown"
            case .stale:
                "Remaining capacity unknown. Data stale"
            case .failure:
                "Remaining capacity unknown. Refresh failed"
            case .setupNeeded:
                "Remaining capacity unknown. Setup needed"
            }
        }
        var value = summary.widgetCapacityAccessibilityValue(snapshotState: snapshot.state)
        if lane?.provider == .openAI, let forecast = snapshot.fastModeForecast {
            value += ". Burn pace \(forecast.burnPaceCopy)"
        }
        return value
    }
}

struct CPWMainLimitRow: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let summary: MainLimitSummary?
    let fallbackProvider: Provider
    let fallbackWindow: MainLimitWindow
    let snapshotState: WidgetSnapshotState

    init(summary: MainLimitSummary, snapshotState: WidgetSnapshotState = .ready) {
        self.summary = summary
        fallbackProvider = summary.provider
        fallbackWindow = summary.window
        self.snapshotState = snapshotState
    }

    init(lane: WidgetMainLimitLane, snapshotState: WidgetSnapshotState = .ready) {
        summary = lane.summary
        fallbackProvider = lane.provider
        fallbackWindow = lane.window
        self.snapshotState = snapshotState
    }

    private var provider: Provider {
        summary?.provider ?? fallbackProvider
    }

    private var status: UsageStatus {
        snapshotState == .stale ? .stale : (summary?.status ?? .unknown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                CPWProviderBadge(provider: provider, compact: true)
                Text(summary?.widgetWindowLine ?? fallbackWindow.placeholderWidgetLine(provider: fallbackProvider))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(summary?.widgetUsageText ?? "No data yet")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
            }
            HStack(spacing: 6) {
                CPWUsagePressureBar(usedRatio: summary?.widgetUsageRatio, status: status)
                Text(summary?.widgetResetConfidenceText ?? "")
                    .font(.system(size: 9))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityLabel: String {
        guard let summary else {
            return "\(provider.displayName), \(fallbackWindow.displayName)"
        }
        return "\(provider.displayName), \(summary.widgetWindowLine)"
    }

    private var accessibilityValue: String {
        guard let summary else {
            return snapshotState == .stale ? "Usage unknown. Data stale" : "Usage unknown. Status unknown"
        }
        return summary.widgetPressureAccessibilityValue(snapshotState: snapshotState)
    }
}

struct CPWProviderSummaryGrid: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ForEach(Provider.allCases) { provider in
                let providerLimits = snapshot.limits.filter { $0.provider == provider }
                let metricSummary = snapshot.widgetProviderMainLimitSummary(provider: provider)
                let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                let nonMainStatuses = providerLimits.filter { !$0.isMainLimit }.map(\.status)
                let providerStatus = provider == .anthropic && !summaries.isEmpty
                    ? summaries.map(\.status).contextPanelWorstStatus
                    : (summaries.map(\.status) + nonMainStatuses).contextPanelWorstStatus
                let metricStatus = metricSummary?.status ?? .unknown
                let displayProviderStatus = snapshot.widgetPresentationStatus(for: providerStatus)
                let displayMetricStatus = snapshot.widgetPresentationStatus(for: metricStatus)
                let isConnected = !providerLimits.isEmpty
                let summaryText = snapshot.widgetProviderSummaryText(provider: provider)

                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    HStack(spacing: 5) {
                        CPWProviderBadge(provider: provider, compact: true)
                        if isConnected && displayProviderStatus.shouldShowWidgetProviderStatus(relativeTo: displayMetricStatus) {
                            Text(displayProviderStatus.widgetLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CPWTheme.statusColor(displayProviderStatus))
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(summaryText)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                        .lineLimit(compact ? 1 : 2)
                    CPWUsagePressureBar(
                        usedRatio: metricSummary?.widgetUsageRatio,
                        status: displayMetricStatus,
                        height: 5
                    )
                }
                .opacity(isConnected ? 1 : 0.45)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(providerAccessibilityLabel(provider: provider, summary: metricSummary))
                .accessibilityValue(providerAccessibilityValue(
                    summaryText: summaryText,
                    providerStatus: providerStatus,
                    metricSummary: metricSummary,
                    isConnected: isConnected,
                    snapshotState: snapshot.state
                ))
            }
        }
    }

    private func providerAccessibilityLabel(provider: Provider, summary: MainLimitSummary?) -> String {
        guard let summary else { return provider.displayName }
        return "\(provider.displayName), \(summary.widgetWindowLine)"
    }

    private func providerAccessibilityValue(
        summaryText: String,
        providerStatus: UsageStatus,
        metricSummary: MainLimitSummary?,
        isConnected: Bool,
        snapshotState: WidgetSnapshotState
    ) -> String {
        guard isConnected else { return "Setup needed" }
        var parts: [String]
        if let metricSummary {
            parts = [metricSummary.widgetPressureAccessibilityValue(snapshotState: snapshotState)]
            if providerStatus != metricSummary.status {
                let label = snapshotState == .stale ? "Last known provider status" : "Provider status"
                parts.append("\(label) \(providerStatus.widgetAccessibilityLabel)")
            }
        } else {
            parts = [summaryText]
            parts.append("Usage pressure unknown")
            if snapshotState == .stale {
                parts.append("Data stale")
            }
            let label = snapshotState == .stale ? "Last known provider status" : "Provider status"
            parts.append("\(label) \(providerStatus.widgetAccessibilityLabel)")
        }
        return parts.joined(separator: ". ")
    }
}

struct CPWEmptyRow: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            CPWStatusMark(status: .unknown, size: 9)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                .lineLimit(2)
        }
    }
}

struct CPWFastModeCard: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(CPWTheme.fastModeColor(snapshot.fastModeStatus))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.fastModeVerdict)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText(variant: themeVariant))
                    .lineLimit(1)
                Text(snapshot.fastModeDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText(variant: themeVariant))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(CPWTheme.line(variant: themeVariant).opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CPWUsagePressureBar: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let usedRatio: Double?
    let status: UsageStatus
    var height: CGFloat = 4

    private var metric: MetricProgress {
        .usedPressure(usedRatio: usedRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CPWTheme.line(variant: themeVariant))
                if let ratio = metric.ratio {
                    Capsule()
                        .fill(CPWTheme.statusColor(status))
                        .frame(width: proxy.size.width * ratio)
                } else {
                    Capsule()
                        .stroke(
                            CPWTheme.statusColor(.unknown),
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

struct CPWRemainingCapacityBar: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let remainingRatio: Double?
    let status: UsageStatus
    var height: CGFloat = 4

    private var metric: MetricProgress {
        .remainingCapacity(remainingRatio: remainingRatio)
    }

    var body: some View {
        GeometryReader { proxy in
            if let ratio = metric.ratio {
                ZStack(alignment: .leading) {
                    Capsule().fill(CPWTheme.line(variant: themeVariant))
                    Capsule()
                        .fill(CPWTheme.statusColor(status))
                        .frame(width: proxy.size.width * ratio)
                }
            } else {
                Capsule()
                    .stroke(
                        CPWTheme.statusColor(.unknown),
                        style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                    )
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remaining capacity")
        .accessibilityValue(metric.accessibilityValue)
    }
}

struct CPWBurnPaceBar: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let forecast: FastModeCapacityForecast?
    var isStale = false

    private var markerPosition: Double? {
        guard let ratio = forecast?.burnPaceRatio, ratio.isFinite else { return nil }
        if ratio <= 1 {
            return max(min(ratio * 0.5, 0.5), 0)
        }
        return min(0.5 + ((ratio - 1) / 2 * 0.5), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(CPWTheme.line(variant: themeVariant))
                    Capsule()
                        .fill(
                            isStale
                                ? CPWTheme.statusColor(.stale).opacity(0.82)
                                : CPWTheme.statusColor(.healthy).opacity(0.85)
                        )
                        .frame(width: width * 0.5)
                    Capsule()
                        .fill(
                            isStale
                                ? CPWTheme.statusColor(.stale).opacity(0.42)
                                : CPWTheme.statusColor(.limited).opacity(0.78)
                        )
                        .frame(width: width * 0.5)
                        .offset(x: width * 0.5)
                    Rectangle()
                        .fill(CPWTheme.primaryText(variant: themeVariant).opacity(0.72))
                        .frame(width: 1, height: 8)
                        .offset(x: width * 0.5)
                    if let markerPosition {
                        Circle()
                            .fill(CPWTheme.primaryText(variant: themeVariant))
                            .frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                            .offset(x: max(min(width * markerPosition - 3.5, width - 7), 0))
                    }
                }
            }
            .frame(height: 7)

            Text(forecast?.burnPaceCopy ?? "calibrating")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

struct CPWProviderBadge: View {
    let provider: Provider
    var compact = false

    var body: some View {
        Text(provider.shortName)
            .font(.system(size: compact ? 9 : 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(CPWTheme.providerColor(provider))
            .lineLimit(1)
    }
}

struct CPWStatusMark: View {
    let status: UsageStatus
    var size: CGFloat = 8

    var body: some View {
        Group {
            switch status {
            case .healthy:
                Circle().fill(CPWTheme.statusColor(status))
            case .close:
                Circle().trim(from: 0, to: 0.75).stroke(CPWTheme.statusColor(status), lineWidth: 2)
            case .limited:
                RoundedRectangle(cornerRadius: 1).fill(CPWTheme.statusColor(status))
            case .stale:
                Circle().stroke(CPWTheme.statusColor(status), style: StrokeStyle(lineWidth: 1.4, dash: [2, 2]))
            case .unknown:
                Text("?").font(.system(size: size + 3, weight: .semibold)).foregroundStyle(CPWTheme.statusColor(status))
            case .failure:
                Image(systemName: "xmark").font(.system(size: size, weight: .bold)).foregroundStyle(CPWTheme.statusColor(status))
            case .loading:
                Circle().stroke(CPWTheme.statusColor(status), lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CPWSectionHeader: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let title: String
    var trailing: String? = nil
    var accessory: CPWPromptCacheInlineStat? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
            if let accessory {
                accessory
            }
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
            }
        }
    }
}

struct CPWLabel: View {
    @Environment(\.cpwThemeVariant) private var themeVariant
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(CPWTheme.tertiaryText(variant: themeVariant))
    }
}

public enum CPWTheme {
    // Exposed so platform widget targets can apply the shared surface behind the rendered content.
    public static let surface = surface(variant: .adaptive)
    static let line = line(variant: .adaptive)
    static let primaryText = primaryText(variant: .adaptive)
    static let secondaryText = secondaryText(variant: .adaptive)
    static let tertiaryText = tertiaryText(variant: .adaptive)
    static let accent = Color(red: 74 / 255, green: 91 / 255, blue: 122 / 255)

    public static func surface(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor(red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1),
            dark: CPWPlatformColor(red: 32 / 255, green: 33 / 255, blue: 36 / 255, alpha: 1),
            variant: variant
        )
    }

    static func line(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor.black.withAlphaComponent(0.08),
            dark: CPWPlatformColor.white.withAlphaComponent(0.11),
            variant: variant
        )
    }

    static func primaryText(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1),
            dark: CPWPlatformColor(red: 239 / 255, green: 240 / 255, blue: 242 / 255, alpha: 1),
            variant: variant
        )
    }

    static func secondaryText(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor(red: 87 / 255, green: 87 / 255, blue: 92 / 255, alpha: 1),
            dark: CPWPlatformColor(red: 178 / 255, green: 180 / 255, blue: 186 / 255, alpha: 1),
            variant: variant
        )
    }

    static func tertiaryText(variant: CPWThemeVariant) -> Color {
        themedColor(
            light: CPWPlatformColor(red: 130 / 255, green: 130 / 255, blue: 136 / 255, alpha: 1),
            dark: CPWPlatformColor(red: 128 / 255, green: 131 / 255, blue: 139 / 255, alpha: 1),
            variant: variant
        )
    }

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

    static func fastModeColor(_ recommendation: FastModeRecommendation?) -> Color {
        switch recommendation {
        case .safeThroughReset:
            statusColor(.healthy)
        case .safeForLimitedTime:
            statusColor(.close)
        case .saveFastMode, .limited:
            statusColor(.limited)
        case .needsCalibration, nil:
            statusColor(.unknown)
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
        case .stale:
            adaptiveColor(
                light: CPWPlatformColor(red: 122 / 255, green: 98 / 255, blue: 63 / 255, alpha: 1),
                dark: CPWPlatformColor(red: 194 / 255, green: 168 / 255, blue: 117 / 255, alpha: 1)
            )
        case .unknown, .loading:
            Color(red: 106 / 255, green: 106 / 255, blue: 114 / 255)
        }
    }

    private static func themedColor(
        light: CPWPlatformColor,
        dark: CPWPlatformColor,
        variant: CPWThemeVariant
    ) -> Color {
        switch variant {
        case .adaptive:
            adaptiveColor(light: light, dark: dark)
        case .light:
            fixedColor(light)
        case .dark:
            fixedColor(dark)
        }
    }

    #if canImport(AppKit)
    private static func fixedColor(_ color: NSColor) -> Color {
        Color(nsColor: color)
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        })
    }
    #elseif canImport(UIKit)
    private static func fixedColor(_ color: UIColor) -> Color {
        Color(uiColor: color)
    }

    private static func adaptiveColor(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
    #else
    private static func fixedColor(_ color: Color) -> Color {
        color
    }

    private static func adaptiveColor(light: Color, dark: Color) -> Color {
        light
    }
    #endif
}

private extension MainLimitWindow {
    func placeholderWidgetLine(provider: Provider) -> String {
        switch self {
        case .availability where provider == .google:
            "Google reset window"
        default:
            displayName
        }
    }
}

extension UsageLimit {
    var widgetRemainingHeadline: String {
        guard let remaining else {
            if status == .failure { return "Failed" }
            return provider == .anthropic ? "Awaiting data" : "Unknown"
        }
        let prefix = isAssumedAfterScheduledReset ? "≈" : ""
        if unit == .percent { return "\(prefix)\(remaining)% left" }
        return "\(prefix)\(remaining) left"
    }

    var widgetUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "limit not reported"
        }
        let prefix = isAssumedAfterScheduledReset ? "≈" : ""
        if unit == .percent, let used {
            return "\(prefix)\(used)% used"
        }
        if let used, let limit {
            return "\(prefix)\(used)/\(limit) used"
        }
        if status == .failure { return "refresh failed" }
        return provider == .anthropic ? "awaiting data" : "unknown"
    }

    var widgetWindowLine: String {
        [provider.shortName, accountName, displayLabel, modelLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .deduplicated()
            .joined(separator: " · ")
    }

    var widgetResetText: String? {
        if isAssumedAfterScheduledReset { return "assumed reset" }
        guard let resetsAt else {
            if status == .failure { return "refresh failed" }
            return provider == .anthropic ? nil : "unknown reset"
        }
        if resetsAt < Date().addingTimeInterval(-60) {
            return "reset passed"
        }
        return resetsAt.widgetCompactResetText
    }

    var widgetResetConfidenceText: String? {
        if isAssumedAfterScheduledReset { return "assumed after reset" }
        guard let resetText = widgetResetText, !resetText.isEmpty else { return nil }
        if confidence.shouldShowWidgetResetQualifier {
            return "\(resetText) · \(confidence.widgetLabel)"
        }
        return resetText
    }
}

extension WidgetSnapshot {
    var shouldShowSetupPlaceholder: Bool {
        state == .setupNeeded && mainLimitSummaries.isEmpty
    }

    var shouldShowMainLimitEmptyRow: Bool {
        mainLimitSummaries.isEmpty
    }

    var mainLimitSummaries: [MainLimitSummary] {
        usageSnapshot.mainLimitSummaries
    }

    var mostConstrainedMainLimitSummaries: [MainLimitSummary] {
        usageSnapshot.mostConstrainedMainLimitSummaries
    }

    func visibleMainLimitLanes(
        displayPreferences: WidgetDisplayPreferences,
        maximumCount: Int = 4
    ) -> [WidgetMainLimitLane] {
        displayPreferences.visibleMainLimitLanes(from: mainLimitSummaries, maximumCount: maximumCount)
    }

    var providerPressureText: String {
        let limited = mainLimitSummaries.filter { $0.status == .limited }.count
        let close = mainLimitSummaries.filter { $0.status == .close }.count
        if limited > 0 || close > 0 {
            return "\(limited) limited · \(close) close"
        }
        return "all healthy"
    }

    var fastModeForecast: FastModeCapacityForecast? {
        mainLimitSummaries.openAIFastModeCapacityForecast(
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings
        ).bestForecast
    }

    var fastModeStatus: FastModeRecommendation? {
        fastModeForecast?.recommendation
    }

    var fastModeVerdict: String {
        if needsProviderConnection { return "Connect accounts to track limits" }
        return fastModeForecast?.copy ?? message
    }

    var fastModeDetail: String {
        if needsProviderConnection { return "Open the app to connect OpenAI, Claude, or Google." }
        return mainLimitSummaries.openAIFastModeCapacityForecast(
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings
        ).detailCopy
    }

    var fastModeResetDetail: String {
        if needsProviderConnection { return "limits appear after setup" }
        guard let resetAt = fastModeForecast?.nextResetAt else { return "next reset unknown" }
        return "reset \(resetAt.widgetDateTimeWithRelativeText)"
    }

    var widgetProblemText: String? {
        if syncErrorMessage != nil { return "Mac update failed" }
        if let providerAccessProblemText { return providerAccessProblemText }
        switch state {
        case .failure:
            return "Reconnect account"
        case .stale:
            return requiresProviderReconnect ? widgetReconnectTitle : refreshAttentionSummary?.refreshNeededTitle ?? "Saved usage"
        case .setupNeeded:
            return limits.isEmpty ? nil : "Setup needed"
        case .ready:
            if needsProviderConnection { return "Setup needed" }
            if let refreshAttentionSummary {
                return requiresProviderReconnect ? widgetReconnectTitle : refreshAttentionSummary.refreshNeededTitle
            }
            if status == .failure { return "Provider refresh needed" }
            if status == .stale {
                return requiresProviderReconnect ? widgetReconnectTitle : refreshAttentionSummary?.refreshNeededTitle ?? "Saved usage"
            }
            if status == .unknown { return "Awaiting data" }
            return nil
        }
    }

    var widgetProblemStatus: UsageStatus {
        if syncErrorMessage != nil || requiresProviderReconnect || state == .failure || status == .failure {
            return .failure
        }
        if let alert = primaryProviderAccessAlert {
            return alert.status
        }
        if refreshAttentionSummary != nil || state == .stale || status == .stale {
            return .stale
        }
        return status
    }

    private var providerAccessProblemText: String? {
        guard state != .failure,
              status != .failure,
              !requiresProviderReconnect,
              let alert = primaryProviderAccessAlert
        else { return nil }
        if let resetsAt = alert.accessState.resetsAt {
            return "\(alert.title) · reset \(resetsAt.widgetDateTimeWithRelativeText)"
        }
        return alert.title
    }

    func widgetDeepLinkURL(links: ContextPanelWidgetLinks) -> URL {
        if syncErrorMessage != nil { return links.overview }
        return switch state {
        case .failure:
            links.reconnect
        case .stale:
            requiresProviderReconnect ? links.reconnect : links.overview
        case .ready:
            if needsProviderConnection || requiresProviderReconnect {
                links.reconnect
            } else if promptCacheWidgetState == .needsAuthorization {
                links.cacheStatsSettings
            } else {
                links.overview
            }
        case .setupNeeded:
            promptCacheWidgetState == .needsAuthorization ? links.cacheStatsSettings : links.overview
        }
    }

    private var requiresProviderReconnect: Bool {
        reports.reconnectBlockingFailures(coveredBy: limits).contains(where: \.requiresCredentialReconnect)
    }

    private var widgetReconnectTitle: String {
        if let provider = refreshAttentionSummary?.singleProvider {
            return "\(provider.displayName) reconnect needed"
        }
        return "Account reconnect needed"
    }

    func widgetProviderSummaryText(provider: Provider) -> String {
        let providerLimits = limits.filter { $0.provider == provider }
        guard let tightest = widgetProviderMainLimitSummary(provider: provider) else {
            if needsProviderConnection {
                return "not connected"
            }
            return providerLimits.isEmpty ? "setup needed" : "usage unknown"
        }
        return "\(tightest.widgetCompactWindowName) \(tightest.widgetUsageText.lowercased())"
    }

    func widgetPresentationStatus(for status: UsageStatus) -> UsageStatus {
        state == .stale ? .stale : status
    }

    func widgetProviderMainLimitSummary(provider: Provider) -> MainLimitSummary? {
        let summaries = mainLimitSummaries.filter { $0.provider == provider }
        let determinate = summaries.filter { $0.widgetUsageRatio != nil }
        return determinate.max {
            ($0.widgetUsageRatio ?? 0) < ($1.widgetUsageRatio ?? 0)
        } ?? summaries.first
    }

    private static func format(hours: Double) -> String {
        if hours < 1 {
            return "\(max(Int((hours * 60).rounded()), 1))m"
        }
        if hours < 10 {
            let rounded = (hours * 2).rounded() / 2
            if rounded == rounded.rounded() { return "\(Int(rounded))h" }
            return "\(rounded)h"
        }
        return "\(Int(hours.rounded()))h"
    }
}

extension MainLimitSummary {
    var widgetUsageRatio: Double? {
        let numericLimits = lastKnownCapacityLimits
        guard let unit = numericLimits.first?.unit,
              numericLimits.allSatisfy({ $0.unit == unit }) else {
            return nil
        }
        let used = numericLimits.reduce(0) { $0 + ($1.used ?? 0) }
        let limit = numericLimits.reduce(0) { $0 + ($1.limit ?? 0) }
        guard limit > 0 else { return nil }
        return min(max(Double(used) / Double(limit), 0), 1)
    }

    var widgetRemainingCapacityRatio: Double? {
        widgetUsageRatio.map { max(1 - $0, 0) }
    }

    var widgetRemainingHeadline: String {
        let prefix = hasAssumedScheduledResetCapacity ? "≈" : ""
        if let remainingRatio = widgetRemainingCapacityRatio {
            return "\(prefix)\(Int((remainingRatio * 100).rounded()))% left"
        }
        guard unit != nil, remaining != nil else {
            if status == .failure { return "Failed" }
            if provider == .anthropic { return "Awaiting data" }
            return "Unknown"
        }
        guard let remaining else { return "Unknown" }
        return "\(prefix)\(remaining) left"
    }

    var widgetUsageText: String {
        let prefix = hasAssumedScheduledResetCapacity ? "≈" : ""
        if let usageRatio = widgetUsageRatio {
            return "\(prefix)\(Int((usageRatio * 100).rounded()))% used"
        }
        guard unit != nil, used != nil, limit != nil else {
            if provider == .anthropic, status != .failure {
                return "limit not reported"
            }
            return status == .failure ? "refresh failed" : "unknown"
        }
        guard let used, let limit else { return "unknown" }
        return "\(prefix)\(used)/\(limit) used"
    }

    var widgetFreshnessAccessibilityLabel: String? {
        widgetFreshnessAccessibilityLabel(snapshotState: nil)
    }

    func widgetFreshnessAccessibilityLabel(snapshotState: WidgetSnapshotState?) -> String? {
        if snapshotState == .stale {
            return "Data stale"
        }
        if snapshotState == .failure {
            return "Refresh failed"
        }
        if limits.contains(where: { $0.status == .failure }) {
            return "Refresh failed"
        }
        if limits.contains(where: { $0.status == .stale }) {
            return "Data stale"
        }
        if limits.contains(where: { $0.status == .loading }) {
            return "Refreshing"
        }
        return nil
    }

    var widgetPressureAccessibilityValue: String {
        widgetPressureAccessibilityValue(snapshotState: nil)
    }

    func widgetPressureAccessibilityValue(snapshotState: WidgetSnapshotState?) -> String {
        let statusLabel = snapshotState == .stale ? "Last known main limit status" : "Main limit status"
        var parts = [
            accessibilityQuantity(widgetUsageText),
            "\(statusLabel) \(status.widgetAccessibilityLabel)",
        ]
        if let freshness = widgetFreshnessAccessibilityLabel(snapshotState: snapshotState) {
            parts.append(freshness)
        }
        if hasAssumedScheduledResetCapacity {
            parts.append(UsagePresentationAssumption.scheduledReset.accessibilityText)
        } else if let reset = widgetResetConfidenceText {
            parts.append("Reset \(reset)")
        }
        return parts.joined(separator: ". ")
    }

    func widgetCapacityAccessibilityValue(snapshotState: WidgetSnapshotState?) -> String {
        let statusLabel = snapshotState == .stale || snapshotState == .failure
            ? "Last known main limit status"
            : "Main limit status"
        var parts = [
            accessibilityQuantity(widgetRemainingHeadline),
            "\(statusLabel) \(status.widgetAccessibilityLabel)",
        ]
        if let freshness = widgetFreshnessAccessibilityLabel(snapshotState: snapshotState) {
            parts.append(freshness)
        }
        if hasAssumedScheduledResetCapacity {
            parts.append(UsagePresentationAssumption.scheduledReset.accessibilityText)
        } else if let reset = widgetResetConfidenceText {
            parts.append("Reset \(reset)")
        }
        return parts.joined(separator: ". ")
    }

    var widgetWindowLine: String {
        let accounts = accountCount == 1 ? "1 account" : "\(accountCount) accounts"
        return "\(widgetWindowName) · \(accounts)"
    }

    var widgetSmallLaneWindowLine: String {
        let accounts = accountCount == 1 ? "1 acct" : "\(accountCount) accts"
        return "\(widgetCompactWindowName) · \(accounts)"
    }

    var widgetSmallResetConfidenceText: String? {
        if hasAssumedScheduledResetCapacity { return "≈ reset" }
        guard let resetsAt else {
            if status == .failure {
                return "failed"
            }
            return provider == .anthropic ? nil : "reset ?"
        }
        if resetsAt < Date().addingTimeInterval(-60) {
            return "passed"
        }
        let relative = resetsAt.widgetRelativeText
        let compactRelative = relative.hasPrefix("in ") ? String(relative.dropFirst(3)) : relative
        if confidence.shouldShowWidgetResetQualifier {
            return "\(compactRelative) · \(confidence.widgetSmallLabel)"
        }
        return compactRelative
    }

    var widgetWindowName: String {
        displayWindowName
    }

    var widgetCompactWindowName: String {
        compactDisplayWindowName
    }

    var widgetResetText: String? {
        if hasAssumedScheduledResetCapacity { return "assumed reset" }
        guard let resetsAt else {
            if status == .failure {
                return "refresh failed"
            }
            if provider == .anthropic {
                return nil
            }
            return "unknown reset"
        }
        if resetsAt < Date().addingTimeInterval(-60) {
            return "reset passed"
        }
        return resetsAt.widgetCompactResetText
    }

    var widgetResetConfidenceText: String? {
        if hasAssumedScheduledResetCapacity { return "assumed after reset" }
        guard let resetText = widgetResetText, !resetText.isEmpty else {
            return nil
        }
        if confidence.shouldShowWidgetResetQualifier {
            return "\(resetText) · \(confidence.widgetLabel)"
        }
        return resetText
    }

    private func accessibilityQuantity(_ text: String) -> String {
        guard hasAssumedScheduledResetCapacity else { return text }
        return text.replacingOccurrences(of: "≈", with: "approximately ")
    }
}

extension UsageStatus {
    var widgetAccessibilityLabel: String {
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

    var widgetLabel: String {
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

    var shouldShowWidgetIssue: Bool {
        switch self {
        case .failure, .stale, .unknown, .limited:
            true
        case .healthy, .close, .loading:
            false
        }
    }

    func shouldShowWidgetProviderStatus(relativeTo metricStatus: UsageStatus) -> Bool {
        shouldShowWidgetIssue || (self == .close && self != metricStatus)
    }
}

extension UsageConfidence {
    var widgetLabel: String {
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

    var shouldShowWidgetResetQualifier: Bool {
        switch self {
        case .manual, .estimated, .unknown:
            true
        case .official, .observed:
            false
        }
    }

    var widgetSmallLabel: String {
        switch self {
        case .official:
            "official"
        case .observed:
            "observed"
        case .manual:
            "manual"
        case .estimated:
            "est."
        case .unknown:
            "uncertain"
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

    var widgetCompactResetText: String {
        let relative = widgetRelativeText
        let compactRelative = relative.hasPrefix("in ") ? String(relative.dropFirst(3)) : relative
        if shouldShowWidgetDateTime {
            return "\(compactRelative) · \(widgetDateTimeText)"
        }
        return compactRelative
    }

    var widgetDateTimeWithRelativeText: String {
        let relative = widgetRelativeText
        let compactRelative = relative.hasPrefix("in ") ? String(relative.dropFirst(3)) : relative
        if shouldShowWidgetDateTime {
            return "\(widgetDateTimeText) (\(compactRelative))"
        }
        return compactRelative
    }

    var shouldShowWidgetDateTime: Bool {
        abs(timeIntervalSince(Date())) >= 24 * 3_600
    }

    var widgetDateTimeText: String {
        Self.widgetDateTimeFormatter.string(from: self)
    }

    private static let widgetDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        return formatter
    }()

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
