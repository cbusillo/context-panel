import AppKit
import ContextPanelValidationFixtures
import ContextPanelValidationGalleryUI
import Foundation
import SwiftUI

// Renders one macOS Validation Gallery cell to a PNG without launching the app.
// Operator and CI tooling only: it links no app or widget bundle, registers
// nothing with LaunchServices or PlugInKit, and reads only synthetic fixtures.
//
//   ContextPanelSharedViewRenderer --fixture healthy --family systemLarge \
//     --appearance light --presentation overview --output cell.png

private let canvas = CGSize(width: 1_024, height: 768)

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ContextPanelSharedViewRenderer: \(message)\n".utf8))
    exit(EX_USAGE)
}

private func parseArguments(_ arguments: [String]) -> (route: ValidationGalleryRoute, output: URL) {
    let names = ["--fixture", "--family", "--appearance", "--presentation", "--output"]
    var values: [String: String] = [:]
    var index = 0
    while index < arguments.count {
        let name = arguments[index]
        guard names.contains(name), index + 1 < arguments.count, values[name] == nil else {
            fail("unexpected or repeated argument: \(name)")
        }
        values[name] = arguments[index + 1]
        index += 2
    }
    guard let fixture = values["--fixture"].flatMap(ValidationFixtureID.init(rawValue:)),
          let family = values["--family"].flatMap(ValidationGalleryFamily.init(rawValue:)),
          let appearance = values["--appearance"].flatMap(ValidationGalleryAppearance.init(rawValue:)),
          appearance != .adaptive,
          let presentation = values["--presentation"].flatMap(ValidationGalleryPresentation.init(rawValue:)),
          let output = values["--output"], !output.isEmpty
    else {
        fail("--fixture, --family, --appearance (light|dark), --presentation, and --output are required")
    }
    // Application presentations are drawn by views that live in the Mac app target.
    // Without them the gallery falls back to the widget, which would be the wrong image.
    guard presentation == .widget else {
        fail("only the widget presentation can be rendered headlessly; \(presentation.rawValue) needs the Mac app's views")
    }
    return (
        ValidationGalleryRoute(
            fixtureID: fixture,
            family: family,
            appearance: appearance,
            presentation: presentation
        ),
        URL(fileURLWithPath: output)
    )
}

@MainActor
private func render(route: ValidationGalleryRoute) -> Data? {
    let isDark = route.appearance == .dark
    let content = ValidationGalleryView(route: route)
        .frame(width: canvas.width, height: canvas.height)
        .environment(\.colorScheme, isDark ? .dark : .light)
    let hostingView = NSHostingView(rootView: content)
    hostingView.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    hostingView.frame = NSRect(origin: .zero, size: canvas)
    hostingView.layoutSubtreeIfNeeded()
    guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
        return nil
    }
    hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])
}

let (route, output) = parseArguments(Array(CommandLine.arguments.dropFirst()))
guard !FileManager.default.fileExists(atPath: output.path) else {
    fail("refusing to overwrite \(output.path)")
}
let png = MainActor.assumeIsolated { render(route: route) }
guard let png else {
    fail("the gallery cell could not be rendered")
}
do {
    try png.write(to: output, options: .withoutOverwriting)
} catch {
    fail("the PNG could not be written")
}
print("rendered \(route.id) \(Int(canvas.width))x\(Int(canvas.height)) \(png.count) bytes")
