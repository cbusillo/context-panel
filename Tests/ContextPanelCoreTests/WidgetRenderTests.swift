import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import ContextPanelCore
@testable import ContextPanelWidgetUI

private let renderTestWidgetLinks = ContextPanelWidgetLinks(
    overview: URL(string: "contextpanel://overview")!,
    reconnect: URL(string: "contextpanel://reconnect")!,
    cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!
)

@MainActor
@Test func healthyMediumWidgetRenderIsNotBlank() throws {
    let snapshot = WidgetSnapshot(
        state: .ready,
        generatedAt: Date(timeIntervalSince1970: 100),
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai-primary",
                accountName: "OpenAI",
                label: "Codex Weekly",
                windowLabel: "weekly",
                unit: .percent,
                used: 44,
                limit: 100,
                resetsAt: Date(timeIntervalSince1970: 10_000),
                lastUpdatedAt: Date(timeIntervalSince1970: 100),
                confidence: .observed
            ),
            UsageLimit(
                provider: .google,
                accountID: "google-antigravity",
                accountName: "Antigravity",
                label: "Gemini Five Hour Limit",
                windowLabel: "5-hour",
                unit: .percent,
                used: 3,
                limit: 100,
                resetsAt: Date(timeIntervalSince1970: 8_000),
                lastUpdatedAt: Date(timeIntervalSince1970: 100),
                confidence: .observed
            ),
        ],
        promptCacheObservations: [
            PromptCacheObservation(
                provider: .openAI,
                accountID: "openai-primary",
                accountName: "OpenAI",
                observedAt: Date(timeIntervalSince1970: 99),
                windowLabel: "latest",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 960)
            ),
            PromptCacheObservation(
                provider: .openAI,
                accountID: "openai-primary",
                accountName: "OpenAI",
                observedAt: Date(timeIntervalSince1970: 98),
                windowLabel: "previous",
                tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 950)
            ),
        ],
        promptCacheWidgetState: .available,
        status: .healthy,
        message: "All providers refreshed."
    )
    let view = ContextPanelWidgetContentView(
        family: .systemMedium,
        snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        links: renderTestWidgetLinks
    )
    .cpwThemeVariant(.light)
    .frame(width: 344, height: 164)
    .background(CPWTheme.surface(variant: .light))

    let image = try #require(renderedImage(from: view, width: 344, height: 164))
    #expect(nonBackgroundPixelCount(in: image) > 2_500)
}

@MainActor
@Test func selectedSmallWidgetRendersKnownUnknownAndStaleStates() throws {
    let scenarios: [(
        snapshot: WidgetSnapshot,
        preferences: WidgetDisplayPreferences,
        variant: CPWThemeVariant,
        expectsThreeLanes: Bool
    )] = [
        (smallWidgetSnapshot(usedPercent: 58), singleLaneWidgetPreferences, .light, false),
        (smallWidgetSnapshot(usedPercent: nil, status: .unknown), singleLaneWidgetPreferences, .dark, false),
        (smallWidgetSnapshot(usedPercent: 58, state: .stale), singleLaneWidgetPreferences, .light, false),
        (smallWidgetSnapshot(usedPercent: 58, state: .failure), singleLaneWidgetPreferences, .dark, false),
        (multiLaneSmallWidgetSnapshot(), .defaultPreferences, .dark, true),
        (multiLaneSmallWidgetSnapshot(state: .stale), .defaultPreferences, .light, true),
        (multiLaneSmallWidgetSnapshot(state: .failure), .defaultPreferences, .dark, true),
    ]

    for scenario in scenarios {
        let view = ContextPanelWidgetContentView(
            family: .systemSmall,
            snapshot: scenario.snapshot,
            displayPreferences: scenario.preferences,
            links: renderTestWidgetLinks
        )
        .cpwThemeVariant(scenario.variant)
        .frame(width: 164, height: 164)
        .background(CPWTheme.surface(variant: scenario.variant))

        let image = try #require(renderedImage(from: view, width: 164, height: 164))
        #expect(nonBackgroundPixelCount(in: image) > 1_400)
        if scenario.expectsThreeLanes {
            #expect(nonBackgroundPixelCount(in: image, rows: 109..<164) > 150)
        }
    }
}

