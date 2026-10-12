import AppKit
import SwiftUI
import Testing
import Vision
import WidgetKit
@testable import ContextPanelCore
@testable import ContextPanelWidgetUI

@MainActor
@Test(arguments: ["small", "medium", "large"], ["fullColor", "accented", "vibrant"])
func accountWidgetKeepsContentSeparateFromBackground(size: String, mode: String) throws {
    let family: WidgetFamily = size == "small" ? .systemSmall : size == "medium" ? .systemMedium : .systemLarge
    let dimensions = size == "small" ? CGSize(width: 164, height: 164)
        : CGSize(width: 344, height: size == "medium" ? 164 : 344)
    let renderingMode: WidgetRenderingMode = mode == "accented" ? .accented : mode == "vibrant" ? .vibrant : .fullColor
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let limits = Provider.allCases.enumerated().map { index, provider in
        UsageLimit(provider: provider, accountID: "fixture-\(index)", accountName: "Account \(index + 1)",
            label: "Weekly", windowLabel: "Weekly", unit: .percent, used: 25, limit: 100,
            resetsAt: now.addingTimeInterval(86_400), lastUpdatedAt: now, confidence: .observed)
    }
    let snapshot = WidgetSnapshot(state: .ready, generatedAt: now, limits: limits, status: .healthy, message: "")
    let destination = URL(string: "contextpanel://overview")!
    let view = ContextPanelWidgetContentView(family: family, snapshot: snapshot,
        displayPreferences: .defaultPreferences,
        links: ContextPanelWidgetLinks(overview: destination, reconnect: destination, cacheStatsSettings: destination),
        presentationDate: now, allowsNavigation: false)
        .environment(\.widgetRenderingMode, renderingMode)
        .cpwThemeVariant(.light)
        .frame(width: dimensions.width, height: dimensions.height)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: image.width * 4, bitsPerPixel: 32))
    let context = try #require(CGContext(data: bitmap.bitmapData, width: image.width, height: image.height,
        bitsPerComponent: 8, bytesPerRow: bitmap.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(bitmap.bitmapData)
    if renderingMode != .fullColor {
        // A solid content background becomes a solid tile when WidgetKit tints
        // the primary group. Padding must reveal the system's container instead.
        #expect(pixels[2 * bitmap.bytesPerRow + 2 * 4 + 3] == 0)
        // Model the primary group's single-color tint, preserving its alpha.
        // This is a shared-view regression check, not OS-composited proof.
        for offset in stride(from: 0, to: bitmap.bytesPerRow * bitmap.pixelsHigh, by: 4) {
            let gray = 255 - pixels[offset + 3]
            pixels[offset] = gray
            pixels[offset + 1] = gray
            pixels[offset + 2] = gray
            pixels[offset + 3] = 255
        }
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: try #require(bitmap.cgImage)).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let text = lines.joined(separator: " ")
    // Vision can read a capital I as a lowercase l at widget font sizes.
    func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "l", with: "i")
    }
    for provider in Provider.allCases {
        #expect(normalized(text).contains(normalized(provider.accountDisplayName)), "Missing provider in \(mode): \(lines)")
    }
    #expect(text.replacingOccurrences(of: " ", with: "").components(separatedBy: "75%").count - 1 >= limits.count,
        "Missing capacity in \(mode): \(lines)")
    if let output = ProcessInfo.processInfo.environment["CONTEXT_PANEL_RENDER_OUTPUT_DIR"] {
        let root = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: root.appending(path: "widget-\(size)-\(mode).png"))
    }
}
