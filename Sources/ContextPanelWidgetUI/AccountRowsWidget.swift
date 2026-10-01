import ContextPanelCore
import SwiftUI
import WidgetKit

struct AccountRowsWidget: View {
    @Environment(\.cpwThemeVariant) private var theme
    let family: WidgetFamily
    let snapshot: WidgetSnapshot
    let links: ContextPanelWidgetLinks
    let now: Date
    let maximumAge: TimeInterval
    let showsBanked: Bool
    private var overview: AccountOverview { snapshot.accountOverview(now: now, widgetsOnly: true, maximumAge: maximumAge) }
    private var compact: Bool { family == .systemSmall || family == .systemMedium }

    private var maximumRows: Int {
        if family == .systemMedium { return showsBanked && (overview.nextDeadline != nil || overview.accounts.contains { ($0.unknownExpiryCount ?? 0) > 0 }) ? 4 : 5 }
        return family == .systemExtraLarge ? 12 : 7
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 6) {
            if overview.accounts.isEmpty {
                Text(snapshot.accountDisplayMetadata?.isEmpty == false ? "No accounts shown" : "Add your first account")
                    .font(.system(size: 15, weight: .semibold))
                Text("Open Context Panel to set up accounts.").font(.caption).foregroundStyle(CPWTheme.secondaryText(variant: theme))
            } else if family == .systemSmall {
                small
            } else {
                HStack {
                    Text("Accounts").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("% left").font(.system(size: 10)).foregroundStyle(CPWTheme.secondaryText(variant: theme))
                }
                ForEach(Array(overview.accounts.prefix(maximumRows))) { account in
                    Link(destination: links.account(account.metadata.provider, id: account.id)) {
                        row(account)
                    }
                    .buttonStyle(.plain)
                }
                if overview.accounts.count > maximumRows {
                    Link("More accounts", destination: links.overview).font(.system(size: 10))
                }
                Spacer(minLength: 0)
                if showsBanked {
                    if let deadline = overview.nextDeadline {
                        Link(destination: links.deadlines) { deadlineLine(deadline) }.buttonStyle(.plain)
                    } else if let account = overview.accounts.first(where: { ($0.unknownExpiryCount ?? 0) > 0 }) {
                        Link("\(account.bankedState == .available ? "" : "Last seen · ")\(account.bankedResets?.availableCount ?? 0) banked · dates unknown", destination: links.deadlines)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(compact ? 10 : 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(CPWTheme.primaryText(variant: theme))
        .background(CPWTheme.surface(variant: theme))
    }

    private var small: some View {
        let account = overview.closest ?? overview.accounts[0]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                statusMark(account)
                Text(account.isReliable ? "Closest" : account.state.displayText)
                    .font(.system(size: 10, weight: .semibold))
                Spacer(minLength: 0)
                Text(account.metadata.provider.accountDisplayName).font(.system(size: 9))
            }
            Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(2)
            Text(account.remainingText + " left").font(.system(size: 26, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.7).lineLimit(1)
            if let fraction = account.remainingFraction {
                ProgressView(value: fraction).tint(account.state.displayColor)
            }
            Text(account.resetDisplayText).font(.system(size: 10)).lineLimit(2)
                .foregroundStyle(CPWTheme.secondaryText(variant: theme))
            Spacer(minLength: 0)
            if showsBanked, let deadline = overview.nextDeadline {
                deadlineLine(deadline)
            } else if showsBanked, (account.unknownExpiryCount ?? 0) > 0 {
                Text("\(account.bankedResets?.availableCount ?? 0) banked · dates unknown").font(.system(size: 9)).foregroundStyle(CPWTheme.secondaryText(variant: theme))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText + (showsBanked ? overview.nextDeadline.map {
            ", banked reset for \($0.label) expires \(ContextPanelDateFormatting.accountReset($0.expiresAt))"
        } ?? "" : ""))
        .accessibilityHint("Opens this account in Context Panel")
    }

    private func row(_ account: AccountOverview.Account) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: compact ? 6 : 10) {
                statusMark(account)
                Text(account.metadata.label).font(.system(size: compact ? 11 : 13, weight: .medium)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(account.remainingText).font(.system(size: compact ? 12 : 17, weight: .semibold, design: .monospaced))
                    .frame(width: compact ? 40 : 54, alignment: .trailing)
                if compact {
                    Text(account.resetDisplayText).font(.system(size: 9))
                        .foregroundStyle(CPWTheme.secondaryText(variant: theme))
                        .frame(width: 120, alignment: .trailing).lineLimit(1).minimumScaleFactor(0.85)
                }
            }
            if !compact {
                HStack(spacing: 6) {
                    Text(account.metadata.provider.accountDisplayName + " · " + account.state.displayText).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(account.resetDisplayText).lineLimit(1).minimumScaleFactor(0.85)
                }.font(.system(size: 9)).foregroundStyle(CPWTheme.secondaryText(variant: theme))
            }
        }
        .frame(minHeight: compact ? 18 : 31)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText)
        .accessibilityHint("Opens this account")
    }

    private func statusMark(_ account: AccountOverview.Account) -> some View {
        Image(systemName: account.state.displaySymbol).font(.system(size: 9, weight: .semibold))
            .foregroundStyle(account.state.displayColor).accessibilityHidden(true)
    }

    private func deadlineLine(_ deadline: AccountOverview.Deadline) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.counterclockwise.circle")
            VStack(alignment: .leading, spacing: 1) {
                Text(deadline.label + " · banked expires").lineLimit(1)
                Text(ContextPanelDateFormatting.accountReset(deadline.expiresAt, compact: true))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: compact ? 9 : 11, weight: .medium))
        .foregroundStyle(CPWTheme.secondaryText(variant: theme))
        .accessibilityLabel("Banked reset for \(deadline.label) expires \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
    }
}

private extension AccountCapacityState {
    var displayColor: Color {
        switch self {
        case .available: CPWTheme.statusColor(.healthy)
        case .closeToLimit: CPWTheme.statusColor(.close)
        case .limited: CPWTheme.statusColor(.limited)
        case .stale, .unavailable: CPWTheme.statusColor(.stale)
        default: CPWTheme.statusColor(.unknown)
        }
    }
    var displaySymbol: String {
        switch self {
        case .available: "circle.fill"
        case .closeToLimit: "triangle.fill"
        case .limited: "stop.fill"
        case .stale, .unavailable: "clock"
        case .refreshing: "arrow.clockwise"
        default: "circle.dashed"
        }
    }
}
