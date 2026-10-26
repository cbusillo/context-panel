import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WidgetKit

@testable import ContextPanelCore
@testable import ContextPanelWidgetUI

private let renderTestWidgetLinks = ContextPanelWidgetLinks(
    overview: URL(string: "contextpanel://overview")!
)

private let renderCompanionWidgetLinks = ContextPanelWidgetLinks(
    overview: URL(string: "contextpanelcompanion://overview")!
)

private func resetCreditRenderSnapshot(
    now: Date,
    weeklyUsed: Int = 100,
    resetInterval: TimeInterval = 3 * 86_400,
    expiryInterval: TimeInterval = 2 * 86_400,
    fiveHourUsed: Int? = nil,
    promptCacheObservations: [PromptCacheObservation] = [],
    promptCacheWidgetState: PromptCacheWidgetState = .unavailable
) -> WidgetSnapshot {
    let accountID = "openai-long-account-name"
    let configuredAccountID = "configured-openai"
    var limits = [
        UsageLimit(
            provider: .openAI,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: "OpenAI Long Account Name For Layout",
            label: "Codex Weekly",
            windowLabel: "weekly",
            unit: .percent,
            used: weeklyUsed,
            limit: 100,
            resetsAt: now.addingTimeInterval(resetInterval),
            lastUpdatedAt: now,
            confidence: .observed
        ),
    ]
    if let fiveHourUsed {
        limits.append(UsageLimit(
            provider: .openAI,
            accountID: accountID,
            configuredAccountID: configuredAccountID,
            accountName: "OpenAI Long Account Name For Layout",
            label: "Codex 5-hour",
            windowLabel: "5-hour",
            unit: .percent,
            used: fiveHourUsed,
            limit: 100,
            resetsAt: now.addingTimeInterval(2 * 3_600),
            lastUpdatedAt: now,
            confidence: .observed
        ))
    }
    return WidgetSnapshot(
        state: .ready,
        generatedAt: now,
        limits: limits,
        reports: [
            StoredProviderReport(
                provider: .openAI,
                accountID: accountID,
                configuredAccountID: configuredAccountID,
                accountName: "OpenAI Long Account Name For Layout",
                generatedAt: now,
                resetCredits: ProviderResetCreditSummary(
                    availableCount: 2,
                    observedAt: now,
                    coverage: .complete,
                    earliestKnownExpiry: now.addingTimeInterval(expiryInterval)
                ),
                status: .healthy,
                errorMessage: nil
            ),
        ],
        promptCacheObservations: promptCacheObservations,
        promptCacheWidgetState: promptCacheWidgetState,
        status: weeklyUsed >= 100 ? .limited : .close,
        message: "Current"
    )
}

private func resetCreditPromptCacheObservations(now: Date) -> [PromptCacheObservation] {
    [
        PromptCacheObservation(
            provider: .openAI,
            accountID: "openai-long-account-name",
            accountName: "OpenAI Long Account Name For Layout",
            observedAt: now,
            windowLabel: "latest",
            tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 980)
        ),
        PromptCacheObservation(
            provider: .openAI,
            accountID: "openai-long-account-name",
            accountName: "OpenAI Long Account Name For Layout",
            observedAt: now.addingTimeInterval(-60),
            windowLabel: "previous",
            tokens: PromptCacheTokenSet(inputTokens: 1_000, cachedInputTokens: 970)
        ),
    ]
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

private extension Range where Bound == Int {
    func clamped(to limits: Range<Int>) -> Range<Int> {
        Swift.max(lowerBound, limits.lowerBound)..<Swift.min(upperBound, limits.upperBound)
    }
}

@Test func accountWidgetLinksRoundTripAllProvidersAndDeadlineDestination() throws {
    for provider in Provider.allCases {
        let id = AccountDisplayMetadata.safeID(provider, "synthetic-account")
        let mac = renderTestWidgetLinks.account(provider, id: id)
        #expect(mac.host == "provider")
        #expect(mac.path == "/\(provider.rawValue)")
        #expect(URLComponents(url: mac, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == id)
        let companion = renderCompanionWidgetLinks.account(provider, id: id)
        #expect(companion.scheme == renderCompanionWidgetLinks.overview.scheme)
        #expect(companion.query == mac.query)
    }
    #expect(renderTestWidgetLinks.deadlines.host == "deadlines")
    #expect(renderCompanionWidgetLinks.deadlines.scheme == renderCompanionWidgetLinks.overview.scheme)
}

@MainActor
@Test func accountRowsRenderCapacityAndBankedExpiryInsideMediumCanvas() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let snapshot = resetCreditRenderSnapshot(now: now, weeklyUsed: 71)
    let view = ContextPanelWidgetContentView(family: .systemMedium, snapshot: snapshot,
        links: renderTestWidgetLinks,
        showsResetCreditSurfaces: true, presentationDate: now)
        .cpwThemeVariant(.light).frame(width: 344, height: 164)
    let image = try #require(renderedImage(from: view, width: 344, height: 164))
    #expect(nonBackgroundPixelCount(in: image) > 500)
    #expect(nonBackgroundPixelCount(in: image, rows: 125..<160) > 30)
}

