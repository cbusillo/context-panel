import ContextPanelCore
import SwiftUI

/// Mac overview in the Horizon design: one sentence first, a calm "use next" card per provider, the single
/// "runs out before reset" callout, then every account as one shape draining toward its weekly reset,
/// grouped by provider. Hatched red is the only red, and means an account runs out before it resets.
public struct AccountDashboardPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let overview: AccountOverview
    let now: Date
    let openAccount: (AccountOverview.Account) -> Void
    let openDeadlines: () -> Void
    let compact: Bool
    let accountDetails: ((AccountOverview.Account) -> AnyView)?

    /// `compact` stacks everything into one column, for phone widths.
    public init(overview: AccountOverview, now: Date, compact: Bool = false,
                accountDetails: ((AccountOverview.Account) -> AnyView)? = nil,
                openAccount: @escaping (AccountOverview.Account) -> Void, openDeadlines: @escaping () -> Void) {
        self.overview = overview
        self.now = now
        self.compact = compact
        self.accountDetails = accountDetails
        self.openAccount = openAccount
        self.openDeadlines = openDeadlines
    }

    private var palette: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }
    private var nextIDs: Set<String> { Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id }) }
    private var totals: [AccountProviderTotal] { overview.providerTotals(now: now) }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 16 : 22) {
            header
            if overview.accounts.isEmpty {
                Text("Add an account in Settings to see its usage and reset times.").foregroundStyle(palette.secondary)
            } else {
                useNextCards
                callout
                if compact { compactGroups } else { table }
                legend
            }
        }
        .foregroundStyle(palette.primary)
    }

    // MARK: Sentence

    private var header: some View {
        let sentence = AccountTerms.headline(overview.headline(now: now))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(([now.formatted(.dateTime.weekday(.wide).month(.wide).day())]
                      + (overview.accounts.compactMap(\.observedAt).max().map {
                          [AccountTerms.updated.lowercased() + " " + AccountPaceText.when($0, now: now)] } ?? []))
                    .joined(separator: " · "))
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary)
                Spacer(minLength: 8)
                if !compact { bankedLink }
            }
            (Text(sentence.lead).foregroundStyle(palette.primary)
             + Text(sentence.rest.isEmpty ? "" : " " + sentence.rest).foregroundStyle(palette.tertiary))
                .font(.system(size: compact ? 24 : 26, weight: .bold)).tracking(-0.4)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if compact { bankedLink }
        }
    }

    /// The next banked reset to lapse, its countdown and how many are dated: opens Deadlines.
    @ViewBuilder private var bankedLink: some View {
        if let first = overview.deadlines.first {
            Button(action: openDeadlines) {
                HStack(spacing: 6) {
                    DashboardDiamond(palette: palette, size: 8)
                    Text(AccountTerms.bankedResetExpires + " " + AccountPaceText.when(first.expiresAt, now: now))
                        .fontWeight(.medium)
                    Text(AccountPaceText.countdown(to: first.expiresAt, now: now) + " · " + AccountTerms.dated(overview.deadlines.count))
                        .foregroundStyle(palette.secondary)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.tertiary)
                }
                .font(.system(size: 12)).monospacedDigit().lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AccountTerms.bankedResetExpires + " " + AccountPaceText.when(first.expiresAt, now: now) + ", "
                + AccountTerms.deadlineLabel(first) + ", " + AccountTerms.dated(overview.deadlines.count))
        }
    }

    // MARK: Use next

    private var useNextCards: some View {
        let providers = totals.map(\.provider)
        let layout = compact ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            ForEach(providers, id: \.self) { provider in useNextCard(provider) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func useNextCard(_ provider: Provider) -> some View {
        let account = overview.useNext(provider: provider)
        return Button { if let account { openAccount(account) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(provider.accountDisplayName).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.provider(provider))
                    Spacer()
                    Text(AccountTerms.useNext).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.provider(provider))
                }
                if let account {
                    let horizon = account.horizon(now: now)
                    Text(account.metadata.label).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    HStack(alignment: .center, spacing: 10) {
                        DashboardRing(fraction: horizon.remaining, color: palette.provider(provider), track: palette.track, lineWidth: 5)
                            .frame(width: 38, height: 38)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(AccountNumbers.percent(horizon.remaining)).font(.system(size: 30, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                            if horizon.remaining != nil {
                                Text("%").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(palette.secondary)
                            }
                            Text(AccountTerms.horizonLeft(horizon.window)).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.secondary)
                        }
                    }
                    Text(AccountTerms.useNextReason(account, horizon, now: now))
                        .font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(AccountTerms.noEligibleAccount).font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            .padding(compact ? 14 : 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.color(provider.surfaceToken)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(account == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.accountDisplayName + ", " + AccountTerms.useNext + ", " + (account.map {
            $0.metadata.label + ", " + AccountNumbers.percentWithSign($0.horizon(now: now).remaining) + " " + AccountTerms.horizonLeft($0.horizon(now: now).window) + ", "
                + AccountTerms.useNextReason($0, $0.horizon(now: now), now: now) } ?? AccountTerms.noEligibleAccount))
    }

    // MARK: Callout

    /// The single "runs out before reset" callout: every account whose week runs out first, soonest first.
    @ViewBuilder private var callout: some View {
        let short = overview.runningShort(now: now)
        if !short.isEmpty {
            let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            layout {
                Text(AccountTerms.runsOutBeforeReset.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(1.2)
                    .foregroundStyle(palette.color(AccountAlarm.token))
                    .frame(width: compact ? nil : 110, alignment: .leading)
                ForEach(short, id: \.account.id) { account, horizon in
                    Button { openAccount(account) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: AccountGlyphs.runOut).font(.system(size: 10))
                                Text(account.metadata.label).font(.system(size: 13.5, weight: .semibold)).lineLimit(2)
                            }
                            .foregroundStyle(palette.bad)
                            let outcome = AccountTerms.outcome(account, horizon, now: now)
                            let providerName = account.metadata.provider.accountDisplayName
                            let repeatedPrefix = providerName + " · "
                            let title = outcome.title.hasPrefix(repeatedPrefix)
                                ? String(outcome.title.dropFirst(repeatedPrefix.count)) : outcome.title
                            (Text(providerName).foregroundStyle(palette.provider(account.metadata.provider))
                             + Text(" · " + title))
                                .font(.system(size: 12, weight: .medium))
                            Text(outcome.detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
                            if let banked = overview.bankedBeforeRunOut(account, now: now) {
                                HStack(spacing: 5) {
                                    DashboardDiamond(palette: palette, size: 7)
                                    Text(AccountTerms.bankedBeforeRunOut(banked, now: now))
                                }
                                .font(.system(size: 12)).foregroundStyle(palette.secondary)
                            }
                        }
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(compact ? 14 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.bad.opacity(0.35), lineWidth: 1))
        }
    }

    // MARK: Table

    private enum Column {
        static let week: CGFloat = 50
        static let horizon: CGFloat = 206
        static let fiveHour: CGFloat = 118
        static let outcome: CGFloat = 172
    }

    private var weeklyColumns: Bool { overview.accounts.allSatisfy { $0.longWindow == nil || $0.longWindow?.duration == 7 * 86_400 } }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text(AccountTerms.account).frame(maxWidth: .infinity, alignment: .leading)
                Text(AccountTerms.longColumn(weekly: weeklyColumns)).frame(width: Column.week, alignment: .trailing)
                DashboardHorizonAxis(now: now, palette: palette).frame(width: Column.horizon)
                Text(AccountTerms.fiveHourLong).frame(width: Column.fiveHour, alignment: .leading)
                Text(AccountTerms.beforeItsReset).frame(width: Column.outcome, alignment: .leading)
            }
            .font(.system(size: AccountTextSize.appMinimum, weight: .semibold)).foregroundStyle(palette.secondary)
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
            ForEach(totals) { total in
                Rectangle().fill(palette.line).frame(height: 1)
                groupHeader(total).padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                ForEach(overview.accounts.filter { $0.metadata.provider == total.provider }) { account in
                    Button { openAccount(account) } label: { row(account) }.buttonStyle(.plain)
                    foldedDetails(account)
                }
            }
        }
        .padding(.bottom, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.line, lineWidth: 1))
    }

    @ViewBuilder private func foldedDetails(_ account: AccountOverview.Account) -> some View {
        if let accountDetails {
            DisclosureGroup("Windows and banked resets") {
                accountDetails(account).padding(.top, 10)
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.secondary)
            .padding(.horizontal, 16).padding(.bottom, 12)
            .accessibilityLabel("Windows and banked resets for " + account.metadata.label)
        }
    }

    private func groupHeader(_ total: AccountProviderTotal) -> some View {
        let summary = AccountTerms.providerSummary(total, now: now)
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 14))
        return layout {
            Text(total.provider.accountDisplayName).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.provider(total.provider))
                .frame(width: compact ? nil : 140, alignment: .leading)
            (Text(summary.facts + " · ") + Text(summary.outlook).foregroundStyle(palette.color(AccountAlarm.providerOutlookToken)))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !compact { Spacer(minLength: 0) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(total.accessibilityText(now: now))
    }

    private func row(_ account: AccountOverview.Account) -> some View {
        let horizon = account.horizon(now: now)
        let outcome = AccountTerms.outcome(account, horizon, now: now)
        return HStack(alignment: .center, spacing: 14) {
            nameBlock(account).frame(maxWidth: .infinity, alignment: .leading)
            percent(horizon, account: account, size: 20).frame(width: Column.week, alignment: .trailing)
            DashboardHorizon(account: account, horizon: horizon, deadlines: deadlines(account), now: now, palette: palette)
                .frame(width: Column.horizon, height: 30)
            fiveHour(account).frame(width: Column.fiveHour, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.title).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.color(AccountAlarm.outcomeToken(account, horizon)))
                Text(outcome.detail).font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .monospacedDigit()
            .frame(width: Column.outcome, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(account, horizon))
    }

    private func nameBlock(_ account: AccountOverview.Account) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            (Text(account.metadata.label).font(.system(size: compact ? 15 : 13.5, weight: .semibold))
             + tags(account))
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            meta(account)
        }
    }

    private func tags(_ account: AccountOverview.Account) -> Text {
        var text = Text("")
        if nextIDs.contains(account.id) {
            text = text + Text("  " + AccountTerms.useNext).font(.system(size: AccountTextSize.appMinimum, weight: .semibold))
                .foregroundColor(palette.provider(account.metadata.provider))
        }
        if account.metadata.useLast {
            text = text + Text("  " + AccountTerms.useLast).font(.system(size: AccountTextSize.appMinimum, weight: .medium)).foregroundColor(palette.secondary)
        }
        return text
    }

    @ViewBuilder private func meta(_ account: AccountOverview.Account) -> some View {
        let count = account.bankedResets?.availableCount ?? 0
        let next = overview.deadlines.first { $0.accountID == account.id }
        if account.state.needsWord || count > 0 {
            HStack(spacing: 5) {
                if account.state.needsWord {
                    Text(account.stateText).foregroundStyle(palette.stale)
                    if count > 0 { Text("·") }
                }
                if count > 0 {
                    DashboardDiamond(palette: palette, size: 7)
                    Text(AccountTerms.bankedCount(count, current: account.bankedState == .available)
                         + (next.map { " · next lapses " + AccountPaceText.when($0.expiresAt, now: now) } ?? ""))
                }
            }
            .font(.system(size: AccountTextSize.appMinimum)).monospacedDigit().foregroundStyle(palette.secondary)
            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percent(_ horizon: AccountHorizon, account: AccountOverview.Account, size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(horizon.window.map { AccountNumbers.window($0, sign: false) } ?? AccountTerms.unknown)
                .font(.system(size: size, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(horizon.isCurrent ? palette.primary : palette.stale)
            if horizon.remaining != nil { Text("%").font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(palette.tertiary) }
        }
    }

    @ViewBuilder private func fiveHour(_ account: AccountOverview.Account) -> some View {
        if let window = account.shortWindow {
            HStack(spacing: 7) {
                DashboardRing(fraction: window.remainingFraction, color: palette.secondary, track: palette.track, lineWidth: 3.5)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(AccountNumbers.window(window)).font(.system(size: 12.5, weight: .semibold))
                    Text(AccountTerms.refill(window, now: now)).font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary)
                }
                .monospacedDigit().fixedSize()
            }
        } else {
            Text(AccountTerms.unknown).foregroundStyle(palette.tertiary)
        }
    }

    private func deadlines(_ account: AccountOverview.Account) -> [AccountOverview.Deadline] {
        overview.deadlines.filter { $0.accountID == account.id }
    }

    private func accessibility(_ account: AccountOverview.Account, _ horizon: AccountHorizon) -> String {
        let outcome = AccountTerms.outcome(account, horizon, now: now)
        return account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)) + ", " + outcome.title + ", " + outcome.detail
    }

    // MARK: Phone

    private var compactGroups: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(totals) { total in
                VStack(alignment: .leading, spacing: 0) {
                    groupHeader(total).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    ForEach(overview.accounts.filter { $0.metadata.provider == total.provider }) { account in
                        Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 14)
                        Button { openAccount(account) } label: { compactRow(account) }.buttonStyle(.plain)
                        foldedDetails(account)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.card))
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.provider(total.provider).opacity(0.05)))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.line, lineWidth: 1))
            }
        }
    }

    private func compactRow(_ account: AccountOverview.Account) -> some View {
        let horizon = account.horizon(now: now)
        let outcome = AccountTerms.outcome(account, horizon, now: now)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                nameBlock(account)
                Spacer(minLength: 8)
                percent(horizon, account: account, size: 22)
            }
            DashboardHorizon(account: account, horizon: horizon, deadlines: deadlines(account), now: now, palette: palette)
                .frame(height: 26)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title).font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(palette.color(AccountAlarm.outcomeToken(account, horizon)))
                    Text(outcome.detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let window = account.shortWindow {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(AccountTerms.fiveHour + " " + AccountNumbers.window(window)).font(.system(size: 12.5, weight: .semibold))
                        Text(AccountTerms.refill(window, now: now)).font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary)
                    }
                }
            }
            .monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility(account, horizon))
    }

    // MARK: Legend

    private var legend: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 18))
        return layout {
            HStack(spacing: 6) {
                DashboardLegendSwatch(kind: .left, palette: palette)
                Text(AccountTerms.horizonLegendLeft)
            }
            HStack(spacing: 6) {
                DashboardLegendSwatch(kind: .empty, palette: palette)
                Text(AccountTerms.horizonLegendEmpty)
            }
            HStack(spacing: 6) {
                DashboardLegendSwatch(kind: .reset, palette: palette)
                Text(AccountTerms.horizonLegendReset)
            }
            HStack(spacing: 6) {
                DashboardDiamond(palette: palette, size: 7)
                Text(AccountTerms.bankedLapsesLegend)
            }
            if !compact { Spacer(minLength: 0) }
        }
        .font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary)
    }
}

