import ContextPanelCore
import SwiftUI

/// Mac overview: three answers on top, then one row per account with both windows,
/// pace, and a seven-day lane of resets, run-outs and banked expiries.
public struct AccountDashboardPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let overview: AccountOverview
    let now: Date
    let openAccount: (AccountOverview.Account) -> Void
    let openDeadlines: () -> Void

    public init(overview: AccountOverview, now: Date, openAccount: @escaping (AccountOverview.Account) -> Void,
                openDeadlines: @escaping () -> Void) {
        self.overview = overview
        self.now = now
        self.openAccount = openAccount
        self.openDeadlines = openDeadlines
    }

    private var palette: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }
    private var nextIDs: Set<String> { Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id }) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountTerms.accounts).font(.system(size: 24, weight: .semibold))
                Spacer()
                if let updated = overview.accounts.compactMap(\.observedAt).max() {
                    Text("Updated " + AccountPaceText.when(updated, now: now)).font(.system(size: 12))
                        .monospacedDigit().foregroundStyle(palette.secondary)
                }
            }
            if overview.accounts.isEmpty {
                Text("Add an account in Settings to see its usage and reset times.").foregroundStyle(palette.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    tightestCard
                    useNextCard
                    bankedCard
                }
                .fixedSize(horizontal: false, vertical: true)
                table
                legend
            }
        }
        .foregroundStyle(palette.primary)
    }

    // MARK: Answers

    private var tightestCard: some View {
        DashboardCard(title: AccountTerms.tightest, palette: palette) {
            if let account = overview.closest {
                Button { openAccount(account) } label: {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            DashboardRing(fraction: account.remainingFraction, color: palette.color(for: account),
                                          track: palette.track, lineWidth: 6)
                            VStack(spacing: -2) {
                                Text(AccountNumbers.percent(account.remainingFraction))
                                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                                Text(AccountTerms.percentLeft).font(.system(size: 8.5, weight: .medium)).foregroundStyle(palette.secondary)
                            }
                        }
                        .frame(width: 64, height: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.metadata.label).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text("\(account.metadata.provider.accountDisplayName) · \(account.limitingWindow?.label ?? "window")")
                                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                            if let reset = account.limitingWindow?.naturalResetAt {
                                Text("Resets " + AccountPaceText.when(reset, now: now)).font(.system(size: 11)).monospacedDigit()
                            }
                            if let runOut = account.earliestRunOut(now: now) {
                                Label("Out \(AccountPaceText.approximately(runOut.date, now: now)) at this pace",
                                      systemImage: AccountGlyphs.runOut)
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(palette.bad)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(AccountTerms.noCurrentReading).foregroundStyle(palette.secondary)
            }
        }
    }

    private var useNextCard: some View {
        DashboardCard(title: AccountTerms.useNext, palette: palette) {
            VStack(alignment: .leading, spacing: 7) {
                let picks = Provider.allCases.compactMap { provider in overview.useNext(provider: provider).map { (provider, $0) } }
                ForEach(picks, id: \.1.id) { provider, account in
                    Button { openAccount(account) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(provider.accountDisplayName).font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(palette.secondary).frame(width: 46, alignment: .leading)
                            Text(account.metadata.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(account.remainingText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if picks.isEmpty { Text(AccountTerms.noEligibleAccount).foregroundStyle(palette.secondary) }
            }
        }
    }

    private var bankedCard: some View {
        DashboardCard(title: AccountTerms.bankedResets, trailing: overview.deadlines.isEmpty ? nil : "\(overview.deadlines.count) dated",
                      palette: palette) {
            Button(action: openDeadlines) {
                VStack(alignment: .leading, spacing: 5) {
                    if let first = overview.nextDeadline {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: AccountGlyphs.banked).foregroundStyle(palette.banked)
                            Text(AccountPaceText.when(first.expiresAt, now: now))
                                .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                            Text(AccountPaceText.countdown(to: first.expiresAt, now: now))
                                .font(.system(size: 11)).foregroundStyle(palette.secondary)
                        }
                        Text(first.label + (first.state == .available ? "" : " · last seen"))
                            .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                        ForEach(overview.deadlines.dropFirst().prefix(2)) { deadline in
                            HStack(spacing: 6) {
                                Text(AccountPaceText.when(deadline.expiresAt, now: now)).monospacedDigit()
                                    .frame(width: 104, alignment: .leading)
                                Text(deadline.label).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                            .font(.system(size: 11))
                        }
                    } else {
                        Text("None dated").foregroundStyle(palette.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Table

    private enum Column {
        static let fiveHour: CGFloat = 112
        static let week: CGFloat = 132
        static let pace: CGFloat = 96
        static let lane: CGFloat = 180
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text("Account").frame(maxWidth: .infinity, alignment: .leading)
                Text("5-hour").frame(width: Column.fiveHour, alignment: .leading)
                Text("Week").frame(width: Column.week, alignment: .leading)
                Text(AccountTerms.pace).frame(width: Column.pace, alignment: .leading)
                DashboardWeekAxis(now: now, palette: palette).frame(width: Column.lane)
            }
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(palette.tertiary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            Rectangle().fill(palette.line).frame(height: 1)
            ForEach(overview.accounts) { account in
                Button { openAccount(account) } label: { row(account) }.buttonStyle(.plain)
                if account.id != overview.accounts.last?.id {
                    Rectangle().fill(palette.line).frame(height: 1).padding(.leading, 14)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }

    private func row(_ account: AccountOverview.Account) -> some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .top, spacing: 8) {
                DashboardStatusMark(state: account.state, palette: palette).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.metadata.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if nextIDs.contains(account.id) { DashboardTag(text: AccountTerms.next, color: palette.next) }
                        if account.metadata.useLast { DashboardTag(text: AccountTerms.last, color: palette.tertiary) }
                    }
                    HStack(spacing: 5) {
                        Text(account.metadata.provider.accountDisplayName)
                        if ![.available, .closeToLimit].contains(account.state) {
                            Text("·")
                            Text(account.state.displayText)
                        }
                        if let count = account.bankedResets?.availableCount, count > 0 {
                            Text("·")
                            Image(systemName: AccountGlyphs.bankedSmall).font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(palette.banked)
                            Text(AccountTerms.bankedCount(count, current: account.bankedState == .available))
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(palette.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            windowCell(account, window: account.shortWindow).frame(width: Column.fiveHour)
            windowCell(account, window: account.longWindow).frame(width: Column.week)
            paceCell(account).frame(width: Column.pace, alignment: .leading)
            DashboardWeekLane(account: account, deadlines: overview.deadlines.filter { $0.accountID == account.id },
                              now: now, palette: palette)
                .frame(width: Column.lane, height: 14)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)))
    }

    private func windowCell(_ account: AccountOverview.Account, window: AccountOverview.Window?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(AccountNumbers.percent(window?.remainingFraction))
                    .font(.system(size: 17, weight: window?.id == account.limitingWindow?.id ? .bold : .medium))
                    .monospacedDigit().foregroundStyle(window.map { palette.textColor(for: $0) } ?? palette.tertiary)
                Text("%").font(.system(size: 10, weight: .medium)).foregroundStyle(palette.tertiary)
                Spacer(minLength: 4)
                Text(window?.naturalResetAt.map { AccountPaceText.when($0, now: now) } ?? "")
                    .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
            }
            if let window { DashboardMeter(window: window, now: now, palette: palette, height: 5) }
            else { Capsule().fill(palette.track).frame(height: 5) }
        }
    }

    private func paceCell(_ account: AccountOverview.Account) -> some View {
        let ratio = account.paceRatio(now: now)
        return VStack(alignment: .leading, spacing: 2) {
            Text(AccountPaceText.ratio(ratio)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                .foregroundStyle(palette.paceColor(ratio))
            if let runOut = account.earliestRunOut(now: now) {
                Text(AccountTerms.runOut(runOut.date, now: now)).font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit().foregroundStyle(palette.bad).lineLimit(1)
            } else {
                Text(AccountTerms.paceWord(ratio))
                    .font(.system(size: 10.5)).foregroundStyle(palette.secondary)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 18) {
            HStack(spacing: 5) {
                Rectangle().fill(palette.primary.opacity(0.75)).frame(width: 1.5, height: 10)
                Text("even-pace mark")
            }
            HStack(spacing: 5) {
                Rectangle().fill(palette.primary).frame(width: 1.5, height: 10)
                Text("weekly reset")
            }
            HStack(spacing: 5) {
                Capsule().fill(palette.bad).frame(width: 14, height: 4)
                Text("out before reset at this pace")
            }
            HStack(spacing: 5) {
                Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 8)).foregroundStyle(palette.banked)
                Text("banked reset expires")
            }
            Spacer()
        }
        .font(.system(size: 10.5)).foregroundStyle(palette.secondary)
    }
}

/// One account: both windows in full, pace math, banked inventory and its week.
public struct AccountDashboardDetail: View {
    @Environment(\.colorScheme) private var colorScheme
    let account: AccountOverview.Account
    let overview: AccountOverview
    let now: Date

    public init(account: AccountOverview.Account, overview: AccountOverview, now: Date) {
        self.account = account
        self.overview = overview
        self.now = now
    }

    private var palette: DashboardPalette { DashboardPalette(dark: colorScheme == .dark) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    DashboardStatusMark(state: account.state, palette: palette)
                    Text(account.metadata.label).font(.system(size: 24, weight: .semibold))
                    if Provider.allCases.contains(where: { overview.useNext(provider: $0)?.id == account.id }) {
                        DashboardTag(text: "USE NEXT", color: palette.next)
                    }
                    if account.metadata.useLast { DashboardTag(text: "USE LAST", color: palette.tertiary) }
                }
                Text("\(account.metadata.provider.accountDisplayName) · \(account.state.displayText)"
                     + (account.observedAt.map { " · updated " + AccountPaceText.when($0, now: now) } ?? ""))
                    .font(.system(size: 12)).foregroundStyle(palette.secondary)
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(account.orderedWindows) { window in windowCard(window) }
            }
            .fixedSize(horizontal: false, vertical: true)
            DashboardCard(title: AccountTerms.nextSevenDays, fillsHeight: false, palette: palette) {
                VStack(spacing: 6) {
                    DashboardWeekAxis(now: now, palette: palette)
                    DashboardWeekLane(account: account, deadlines: overview.deadlines.filter { $0.accountID == account.id },
                                      now: now, palette: palette)
                        .frame(height: 18)
                }
            }
            bankedCard
        }
        .foregroundStyle(palette.primary)
    }

    private func windowCard(_ window: AccountOverview.Window) -> some View {
        DashboardCard(title: window.label, trailing: window.id == account.limitingWindow?.id ? AccountTerms.tightest : nil, palette: palette) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    DashboardRing(fraction: window.remainingFraction, color: palette.color(forRemaining: window.remainingFraction),
                                  track: palette.track, lineWidth: 8, evenPace: window.evenPaceRemaining(now: now),
                                  tick: palette.primary)
                    VStack(spacing: -2) {
                        Text(AccountNumbers.percent(window.remainingFraction))
                            .font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(AccountTerms.percentLeft).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                    fact("Resets", window.naturalResetAt.map {
                        ContextPanelDateFormatting.accountReset($0, compact: true) + "  " + AccountPaceText.countdown(to: $0, now: now)
                    } ?? "Unknown")
                    if let used = window.used, let limit = window.limit {
                        fact("Used", window.unit == .percent && limit == 100 ? "\(used)%" : "\(used) of \(limit) \(window.unit.rawValue)")
                    }
                    if let even = window.evenPaceRemaining(now: now) {
                        fact("Even pace", AccountNumbers.percentWithSign(even) + " left now")
                    }
                    fact("Burn", !account.isReliable ? "not current" : window.burnFractionPerHour.map { String(format: "%.1f%%/h", $0 * 100) + " · "
                        + AccountPaceText.ratio(window.paceRatio(now: now)) + " pace" } ?? AccountTerms.measuring)
                    if account.isReliable, let runOut = window.projectedRunOut(now: now) {
                        GridRow {
                            Text("Runs out").foregroundStyle(palette.secondary)
                            Text(AccountPaceText.approximately(runOut, now: now) + " · before reset")
                                .fontWeight(.semibold).foregroundStyle(palette.bad)
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
        let deadlines = overview.deadlines.filter { $0.accountID == account.id }
        return DashboardCard(title: AccountTerms.bankedResets, trailing: account.bankedResets.map {
            "\($0.availableCount) \(account.bankedState == .available ? "available" : "last seen")" },
                             fillsHeight: false, palette: palette) {
            VStack(alignment: .leading, spacing: 6) {
                if account.bankedResets == nil {
                    Text("Unknown for this account").foregroundStyle(palette.secondary)
                }
                ForEach(deadlines) { deadline in
                    HStack(spacing: 10) {
                        Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 9)).foregroundStyle(palette.banked)
                        Text("Expires " + ContextPanelDateFormatting.accountReset(deadline.expiresAt)).monospacedDigit()
                        if deadline.state != .available {
                            Text("last seen " + AccountPaceText.when(deadline.observedAt, now: now))
                                .foregroundStyle(palette.stale)
                        }
                        Spacer()
                        Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).monospacedDigit()
                            .foregroundStyle(palette.secondary)
                    }
                    .font(.system(size: 12.5))
                }
                if let unknown = account.unknownExpiryCount, unknown > 0 {
                    Text("\(unknown) without a known expiry").font(.system(size: 11.5)).foregroundStyle(palette.secondary)
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
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.system(size: 11)).foregroundStyle(palette.tertiary) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
    }
}

struct DashboardTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 8.5, weight: .heavy)).tracking(0.5).foregroundStyle(color)
            .padding(.horizontal, 4).padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(color, lineWidth: 1))
    }
}

struct DashboardStatusMark: View {
    let state: AccountCapacityState
    let palette: DashboardPalette

    var body: some View {
        Image(systemName: state.glyphName).font(.system(size: 9, weight: .bold))
            .foregroundStyle(palette.color(state.colorToken))
            .frame(width: 11).accessibilityHidden(true)
    }
}

struct DashboardMeter: View {
    let window: AccountOverview.Window
    let now: Date
    let palette: DashboardPalette
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let fraction = window.remainingFraction ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track).frame(height: height)
                Capsule().fill(palette.color(forRemaining: window.remainingFraction))
                    .frame(width: max(fraction > 0 ? height : 0, width * fraction), height: height)
                if let even = window.evenPaceRemaining(now: now) {
                    Rectangle().fill(palette.primary.opacity(0.75)).frame(width: 1.5, height: height + 6)
                        .offset(x: min(width - 1.5, max(0, width * even - 0.75)))
                }
            }
            .frame(height: height + 6)
        }
        .frame(height: height + 6)
        .accessibilityHidden(true)
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

