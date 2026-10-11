import ContextPanelCore
import Foundation
import SwiftUI

/// One board-level observation summary, preserving per-account freshness in mixed snapshots.
public struct TVAccountFreshnessSummary: Equatable, Sendable {
    public let text: String
    public let hasSavedReadings: Bool

    public init(overview: AccountOverview, now: Date) {
        let notUpdating = overview.accounts.filter { [.stale, .unavailable].contains($0.state) }
        let saved = notUpdating.filter { !$0.windows.isEmpty }
        hasSavedReadings = !saved.isEmpty
        if !notUpdating.isEmpty {
            let count = AccountTerms.accountsCount(notUpdating.count)
            let observed = saved.compactMap(\.observedAt).min()
            text = count + " not updating" + (saved.isEmpty ? "" : " · showing saved readings")
                + (observed.map { " from " + AccountPaceText.when($0, now: now) } ?? "")
        } else if let observed = overview.accounts.compactMap(\.observedAt).max() {
            text = AccountTerms.updated + " " + AccountPaceText.when(observed, now: now)
        } else {
            text = AccountTerms.noCurrentReading
        }
    }
}

public struct TVAccountFreshness: View {
    let overview: AccountOverview
    let now: Date

    public init(overview: AccountOverview, now: Date) {
        self.overview = overview
        self.now = now
    }

    public var body: some View {
        let summary = TVAccountFreshnessSummary(overview: overview, now: now)
        Label(summary.text, systemImage: summary.hasSavedReadings ? "clock" : "clock.arrow.circlepath")
            .font(.system(size: 22)).monospacedDigit()
            .foregroundStyle(TVTokens.color(summary.hasSavedReadings ? .saved : .secondary))
    }
}