/// One account: both windows in full, pace math, banked inventory and its week.
public struct AccountDashboardDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: AccountOverview.Account
    let overview: AccountOverview
    let now: Date
    let compact: Bool
    let showsHeader: Bool
    let showsHorizon: Bool

    public init(account: AccountOverview.Account, overview: AccountOverview, now: Date, compact: Bool = false,
                showsHeader: Bool = true, showsHorizon: Bool = true) {
        self.account = account
        self.overview = overview
        self.now = now
        self.compact = compact
        self.showsHeader = showsHeader
        self.showsHorizon = showsHorizon
    }

    private var hasBurn: Bool { AccountOverview.Account.hasBurn(in: overview) }

    private var palette: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 4) {
                    Text(account.metadata.label).font(.system(size: 24, weight: .semibold)).lineLimit(2)
                    (Text(account.metadata.provider.accountDisplayName).fontWeight(.semibold)
                        .foregroundColor(palette.provider(account.metadata.provider))
                     + Text(" · \(account.stateText)" + (account.observedAt.map { " · updated " + AccountPaceText.when($0, now: now) } ?? ""))
                     + (Provider.allCases.contains(where: { overview.useNext(provider: $0)?.id == account.id })
                        ? Text(" · " + AccountTerms.useNext).fontWeight(.semibold).foregroundColor(palette.provider(account.metadata.provider)) : Text(""))
                     + (account.metadata.useLast ? Text(" · " + AccountTerms.useLast) : Text("")))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
            if let plan = account.providerPlan {
                Text("Plan · " + plan).font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            if showsHorizon { horizonCard }
            if compact {
                ForEach(account.orderedWindows) { window in windowCard(window) }
            } else {
                AccountWindowCardsLayout {
                    ForEach(account.orderedWindows) { window in windowCard(window) }
                }
            }
            bankedCard
        }
        .foregroundStyle(palette.primary)
    }

    /// The week as one horizon, with what happens before its reset.
    private var horizonCard: some View {
        let horizon = account.horizon(now: now)
        let outcome = AccountTerms.outcome(account, horizon, now: now)
        return DashboardCard(title: AccountTerms.nextSevenDays, fillsHeight: false, palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // This page's one alarm (`AccountAlarm`): the window cards below stay calm.
                    Text(outcome.title).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(horizon.runsOutBeforeReset ? palette.color(AccountAlarm.token)
                                         : palette.color(AccountAlarm.outcomeToken(account, horizon)))
                    Text(outcome.detail).font(.system(size: 12.5)).foregroundStyle(palette.secondary)
                }
                .monospacedDigit()
                DashboardHorizonAxis(now: now, palette: palette).font(.system(size: AccountTextSize.appMinimum, weight: .medium)).foregroundStyle(palette.secondary)
                DashboardHorizon(account: account, horizon: horizon, deadlines: overview.deadlines.filter { $0.accountID == account.id },
                                 now: now, palette: palette)
                    .frame(height: 40)
                if let banked = overview.bankedBeforeRunOut(account, now: now) {
                    HStack(spacing: 6) {
                        DashboardDiamond(palette: palette, size: 7)
                        Text(AccountTerms.bankedBeforeRunOut(banked, now: now))
                    }
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccountTerms.nextSevenDays + ", " + outcome.title + ", " + outcome.detail)
    }

    private func windowCard(_ window: AccountOverview.Window) -> some View {
        DashboardCard(title: window.label, trailing: window.id == account.limitingWindow?.id ? AccountTerms.tightest : nil, fillsHeight: true, palette: palette) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    DashboardRing(fraction: window.remainingFraction, color: account.isReliable ? palette.provider(account.metadata.provider) : palette.stale,
                                  track: palette.track, lineWidth: 8, evenPace: window.evenPaceRemaining(now: now),
                                  tick: palette.primary)
                    VStack(spacing: -2) {
                        Text(window.remainingFraction == nil
                             ? window.used.map(String.init) ?? AccountNumbers.window(window, sign: false)
                             : AccountNumbers.window(window, sign: false))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(window.remainingFraction == nil && window.used != nil
                             ? window.unit.rawValue + " used" : AccountTerms.percentLeft)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    fact(AccountTerms.resets, AccountTerms.reset(window, now: now).map {
                        $0 + "  " + AccountPaceText.countdown(to: window.naturalResetAt ?? now, now: now)
                    } ?? AccountTerms.unknown)
                    if let used = window.used {
                        fact("Used", window.limit.map { window.unit == .percent && $0 == 100
                            ? "\(used)%" : "\(used) of \($0) \(window.unit.rawValue)" }
                            ?? "\(used) \(window.unit.rawValue)")
                    } else if let limit = window.limit {
                        fact("Limit", "\(limit) \(window.unit.rawValue)")
                    }
                    fact("Status", window.status.displayText)
                    fact("Reading", window.assumption?.displayText ?? window.confidence.rawValue.capitalized)
                    if let observed = window.observedAt {
                        fact("Observed", ContextPanelDateFormatting.accountReset(observed))
                    }
                    if let even = window.evenPaceRemaining(now: now) {
                        fact("Even pace", AccountNumbers.percentWithSign(even) + " left now")
                    }
                    if hasBurn { fact("Using", !account.isReliable ? "not current" : window.burnFractionPerHour.map { AccountTerms.burn($0, windowDuration: window.duration) + " · "
                        + AccountPaceText.ratio(window.paceRatio(now: now)) + " the even pace" } ?? AccountTerms.measuring) }
                    if account.isReliable, let runOut = window.projectedRunOut(now: now) {
                        GridRow {
                            Text("Runs out").foregroundStyle(palette.secondary)
                            Text(AccountPaceText.approximately(runOut, now: now) + " · before reset")
                                .fontWeight(.semibold)
                                .foregroundStyle(AccountAlarm.windowRunOutIsAlarm(account.horizon(now: now))
                                                 ? palette.color(AccountAlarm.token) : palette.primary)
                        }
                    }
                }
                .font(.system(size: 12)).monospacedDigit()
                Spacer(minLength: 0)
            }
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(palette.secondary)
            Text(value)
        }
    }

    private var bankedCard: some View {
        let inventory = account.bankedResets
        let dates = inventory.map { value in
            (value.knownExpiries.isEmpty ? value.earliestKnownExpiry.map { [$0] } ?? [] : value.knownExpiries)
                .filter { $0 > now }
        }.map(Array.init) ?? []
        return DashboardCard(title: AccountTerms.bankedResets, trailing: account.bankedResets.map {
            AccountTerms.bankedCount($0.availableCount, current: account.bankedState == .available) },
                             fillsHeight: false, palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                if let inventory = account.bankedResets {
                    Text("Observed " + ContextPanelDateFormatting.accountReset(inventory.observedAt))
                        .font(.system(size: 12)).foregroundStyle(palette.secondary)
                    if account.bankedState != .available {
                        Text("Last observed · refresh the Mac for current inventory")
                            .font(.system(size: 12)).foregroundStyle(palette.stale)
                    }
                } else {
                    Text("Unknown for this account").foregroundStyle(palette.secondary)
                }
                if let advice = account.bankedAdvice {
                    Text(advice.title).font(.system(size: 12, weight: .semibold))
                    Text(advice.detail).font(.system(size: 12)).foregroundStyle(palette.secondary)
                }
                ForEach(Array(dates.enumerated()), id: \.offset) { _, expiry in
                    HStack(spacing: 10) {
                        Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 9)).foregroundStyle(palette.banked)
                        Text("Expires " + AccountPaceText.when(expiry, now: now)).monospacedDigit()
                        Spacer()
                        Text(AccountPaceText.countdown(to: expiry, now: now)).monospacedDigit()
                            .foregroundStyle(palette.secondary)
                    }
                    .font(.system(size: 12.5))
                }
                if let unknown = account.unknownExpiryCount, unknown > 0 {
                    Text("\(unknown) without a known expiry").font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary)
                }
            }
        }
    }
}

