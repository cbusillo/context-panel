import ContextPanelCore
import SwiftUI
import WidgetKit

/// Account widgets in the Horizon design: one plain sentence first, a "use next" account per provider,
/// and each account's weekly window as one shape draining toward its reset. Hatched red is the only red.
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

    var body: some View {
        let overview = overview
        Group {
            if overview.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AccountTerms.widgetTitle).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    Text(snapshot.accountDisplayMetadata?.isEmpty == false ? "No accounts shown" : AccountTerms.addFirstAccount)
                        .font(.system(size: 14, weight: .semibold))
                    Text("Open Context Panel to set up accounts.").font(.system(size: 11)).foregroundStyle(palette.secondary)
                }
            } else {
                switch family {
                case .systemSmall:
                    small(overview)
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

    // MARK: Shared pieces

    /// Each provider with accounts, and its account to use next (nil when none is eligible).
    private func picks(_ overview: AccountOverview) -> [(provider: Provider, account: AccountOverview.Account?)] {
        Provider.allCases.compactMap { provider in
            overview.accounts.contains { $0.metadata.provider == provider } ? (provider, overview.useNext(provider: provider)) : nil
        }
    }

    /// Week percent from the window the horizon follows, keeping "≈" for assumed capacity.
    private func weekPercent(_ horizon: AccountHorizon, account: AccountOverview.Account) -> String {
        horizon.window.map { AccountNumbers.window($0) } ?? AccountNumbers.account(account)
    }

    private func horizonView(_ account: AccountOverview.Account, _ horizon: AccountHorizon, in overview: AccountOverview) -> some View {
        let deadlines = showsBanked ? overview.deadlines.filter { $0.accountID == account.id && $0.state == .available } : []
        return HorizonShape(geometry: horizon.remaining == nil ? nil : horizon.geometry(now: now, deadlines: deadlines),
                            hue: horizon.isCurrent ? palette.provider(account.metadata.provider) : palette.stale,
                            palette: palette)
    }

    /// Calm outcome words: the headline's lead is a widget's one alarm (`AccountAlarm`).
    private func outcomeColor(_ account: AccountOverview.Account, _ horizon: AccountHorizon) -> Color {
        palette.color(AccountAlarm.outcomeToken(account, horizon))
    }

    private func headline(_ overview: AccountOverview) -> (lead: String, rest: String, short: Bool) {
        let headline = overview.headline(now: now)
        let words = AccountTerms.compactHeadline(headline)
        return (words.lead, words.rest, headline.shortCount > 0)
    }

    private func header(trailing: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(AccountTerms.widgetTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let trailing {
                Text(trailing).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .foregroundStyle(palette.secondary).lineLimit(1)
            }
        }
    }

    private var nextUpWord: String { AccountTerms.useNext.lowercased() }

    // MARK: Small

    /// One row per provider: its name in its hue, the account to use next and its week left; the
    /// headline's lead at the bottom, red only when something runs out before its reset.
    private func small(_ overview: AccountOverview) -> some View {
        let picks = picks(overview).filter { $0.account != nil }
        let headline = headline(overview)
        let roomy = picks.count <= 2
        return VStack(alignment: .leading, spacing: 0) {
            header(trailing: picks.isEmpty ? nil : nextUpWord).padding(.bottom, 2)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if headline.short {
                    Circle().fill(palette.bad).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                }
                Text(headline.lead)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(headline.short ? palette.bad : palette.primary)
                    .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .padding(.bottom, 5)
            .accessibilityLabel([headline.lead, headline.rest].filter { !$0.isEmpty }.joined(separator: " "))
            if picks.isEmpty {
                Text(AccountTerms.noEligibleAccount).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: roomy ? 8 : 4) {
                ForEach(picks, id: \.provider) { pick in
                    if let account = pick.account { smallRow(account, roomy: roomy, overview: overview) }
                }
            }
            Spacer(minLength: 2)
            if showsBanked, let deadline = overview.nextDeadline {
                // The next banked expiry, as before Horizon: "Fri 2:27 PM in 1d 0h".
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    BankedDiamond(palette: palette, size: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                    Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold)
                    Text(AccountPaceText.countdown(to: deadline.expiresAt, now: now)).foregroundStyle(palette.secondary)
                }
                .font(.system(size: AccountTextSize.glanceMinimum)).monospacedDigit().lineLimit(1).padding(.bottom, 2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Banked reset for \(deadline.label) expires \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
            }
        }
    }

    private func smallRow(_ account: AccountOverview.Account, roomy: Bool, overview: AccountOverview) -> some View {
        let horizon = account.horizon(now: now)
        let provider = account.metadata.provider
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(provider.accountDisplayName).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.provider(provider)).lineLimit(1)
                Spacer(minLength: 2)
                Text(weekPercent(horizon, account: account)).font(.system(size: 12, weight: .bold)).monospacedDigit()
            }
            Text(account.metadata.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if roomy {
                horizonView(account, horizon, in: overview).frame(height: 9).padding(.top, 2)
                Text(AccountTerms.outcomeShort(account, horizon, now: now))
                    .font(.system(size: AccountTextSize.glanceMinimum))
                    .foregroundStyle(outcomeColor(account, horizon)).lineLimit(1)
            }
        }
        .padding(.leading, 6)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(palette.provider(provider)).frame(width: 2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: true))
    }

    // MARK: Medium

    /// A calm "use next" card per provider, tinted with its hue: name, the account, its week left, its horizon and
    /// that account's own outcome; when other accounts of the provider run out, a calm "1 other runs out" under it.
    private func medium(_ overview: AccountOverview) -> some View {
        let picks = picks(overview)
        let totals = overview.providerTotals(now: now)
        return VStack(alignment: .leading, spacing: 6) {
            let headline = headline(overview)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(AccountTerms.widgetTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                (Text(headline.lead).foregroundStyle(headline.short ? palette.bad : palette.primary)
                 + Text(headline.rest.isEmpty ? "" : " " + headline.rest).foregroundStyle(palette.secondary))
                    .font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([AccountTerms.widgetTitle, headline.lead, headline.rest].filter { !$0.isEmpty }.joined(separator: " "))
            HStack(alignment: .top, spacing: 6) {
                ForEach(picks, id: \.provider) { pick in
                    let card = mediumCard(pick.provider, account: pick.account,
                                          total: totals.first { $0.provider == pick.provider }, overview: overview)
                    CPWNavigationLink(destination: pick.account.map { links.account(pick.provider, id: $0.id) } ?? links.overview) { card }
                        .buttonStyle(.plain)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func mediumCard(_ provider: Provider, account: AccountOverview.Account?, total: AccountProviderTotal?,
                            overview: AccountOverview) -> some View {
        let horizon = account?.horizon(now: now)
        // The shown account's own outcome; the provider's other run-outs are said apart from it, so a card
        // never reads as its account being in trouble. The header's lead is the widget's one alarm.
        let own: String? = if let account, let horizon {
            horizon.isCurrent ? AccountTerms.outcomeShort(account, horizon, now: now) : account.stateText
        } else {
            total.map { AccountTerms.providerSummary($0, now: now).outlook }
        }
        // Only beside a shown account: with none, the provider outlook above already says it.
        let others = account == nil ? nil : total.flatMap { AccountTerms.othersRunOut($0, shownRunsOut: horizon?.runsOutBeforeReset == true) }
        return VStack(alignment: .leading, spacing: 0) {
            Text(provider.accountDisplayName).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(palette.provider(provider)).lineLimit(1)
            if let account, let horizon {
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 1)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(weekPercent(horizon, account: account)).font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Text(AccountTerms.left).font(.system(size: 10, weight: .medium)).foregroundStyle(palette.secondary)
                }
                horizonView(account, horizon, in: overview).frame(height: 10).padding(.top, 2)
            } else {
                Text(AccountTerms.noEligibleAccount).font(.system(size: 10)).foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 2)
            }
            if let own {
                Text(own).font(.system(size: AccountTextSize.glanceMinimum, weight: .medium))
                    .foregroundStyle(account.map { outcomeColor($0, horizon ?? $0.horizon(now: now)) } ?? palette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.9).padding(.top, 3)
            }
            if let others {
                Text(others).font(.system(size: AccountTextSize.glanceMinimum)).foregroundStyle(palette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.9)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7).padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(palette.color(provider.surfaceToken)))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([account.map { $0.glanceAccessibilityText(now: now, isNext: true) }
                                ?? provider.accountDisplayName + ", " + AccountTerms.noEligibleAccount,
                             total.map { $0.accessibilityText(now: now) }].compactMap { $0 }.joined(separator: ". "))
        .accessibilityHint(account == nil ? "Opens Context Panel" : "Opens this account")
    }

    // MARK: Large

    private func large(_ overview: AccountOverview) -> some View {
        let rows = Array(overview.accounts.prefix(6))
        let totals = overview.providerTotals(now: now)
        let headline = headline(overview)
        return VStack(alignment: .leading, spacing: 0) {
            header(trailing: AccountPaceText.when(now, now: now)
                + (overview.accounts.count > rows.count ? " · +\(overview.accounts.count - rows.count)" : ""))
                .padding(.bottom, 3)
            (Text(headline.lead).foregroundStyle(headline.short ? palette.bad : palette.primary)
                + Text(headline.rest.isEmpty ? "" : " " + headline.rest).foregroundStyle(palette.secondary))
                .font(.system(size: 13.5, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.85)
                .padding(.bottom, 5)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(totals) { total in
                    let members = rows.filter { $0.metadata.provider == total.provider }
                    if !members.isEmpty { largeGroup(total, members: members, overview: overview) }
                }
            }
            Spacer(minLength: 3)
            if showsBanked { largeCallout(overview) }
        }
    }

    private func largeGroup(_ total: AccountProviderTotal, members: [AccountOverview.Account], overview: AccountOverview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(total.provider.accountDisplayName).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(palette.provider(total.provider))
                Spacer(minLength: 2)
                Text(groupFacts(total)).font(.system(size: AccountTextSize.glanceMinimum)).foregroundStyle(palette.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(total.accessibilityText(now: now))
            ForEach(members) { account in
                CPWNavigationLink(destination: links.account(account.metadata.provider, id: account.id)) {
                    largeRow(account, overview: overview)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.provider(total.provider).opacity(palette.dark ? 0.10 : 0.07)))
    }

    /// "3 accounts · 59% left on average"; burn and pace are carried by the shapes instead.
    private func groupFacts(_ total: AccountProviderTotal) -> String {
        var facts = [AccountTerms.accountCount(total)]
        if total.isCombined, let long = total.longRemaining {
            facts.append(AccountNumbers.percentWithSign(long) + " " + AccountTerms.leftOnAverage)
        }
        return facts.joined(separator: " · ")
    }

    private func largeRow(_ account: AccountOverview.Account, overview: AccountOverview) -> some View {
        let horizon = account.horizon(now: now)
        let provider = account.metadata.provider
        let next = overview.useNext(provider: provider)?.id == account.id
        return HStack(alignment: .center, spacing: 5) {
            VStack(alignment: .leading, spacing: 0) {
                Text(account.metadata.label).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                // "next" (or a quiet "use last") leads the second line so the name keeps the first line.
                ViewThatFits(in: .horizontal) {
                    secondaryLine(account, horizon: horizon, next: next, withRefill: true)
                    secondaryLine(account, horizon: horizon, next: next, withRefill: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(weekPercent(horizon, account: account)).font(.system(size: 11.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(horizon.isCurrent ? palette.primary : palette.secondary)
                .lineLimit(1).frame(width: 30, alignment: .trailing)
            horizonView(account, horizon, in: overview).frame(width: 50, height: 13)
            VStack(alignment: .trailing, spacing: 0) {
                Text(AccountTerms.outcomeShort(account, horizon, now: now))
                    .font(.system(size: AccountTextSize.glanceMinimum, weight: .medium))
                    .foregroundStyle(outcomeColor(account, horizon))
                if horizon.isCurrent, let reset = horizon.window.flatMap({ AccountTerms.reset($0, now: now) }) {
                    ViewThatFits(in: .horizontal) {
                        Text(AccountTerms.resets + " " + reset)
                        Text(reset)
                    }
                    .font(.system(size: AccountTextSize.glanceMinimum)).foregroundStyle(palette.secondary)
                }
            }
            .monospacedDigit().lineLimit(1).frame(width: 93, alignment: .trailing)
        }
        .padding(.vertical, 1.5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: next))
        .accessibilityHint("Opens this account")
    }

    /// Under the name: "next" or "use last", then the 5-hour window's room and refill for current
    /// readings, or the saved time for readings that are not current.
    private func secondaryLine(_ account: AccountOverview.Account, horizon: AccountHorizon, next: Bool, withRefill: Bool) -> some View {
        var facts: [String] = []
        if !horizon.isCurrent {
            facts.append(AccountTerms.accountTiming(account, now: now))
        } else if let short = account.shortWindow, short.remainingFraction != nil {
            facts.append(AccountTerms.fiveHour + " " + AccountNumbers.window(short))
            if withRefill { facts.append(AccountTerms.refill(short, now: now)) }
        }
        let tag: Text? = next
            ? Text(AccountTerms.next.lowercased()).fontWeight(.semibold).foregroundStyle(palette.provider(account.metadata.provider))
            : account.metadata.useLast ? Text(AccountTerms.useLast.lowercased()).foregroundStyle(palette.secondary) : nil
        let rest = Text((tag == nil || facts.isEmpty ? "" : " · ") + facts.joined(separator: " · ")).foregroundStyle(palette.secondary)
        return (tag.map { $0 + rest } ?? rest)
            .font(.system(size: AccountTextSize.glanceMinimum)).monospacedDigit().lineLimit(1).fixedSize()
    }

    /// The single callout: a banked reset that lapses before its account runs out; else the next banked expiry.
    @ViewBuilder
    private func largeCallout(_ overview: AccountOverview) -> some View {
        let lapsing = overview.runningShort(now: now).lazy.compactMap { overview.bankedBeforeRunOut($0.account, now: now) }.first
        if let deadline = lapsing ?? overview.nextDeadline {
            let others = overview.deadlines.filter { $0.state == .available }.count - 1
            CPWNavigationLink(destination: links.deadlines) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    BankedDiamond(palette: palette, size: 6.5).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    // Lead with the expiry so a long account name cannot hide its time.
                    (Text(lapsing != nil ? AccountTerms.bankedBeforeRunOut(deadline, now: now)
                            : AccountTerms.bankedResetExpires + " " + AccountPaceText.when(deadline.expiresAt, now: now))
                            .foregroundStyle(palette.primary)
                        + Text(" · " + deadline.label).foregroundStyle(palette.secondary))
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if others > 0 {
                        Text(AccountTerms.additionalBankedExpiries(others, compact: true))
                            .foregroundStyle(palette.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 94, alignment: .trailing)
                    }
                }
                .font(.system(size: AccountTextSize.glanceMinimum))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Banked reset for \(deadline.label) expires \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))"
                + (lapsing != nil ? ", before it runs out" : "")
                + (others > 0 ? ", " + AccountTerms.additionalBankedExpiries(others) : ""))
        }
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
    var bad: Color { color(.critical) }
    var stale: Color { color(.saved) }
    var banked: Color { color(.banked) }

    func provider(_ provider: Provider) -> Color { color(provider.colorToken) }
}

/// One account's weekly window across the next seven days: what is left draining at the observed burn,
/// hatched red if it empties before the reset, the reset mark, then full again. Drawn from
/// `AccountHorizonGeometry`; nil geometry (no reading) draws only the track.
struct HorizonShape: View {
    let geometry: AccountHorizonGeometry?
    let hue: Color
    let palette: GlancePalette

    var body: some View {
        Canvas { context, size in
            let width = size.width, height = size.height
            func x(_ fraction: Double) -> CGFloat { CGFloat(fraction) * width }
            func y(_ level: Double) -> CGFloat { height * CGFloat(1 - min(1, max(0, level))) }
            let resetX = geometry?.resetX ?? 1
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2.5))
            context.fill(Path(CGRect(x: 0, y: 0, width: x(resetX), height: height)), with: .color(palette.track))
            guard let geometry else { return }
            for day in geometry.dayXs where day < resetX {
                context.fill(Path(CGRect(x: x(day) - 0.25, y: 0, width: 0.5, height: height)), with: .color(palette.line))
            }
            if let reset = geometry.resetX, reset < 1 {
                context.fill(Path(CGRect(x: x(reset), y: 0, width: width - x(reset), height: height)), with: .color(hue.opacity(0.13)))
            }
            var fill = Path()
            fill.move(to: CGPoint(x: 0, y: height))
            fill.addLine(to: CGPoint(x: 0, y: y(geometry.startLevel)))
            fill.addLine(to: CGPoint(x: x(geometry.fillEndX), y: y(geometry.fillEndLevel)))
            fill.addLine(to: CGPoint(x: x(geometry.fillEndX), y: height))
            fill.closeSubpath()
            context.fill(fill, with: .linearGradient(Gradient(colors: [hue.opacity(0.95), hue.opacity(0.45)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: height)))
            var edge = Path()
            edge.move(to: CGPoint(x: 0, y: y(geometry.startLevel)))
            edge.addLine(to: CGPoint(x: x(geometry.fillEndX), y: y(geometry.fillEndLevel)))
            context.stroke(edge, with: .color(hue), lineWidth: 1.5)
            if let empty = geometry.emptyRange, empty.upperBound > empty.lowerBound {
                let band = CGRect(x: x(empty.lowerBound), y: 0, width: x(empty.upperBound) - x(empty.lowerBound), height: height)
                context.drawLayer { layer in
                    layer.clip(to: Path(band))
                    var stripes = Path()
                    var start = band.minX - height
                    while start < band.maxX {
                        stripes.move(to: CGPoint(x: start, y: height))
                        stripes.addLine(to: CGPoint(x: start + height, y: 0))
                        start += 5
                    }
                    layer.stroke(stripes, with: .color(palette.bad.opacity(0.3)), lineWidth: 2)
                }
                context.fill(Path(CGRect(x: band.minX, y: height - 2.5, width: band.width, height: 2.5)), with: .color(palette.bad))
            }
            if let reset = geometry.resetX {
                context.fill(Path(CGRect(x: min(width - 1.5, x(reset) - 0.75), y: 0, width: 1.5, height: height)),
                             with: .color(palette.primary))
            }
            let side = min(7, height * 0.62)
            for lapse in geometry.banked {
                let center = CGPoint(x: min(width - side / 2, max(side / 2, x(lapse.x))),
                                     y: min(height - side / 2, max(side / 2, y(lapse.level))))
                var diamond = Path()
                diamond.move(to: CGPoint(x: center.x, y: center.y - side / 2))
                diamond.addLine(to: CGPoint(x: center.x + side / 2, y: center.y))
                diamond.addLine(to: CGPoint(x: center.x, y: center.y + side / 2))
                diamond.addLine(to: CGPoint(x: center.x - side / 2, y: center.y))
                diamond.closeSubpath()
                context.stroke(diamond, with: .color(palette.card), lineWidth: 1.5)
                context.fill(diamond, with: .color(palette.banked))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The banked-reset mark beside the callout, matching the diamonds on the shapes.
struct BankedDiamond: View {
    let palette: GlancePalette
    let size: CGFloat

    var body: some View {
        Rectangle().fill(palette.banked).frame(width: size, height: size).rotationEffect(.degrees(45))
            .frame(width: size * 1.42, height: size * 1.42).accessibilityHidden(true)
    }
}
