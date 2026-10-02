import ContextPanelCore
import SwiftUI

// REQUEST: AccountTerms — words this page needs that AccountTerms does not have yet. Move them there and delete these.

/// Deadlines in Horizon's style: a day-by-day agenda for the next 7 days (banked resets lapsing,
/// projected run-outs, weekly resets), then later banked resets and undated ones, beside a small
/// map of the week with one horizon per account. Words, dates and colours come from
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
    private static let week: TimeInterval = 7 * 86_400
    private static let month: TimeInterval = 30 * 86_400

    private func account(_ id: String) -> AccountOverview.Account? { overview.accounts.first { $0.id == id } }
    private var undated: [AccountOverview.Account] { overview.accounts.filter { ($0.unknownExpiryCount ?? 0) > 0 } }
    private var undatedTotal: Int { undated.reduce(0) { $0 + ($1.unknownExpiryCount ?? 0) } }

    // MARK: Events

    fileprivate enum Kind { case banked(AccountOverview.Deadline), runOut(AccountHorizon), reset(AccountHorizon) }

    fileprivate struct Event: Identifiable {
        let id: String
        let date: Date
        let accountID: String
        let provider: Provider
        let label: String
        let kind: Kind
        /// Same-minute order: a lapse, then a run-out, then a reset.
        var rank: Int {
            switch kind {
            case .banked: 0
            case .runOut: 1
            case .reset: 2
            }
        }
    }

    private var events: [Event] {
        var result: [Event] = overview.deadlines.filter { $0.expiresAt > now }.map { deadline in
            Event(id: "banked-" + deadline.id, date: deadline.expiresAt, accountID: deadline.accountID, provider: deadline.provider,
                  label: account(deadline.accountID)?.metadata.label ?? deadline.label, kind: .banked(deadline))
        }
        for account in overview.accounts {
            let horizon = account.horizon(now: now)
            if let runOut = horizon.runOutAt {
                result.append(Event(id: "out-" + account.id, date: runOut, accountID: account.id, provider: account.metadata.provider,
                                    label: account.metadata.label, kind: .runOut(horizon)))
            }
            if let reset = horizon.resetAt, reset.timeIntervalSince(now) <= Self.week {
                result.append(Event(id: "reset-" + account.id, date: reset, accountID: account.id, provider: account.metadata.provider,
                                    label: account.metadata.label, kind: .reset(horizon)))
            }
        }
        return result.sorted { ($0.date, $0.rank) < ($1.date, $1.rank) }
    }

    private var days: [(day: Date, events: [Event])] {
        let calendar = Calendar.current
        let soon = events.filter { $0.date.timeIntervalSince(now) <= Self.week }
        let grouped = Dictionary(grouping: soon) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { ($0, grouped[$0] ?? []) }
    }

    private var later: [Event] { events.filter { $0.date.timeIntervalSince(now) > Self.week } }

    // MARK: Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            HStack(alignment: .top, spacing: 22) {
                agenda.frame(maxWidth: .infinity, alignment: .leading)
                glance.frame(width: 240)
            }
        }
        .foregroundStyle(palette.primary)
    }

    private var header: some View {
        let words = AccountTerms.headline(overview.headline(now: now))
        let dated = overview.deadlines.count
        let thisWeek = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= Self.week }.count
        let month = overview.deadlines.filter { $0.expiresAt.timeIntervalSince(now) <= Self.month }.count
        let summary = dated == 0 && undated.isEmpty ? AccountTerms.noDatedBankedResets
            : AccountTerms.deadlinesSummary(dated: dated, thisWeek: thisWeek, month: month, undated: undatedTotal,
                                    next: overview.nextDeadline ?? overview.deadlines.first, now: now)
        return VStack(alignment: .leading, spacing: 5) {
            Text(AccountTerms.deadlines + " · " + AccountTerms.deadlinesKickerRest)
                .font(.system(size: 12)).foregroundStyle(palette.tertiary)
            (Text(words.lead).foregroundStyle(palette.primary)
                + Text(words.rest.isEmpty ? "" : " " + words.rest).foregroundStyle(palette.tertiary).fontWeight(.semibold))
                .font(.system(size: 23, weight: .bold)).fixedSize(horizontal: false, vertical: true)
            Text(summary).font(.system(size: 13)).foregroundStyle(palette.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Agenda

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(days.enumerated()), id: \.element.day) { index, group in
                daySection(title: dayTitle(group.day), subtitle: group.day.formatted(.dateTime.month(.wide).day()),
                           first: index == 0) {
                    ForEach(group.events) { event in entry(event, later: false) }
                }
            }
            if !later.isEmpty {
                daySection(title: AccountTerms.later, subtitle: AccountTerms.afterThisWeek, first: days.isEmpty) {
                    ForEach(later) { event in entry(event, later: true) }
                }
            }
            if !undated.isEmpty {
                daySection(title: AccountTerms.datesUnknown, subtitle: nil, first: days.isEmpty && later.isEmpty) {
                    ForEach(undated) { account in undatedRow(account) }
                }
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(day, inSameDayAs: now) { return AccountTerms.today }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(day, inSameDayAs: tomorrow) { return AccountTerms.tomorrow }
        return day.formatted(.dateTime.weekday(.wide))
    }

    private func daySection<Content: View>(title: String, subtitle: String?, first: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            if !first { Rectangle().fill(palette.line).frame(height: 1) }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .bold))
                    if let subtitle { Text(subtitle).font(.system(size: 11.5)).foregroundStyle(palette.tertiary) }
                }
                .frame(width: 98, alignment: .leading).padding(.top, 6)
                .accessibilityElement(children: .combine).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 4) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, first ? 0 : 9).padding(.bottom, 7)
        }
    }

    @ViewBuilder
    private func entry(_ event: Event, later: Bool) -> some View {
        Button { openAccount(event.accountID) } label: {
            switch event.kind {
            case .banked(let deadline): bankedEntry(event, deadline, later: later)
            case .runOut(let horizon): runOutEntry(event, horizon)
            case .reset(let horizon): resetEntry(event, horizon)
            }
        }
        .buttonStyle(.plain)
    }

    /// Time column, glyph column, then the words; shared by every entry.
    private func row<Glyph: View, Words: View>(times: [(String, Color, Font)], @ViewBuilder glyph: () -> Glyph,
                                               @ViewBuilder words: () -> Words) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(times.enumerated()), id: \.offset) { _, time in
                    Text(time.0).font(time.2).foregroundStyle(time.1).monospacedDigit().lineLimit(1)
                }
            }
            .frame(width: 66, alignment: .leading)
            glyph().frame(width: 20, height: 17)
            VStack(alignment: .leading, spacing: 2) { words() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func title(_ event: Event, _ action: Text, prefix: String? = nil) -> Text {
        (prefix.map { Text($0 + " · ").fontWeight(.semibold).foregroundStyle(palette.primary) } ?? Text(""))
            + Text(event.provider.accountDisplayName + "  ").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.provider(event.provider))
            + action + Text(" · ").foregroundStyle(palette.tertiary)
            + Text(event.label).fontWeight(.semibold).foregroundStyle(palette.primary)
    }

    private func clock(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    private func bankedEntry(_ event: Event, _ deadline: AccountOverview.Deadline, later: Bool) -> some View {
        let account = account(deadline.accountID)
        let saved = deadline.state != .available
        let relation = AccountTerms.weekResetRelation(expiresAt: deadline.expiresAt, week: account?.longWindow,
                                                      current: account?.isReliable ?? false, now: now)
        let before = account.flatMap { overview.bankedBeforeRunOut($0, now: now) }?.id == deadline.id
            ? account?.horizon(now: now).runOutAt.map { AccountTerms.lapsesBeforeRunOut($0.timeIntervalSince(deadline.expiresAt)) } : nil
        let countdown = AccountPaceText.countdown(to: deadline.expiresAt, now: now)
        let label = account?.metadata.label ?? deadline.label
        let action = AccountTerms.bankedResetLapses + (saved ? " · " + AccountTerms.lastSeen : "")
        let date = later ? deadline.expiresAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) : nil
        var times: [(String, Color, Font)] = []
        times.append((clock(deadline.expiresAt), palette.secondary, .system(size: 12.5)))
        times.append((countdown, saved ? palette.stale : palette.banked, .system(size: 11, weight: .medium)))
        return row(times: times) {
            Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 9)).foregroundStyle(saved ? palette.stale : palette.banked)
        } words: {
            title(event, Text(action).fontWeight(.semibold).foregroundStyle(palette.primary), prefix: date)
                .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            if saved {
                Text(AccountTerms.lastSeen + " " + AccountPaceText.when(deadline.observedAt, now: now))
                    .font(.system(size: 11.5)).foregroundStyle(palette.stale)
            }
            if let relation {
                Text(relation).font(.system(size: 11.5)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let before {
                Text(before + ".").font(.system(size: 11.5, weight: .medium)).foregroundStyle(palette.banked)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(later ? Color.clear : palette.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(later ? Color.clear : palette.line, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([event.provider.accountDisplayName, action, label,
                             AccountPaceText.when(deadline.expiresAt, now: now), countdown,
                             saved ? AccountTerms.lastSeen + " " + AccountPaceText.when(deadline.observedAt, now: now) : nil,
                             relation, before].compactMap { $0 }.joined(separator: ", "))
    }

    private func runOutEntry(_ event: Event, _ horizon: AccountHorizon) -> some View {
        let outcome = account(event.accountID).map { AccountTerms.outcome($0, horizon, now: now) }
        let time = "~" + event.date.formatted(.dateTime.hour())
        return row(times: [(time, palette.secondary, .system(size: 12.5))]) {
            Circle().fill(palette.bad).frame(width: 9, height: 9)
        } words: {
            title(event, Text(AccountTerms.runsOutTitle).fontWeight(.semibold).foregroundStyle(palette.bad))
                .font(.system(size: 13.5)).fixedSize(horizontal: false, vertical: true)
            if let detail = outcome?.detail, !detail.isEmpty {
                Text(detail + ".").font(.system(size: 11.5)).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(palette.bad.opacity(colorScheme == .dark ? 0.12 : 0.08)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([event.provider.accountDisplayName, AccountTerms.runsOutTitle, event.label,
                             AccountPaceText.approximately(event.date, now: now), outcome?.detail].compactMap { $0 }.joined(separator: ", "))
    }

    private func resetEntry(_ event: Event, _ horizon: AccountHorizon) -> some View {
        let words: String = if horizon.runsOutBeforeReset { AccountTerms.backToFull }
            else if horizon.isCurrent, let spare = horizon.spare { AccountTerms.resetsUnused(spare) }
            else { AccountTerms.resets + (horizon.isCurrent ? "" : ", " + AccountTerms.lastSeen) }
        let hue = horizon.isCurrent ? palette.provider(event.provider) : palette.stale
        return row(times: [(clock(event.date), palette.secondary, .system(size: 12.5))]) {
            Circle().strokeBorder(hue, lineWidth: 2).frame(width: 10, height: 10)
        } words: {
            title(event, Text(words).foregroundStyle(palette.secondary))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([event.provider.accountDisplayName, words, event.label,
                             AccountPaceText.when(event.date, now: now)].joined(separator: ", "))
    }

    private func undatedRow(_ account: AccountOverview.Account) -> some View {
        let count = AccountTerms.undated(account.unknownExpiryCount ?? 0)
        return Button { openAccount(account.id) } label: {
            row(times: []) {
                Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 9)).foregroundStyle(palette.tertiary)
            } words: {
                (Text(account.metadata.provider.accountDisplayName + "  ").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.provider(account.metadata.provider))
                    + Text(account.metadata.label).fontWeight(.semibold)
                    + Text(" · " + count).foregroundStyle(palette.secondary))
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([account.metadata.provider.accountDisplayName, account.metadata.label, count].joined(separator: ", "))
    }

    // MARK: Glance

    private var glance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AccountTerms.thisWeekAtAGlance).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.secondary)
            ForEach(overview.accounts) { account in glanceLane(account) }
            legend.padding(.top, 2)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(palette.card))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.line, lineWidth: 1))
    }

    private func glanceLane(_ account: AccountOverview.Account) -> some View {
        let horizon = account.horizon(now: now)
        let deadlines = overview.deadlines.filter { $0.accountID == account.id }
        let room = account.longWindow.map { AccountNumbers.window($0) + " " + AccountTerms.left
            + (account.isReliable ? "" : ", " + AccountTerms.lastSeen) }
        return Button { openAccount(account.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(account.metadata.label).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(room ?? AccountTerms.unknown).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(account.isReliable ? palette.secondary : palette.stale).lineLimit(1)
                }
                DeadlineHorizonShape(geometry: horizon.geometry(now: now, deadlines: deadlines),
                                     hue: horizon.isCurrent ? account.metadata.provider.colorToken : .saved,
                                     current: horizon.isCurrent, palette: palette)
                    .frame(height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([account.metadata.provider.accountDisplayName, account.metadata.label,
                             account.longWindow.map { $0.shortLabel + " " + (room ?? "") },
                             AccountTerms.outcome(account, horizon, now: now).title].compactMap { $0 }.joined(separator: ", "))
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AccountTerms.deadlinesGlanceKey).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                DeadlineHatch(palette: palette).frame(width: 14, height: 9)
                Text(AccountTerms.horizonLegendEmpty)
            }
            HStack(spacing: 5) {
                Image(systemName: AccountGlyphs.bankedExpiry).font(.system(size: 7)).foregroundStyle(palette.banked).frame(width: 14)
                Text(AccountTerms.bankedLapsesLegend)
            }
        }
        .font(.system(size: 10.5)).foregroundStyle(palette.secondary)
        .accessibilityElement(children: .combine)
    }
}

