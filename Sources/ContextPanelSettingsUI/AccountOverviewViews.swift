import ContextPanelCore
import SwiftUI

public struct AccountOverviewPanel: View {
    let overview: AccountOverview
    let openAccount: (AccountOverview.Account) -> Void
    let openDeadlines: () -> Void

    public init(overview: AccountOverview, openAccount: @escaping (AccountOverview.Account) -> Void,
                openDeadlines: @escaping () -> Void) {
        self.overview = overview
        self.openAccount = openAccount
        self.openDeadlines = openDeadlines
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Accounts").font(.largeTitle.weight(.semibold))
            if overview.accounts.isEmpty {
                Text("Add an account in Settings to see its usage and reset times.").foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { answerCards }
                    VStack(alignment: .leading, spacing: 12) { answerCards }
                }
                GroupBox {
                    VStack(spacing: 0) {
                        ForEach(overview.accounts) { account in
                            Button { openAccount(account) } label: {
                                AccountOverviewRow(account: account)
                            }
                            .buttonStyle(.plain)
                            if account.id != overview.accounts.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var answerCards: some View {
        GroupBox("Closest to limit") {
            if let closest = overview.closest {
                Button { openAccount(closest) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(closest.metadata.label).font(.headline).lineLimit(2)
                        Text(closest.metadata.provider.accountDisplayName + " · " + closest.remainingText + " left")
                        Text(closest.resetDisplayText).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            } else { Text("No current reading").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
        }
        if let deadline = overview.nextDeadline {
            GroupBox("Next banked expiry") {
                Button(action: openDeadlines) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(deadline.label).font(.headline).lineLimit(2)
                        Text(ContextPanelDateFormatting.accountReset(deadline.expiresAt, compact: true))
                            .foregroundStyle(.primary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
        }
        GroupBox("Use next") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Provider.allCases) { provider in
                    if let next = overview.useNext(provider: provider) {
                        Button { openAccount(next) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.accountDisplayName).font(.caption).foregroundStyle(.secondary)
                                Text(next.metadata.label).font(.headline).lineLimit(2)
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if !Provider.allCases.contains(where: { overview.useNext(provider: $0) != nil }) {
                    Text("No eligible account").foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

public struct AccountOverviewRow: View {
    let account: AccountOverview.Account
    public init(account: AccountOverview.Account) { self.account = account }
    public var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: account.state.accountSymbol).foregroundStyle(account.state.accountColor)
                .frame(width: 14).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.metadata.label).font(.headline)
                Text(account.metadata.provider.accountDisplayName + " · " + account.state.displayText)
                    .font(.caption).foregroundStyle(.secondary)
                if account.metadata.useLast { Text("Use last").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(account.remainingText + " left").font(.title3.weight(.semibold)).monospacedDigit()
                Text(account.resetDisplayText).font(.caption).foregroundStyle(.secondary)
                if let summary = account.bankedResets, summary.availableCount > 0 {
                    Text("\(account.bankedState == .available ? "" : "Last seen · ")\(summary.availableCount) banked\(account.unknownExpiryCount == 0 ? "" : " · dates incomplete")")
                        .font(.caption).foregroundStyle(.primary)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.accessibilityText)
    }
}

public struct AccountDeadlinesPanel: View {
    let overview: AccountOverview
    let openAccount: (String) -> Void
    public init(overview: AccountOverview, openAccount: @escaping (String) -> Void) {
        self.overview = overview
        self.openAccount = openAccount
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Deadlines").font(.largeTitle.weight(.semibold))
            Text("Banked resets expire here; expiration does not use a reset.").font(.callout).foregroundStyle(.secondary)
            if overview.deadlines.isEmpty { Text("No dated banked resets.").foregroundStyle(.secondary) }
            ForEach(overview.deadlines) { deadline in
                Button { openAccount(deadline.accountID) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Image(systemName: "arrow.counterclockwise.circle").foregroundStyle(.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deadline.label).font(.headline)
                            Text(deadline.provider.accountDisplayName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(ContextPanelDateFormatting.accountReset(deadline.expiresAt)).monospacedDigit()
                            if deadline.state != .available {
                                Text("Last seen " + ContextPanelDateFormatting.accountReset(deadline.observedAt, compact: true))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.padding(12).frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
            ForEach(overview.accounts.filter { ($0.unknownExpiryCount ?? 0) > 0 }) { account in
                Text("\(account.metadata.label): \(account.unknownExpiryCount ?? 0) banked reset dates unknown")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

public struct AccountDetailPanel: View {
    let account: AccountOverview.Account
    let overview: AccountOverview
    public init(account: AccountOverview.Account, overview: AccountOverview) {
        self.account = account
        self.overview = overview
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(account.metadata.label).font(.largeTitle.weight(.semibold))
            Text(account.metadata.provider.accountDisplayName + " · " + account.state.displayText).foregroundStyle(.secondary)
            ForEach(account.windows) { window in
                GroupBox(window.label) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(window.remainingFraction.map { (window.assumption == nil ? "" : "≈ ") + "\(Int(($0 * 100).rounded()))% left" } ?? "Unknown")
                            .font(.title2.weight(.semibold)).monospacedDigit()
                        if let used = window.used, let limit = window.limit {
                            Text("\(used) of \(limit) \(window.unit.rawValue) used").font(.caption).foregroundStyle(.secondary)
                        }
                        if let date = window.naturalResetAt {
                            Text((window.assumption == nil ? "Reset " : "Assumed after reset ") + ContextPanelDateFormatting.accountReset(date))
                        } else { Text("Reset unknown").foregroundStyle(.secondary) }
                        if window.assumption != nil { Text("Estimated after the scheduled reset; awaiting a new observation.").font(.caption).foregroundStyle(.secondary) }
                        if let date = window.observedAt { Text("Observed " + ContextPanelDateFormatting.accountReset(date)).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
            }
            GroupBox("Banked resets") {
                VStack(alignment: .leading, spacing: 8) {
                    if let summary = account.bankedResets {
                        Text("\(summary.availableCount)\(account.bankedState == .available ? " available" : " last seen")")
                        ForEach(overview.deadlines.filter { $0.accountID == account.id }) { deadline in
                            Text("Expires " + ContextPanelDateFormatting.accountReset(deadline.expiresAt))
                        }
                        if (account.unknownExpiryCount ?? 0) > 0 { Text("Some expiry dates are unknown.").foregroundStyle(.secondary) }
                    } else { Text("Unknown").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }
}

private extension AccountCapacityState {
    var accountColor: Color {
        switch self {
        case .available: .green
        case .closeToLimit: .orange
        case .limited: .red
        case .stale, .unavailable: .brown
        default: .secondary
        }
    }
    var accountSymbol: String {
        switch self {
        case .available: "circle.fill"
        case .closeToLimit: "triangle.fill"
        case .limited: "stop.fill"
        case .stale, .unavailable: "clock"
        default: "circle.dashed"
        }
    }
}
