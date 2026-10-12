import ContextPanelCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

public enum SpatialAccountOverviewLayout {
    public static func usesCompactCards(contentWidth: CGFloat, accessibility: Bool) -> Bool {
        accessibility || !contentWidth.isFinite || contentWidth < 700
    }

    public static func usesCompactAccounts(contentWidth: CGFloat, accessibility: Bool) -> Bool {
        accessibility || !contentWidth.isFinite || contentWidth < AccountDashboardPanel.minimumTableWidth
    }
}

/// Vision's window composition, built from the same Horizon components and tokens as the Mac.
/// Sync presentation stays with the companion's shared status view and normalized freshness model.
public struct SpatialAccountOverviewPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let overview: AccountOverview
    private let now: Date
    private let contentWidth: CGFloat
    private let openAccount: (AccountOverview.Account) -> Void
    private let openDeadlines: () -> Void

    private var enlargedTextScale: CGFloat {
        #if canImport(UIKit)
        let category: UIContentSizeCategory = switch dynamicTypeSize {
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        default: .large
        }
        // Explicit traits also give offscreen shared-view captures the same scaling as the window.
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: AccountTextSize.appMinimum,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category)) / AccountTextSize.appMinimum
        #else
        return 1
        #endif
    }

    public init(overview: AccountOverview, now: Date, contentWidth: CGFloat,
                openAccount: @escaping (AccountOverview.Account) -> Void,
                openDeadlines: @escaping () -> Void) {
        self.overview = overview
        self.now = now
        self.contentWidth = contentWidth
        self.openAccount = openAccount
        self.openDeadlines = openDeadlines
    }

    public var body: some View {
        AccountDashboardPanel(overview: overview, now: now,
            compact: SpatialAccountOverviewLayout.usesCompactCards(contentWidth: contentWidth, accessibility: dynamicTypeSize.isAccessibilitySize),
            compactAccounts: SpatialAccountOverviewLayout.usesCompactAccounts(contentWidth: contentWidth, accessibility: dynamicTypeSize.isAccessibilitySize),
            emptyMessage: "Open Context Panel on your Mac to check accounts and share their usage.",
            emptyHeadline: "Waiting for account readings",
            textScale: dynamicTypeSize.isAccessibilitySize ? enlargedTextScale : 1,
            openAccount: openAccount, openDeadlines: openDeadlines)
    }
}
