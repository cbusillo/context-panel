import ContextPanelCore
import Foundation
import SwiftUI

/// A complete read-only offer list for app-sized surfaces. Advice comes from the account overview's one advisor.
public struct BankedResetDeadlinesView: View {
    private let reports: [StoredProviderReport]
    private let presentationDate: Date?
    private let maximumAge: TimeInterval
    private let adviceByAccountID: [String: AccountOverview.BankedAdvice]?

    public init(reports: [StoredProviderReport], presentationDate: Date? = nil, maximumAge: TimeInterval = SnapshotFreshness.appMaximumAge, adviceByAccountID: [String: AccountOverview.BankedAdvice]? = nil) {
        self.reports = reports
        self.presentationDate = presentationDate
        self.maximumAge = maximumAge
        self.adviceByAccountID = adviceByAccountID
    }

    public var body: some View {
        if let presentationDate {
            content(now: presentationDate)
        } else {
            let start = Date()
            TimelineView(.explicit([start] + reports.resetCreditTransitionDates(after: start))) { context in
                content(now: context.date)
            }
        }
    }

    func advice(for report: StoredProviderReport) -> AccountOverview.BankedAdvice? {
        adviceByAccountID?[report.accountID]
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Banked reset deadlines").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.provider.displayName) · \(report.accountName)").font(.headline)
                        if let summary = report.resetCredits?.presented(at: now) {
                            let dates = summary.expiries(after: now)
                            Text("\(summary.availableCount) banked resets")
                            if report.provider == .anthropic && !summary.generalWeeklyOnly {
                                Text("General-week refill unconfirmed; excluded from the plan").foregroundStyle(.secondary)
                            }
                            if summary.excludedOfferCount > 0 {
                                Text("\(summary.excludedOfferCount) offers with no resets left").foregroundStyle(.secondary)
                            }
                            if summary.unrecognizedKindCount > 0 {
                                Text("\(summary.unrecognizedKindCount) model-only or unrecognized resets, excluded from the plan")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(dates.enumerated()), id: \.offset) { _, expiry in
                                Text("Expires \(ContextPanelDateFormatting.resetDeadline(expiry))")
                            }
                            if dates.count < summary.availableCount {
                                Text("\(summary.availableCount - dates.count) expiry dates unknown")
                                    .foregroundStyle(.secondary)
                            }
                            if report.status == .failure || abs(report.generatedAt.timeIntervalSince(summary.observedAt)) > 1 || now.timeIntervalSince(summary.observedAt) > maximumAge {
                                Text("Last observed · refresh the Mac for current inventory")
                                    .foregroundStyle(.secondary)
                            }
                            if let advice = advice(for: report) {
                                Text(advice.title + " · " + advice.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Banked resets unknown").foregroundStyle(.secondary)
                        }
                    }
                    .id("reset-account:\(report.accountID)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}
