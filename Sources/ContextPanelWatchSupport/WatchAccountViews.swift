import ContextPanelCore
import SwiftUI

/// Watch account rows and complication faces, in the shared account design. Words, numbers,
/// colours and status marks come from `AccountPresentation` in ContextPanelCore.
/// Lives in WatchSupport so the watch targets and the macOS renderer compile the same views.
public struct WatchAccountRow: View {
    let account: AccountOverview.Account
    let isNext: Bool
    let now: Date

    public init(account: AccountOverview.Account, isNext: Bool, now: Date) {
        self.account = account
        self.isNext = isNext
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: account.state.glyphName).font(.system(size: 9, weight: .bold))
                    .foregroundStyle(WatchTokens.color(account.state.colorToken))
                Text(account.metadata.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if isNext {
                    Image(systemName: AccountGlyphs.useNext).font(.system(size: 10)).foregroundStyle(WatchTokens.color(.next))
                }
                Spacer(minLength: 2)
                Text(AccountNumbers.account(account))
                    .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(WatchTokens.color(AccountTone.forAccount(account).textToken))
            }
            HStack(spacing: 6) {
                ForEach([account.shortWindow, account.longWindow].compactMap { $0 }) { window in
                    WatchMeter(window: window, now: now)
                }
            }
            Group {
                if let runOut = account.earliestRunOut(now: now) {
                    Text(AccountTerms.runOut(runOut.date, now: now)).foregroundStyle(WatchTokens.color(.critical))
                } else if account.state.needsWord {
                    Text(savedText(account)).foregroundStyle(WatchTokens.color(account.state.colorToken))
                } else if let window = account.limitingWindow, let reset = AccountTerms.reset(window, now: now) {
                    Text(AccountTerms.resets + " " + reset).foregroundStyle(WatchTokens.color(.secondary))
                }
            }
            .font(.system(size: 12)).monospacedDigit().lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: isNext))
    }
}

/// The next banked expiry, as the watch list's first line.
public struct WatchBankedLine: View {
    let deadline: AccountOverview.Deadline
    let now: Date

    public init(deadline: AccountOverview.Deadline, now: Date) {
        self.deadline = deadline
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: AccountGlyphs.banked).foregroundStyle(WatchTokens.color(.banked))
                Text(AccountPaceText.when(deadline.expiresAt, now: now)).fontWeight(.semibold).monospacedDigit()
            }
            .font(.system(size: 14))
            Text(AccountTerms.bankedResetExpires + " · " + deadline.label)
                .font(.system(size: 11)).foregroundStyle(WatchTokens.color(.secondary)).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(AccountTerms.bankedResetExpires) for \(deadline.label), \(ContextPanelDateFormatting.accountReset(deadline.expiresAt))")
    }
}

/// Rectangular complication: the tightest account, both windows, and the next deadline.
public struct WatchAccountRectangularFace: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        if let account = overview.closest ?? overview.accounts.first {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Image(systemName: account.state.glyphName).font(.system(size: 8, weight: .bold))
                    Text(account.metadata.label).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(AccountNumbers.account(account))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                HStack(spacing: 4) {
                    ForEach([account.shortWindow, account.longWindow].compactMap { $0 }) { window in
                        WatchMeter(window: window, now: now, showsLabel: false)
                    }
                }
                Text(footer(account)).font(.system(size: 11)).monospacedDigit().lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(account.glanceAccessibilityText(now: now, isNext: false))
        } else {
            Text(AccountTerms.addFirstAccount).font(.system(size: 12))
        }
    }

    private func footer(_ account: AccountOverview.Account) -> String {
        if let runOut = account.earliestRunOut(now: now) { return AccountTerms.runOut(runOut.date, now: now) }
        if account.state.needsWord { return savedText(account) }
        if let deadline = overview.nextDeadline { return "◆ " + AccountPaceText.when(deadline.expiresAt, now: now) }
        return account.limitingWindow.flatMap { AccountTerms.reset($0, now: now) }.map { AccountTerms.resets + " " + $0 } ?? ""
    }
}

/// Circular complication: the tightest account's percent left on its ring.
public struct WatchAccountCircularFace: View {
    let overview: AccountOverview

    public init(overview: AccountOverview) { self.overview = overview }

    public var body: some View {
        let account = overview.closest ?? overview.accounts.first
        ZStack {
            Circle().stroke(WatchTokens.color(.track), lineWidth: 5)
            if let fraction = account?.remainingFraction {
                Circle().trim(from: 0, to: max(0.01, fraction))
                    .stroke(account.map { WatchTokens.color(AccountTone.forAccount($0).fillToken) } ?? .gray,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(AccountNumbers.percent(account?.remainingFraction))
                .font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .padding(3)
        .accessibilityLabel(account.map { $0.glanceAccessibilityText(now: Date(), isNext: false) } ?? AccountTerms.addFirstAccount)
    }
}

struct WatchMeter: View {
    let window: AccountOverview.Window
    let now: Date
    var showsLabel = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if showsLabel {
                HStack(spacing: 2) {
                    Text(window.shortLabel).foregroundStyle(WatchTokens.color(.secondary))
                    Text(AccountNumbers.window(window, sign: false))
                        .foregroundStyle(WatchTokens.color(AccountTone.forRemaining(window.remainingFraction).textToken))
                }
                .font(.system(size: 10, weight: .medium)).monospacedDigit()
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(WatchTokens.color(.track))
                    Capsule().fill(WatchTokens.color(AccountTone.forRemaining(window.remainingFraction).fillToken))
                        .frame(width: max(3, width * (window.remainingFraction ?? 0)))
                    if let even = window.evenPaceRemaining(now: now) {
                        Rectangle().fill(WatchTokens.color(.primary).opacity(0.8)).frame(width: 1.5)
                            .offset(x: min(width - 1.5, max(0, width * even - 0.75)))
                    }
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// "Saved 6:04 PM" for saved values, otherwise the state word.
func savedText(_ account: AccountOverview.Account) -> String {
    guard [.stale, .unavailable].contains(account.state), !account.windows.isEmpty, let observed = account.observedAt else {
        return account.stateText
    }
    return account.stateText + " " + AccountPaceText.when(observed, now: Date())
}

/// The watch is always dark.
enum WatchTokens {
    static func color(_ token: AccountColorToken) -> Color {
        let value = token.rgb(dark: true)
        return Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: token.opacity(dark: true))
    }
}
