import ContextPanelCore
import SwiftUI

// REQUEST: AccountTerms — "Saved for last", the quiet label for an account kept for last.

// Apple TV account board in the Horizon design, read from across the room: one sentence, a use-next
// card per provider, the single "runs out before reset" callout, then each provider's accounts as
// horizon shapes. Words, numbers and colours come from `AccountPresentation` and `AccountPace` in
// ContextPanelCore. Rows and cards have fixed heights so the large percentages share one baseline
// across columns. Lives in TVSupport so the TV app and the macOS renderer compile the same views;
// the app adds focus and navigation.

/// The sentence every surface leads with, at TV size: a bold lead and a quieter rest.
public struct TVAccountHeadline: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        let text = AccountTerms.headline(overview.headline(now: now))
        (Text(text.lead).foregroundColor(TVTokens.color(.primary))
            + Text(text.rest.isEmpty ? "" : " " + text.rest).foregroundColor(TVTokens.color(.secondary)))
            .font(.system(size: 48, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            .accessibilityLabel([text.lead, text.rest].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// The answers above the accounts: the headline, a use-next card per provider, and the callout.
public struct TVAccountAnswers: View {
    let overview: AccountOverview
    let now: Date
    let showsHeadline: Bool

    public init(overview: AccountOverview, now: Date, showsHeadline: Bool = true) {
        self.overview = overview
        self.now = now
        self.showsHeadline = showsHeadline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if showsHeadline { TVAccountHeadline(overview: overview, now: now) }
            HStack(alignment: .top, spacing: 24) {
                ForEach(tvProviders(overview), id: \.self) { provider in
                    TVUseNextCard(provider: provider, account: overview.useNext(provider: provider),
                                  deadlines: overview.deadlines, now: now)
                }
            }
            TVRunsOutCallout(overview: overview, now: now)
        }
    }
}

/// One provider's use-next account on the calm next surface: the name in the provider's hue, the
/// account, its weekly share left in large type, its horizon and why it is next.
struct TVUseNextCard: View {
    let provider: Provider
    let account: AccountOverview.Account?
    let deadlines: [AccountOverview.Deadline]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.accountDisplayName).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(TVTokens.color(provider.colorToken))
                Spacer()
                Text(AccountTerms.useNext).font(.system(size: 20)).foregroundStyle(TVTokens.color(.secondary))
            }
            .frame(height: 28)
            if let account {
                let horizon = account.horizon(now: now)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(account.metadata.label).font(.system(size: 30, weight: .semibold)).lineLimit(1)
                    TVBankedCount(account: account)
                    Spacer(minLength: 0)
                }
                .frame(height: 36)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(tvWeekPercent(horizon, sign: false))
                        .font(.system(size: 72, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(AccountTerms.percentLeft).font(.system(size: 24)).foregroundStyle(TVTokens.color(.secondary))
                    Spacer(minLength: 8)
                    if let short = account.shortWindow, account.longWindow != short {
                        Text(AccountTerms.fiveHour + " " + AccountNumbers.window(short) + " · " + AccountTerms.refill(short, now: now))
                            .font(.system(size: 20)).monospacedDigit().foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
                    }
                }
                .frame(height: 76)
                TVHorizon(geometry: horizon.geometry(now: now, deadlines: tvDeadlines(deadlines, account)),
                          token: horizon.isCurrent ? provider.colorToken : .saved)
                    .frame(height: 26)
                Text(AccountTerms.useNextReason(account, horizon, now: now))
                    .font(.system(size: 20)).monospacedDigit().foregroundStyle(TVTokens.color(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.8).frame(height: 26)
            } else {
                Text(AccountTerms.noEligibleAccount).font(.system(size: 24)).foregroundStyle(TVTokens.color(.secondary))
                    .lineLimit(2).frame(height: 196, alignment: .topLeading)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVTokens.color(.nextSurface), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.accountDisplayName + ", " + AccountTerms.useNext + ": "
            + (account.map { $0.glanceAccessibilityText(now: now, isNext: true) } ?? AccountTerms.noEligibleAccount))
    }
}

