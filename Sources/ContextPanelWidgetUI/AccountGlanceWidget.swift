import ContextPanelCore
import SwiftUI
import WidgetKit

/// Account widgets: every account's 5h and weekly room, pace, the next reset or run-out, and banked deadlines.
struct AccountGlanceWidget: View {
    @Environment(\.cpwThemeVariant) private var theme
    @Environment(\.colorScheme) private var colorScheme
    let family: WidgetFamily
    let snapshot: WidgetSnapshot
    let links: ContextPanelWidgetLinks
    let now: Date
    let maximumAge: TimeInterval
    let showsBanked: Bool

    private var overview: AccountOverview { snapshot.accountOverview(now: now, widgetsOnly: true, maximumAge: maximumAge) }
    private var palette: GlancePalette {
        GlancePalette(dark: theme == .dark || (theme == .adaptive && colorScheme == .dark))
    }
    private var nextIDs: Set<String> {
        Set(Provider.allCases.compactMap { overview.useNext(provider: $0)?.id })
    }

    var body: some View {
        let overview = overview
        Group {
            if overview.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.accountDisplayMetadata?.isEmpty == false ? "No accounts shown" : "Add your first account")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Open Context Panel to set up accounts.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            } else {
                switch family {
                case .systemSmall:
                    if overview.accounts.count <= 2 { spotlight(overview.closest ?? overview.accounts[0], overview: overview) }
                    else { ringGrid(overview) }
                case .systemLarge, .systemExtraLarge:
                    large(overview)
                default:
                    medium(overview)
                }
            }
        }
        .padding(family == .systemSmall ? 12 : 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(palette.primary)
        .background(palette.surface)
    }

    // MARK: Small

    /// One row per provider: its mark, then a ring per account (tightest % left), so which
    /// account belongs to which provider reads without words.
    private func ringGrid(_ overview: AccountOverview) -> some View {
        let shown = Set(overview.accounts.prefix(6).map(\.id))
        let names = overview.shortLabels
        let groups = Provider.allCases.map { provider in overview.accounts.filter { $0.metadata.provider == provider && shown.contains($0.id) } }
            .filter { !$0.isEmpty }
        let ring: CGFloat = groups.count > 2 ? 27 : 31
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(AccountTerms.widgetTitle).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if overview.accounts.count > shown.count {
                    Text("+\(overview.accounts.count - shown.count)").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                }
                Spacer(minLength: 0)
                Text(AccountTerms.percentLeft).font(.system(size: 8.5, weight: .medium)).foregroundStyle(palette.tertiary)
            }
            ForEach(groups, id: \.first!.id) { group in
                HStack(alignment: .top, spacing: 6) {
                    GlanceProviderMark(provider: group[0].metadata.provider, palette: palette, size: 14).padding(.top, (ring - 14) / 2)
                    ForEach(group) { account in
                        VStack(spacing: 1) {
                            ZStack {
                                GlanceRing(fraction: account.remainingFraction, color: palette.color(for: account),
                                           track: palette.track, lineWidth: 3)
                                Text(AccountNumbers.account(account, sign: false))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(width: ring, height: ring)
                            .overlay(alignment: .topTrailing) {
                                if nextIDs.contains(account.id) {
                                    Circle().fill(palette.next).frame(width: 6.5, height: 6.5)
                                        .overlay(Circle().stroke(palette.surface, lineWidth: 1.5))
                                }
                            }
                            if groups.count <= 2 {
                                Text(names[account.id] ?? account.metadata.label).font(.system(size: 8, weight: .medium)).lineLimit(1)
                                    .foregroundStyle(palette.secondary).frame(width: ring + 8)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)))
                    }
                    Spacer(minLength: 0)
                }
            }
            Spacer(minLength: 0)
            if showsBanked, let deadline = overview.nextDeadline {
                bankedLine(deadline, compact: true)
            } else if let runOut = overview.accounts.compactMap({ a in a.earliestRunOut(now: now).map { (a, $0.date) } }).min(by: { $0.1 < $1.1 }) {
                HStack(spacing: 4) {
                    Image(systemName: AccountGlyphs.runOut).font(.system(size: 8))
                    Text("\(runOut.0.metadata.label) out \(AccountPaceText.approximately(runOut.1, now: now))").lineLimit(1)
                }.font(.system(size: 9, weight: .medium)).foregroundStyle(palette.bad)
            }
        }
    }

    private func spotlight(_ account: AccountOverview.Account, overview: AccountOverview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                GlanceProviderMark(provider: account.metadata.provider, palette: palette, size: 12)
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                GlanceStatusMark(state: account.state, palette: palette)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(account.remainingText).font(.system(size: 30, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(AccountTerms.left).font(.system(size: 11, weight: .medium)).foregroundStyle(palette.secondary)
            }
            ForEach(account.orderedWindows) { window in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(window.shortLabel).font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.secondary)
                        Spacer(minLength: 0)
                        Text(AccountTerms.reset(window, now: now) ?? "—")
                            .font(.system(size: 9)).monospacedDigit().foregroundStyle(palette.secondary)
                    }
                    GlanceMeter(fraction: window.remainingFraction, even: window.evenPaceRemaining(now: now), palette: palette, height: 4)
                }
            }
            Spacer(minLength: 0)
            if showsBanked, let deadline = overview.nextDeadline { bankedLine(deadline, compact: true) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)))
    }

    // MARK: Medium

    private func medium(_ overview: AccountOverview) -> some View {
        let showsDeadline = showsBanked && overview.nextDeadline != nil
        let combined = overview.providerTotals(now: now).filter(\.isCombined)
        let rows = Array(overview.accounts.prefix(showsDeadline ? 6 : 7))
        return VStack(alignment: .leading, spacing: 0) {
            columnHeader(title: AccountTerms.widgetTitle + (overview.accounts.count > rows.count ? " +\(overview.accounts.count - rows.count)" : ""),
                         trailing: AccountTerms.next.capitalized, compact: true)
                .padding(.bottom, 3)
            ForEach(rows) { account in
                Link(destination: links.account(account.metadata.provider, id: account.id)) {
                    compactRow(account)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
            if !combined.isEmpty {
                combinedStrip(combined).padding(.bottom, 2)
            }
            if showsDeadline, let deadline = overview.nextDeadline {
                Link(destination: links.deadlines) { bankedLine(deadline, compact: false, total: overview.deadlines.filter { $0.state == .available }.count) }
                    .buttonStyle(.plain)
            } else if overview.accounts.count > rows.count {
                Link("+\(overview.accounts.count - rows.count) more", destination: links.overview)
                    .font(.system(size: 9, weight: .medium)).foregroundStyle(palette.secondary)
            }
        }
    }

    private func columnHeader(title: String, trailing: String, compact: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(AccountTerms.longColumn(weekly: overview.accounts.allSatisfy { $0.longWindow == nil || $0.longWindow?.duration == 7 * 86_400 }))
                    .frame(width: 52, alignment: .leading)
                Text(AccountTerms.fiveHour).frame(width: 44, alignment: .leading)
                Text(trailing).frame(width: 84, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(palette.tertiary)
        }
    }

    private func compactRow(_ account: AccountOverview.Account) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 4) {
                GlanceProviderMark(provider: account.metadata.provider, palette: palette, size: 12)
                Text(account.metadata.label).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                // The provider mark leads; status is marked only when it is not the normal one.
                if account.state != .available { GlanceStatusMark(state: account.state, palette: palette) }
                if nextIDs.contains(account.id) { NextMark(palette: palette) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            windowCell(account, window: weekly(account), width: 52)
            windowCell(account, window: fiveHour(account), width: 44)
            trailingTime(account).frame(width: 84, alignment: .trailing)
        }
        .frame(height: 15.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)))
        .accessibilityHint("Opens this account")
    }

    private func windowCell(_ account: AccountOverview.Account, window: AccountOverview.Window?, width: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text(window.map { AccountNumbers.window($0, sign: false) } ?? AccountTerms.unknown)
                .font(.system(size: 10, weight: window?.id == account.limitingWindow?.id ? .bold : .regular).monospacedDigit())
                .foregroundStyle(window.map { palette.textColor(for: $0) } ?? palette.tertiary)
                .frame(width: 20, alignment: .trailing)
            GlanceMeter(fraction: window?.remainingFraction, even: window?.evenPaceRemaining(now: now), palette: palette, height: 4)
        }
        .frame(width: width)
    }

    @ViewBuilder
    private func trailingTime(_ account: AccountOverview.Account) -> some View {
        if let runOut = account.earliestRunOut(now: now) {
            HStack(spacing: 2) {
                Image(systemName: AccountGlyphs.runOut).font(.system(size: 7))
                Text(AccountPaceText.approximately(runOut.date, now: now)).monospacedDigit()
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.bad).lineLimit(1)
        } else if [.stale, .unavailable].contains(account.state) {
            Text(AccountTerms.accountTiming(account, now: now))
                .font(.system(size: 9.5)).foregroundStyle(palette.stale).lineLimit(1)
        } else {
            Text(account.limitingWindow.flatMap { AccountTerms.reset($0, now: now) } ?? account.state.displayText)
                .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
        }
    }

    /// Combined room per provider with more than one account: mark, week % left, and its outlook.
    private func combinedStrip(_ totals: [AccountProviderTotal]) -> some View {
        HStack(spacing: 10) {
            Text(AccountTerms.combined).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(palette.tertiary)
            ForEach(totals) { total in
                HStack(spacing: 3) {
                    GlanceProviderMark(provider: total.provider, palette: palette, size: 10)
                    Text(AccountNumbers.percentWithSign(total.longRemaining)).fontWeight(.semibold).monospacedDigit()
                        .foregroundStyle(palette.color(AccountTone.forRemaining(total.longRemaining).textToken))
                    if total.runOut != nil {
                        Text(AccountTerms.combinedOutlook(total, now: now)).foregroundStyle(palette.bad)
                    } else if total.paceRatio != nil {
                        Text(AccountPaceText.ratio(total.paceRatio)).foregroundStyle(palette.paceColor(total.paceRatio))
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(total.accessibilityText(now: now))
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 9.5))
    }

    // MARK: Large

    private func large(_ overview: AccountOverview) -> some View {
        let rows = Array(overview.accounts.prefix(6))
        let totals = overview.providerTotals(now: now)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(AccountTerms.widgetTitle).font(.system(size: 12, weight: .semibold))
                if overview.accounts.count > rows.count {
                    Text("+\(overview.accounts.count - rows.count)").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(palette.secondary)
                }
                Spacer()
                Text([AccountTerms.week, AccountTerms.fiveHour, AccountTerms.pace.lowercased()].joined(separator: " · "))
                    .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(palette.tertiary)
            }
            .padding(.bottom, 3)
            ForEach(totals) { total in
                let members = rows.filter { $0.metadata.provider == total.provider }
                if !members.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        if total.isCombined {
                            largeCombinedRow(total)
                        }
                        ForEach(members) { account in
                            Link(destination: links.account(account.metadata.provider, id: account.id)) {
                                largeRow(account, showsMark: !total.isCombined)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 5)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(palette.provider(total.provider)).frame(width: 2).padding(.vertical, 2)
                    }
                    .padding(.vertical, 1)
                }
            }
            Spacer(minLength: 3)
            if showsBanked, !overview.deadlines.isEmpty {
                Link(destination: links.deadlines) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(overview.deadlines.prefix(3)) { deadline in
                            HStack(spacing: 5) {
                                Image(systemName: AccountGlyphs.banked).foregroundStyle(palette.banked)
                                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                                    .frame(width: 84, alignment: .leading)
                                Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).monospacedDigit()
                                    .foregroundStyle(palette.secondary).frame(width: 52, alignment: .leading)
                                Text(AccountTerms.deadlineLabel(deadline)).foregroundStyle(palette.secondary).lineLimit(1)
                            }
                        }
                    }
                    .font(.system(size: 9.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// A provider's combined room as the first line of its group.
    private func largeCombinedRow(_ total: AccountProviderTotal) -> some View {
        HStack(spacing: 5) {
            GlanceProviderMark(provider: total.provider, palette: palette, size: 11)
            Text(total.provider.accountDisplayName).font(.system(size: 10.5, weight: .bold))
            Text(AccountNumbers.percentWithSign(total.longRemaining)).font(.system(size: 10.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(palette.color(AccountTone.forRemaining(total.longRemaining).textToken))
            GlanceMeter(fraction: total.longRemaining, even: total.evenPaceRemaining, palette: palette, height: 3.5)
                .frame(width: 46)
            Text(AccountNumbers.percentWithSign(total.shortRemaining)).font(.system(size: 9)).monospacedDigit()
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 2)
            Text(AccountTerms.combinedOutlook(total, now: now)).font(.system(size: 8.5, weight: total.runOut == nil ? .regular : .semibold))
                .foregroundStyle(total.runOut == nil ? palette.secondary : palette.bad).lineLimit(1)
            Text(AccountPaceText.ratio(total.paceRatio)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                .foregroundStyle(palette.paceColor(total.paceRatio)).frame(width: 30, alignment: .trailing)
        }
        .padding(.vertical, 3).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(palette.provider(total.provider).opacity(palette.dark ? 0.14 : 0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(total.accessibilityText(now: now))
    }

    private func largeRow(_ account: AccountOverview.Account, showsMark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if showsMark { GlanceProviderMark(provider: account.metadata.provider, palette: palette, size: 11) }
                GlanceStatusMark(state: account.state, palette: palette)
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                if nextIDs.contains(account.id) { NextTag(palette: palette) }
                if let count = account.bankedResets?.availableCount, count > 0, showsBanked {
                    HStack(spacing: 2) {
                        Image(systemName: AccountGlyphs.bankedSmall).font(.system(size: 7, weight: .bold))
                        Text("\(count)")
                    }
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.banked)
                }
                Spacer(minLength: 2)
                if let runOut = account.earliestRunOut(now: now) {
                    Text(AccountTerms.runOut(runOut.date, now: now))
                        .font(.system(size: 9, weight: .semibold)).monospacedDigit().foregroundStyle(palette.bad).lineLimit(1)
                }
                Text(AccountPaceText.ratio(account.paceRatio(now: now)))
                    .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(paceColor(account)).frame(width: 30, alignment: .trailing)
            }
            HStack(spacing: 10) {
                largeWindowCell(account, window: weekly(account))
                largeWindowCell(account, window: fiveHour(account))
            }
            .padding(.leading, 14)
        }
        .padding(.vertical, 3).padding(.leading, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: nextIDs.contains(account.id)))
        .accessibilityHint("Opens this account")
    }

    private func largeWindowCell(_ account: AccountOverview.Account, window: AccountOverview.Window?) -> some View {
        HStack(spacing: 4) {
            Text(window.map { AccountNumbers.window($0, sign: false) } ?? AccountTerms.unknown)
                .font(.system(size: 11, weight: window?.id == account.limitingWindow?.id ? .bold : .medium).monospacedDigit())
                .foregroundStyle(window.map { palette.textColor(for: $0) } ?? palette.tertiary)
                .frame(width: 22, alignment: .trailing)
            if let window { GlanceMeter(fraction: window.remainingFraction, even: window.evenPaceRemaining(now: now), palette: palette, height: 3.5) }
            Text(window.flatMap { AccountTerms.reset($0, now: now) } ?? "")
                .font(.system(size: 8)).monospacedDigit().foregroundStyle(palette.secondary).lineLimit(1)
                .frame(width: 86, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Shared

    private func fiveHour(_ account: AccountOverview.Account) -> AccountOverview.Window? { account.shortWindow }

    private func weekly(_ account: AccountOverview.Account) -> AccountOverview.Window? { account.longWindow }

    private func paceColor(_ account: AccountOverview.Account) -> Color { palette.paceColor(account.paceRatio(now: now)) }

    private func bankedLine(_ deadline: AccountOverview.Deadline, compact: Bool, total: Int = 0) -> some View {
        HStack(spacing: 4) {
            Image(systemName: AccountGlyphs.banked).font(.system(size: compact ? 9 : 10))
                .foregroundStyle(palette.banked)
            if compact {
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).foregroundStyle(palette.secondary)
            } else {
                Text(AccountTerms.bankedResetExpires).foregroundStyle(palette.secondary)
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
                Text("· " + deadline.label).foregroundStyle(palette.secondary)
                Spacer(minLength: 0)
                if total > 1 { Text("+\(total - 1)").foregroundStyle(palette.tertiary) }
            }
        }
        .font(.system(size: compact ? 9 : 9.5)).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Banked reset for \(deadline.label) expires \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
    }
}

// MARK: - Building blocks

struct GlancePalette {
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
    var markInk: Color { color(.markInk) }
}

/// The provider's letter on its colour, the same mark as the app.
struct GlanceProviderMark: View {
    let provider: Provider
    let palette: GlancePalette
    let size: CGFloat

    var body: some View {
        Text(provider.markLetter).font(.system(size: size * 0.66, weight: .bold, design: .rounded))
            .foregroundStyle(palette.markInk)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(palette.provider(provider)))
            .accessibilityHidden(true)
    }
}

/// Remaining share as a bar, with a tick where an even spend would be now.
struct GlanceMeter: View {
    let fraction: Double?
    let even: Double?
    let palette: GlancePalette
    let height: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let filled = fraction ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(palette.track)
                Capsule().fill(palette.color(forRemaining: fraction))
                    .frame(width: max(filled > 0 ? height : 0, width * filled))
                if let even {
                    Rectangle().fill(palette.primary.opacity(0.75))
                        .frame(width: 1.5, height: height + 4)
                        .offset(x: min(width - 1.5, max(0, width * even - 0.75)))
                }
            }
            .frame(height: height + 4)
        }
        .frame(height: height + 4)
        .accessibilityHidden(true)
    }
}

