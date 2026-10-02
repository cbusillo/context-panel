import AppKit
import SwiftUI
import Testing
import ContextPanelSettingsUI
@testable import ContextPanelCore

private let detailNow = Date(timeIntervalSince1970: 1_800_000_000)

private func detailOverview(windowCount: Int) -> AccountOverview {
    let limits = (0..<windowCount).map { index in
        UsageLimit(id: "window-\(index)", provider: .google, accountID: "google-detail",
            accountName: "Google account", label: index < 2 ? "Third-party models" : "Gemini",
            windowLabel: index.isMultiple(of: 2) ? "Weekly" : "5-hour",
            modelLabel: index < 2 ? "3p" : "Gemini", unit: .percent, used: 35, limit: 100,
            resetsAt: detailNow.addingTimeInterval(index.isMultiple(of: 2) ? 86_400 : 3_600), lastUpdatedAt: detailNow)
    }
    return AccountOverview(snapshot: UsageSnapshot(generatedAt: detailNow, limits: limits), reports: [], now: detailNow)
}

@MainActor
@Test func googleDetailWrapsFourWindowsAndStacksAtNarrowWidths() throws {
    func render(_ count: Int, _ width: CGFloat) throws -> CGImage {
        let overview = detailOverview(windowCount: count)
        let account = try #require(overview.accounts.first)
        let renderer = ImageRenderer(content: AccountDashboardDetail(account: account, overview: overview, now: detailNow)
            .padding(24).frame(width: width))
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(width))
        if let output = ProcessInfo.processInfo.environment["CONTEXT_PANEL_RENDER_OUTPUT_DIR"] {
            let root = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bytes = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try bytes.write(to: root.appendingPathComponent("google-detail-\(count)-\(Int(width)).png"))
        }
        return image
    }
    let two = try render(2, 800)
    let four = try render(4, 800)
    let narrow = try render(4, 500)
    // An extra pair needs another card row, rather than reducing each text column to a few letters.
    #expect(four.height > two.height + 120)
    #expect(narrow.height > four.height + 200)
}

@Test func savedGoogleAbbreviationIsExpandedWithoutChangingOtherProviders() throws {
    let account = try #require(detailOverview(windowCount: 4).accounts.first)
    #expect(account.windows.prefix(2).allSatisfy { $0.label.hasPrefix("Third-party models") })
    #expect(AccountTerms.modelName("3p", provider: .openAI) == "3p")
    #expect(AccountTerms.modelName("Gemini", provider: .google) == "Gemini")
}

@Test func sidebarReportsMeanRemainingRoomAndPartialCoverage() throws {
    let limits = [20, 60].enumerated().map { index, used in
        UsageLimit(provider: .openAI, accountID: "account-\(index)", accountName: "Account \(index)",
            label: "Weekly", windowLabel: "Weekly", unit: .percent, used: used, limit: 100,
            resetsAt: detailNow.addingTimeInterval(86_400), lastUpdatedAt: detailNow)
    }
    let missing = AccountDisplayMetadata(id: "missing", configurationID: "missing", provider: .openAI, label: "Missing")
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: detailNow, limits: limits), reports: [],
        metadata: limits.map { AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(.openAI, $0.accountID),
            configurationID: AccountDisplayMetadata.safeID(.openAI, $0.accountID), provider: .openAI, label: $0.accountName) } + [missing], now: detailNow)
    let total = try #require(overview.providerTotals(now: detailNow).first)
    #expect(abs((total.longRemaining ?? 0) - 0.6) < 0.000001)
    let text = AccountTerms.sidebarRemaining(total)
    #expect(text.contains("60% left"))
    #expect(text.contains("2 of 3 current"))
    #expect(!text.contains("used"))
}