/// The single callout for accounts that run out before their reset, soonest first, with the banked
/// reset that lapses before each runs out. Nothing is drawn when every account lasts.
struct TVRunsOutCallout: View {
    let overview: AccountOverview
    let now: Date

    var body: some View {
        let short = overview.runningShort(now: now)
        if !short.isEmpty {
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    TVHatch().stroke(TVTokens.color(.critical), lineWidth: 2)
                        .frame(width: 56, height: 22)
                        .overlay(alignment: .bottom) { Rectangle().fill(TVTokens.color(.critical)).frame(height: 3) }
                        .clipped()
                    Text(AccountTerms.runsOutBeforeReset).font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(TVTokens.color(.critical)).lineLimit(2)
                }
                .frame(width: 250, alignment: .leading)
                ForEach(short.prefix(3), id: \.account.id) { item in
                    let outcome = AccountTerms.outcome(item.account, item.horizon, now: now)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(item.account.metadata.provider.accountDisplayName).font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(TVTokens.color(item.account.metadata.provider.colorToken))
                            Text(item.account.metadata.label).font(.system(size: 24, weight: .semibold)).lineLimit(1)
                        }
                        Text(outcome.title).font(.system(size: 24, weight: .semibold)).foregroundStyle(TVTokens.color(.critical))
                        Text(outcome.detail).font(.system(size: 20)).foregroundStyle(TVTokens.color(.secondary)).lineLimit(1)
                        if let banked = overview.bankedBeforeRunOut(item.account, now: now) {
                            HStack(spacing: 8) {
                                TVDiamond().fill(TVTokens.color(.banked)).frame(width: 13, height: 13)
                                Text(AccountTerms.bankedBeforeRunOut(banked, now: now)).lineLimit(1)
                            }
                            .font(.system(size: 20)).foregroundStyle(TVTokens.color(.secondary))
                        }
                    }
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TVTokens.color(.critical).opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

/// One account: name and weekly share left, the horizon, then its outcome and the fact it rests on.
/// Every line has a fixed height so rows line up across provider columns.
struct TVAccountLines: View {
    let account: AccountOverview.Account
    let deadlines: [AccountOverview.Deadline]
    let now: Date

    var body: some View {
        let horizon = account.horizon(now: now)
        let outcome = AccountTerms.outcome(account, horizon, now: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(account.metadata.label).font(.system(size: 26, weight: .semibold)).lineLimit(1)
                TVBankedCount(account: account)
                Spacer(minLength: 8)
                Text(tvWeekPercent(horizon, sign: true))
                    .font(.system(size: 40, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(TVTokens.color(horizon.isCurrent ? .primary : .saved))
                    .fixedSize()
            }
            .frame(height: 44)
            TVHorizon(geometry: horizon.geometry(now: now, deadlines: tvDeadlines(deadlines, account)),
                      token: horizon.isCurrent ? account.metadata.provider.colorToken : .saved)
                .frame(height: 24)
            HStack(alignment: .firstTextBaseline) {
                Text(outcome.title).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TVTokens.color(outcomeToken(horizon)))
                Spacer(minLength: 8)
                if let short = account.shortWindow, account.longWindow != short {
                    Text(AccountTerms.fiveHour + " " + AccountNumbers.window(short)).font(.system(size: 20))
                        .foregroundStyle(TVTokens.color(.secondary))
                }
            }
            .lineLimit(1).frame(height: 28)
            HStack(alignment: .firstTextBaseline) {
                Text(detail(outcome.detail)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                if let short = account.shortWindow, account.longWindow != short {
                    Text(AccountTerms.refill(short, now: now)).lineLimit(1).fixedSize()
                }
            }
            .font(.system(size: 19)).foregroundStyle(TVTokens.color(.secondary)).frame(height: 24)
        }
        .monospacedDigit()
    }

    private func detail(_ text: String) -> String {
        account.metadata.useLast ? [text, AccountTerms.useLast].filter { !$0.isEmpty }.joined(separator: " · ") : text
    }

    private func outcomeToken(_ horizon: AccountHorizon) -> AccountColorToken {
        if horizon.runsOutBeforeReset { return .critical }
        if !horizon.isCurrent, account.state.needsWord { return account.state.colorToken }
        return .primary
    }
}

/// Banked resets available on an account, as a diamond and a count; nothing when there are none.
struct TVBankedCount: View {
    let account: AccountOverview.Account