// MARK: - Building blocks

struct DashboardPalette {
    let dark: Bool

    /// Every value comes from `AccountColorToken` in ContextPanelCore.
    func color(_ token: AccountColorToken) -> Color {
        let value = token.rgb(dark: dark)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: dark))
    }

    var surface: Color { color(.surface) }
    var card: Color { color(.card) }
    var primary: Color { color(.primary) }
    var secondary: Color { color(.secondary) }
    var tertiary: Color { color(.tertiary) }
    var line: Color { color(.line) }
    var track: Color { color(.track) }
    var fill: Color { color(.fill) }
    var good: Color { color(.available) }
    var warn: Color { color(.low) }
    var bad: Color { color(.critical) }
    var stale: Color { color(.saved) }
    var banked: Color { color(.banked) }
    var next: Color { color(.next) }

    func color(forRemaining fraction: Double?) -> Color { color(AccountTone.forRemaining(fraction).fillToken) }
    func color(for account: AccountOverview.Account) -> Color { color(AccountTone.forAccount(account).fillToken) }
    func textColor(for window: AccountOverview.Window) -> Color {
        color(AccountTone.forRemaining(window.remainingFraction).textToken)
    }
    func paceColor(_ ratio: Double?) -> Color { color(AccountTone.forPace(ratio)) }
    func provider(_ provider: Provider) -> Color { color(provider.colorToken) }
}

