import ContextPanelCore
import AppKit
import SwiftUI
import WidgetKit

struct CPWSetupPlaceholderWidget: View {
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
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text("Set up Context Panel")
                .font(.system(size: isSmall ? 19 : 23, weight: .semibold))
                .foregroundStyle(CPWTheme.primaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

            Text("Open the app to add your first account.")
                .font(.system(size: isSmall ? 11 : 13, weight: .medium))
                .foregroundStyle(CPWTheme.secondaryText)
                .lineLimit(isSmall ? 2 : 1)
                .minimumScaleFactor(0.88)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Open app")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(CPWTheme.secondaryText)
            }
            .accessibilityHidden(true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContextPanelSmallWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let problem = snapshot.widgetProblemText {
                CPWProblemLabel(problem, status: snapshot.status)
            }
            Spacer(minLength: 4)
            if let tightest = snapshot.tightestMainLimitSummary {
                Text(tightest.widgetRemainingHeadline)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPWTheme.primaryText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(tightest.widgetSmallWindowLine)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                    .minimumScaleFactor(0.85)
                    .lineLimit(2)
                Text(tightest.widgetResetConfidenceText)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
                CPWCapacityBar(value: tightest.usageRatio ?? 0, status: tightest.status, height: 6)
            } else {
                Text("Set up accounts")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(2)
                Text(snapshot.message)
                    .font(.system(size: 11))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            CPWProviderMiniStatus(snapshot: snapshot)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContextPanelMediumWidget: View {
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                if let problem = snapshot.widgetProblemText {
                    CPWProblemLabel(problem, status: snapshot.status)
                }
                Spacer(minLength: 0)
                CPWGlanceNumber(snapshot: snapshot)
                Text(snapshot.fastModeVerdict)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(2)
                Text(snapshot.fastModeDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
                Text(snapshot.fastModeResetDetail)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 0)
            }
            .frame(width: 134, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                let lanes = snapshot.visibleMainLimitLanes(
                    displayPreferences: displayPreferences,
                    maximumCount: 3
                )
                CPWSectionHeader(title: "Main Limits")
                ForEach(lanes) { lane in
                    CPWMainLimitRow(lane: lane)
                }
                if snapshot.limits.isEmpty {
                    CPWEmptyRow(message: snapshot.message)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ContextPanelLargeWidget: View {
    let snapshot: WidgetSnapshot
    let displayPreferences: WidgetDisplayPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if let problem = snapshot.widgetProblemText {
                        CPWProblemLabel(problem, status: snapshot.status)
                    }
                    Text(snapshot.fastModeVerdict)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(CPWTheme.primaryText)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                    Text(snapshot.fastModeDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                        .lineLimit(1)
                    Text(snapshot.fastModeResetDetail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CPWTheme.tertiaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                Spacer()
                CPWGlanceNumber(snapshot: snapshot)
            }

            CPWProviderSummaryGrid(snapshot: snapshot, compact: true)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                let lanes = snapshot.visibleMainLimitLanes(
                    displayPreferences: displayPreferences,
                    maximumCount: 5
                )
                CPWSectionHeader(title: "Main Limits")
                ForEach(lanes) { lane in
                    CPWMainLimitRow(lane: lane)
                }
                if snapshot.limits.isEmpty {
                    CPWEmptyRow(message: snapshot.message)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(snapshot.tightestHeadline)
                .font(.system(size: 28, weight: .semibold, design: .monospaced))
                .foregroundStyle(CPWTheme.primaryText)
                .minimumScaleFactor(0.65)
                .lineLimit(1)
            Text(snapshot.tightestSubheadline)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(CPWTheme.secondaryText)
                .lineLimit(2)
            CPWBurnPaceBar(forecast: snapshot.fastModeForecast)
        }
        .frame(width: 94, alignment: .leading)
    }
}

struct CPWMainLimitRow: View {
    let summary: MainLimitSummary?
    let fallbackProvider: Provider
    let fallbackWindow: MainLimitWindow

    init(summary: MainLimitSummary) {
        self.summary = summary
        fallbackProvider = summary.provider
        fallbackWindow = summary.window
    }

    init(lane: WidgetMainLimitLane) {
        summary = lane.summary
        fallbackProvider = lane.provider
        fallbackWindow = lane.window
    }

    private var provider: Provider {
        summary?.provider ?? fallbackProvider
    }

    private var status: UsageStatus {
        summary?.status ?? .unknown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                CPWProviderBadge(provider: provider, compact: true)
                Text(summary?.widgetWindowLine ?? fallbackWindow.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(summary?.widgetUsageText ?? "No data yet")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPWTheme.secondaryText)
            }
            HStack(spacing: 6) {
                CPWCapacityBar(value: summary?.usageRatio ?? 0, status: status)
                Text(summary?.widgetResetConfidenceText ?? "no reset data")
                    .font(.system(size: 9))
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .lineLimit(1)
                    .frame(minWidth: 72, alignment: .trailing)
            }
        }
    }
}

struct CPWProviderSummaryGrid: View {
    let snapshot: WidgetSnapshot
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 10 : 12) {
            ForEach(Provider.allCases) { provider in
                let summaries = snapshot.mainLimitSummaries.filter { $0.provider == provider }
                let status = summaries.map(\.status).contextPanelWorstStatus
                VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                    HStack(spacing: 5) {
                        CPWProviderBadge(provider: provider, compact: true)
                        if status.shouldShowWidgetIssue {
                            Text(status.widgetLabel)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(CPWTheme.statusColor(status))
                                .textCase(.uppercase)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(snapshot.widgetProviderSummaryText(provider: provider))
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                        .lineLimit(compact ? 1 : 2)
                    CPWCapacityBar(value: summaries.map { $0.usageRatio ?? 0 }.max() ?? 0, status: status, height: 5)
                }
                .opacity(summaries.isEmpty ? 0.45 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CPWProviderMiniStatus: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Provider.allCases) { provider in
                let hasMainLimits = snapshot.mainLimitSummaries.contains { $0.provider == provider }
                Text(provider.shortName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(hasMainLimits ? CPWTheme.providerColor(provider) : CPWTheme.tertiaryText)
                    .lineLimit(1)
                    .opacity(hasMainLimits ? 1 : 0.35)
            }
        }
    }
}

struct CPWEmptyRow: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            CPWStatusMark(status: .unknown, size: 9)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CPWTheme.secondaryText)
                .lineLimit(2)
        }
    }
}

