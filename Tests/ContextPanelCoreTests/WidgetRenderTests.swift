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
    let scenarios: [(snapshot: WidgetSnapshot, variant: CPWThemeVariant)] = [
        (smallWidgetSnapshot(usedPercent: 58), .light),
        (smallWidgetSnapshot(usedPercent: nil, status: .unknown), .dark),
        (smallWidgetSnapshot(usedPercent: 58, state: .stale), .light),
    ]

    for scenario in scenarios {
        let view = ContextPanelWidgetContentView(
            family: .systemSmall,
            snapshot: scenario.snapshot,
            displayPreferences: .defaultPreferences,
            links: renderTestWidgetLinks
        )
        .cpwThemeVariant(scenario.variant)
        .frame(width: 164, height: 164)
        .background(CPWTheme.surface(variant: scenario.variant))

        let image = try #require(renderedImage(from: view, width: 164, height: 164))
        #expect(nonBackgroundPixelCount(in: image) > 1_400)
    }
}

@MainActor
private func renderedImage<V: View>(from view: V, width: CGFloat, height: CGFloat) -> CGImage? {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.proposedSize = ProposedViewSize(width: width, height: height)
    return renderer.cgImage
}

private func nonBackgroundPixelCount(in image: CGImage) -> Int {
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
    for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
        let delta = abs(Int(pixels[offset]) - Int(background[0]))
            + abs(Int(pixels[offset + 1]) - Int(background[1]))
            + abs(Int(pixels[offset + 2]) - Int(background[2]))
            + abs(Int(pixels[offset + 3]) - Int(background[3]))
        if delta > 18 {
            changed += 1
        }
    }
    return changed
}

private func smallWidgetSnapshot(
    usedPercent: Int?,
    state: WidgetSnapshotState = .ready,
    status: UsageStatus? = nil
) -> WidgetSnapshot {
    let now = Date()
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
        status: state == .stale ? .stale : (status ?? .healthy),
        message: "Synced"
    )
}
