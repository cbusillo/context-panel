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
        let state = horizon.isCurrent ? nil : account.stateText
        stateSymbol = horizon.remaining == nil ? "questionmark"
            : horizon.isCurrent ? nil : "clock"
        let provider = account.metadata.provider.accountDisplayName
        compactInlineText = [provider, quantity + " " + AccountTerms.left, state].compactMap { $0 }.joined(separator: " · ")
        inlineText = [provider, account.metadata.label, quantity + " " + AccountTerms.left, state]
            .compactMap { $0 }.joined(separator: " · ")
        cornerLabel = [provider, state].compactMap { $0 }.joined(separator: " · ")
        accessibilityText = account.glanceAccessibilityText(now: now, isNext: false)
    }

    private static func focusAccount(_ overview: AccountOverview, now: Date) -> AccountOverview.Account? {
        if let short = overview.runningShort(now: now).first { return short.account }
        let next = Provider.allCases.compactMap { overview.useNext(provider: $0) }
            .max { ($0.horizon(now: now).remaining ?? 0) < ($1.horizon(now: now).remaining ?? 0) }
        return next ?? overview.closest ?? overview.accounts.first
    }
}