    var body: some View {
        if let banked = account.bankedResets, banked.availableCount > 0 {
            HStack(spacing: 5) {
                TVDiamond().fill(TVTokens.color(.banked)).frame(width: 12, height: 12)
                Text("\(banked.availableCount)")
            }
            .font(.system(size: 20, weight: .semibold)).foregroundStyle(TVTokens.color(.secondary))
            .fixedSize()
        }
    }
}

/// A single account card, as the TV app's focusable grid shows it.
public struct TVAccountTile: View {
    let account: AccountOverview.Account
    let isNext: Bool
    let now: Date
    let deadlines: [AccountOverview.Deadline]

    /// `showsPace` is kept for callers from before Horizon, which drops pace multipliers.
    public init(account: AccountOverview.Account, isNext: Bool, now: Date, showsPace: Bool = true,
                deadlines: [AccountOverview.Deadline] = []) {
        self.account = account
        self.isNext = isNext
        self.now = now
        self.deadlines = deadlines
    }

    public var body: some View {
        let provider = account.metadata.provider
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(provider.accountDisplayName).foregroundStyle(TVTokens.color(provider.colorToken))
                Spacer()
                if isNext { Text(AccountTerms.useNext).foregroundStyle(TVTokens.color(provider.colorToken)) }
            }
            .font(.system(size: 20, weight: .semibold)).frame(height: 26)
            TVAccountLines(account: account, deadlines: deadlines, now: now)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TVTokens.color(.card), in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: isNext))
    }
}

/// Accounts grouped by provider, one column per provider under its use-next card. With
/// `excludesUseNext`, a column lists only the accounts its use-next card above does not already show.
public struct TVAccountGroups: View {
    let overview: AccountOverview
    let now: Date
    let excludesUseNext: Bool

    public init(overview: AccountOverview, now: Date, excludesUseNext: Bool = false) {
        self.overview = overview
        self.now = now
        self.excludesUseNext = excludesUseNext
    }

    public var body: some View {
        let totals = overview.providerTotals(now: now)
        HStack(alignment: .top, spacing: 24) {
            ForEach(tvProviders(overview), id: \.self) { provider in
                let next = excludesUseNext ? overview.useNext(provider: provider)?.id : nil
                let accounts = overview.accounts.filter { $0.metadata.provider == provider && $0.id != next }
                VStack(alignment: .leading, spacing: 12) {
                    if let total = totals.first(where: { $0.provider == provider }) {
                        let summary = AccountTerms.providerSummary(total, now: now)
                        (Text(summary.facts + " · ").foregroundColor(TVTokens.color(.secondary))
                            + Text(summary.outlook).foregroundColor(TVTokens.color(summary.isShort ? .critical : .secondary)))
                            .font(.system(size: 19)).lineLimit(1).minimumScaleFactor(0.7).frame(height: 24)
                    }
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Rectangle().fill(TVTokens.color(.line)).frame(height: 1) }
                        TVAccountLines(account: account, deadlines: overview.deadlines, now: now)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(account.glanceAccessibilityText(
                                now: now, isNext: overview.useNext(provider: provider)?.id == account.id))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(TVTokens.color(.card), in: RoundedRectangle(cornerRadius: 20))
            }
        }
    }
}