@MainActor
@Test func providerRefreshAttentionKeepsHealthyLaneColors() throws {
    let now = Date()
    let expiredLimit = UsageLimit(
        provider: .openAI,
        accountID: "expired-openai",
        accountName: "Expired OpenAI",
        label: "Codex 5-hour",
        windowLabel: "5-hour",
        unit: .percent,
        used: 0,
        limit: 100,
        resetsAt: now.addingTimeInterval(-60),
        lastUpdatedAt: now.addingTimeInterval(-300),
        confidence: .observed
    )
    let stored = StoredUsageSnapshot(
        savedAt: now,
        snapshot: UsageSnapshot(generatedAt: now, limits: [
            expiredLimit,
            UsageLimit(
                provider: .openAI,
                accountID: "current-openai",
                accountName: "Current OpenAI",
                label: "Codex 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 34,
                limit: 100,
                resetsAt: now.addingTimeInterval(3_600),
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "current-claude",
                accountName: "Claude",
                label: "Claude weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 12,
                limit: 100,
                resetsAt: now.addingTimeInterval(86_400),
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .google,
                accountID: "current-google",
                accountName: "Antigravity",
                label: "Gemini weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: 13,
                limit: 100,
                resetsAt: now.addingTimeInterval(86_400),
                lastUpdatedAt: now,
                confidence: .observed
            ),
        ]),
        reports: [StoredProviderReport(
            provider: .openAI,
            accountID: "expired-openai",
            accountName: "Expired OpenAI",
            generatedAt: now,
            status: .failure,
            errorMessage: "Every Code auth is no longer authorized for Codex usage."
        )]
    )
    let document = CompanionSyncDocument(storedSnapshot: stored, publishedAt: now)
    let snapshot = WidgetSnapshot.fromCompanionSync(
        CompanionSyncLoadResult(document: document, status: document.companionStatus),
        now: now
    )
    let view = ContextPanelWidgetContentView(
        family: .systemLarge,
        snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        links: renderTestWidgetLinks
    )
    .cpwThemeVariant(.light)
    .frame(width: 344, height: 344)
    .background(CPWTheme.surface(variant: .light))

    let image = try #require(renderedImage(from: view, width: 344, height: 344))
    #expect(pixelCount(in: image, near: (74, 122, 91)) > 100)
    #expect(pixelCount(in: image, near: (122, 98, 63)) > 5)
}

private var singleLaneWidgetPreferences: WidgetDisplayPreferences {
    var preferences = WidgetDisplayPreferences.defaultPreferences
    for index in preferences.mainLimits.indices {
        preferences.mainLimits[index].isVisible = preferences.mainLimits[index].provider == .openAI
            && preferences.mainLimits[index].window == .weekly
    }
    return preferences
}

private func multiLaneSmallWidgetSnapshot(state: WidgetSnapshotState = .ready) -> WidgetSnapshot {
    let now = Date()
    let snapshotStatus: UsageStatus
    switch state {
    case .ready:
        snapshotStatus = .healthy
    case .stale:
        snapshotStatus = .stale
    case .failure:
        snapshotStatus = .failure
    case .setupNeeded:
        snapshotStatus = .unknown
    }
    return WidgetSnapshot(
        state: state,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "openai-weekly",
                accountName: "OpenAI",
                label: "Codex Weekly",
                windowLabel: "weekly",
                unit: .percent,
                used: 44,
                limit: 100,
                resetsAt: now.addingTimeInterval(86_400),
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .openAI,
                accountID: "openai-five-hour",
                accountName: "OpenAI",
                label: "Codex 5-hour",
                windowLabel: "5-hour",
                unit: .percent,
                used: 18,
                limit: 100,
                resetsAt: now.addingTimeInterval(7_200),
                lastUpdatedAt: now,
                confidence: .observed
            ),
            UsageLimit(
                provider: .anthropic,
                accountID: "anthropic-weekly",
                accountName: "Anthropic",
                label: "Claude Weekly",
                windowLabel: "weekly",
                unit: .percent,
                used: 27,
                limit: 100,
                resetsAt: now.addingTimeInterval(172_800),
                lastUpdatedAt: now,
                confidence: .official
            ),
        ],
        status: snapshotStatus,
        message: "All providers refreshed."
    )
}