struct GlanceRing: View {
    let fraction: Double?
    let color: Color
    let track: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            if let fraction {
                Circle().trim(from: 0, to: max(0.015, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().stroke(track, style: StrokeStyle(lineWidth: lineWidth, dash: [2, 3]))
            }
        }
        .padding(lineWidth / 2)
    }
}

struct GlanceStatusMark: View {
    let state: AccountCapacityState
    let palette: GlancePalette

    var body: some View {
        Image(systemName: state.glyphName).font(.system(size: 7.5, weight: .bold))
            .foregroundStyle(palette.color(state.colorToken))
            .frame(width: 9).accessibilityHidden(true)
    }
}

struct NextTag: View {
    let palette: GlancePalette
    var body: some View {
        Text(AccountTerms.next).font(.system(size: 6.5, weight: .heavy)).tracking(0.4)
            .foregroundStyle(palette.next)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 2.5).stroke(palette.next, lineWidth: 0.8))
            .accessibilityLabel("Use next")
    }
}

/// A small "use next" arrow for rows too narrow for the NEXT tag.
struct NextMark: View {
    let palette: GlancePalette
    var body: some View {
        Image(systemName: AccountGlyphs.useNext).font(.system(size: 8.5)).foregroundStyle(palette.next)
            .accessibilityLabel("Use next")
    }
}