struct DashboardWeekAxis: View {
    let now: Date
    let palette: DashboardPalette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                ForEach(0..<7, id: \.self) { day in
                    let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(day + 1) * 86_400)
                    let x = proxy.size.width * start.timeIntervalSince(now) / (7 * 86_400)
                    if x < proxy.size.width - 14 {
                        Text(start.formatted(.dateTime.weekday(.short)))
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.tertiary)
                            .fixedSize()
                            .offset(x: x + 3)
                    }
                }
            }
        }
        .frame(height: 13)
    }
}

/// Now to seven days: the bar runs to the weekly reset, turns red where this pace would run out first,
/// and diamonds mark banked expiries.
struct DashboardWeekLane: View {
    let account: AccountOverview.Account
    let deadlines: [AccountOverview.Deadline]
    let now: Date
    let palette: DashboardPalette
    private let span: TimeInterval = 7 * 86_400

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let long = account.longWindow
            let reset = long?.naturalResetAt
            let runOut = account.isReliable ? long?.projectedRunOut(now: now) : nil
            ZStack(alignment: .leading) {
                ForEach(0..<7, id: \.self) { day in
                    let start = Calendar.current.startOfDay(for: now).addingTimeInterval(Double(day + 1) * 86_400)
                    Rectangle().fill(palette.line).frame(width: 1, height: height)
                        .offset(x: x(start, width))
                }
                Capsule().fill(palette.track).frame(width: width, height: 3)
                if let reset {
                    Capsule().fill(palette.color(for: account).opacity(0.9)).frame(width: max(3, x(reset, width)), height: 5)
                    if let runOut {
                        Capsule().fill(palette.bad).frame(width: max(3, x(reset, width) - x(runOut, width)), height: 5)
                            .offset(x: x(runOut, width))
                    }
                    if reset.timeIntervalSince(now) <= span {
                        Rectangle().fill(palette.primary).frame(width: 2, height: height)
                            .offset(x: x(reset, width) - 1)
                    }
                }
                ForEach(deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= span }) { deadline in
                    Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: height * 0.72))
                        .foregroundStyle(palette.banked)
                        .background(Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: height * 0.72 + 3))
                            .foregroundStyle(palette.card))
                        .offset(x: x(deadline.expiresAt, width) - height * 0.36)
                }
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
    }

    private func x(_ date: Date, _ width: CGFloat) -> CGFloat {
        width * min(1, max(0, date.timeIntervalSince(now) / span))
    }
}
