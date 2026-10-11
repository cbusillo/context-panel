import ContextPanelCore
import SwiftUI

// REQUEST: AccountTerms — "Saved for last", the quiet label for an account kept for last.

// Watch account rows and complication faces in the Horizon design: one sentence first, then one line
// per account with its weekly window as a small horizon draining toward the reset. Words, numbers and
// colours come from `AccountPresentation` and `AccountPace` in ContextPanelCore. Lives in WatchSupport
// so the watch targets and the macOS renderer compile the same views.

/// The compact headline: "2 run out before reset." in red when anything runs short, then the rest.
public struct WatchAccountHeadline: View {
    @ScaledMetric(relativeTo: .headline) private var textSize = 14.0
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        let headline = overview.headline(now: now)
        let text = AccountTerms.compactHeadline(headline)
        (Text(text.lead).foregroundColor(WatchTokens.color(headline.shortCount > 0 ? AccountAlarm.token : .primary))
            + Text(text.rest.isEmpty ? "" : " " + text.rest).foregroundColor(WatchTokens.color(.secondary)))
            .font(.system(size: textSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel([text.lead, text.rest].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

public struct WatchAccountRow: View {
    @ScaledMetric(relativeTo: .headline) private var nameSize = 14.0
    @ScaledMetric(relativeTo: .title2) private var quantitySize = 22.0
    @ScaledMetric(relativeTo: .caption) private var detailSize = 11.0
    let account: AccountOverview.Account
    let isNext: Bool
    let now: Date
    let deadlines: [AccountOverview.Deadline]

    public init(account: AccountOverview.Account, isNext: Bool, now: Date, deadlines: [AccountOverview.Deadline] = []) {
        self.account = account
        self.isNext = isNext
        self.now = now
        self.deadlines = deadlines
    }

    public var body: some View {
        let horizon = account.horizon(now: now)
        let provider = account.metadata.provider
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(provider.accountDisplayName).foregroundStyle(WatchTokens.color(provider.colorToken))
                Spacer(minLength: 2)
                if isNext && horizon.isCurrent {
                    Text(AccountTerms.useNext).foregroundStyle(WatchTokens.color(provider.colorToken))
                } else if account.metadata.useLast {
                    Text(AccountTerms.useLast).foregroundStyle(WatchTokens.color(.secondary))
                }
            }
            .font(.system(size: detailSize, weight: .semibold))
            .fixedSize(horizontal: false, vertical: true)
            Text(account.metadata.label).font(.system(size: nameSize, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    quantity(horizon)
                    Text(AccountTerms.horizonLeft(horizon.window))
                        .font(.system(size: detailSize)).foregroundStyle(WatchTokens.color(.secondary))
                        .fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 1) {
                    quantity(horizon)
                    Text(AccountTerms.horizonLeft(horizon.window))
                        .font(.system(size: detailSize)).foregroundStyle(WatchTokens.color(.secondary))
                }
            }
            WatchHorizon(geometry: horizon.remaining == nil ? nil : horizon.geometry(now: now, deadlines: accountDeadlines),
                         token: horizon.isCurrent ? provider.colorToken : .saved)
                .frame(height: 14)
            Text(outcome(horizon)).foregroundStyle(WatchTokens.color(AccountAlarm.outcomeToken(account, horizon)))
                .font(.system(size: detailSize)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if let short = account.shortWindow, account.longWindow != short {
                Text(AccountTerms.fiveHour + " " + AccountNumbers.window(short) + " " + AccountTerms.left)
                    .font(.system(size: detailSize)).monospacedDigit()
                    .foregroundStyle(WatchTokens.color(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if horizon.isCurrent, let reset = horizon.window.flatMap({ AccountTerms.reset($0, now: now) }) {
                Text(AccountTerms.resets + " " + reset).font(.system(size: detailSize)).monospacedDigit()
                    .foregroundStyle(WatchTokens.color(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WatchAccountText.accessibility(account, now: now, isNext: isNext))
    }

    private func quantity(_ horizon: AccountHorizon) -> some View {
        Text(weekPercent(horizon))
            .font(.system(size: quantitySize, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(WatchTokens.color(horizon.isCurrent ? .primary : .saved))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var accountDeadlines: [AccountOverview.Deadline] {
        deadlines.filter { $0.accountID == account.id && $0.state == .available }
    }

    private func outcome(_ horizon: AccountHorizon) -> String {
        horizon.isCurrent ? AccountTerms.outcomeShort(account, horizon, now: now)
            : [.stale, .unavailable].contains(account.state) ? savedText(account, now: now)
            : WatchAccountText.state(account, horizon: horizon)
    }

}

/// The next banked expiry, kept as one line in the watch list.
public struct WatchBankedLine: View {
    @ScaledMetric(relativeTo: .headline) private var timeSize = 14.0
    @ScaledMetric(relativeTo: .caption) private var detailSize = 11.0
    let deadline: AccountOverview.Deadline
    let now: Date

    public init(deadline: AccountOverview.Deadline, now: Date) {
        self.deadline = deadline
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                WatchDiamond().fill(WatchTokens.color(.banked)).frame(width: 9, height: 9)
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: timeSize))
            .fixedSize(horizontal: false, vertical: true)
            Text(AccountTerms.bankedResetExpires + " · " + deadline.label)
                .font(.system(size: detailSize)).foregroundStyle(WatchTokens.color(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(AccountTerms.bankedResetExpires) for \(deadline.label), \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
    }
}

/// Rectangular complication: the sentence's lead, then the account that runs out first or, when
/// nothing does, the account to use next, with its horizon and outcome.
public struct WatchAccountRectangularFace: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        if let presentation = WatchAccountComplicationPresentation(overview: overview, now: now) {
            let account = presentation.account
            let horizon = presentation.horizon
            let headline = overview.headline(now: now)
            let provider = account.metadata.provider
            VStack(alignment: .leading, spacing: 2) {
                Text(AccountTerms.compactHeadline(headline).lead)
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    .foregroundStyle(WatchTokens.color(headline.shortCount > 0 ? AccountAlarm.token : .primary))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(provider.accountDisplayName).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WatchTokens.color(provider.colorToken))
                    Text(account.metadata.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(presentation.quantity + " " + AccountTerms.left).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                        .layoutPriority(1)
                }
                WatchHorizon(geometry: horizon.remaining == nil ? nil : horizon.geometry(now: now), token: presentation.colorToken)
                    .frame(height: 6)
                Text(footer(account, horizon)).font(.system(size: 11)).monospacedDigit().lineLimit(1)
                    .foregroundStyle(WatchTokens.color(AccountAlarm.outcomeToken(account, horizon)))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccountTerms.compactHeadline(headline).lead + " "
                + presentation.accessibilityText)
        } else {
            Text(AccountTerms.addFirstAccount).font(.system(size: 12))
        }
    }

    private func footer(_ account: AccountOverview.Account, _ horizon: AccountHorizon) -> String {
        if !horizon.isCurrent {
            return [.stale, .unavailable].contains(account.state) ? savedText(account, now: now)
                : WatchAccountText.state(account, horizon: horizon)
        }
        let outcome = AccountTerms.outcomeShort(account, horizon, now: now)
        guard !horizon.runsOutBeforeReset, let deadline = overview.nextDeadline else { return outcome }
        return outcome + " · ◆ " + AccountPaceText.when(deadline.expiresAt, now: now)
    }
}

/// Circular complication: the focus account's weekly share left as a ring in its provider's hue,
/// with a red segment only when it runs out before its reset.
public struct WatchAccountCircularFace: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        let presentation = WatchAccountComplicationPresentation(overview: overview, now: now)
        let horizon = presentation?.horizon
        let token = presentation?.colorToken ?? .tertiary
        let numeral = AccountNumbers.percent(horizon?.remaining)
        let qualifier = presentation?.circularQuantity.replacingOccurrences(of: numeral, with: "") ?? ""
        GeometryReader { proxy in
            ZStack {
                Circle().stroke(WatchTokens.color(.track), style: StrokeStyle(lineWidth: 5,
                    dash: horizon?.remaining == nil ? [2, 3] : []))
                if let horizon, let fraction = horizon.remaining {
                    Circle().trim(from: 0, to: fraction)
                        .stroke(WatchTokens.color(token), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    if horizon.runsOutBeforeReset {
                        // A short red mark past what is left: it runs dry before the reset refills it.
                        let start = min(0.9, fraction + 0.05)
                        Circle().trim(from: start, to: start + 0.08)
                            .stroke(WatchTokens.color(.critical), style: StrokeStyle(lineWidth: 5, lineCap: .butt))
                            .rotationEffect(.degrees(-90))
                    }
                }
                Text(numeral)
                    .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(width: proxy.size.width * 0.68)
                    .foregroundStyle(WatchTokens.color(.primary))
                if !qualifier.isEmpty {
                    Text(qualifier).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WatchTokens.color(token))
                        .offset(y: -proxy.size.height * 0.26)
                        .accessibilityHidden(true)
                }
                if let symbol = presentation?.stateSymbol {
                    Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(WatchTokens.color(token))
                        .offset(y: proxy.size.height * 0.28)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .padding(3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation?.accessibilityText ?? AccountTerms.addFirstAccount)
    }
}

/// The weekly window's share left, the number every Horizon surface leads with.
private func weekPercent(_ horizon: AccountHorizon) -> String {
    horizon.window.map { AccountNumbers.window($0) } ?? AccountTerms.unknown
}

/// The horizon at watch size: what is left draining toward the reset, the empty gap as a solid red
/// segment, a reset mark, banked lapses, and a faint full block after the reset. No day lines or hatching.
struct WatchHorizon: View {
    let geometry: AccountHorizonGeometry?
    let token: AccountColorToken

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let resetX = geometry?.resetX ?? 1
            ZStack(alignment: .topLeading) {
                Rectangle().fill(WatchTokens.color(.track)).frame(width: width * resetX)
                if let geometry {
                    if resetX < 1 {
                        Rectangle().fill(WatchTokens.color(token).opacity(0.13))
                            .frame(width: width * (1 - resetX)).offset(x: width * resetX)
                    }
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: height))
                        path.addLine(to: CGPoint(x: 0, y: height * (1 - geometry.startLevel)))
                        path.addLine(to: CGPoint(x: geometry.fillEndX * width, y: height * (1 - geometry.fillEndLevel)))
                        path.addLine(to: CGPoint(x: geometry.fillEndX * width, y: height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [WatchTokens.color(token).opacity(0.95), WatchTokens.color(token).opacity(0.55)],
                                         startPoint: .top, endPoint: .bottom))
                    if let empty = geometry.emptyRange {
                        let emptyWidth = max(2, width * (empty.upperBound - empty.lowerBound))
                        Rectangle().fill(WatchTokens.color(.critical).opacity(0.4))
                            .frame(width: emptyWidth).offset(x: width * empty.lowerBound)
                        Rectangle().fill(WatchTokens.color(.critical))
                            .frame(width: emptyWidth, height: 2).offset(x: width * empty.lowerBound, y: height - 2)
                    }
                    if let reset = geometry.resetX {
                        Rectangle().fill(WatchTokens.color(.primary)).frame(width: 1)
                            .offset(x: min(width - 1, max(0, width * reset - 0.5)))
                    }
                    ForEach(Array(geometry.banked.enumerated()), id: \.offset) { _, mark in
                        WatchDiamond().fill(WatchTokens.color(.banked)).frame(width: 6, height: 6)
                            .offset(x: min(width - 6, max(0, width * mark.x - 3)),
                                    y: min(height - 6, max(0, height * (1 - mark.level) - 3)))
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// The banked-reset mark used across Horizon surfaces.
struct WatchDiamond: Shape {
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

/// "Saved 6:04 PM" for saved values, otherwise the state word.
func savedText(_ account: AccountOverview.Account, now: Date) -> String {
    guard [.stale, .unavailable].contains(account.state), !account.windows.isEmpty, let observed = account.observedAt else {
        return account.stateText
    }
    return account.stateText + " " + AccountPaceText.when(observed, now: now)
}

/// The watch is always dark.
enum WatchTokens {
    static func color(_ token: AccountColorToken) -> Color {
        let value = token.rgb(dark: true)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: true))
    }
}