struct CPWFastModeCard: View {
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
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(1)
                Text(snapshot.fastModeDetail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(CPWTheme.line.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct CPWCapacityBar: View {
    let value: Double
    let status: UsageStatus
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CPWTheme.line)
                Capsule()
                    .fill(CPWTheme.statusColor(status))
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: height)
    }
}

struct CPWBurnPaceBar: View {
    let forecast: FastModeCapacityForecast?

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
                    Capsule().fill(CPWTheme.line)
                    Capsule()
                        .fill(CPWTheme.statusColor(.healthy).opacity(0.85))
                        .frame(width: width * 0.5)
                    Capsule()
                        .fill(CPWTheme.statusColor(.limited).opacity(0.78))
                        .frame(width: width * 0.5)
                        .offset(x: width * 0.5)
                    Rectangle()
                        .fill(CPWTheme.primaryText.opacity(0.72))
                        .frame(width: 1, height: 8)
                        .offset(x: width * 0.5)
                    if let markerPosition {
                        Circle()
                            .fill(CPWTheme.primaryText)
                            .frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                            .offset(x: max(min(width * markerPosition - 3.5, width - 7), 0))
                    }
                }
            }
            .frame(height: 7)

            Text(forecast?.burnPaceCopy ?? "calibrating")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(CPWTheme.tertiaryText)
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
    let title: String
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(CPWTheme.tertiaryText)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(CPWTheme.tertiaryText)
            }
        }
    }
}

struct CPWLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(CPWTheme.tertiaryText)
    }
}

enum CPWTheme {
    static let surface = adaptiveColor(
        light: NSColor(red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1),
        dark: NSColor(red: 32 / 255, green: 33 / 255, blue: 36 / 255, alpha: 1)
    )
    static let line = adaptiveColor(
        light: NSColor.black.withAlphaComponent(0.08),
        dark: NSColor.white.withAlphaComponent(0.11)
    )
    static let primaryText = adaptiveColor(
        light: NSColor(red: 10 / 255, green: 10 / 255, blue: 11 / 255, alpha: 1),
        dark: NSColor(red: 239 / 255, green: 240 / 255, blue: 242 / 255, alpha: 1)
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
        case .stale, .unknown, .loading:
            Color(red: 106 / 255, green: 106 / 255, blue: 114 / 255)
        }
    }

    private static func adaptiveColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        })
    }
}

extension UsageLimit {
    var widgetRemainingHeadline: String {
        guard let remaining else {
            if status == .failure { return "Failed" }
            return "Unknown"
        }
        if unit == .percent { return "\(remaining)% left" }
        return "\(remaining) left"
    }

