import ContextPanelCore
import SwiftUI

/// Every dated banked reset: what expires next, a 30-day picture against each account's weekly
/// resets, and a row per reset with that account's weekly room. Words, dates and colours come from
/// `AccountPresentation` in ContextPanelCore.
public struct AccountDeadlinesPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let overview: AccountOverview
    let now: Date
    let openAccount: (String) -> Void

    public init(overview: AccountOverview, now: Date = Date(), openAccount: @escaping (String) -> Void) {
        self.overview = overview
        self.now = now
        self.openAccount = openAccount
    }

    private var palette: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }
    private static let span: TimeInterval = 30 * 86_400

    private func account(_ id: String) -> AccountOverview.Account? { overview.accounts.first { $0.id == id } }

    private var buckets: [(title: String, deadlines: [AccountOverview.Deadline])] {
        let week = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= 7 * 86_400 }
        let month = overview.deadlines.filter { (7 * 86_400 + 1...Self.span).contains($0.expiresAt.timeIntervalSince(now)) }
        let later = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) > Self.span }
        return [(AccountTerms.thisWeek, week), (AccountTerms.nextThirtyDays, month), (AccountTerms.later, later)].filter { !$0.1.isEmpty }
    }

    private var undated: [AccountOverview.Account] { overview.accounts.filter { ($0.unknownExpiryCount ?? 0) > 0 } }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountTerms.bankedResets).font(.system(size: 24, weight: .semibold))
                Spacer()
                Text("\(overview.deadlines.count) dated" + (undated.isEmpty ? "" : " · " + AccountTerms.undated(undated.reduce(0) { $0 + ($1.unknownExpiryCount ?? 0) })))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            if overview.deadlines.isEmpty && undated.isEmpty {
                Text(AccountTerms.noDatedBankedResets).foregroundStyle(palette.secondary)
            } else {
                tiles
                if !overview.deadlines.isEmpty { timeline }
                ForEach(buckets, id: \.title) { bucket in
                    section(bucket.title, bucket.deadlines)
                }
                if !undated.isEmpty { undatedCard }
            }
        }
        .foregroundStyle(palette.primary)
    }

    // MARK: Tiles

    private var tiles: some View {
        let accountsWithBanked = Set(overview.deadlines.map(\.accountID)).count
        let thisWeek = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= 7 * 86_400 }.count
        let month = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= Self.span }.count
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            DashboardCard(title: AccountTerms.nextExpiry, palette: palette) {
                if let next = overview.nextDeadline ?? overview.deadlines.first {
                    Button { openAccount(next.accountID) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: AccountGlyphs.banked).foregroundStyle(palette.banked)
                                Text(AccountPaceText.when(next.expiresAt, now: now)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                            }
                            Text(AccountPaceText.countdown(to: next.expiresAt, now: now)).font(.system(size: 12, weight: .medium))
                                .monospacedDigit().foregroundStyle(palette.banked)
                            HStack(spacing: 5) {
                                DashboardProviderMark(provider: next.provider, palette: palette, size: 13)
                                Text(AccountTerms.deadlineLabel(next)).lineLimit(1)
                            }
                            .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(AccountTerms.unknown).foregroundStyle(palette.secondary)
                }
            }
            countTile(AccountTerms.thisWeek, thisWeek, detail: overview.deadlines.first.map { _ in "of \(overview.deadlines.count) dated" })
            countTile(AccountTerms.nextThirtyDays, month, detail: "\(accountsWithBanked) account" + (accountsWithBanked == 1 ? "" : "s"))
            countTile(AccountTerms.datesUnknown, undated.reduce(0) { $0 + ($1.unknownExpiryCount ?? 0) },
                      detail: undated.isEmpty ? nil : undated.map(\.metadata.label).joined(separator: ", "))
        }
    }

    private func countTile(_ title: String, _ value: Int, detail: String?) -> some View {
        DashboardCard(title: title, palette: palette) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(value)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(value == 0 ? palette.tertiary : palette.primary)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1) }
            }
        }
    }

    // MARK: Timeline

    /// Thirty days, one lane per account with banked resets: diamonds where they expire, ticks
    /// where the account's weekly window resets on its own.
    private var timeline: some View {
        let lanes = overview.accounts.filter { account in overview.deadlines.contains { $0.accountID == account.id } }
        let names = overview.shortLabels
        return DashboardCard(title: AccountTerms.nextThirtyDays, fillsHeight: false, palette: palette) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Color.clear.frame(width: 120, height: 1)
                    DeadlineAxis(now: now, span: Self.span, palette: palette)
                }
                ForEach(lanes) { account in
                    Button { openAccount(account.id) } label: {
                        HStack(spacing: 10) {
                            HStack(spacing: 6) {
                                DashboardProviderMark(provider: account.metadata.provider, palette: palette, size: 14)
                                Text(names[account.id] ?? account.metadata.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                            }
                            .frame(width: 120, alignment: .leading)
                            DeadlineLane(account: account, deadlines: overview.deadlines.filter { $0.accountID == account.id },
                                         now: now, span: Self.span, palette: palette)
                                .frame(height: 16)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 16) {
                    HStack(spacing: 5) {
                        Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 8)).foregroundStyle(palette.banked)
                        Text("banked reset expires")
                    }
                    HStack(spacing: 5) {
                        Rectangle().fill(palette.secondary).frame(width: 1.5, height: 10)
                        Text("weekly reset")
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(palette.secondary).padding(.top, 2)
            }
        }
    }

    // MARK: Rows

    private func section(_ title: String, _ deadlines: [AccountOverview.Deadline]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                Spacer()
                Text("\(deadlines.count)").font(.system(size: 11)).foregroundStyle(palette.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            ForEach(deadlines) { deadline in
                Rectangle().fill(palette.line).frame(height: 1)
                Button { openAccount(deadline.accountID) } label: { row(deadline) }.buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }

    private func row(_ deadline: AccountOverview.Deadline) -> some View {
        let account = account(deadline.accountID)
        let week = account?.longWindow
        let relation = AccountTerms.weekResetRelation(expiresAt: deadline.expiresAt, weekReset: week?.naturalResetAt, now: now)
        let lapsesFirst = week?.naturalResetAt.map { $0 >= deadline.expiresAt } ?? false
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                when(deadline).frame(width: 150, alignment: .leading)
                who(deadline).frame(maxWidth: .infinity, alignment: .leading)
                if let account { weekRoom(account, week: week).frame(width: 150) }
                Text(relation ?? "").font(.system(size: 11, weight: lapsesFirst ? .medium : .regular))
                    .foregroundStyle(lapsesFirst ? palette.banked : palette.secondary).lineLimit(2)
                    .frame(width: 170, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    when(deadline)
                    Spacer(minLength: 8)
                    if let account { weekRoom(account, week: week).frame(width: 120) }
                }
                who(deadline)
                if let relation {
                    Text(relation).font(.system(size: 12, weight: lapsesFirst ? .medium : .regular))
                        .foregroundStyle(lapsesFirst ? palette.banked : palette.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([AccountTerms.bankedResetExpires, deadline.label, ContextPanelDateFormatting.accountReset(deadline.expiresAt),
                             relation].compactMap { $0 }.joined(separator: ", "))
    }

    private func when(_ deadline: AccountOverview.Deadline) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 10)).foregroundStyle(palette.banked)
            VStack(alignment: .leading, spacing: 2) {
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(deadline.state == .available ? AccountPaceText.countdown(to: deadline.expiresAt, now: now)
                     : AccountTerms.lastSeen + " " + AccountPaceText.when(deadline.observedAt, now: now))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(deadline.state == .available ? palette.secondary : palette.stale)
            }
        }
    }

    private func who(_ deadline: AccountOverview.Deadline) -> some View {
        HStack(spacing: 8) {
            DashboardProviderMark(provider: deadline.provider, palette: palette, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(deadline.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(deadline.provider.accountDisplayName).font(.system(size: 11)).foregroundStyle(palette.secondary)
            }
        }
    }

    /// The account's weekly room now, so you can see whether a banked reset is worth spending.
    private func weekRoom(_ account: AccountOverview.Account, week: AccountOverview.Window?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(week.map { AccountNumbers.window($0, sign: false) } ?? AccountTerms.unknown)
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(week.map { palette.textColor(for: $0) } ?? palette.tertiary)
                Text(AccountTerms.percentLeft + " · " + (week?.shortLabel ?? AccountTerms.week))
                    .font(.system(size: 10.5)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            DashboardMeter(fraction: week?.remainingFraction, even: week?.evenPaceRemaining(now: now), palette: palette, height: 4)
        }
    }

    private var undatedCard: some View {
        DashboardCard(title: AccountTerms.datesUnknown, fillsHeight: false, palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(undated) { account in
                    HStack(spacing: 8) {
                        DashboardProviderMark(provider: account.metadata.provider, palette: palette, size: 14)
                        Text(account.metadata.label).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(AccountTerms.undated(account.unknownExpiryCount ?? 0)).font(.system(size: 12)).foregroundStyle(palette.secondary)
                    }
                }
            }
        }
    }
}