/// The whole board without focus handling, for captures and Top Shelf previews.
public struct TVAccountBoard: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                if let updated = overview.accounts.compactMap(\.observedAt).max() {
                    Text(AccountTerms.accounts + " · " + AccountTerms.updated.lowercased() + " "
                         + AccountPaceText.when(updated, now: now))
                        .font(.system(size: 22)).foregroundStyle(TVTokens.color(.secondary))
                }
                TVAccountHeadline(overview: overview, now: now)
            }
            TVAccountAnswers(overview: overview, now: now, showsHeadline: false)
            TVAccountGroups(overview: overview, now: now, excludesUseNext: true)
        }
        .foregroundStyle(TVTokens.color(.primary))
    }
}

/// Providers that have accounts, in the shared provider order.
private func tvProviders(_ overview: AccountOverview) -> [Provider] {
    Provider.allCases.filter { provider in overview.accounts.contains { $0.metadata.provider == provider } }
}

private func tvDeadlines(_ deadlines: [AccountOverview.Deadline], _ account: AccountOverview.Account) -> [AccountOverview.Deadline] {
    deadlines.filter { $0.accountID == account.id && $0.state == .available }
}

private func tvWeekPercent(_ horizon: AccountHorizon, sign: Bool) -> String {
    horizon.window.map { AccountNumbers.window($0, sign: sign) } ?? AccountTerms.unknown
}

/// The horizon: what is left now draining at the observed burn toward the weekly reset. A gap
/// before the reset is hatched red, the only red; after the reset the window is full again.
struct TVHorizon: View {
    let geometry: AccountHorizonGeometry
    let token: AccountColorToken

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let resetX = geometry.resetX ?? 1
            let hue = TVTokens.color(token)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(TVTokens.color(.track)).frame(width: width * resetX)
                if resetX < 1 {
                    Rectangle().fill(hue.opacity(0.13)).frame(width: width * (1 - resetX)).offset(x: width * resetX)
                }
                ForEach(geometry.dayXs, id: \.self) { day in
                    Rectangle().fill(TVTokens.color(.line)).frame(width: 1).offset(x: width * day)
                }
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height * (1 - geometry.startLevel)))
                    path.addLine(to: CGPoint(x: geometry.fillEndX * width, y: height * (1 - geometry.fillEndLevel)))
                    path.addLine(to: CGPoint(x: geometry.fillEndX * width, y: height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [hue.opacity(0.95), hue.opacity(0.45)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * (1 - geometry.startLevel)))
                    path.addLine(to: CGPoint(x: geometry.fillEndX * width, y: height * (1 - geometry.fillEndLevel)))
                }
                .stroke(hue, lineWidth: 1.5)
                if let empty = geometry.emptyRange {
                    let emptyWidth = max(3, width * (empty.upperBound - empty.lowerBound))
                    TVHatch().stroke(TVTokens.color(.critical).opacity(0.3), lineWidth: 1.5)
                        .frame(width: emptyWidth, height: height).clipped()
                        .offset(x: width * empty.lowerBound)
                    Rectangle().fill(TVTokens.color(.critical)).frame(width: emptyWidth, height: 2.5)
                        .offset(x: width * empty.lowerBound, y: height - 2.5)
                }
                if let reset = geometry.resetX {
                    Rectangle().fill(TVTokens.color(.primary)).frame(width: 1.5)
                        .offset(x: min(width - 1.5, max(0, width * reset - 0.75)))
                }
                ForEach(Array(geometry.banked.enumerated()), id: \.offset) { _, mark in
                    let size = min(12, height * 0.5)
                    TVDiamond().fill(TVTokens.color(.banked)).frame(width: size, height: size)
                        .offset(x: min(width - size, max(0, width * mark.x - size / 2)),
                                y: min(height - size, max(0, height * (1 - mark.level) - size / 2)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// 45° stripes across the rect, for the empty gap before a reset.
struct TVHatch: Shape {
    var spacing: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        Path { path in
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += spacing
            }
        }
    }
}

/// The banked-reset mark.
struct TVDiamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

/// The TV app draws on a dark background.
public enum TVTokens {
    public static func color(_ token: AccountColorToken) -> Color {
        let value = token.rgb(dark: true)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: true))
    }
}