struct DashboardCard<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var fillsHeight = true
    let palette: DashboardPalette
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.system(size: AccountTextSize.appMinimum, weight: .semibold)).foregroundStyle(palette.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: AccountTextSize.appMinimum)).foregroundStyle(palette.secondary) }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }
}

struct DashboardRing: View {
    let fraction: Double?
    let color: Color
    let track: Color
    let lineWidth: CGFloat
    var evenPace: Double? = nil
    var tick: Color = .primary

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(0.01, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            if let evenPace {
                Capsule().fill(tick.opacity(0.75)).frame(width: 2, height: lineWidth + 6)
                    .offset(y: -1)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .rotationEffect(.degrees(360 * evenPace))
                    .padding(-3)
            }
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Horizon

/// One account's horizon: what is left now, draining at the observed burn toward the weekly reset. The gap
/// between running out and the reset is hatched red, the only red; after the reset the window is full again.
struct DashboardHorizon: View {
    let account: AccountOverview.Account
    let horizon: AccountHorizon
    let deadlines: [AccountOverview.Deadline]
    let now: Date
    let palette: DashboardPalette
    var showsDays = true

    var body: some View {
        let geometry = horizon.geometry(now: now, deadlines: deadlines)
        let hue = horizon.isCurrent ? palette.provider(account.metadata.provider) : palette.stale
        Canvas { context, size in
            let w = size.width, h = size.height
            let trackEnd = (geometry.resetX ?? 1) * w
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: trackEnd, height: h), cornerRadius: 3), with: .color(palette.track))
            if showsDays {
                for x in geometry.dayXs {
                    context.fill(Path(CGRect(x: x * w, y: 0, width: 1, height: h)), with: .color(palette.line))
                }
            }
            if let reset = geometry.resetX, reset < 1 {
                context.fill(Path(roundedRect: CGRect(x: reset * w, y: 1.5, width: w - reset * w, height: h - 1.5), cornerRadius: 2),
                             with: .color(hue.opacity(0.13)))
            }
            guard horizon.remaining != nil else { return }
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: h))
            fill.addLine(to: CGPoint(x: 0, y: h * (1 - geometry.startLevel)))
            fill.addLine(to: CGPoint(x: geometry.fillEndX * w, y: h * (1 - geometry.fillEndLevel)))
            fill.addLine(to: CGPoint(x: geometry.fillEndX * w, y: h))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [hue.opacity(0.95), hue.opacity(0.45)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: h * (1 - geometry.startLevel)))
            edge.addLine(to: CGPoint(x: geometry.fillEndX * w, y: h * (1 - geometry.fillEndLevel)))
            context.stroke(edge, with: .color(hue), lineWidth: 1.5)
            if let empty = geometry.emptyRange {
                let rect = CGRect(x: empty.lowerBound * w, y: 0, width: (empty.upperBound - empty.lowerBound) * w, height: h)
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    var stripes = Path()
                    var x = rect.minX - h
                    while x < rect.maxX {
                        stripes.move(to: CGPoint(x: x, y: h))
                        stripes.addLine(to: CGPoint(x: x + h, y: 0))
                        x += 5
                    }
                    layer.stroke(stripes, with: .color(palette.bad.opacity(0.32)), lineWidth: 2)
                }
                context.fill(Path(roundedRect: CGRect(x: rect.minX, y: h - 2.5, width: rect.width, height: 2.5), cornerRadius: 1),
                             with: .color(palette.bad))
            }
            if let reset = geometry.resetX {
                context.fill(Path(CGRect(x: min(w - 1.5, reset * w - 0.75), y: 0, width: 1.5, height: h)), with: .color(palette.primary))
            }
            for lapse in geometry.banked {
                let center = CGPoint(x: lapse.x * w, y: min(h - 4.5, max(4.5, h * (1 - lapse.level))))
                let diamond = Path { path in
                    path.move(to: CGPoint(x: center.x, y: center.y - 4.5))
                    path.addLine(to: CGPoint(x: center.x + 4.5, y: center.y))
                    path.addLine(to: CGPoint(x: center.x, y: center.y + 4.5))
                    path.addLine(to: CGPoint(x: center.x - 4.5, y: center.y))
                    path.closeSubpath()
                }
                context.stroke(diamond, with: .color(palette.card), lineWidth: 2.5)
                context.fill(diamond, with: .color(palette.banked))
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Now" and the weekday at each midnight across the horizon's seven days.
struct DashboardHorizonAxis: View {
    let now: Date
    let palette: DashboardPalette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Text(AccountTerms.now).foregroundStyle(palette.primary).fixedSize()
                ForEach(AccountHorizon.days(now: now), id: \.date) { day in
                    if day.x * proxy.size.width > 34, day.x * proxy.size.width < proxy.size.width - 16 {
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated))).fixedSize().offset(x: day.x * proxy.size.width + 3)
                    }
                }
            }
        }
        .frame(height: 14)
    }
}

