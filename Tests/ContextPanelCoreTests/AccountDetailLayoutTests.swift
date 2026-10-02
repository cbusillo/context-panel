import AppKit
import SwiftUI
import Testing
@testable import ContextPanelSettingsUI
@testable import ContextPanelCore
@testable import ContextPanelApp

private let detailNow = Date(timeIntervalSince1970: 1_800_000_000)

private func detailOverview(windowCount: Int) -> AccountOverview {
    let limits = (0..<windowCount).map { index in
        UsageLimit(id: "window-\(index)", provider: .google, accountID: "google-detail",
            accountName: "Google account", label: index < 2 ? "Third-party models" : "Gemini",
            windowLabel: index.isMultiple(of: 2) ? "Weekly" : "5-hour",
            modelLabel: index < 2 ? "3p" : "Gemini", unit: .percent, used: 35, limit: 100,
            resetsAt: detailNow.addingTimeInterval(index.isMultiple(of: 2) ? 86_400 : 3_600), lastUpdatedAt: detailNow)
    }
    return AccountOverview(snapshot: UsageSnapshot(generatedAt: detailNow, limits: limits), reports: [], now: detailNow, accountBurnRates: ["google-detail": Dictionary(uniqueKeysWithValues: limits.map { ($0.id, ObservedBurnRate(limitID: $0.id, unitsPerHour: 4, observedDurationHours: 2, sampleCount: 3)) })])
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

@Test func quotaCardRowsHaveTwoColumnsAndEqualHeightWithoutTextDependentBreakpoints() {
    let layout = AccountWindowCardsLayout()
    let wide = layout.frames(width: 800, heights: [180, 260, 200, 220])
    #expect(Set(wide.map(\.minX)).count == 2)
    #expect(wide[0].minY == wide[1].minY)
    #expect(wide[0].height == wide[1].height)
    #expect(wide[2].minY > wide[0].maxY)
    #expect(wide.allSatisfy { $0.maxX <= 800 })
    let narrow = layout.frames(width: 500, heights: [180, 260, 200, 220])
    #expect(Set(narrow.map(\.minX)).count == 1)
    #expect(zip(narrow, narrow.dropFirst()).allSatisfy { $0.maxY < $1.minY })
    #expect(narrow.allSatisfy { $0.width == 500 })
}

@Test func decodedOldGoogleLabelsBecomePlainWordsOnEveryLimitSurface() throws {
    let original = try #require(detailOverview(windowCount: 1).accounts.first)
    #expect(original.windows.first?.modelLabel == "Third-party models")
    let limit = UsageLimit(id: "stable-history-id", provider: .google, accountID: "a", accountName: "Google",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 20, limit: 100)
    var raw = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(limit)) as? [String: Any])
    raw["label"] = "3p Models Weekly"
    raw["modelLabel"] = "3p Models"
    let decoded = try JSONDecoder().decode(UsageLimit.self, from: JSONSerialization.data(withJSONObject: raw))
    #expect(decoded.id == limit.id)
    #expect(decoded.label == "Third-party models Weekly")
    #expect(decoded.modelLabel == "Third-party models")
    #expect(decoded.used == limit.used)
}

@Test func limitHistoryKeepsItsProviderHighlightedAndMissingLimitsReturnToOverview() throws {
    let snapshot = UsageSnapshot(generatedAt: detailNow, limits: [
        UsageLimit(provider: .google, accountID: "a", accountName: "Google", label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: 20, limit: 100)
    ])
    let summary = try #require(snapshot.mainLimitSummaries.first)
    #expect(AppNavigationSelection.mainLimit(summary.id).sidebarSelection(in: snapshot) == .provider(.google))
    #expect(AppNavigationSelection.mainLimit(summary.id).sidebarSelection(in: UsageSnapshot(generatedAt: detailNow, limits: [])) == .overview)
    let account = AppNavigationSelection.providerAccount(.google, "a")
    #expect(account.sidebarSelection(in: snapshot) == account)
}