struct DeadlineAxis: View {
    let now: Date
    let span: TimeInterval
    let palette: DashboardPalette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(0..<5, id: \.self) { week in
                    let date = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(week * 7 + 1) * 86_400)
                    let x = proxy.size.width * date.timeIntervalSince(now) / span
                    if x < proxy.size.width - 30 {
                        Text(date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.tertiary)
                            .fixedSize().offset(x: x + 3)
                    }
                }
            }
        }
        .frame(height: 13)
    }
}

/// One account across the span: a track, its weekly natural resets as ticks, and its banked expiries as diamonds.
struct DeadlineLane: View {
    let account: AccountOverview.Account
    let deadlines: [AccountOverview.Deadline]
    let now: Date
    let span: TimeInterval
    let palette: DashboardPalette

    private var weeklyResets: [Date] {
        guard let week = account.longWindow, week.duration == 7 * 86_400, let first = week.naturalResetAt, first > now else { return [] }
        return (0..<5).map { first.addingTimeInterval(Double($0) * 7 * 86_400) }.filter { $0.timeIntervalSince(now) <= span }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            ZStack(alignment: .leading) {
                ForEach(0..<5, id: \.self) { week in
                    let date = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(week * 7 + 1) * 86_400)
                    Rectangle().fill(palette.line).frame(width: 1, height: height).offset(x: x(date, width))
                }
                Capsule().fill(palette.track).frame(width: width, height: 4)
                ForEach(weeklyResets, id: \.self) { reset in
                    Rectangle().fill(palette.secondary).frame(width: 1.5, height: height * 0.75).offset(x: x(reset, width) - 0.75)
                }
                ForEach(deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= span }) { deadline in
                    Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: height * 0.72))
                        .foregroundStyle(deadline.state == .available ? palette.banked : palette.stale)
                        .background(Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: height * 0.72 + 3)).foregroundStyle(palette.card))
                        .offset(x: x(deadline.expiresAt, width) - height * 0.36)
                }
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat { width * min(1, max(0, date.timeIntervalSince(now) / span)) }
}
