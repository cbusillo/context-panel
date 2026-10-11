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
            let saved = members.first {
                [.stale, .unavailable].contains($0.state) && $0.longWindow?.remainingFraction != nil
            }
            return WidgetPick(provider: provider, account: saved, isRecommendation: false)
        }
    }

    /// Use the oldest represented observation rather than the time the widget was rendered.
    var widgetObservationDate: Date? {
        accounts.compactMap(\.observedAt).min()
    }

    var widgetShowsOnlySavedUsage: Bool {
        !accounts.isEmpty && accounts.allSatisfy { [.stale, .unavailable].contains($0.state) }
            && accounts.contains { $0.longWindow?.remainingFraction != nil }
    }
}
