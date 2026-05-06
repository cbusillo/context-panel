import ContextPanelCore
import SwiftUI

struct ContextPanelSmallWidget: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CPWHeader(status: snapshot.status)
            Spacer(minLength: 4)
            if let tightest = snapshot.mostConstrainedLimits.first {
                Text(tightest.widgetUsageText)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(CPWTheme.primaryText)
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                Text("\(tightest.label) · \(tightest.accountName)")
                    .font(.system(size: 11))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
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
                CPWHeader(status: snapshot.status)
                Spacer(minLength: 0)
                CPWCapacityDial(
                    value: snapshot.aggregateCapacityRatio,
                    status: snapshot.status,
                    label: "\(Int(snapshot.aggregateCapacityRatio * 100))",
                    sublabel: "capacity",
                    size: 86
                )
                Text(snapshot.message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPWTheme.secondaryText)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(width: 142, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                CPWSectionHeader(title: "Most Constrained", trailing: "\(snapshot.limits.count) limits")
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
                    Text(snapshot.message)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(CPWTheme.primaryText)
                        .lineLimit(2)
                    Text(snapshot.state.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                        .textCase(.uppercase)
                }
                Spacer()
                CPWCapacityDial(
                    value: snapshot.aggregateCapacityRatio,
                    status: snapshot.status,
                    label: "\(Int(snapshot.aggregateCapacityRatio * 100))",
                    sublabel: "cap",
                    size: 82
                )
            }

            CPWProviderSummaryGrid(snapshot: snapshot)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                CPWSectionHeader(title: "Account Limits", trailing: snapshot.generatedAt.widgetRelativeText)
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

    var body: some View {
        HStack {
            CPWLabel("Context Panel")
            Spacer()
            CPWStatusMark(status: status, size: 9)
        }
    }
}

struct CPWLimitRow: View {
    let limit: UsageLimit

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CPWProviderGlyph(provider: limit.provider, size: 10)
                Text(limit.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CPWTheme.primaryText)
                    .lineLimit(1)
                Text("· \(limit.accountName)")
                    .font(.system(size: 11))
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(limit.widgetUsageText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(CPWTheme.secondaryText)
            }
            HStack(spacing: 8) {
                CPWCapacityBar(value: limit.usageRatio ?? 0, status: limit.status)
                Text(limit.widgetResetText)
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
                        CPWProviderGlyph(provider: summary.provider, size: 10)
                        Text(summary.provider.shortName)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Spacer()
                        CPWStatusMark(status: summary.status, size: 7)
                    }
                    Text(summary.limitCount == 0 ? "setup" : "\(Int(summary.capacityRatio * 100))% room")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPWTheme.secondaryText)
                    CPWCapacityBar(value: 1 - summary.capacityRatio, status: summary.status)
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
                HStack(spacing: 5) {
                    CPWProviderGlyph(provider: summary.provider, size: 9)
                    Text(summary.provider.shortName)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(CPWTheme.secondaryText)
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

struct CPWCapacityDial: View {
    let value: Double
    let status: UsageStatus
    let label: String
    let sublabel: String
    var size: CGFloat = 86

    var body: some View {
        ZStack {
            Circle().stroke(CPWTheme.line, lineWidth: 6)
            Circle()
                .trim(from: 0, to: min(max(value, 0), 1))
                .stroke(CPWTheme.statusColor(status), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .foregroundStyle(CPWTheme.primaryText)
                Text(sublabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(CPWTheme.tertiaryText)
                    .textCase(.uppercase)
            }
        }
        .frame(width: size, height: size)
    }
}

struct CPWCapacityBar: View {
    let value: Double
    let status: UsageStatus

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(CPWTheme.line)
                Capsule()
                    .fill(CPWTheme.statusColor(status))
                    .frame(width: proxy.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 4)
    }
}

struct CPWProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 10

    var body: some View {
        Group {
            switch provider {
            case .openAI:
                RoundedRectangle(cornerRadius: 2).stroke(CPWTheme.accent, lineWidth: 1.4)
            case .anthropic:
                CPWTriangle().stroke(CPWTheme.accent, lineWidth: 1.4)
            case .google:
                RoundedRectangle(cornerRadius: 1).rotation(.degrees(45)).stroke(CPWTheme.accent, lineWidth: 1.4)
            }
        }
        .frame(width: size, height: size)
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
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(CPWTheme.accent)
                .rotationEffect(.degrees(45))
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(CPWTheme.tertiaryText)
        }
    }
}

struct CPWTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

enum CPWTheme {
    static let surface = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    static let line = Color.black.opacity(0.08)
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
}

extension UsageLimit {
    var widgetUsageText: String {
        if let remaining, let limit {
            return "\(remaining)/\(limit) left"
        }
        if status == .failure { return "refresh failed" }
        return "unknown"
    }

    var widgetResetText: String {
        guard let resetsAt else {
            return status == .failure ? "refresh failed" : "unknown reset"
        }
        return "resets \(resetsAt.widgetRelativeText)"
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