    var widgetUsageText: String {
        if provider == .anthropic, unit == .unknown, status == .unknown {
            return "limit unknown"
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

    var widgetWindowLine: String {
        [provider.shortName, accountName, displayLabel, modelLabel]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .deduplicated()
            .joined(separator: " · ")
    }

    var widgetResetText: String {
        guard let resetsAt else {
            return status == .failure ? "refresh failed" : "unknown reset"
        }
        if resetsAt < Date().addingTimeInterval(-60) {
            return "reset passed"
        }
        return resetsAt.widgetCompactResetText
    }

    var widgetResetConfidenceText: String {
        if confidence.shouldShowWidgetResetQualifier {
            return "\(widgetResetText) · \(confidence.widgetLabel)"
        }
        return widgetResetText
    }
}

extension WidgetSnapshot {
    var shouldShowSetupPlaceholder: Bool {
        state == .setupNeeded && limits.isEmpty
    }

    var mainLimitSummaries: [MainLimitSummary] {
        usageSnapshot.mainLimitSummaries
    }

    var mostConstrainedMainLimitSummaries: [MainLimitSummary] {
        usageSnapshot.mostConstrainedMainLimitSummaries
    }

    var largeWidgetMainLimitSummaries: [MainLimitSummary] {
        mainLimitSummaries.sorted { lhs, rhs in
            let lhsPriority = lhs.defaultWidgetSortRank
            let rhsPriority = rhs.defaultWidgetSortRank
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return (lhs.usageRatio ?? 0) > (rhs.usageRatio ?? 0)
        }
    }

    var tightestMainLimitSummary: MainLimitSummary? {
        largeWidgetMainLimitSummaries.first ?? mostConstrainedMainLimitSummaries.first
    }

    func visibleMainLimitLanes(
        displayPreferences: WidgetDisplayPreferences,
        maximumCount: Int = 4
    ) -> [WidgetMainLimitLane] {
        displayPreferences.visibleMainLimitLanes(from: mainLimitSummaries, maximumCount: maximumCount)
    }

    var tightestHeadline: String {
        tightestMainLimitSummary?.widgetRemainingHeadline ?? "No data"
    }

    var tightestSubheadline: String {
        guard let summary = tightestMainLimitSummary else { return message }
        return "\(summary.provider.shortName) \(summary.window.displayName)"
    }

    var tightestUsageRatio: Double {
        tightestMainLimitSummary?.usageRatio ?? 0
    }

    var tightestCapacityRatio: Double {
        guard let ratio = tightestMainLimitSummary?.usageRatio else { return 0 }
        return max(1 - ratio, 0)
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
        fastModeForecast?.copy ?? message
    }

    var fastModeDetail: String {
        mainLimitSummaries.openAIFastModeCapacityForecast(
            observedBurnRates: observedBurnRates,
            settings: fastModeForecastSettings
        ).detailCopy
    }

    var fastModeResetDetail: String {
        guard let resetAt = fastModeForecast?.nextResetAt else { return "next reset unknown" }
        if resetAt.shouldShowWidgetDateTime {
            return "next reset \(resetAt.widgetDateTimeText)"
        }
        return "next reset \(resetAt.widgetCompactResetText)"
    }

    var widgetProblemText: String? {
        switch state {
        case .failure:
            return "Update failed"
        case .stale:
            return "Old data"
        case .setupNeeded:
            return limits.isEmpty ? nil : "Setup needed"
        case .ready:
            if status == .failure { return "Update failed" }
            if status == .stale { return "Old data" }
            if status == .unknown { return "Awaiting data" }
            return nil
        }
    }

    func widgetProviderSummaryText(provider: Provider) -> String {
        let summaries = mainLimitSummaries.filter { $0.provider == provider }
        guard !summaries.isEmpty else { return "setup needed" }
        guard let tightest = summaries.sorted(by: { ($0.usageRatio ?? 0) > ($1.usageRatio ?? 0) }).first else {
            return "setup needed"
        }
        return "\(tightest.window.shortName) \(tightest.widgetRemainingHeadline.lowercased())"
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
    var widgetRemainingHeadline: String {
        guard unit != nil, remaining != nil else {
            if status == .failure { return "Failed" }
            return "Unknown"
        }
        if usageRatio != nil {
            return "\(Int((capacityRatio * 100).rounded()))% left"
        }
        guard let remaining else { return "Unknown" }
        return "\(remaining) left"
    }

    var widgetUsageText: String {
        guard unit != nil, used != nil, limit != nil else {
            return status == .failure ? "refresh failed" : "unknown"
        }
        if usageRatio != nil {
            return "\(Int(((usageRatio ?? 0) * 100).rounded()))% used"
        }
        guard let used, let limit else { return "unknown" }
        return "\(used)/\(limit) used"
    }

    var widgetWindowLine: String {
        let accounts = accountCount == 1 ? "1 account" : "\(accountCount) accounts"
        return "\(window.displayName) · \(accounts)"
    }

    var widgetSmallWindowLine: String {
        let accounts = accountCount == 1 ? "1 acct" : "\(accountCount) accts"
        return "\(provider.shortName) \(window.displayName) · \(accounts)"
    }

    var widgetResetText: String {
        guard let resetsAt else {
            return status == .failure ? "refresh failed" : "unknown reset"
        }
        if resetsAt < Date().addingTimeInterval(-60) {
            return "reset passed"
        }
        return resetsAt.widgetCompactResetText
    }

    var widgetResetConfidenceText: String {
        if confidence.shouldShowWidgetResetQualifier {
            return "\(widgetResetText) · \(confidence.widgetLabel)"
        }
        return widgetResetText
    }
}

extension UsageStatus {
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

    var widgetCompactResetText: String {
        let relative = widgetRelativeText
        let compactRelative = relative.hasPrefix("in ") ? String(relative.dropFirst(3)) : relative
        if shouldShowWidgetDateTime {
            return "\(compactRelative) · \(widgetDateTimeText)"
        }
        return compactRelative
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
