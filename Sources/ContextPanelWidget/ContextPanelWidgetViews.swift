import ContextPanelCore
import SwiftUI

struct ContextPanelSmallWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            CPWHeader(status: snapshot.status, text: snapshot.generatedAt.widgetRelativeText)
            Spacer(minLength: 4)
            if let tightest = snapshot.mostConstrainedLimits.first {
                Text(tightest.widgetRemainingHeadline)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPWTheme.primaryText)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text(tightest.widgetWindowLine)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
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
        .padding(16)
    }
}

struct ContextPanelMediumWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                CPWHeader(status: snapshot.status, text: snapshot.generatedAt.widgetRelativeText)
                Spacer(minLength: 0)
                CPWGlanceNumber(snapshot: snapshot)
                Text(snapshot.fastModeVerdict)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(width: 142, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                CPWSectionHeader(title: "Tightest Windows", trailing: "\(snapshot.limits.count) limits")
                ForEach(snapshot.mostConstrainedLimits.prefix(4)) { limit in
                    CPWLimitRow(limit: limit)
                }
                if snapshot.limits.isEmpty {
                    CPWEmptyRow(message: snapshot.message)
                }
            }
        }
        .padding(16)
    }
}

struct ContextPanelLargeWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    CPWLabel("Context Panel")
                    Text(snapshot.fastModeVerdict)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CPWTheme.primaryText)
                        .lineLimit(2)
                    Text(snapshot.generatedAt.widgetRelativeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                        .textCase(.uppercase)
                }
                Spacer()
                CPWGlanceNumber(snapshot: snapshot)
            }

            CPWProviderSummaryGrid(snapshot: snapshot)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                CPWFastModeCard(snapshot: snapshot)

                CPWSectionHeader(title: "Tightest Windows", trailing: snapshot.providerPressureText)
                ForEach(snapshot.mostConstrainedLimits.prefix(6)) { limit in
                    CPWLimitRow(limit: limit)
                }
                if snapshot.limits.isEmpty {
                    CPWEmptyRow(message: snapshot.message)
                }
            }
        }
        .padding(16)
    }
}

struct CPWHeader: View {
    let status: UsageStatus
    var text = "Context Panel"

    var body: some View {
        HStack {
            CPWLabel(text)
            Spacer()
            Text(status.widgetLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(CPWTheme.statusColor(status))
                .textCase(.uppercase)
        }
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
            CPWCapacityBar(value: snapshot.tightestUsageRatio, status: snapshot.status, height: 6)
        }
        .frame(width: 94, alignment: .leading)
    }
}

struct CPWLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CPWProviderBadge(provider: limit.provider, compact: true)
                Text(limit.widgetWindowLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(limit.widgetUsageText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPWTheme.secondaryText)
            }
            HStack(spacing: 8) {
                CPWCapacityBar(value: limit.usageRatio ?? 0, status: limit.status)
                Text(limit.widgetResetConfidenceText)
                    .font(.system(size: 10))
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .lineLimit(1)
            }
        }
    }
}

struct CPWProviderSummaryGrid: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(snapshot.providerSummaries, id: \.provider) { summary in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(summary.provider.displayName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(CPWTheme.providerColor(summary.provider))
                            .lineLimit(1)
                        Spacer()
                        Text(summary.status.widgetLabel)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(CPWTheme.statusColor(summary.status))
                            .textCase(.uppercase)
                    }
                    Text(summary.widgetSummaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                        .lineLimit(2)
                    CPWCapacityBar(value: 1 - summary.capacityRatio, status: summary.status, height: 5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct CPWProviderMiniStatus: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        HStack(spacing: 12) {
            ForEach(snapshot.providerSummaries, id: \.provider) { summary in
                Text(summary.provider.shortName)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(summary.limitCount == 0 ? CPWTheme.tertiaryText : CPWTheme.providerColor(summary.provider))
                    .lineLimit(1)
                    .opacity(summary.limitCount == 0 ? 0.35 : 1)
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
    static let surface = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    static let line = Color.black.opacity(0.08)
    static let primaryText = Color(red: 10 / 255, green: 10 / 255, blue: 11 / 255)
    static let secondaryText = primaryText.opacity(0.66)
    static let tertiaryText = primaryText.opacity(0.46)
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
        return "resets \(resetsAt.widgetRelativeText)"
    }

    var widgetResetConfidenceText: String {
        "\(widgetResetText) · \(confidence.widgetLabel)"
    }
}

extension WidgetSnapshot {
    var tightestHeadline: String {
        mostConstrainedLimits.first?.widgetRemainingHeadline ?? "No data"
    }

    var tightestSubheadline: String {
        guard let limit = mostConstrainedLimits.first else { return message }
        return "\(limit.provider.shortName) \(limit.displayLabel)"
    }

    var tightestUsageRatio: Double {
        mostConstrainedLimits.first?.usageRatio ?? 0
    }

    var tightestCapacityRatio: Double {
        guard let ratio = mostConstrainedLimits.first?.usageRatio else { return 0 }
        return max(1 - ratio, 0)
    }

    var providerPressureText: String {
        let limited = limits.filter { $0.status == .limited }.count
        let close = limits.filter { $0.status == .close }.count
        if limited > 0 || close > 0 {
            return "\(limited) limited · \(close) close"
        }
        return "all healthy"
    }

    var fastModeForecast: FastModeForecast? {
        let forecasts = limits
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
        return FastModePortfolioForecast(forecasts: forecasts).bestForecast
    }

    var fastModeStatus: FastModeRecommendation? {
        fastModeForecast?.recommendation
    }

    var fastModeVerdict: String {
        fastModeForecast?.copy ?? message
    }

    var fastModeDetail: String {
        guard let forecast = fastModeForecast else { return "OpenAI account needed for fast-mode forecast" }
        let runway = forecast.fastModeRunwayHours.map { "runway \(Self.format(hours: $0))" } ?? "runway unknown"
        let reset = forecast.hoursUntilReset.map { "reset \(Self.format(hours: $0))" } ?? "reset unknown"
        return "\(forecast.accountName) · \(runway) · \(reset)"
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

extension ProviderSummary {
    var widgetSummaryText: String {
        guard let tightestLimit else { return "setup needed" }
        let remaining = tightestLimit.widgetRemainingHeadline.lowercased()
        return "\(tightestLimit.accountName) \(tightestLimit.displayLabel) · \(remaining)"
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
            return "in \(hours / 24)d"
        }
        let elapsed = abs(seconds)
        let minutes = elapsed / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