/// The banked-reset diamond.
struct DashboardDiamond: View {
    let palette: DashboardPalette
    let size: CGFloat
    var body: some View {
        Rectangle().fill(palette.banked).frame(width: size, height: size).rotationEffect(.degrees(45))
            .frame(width: size * 1.42, height: size * 1.42).accessibilityHidden(true)
    }
}

struct DashboardLegendSwatch: View {
    enum Kind { case left, empty, reset }
    let kind: Kind
    let palette: DashboardPalette

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            switch kind {
            case .left:
                var path = Path()
                path.move(to: CGPoint(x: 0, y: h)); path.addLine(to: CGPoint(x: 0, y: 2))
                path.addLine(to: CGPoint(x: w, y: h * 0.55)); path.addLine(to: CGPoint(x: w, y: h)); path.closeSubpath()
                context.fill(path, with: .color(palette.provider(.openAI).opacity(0.75)))
            case .empty:
                var stripes = Path()
                var x = -h
                while x < w { stripes.move(to: CGPoint(x: x, y: h)); stripes.addLine(to: CGPoint(x: x + h, y: 0)); x += 5 }
                context.clip(to: Path(CGRect(origin: .zero, size: size)))
                context.stroke(stripes, with: .color(palette.bad.opacity(0.4)), lineWidth: 2)
                context.fill(Path(CGRect(x: 0, y: h - 2.5, width: w, height: 2.5)), with: .color(palette.bad))
            case .reset:
                context.fill(Path(CGRect(x: 5, y: 0, width: 1.5, height: h)), with: .color(palette.primary))
                context.fill(Path(CGRect(x: 7, y: 1, width: w - 7, height: h - 1)), with: .color(palette.provider(.openAI).opacity(0.15)))
            }
        }
        .frame(width: 22, height: 12)
        .accessibilityHidden(true)
    }
}
