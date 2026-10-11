import ContextPanelCore
import SwiftUI

/// Vision's window composition, built from the same Horizon components and tokens as the Mac.
public struct SpatialAccountOverviewPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let overview: AccountOverview
    private let now: Date
    private let contentWidth: CGFloat
    private let syncTitle: String
    private let syncDetail: String
    private let syncSymbol: String
    private let lastSyncedAt: Date?
    private let openAccount: (AccountOverview.Account) -> Void
    private let openDeadlines: () -> Void

    public init(overview: AccountOverview, now: Date, contentWidth: CGFloat,
                syncTitle: String, syncDetail: String, syncSymbol: String, lastSyncedAt: Date?,
                openAccount: @escaping (AccountOverview.Account) -> Void,
                openDeadlines: @escaping () -> Void) {
        self.overview = overview
        self.now = now
        self.contentWidth = contentWidth
        self.syncTitle = syncTitle
        self.syncDetail = syncDetail
        self.syncSymbol = syncSymbol
        self.lastSyncedAt = lastSyncedAt
        self.openAccount = openAccount
        self.openDeadlines = openDeadlines
    }

    public nonisolated static func usesCompactCards(contentWidth: CGFloat, accessibility: Bool) -> Bool {
        accessibility || !contentWidth.isFinite || contentWidth < 600
    }

    public nonisolated static func usesCompactAccounts(contentWidth: CGFloat, accessibility: Bool) -> Bool {
        accessibility || !contentWidth.isFinite || contentWidth < AccountDashboardPanel.minimumTableWidth
    }

    public var body: some View {
        let palette = DashboardPalette(dark: colorScheme == .dark)
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label(syncTitle, systemImage: syncSymbol)
                    .font(.headline).foregroundStyle(palette.primary)
                Text(syncDetail).font(.subheadline).foregroundStyle(palette.secondary)
                if let lastSyncedAt {
                    Text("Last synced " + lastSyncedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(palette.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(palette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(palette.line, lineWidth: 1))
            .accessibilityElement(children: .combine)

            AccountDashboardPanel(overview: overview, now: now,
                compact: Self.usesCompactCards(contentWidth: contentWidth, accessibility: dynamicTypeSize.isAccessibilitySize),
                compactAccounts: Self.usesCompactAccounts(contentWidth: contentWidth, accessibility: dynamicTypeSize.isAccessibilitySize),
                emptyMessage: "No accounts have synced yet. Open Context Panel on your Mac to add an account.",
                openAccount: openAccount, openDeadlines: openDeadlines)
        }
    }
}
