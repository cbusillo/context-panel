import Foundation

public extension AccountOverview {
    struct WidgetPick: Equatable, Sendable {
        public let provider: Provider
        public let account: Account?
        public let isRecommendation: Bool
    }

    struct WidgetObservation: Equatable, Sendable {
        public let date: Date
        public let isCurrent: Bool
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
    func widgetObservation(in displayedAccounts: [Account]? = nil) -> WidgetObservation? {
        let represented = (displayedAccounts ?? accounts).filter { $0.longWindow?.remainingFraction != nil }
        if let current = represented.compactMap({ account -> Date? in
            let horizon = account.horizon(now: rankedAt)
            return horizon.isCurrent ? horizon.window?.observedAt : nil
        }).max() {
            return WidgetObservation(date: current, isCurrent: true)
        }
        return represented
            .filter { [.stale, .unavailable, .refreshing].contains($0.state) }
            .compactMap(\.observedAt).min()
            .map { WidgetObservation(date: $0, isCurrent: false) }
    }

    var widgetShowsOnlySavedUsage: Bool {
        let represented = accounts.filter {
            ![.off, .notConnected].contains($0.state)
                && ($0.remainingFraction != nil || $0.longWindow?.remainingFraction != nil)
        }
        return !represented.isEmpty && represented.allSatisfy { [.stale, .unavailable].contains($0.state) }
    }

    var widgetTapAccount: Account? {
        let shown = widgetPicks.compactMap(\.account)
        if let closest, let selected = shown.first(where: { $0.id == closest.id }) { return selected }
        return shown.first
    }
}