@MainActor
private func renderedImage<V: View>(from view: V, width: CGFloat, height: CGFloat) -> CGImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.proposedSize = ProposedViewSize(width: width, height: height)
    return renderer.cgImage
}

private func nonBackgroundPixelCount(in image: CGImage) -> Int {
    nonBackgroundPixelCount(in: image, rows: 0..<image.height)
}

private func nonBackgroundPixelCount(in image: CGImage, rows: Range<Int>) -> Int {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return 0
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let background = Array(pixels.prefix(bytesPerPixel))
    var changed = 0
    for row in rows.clamped(to: 0..<height) {
        let rowStart = row * bytesPerRow
        for offset in stride(from: rowStart, to: rowStart + bytesPerRow, by: bytesPerPixel) {
            let delta = abs(Int(pixels[offset]) - Int(background[0]))
                + abs(Int(pixels[offset + 1]) - Int(background[1]))
                + abs(Int(pixels[offset + 2]) - Int(background[2]))
                + abs(Int(pixels[offset + 3]) - Int(background[3]))
            if delta > 18 {
                changed += 1
            }
        }
    }
    return changed
}

private func pixelCount(
    in image: CGImage,
    near target: (red: UInt8, green: UInt8, blue: UInt8),
    tolerance: Int = 12
) -> Int {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return 0
    }

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return stride(from: 0, to: pixels.count, by: bytesPerPixel).reduce(into: 0) { count, offset in
        let redDelta = abs(Int(pixels[offset]) - Int(target.red))
        let greenDelta = abs(Int(pixels[offset + 1]) - Int(target.green))
        let blueDelta = abs(Int(pixels[offset + 2]) - Int(target.blue))
        if redDelta <= tolerance, greenDelta <= tolerance, blueDelta <= tolerance {
            count += 1
        }
    }
}

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        Swift.max(lowerBound, limits.lowerBound)..<Swift.min(upperBound, limits.upperBound)
    }
}

private func smallWidgetSnapshot(
    usedPercent: Int?,
    state: WidgetSnapshotState = .ready,
    status: UsageStatus? = nil
) -> WidgetSnapshot {
    let now = Date()
    let snapshotStatus: UsageStatus
    switch state {
    case .ready:
        snapshotStatus = status ?? .healthy
    case .stale:
        snapshotStatus = .stale
    case .failure:
        snapshotStatus = .failure
    case .setupNeeded:
        snapshotStatus = .unknown
    }
    return WidgetSnapshot(
        state: state,
        generatedAt: now,
        limits: [
            UsageLimit(
                provider: .openAI,
                accountID: "render",
                accountName: "Render",
                label: "Weekly",
                windowLabel: "Weekly",
                unit: .percent,
                used: usedPercent,
                limit: usedPercent == nil ? nil : 100,
                resetsAt: now.addingTimeInterval(86_400),
                lastUpdatedAt: state == .stale || status == .stale ? now.addingTimeInterval(-10_800) : now,
                confidence: usedPercent == nil ? .estimated : .observed,
                statusOverride: status
            ),
        ],
        status: snapshotStatus,
        message: "Synced"
    )
}
