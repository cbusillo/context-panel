import AppKit
import SwiftUI
import Testing
@testable import ContextPanelApp
@testable import ContextPanelCore

@MainActor
@Test(arguments: [760, 960])
func allAccountsCardRendersFiveAccountsWithPartialData(width: Int) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let configs = (0..<5).map { index in
        LocalProviderAccountConfiguration(id: "fixture-\(index)", provider: index < 3 ? .openAI : .anthropic,
            connectorKind: index < 3 ? .codexRateLimits : .claudeOAuthUsage,
            displayName: ["Personal", "Projects", "Research", "Writing", "Secondary"][index])
    }
    let limits = configs.prefix(4).flatMap { config in
        ["5-hour", "Weekly"].map { window in
            UsageLimit(provider: config.provider, accountID: config.id, configuredAccountID: config.id,
                accountName: config.displayName, label: window, windowLabel: window, unit: .percent,
                used: config.provider == .openAI ? 45 : 80, limit: 100,
                resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: now)
        }
    }
    let reports = configs.prefix(4).map { config in
        StoredProviderReport(provider: config.provider, accountID: config.id, configuredAccountID: config.id,
            accountName: config.displayName, generatedAt: now,
            resetCredits: config == configs[0] ? ProviderResetCreditSummary(availableCount: 3, observedAt: now,
                coverage: .complete, earliestKnownExpiry: now.addingTimeInterval(86_400),
                knownExpiries: [1, 8, 15].map { now.addingTimeInterval(Double($0) * 86_400) }) : nil,
            usageCredits: config == configs[0] ? ProviderUsageCreditSummary(hasCredits: true, unlimited: false, balance: 500) : nil,
            status: .healthy, errorMessage: nil)
    }
    let rows = AccountCapacity.rows(configuration: configs, snapshot: UsageSnapshot(generatedAt: now, limits: limits), reports: reports, now: now)
    let rates = Dictionary(uniqueKeysWithValues: configs.prefix(4).map { config in
        (config.id, ["\(config.provider.rawValue):weekly": ObservedBurnRate(limitID: "weekly", unitsPerHour: 1.5, observedDurationHours: 2, sampleCount: 3)])
    })
    let renderer = ImageRenderer(content: AccountCapacityCard(rows: rows, burnRates: rates, now: now).padding(20).frame(width: CGFloat(width)))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    #expect(image.height > 500)
    if let output = ProcessInfo.processInfo.environment["CONTEXT_PANEL_RENDER_OUTPUT_DIR"] {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent("all-accounts-\(width).png"))
    }
}
