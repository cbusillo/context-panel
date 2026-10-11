import Foundation

public extension AccountOverview {
    struct WidgetPick: Equatable, Sendable {
        public let provider: Provider
        public let account: Account?
        public let isRecommendation: Bool
    }

    /// Saved readings remain glanceable without becoming live recommendations.
    /// Fallbacks keep the person's saved order and never restore hidden/paused accounts.
    var widgetPicks: [WidgetPick] {
        Provider.allCases.compactMap { provider in
            let members = accounts.filter { $0.metadata.provider == provider }
            guard !members.isEmpty else { return nil }
            if let account = useNext(provider: provider) {
                return WidgetPick(provider: provider, account: account, isRecommendation: true)
            }
            // A saved sibling must not mask a known current provider limit or cushion hold.
            let hasCurrent = members.contains { [.available, .closeToLimit, .limited].contains($0.state) }
            let saved = hasCurrent ? nil : members.first {
                [.stale, .unavailable, .refreshing].contains($0.state) && $0.longWindow?.remainingFraction != nil
            }
            return WidgetPick(provider: provider, account: saved, isRecommendation: false)
        }
    }

    /// Current observations lead mixed data; all-saved data uses its oldest represented reading.
    func widgetObservationDate(in displayedAccounts: [Account]? = nil) -> Date? {
        let represented = (displayedAccounts ?? accounts).filter { $0.longWindow?.remainingFraction != nil }
        if let current = represented.filter(\.isReliable).compactMap(\.observedAt).max() { return current }
        return represented
            .filter { [.stale, .unavailable, .refreshing].contains($0.state) }
            .compactMap(\.observedAt).min()
    }

    var widgetShowsOnlySavedUsage: Bool {
        !accounts.isEmpty && accounts.allSatisfy { [.stale, .unavailable].contains($0.state) }
            && accounts.contains { $0.longWindow?.remainingFraction != nil }
    }
}
