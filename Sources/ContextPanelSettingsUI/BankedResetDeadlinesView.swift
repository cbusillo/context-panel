import ContextPanelCore
import Foundation
import SwiftUI

/// A complete read-only offer list for app-sized surfaces. Widget glances use the shared advisor.
public struct BankedResetDeadlinesView: View {
    private let reports: [StoredProviderReport]
    private let presentationDate: Date?
    private let limits: [UsageLimit]

    public init(reports: [StoredProviderReport], limits: [UsageLimit] = [], presentationDate: Date? = nil) {
        self.reports = reports
        self.limits = limits
        self.presentationDate = presentationDate
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

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Banked reset deadlines").font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(reports.enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(report.provider.displayName) · \(report.accountName)").font(.headline)
                        if let summary = report.resetCredits?.presented(at: now) {
                            let dates = summary.knownExpiries.isEmpty
                                ? summary.earliestKnownExpiry.map { [$0] } ?? [] : summary.knownExpiries
                            Text("\(summary.availableCount) banked resets")
                            ForEach(Array(dates.enumerated()), id: \.offset) { _, expiry in
                                Text("Expires \(ContextPanelDateFormatting.resetDeadline(expiry))")
                            }
                            if dates.count < summary.availableCount {
                                Text("\(summary.availableCount - dates.count) expiry dates unknown")
                                    .foregroundStyle(.secondary)
                            }
                            if report.status == .failure || abs(report.generatedAt.timeIntervalSince(summary.observedAt)) > 1 || now.timeIntervalSince(summary.observedAt) > SnapshotFreshness.companionProviderMaximumAge {
                                Text("Last observed · refresh the Mac for current inventory")
                                    .foregroundStyle(.secondary)
                            }
                            if !limits.isEmpty, let guidance = ResetCreditGuidanceAdvisor.guidance(report: report, limits: limits, now: now) {
                                Text(guidance.recommendationTitle + " · " + guidance.recommendationDetail(now: now))
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