/// A small swatch of the red hatch used for time spent empty.
private struct DeadlineHatch: View {
    let palette: DashboardPalette
    var body: some View {
        Canvas { context, size in
            DeadlineHorizonShape.hatch(in: CGRect(origin: .zero, size: size), context: &context, palette: palette, bar: false)
        }
        .accessibilityHidden(true)
    }
}

/// One account's week as a horizon: what is left draining at the observed burn, red hatch while
/// empty before the reset, the reset mark, then a faint refilled block; banked lapses as diamonds.
private struct DeadlineHorizonShape: View {
    let geometry: AccountHorizonGeometry
    let hue: AccountColorToken
    let current: Bool
    let palette: DashboardPalette

    static func hatch(in rect: CGRect, context: inout GraphicsContext, palette: DashboardPalette, bar: Bool) {
        guard rect.width > 0 else { return }
        let critical = palette.color(.critical)
        context.drawLayer { layer in
            layer.clip(to: Path(rect))
            var lines = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                lines.move(to: CGPoint(x: x, y: rect.maxY))
                lines.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += 5
            }
            layer.stroke(lines, with: .color(critical.opacity(0.3)), lineWidth: 2)
        }
        if bar {
            context.fill(Path(roundedRect: CGRect(x: rect.minX, y: rect.maxY - 2.5, width: rect.width, height: 2.5), cornerRadius: 1),
                         with: .color(critical))
        }
    }

    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            let color = palette.color(hue)
            let resetEnd = (geometry.resetX ?? 1) * width
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: resetEnd, height: height), cornerRadius: 3),
                         with: .color(palette.track))
            for day in geometry.dayXs {
                context.fill(Path(CGRect(x: day * width - 0.5, y: 0, width: 1, height: height)), with: .color(palette.line))
            }
            let startY = height * (1 - geometry.startLevel)
            let endX = geometry.fillEndX * width
            let endY = height * (1 - geometry.fillEndLevel)
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: height))
            fill.addLine(to: CGPoint(x: 0, y: startY))
            fill.addLine(to: CGPoint(x: endX, y: endY))
            fill.addLine(to: CGPoint(x: endX, y: height))
            fill.closeSubpath()
            if current {
                context.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.95), color.opacity(0.45)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
            } else {
                context.fill(fill, with: .color(color.opacity(0.55)))
            }
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: startY))
            edge.addLine(to: CGPoint(x: endX, y: endY))
            context.stroke(edge, with: .color(color), lineWidth: 1.5)
            if let empty = geometry.emptyRange {
                let rect = CGRect(x: empty.lowerBound * width, y: 0, width: (empty.upperBound - empty.lowerBound) * width, height: height)
                Self.hatch(in: rect, context: &context, palette: palette, bar: true)
            }
            if let resetX = geometry.resetX {
                let x = resetX * width
                if width - x > 0.5 {
                    context.fill(Path(roundedRect: CGRect(x: x, y: 1.5, width: width - x, height: height - 1.5), cornerRadius: 2),
                                 with: .color(color.opacity(0.13)))
                }
                context.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: height)), with: .color(palette.primary))
            }
            for lapse in geometry.banked {
                let center = CGPoint(x: lapse.x * width, y: min(height - 4.5, max(4.5, height * (1 - lapse.level))))
                var diamond = Path()
                diamond.move(to: CGPoint(x: center.x, y: center.y - 4))
                diamond.addLine(to: CGPoint(x: center.x + 4, y: center.y))
                diamond.addLine(to: CGPoint(x: center.x, y: center.y + 4))
                diamond.addLine(to: CGPoint(x: center.x - 4, y: center.y))
                diamond.closeSubpath()
                context.stroke(diamond, with: .color(palette.card), lineWidth: 2)
                context.fill(diamond, with: .color(palette.banked))
            }
        }
        .accessibilityHidden(true)
    }
}
