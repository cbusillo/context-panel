import ContextPanelCore
import Foundation

/// One account answer for every Watch complication, derived from the shared Horizon model.
public struct WatchAccountComplicationPresentation {
    public let account: AccountOverview.Account
    public let horizon: AccountHorizon
    public let quantity: String
    public let circularQuantity: String
    public let inlineText: String
    public let compactInlineText: String
    public let cornerLabel: String
    public let accessibilityText: String
    public let colorToken: AccountColorToken
    public let stateSymbol: String?

    public init?(overview: AccountOverview, now: Date) {
        guard let account = Self.focusAccount(overview, now: now) else { return nil }
        self.account = account
        let horizon = account.horizon(now: now)
        self.horizon = horizon
        quantity = horizon.window.map { AccountNumbers.window($0) } ?? AccountTerms.unknown
        circularQuantity = horizon.window.map { AccountNumbers.window($0, sign: false) } ?? AccountTerms.unknown
        colorToken = horizon.isCurrent ? account.metadata.provider.colorToken : .saved
        let state = horizon.isCurrent ? nil : WatchAccountText.state(account, horizon: horizon)
        if horizon.remaining == nil || account.state == .unknown {
            stateSymbol = "questionmark"
        } else if account.windows.contains(where: { $0.assumption != nil }) {
            stateSymbol = "arrow.clockwise"
        } else {
            stateSymbol = switch account.state {
            case .stale, .unavailable: "clock"
            case .off: "pause"
            case .notConnected: "icloud.slash"
            case .refreshing: "arrow.clockwise"
            default: horizon.isCurrent ? nil : "questionmark"
            }
        }
        let provider = account.metadata.provider.accountDisplayName
        compactInlineText = [provider, quantity + " " + AccountTerms.left, state].compactMap { $0 }.joined(separator: " · ")
        inlineText = [provider, account.metadata.label, quantity + " " + AccountTerms.left, state]
            .compactMap { $0 }.joined(separator: " · ")
        cornerLabel = [provider, state].compactMap { $0 }.joined(separator: " · ")
        accessibilityText = WatchAccountText.accessibility(account, now: now, isNext: false)
    }

    private static func focusAccount(_ overview: AccountOverview, now: Date) -> AccountOverview.Account? {
        if let short = overview.runningShort(now: now).first { return short.account }
        let next = Provider.allCases.compactMap { overview.useNext(provider: $0) }
            .max { ($0.horizon(now: now).remaining ?? 0) < ($1.horizon(now: now).remaining ?? 0) }
        if let current = next ?? overview.closest { return current }

        // Reconstruct the last-good focus from saved normalized evidence, without calling it Use next.
        let saved = overview.accounts.filter { [.stale, .unavailable].contains($0.state) }
        let savedRunOut = saved.compactMap { account -> (AccountOverview.Account, Date)? in
            guard let observed = account.observedAt else { return nil }
            let long = account.windows.filter { $0.id != account.shortWindow?.id && $0.assumption == nil }
            let first = long.compactMap { window -> Date? in
                if window.remainingFraction == 0, (window.naturalResetAt ?? .distantPast) > observed { return observed }
                return window.projectedRunOut(now: observed)
            }.min()
            return first.map { (account, $0) }
        }.min { $0.1 < $1.1 }?.0
        if let savedRunOut { return savedRunOut }
        let savedNext = Provider.allCases.compactMap { provider -> AccountOverview.Account? in
            let ranking = overview.useNextRanking(provider: provider)
            guard ranking.basedOnStaleReadings, let id = ranking.entries.first?.accountID else { return nil }
            return saved.first { $0.id == id }
        }.max { ($0.horizon(now: now).remaining ?? 0) < ($1.horizon(now: now).remaining ?? 0) }
        return savedNext ?? saved.max { ($0.horizon(now: now).remaining ?? 0) < ($1.horizon(now: now).remaining ?? 0) }
            ?? overview.accounts.first
    }
}

/// Watch speech leads with the same named window and quantity the visible horizon uses.
public enum WatchAccountText {
    public static func state(_ account: AccountOverview.Account, horizon: AccountHorizon) -> String {
        if [.available, .closeToLimit, .limited].contains(account.state), !horizon.isCurrent {
            return account.windows.contains { $0.assumption != nil } ? AccountTerms.assumed : AccountCapacityState.unknown.displayText
        }
        return account.stateText
    }

    public static func accessibility(_ account: AccountOverview.Account, now: Date, isNext: Bool) -> String {
        let horizon = account.horizon(now: now)
        var parts = [account.metadata.provider.accountDisplayName, account.metadata.label]
        if let window = horizon.window {
            parts.append(window.label + " " + AccountNumbers.window(window) + " " + AccountTerms.left)
        } else {
            parts.append(AccountCapacityState.unknown.displayText)
        }
        parts.append(state(account, horizon: horizon))
        if horizon.isCurrent { parts.append(AccountTerms.outcomeShort(account, horizon, now: now)) }
        for window in account.orderedWindows {
            if window.id != horizon.window?.id {
                parts.append(window.label + " " + AccountNumbers.window(window) + " " + AccountTerms.left)
            }
            if let reset = AccountTerms.reset(window, now: now) { parts.append(window.label + " " + AccountTerms.resets + " " + reset) }
            if let assumption = window.assumption { parts.append(assumption.accessibilityText) }
        }
        if [.stale, .unavailable].contains(account.state), let observed = account.observedAt {
            parts.append(AccountTerms.lastSeen + " " + ContextPanelDateFormatting.accountReset(observed))
        }
        if let banked = account.bankedResets {
            parts.append((account.bankedState == .available ? "" : AccountTerms.lastSeen + " ")
                + "\(banked.availableCount) " + AccountTerms.bankedResets)
        }
        if isNext && horizon.isCurrent { parts.append(AccountTerms.useNext) }
        return parts.joined(separator: ", ")
    }
}