@Test func loneQuotaCardsSpanTheAvailablePane() {
    let layout = AccountWindowCardsLayout()
    let one = layout.frames(width: 800, heights: [180])
    #expect(one.first?.width == 800)
    let three = layout.frames(width: 800, heights: [180, 260, 200])
    #expect(three.last?.width == 800)
    #expect(three.last!.minY > three.first!.maxY)
}

@Test func vanishedLimitClearsStoredNavigationSoARecoveredLimitCannotReopenIt() throws {
    let snapshot = UsageSnapshot(generatedAt: detailNow, limits: [
        UsageLimit(provider: .google, accountID: "a", accountName: "Google", label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: 20, limit: 100)
    ])
    let summary = try #require(snapshot.mainLimitSummaries.first)
    let selected = AppNavigationSelection.mainLimit(summary.id)
    #expect(selected.retainingAvailableLimit(in: snapshot) == selected)
    let cleared = selected.retainingAvailableLimit(in: UsageSnapshot(generatedAt: detailNow, limits: []))
    #expect(cleared == .overview)
    #expect(cleared.retainingAvailableLimit(in: snapshot) == .overview)
}

@Test(arguments: [false, true])
func providerTotalDoesNotBorrowAnotherAccountsMissingWeeklyPercentage(healthyReports: Bool) throws {
    let limits = ["a", "b"].flatMap { account in
        [UsageLimit(provider: .openAI, accountID: account, accountName: account, label: "Weekly", windowLabel: "Weekly",
            unit: .percent, used: account == "a" ? 20 : nil, limit: 100,
            resetsAt: detailNow.addingTimeInterval(86_400), lastUpdatedAt: detailNow, confidence: .observed),
         UsageLimit(provider: .openAI, accountID: account, accountName: account, label: "5-hour", windowLabel: "5-hour",
            unit: .percent, used: 30, limit: 100, resetsAt: detailNow.addingTimeInterval(3_600),
            lastUpdatedAt: detailNow, confidence: .observed)]
    }
    let reports = healthyReports ? ["a", "b"].map {
        StoredProviderReport(provider: .openAI, accountID: $0, accountName: $0, generatedAt: detailNow, status: .healthy, errorMessage: nil)
    } : []
    let overview = AccountOverview(snapshot: UsageSnapshot(generatedAt: detailNow, limits: limits), reports: reports, now: detailNow)
    let total = try #require(overview.providerTotals(now: detailNow).first)
    // A missing weekly reading must either exclude its account visibly or make the aggregate unknown.
    #expect(total.countedCount < total.accountCount || total.longRemaining == nil)
}


@Test func providerPageKeepsItsOriginalAccountObservationsAndForecasts() throws {
    let google = detailOverview(windowCount: 4)
    let openAI = UsageLimit(provider: .openAI, accountID: "other", accountName: "Other",
        label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 90, limit: 100,
        resetsAt: detailNow.addingTimeInterval(86_400), lastUpdatedAt: detailNow)
    let mixed = AccountOverview(
        snapshot: UsageSnapshot(generatedAt: detailNow, limits: google.accounts.flatMap { account in
            account.windows.map { window in
                UsageLimit(id: window.id, provider: .google, accountID: account.metadata.configurationID,
                    accountName: account.metadata.label, label: window.label, windowLabel: window.periodLabel,
                    unit: window.unit, used: window.used, limit: window.limit,
                    resetsAt: window.naturalResetAt, lastUpdatedAt: window.observedAt)
            }
        } + [openAI]), reports: [], now: detailNow)
    let selected = mixed.filtered(to: .google)
    #expect(selected.accounts == mixed.accounts.filter { $0.metadata.provider == .google })
    #expect(selected.deadlines == mixed.deadlines.filter { $0.provider == .google })
    #expect(selected.providerTotals(now: detailNow).count == 1)
    #expect(selected.useNext(provider: .openAI) == nil)
    #expect(selected.accounts.first?.horizon(now: detailNow) == mixed.accounts.first { $0.metadata.provider == .google }?.horizon(now: detailNow))
}
