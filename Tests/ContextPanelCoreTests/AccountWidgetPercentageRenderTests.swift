import AppKit
import SwiftUI
import Testing
import Vision
import WidgetKit
@testable import ContextPanelCore
@testable import ContextPanelWidgetUI

@MainActor
@Test(arguments: ["small", "medium", "large", "extra-large"], [false, true])
func accountWidgetKeepsFullPercentageWithLongNames(size: String, dark: Bool) throws {
    let family: WidgetFamily
    let dimensions: CGSize
    switch size {
    case "small":
        family = .systemSmall
        dimensions = SettingsWidgetPreviewFamily.small.size
    case "medium":
        family = .systemMedium
        dimensions = SettingsWidgetPreviewFamily.medium.size
    case "large":
        family = .systemLarge
        dimensions = SettingsWidgetPreviewFamily.large.size
    default:
        family = .systemExtraLarge
        dimensions = CGSize(width: 720, height: 344)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let providers: [Provider] = [.openAI, .openAI, .openAI, .anthropic, .anthropic, .google]
    let limits = providers.enumerated().map { index, provider in
        UsageLimit(provider: provider, accountID: "synthetic-\(index)",
            accountName: "longest.configured.account.\(index)@example.invalid",
            label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 0, limit: 100,
            resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: now, confidence: .observed)
    }
    let metadata = limits.map { limit in
        AccountDisplayMetadata(id: AccountDisplayMetadata.safeID(limit.provider, limit.accountID),
            configurationID: AccountDisplayMetadata.safeID(limit.provider, limit.accountID),
            provider: limit.provider, label: limit.accountName)
    }
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: limits,
        status: .healthy, message: "", accountDisplayMetadata: metadata)
    let links = ContextPanelWidgetLinks(overview: URL(string: "contextpanel://overview")!,
        reconnect: URL(string: "contextpanel://settings")!,
        cacheStatsSettings: URL(string: "contextpanel://settings/cache-stats")!, resetCreditInteraction: .none)
    let view = ContextPanelWidgetContentView(family: family, snapshot: snapshot,
        displayPreferences: .defaultPreferences, links: links, presentationDate: now)
        .cpwThemeVariant(dark ? .dark : .light)
        .environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: dimensions.width, height: dimensions.height)
    let host = NSHostingView(rootView: view)
    host.frame = CGRect(origin: .zero, size: dimensions)
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(dimensions.width * 2), pixelsHigh: Int(dimensions.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = dimensions
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let image = try #require(bitmap.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    // Large layouts also show a provider average. Exclude those headers so they
    // cannot mask a truncated account percentage.
    let accountLines = lines.filter { !$0.contains("average") }
    let fullPercentages = accountLines.reduce(0) { count, line in
        count + line.replacingOccurrences(of: " ", with: "").components(separatedBy: "100%").count - 1
    }
    let expected = family == .systemLarge || family == .systemExtraLarge ? limits.count : Set(providers).count
    #expect(fullPercentages == expected, "Visible account percentages: \(lines)")
    if let output = ProcessInfo.processInfo.environment["CONTEXT_PANEL_RENDER_OUTPUT_DIR"] {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: root.appending(path: "widget-\(size)-\(dark ? "dark" : "light").png"))
    }
}
